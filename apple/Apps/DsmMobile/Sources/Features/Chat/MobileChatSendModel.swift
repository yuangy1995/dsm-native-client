import DsmCore
import Foundation
import Observation

/// 文字、线程与附件共用发送生命周期；页面切换不释放已提交记录。
@MainActor
@Observable
final class MobileChatSendModel {
    typealias Entry = MobileChatSendStore.Entry
    let context: String
    let recovery: MobileChatSendStore
    private let repository: any ChatRepository
    private let copier: any MobileDocumentImportCopying
    private weak var owner: MobileChatModel?
    private var active = true
    private var work: Task<Bool, Never>?
    private(set) var availability = ChatAvailability(status: .requiresValidation)
    private(set) var confirmedMessage: ChatMessage?
    private(set) var runningID: UUID?
    private(set) var preparingKind: MobileChatSendStore.Kind?
    private(set) var progressFraction: Double?
    private(set) var errorKey: String?
    private(set) var errorConversationID: String?

    init(context: String, repository: any ChatRepository, recovery: MobileChatSendStore,
         copier: any MobileDocumentImportCopying = MobileSecurityScopedDocumentCopier(), owner: MobileChatModel? = nil) {
        self.context = context; self.repository = repository; self.recovery = recovery
        self.copier = copier; self.owner = owner
    }
    var entries: [Entry] { recovery.entries.filter { $0.context == context } }
    var isBusy: Bool { work != nil || recovery.isBusy(in: context) }
    var runningKind: MobileChatSendStore.Kind? {
        preparingKind ?? entries.first { recovery.isExecuting($0.id) }?.kind
    }
    func entry(_ id: UUID) -> Entry? { recovery.entry(id, in: context) }
    func updateAvailability(_ value: ChatAvailability) { availability = value }
    func invalidate() { active = false; work?.cancel(); errorKey = nil }
    func cancel() { work?.cancel() }
    func hasUnfinished(in conversationID: String) -> Bool {
        recovery.failed || entries.contains { $0.conversationID == conversationID && $0.hasUnfinished }
            || (preparingKind != nil && errorConversationID == conversationID)
    }
    func protectsRoot(_ id: String, in conversationID: String) -> Bool {
        protectsPendingMessage(id, in: conversationID)
            || entries.contains { $0.conversationID == conversationID && $0.threadID == id && $0.hasUnfinished }
    }
    func protectsPendingMessage(_ id: String, in conversationID: String) -> Bool {
        recovery.failed || entries.contains { $0.conversationID == conversationID && $0.receipt?.candidateMessageID == id && $0.hasUnfinished }
    }
    func pendingText(_ text: String, conversationID: String, threadID: String? = nil) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.contains { $0.hasUnfinished && $0.conversationID == conversationID && $0.threadID == threadID
            && $0.kind != .attachment && $0.payload?.text == body }
    }
    func canSend(conversationID: String, threadID: String? = nil, text: String?, attachmentKind: ChatAttachmentKind? = nil) -> Bool {
        guard active, !isBusy, !recovery.failed, permits(conversationID: conversationID, threadID: threadID, attachmentKind: attachmentKind) else { return false }
        guard attachmentKind == nil else { return threadID == nil }
        let body = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !body.isEmpty && !pendingText(body, conversationID: conversationID, threadID: threadID)
    }
    func canSendPrepared(_ entry: Entry) -> Bool {
        active && !isBusy && !recovery.failed && entry.phase == .prepared
            && permits(conversationID: entry.conversationID, threadID: entry.threadID, attachmentKind: entry.payload?.attachment?.kind)
    }
    private func permits(conversationID: String, threadID: String?, attachmentKind: ChatAttachmentKind?) -> Bool {
        guard active, availability.status == .available,
              availability.supportedFeatures.contains(attachmentKind.map(MobileChatAttachmentSelection.requiredFeature) ?? .textMessage),
              threadID == nil || availability.supportedFeatures.contains(.threadedReplies),
              owner?.management?.blocksWrites(in: conversationID) != true else { return false }
        if let owner {
            guard owner.state.conversations.contains(where: { $0.id == conversationID && !$0.isEncrypted }) else { return false }
            if let threadID, owner.deletion?.protects(messageID: threadID, conversationID: conversationID) == true { return false }
        }
        return true
    }

    @discardableResult
    func send(conversationID: String, threadID: String? = nil, text: String?, attachment: MobileChatAttachmentSelection? = nil, replacingID: UUID? = nil) async -> Bool {
        guard canSend(conversationID: conversationID, threadID: threadID, text: text, attachmentKind: attachment?.kind),
              recovery.beginPreparing(in: context) else { return false }
        preparingKind = attachment == nil ? (threadID == nil ? .text : .reply) : .attachment
        errorKey = nil; confirmedMessage = nil; errorConversationID = conversationID; progressFraction = nil
        let task = Task { await self.prepareAndSend(conversationID: conversationID, threadID: threadID, text: text, attachment: attachment, replacingID: replacingID) }
        work = task
        let result = await task.value
        work = nil
        return result
    }

    private func prepareAndSend(conversationID: String, threadID: String?, text: String?, attachment: MobileChatAttachmentSelection?, replacingID: UUID?) async -> Bool {
        let id = UUID()
        do {
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var copied: MobileChatSendStore.Attachment?
            if let attachment {
                let name = MobileDocumentTransferController.safeLeafName(attachment.fileName).replacingOccurrences(of: "\"", with: "'")
                let directory = recovery.directory(id), url = directory.appendingPathComponent(name)
                try await copier.copySecurityScopedFile(from: attachment.localURL, to: url, in: directory)
                try Task.checkCancellation()
                let fingerprint = try await Self.fingerprint(url)
                copied = .init(fileName: name, kind: attachment.kind, byteCount: fingerprint.size, contentDigest: fingerprint.digest)
            }
            try Task.checkCancellation()
            guard active else { throw CancellationError() }
            let payload = MobileChatSendStore.Payload(text: trimmed.isEmpty ? nil : trimmed, attachment: copied)
            let entry = Entry(id: id, context: context, conversationID: conversationID, threadID: threadID, createdAt: Date(),
                kind: copied == nil ? (threadID == nil ? .text : .reply) : .attachment,
                inputDigest: try MobileChatSendStore.digest(payload), payload: payload)
            try recovery.reserve(entry, replacing: replacingID)
            recovery.endPreparing(in: context); preparingKind = nil
            return await perform(id, sendPrepared: true)
        } catch {
            recovery.cleanFiles(id); recovery.endPreparing(in: context); preparingKind = nil
            if !(error is CancellationError) { showError(recovery.failed ? "mobile.chat.interaction.storage-error" : "mobile.chat.send.failed") }
            return false
        }
    }

    /// 提交过的记录无论入口参数如何都只能读取，不能重放创建请求。
    @discardableResult
    func run(_ id: UUID, sendPrepared: Bool) async -> Bool {
        guard active, !isBusy, let entry = entry(id), entry.hasUnfinished else { return false }
        errorKey = nil; errorConversationID = entry.conversationID; progressFraction = nil
        let task = Task { await self.perform(id, sendPrepared: sendPrepared) }
        work = task
        let result = await task.value
        work = nil
        return result
    }

    private func perform(_ id: UUID, sendPrepared: Bool) async -> Bool {
        guard active, let initial = entry(id), initial.phase == .submitted || sendPrepared,
              recovery.begin(id, in: context) else { return false }
        runningID = id
        defer { recovery.end(id); runningID = nil; progressFraction = nil }
        do {
            let outcome: ChatMessageSendOutcome
            if let receipt = initial.receipt {
                outcome = try await repository.recoverMessageSend(receipt, recordProgress: recorder(id))
            } else {
                guard let payload = initial.payload, permits(conversationID: initial.conversationID, threadID: initial.threadID,
                    attachmentKind: payload.attachment?.kind) else { throw SendError.unavailable }
                if let attachment = payload.attachment, let url = recovery.attachmentURL(initial) {
                    let value = try await Self.fingerprint(url)
                    guard value.size == attachment.byteCount, value.digest == attachment.contentDigest else { throw SendError.attachmentChanged }
                }
                try Task.checkCancellation()
                guard active else { throw CancellationError() }
                let draft = try ChatMessageDraft(clientRequestID: id, conversationID: initial.conversationID, text: payload.text,
                    localAttachmentURLs: recovery.attachmentURL(initial).map { [$0] } ?? [], threadID: initial.threadID)
                let progress: FileTransferProgress = { [weak self] completed, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.active, self.runningID == id, let total, total > 0 else { return }
                        self.progressFraction = min(max(Double(completed) / Double(total), 0), 1)
                    }
                }
                if payload.attachment != nil {
                    outcome = try await repository.sendAttachmentMessageResult(draft, progress: progress, recordProgress: recorder(id))
                } else {
                    outcome = try await repository.sendMessageResult(draft, progress: progress, recordProgress: recorder(id))
                }
            }
            guard outcome.clientRequestID == id, outcome.conversationID == initial.conversationID else { throw SendError.invalid }
            if outcome.result.status == .confirmedSuccess, let receipt = entry(id)?.receipt,
               let message = outcome.confirmedMessage, receipt.matches(message) {
                try recovery.finish(id, context: context, phase: .complete)
                if active {
                    errorKey = nil; confirmedMessage = message
                    if initial.threadID != nil { owner?.interaction?.acceptSentReply(message) }
                    else { owner?.applySentMessage(message, text: initial.payload?.text) }
                }
                return true
            }
            // 明确的写拒绝与写前取消可结束；恢复读取失败绝不能释放原提交。
            if initial.phase == .prepared, entry(id)?.receipt?.candidateMessageID == nil {
                switch outcome.result.status {
                case .cancelledBeforeSubmission:
                    try recovery.finish(id, context: context, phase: .cancelled)
                case .permissionDenied, .confirmedFailure, .unsupported:
                    try recovery.finish(id, context: context, phase: .failed,
                        failure: outcome.result.status == .permissionDenied ? .denied : (outcome.result.status == .unsupported ? .unavailable : .invalid))
                default: break
                }
            }
            showError(entry(id)?.phase == .submitted ? "mobile.chat.send.pending" : "mobile.chat.send.failed")
        } catch {
            // 回执保存后抛出的任何错误都保留提交记录，包括保存返回身份时磁盘写入失败。
            if entry(id)?.phase == .prepared, !recovery.failed {
                do {
                    let failure: MobileChatSendStore.Failure = (error as? SendError) == .attachmentChanged ? .attachmentChanged
                        : ((error as? SendError) == .unavailable ? .unavailable : .invalid)
                    try recovery.finish(id, context: context, phase: error is CancellationError ? .cancelled : .failed,
                        failure: error is CancellationError ? nil : failure)
                } catch { showError("mobile.chat.interaction.storage-error"); return false }
            }
            showError(recovery.failed ? "mobile.chat.interaction.storage-error"
                : (entry(id)?.phase == .submitted ? "mobile.chat.send.pending" : "mobile.chat.send.failed"))
        }
        return false
    }

    private func recorder(_ id: UUID) -> @Sendable (ChatMessageSendReceipt) async throws -> Void {
        { [weak self] receipt in
            try await MainActor.run {
                guard let self, receipt.clientRequestID == id, let entry = self.entry(id) else { throw CancellationError() }
                if entry.receipt == nil {
                    guard !Task.isCancelled, self.permits(conversationID: entry.conversationID, threadID: entry.threadID,
                        attachmentKind: entry.payload?.attachment?.kind) else { throw CancellationError() }
                }
                try self.recovery.record(receipt, in: self.context)
            }
        }
    }

    func cancelPrepared(_ id: UUID) {
        guard active else { return }
        do { try recovery.cancelPrepared(id, context: context); errorKey = nil }
        catch { showError("mobile.chat.interaction.storage-error") }
    }
    func remove(_ id: UUID) {
        guard active else { return }
        do { try recovery.remove(id, context: context); errorKey = nil }
        catch { showError("mobile.chat.interaction.storage-error") }
    }
    @discardableResult
    func retry(_ id: UUID) async -> Bool {
        guard let entry = entry(id), [.failed, .cancelled].contains(entry.phase), let payload = entry.payload else { return false }
        let attachment = payload.attachment.flatMap { value in recovery.attachmentURL(entry).map { url in
            MobileChatAttachmentSelection(id: id, localURL: url, directoryURL: recovery.directory(id),
                fileName: value.fileName, kind: value.kind, byteCount: value.byteCount)
        } }
        if let original = payload.attachment, let url = recovery.attachmentURL(entry) {
            guard let value = try? await Self.fingerprint(url), value.size == original.byteCount,
                  value.digest == original.contentDigest else { showError("mobile.chat.send.attachment-changed"); return false }
        }
        return await send(conversationID: entry.conversationID, threadID: entry.threadID, text: payload.text, attachment: attachment, replacingID: id)
    }
    private func showError(_ key: String) { if active { errorKey = key } }
    private enum SendError: Error { case unavailable, attachmentChanged, invalid }
    private nonisolated static func fingerprint(_ url: URL) async throws -> (size: Int64, digest: String) {
        try await Task.detached(priority: .utility) {
            let digest = try MobileChatSendStore.fileDigest(url)
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw SendError.attachmentChanged }
            return (Int64(size), digest)
        }.value
    }
}

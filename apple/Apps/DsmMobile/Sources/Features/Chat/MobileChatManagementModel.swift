import DsmCore
import Foundation
import Observation

@MainActor
@Observable
final class MobileChatManagementModel {
    typealias Entry = MobileChatManagementStore.Entry
    enum CloseResult { case closed, failed, pending }
    let context: String
    let recovery: MobileChatManagementStore
    private let repository: any ChatRepository
    private weak var owner: MobileChatModel?
    private var active = true
    private(set) var availability = ChatAvailability(status: .requiresValidation)
    private(set) var isMutating = false
    private(set) var isRecovering = false
    private(set) var errorKey: String?
    private var errorConversationID: String?
    private var errorMessageID: String?
    private(set) var closeResults: [String: CloseResult] = [:]

    init(context: String, repository: any ChatRepository, recovery: MobileChatManagementStore, owner: MobileChatModel? = nil) {
        self.context = context; self.repository = repository; self.recovery = recovery; self.owner = owner
    }
    var pending: [Entry] { recovery.entries.filter { $0.context == context } }
    var isBusy: Bool { isMutating || isRecovering || recovery.failed }
    var canManageConversations: Bool { supports(.closeConversation) }
    func updateAvailability(_ value: ChatAvailability) { availability = value }
    func invalidate() { active = false; errorKey = nil; closeResults = [:] }
    func error(for message: ChatMessage) -> String? {
        errorConversationID == message.conversationID && errorMessageID == message.id ? errorKey : nil
    }
    func hasPending(in conversationID: String, messageID: String? = nil) -> Bool {
        pending.contains { $0.conversationID == conversationID && (messageID == nil || $0.kind == .close || $0.messageID == messageID) }
    }
    func blocksWrites(in conversationID: String) -> Bool {
        isMutating || pending.contains { $0.kind == .close && $0.conversationID == conversationID }
    }
    private func supports(_ feature: ChatFeature) -> Bool {
        active && availability.status == .available && availability.supportedFeatures.contains(feature)
    }
    func canPin(_ message: ChatMessage) -> Bool {
        supports(.pinnedMessages) && !isBusy && message.deliveryState == .sent && message.encryptionState == .notEncrypted
            && !hasPending(in: message.conversationID, messageID: message.id)
            && (owner == nil || owner?.state.selectedConversation?.kind == .group)
            && owner?.state.deletingMessageID == nil && owner?.interaction?.isMutating != true
            && owner?.polls?.isMutating != true
            && owner?.interaction?.pending.contains(where: { $0.kind == .edit && $0.conversationID == message.conversationID && $0.messageID == message.id }) != true
            && owner?.polls?.pending.contains(where: { $0.kind == .vote && $0.conversationID == message.conversationID && $0.messageID == message.id }) != true
    }
    func canClose(_ conversation: ChatConversation) -> Bool {
        canManageConversations && !isBusy && !hasPending(in: conversation.id)
            && owner?.hasUnfinishedChatWrite(in: conversation.id) != true
    }

    func setPinned(_ original: ChatMessage, isPinned: Bool) async -> Bool {
        guard canPin(original), !Task.isCancelled else { return false }
        isMutating = true; errorKey = nil; errorConversationID = original.conversationID; errorMessageID = original.id
        defer { isMutating = false }
        do {
            let conversations = try await repository.listConversations()
            guard conversations.contains(where: { $0.id == original.conversationID && $0.kind == .group && !$0.isEncrypted }),
                  let fresh = try await repository.message(conversationID: original.conversationID, messageID: original.id, threadID: original.threadID),
                  sameContent(original, fresh) else { throw ManagementError.changed }
            let pinned = try await repository.listPinnedMessages(conversationID: original.conversationID)
            let baseline = pinned.first { $0.id == original.id }
            guard (baseline != nil) == original.isPinned,
                  baseline.map({ sameContent(original, $0) && $0.pinnedAt == original.pinnedAt }) ?? true else { throw ManagementError.changed }
            try checkActive()
        } catch { return preflightFailure(error) }
        let entry = Entry(id: UUID(), context: context, kind: isPinned ? .pin : .unpin,
            conversationID: original.conversationID, messageID: original.id)
        guard reserve(entry) else { return false }
        recovery.beginExecution(entry)
        defer { recovery.endExecution(entry) }
        do {
            try await repository.setMessagePinned(conversationID: original.conversationID, messageID: original.id,
                isPinned: isPinned, clientRequestID: entry.id)
            guard recovery.finish(entry) else { return storageFailure() }
            if active {
                await owner?.refreshManagementMessages(in: original.conversationID)
            }
            return active
        } catch { return handle(error, entry: entry) }
    }

    /// 每项只提交一次；出现未知结果后停止本批尚未开始的项。
    func close(_ originals: [ChatConversation]) async {
        guard !originals.isEmpty, Set(originals.map(\.id)).count == originals.count,
              originals.allSatisfy({ canClose($0) }), !Task.isCancelled else { return }
        isMutating = true; errorKey = nil; errorMessageID = nil; closeResults = [:]
        defer { isMutating = false }
        for original in originals {
            guard active, !Task.isCancelled else { break }
            errorConversationID = original.id
            do {
                let current = try await repository.listConversations()
                try checkActive()
                if let fresh = current.first(where: { $0.id == original.id }) {
                    guard fresh.kind == original.kind, fresh.title == original.title,
                          fresh.isEncrypted == original.isEncrypted, Set(fresh.memberIDs) == Set(original.memberIDs) else { throw ManagementError.changed }
                } else {
                    closeResults[original.id] = .closed; owner?.applyClosedConversation(original.id); continue
                }
                try checkActive()
            } catch {
                _ = preflightFailure(error); if active { closeResults[original.id] = .failed }; continue
            }
            let entry = Entry(id: UUID(), context: context, kind: .close, conversationID: original.id, messageID: nil)
            guard reserve(entry) else { break }
            recovery.beginExecution(entry)
            defer { recovery.endExecution(entry) }
            do {
                try await repository.closeConversation(conversationID: original.id, clientRequestID: entry.id)
                guard recovery.finish(entry) else { _ = storageFailure(); break }
                if active { closeResults[original.id] = .closed; owner?.applyClosedConversation(original.id) }
            } catch {
                _ = handle(error, entry: entry)
                let unknown = pending.contains { $0.id == entry.id }
                if active { closeResults[original.id] = unknown ? .pending : .failed }
                if unknown { break }
            }
        }
    }

    func recover() async {
        guard active, !isBusy else { return }
        isRecovering = true; defer { isRecovering = false }
        for entry in pending {
            guard active, !Task.isCancelled else { return }
            // 切换账号后旧请求仍在执行时，新模型不能提前把并发读到的状态当成它的结果。
            guard !recovery.isExecuting(entry) else { continue }
            do {
                let resolved: Bool
                if entry.kind == .close {
                    resolved = try await !repository.listConversations().contains { $0.id == entry.conversationID }
                } else {
                    let conversations = try await repository.listConversations()
                    guard conversations.contains(where: { $0.id == entry.conversationID && $0.kind == .group && !$0.isEncrypted }) else { continue }
                    let values = try await repository.listPinnedMessages(conversationID: entry.conversationID)
                    resolved = values.contains { $0.id == entry.messageID } == (entry.kind == .pin)
                }
                guard active else { return }
                if resolved, recovery.finish(entry) {
                    if entry.kind == .close { closeResults[entry.conversationID] = .closed; owner?.applyClosedConversation(entry.conversationID) }
                    else { await owner?.refreshManagementMessages(in: entry.conversationID) }
                    if errorConversationID == entry.conversationID { errorKey = nil }
                }
            } catch { /* 只读恢复失败时保留原操作，不能重放。 */ }
        }
    }

    private func sameContent(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.conversationID == rhs.conversationID && lhs.senderID == rhs.senderID
            && lhs.text == rhs.text && lhs.attachments == rhs.attachments && lhs.poll == rhs.poll
            && lhs.encryptionState == rhs.encryptionState && lhs.threadID == rhs.threadID
    }
    private func checkActive() throws { guard active, !Task.isCancelled else { throw CancellationError() } }
    private func preflightFailure(_ error: Error) -> Bool {
        if active, !(error is CancellationError) { errorKey = error as? ManagementError == .changed ? "mobile.chat.management.changed" : "mobile.chat.management.failed" }
        return false
    }
    private func reserve(_ entry: Entry) -> Bool {
        guard recovery.reserve(entry) else { return storageFailure() }; return true
    }
    private func storageFailure() -> Bool { if active { errorKey = "mobile.chat.interaction.storage-error" }; return false }
    private func handle(_ error: Error, entry: Entry) -> Bool {
        let rejected = (error as? AppError).map { $0.category != .partialFailure } == true || error is MobileReadOnlyChatRepositoryError
        if rejected { recovery.finish(entry) }
        if active { errorKey = recovery.failed ? "mobile.chat.interaction.storage-error"
            : (rejected ? "mobile.chat.management.failed" : Self.pendingKey(entry.kind)) }
        return false
    }
    static func pendingKey(_ kind: Entry.Kind) -> String { kind == .close ? "mobile.chat.close.pending" : "mobile.chat.announcement.pending" }
    private enum ManagementError: Error, Equatable { case changed }
}

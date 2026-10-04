import DsmCore
import Foundation
import Observation

@MainActor
@Observable
final class MobileChatDeletionModel {
    typealias Entry = MobileChatDeletionStore.Entry
    let context: String
    let recovery: MobileChatDeletionStore
    private let repository: any ChatRepository
    private weak var owner: MobileChatModel?
    private var active = true
    private(set) var availability = ChatAvailability(status: .requiresValidation)
    private(set) var runningID: UUID?
    private(set) var errorKey: String?
    private(set) var errorBatchID: UUID?
    private var cancelRequestedID: UUID?

    init(context: String, repository: any ChatRepository, recovery: MobileChatDeletionStore, owner: MobileChatModel? = nil) {
        self.context = context; self.repository = repository; self.recovery = recovery; self.owner = owner
    }
    var entries: [Entry] { recovery.entries.filter { $0.context == context } }
    var isBusy: Bool { entries.contains { recovery.isExecuting($0.id) } }
    var canDelete: Bool { active && availability.status == .available && availability.supportedFeatures.contains(.deleteOwnMessage) }
    func entry(_ id: UUID) -> Entry? { recovery.entry(id, in: context) }
    func updateAvailability(_ value: ChatAvailability) { availability = value }
    func invalidate() { active = false; errorKey = nil }
    func protects(_ message: ChatMessage) -> Bool {
        recovery.failed || entries.contains { $0.items.contains { ($0.phase == .planned || $0.phase == .submitted)
            && $0.source.messageID == message.id && $0.source.conversationID == message.conversationID } }
    }
    func hasUnfinished(in conversationID: String) -> Bool {
        recovery.failed || entries.contains { $0.hasUnfinished && $0.items.first?.source.conversationID == conversationID }
    }
    func status(for message: ChatMessage) -> String? {
        if recovery.failed { return "mobile.chat.interaction.storage-error" }
        let item = entries.reversed().flatMap(\.items).first { $0.source.messageID == message.id && $0.source.conversationID == message.conversationID }
        switch item?.phase {
        case .submitted: return "chat.delete.pending"
        case .planned: return "mobile.chat.deletion.planned"
        case .failed: return "mobile.chat.deletion.failed"
        default: return nil
        }
    }
    static func permits(_ message: ChatMessage) -> Bool {
        message.deliveryState == .sent && message.encryptionState == .notEncrypted && message.isFromCurrentUser == true
            && message.threadID == nil
    }
    func canSelect(_ message: ChatMessage) -> Bool {
        canDelete && !isBusy && !recovery.failed && Self.permits(message) && !protects(message)
            && !otherWriteBlocks(messageID: message.id, conversationID: message.conversationID)
            && (owner == nil || (owner?.state.selectedConversation?.id == message.conversationID
                && owner?.state.selectedConversation?.isEncrypted == false
                && owner?.state.selectedMessages.messages.contains { $0.id == message.id } == true))
    }
    private func otherWriteBlocks(messageID: String, conversationID: String) -> Bool {
        owner?.interaction?.isMutating == true || owner?.polls?.isMutating == true
            || owner?.timedActions?.isMutating == true || owner?.management?.blocksWrites(in: conversationID) == true
            || owner?.forwarding?.entries.contains(where: { $0.items.contains { ($0.phase == .planned || $0.phase == .submitted)
                && $0.source.messageID == messageID && $0.source.conversationID == conversationID } }) == true
            || owner?.forwarding?.recovery.failed == true
            || owner?.management?.hasPending(in: conversationID, messageID: messageID) == true
            || owner?.timedActions?.hasPending(in: conversationID, targetID: messageID, reminder: true) == true
            || owner?.polls?.pending.contains(where: { $0.kind == .vote && $0.conversationID == conversationID && $0.messageID == messageID }) == true
            || owner?.interaction?.pending.contains(where: { $0.conversationID == conversationID
                && ($0.messageID == messageID || $0.threadID == messageID) }) == true
    }

    /// 必须由明确的删除确认调用；此处先落盘，因此双击不能产生第二份批次。
    func createBatch(_ messages: [ChatMessage]) -> UUID? {
        guard active, !isBusy, !messages.isEmpty, Set(messages.map(\.id)).count == messages.count,
              Set(messages.map(\.conversationID)).count == 1, messages.allSatisfy(canSelect) else { return nil }
        do {
            let items = try messages.sorted { $0.sentAt == $1.sentAt ? $0.id < $1.id : $0.sentAt < $1.sentAt }
                .map { MobileChatDeletionStore.Item(id: UUID(), source: try .init($0)) }
            let entry = Entry(id: UUID(), context: context, createdAt: Date(), items: items)
            try recovery.reserve(entry); errorKey = nil; errorBatchID = nil; return entry.id
        } catch { showError(); return nil }
    }

    func run(_ id: UUID, continuePlanned: Bool) async {
        guard active, !isBusy, !recovery.failed, let initial = entry(id),
              !continuePlanned || canDelete, recovery.begin(id, in: context) else { return }
        // 进入时存在已提交项，本轮始终只读；恢复成功不会顺带删除下一条。
        let allowsNew = continuePlanned && !initial.hasSubmitted
        runningID = id; errorKey = nil; errorBatchID = id; cancelRequestedID = nil
        defer {
            recovery.end(id); runningID = nil
            if active { owner?.updateActive { $0.deletingMessageID = nil } }
            if cancelRequestedID == id {
                do { try recovery.cancelRemaining(id, context: context) } catch { showError() }
                cancelRequestedID = nil
            }
        }
        for item in initial.items where item.phase == .submitted || (allowsNew && item.phase == .planned) {
            guard active, !Task.isCancelled, !recovery.failed, cancelRequestedID != id else { return }
            if active { owner?.updateActive { $0.deletingMessageID = item.source.messageID } }
            do {
                let removed: Bool
                if item.phase == .submitted {
                    removed = try await repository.recoverMessageDeletion(item.source, clientRequestID: item.id)
                } else {
                    guard canDelete, !otherWriteBlocks(messageID: item.source.messageID, conversationID: item.source.conversationID) else { return }
                    try await repository.deleteMessage(item.source, clientRequestID: item.id) { [weak self] in
                        try await MainActor.run {
                            guard let self, self.canDelete, !Task.isCancelled, self.cancelRequestedID != id else { throw CancellationError() }
                            try self.recovery.progress(item.id, in: id, context: self.context, phase: .submitted)
                        }
                    }
                    removed = true
                }
                if removed {
                    try recovery.progress(item.id, in: id, context: context, phase: .complete)
                    if active { owner?.applyMessageDeletion(item.source) }
                } else if active { errorKey = "chat.delete.pending" }
            } catch {
                let current = entry(id)?.items.first { $0.id == item.id }
                if error is CancellationError, current?.phase == .planned { return }
                // 写前失败可结束；提交后仅当前新请求的明确拒绝或提交前取消可结束。
                let rejected = current?.phase == .planned || (item.phase == .planned
                    && ((error as? AppError).map { $0.category != .partialFailure } == true
                        || error is MobileReadOnlyChatRepositoryError || error is CancellationError))
                if rejected, !recovery.failed {
                    let category = (error as? AppError)?.category
                    let failure: MobileChatDeletionStore.Failure = category == .conflict ? .changed : (category == .permissionDenied ? .denied : .unavailable)
                    try? recovery.progress(item.id, in: id, context: context, phase: .failed, failure: failure)
                }
                if active { errorKey = recovery.failed ? "mobile.chat.interaction.storage-error"
                    : (rejected ? "mobile.chat.deletion.failed" : "chat.delete.pending") }
            }
            guard let latest = entry(id), !latest.hasSubmitted else { return }
        }
    }
    func cancelRemaining(_ id: UUID) {
        guard active else { return }
        if runningID == id { cancelRequestedID = id; return }
        do { try recovery.cancelRemaining(id, context: context); errorKey = nil } catch { showError() }
    }
    func remove(_ id: UUID) {
        guard active else { return }
        do { try recovery.remove(id, context: context); errorKey = nil } catch { showError() }
    }
    private func showError() {
        if active { errorKey = recovery.failed ? "mobile.chat.interaction.storage-error" : "mobile.chat.deletion.failed" }
    }
}

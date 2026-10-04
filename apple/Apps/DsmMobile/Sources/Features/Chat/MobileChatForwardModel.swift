import DsmCore
import Foundation
import Observation

@MainActor
@Observable
final class MobileChatForwardModel {
    typealias Entry = MobileChatForwardStore.Entry
    typealias Destination = MobileChatForwardStore.Destination
    enum TargetState { case loading, content, empty, error }
    let context: String
    let recovery: MobileChatForwardStore
    private let repository: any ChatRepository
    private weak var owner: MobileChatModel?
    private var active = true
    private var targetGeneration = 0
    private(set) var availability = ChatAvailability(status: .requiresValidation)
    private(set) var targetState: TargetState = .loading
    private(set) var conversations: [ChatConversation] = []
    private(set) var contacts: [ChatUser] = []
    private(set) var contactsUnavailable = false
    private(set) var errorKey: String?
    private(set) var errorBatchID: UUID?
    private(set) var runningID: UUID?
    private var cancelRequestedID: UUID?

    init(context: String, repository: any ChatRepository, recovery: MobileChatForwardStore, owner: MobileChatModel? = nil) {
        self.context = context; self.repository = repository; self.recovery = recovery; self.owner = owner
    }
    var entries: [Entry] { recovery.entries.filter { $0.context == context } }
    var isBusy: Bool { entries.contains { recovery.isExecuting($0.id) } }
    var canForward: Bool { active && availability.status == .available && availability.supportedFeatures.contains(.messageForward) }
    var hasUnfinishedContacts: Bool {
        entries.contains { $0.destinations.contains { $0.kind == .contact && ($0.phase == .planned || $0.phase == .submitted) } }
    }
    var blocksContactCreation: Bool { recovery.failed || hasUnfinishedContacts }
    var canSelectNewContact: Bool {
        availability.supportedFeatures.contains(.directConversation) && !blocksContactCreation
            && owner?.conversationCreator?.requiresReview != true && owner?.conversationCreator?.isSubmitting != true
            && owner?.conversationCreator?.storageFailed != true
    }
    func updateAvailability(_ value: ChatAvailability) { availability = value }
    func invalidate() { active = false; targetGeneration &+= 1; conversations = []; contacts = []; errorKey = nil }
    func entry(_ id: UUID) -> Entry? { recovery.entry(id, in: context) }
    func protects(_ message: ChatMessage) -> Bool {
        recovery.failed || entries.contains { $0.items.contains { ($0.phase == .planned || $0.phase == .submitted)
            && $0.source.messageID == message.id && $0.source.conversationID == message.conversationID } }
    }
    func hasUnfinished(in conversationID: String) -> Bool {
        recovery.failed || entries.contains { entry in entry.hasUnfinished && (entry.items.contains { $0.source.conversationID == conversationID }
            || entry.destinations.contains { $0.conversationID == conversationID }) }
    }
    static func permits(_ message: ChatMessage) -> Bool {
        message.deliveryState == .sent && message.encryptionState == .notEncrypted && message.poll == nil
            && message.kind != .system && message.kind != .unknown
            && (message.text?.isEmpty == false || !message.attachments.isEmpty)
    }
    func canSelect(_ message: ChatMessage) -> Bool {
        canForward && !isBusy && !recovery.failed && Self.permits(message) && !protects(message)
            && !otherWriteBlocks(message)
    }
    private func otherWriteBlocks(_ message: ChatMessage) -> Bool {
        owner?.state.deletingMessageID != nil || owner?.interaction?.isMutating == true
            || owner?.management?.hasPending(in: message.conversationID, messageID: message.id) == true
            || owner?.management?.blocksWrites(in: message.conversationID) == true
            || owner?.interaction?.pending.contains(where: { $0.kind == .edit && $0.conversationID == message.conversationID && $0.messageID == message.id }) == true
            || owner?.state.deleteReviewBlockedMessageIDsByConversation[message.conversationID]?.contains(message.id) == true
    }

    func loadTargets(sourceConversationID: String) async {
        guard active else { return }
        targetGeneration &+= 1
        let generation = targetGeneration
        targetState = .loading; contactsUnavailable = false
        do {
            let values = try await repository.listConversations()
            guard active, generation == targetGeneration, !Task.isCancelled else { return }
            conversations = values.filter { $0.id != sourceConversationID && !$0.isEncrypted
                && Int($0.id).map({ $0 > 0 }) == true }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            contacts = []
            if availability.supportedFeatures.contains(.directConversation) {
                do {
                    let users = try await repository.listUsers()
                    guard active, generation == targetGeneration, !Task.isCancelled else { return }
                    let currentUserID = users.first { $0.isCurrentUser == true }?.id
                    // 已有单聊从会话列表选择，避免同一接收人在两个分区重复出现。
                    let existingMembers = Set(values.filter { $0.kind == .direct && !$0.isEncrypted && $0.memberIDs.count == 2 }
                        .flatMap(\.memberIDs))
                    contacts = users.filter { !$0.isDisabled && $0.isCurrentUser != true && $0.id != currentUserID
                        && !existingMembers.contains($0.id) }
                        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                } catch {
                    guard active, generation == targetGeneration else { return }
                    contactsUnavailable = true
                }
            }
            guard active, generation == targetGeneration else { return }
            targetState = conversations.isEmpty && contacts.isEmpty ? (contactsUnavailable ? .error : .empty) : .content
        } catch {
            guard active, generation == targetGeneration else { return }
            targetState = .error
        }
    }

    func createBatch(messages: [ChatMessage], conversationIDs: Set<String>, contactIDs: Set<String>) -> UUID? {
        guard active, !isBusy, !messages.isEmpty, Set(messages.map(\.id)).count == messages.count,
              Set(messages.map(\.conversationID)).count == 1, messages.allSatisfy(canSelect),
              !conversationIDs.isEmpty || !contactIDs.isEmpty,
              conversationIDs.allSatisfy({ id in conversations.contains { $0.id == id && id != messages[0].conversationID && !$0.isEncrypted }
                  && owner?.management?.blocksWrites(in: id) != true }),
              contactIDs.allSatisfy({ id in contacts.contains { $0.id == id } }),
              contactIDs.isEmpty || canSelectNewContact
        else { return nil }
        do {
            let items = try messages.sorted { $0.sentAt == $1.sentAt ? $0.id < $1.id : $0.sentAt < $1.sentAt }
                .map { MobileChatForwardStore.Item(id: UUID(), source: try .init($0)) }
            let destinations = conversationIDs.sorted().map(Destination.conversation) + contactIDs.sorted().map(Destination.contact)
            let entry = Entry(id: UUID(), context: context, createdAt: Date(), items: items, destinations: destinations)
            try recovery.reserve(entry); errorKey = nil; errorBatchID = nil; return entry.id
        } catch { showError(); return nil }
    }

    /// 继续仅处理计划项；刷新只读取提交项，绝不悄悄发送下一条。
    func run(_ id: UUID, continuePlanned: Bool) async {
        guard active, !isBusy, !recovery.failed, let initial = entry(id),
              !continuePlanned || canForward, recovery.begin(id, in: context) else { return }
        runningID = id; errorKey = nil; errorBatchID = id; cancelRequestedID = nil
        defer {
            recovery.end(id); runningID = nil
            if cancelRequestedID == id {
                do { try recovery.cancelRemaining(id, context: context) } catch { showError() }
                cancelRequestedID = nil
            }
        }
        for destination in initial.destinations where destination.phase == .submitted || (continuePlanned && destination.phase == .planned) {
            guard active, !Task.isCancelled, cancelRequestedID != id else { return }
            if destination.phase == .planned, owner?.conversationCreator?.requiresReview == true || owner?.conversationCreator?.isSubmitting == true || owner?.conversationCreator?.storageFailed == true {
                showError(); return
            }
            await resolve(destination, in: id)
            guard !recovery.failed, let latest = entry(id), !latest.destinations.contains(where: { $0.phase == .submitted }) else { return }
        }
        guard active, !Task.isCancelled, let ready = entry(id), !ready.destinations.contains(where: { $0.phase == .submitted || $0.phase == .planned }) else { return }
        for item in ready.items where item.phase == .submitted || (continuePlanned && item.phase == .planned) {
            guard active, !Task.isCancelled, !recovery.failed, cancelRequestedID != id else { return }
            do {
                if let receipt = item.receipt {
                    _ = try await repository.recoverForward(receipt, recordProgress: recorder(id, allowInitial: false))
                } else {
                    guard !ready.targetIDs.isEmpty else { throw ForwardError.unavailable }
                    guard let original = try await repository.message(conversationID: item.source.conversationID,
                        messageID: item.source.messageID, threadID: item.source.threadID), item.source.matches(original),
                          Self.permits(original), !otherWriteBlocks(original) else { throw ForwardError.changed }
                    guard active, !Task.isCancelled else { return }
                    _ = try await repository.forwardMessage(original, toConversationIDs: ready.targetIDs,
                        clientRequestID: item.id, recordProgress: recorder(id, allowInitial: true))
                }
            } catch {
                // 无回执的准备失败没有写入；写前回执后只有明确拒绝或共享层的提交前取消可结束。
                let current = entry(id)?.items.first { $0.id == item.id }
                let rejected = current?.receipt == nil || (item.receipt == nil
                    && ((error as? AppError).map { $0.category != .partialFailure } == true
                        || error is MobileReadOnlyChatRepositoryError || error is CancellationError))
                if rejected, !recovery.failed { try? recovery.failItem(item.id, in: id, context: context) }
                if active { errorKey = recovery.failed ? "mobile.chat.interaction.storage-error"
                    : (rejected ? "mobile.chat.forward.failed" : "mobile.chat.forward.pending") }
            }
            guard let latest = entry(id), !latest.items.contains(where: { $0.phase == .submitted }) else { return }
        }
    }

    private func recorder(_ id: UUID, allowInitial: Bool) -> @Sendable (ChatForwardReceipt) async throws -> Void {
        { [weak self] receipt in
            try await MainActor.run {
                guard let self else { throw CancellationError() }
                let existing = self.entry(id)?.items.first { $0.id == receipt.clientRequestID }?.receipt
                // 已写入的迟到结果仍落盘到原上下文；新写入必须来自仍有效的页面。
                if existing == nil {
                    guard allowInitial, self.active, !Task.isCancelled else { throw CancellationError() }
                }
                try self.recovery.progress(receipt, in: id, context: self.context)
            }
        }
    }

    private func resolve(_ destination: Destination, in id: UUID) async {
        do {
            let outcome: ChatConversationCreateOutcome
            if destination.phase == .submitted {
                outcome = try await repository.recoverDirectConversation(userID: destination.referenceID, clientRequestID: destination.id)
            } else {
                outcome = try await repository.openDirectConversationResult(userID: destination.referenceID, clientRequestID: destination.id) { [weak self] in
                    try await MainActor.run {
                        guard let self, self.active, !Task.isCancelled else { throw CancellationError() }
                        try self.recovery.destination(destination.id, in: id, context: self.context, phase: .submitted)
                    }
                }
            }
            if outcome.result.status == .confirmedSuccess, let conversation = outcome.confirmedConversation,
               !conversation.isEncrypted, conversation.kind == .direct, conversation.memberIDs.contains(destination.referenceID),
               conversation.id != entry(id)?.items.first?.source.conversationID {
                try recovery.destination(destination.id, in: id, context: context, phase: .complete, conversationID: conversation.id)
                if active, !conversations.contains(where: { $0.id == conversation.id }) { conversations.append(conversation) }
            } else if [.submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess].contains(outcome.result.status) {
                if active { errorKey = "mobile.chat.forward.pending" }
            } else {
                try recovery.destination(destination.id, in: id, context: context, phase: .failed)
                if active { errorKey = "mobile.chat.forward.recipient-failed" }
            }
        } catch {
            if entry(id)?.destinations.first(where: { $0.id == destination.id })?.phase == .planned, !recovery.failed {
                try? recovery.destination(destination.id, in: id, context: context, phase: .failed)
            }
            if active { errorKey = recovery.failed ? "mobile.chat.interaction.storage-error" : "mobile.chat.forward.recipient-failed" }
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
    private func showError() { if active { errorKey = recovery.failed ? "mobile.chat.interaction.storage-error" : "mobile.chat.forward.failed" } }
    private enum ForwardError: Error { case changed, unavailable }
}

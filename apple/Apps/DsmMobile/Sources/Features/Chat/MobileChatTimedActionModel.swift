import DsmCore
import Foundation
import Observation

@MainActor
@Observable
final class MobileChatTimedActionModel {
    typealias Entry = MobileChatTimedActionStore.Entry
    let context: String
    let recovery: MobileChatTimedActionStore
    private let repository: any ChatRepository
    private weak var owner: MobileChatModel?
    private var active = true
    private var reminderGeneration = 0
    private var scheduleGeneration = 0
    private(set) var availability = ChatAvailability(status: .requiresValidation)
    private(set) var reminders: [ChatReminder] = []
    private(set) var schedules: [ChatScheduledMessage] = []
    private(set) var reminderConversationID: String?
    private(set) var scheduleConversationID: String?
    private(set) var reminderState: MobilePageState = .loading
    private(set) var scheduleState: MobilePageState = .loading
    private(set) var isMutating = false
    private(set) var isRecovering = false
    private(set) var errorKey: String?
    private var errorConversationID: String?

    init(context: String, repository: any ChatRepository, recovery: MobileChatTimedActionStore, owner: MobileChatModel? = nil) {
        self.context = context; self.repository = repository; self.recovery = recovery; self.owner = owner
    }
    var pending: [Entry] { recovery.entries.filter { $0.context == context } }
    var canManageReminders: Bool { supports(.reminderManagement) }
    var canManageSchedules: Bool { supports(.scheduledMessage) }
    var isBusy: Bool { isMutating || isRecovering || recovery.failed }
    func updateAvailability(_ value: ChatAvailability) { availability = value }
    func invalidate() {
        active = false; reminderGeneration &+= 1; scheduleGeneration &+= 1
        reminders = []; schedules = []; errorKey = nil
    }
    func clearError() { errorKey = nil; errorConversationID = nil }
    func error(in conversationID: String) -> String? { errorConversationID == conversationID ? errorKey : nil }

    func canSetReminder(_ message: ChatMessage) -> Bool {
        supports(.reminder) && !isBusy && message.encryptionState == .notEncrypted && message.deliveryState == .sent
            && owner?.state.deletingMessageID != message.id
            && !hasPending(in: message.conversationID, targetID: message.id, reminder: true)
    }
    func canCreateSchedule(in conversation: ChatConversation) -> Bool {
        canManageSchedules && !isBusy && !conversation.isEncrypted
            && !pending.contains { $0.kind == .createSchedule && $0.conversationID == conversation.id }
    }
    func hasPending(in conversationID: String, targetID: String, reminder: Bool) -> Bool {
        pending.contains { $0.conversationID == conversationID && $0.kind.isReminder == reminder && $0.targetID == targetID }
    }
    private func supports(_ feature: ChatFeature) -> Bool {
        active && availability.status == .available && availability.supportedFeatures.contains(feature)
    }

    func loadReminders(in conversationID: String) async {
        guard canManageReminders else { return }
        reminderGeneration &+= 1; let generation = reminderGeneration
        reminderConversationID = conversationID; reminders = []; reminderState = .loading
        do {
            let values = try await repository.listReminders(conversationID: conversationID)
            guard active, generation == reminderGeneration else { return }
            reminders = values; reminderState = values.isEmpty ? .empty : .content
        } catch { if active, generation == reminderGeneration { reminderState = .error } }
    }
    func loadSchedules(in conversationID: String) async {
        guard canManageSchedules else { return }
        scheduleGeneration &+= 1; let generation = scheduleGeneration
        scheduleConversationID = conversationID; schedules = []; scheduleState = .loading
        do {
            let values = try await repository.listScheduledMessages(conversationID: conversationID)
            guard active, generation == scheduleGeneration else { return }
            schedules = values; scheduleState = values.isEmpty ? .empty : .content
        } catch { if active, generation == scheduleGeneration { scheduleState = .error } }
    }
    func message(for reminder: ChatReminder, in conversationID: String) async throws -> ChatMessage? {
        let value = try await repository.message(conversationID: conversationID, messageID: reminder.messageID, threadID: nil)
        guard active else { throw CancellationError() }
        return value
    }

    func setReminder(for original: ChatMessage, at date: Date, replacing baseline: ChatReminder?) async -> Bool {
        guard canSetReminder(original), date > Date(), !Task.isCancelled else { return false }
        isMutating = true; errorKey = nil; defer { isMutating = false }
        do {
            try await requireConversation(original.conversationID)
            guard let fresh = try await repository.message(conversationID: original.conversationID, messageID: original.id, threadID: original.threadID),
                  fresh.id == original.id, fresh.conversationID == original.conversationID, fresh.encryptionState == .notEncrypted else { throw TimedError.changed }
            let current = try await repository.listReminders(conversationID: original.conversationID)
            guard current.first(where: { $0.messageID == original.id }) == baseline, date > Date() else { throw TimedError.changed }
            try checkActive()
        } catch { return preflightFailure(error, in: original.conversationID) }
        let entry = Entry(id: UUID(), context: context, kind: .setReminder, conversationID: original.conversationID,
            targetID: original.id, time: date, textDigest: nil)
        guard reserve(entry) else { return false }
        do {
            let value = try await repository.setReminder(messageID: original.id, remindAt: date, clientRequestID: entry.id)
            guard matches(value, entry) else { throw TimedError.invalidResponse }
            guard finish(entry) else { return false }
            if active, reminderConversationID == nil || reminderConversationID == original.conversationID { await loadReminders(in: original.conversationID) }
            return active
        } catch { return handle(error, entry: entry) }
    }

    func createSchedule(in conversation: ChatConversation, text: String, at date: Date) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canCreateSchedule(in: conversation), !text.isEmpty, date > Date(), !Task.isCancelled else { return false }
        isMutating = true; errorKey = nil; defer { isMutating = false }
        do { try await requireConversation(conversation.id); try checkActive() }
        catch { return preflightFailure(error, in: conversation.id) }
        let entry = Entry(id: UUID(), context: context, kind: .createSchedule, conversationID: conversation.id,
            targetID: nil, time: date, textDigest: MobileChatInteractionStore.digest(text))
        guard reserve(entry) else { return false }
        do {
            let store = recovery
            let value = try await repository.createScheduledMessage(conversationID: conversation.id, text: text, sendAt: date,
                clientRequestID: entry.id) { id in try await store.recordCreatedSchedule(id, entry: entry) }
            guard let saved = recovery.entries.first(where: { $0.id == entry.id }), matches(value, saved) else { throw TimedError.invalidResponse }
            guard finish(entry) else { return false }
            if active, scheduleConversationID == nil || scheduleConversationID == conversation.id { await loadSchedules(in: conversation.id) }
            return active
        } catch { return handle(error, entry: entry) }
    }

    func deleteReminder(_ original: ChatReminder, in conversationID: String) async -> Bool {
        guard canManageReminders, !isBusy, !Task.isCancelled,
              !hasPending(in: conversationID, targetID: original.messageID, reminder: true) else { return false }
        isMutating = true; errorKey = nil; defer { isMutating = false }
        do {
            try await requireConversation(conversationID)
            let current = try await repository.listReminders(conversationID: conversationID)
            guard current.first(where: { $0.messageID == original.messageID }) == original else { throw TimedError.changed }
            try checkActive()
        } catch { return preflightFailure(error, in: conversationID) }
        let entry = Entry(id: UUID(), context: context, kind: .deleteReminder, conversationID: conversationID,
            targetID: original.messageID, time: original.remindAt, textDigest: nil)
        guard reserve(entry) else { return false }
        do {
            try await repository.deleteReminder(messageID: original.messageID, conversationID: conversationID, clientRequestID: entry.id)
            guard finish(entry) else { return false }
            if active, reminderConversationID == nil || reminderConversationID == conversationID { await loadReminders(in: conversationID) }
            return active
        } catch { return handle(error, entry: entry) }
    }

    func deleteSchedule(_ original: ChatScheduledMessage) async -> Bool {
        guard canManageSchedules, !isBusy, !Task.isCancelled,
              !hasPending(in: original.conversationID, targetID: original.id, reminder: false) else { return false }
        isMutating = true; errorKey = nil; defer { isMutating = false }
        do {
            try await requireConversation(original.conversationID)
            let current = try await repository.listScheduledMessages(conversationID: original.conversationID)
            guard current.first(where: { $0.id == original.id }) == original, original.sendAt > Date() else { throw TimedError.changed }
            try checkActive()
        } catch { return preflightFailure(error, in: original.conversationID) }
        let entry = Entry(id: UUID(), context: context, kind: .deleteSchedule, conversationID: original.conversationID,
            targetID: original.id, time: original.sendAt, textDigest: MobileChatInteractionStore.digest(original.text))
        guard reserve(entry) else { return false }
        do {
            try await repository.deleteScheduledMessage(id: original.id, conversationID: original.conversationID, clientRequestID: entry.id)
            // 到达发送时间后列表消失也可能表示已发送，不能据此宣布取消成功。
            guard original.sendAt > Date() else { throw TimedError.invalidResponse }
            guard finish(entry) else { return false }
            if active, scheduleConversationID == nil || scheduleConversationID == original.conversationID { await loadSchedules(in: original.conversationID) }
            return active
        } catch { return handle(error, entry: entry) }
    }

    func recover() async {
        guard active, !isBusy else { return }
        isRecovering = true; defer { isRecovering = false }
        for entry in pending {
            guard active, !Task.isCancelled else { return }
            do {
                let resolved: Bool
                if entry.kind.isReminder {
                    let values = try await repository.listReminders(conversationID: entry.conversationID)
                    resolved = entry.kind == .setReminder ? values.contains { matches($0, entry) }
                        : !values.contains { $0.messageID == entry.targetID }
                    if active, reminderConversationID == entry.conversationID {
                        reminders = values; reminderState = values.isEmpty ? .empty : .content
                    }
                } else {
                    guard entry.targetID != nil else { continue }
                    let values = try await repository.listScheduledMessages(conversationID: entry.conversationID)
                    resolved = entry.kind == .createSchedule ? values.contains { matches($0, entry) }
                        : entry.time > Date() && !values.contains { $0.id == entry.targetID }
                    if active, scheduleConversationID == entry.conversationID {
                        schedules = values; scheduleState = values.isEmpty ? .empty : .content
                    }
                }
                guard active else { return }
                if resolved, recovery.finish(entry) { errorKey = nil }
            } catch { /* 恢复只有读取；保留原操作身份，不再次提交。 */ }
        }
    }

    private func requireConversation(_ id: String) async throws {
        let current = try await repository.listConversations()
        guard current.contains(where: { $0.id == id && !$0.isEncrypted }) else { throw TimedError.changed }
        try checkActive()
    }
    private func checkActive() throws { guard active, !Task.isCancelled else { throw CancellationError() } }
    private func preflightFailure(_ error: Error, in conversationID: String) -> Bool {
        errorConversationID = conversationID
        if active, !(error is CancellationError) { errorKey = error as? TimedError == .changed ? "mobile.chat.timed.changed" : "mobile.chat.timed.failed" }
        return false
    }
    private func reserve(_ entry: Entry) -> Bool {
        errorConversationID = entry.conversationID
        guard recovery.reserve(entry) else { errorKey = "mobile.chat.interaction.storage-error"; return false }
        return true
    }
    private func finish(_ entry: Entry) -> Bool {
        guard recovery.finish(entry) else { if active { errorKey = "mobile.chat.interaction.storage-error" }; return false }
        return true
    }
    private func handle(_ error: Error, entry: Entry) -> Bool {
        errorConversationID = entry.conversationID
        // 共享层把提交后的网络及回读异常保留为 partialFailure；明确拒绝可解除本目标限制。
        let rejected = (error as? AppError).map { $0.category != .partialFailure } == true || error is MobileReadOnlyChatRepositoryError
        if rejected { recovery.finish(entry) }
        if active { errorKey = recovery.failed ? "mobile.chat.interaction.storage-error"
            : (rejected ? "mobile.chat.timed.failed" : Self.pendingKey(entry.kind)) }
        return false
    }
    static func pendingKey(_ kind: Entry.Kind) -> String {
        switch kind {
        case .setReminder: "mobile.chat.reminder.pending"
        case .deleteReminder: "mobile.chat.reminder.cancel-pending"
        case .createSchedule: "mobile.chat.schedule.pending"
        case .deleteSchedule: "mobile.chat.schedule.cancel-pending"
        }
    }
    private func matches(_ value: ChatReminder, _ entry: Entry) -> Bool {
        value.messageID == entry.targetID && abs(value.remindAt.timeIntervalSince(entry.time)) < 1
    }
    private func matches(_ value: ChatScheduledMessage, _ entry: Entry) -> Bool {
        value.id == entry.targetID && value.conversationID == entry.conversationID
            && MobileChatInteractionStore.digest(value.text) == entry.textDigest && abs(value.sendAt.timeIntervalSince(entry.time)) < 1
    }
    private enum TimedError: Error, Equatable { case changed, invalidResponse }
}

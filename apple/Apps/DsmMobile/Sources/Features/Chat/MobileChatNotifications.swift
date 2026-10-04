import DsmCore
import Foundation
import Observation

/// 系统授权由用户开启；新消息仅前台接收，已确认的提醒交给系统按时显示。
@MainActor
@Observable
final class MobileChatNotifications {
    static let enabledKey = "lanstash.mobile.chat.notifications.enabled.v1"
    static let scopesKey = "lanstash.mobile.chat.notifications.scopes.v1"
    static let reminderLimit = 50
    struct Destination: Hashable, Identifiable {
        let scope: String; let conversationID: String; let messageID: String
        var id: String { scope + "/" + conversationID + "/" + messageID }
    }

    private(set) var enabled: Bool
    private(set) var authorization: MobileChatNotificationAuthorization = .notDetermined
    private(set) var isChangingPermission = false
    private(set) var errorKey: String?
    private(set) var destination: Destination?
    private(set) var scope: String?
    var isForeground = false
    private let driver: any MobileChatNotificationDriving
    private let defaults: UserDefaults
    private let now: () -> Date
    private var context: String?
    private var generation = 0
    private var incomingGeneration = 0
    private var startedAt: Date
    private var baseline: [String: Date]?
    private var reminderValues: [String: [ChatReminder]] = [:]
    private var scheduled: [String: MobileChatNotice] = [:]
    private var pendingDestination: Destination?
    private var cleanupTask: Task<Void, Never>?
    private var reminderLoadGeneration = 0
    private var reminderRevision = 0
    private var reminderTask: Task<Void, Never>?
    private var needsReminderSync = false

    init(defaults: UserDefaults = .standard, driver: any MobileChatNotificationDriving = MobileSystemChatNotificationDriver(), now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.driver = driver; self.now = now; self.startedAt = now()
        enabled = defaults.bool(forKey: Self.enabledKey)
        driver.onOpen = { [weak self] scope, conversation, message in
            guard let self, self.enabled else { return }
            let value = Destination(scope: scope, conversationID: conversation, messageID: message)
            if self.scope == scope { self.destination = value }
            else if self.context == nil { self.pendingDestination = value }
        }
        driver.shouldPresent = { [weak self] scope in self?.enabled == true && self?.scope == scope }
    }

    func configure(context: String?) {
        guard self.context != context else { return }
        self.context = context; generation &+= 1; incomingGeneration &+= 1
        reminderLoadGeneration &+= 1; reminderRevision &+= 1
        baseline = nil; startedAt = now(); reminderValues = [:]; scheduled = [:]; destination = nil
        if let context {
            var scopes = defaults.dictionary(forKey: Self.scopesKey) as? [String: String] ?? [:]
            let value = scopes[context] ?? UUID().uuidString
            scopes[context] = value; defaults.set(scopes, forKey: Self.scopesKey); scope = value
        } else { scope = nil; isForeground = false }
        if enabled, let pendingDestination, pendingDestination.scope == scope { destination = pendingDestination }
        pendingDestination = nil
        enqueueCleanup(exceptScope: enabled ? scope : nil)
    }

    func clearDestination() { destination = nil }

    func setEnabled(_ value: Bool) async {
        guard !isChangingPermission else { return }
        if !value {
            enabled = false; defaults.set(false, forKey: Self.enabledKey)
            generation &+= 1; baseline = nil; destination = nil; scheduled = [:]; errorKey = nil
            enqueueCleanup(exceptScope: nil)
            await cleanupTask?.value
            return
        }
        isChangingPermission = true; errorKey = nil
        defer { isChangingPermission = false }
        do {
            authorization = await driver.authorization()
            if authorization == .notDetermined {
                authorization = try await driver.requestAuthorization() ? .allowed : .denied
            }
            enabled = authorization == .allowed
            defaults.set(enabled, forKey: Self.enabledKey)
            if !enabled { errorKey = "mobile.chat.notification.denied" }
            else { baseline = nil; await reconcileReminders() }
        } catch { errorKey = "mobile.chat.notification.failed" }
    }

    func refreshAuthorization() async {
        authorization = await driver.authorization()
        if authorization == .denied, enabled {
            scheduled = [:]; enqueueCleanup(exceptScope: nil)
        }
    }

    func processIncoming(_ values: [ChatConversation], repository: any ChatRepository,
        suppressConversation: @escaping (String) -> Bool) async {
        let previous = baseline
        baseline = Dictionary(values.compactMap { value in value.lastActivityAt.map { (value.id, $0) } }, uniquingKeysWith: max)
        guard let previous, enabled, isForeground, let scope else { return }
        let generation = self.generation
        incomingGeneration &+= 1; let request = incomingGeneration
        await refreshAuthorization()
        guard authorization == .allowed else { return }
        await cleanupTask?.value
        for conversation in values where conversation.unreadCount > 0 && !conversation.isEncrypted {
            guard isCurrent(scope, generation), isForeground, request == incomingGeneration else { return }
            guard let activity = conversation.lastActivityAt, activity > (previous[conversation.id] ?? startedAt),
                  !suppressConversation(conversation.id) else { continue }
            do {
                let page = try await repository.listMessages(conversationID: conversation.id, before: nil, limit: 1)
                guard isCurrent(scope, generation), isForeground, request == incomingGeneration,
                      let latest = page.messages.last, latest.conversationID == conversation.id,
                      latest.isFromCurrentUser == false, latest.encryptionState == .notEncrypted,
                      latest.sentAt > (previous[conversation.id] ?? startedAt), !suppressConversation(conversation.id) else { continue }
                let notice = MobileChatNotice(id: "mobile.chat.\(scope).message.\(conversation.id).\(latest.id)",
                    scope: scope, conversationID: conversation.id, messageID: latest.id, date: nil)
                try await driver.add(notice)
                if !isCurrent(scope, generation) || !isForeground { await driver.remove(ids: [notice.id]) }
            } catch { /* 新消息仍保留在聊天列表，不把系统提醒失败当作消息读取失败。 */ }
        }
    }

    func refreshReminders(conversations: [ChatConversation], repository: any ChatRepository) async {
        guard enabled, isForeground, let scope else { return }
        let generation = self.generation
        reminderLoadGeneration &+= 1; let request = reminderLoadGeneration
        if errorKey == "mobile.chat.notification.sync-failed" { errorKey = nil }
        await refreshAuthorization()
        guard authorization == .allowed else { return }
        let ids = Set(conversations.filter { !$0.isEncrypted }.map(\.id))
        reminderValues = reminderValues.filter { ids.contains($0.key) }
        for conversation in conversations where !conversation.isEncrypted {
            guard isCurrent(scope, generation), isForeground, request == reminderLoadGeneration else { return }
            do {
                let values = try await repository.listReminders(conversationID: conversation.id)
                guard isCurrent(scope, generation), request == reminderLoadGeneration else { return }
                reminderValues[conversation.id] = values
            } catch { if isCurrent(scope, generation), request == reminderLoadGeneration { errorKey = "mobile.chat.notification.sync-failed" } }
        }
        reminderRevision &+= 1
        await reconcileReminders()
    }

    func updateReminders(_ values: [ChatReminder], conversationID: String) async {
        guard scope != nil else { return }
        reminderLoadGeneration &+= 1; reminderRevision &+= 1
        if errorKey == "mobile.chat.notification.sync-failed" { errorKey = nil }
        reminderValues[conversationID] = values
        await reconcileReminders()
    }

    private func reconcileReminders() async {
        needsReminderSync = true
        if let reminderTask { await reminderTask.value; return }
        let task = Task { [weak self] in
            while let self, self.needsReminderSync {
                self.needsReminderSync = false
                await self.writeReminderSnapshot()
            }
        }
        reminderTask = task
        await task.value
        reminderTask = nil
    }

    private func writeReminderSnapshot() async {
        guard enabled, authorization == .allowed, let scope else { return }
        let generation = self.generation
        let revision = reminderRevision
        await cleanupTask?.value
        guard isCurrent(scope, generation), revision == reminderRevision else { return }
        let notices = reminderValues.flatMap { conversation, reminders in
            reminders.filter { $0.remindAt > now() }.map { reminder in
                MobileChatNotice(id: "mobile.chat.\(scope).reminder.\(conversation).\(reminder.id)",
                    scope: scope, conversationID: conversation, messageID: reminder.messageID, date: reminder.remindAt)
            }
        }.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        if errorKey == "mobile.chat.notification.limit" { errorKey = nil }
        if notices.count > Self.reminderLimit { errorKey = "mobile.chat.notification.limit" }
        let target = Dictionary(notices.prefix(Self.reminderLimit).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let obsolete = Set(scheduled.keys).subtracting(target.keys)
        let allIDs = Set(reminderValues.flatMap { conversation, reminders in
            reminders.map { "mobile.chat.\(scope).reminder.\(conversation).\($0.id)" }
        })
        await driver.remove(ids: Array(Set(scheduled.keys).subtracting(allIDs)))
        // 同时清理上次运行留下、但服务器已经取消或改期的系统请求。
        await driver.removeReminders(scope: scope, keepingIDs: Set(target.keys))
        guard isCurrent(scope, generation), revision == reminderRevision else { return }
        for id in obsolete { scheduled[id] = nil }
        for notice in target.values where scheduled[notice.id] != notice {
            guard isCurrent(scope, generation), revision == reminderRevision else { return }
            do {
                try await driver.add(notice)
                if isCurrent(scope, generation), revision == reminderRevision { scheduled[notice.id] = notice }
                else { await driver.remove(ids: [notice.id]) }
            } catch { errorKey = "mobile.chat.notification.sync-failed" }
        }
    }

    private func isCurrent(_ scope: String, _ generation: Int) -> Bool {
        enabled && self.scope == scope && self.generation == generation && !Task.isCancelled
    }

    private func enqueueCleanup(exceptScope scope: String?) {
        let previous = cleanupTask
        cleanupTask = Task { [driver] in await previous?.value; await driver.removeAll(exceptScope: scope) }
    }
}

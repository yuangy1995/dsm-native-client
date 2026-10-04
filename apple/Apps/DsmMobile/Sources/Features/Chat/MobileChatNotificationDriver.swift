import DsmLocalization
import Foundation
import UserNotifications

enum MobileChatNotificationAuthorization: Sendable { case notDetermined, allowed, denied }

struct MobileChatNotice: Equatable, Sendable {
    let id: String
    let scope: String
    let conversationID: String
    let messageID: String
    let date: Date?
}

@MainActor
protocol MobileChatNotificationDriving: AnyObject {
    var onOpen: ((String, String, String) -> Void)? { get set }
    var shouldPresent: ((String) -> Bool)? { get set }
    func authorization() async -> MobileChatNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func add(_ notice: MobileChatNotice) async throws
    func remove(ids: [String]) async
    func removeReminders(scope: String, keepingIDs: Set<String>) async
    func removeAll(exceptScope: String?) async
}

/// 只保存账号隔离标识与消息定位，不把正文、附件、地址或凭据交给通知中心。
@MainActor
final class MobileSystemChatNotificationDriver: NSObject, MobileChatNotificationDriving, UNUserNotificationCenterDelegate {
    var onOpen: ((String, String, String) -> Void)?
    var shouldPresent: ((String) -> Bool)?
    private let center = UNUserNotificationCenter.current()
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    override init() {
        super.init()
        if !isRunningTests { center.delegate = self }
    }

    func authorization() async -> MobileChatNotificationAuthorization {
        guard !isRunningTests else { return .denied }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        guard !isRunningTests else { return false }
        return try await center.requestAuthorization(options: [.alert, .sound])
    }

    func add(_ notice: MobileChatNotice) async throws {
        guard !isRunningTests else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.string(notice.date == nil ? "chat.notification.title" : "mobile.chat.notification.reminder-title")
        content.body = L10n.string(notice.date == nil ? "mobile.chat.notification.message" : "mobile.chat.notification.reminder")
        content.sound = .default
        content.threadIdentifier = "mobile.chat.\(notice.scope).\(notice.conversationID)"
        content.userInfo = ["chatScope": notice.scope, "conversationID": notice.conversationID, "messageID": notice.messageID]
        let trigger = notice.date.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0.timeIntervalSinceNow), repeats: false) }
        try await center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: trigger))
    }

    func remove(ids: [String]) async {
        guard !isRunningTests, !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    func removeAll(exceptScope: String?) async {
        guard !isRunningTests else { return }
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map { $0.request.identifier }
        let keeps = exceptScope.map { "mobile.chat.\($0)." }
        await remove(ids: Array(Set(pending + delivered)).filter {
            $0.hasPrefix("mobile.chat.") && (keeps == nil || !$0.hasPrefix(keeps!))
        })
    }

    func removeReminders(scope: String, keepingIDs: Set<String>) async {
        guard !isRunningTests else { return }
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        // 已按时显示的提醒留给用户查看；这里只清理尚未触发的旧计划。
        center.removePendingNotificationRequests(withIdentifiers: pending.filter {
            $0.hasPrefix("mobile.chat.\(scope).reminder.") && !keepingIDs.contains($0)
        })
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let scope = notification.request.content.userInfo["chatScope"] as? String else { return [] }
        return await MainActor.run { shouldPresent?(scope) == true ? [.banner, .sound, .list] : [] }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let scope = response.notification.request.content.userInfo["chatScope"] as? String,
              let conversation = response.notification.request.content.userInfo["conversationID"] as? String,
              let message = response.notification.request.content.userInfo["messageID"] as? String else { return }
        await MainActor.run { onOpen?(scope, conversation, message) }
    }
}

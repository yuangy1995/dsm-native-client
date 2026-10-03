import AppKit
import DsmLocalization
import UserNotifications

extension Notification.Name {
    static let chatNotificationOpened = Notification.Name("LanStashChatNotificationOpened")
}

@MainActor
enum ChatNotificationService {
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    static func enable() async -> Bool {
        guard !isRunningTests else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        }
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    static func isEnabled() async -> Bool {
        guard !isRunningTests else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    static func post(conversationTitle: String, conversationID: String, scope: String, messageID: String) {
        guard !isRunningTests else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = L10n.string("chat.notification.title")
            content.body = L10n.string("chat.notification.body", conversationTitle)
            content.sound = .default
            content.threadIdentifier = "chat.\(scope).\(conversationID)"
            // 仅含本次连接的随机标识和消息定位，不写入正文、地址或会话凭据。
            content.userInfo = ["chatScope": scope, "conversationID": conversationID]
            try? await center.add(UNNotificationRequest(identifier: "chat.\(scope).\(messageID)", content: content, trigger: nil))
        }
    }
}

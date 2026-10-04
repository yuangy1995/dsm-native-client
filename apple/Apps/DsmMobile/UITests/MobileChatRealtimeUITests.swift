import XCTest
import UIKit

@MainActor
final class MobileChatRealtimeUITests: XCTestCase {
    func test阅读历史保留未读跳到最新才清除() {
        let app = launch(); enableChat(app); navigate("chat", "Chat", app)
        let row = element("chat-conversation-27", app)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(row.label.contains("3 unread")); row.tap()
        XCTAssertTrue(app.staticTexts["Sample message 11"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Sample message 60"].firstMatch.isHittable)
        screenshot("History does not read the latest message")
        back(app)
        XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertTrue(row.label.contains("3 unread")); row.tap()
        let latest = element("chat-scroll-latest", app)
        XCTAssertTrue(latest.waitForExistence(timeout: 5)); latest.tap()
        XCTAssertTrue(app.staticTexts["Sample message 60"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sample message 60"].firstMatch.isHittable)
        XCTAssertTrue(latest.waitForNonExistence(timeout: 5))
        screenshot("Latest visible message has been read")
        back(app)
        XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertFalse(row.label.contains("unread"))
    }

    func test已读被拒绝时仍能阅读且未读不被本机清空() {
        let app = launch(state: "chat-realtime-read-denied"); enableChat(app); navigate("chat", "Chat", app)
        let row = element("chat-conversation-27", app)
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
        let latest = element("chat-scroll-latest", app)
        XCTAssertTrue(latest.waitForExistence(timeout: 5)); latest.tap()
        XCTAssertTrue(app.staticTexts["Sample message 60"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(latest.waitForNonExistence(timeout: 5))
        back(app)
        XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertTrue(row.label.contains("3 unread"))
        screenshot("Rejected read receipt keeps unread count")
    }

    func test离开聊天页后前台仍更新会话摘要() {
        let app = launch(state: "chat-realtime-live"); enableChat(app); navigate("chat", "Chat", app)
        XCTAssertTrue(app.staticTexts["Sample message 60"].firstMatch.waitForExistence(timeout: 8))
        navigate("settings", "App settings", app)
        // 等合成服务产生新消息；此时可见页面始终是设置，打开 Chat 本身不会重新加载列表。
        let delay = expectation(description: "Synthetic foreground message")
        DispatchQueue.main.asyncAfter(deadline: .now() + 17) { delay.fulfill() }
        wait(for: [delay], timeout: 20)
        navigate("chat", "Chat", app)
        XCTAssertTrue(app.staticTexts["Sample message 61"].firstMatch.waitForExistence(timeout: 3))
        screenshot("Conversation updated while settings was visible")
    }

    func test中文深色大字通知拒绝给出系统设置恢复入口() {
        let app = launch(state: "chat-realtime-notifications-denied", chinese: true)
        enableChat(app, chinese: true)
        let notification = element("chat-notifications-enabled", app)
        for _ in 0..<8 { if notification.exists && notification.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(notification.waitForExistence(timeout: 5)); notification.switches.firstMatch.tap()
        let recovery = element("chat-notifications-settings", app)
        for _ in 0..<4 { if recovery.exists && recovery.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(recovery.waitForExistence(timeout: 5)); XCTAssertTrue(recovery.isHittable)
        XCTAssertTrue(app.staticTexts["通知已被关闭。请前往系统设置，允许岚仓发送通知。"].firstMatch.exists)
        screenshot("Chinese dark large-text notification recovery")
    }

    private func launch(state: String = "chat-realtime-history", chinese: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if chinese { app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch(); return app
    }
    private func enableChat(_ app: XCUIApplication, chinese: Bool = false) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", chinese ? "App 设置" : "App settings", app)
        let toggle = element("mobile.settings.module.chat", app)
        for _ in 0..<7 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.switches.firstMatch.tap()
    }
    private func navigate(_ id: String, _ title: String, _ app: XCUIApplication) {
        if app.tabBars.buttons[title].exists { app.tabBars.buttons[title].tap() }
        else { let item = element("mobile.navigation.\(id)", app); XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap() }
    }
    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars["Sample chat"].buttons.element(boundBy: 0)
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
}

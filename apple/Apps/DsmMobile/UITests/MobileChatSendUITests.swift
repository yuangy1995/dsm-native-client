import XCTest

@MainActor
final class MobileChatSendUITests: XCTestCase {
    func test普通消息发送成功后记录可移除且不会删除聊天消息() {
        let app = launch(); defer { app.terminate() }
        openChat(app); openConversation(app); send("New sample message", app)
        XCTAssertTrue(app.staticTexts["New sample message"].waitForExistence(timeout: 8))
        openRecords(app, inConversation: true); openFirstRecord(app)
        XCTAssertTrue(app.staticTexts["Sent"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("chat-send-retry", app).exists)
        screenshot(app, "Confirmed send keeps only its receipt")
        element("chat-send-remove", app).tap()
        XCTAssertTrue(app.staticTexts["No sent messages"].waitForExistence(timeout: 5))
        screenshot(app, "Removing the last local record shows an empty list")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["New sample message"].waitForExistence(timeout: 5))
    }

    func test发送后读取中断重启仅刷新原消息并恢复成功() {
        let app = launch(state: "chat-send-read-unavailable")
        openChat(app); openConversation(app); send("Recover this message", app)
        XCTAssertTrue(app.staticTexts[pending].waitForExistence(timeout: 8))
        XCTAssertFalse(element("chat-compose-send", app).isEnabled)
        openRecords(app, inConversation: true); openFirstRecord(app)
        XCTAssertTrue(element("chat-send-refresh", app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("chat-send-retry", app).exists)
        screenshot(app, "Interrupted send offers only refresh")
        app.terminate(); app.launchEnvironment["LANSTASH_UI_STATE"] = "chat-send-restored"
        app.launchArguments += ["--ui-preserve-transfer-fixture"]; app.launch(); defer { app.terminate() }
        openChat(app); openRecords(app, inConversation: false); openFirstRecord(app)
        element("chat-send-refresh", app).tap()
        XCTAssertTrue(app.staticTexts["Sent"].waitForExistence(timeout: 8))
        XCTAssertFalse(element("chat-send-refresh", app).exists)
        XCTAssertFalse(element("chat-send-retry", app).exists)
        screenshot(app, "Restart recovers the original message without resending")
    }

    func test丢失创建回执重启后保持原记录且不能重发或移除() {
        let app = launch(state: "chat-send-lost-ack")
        openChat(app); openConversation(app); send("Keep this record", app)
        XCTAssertTrue(app.staticTexts[pending].waitForExistence(timeout: 8))
        app.terminate(); app.launchEnvironment["LANSTASH_UI_STATE"] = "chat-send-restored"
        app.launchArguments += ["--ui-preserve-transfer-fixture"]; app.launch(); defer { app.terminate() }
        openChat(app); openRecords(app, inConversation: false); openFirstRecord(app)
        element("chat-send-refresh", app).tap()
        XCTAssertTrue(app.staticTexts[pending].waitForExistence(timeout: 8))
        XCTAssertTrue(element("chat-send-refresh", app).exists)
        XCTAssertFalse(element("chat-send-retry", app).exists); XCTAssertFalse(element("chat-send-remove", app).exists)
        screenshot(app, "Missing creation receipt remains protected after restart")
    }

    func test中文深色大字号明确拒绝可重新发送并更新唯一记录() {
        let app = launch(state: "chat-send-denied", chinese: true); defer { app.terminate() }
        openChat(app, chinese: true); openConversation(app); send("合成发送内容", app, chinese: true)
        XCTAssertTrue(app.staticTexts["消息未能发送。请在发送记录中重试。"].waitForExistence(timeout: 8))
        openRecords(app, inConversation: true); openFirstRecord(app)
        XCTAssertTrue(app.staticTexts["你没有发送此消息的权限。请联系管理员。"].waitForExistence(timeout: 5))
        screenshot(app, "Chinese dark large-text send rejection")
        let retry = element("chat-send-retry", app)
        for _ in 0..<4 { if retry.isHittable { break }; app.swipeUp() }
        retry.tap()
        XCTAssertTrue(app.navigationBars["发送记录"].waitForExistence(timeout: 8))
        XCTAssertEqual(records(app).count, 1)
        screenshot(app, "Retry replaces the old local record")
    }

    private var pending: String { "The message hasn’t appeared yet. Refresh its status in Sent messages later. Sending it again is currently unavailable." }
    private func launch(state: String = "chat-send-content", chinese: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if chinese { app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch(); return app
    }
    private func openChat(_ app: XCUIApplication, chinese: Bool = false) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", chinese ? "App 设置" : "App settings", app)
        let toggle = element("mobile.settings.module.chat", app)
        for _ in 0..<5 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.switches.firstMatch.tap()
        navigate("chat", chinese ? "聊天" : "Chat", app)
        XCTAssertTrue(app.staticTexts["Sample chat"].firstMatch.waitForExistence(timeout: 8))
    }
    private func navigate(_ id: String, _ title: String, _ app: XCUIApplication) {
        if app.tabBars.buttons[title].exists { app.tabBars.buttons[title].tap() }
        else { let item = element("mobile.navigation.\(id)", app); XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap() }
    }
    private func openConversation(_ app: XCUIApplication) {
        app.staticTexts["Sample chat"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Sample message 1"].waitForExistence(timeout: 8))
    }
    private func send(_ text: String, _ app: XCUIApplication, chinese: Bool = false) {
        let field = element("chat-compose-text", app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(field.frame.width, 120, "The composer must remain usable in a narrow iPad column.")
        field.tap(); field.typeText(text)
        let button = element("chat-compose-send", app)
        XCTAssertTrue(button.isEnabled); button.tap()
    }
    private func openRecords(_ app: XCUIApplication, inConversation: Bool) {
        if inConversation { element("chat-more", app).tap() }
        let button = element("chat-send-records", app)
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
    }
    private func records(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-send-record-"))
    }
    private func openFirstRecord(_ app: XCUIApplication) {
        let record = records(app).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5)); record.tap()
        XCTAssertTrue(element("chat-send-status", app).waitForExistence(timeout: 5))
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

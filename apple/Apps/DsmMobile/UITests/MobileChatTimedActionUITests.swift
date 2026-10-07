import XCTest

@MainActor
final class MobileChatTimedActionUITests: XCTestCase {
    func test定时消息创建列表与取消确认() {
        let app = launch(state: "chat-timed-empty"); defer { app.terminate() }
        openChat(app); openList("schedules", app)
        XCTAssertTrue(app.staticTexts["No scheduled messages"].waitForExistence(timeout: 5))
        element("chat-schedule-create", app).tap(); enterSchedule(app)
        app.buttons["chat-schedule-submit"].tap()
        XCTAssertTrue(app.staticTexts["Later sample"].waitForExistence(timeout: 8))
        screenshot(app, "Created scheduled message")
        element("chat-schedule-cancel-job-101", app).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        app.alerts.buttons["Keep"].tap()
        XCTAssertTrue(app.staticTexts["Later sample"].exists)
        element("chat-schedule-cancel-job-101", app).tap()
        app.alerts.buttons["Cancel scheduled message"].tap()
        XCTAssertTrue(app.staticTexts["No scheduled messages"].waitForExistence(timeout: 8))
    }
    func test消息提醒保存修改与取消() {
        let app = launch(state: "chat-timed-empty"); defer { app.terminate() }
        openChat(app)
        app.staticTexts["Sample message 1"].firstMatch.press(forDuration: 1)
        element("chat-reminder-9001", app).tap()
        let save = app.buttons["chat-reminder-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); save.tap()
        XCTAssertTrue(element("chat-more", app).waitForExistence(timeout: 8))
        openList("reminders", app)
        let reminder = element("chat-reminder-open-9001", app)
        XCTAssertTrue(reminder.waitForExistence(timeout: 8)); reminder.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        screenshot(app, "Saved message reminder can be opened and edited")
        app.navigationBars["Message reminder"].buttons["Close"].tap()
        element("chat-reminder-cancel-9001", app).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel reminder"].tap()
        XCTAssertTrue(app.staticTexts["No reminders"].waitForExistence(timeout: 8))
    }
    func test定时创建中断后重启按原回执恢复() {
        let app = launch(state: "chat-timed-read-failure")
        openChat(app); openList("schedules", app)
        element("chat-schedule-create", app).tap(); enterSchedule(app)
        app.buttons["chat-schedule-submit"].tap()
        let pending = "The scheduled message has not appeared yet. Refresh in a moment and check the chat for delivery."
        XCTAssertTrue(app.staticTexts[pending].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["chat-schedule-submit"].isEnabled)
        screenshot(app, "Interrupted schedule creation keeps its receipt")
        app.terminate(); app.launchEnvironment["LANSTASH_UI_STATE"] = "chat-timed-restored"
        app.launchArguments += ["--ui-preserve-transfer-fixture"]
        app.launch(); defer { app.terminate() }
        openChat(app); openList("schedules", app)
        XCTAssertTrue(app.staticTexts["Later sample"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts[pending].exists)
        element("chat-schedule-create", app).tap()
        XCTAssertTrue(element("chat-schedule-text", app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("chat-schedule-text", app).isEnabled)
        screenshot(app, "Recovered schedule allows a new draft")
    }
    func test中文深色大字定时列表及筛选空状态() {
        let app = launch(chinese: true, dark: true); defer { app.terminate() }
        openChat(app, chinese: true); openList("schedules", app)
        XCTAssertTrue(app.staticTexts["Scheduled sample"].waitForExistence(timeout: 8))
        screenshot(app, "Chinese dark accessible schedule list")
        let search = app.searchFields["搜索消息"].firstMatch
        for _ in 0..<3 { if search.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("missing")
        XCTAssertTrue(app.staticTexts["没有匹配的消息"].waitForExistence(timeout: 5))
        screenshot(app, "Chinese filtered empty schedule list")
    }
    func test提醒与定时的空内容载入错误和加载状态() {
        for state in ["chat-timed-empty", "chat-timed-load-error", "chat-timed-loading"] {
            for list in ["reminders", "schedules"] {
                let app = launch(state: state); openChat(app); openList(list, app)
                let expected = state == "chat-timed-empty" ? (list == "reminders" ? "No reminders" : "No scheduled messages")
                    : (state == "chat-timed-load-error" ? "Could not load messages" : "Loading…")
                XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 8))
                if state == "chat-timed-load-error" { XCTAssertTrue(app.buttons["Try Again"].exists) }
                screenshot(app, "Timed message state \(state) \(list)"); app.terminate()
            }
        }
    }
    private func enterSchedule(_ app: XCUIApplication) {
        let text = element("chat-schedule-text", app)
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap(); text.typeText("Later sample")
        let submit = app.buttons["chat-schedule-submit"]
        for _ in 0..<3 { if submit.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(submit.isEnabled)
    }
    private func openList(_ name: String, _ app: XCUIApplication) {
        element("chat-more", app).tap()
        let list = element("chat-\(name)-list", app)
        XCTAssertTrue(list.waitForExistence(timeout: 5)); list.tap()
    }
    private func launch(state: String = "chat-timed-content", chinese: Bool = false, dark: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if dark { app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch(); return app
    }
    private func openChat(_ app: XCUIApplication, chinese: Bool = false) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", title: chinese ? "App 设置" : "App settings", app)
        MobileUITestNavigation.enableModule(app, module: "chat", test: self)
        navigate("chat", title: chinese ? "聊天" : "Chat", app)
        let chat = app.staticTexts["Sample chat"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 8)); chat.tap()
        XCTAssertTrue(app.staticTexts["Sample message 1"].firstMatch.waitForExistence(timeout: 8))
    }
    private func navigate(_ destination: String, title: String, _ app: XCUIApplication) {
        if app.tabBars.buttons[title].exists { app.tabBars.buttons[title].tap() }
        else { let button = element("mobile.navigation.\(destination)", app); XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap() }
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let value = XCTAttachment(screenshot: app.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value)
    }
}

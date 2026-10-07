import XCTest

@MainActor
final class MobileChatPollUITests: XCTestCase {
    func test创建投票查看结果并提交选择() {
        let app = launch(); defer { app.terminate() }
        openChat(app); element("chat-poll-create", app).tap()
        enterPoll(app)
        app.buttons["chat-poll-submit"].tap()
        XCTAssertTrue(app.staticTexts["Lunch?"].firstMatch.waitForExistence(timeout: 8))
        element("chat-poll-open-9400", app).tap()
        let choice = app.buttons["chat-poll-choice-choice-0"]
        XCTAssertTrue(choice.waitForExistence(timeout: 8)); choice.tap()
        app.buttons["chat-poll-vote"].tap()
        XCTAssertTrue(app.staticTexts["Votes: 1"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["chat-poll-vote"].isEnabled)
        screenshot(app, "Created poll and current user vote")
    }

    func test创建结果中断后重启恢复原投票() {
        let app = launch(state: "chat-poll-create-read-failure")
        openChat(app); element("chat-poll-create", app).tap(); enterPoll(app)
        app.buttons["chat-poll-submit"].tap()
        XCTAssertTrue(app.staticTexts["The new poll has not appeared yet. Refresh the conversation in a moment."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["chat-poll-submit"].isEnabled)
        screenshot(app, "Interrupted poll creation keeps the original receipt")
        app.terminate(); app.launchEnvironment["LANSTASH_UI_STATE"] = "chat-poll-created"
        app.launchArguments += ["--ui-preserve-transfer-fixture"]
        app.launch(); defer { app.terminate() }
        openChat(app)
        XCTAssertTrue(app.staticTexts["Lunch?"].firstMatch.waitForExistence(timeout: 8))
        element("chat-poll-create", app).tap()
        XCTAssertFalse(app.staticTexts["The new poll has not appeared yet. Refresh the conversation in a moment."].exists)
        XCTAssertTrue(element("chat-poll-question", app).isEnabled)
        screenshot(app, "Restarted poll has recovered and new creation is available")
    }

    func test中文深色大字多选投票与已结束投票() {
        for state in ["chat-poll-multiple", "chat-poll-closed"] {
            let app = launch(state: state, chinese: true, dark: true)
            openChat(app, chinese: true); element("chat-poll-open-9300", app).tap()
            let first = app.buttons["chat-poll-choice-choice-0"]
            XCTAssertTrue(first.waitForExistence(timeout: 8))
            if state == "chat-poll-multiple" {
                first.tap(); app.buttons["chat-poll-choice-choice-1"].tap()
                let submit = app.buttons["chat-poll-vote"]
                for _ in 0..<3 { if submit.isHittable { break }; app.swipeUp() }
                submit.tap()
                XCTAssertTrue(app.staticTexts["1 票"].firstMatch.waitForExistence(timeout: 8))
                XCTAssertFalse(submit.isEnabled)
            } else {
                XCTAssertTrue(app.staticTexts["投票已结束"].waitForExistence(timeout: 8))
                XCTAssertFalse(first.isEnabled)
            }
            screenshot(app, "Chinese dark accessible poll \(state)")
            app.terminate()
        }
    }

    func test投票载入失败和已删除状态各有正确内容() {
        for state in ["chat-poll-load-error", "chat-poll-missing", "chat-poll-loading"] {
            let app = launch(state: state); openChat(app)
            element("chat-poll-open-9300", app).tap()
            let text = state == "chat-poll-load-error" ? "Could not load poll"
                : (state == "chat-poll-missing" ? "Message unavailable" : "Loading poll…")
            XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 8))
            if state == "chat-poll-load-error" { XCTAssertTrue(app.buttons["Try Again"].exists) }
            screenshot(app, "Poll state \(state)")
            app.terminate()
        }
    }

    private func enterPoll(_ app: XCUIApplication) {
        let question = element("chat-poll-question", app)
        XCTAssertTrue(question.waitForExistence(timeout: 5)); question.tap(); question.typeText("Lunch?")
        for (index, text) in ["Pasta", "Soup"].enumerated() {
            let option = element("chat-poll-option-\(index)", app); option.tap(); option.typeText(text)
        }
        XCTAssertTrue(app.buttons["chat-poll-submit"].isEnabled)
    }
    private func launch(state: String = "chat-poll-content", chinese: Bool = false, dark: Bool = false) -> XCUIApplication {
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
        XCTAssertTrue(app.staticTexts["Sample poll"].firstMatch.waitForExistence(timeout: 8))
    }
    private func navigate(_ destination: String, title: String, _ app: XCUIApplication) {
        MobileUITestNavigation.open(app, destination: destination, title: title, test: self)
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let value = XCTAttachment(screenshot: app.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value)
    }
}

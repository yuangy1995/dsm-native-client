import XCTest

@MainActor
final class MobileChatForwardUITests: XCTestCase {
    func test多条消息搜索接收人并转发到已有会话和新联系人() {
        let app = launch(); defer { app.terminate() }; openChat(app); selectMessages(app)
        let target = app.buttons["chat-forward-target-conversation-28"]
        XCTAssertTrue(target.waitForExistence(timeout: 8)); screenshot(app, "Forwarding recipients before selection")
        let search = app.searchFields["Search chats or people"]
        XCTAssertTrue(search.exists); search.tap(); search.typeText("missing")
        XCTAssertTrue(app.staticTexts["No Matching Recipients"].waitForExistence(timeout: 5))
        screenshot(app, "Forwarding recipient filter empty"); app.buttons["Show All"].tap()
        target.tap(); app.buttons["chat-forward-target-conversation-30"].tap(); app.buttons["chat-forward-target-contact-2"].tap()
        XCTAssertTrue(app.buttons["chat-forward-submit"].isEnabled); app.buttons["chat-forward-submit"].tap()
        let completed = app.buttons["chat-forward-remove-record"]
        for _ in 0..<4 { if completed.exists && completed.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(completed.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["chat-forward-refresh"].exists)
        screenshot(app, "Two messages forwarded to three recipients")
    }

    func test部分接收成功后重启刷新再继续剩余消息() {
        let app = launch(state: "chat-forward-partial"); openChat(app); selectMessages(app)
        let first = app.buttons["chat-forward-target-conversation-28"]
        XCTAssertTrue(first.waitForExistence(timeout: 8)); first.tap(); app.buttons["chat-forward-target-conversation-30"].tap()
        app.buttons["chat-forward-submit"].tap()
        let refresh = app.buttons["chat-forward-refresh"]
        for _ in 0..<4 { if refresh.exists && refresh.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(refresh.waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["chat-forward-continue"].exists)
        screenshot(app, "Partly delivered forwarding pauses following messages")
        app.terminate(); app.launchEnvironment["LANSTASH_UI_STATE"] = "chat-forward-restored"
        app.launchArguments += ["--ui-preserve-transfer-fixture"]; app.launch(); defer { app.terminate() }
        openChat(app); app.buttons["chat-more"].tap(); app.buttons["chat-forward-records"].tap()
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-forward-record-")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 8)); record.tap()
        for _ in 0..<4 { if refresh.exists && refresh.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(refresh.waitForExistence(timeout: 8)); refresh.tap()
        let next = app.buttons["chat-forward-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 8)); screenshot(app, "Read-only recovery leaves next message unsent")
        next.tap()
        XCTAssertTrue(app.buttons["chat-forward-remove-record"].waitForExistence(timeout: 8))
        XCTAssertFalse(refresh.exists); screenshot(app, "Explicit continuation sends only remaining messages")
    }

    func test丢回执不能重发并可取消剩余消息() {
        let app = launch(state: "chat-forward-unknown"); defer { app.terminate() }; openChat(app); selectMessages(app)
        let target = app.buttons["chat-forward-target-conversation-28"]
        XCTAssertTrue(target.waitForExistence(timeout: 8)); target.tap(); app.buttons["chat-forward-submit"].tap()
        let cancel = app.buttons["chat-forward-cancel-remaining"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 8)); cancel.tap()
        XCTAssertTrue(app.staticTexts["Not sent · Cancelled"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat-forward-refresh"].exists)
        XCTAssertFalse(app.buttons["chat-forward-continue"].exists); XCTAssertFalse(app.buttons["chat-forward-remove-record"].exists)
        screenshot(app, "Unknown forwarding retains original item while remaining message is cancelled")
    }

    func test中文深色大字号接收人加载空内容与错误() {
        for state in ["chat-forward-targets-empty", "chat-forward-targets-error", "chat-forward-targets-loading"] {
            let app = launch(state: state, chinese: true); openChat(app, chinese: true); selectMessages(app)
            let label = state == "chat-forward-targets-empty" ? "没有可选择的接收人"
                : (state == "chat-forward-targets-error" ? "无法加载接收人" : "正在加载接收人…")
            XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 8))
            XCTAssertFalse(app.buttons["chat-forward-submit"].isEnabled)
            if state == "chat-forward-targets-error" { XCTAssertTrue(app.buttons["重试"].exists) }
            screenshot(app, "Chinese dark forwarding \(state)"); app.terminate()
        }
    }

    private func selectMessages(_ app: XCUIApplication) {
        app.buttons["chat-more"].tap(); app.buttons["chat-forward-select"].tap()
        let first = app.buttons["chat-forward-source-9001"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap(); app.buttons["chat-forward-source-9002"].tap()
        XCTAssertTrue(first.isSelected); XCTAssertTrue(app.buttons["chat-forward-source-9002"].isSelected)
        app.buttons["chat-forward-next"].tap()
    }
    private func launch(state: String = "chat-forward-content", chinese: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if chinese { app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch(); return app
    }
    private func openChat(_ app: XCUIApplication, chinese: Bool = false) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", title: chinese ? "App 设置" : "App settings", app)
        let toggle = app.descendants(matching: .any).matching(identifier: "mobile.settings.module.chat").firstMatch
        for _ in 0..<5 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.switches.firstMatch.tap()
        navigate("chat", title: chinese ? "聊天" : "Chat", app)
        let chat = app.staticTexts["Sample chat"].firstMatch; XCTAssertTrue(chat.waitForExistence(timeout: 8)); chat.tap()
        XCTAssertTrue(app.staticTexts["Sample message 1"].firstMatch.waitForExistence(timeout: 8))
    }
    private func navigate(_ destination: String, title: String, _ app: XCUIApplication) {
        if app.tabBars.buttons[title].exists { app.tabBars.buttons[title].tap() }
        else {
            let item = app.descendants(matching: .any).matching(identifier: "mobile.navigation.\(destination)").firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        }
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

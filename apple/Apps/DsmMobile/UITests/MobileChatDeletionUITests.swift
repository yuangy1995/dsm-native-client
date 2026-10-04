import XCTest

@MainActor
final class MobileChatDeletionUITests: XCTestCase {
    func test单条菜单删除沿用确认并进入统一记录() {
        let app = launch(); defer { app.terminate() }; openChat(app)
        app.staticTexts["Sample message 1"].firstMatch.press(forDuration: 1)
        let action = app.buttons["Delete"].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap()
        XCTAssertTrue(app.staticTexts["Delete message?"].waitForExistence(timeout: 5))
        app.buttons["Delete"].firstMatch.tap()
        let removed = NSPredicate(format: "exists == false")
        expectation(for: removed, evaluatedWith: app.staticTexts["Sample message 1"].firstMatch)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.staticTexts["Sample message 2"].firstMatch.exists)
        app.buttons["chat-more"].tap(); app.buttons["chat-deletion-records"].tap()
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-deletion-record-")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 8)); record.tap()
        XCTAssertTrue(app.buttons["chat-deletion-remove-record"].waitForExistence(timeout: 8))
        screenshot(app, "Single message deletion uses durable result history")
    }

    func test多条本人消息搜索选择取消确认再删除并显示逐项结果() {
        let app = launch(); defer { app.terminate() }; openChat(app)
        openSelection(app)
        XCTAssertFalse(app.buttons["chat-deletion-source-9003"].exists)
        let search = app.searchFields["Search your messages"]
        XCTAssertTrue(search.exists); search.tap(); search.typeText("missing")
        XCTAssertTrue(app.staticTexts["No Matching Messages"].waitForExistence(timeout: 5))
        screenshot(app, "Deletion selection filter empty"); app.buttons["Show All"].tap()
        selectBoth(app); app.buttons["chat-deletion-submit"].tap()
        let confirm = app.sheets.buttons.matching(identifier: "chat-deletion-confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); screenshot(app, "Explicit message deletion confirmation")
        let cancel = app.sheets.buttons.matching(identifier: "Cancel").firstMatch
        if cancel.exists { cancel.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.75)).tap() }
        XCTAssertTrue(app.buttons["chat-deletion-source-9001"].isSelected)
        app.buttons["chat-deletion-submit"].tap(); confirm.tap()
        XCTAssertTrue(app.buttons["chat-deletion-remove-record"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["chat-deletion-refresh"].exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Deleted").count, 2)
        screenshot(app, "Two messages deleted with separate results")
    }

    func test中断后重启只读刷新再确认继续剩余消息() {
        let app = launch(state: "chat-deletion-partial"); openChat(app); openSelection(app); selectBoth(app)
        app.buttons["chat-deletion-submit"].tap(); app.sheets.buttons.matching(identifier: "chat-deletion-confirm").firstMatch.tap()
        let refresh = app.buttons["chat-deletion-refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["chat-deletion-continue"].exists)
        screenshot(app, "Deletion interruption pauses following message")
        app.terminate(); app.launchEnvironment["LANSTASH_UI_STATE"] = "chat-deletion-restored"
        app.launchArguments += ["--ui-preserve-transfer-fixture"]; app.launch(); defer { app.terminate() }
        openChat(app, expectedMessage: "Sample message 2")
        app.buttons["chat-more"].tap(); app.buttons["chat-deletion-records"].tap()
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-deletion-record-")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 8)); record.tap()
        XCTAssertTrue(refresh.waitForExistence(timeout: 8)); refresh.tap()
        let next = app.buttons["chat-deletion-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 8)); XCTAssertTrue(app.staticTexts["Not deleted yet"].exists)
        screenshot(app, "Read-only deletion recovery leaves next message intact")
        next.tap(); app.sheets.buttons.matching(identifier: "chat-deletion-confirm-continue").firstMatch.tap()
        XCTAssertTrue(app.buttons["chat-deletion-remove-record"].waitForExistence(timeout: 8))
        XCTAssertFalse(refresh.exists); screenshot(app, "Explicit continuation deletes only remaining message")
    }

    func test未知结果不能重删并可保留剩余消息() {
        let app = launch(state: "chat-deletion-unknown"); defer { app.terminate() }; openChat(app); openSelection(app); selectBoth(app)
        app.buttons["chat-deletion-submit"].tap(); app.sheets.buttons.matching(identifier: "chat-deletion-confirm").firstMatch.tap()
        let cancel = app.buttons["chat-deletion-cancel-remaining"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 8)); cancel.tap()
        XCTAssertTrue(app.staticTexts["Kept"].waitForExistence(timeout: 5))
        app.buttons["chat-deletion-refresh"].tap()
        XCTAssertTrue(app.buttons["chat-deletion-refresh"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["chat-deletion-continue"].exists); XCTAssertFalse(app.buttons["chat-deletion-remove-record"].exists)
        screenshot(app, "Unknown deletion remains while other message is kept")
    }

    func test中文深色大字号删除选择加载空内容和错误() {
        for state in ["chat-deletion-empty", "chat-deletion-error", "chat-deletion-loading"] {
            let app = launch(state: state, chinese: true)
            openChat(app, chinese: true, expectedMessage: nil); openSelection(app)
            let label = state == "chat-deletion-empty" ? "没有可删除的消息" : (state == "chat-deletion-error" ? "无法加载消息" : "正在加载消息…")
            XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 8))
            XCTAssertFalse(app.buttons["chat-deletion-submit"].isEnabled)
            if state == "chat-deletion-error" { XCTAssertTrue(app.buttons["重试"].exists) }
            screenshot(app, "Chinese dark deletion \(state)"); app.terminate()
        }
    }

    private func openSelection(_ app: XCUIApplication) {
        let more = app.buttons["chat-more"]; XCTAssertTrue(more.waitForExistence(timeout: 8))
        more.tap(); app.buttons["chat-deletion-select"].tap()
    }
    private func selectBoth(_ app: XCUIApplication) {
        let first = app.buttons["chat-deletion-source-9001"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap(); app.buttons["chat-deletion-source-9002"].tap()
        XCTAssertTrue(first.isSelected); XCTAssertTrue(app.buttons["chat-deletion-source-9002"].isSelected)
    }
    private func launch(state: String = "chat-deletion-content", chinese: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if chinese { app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch(); return app
    }
    private func openChat(_ app: XCUIApplication, chinese: Bool = false, expectedMessage: String? = "Sample message 1") {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", title: chinese ? "App 设置" : "App settings", app)
        let toggle = app.descendants(matching: .any).matching(identifier: "mobile.settings.module.chat").firstMatch
        for _ in 0..<5 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.switches.firstMatch.tap()
        navigate("chat", title: chinese ? "聊天" : "Chat", app)
        let chat = app.staticTexts["Sample chat"].firstMatch; XCTAssertTrue(chat.waitForExistence(timeout: 8)); chat.tap()
        if let expectedMessage { XCTAssertTrue(app.staticTexts[expectedMessage].firstMatch.waitForExistence(timeout: 8)) }
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

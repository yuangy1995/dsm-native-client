import XCTest

@MainActor
final class MobileChatUITests: XCTestCase {
    func test聊天搜索打开原消息并发送线程回复() {
        let app = launch(); defer { app.terminate() }
        openChat(app)
        let search = element("chat-search-all", app)
        XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap()
        let field = app.searchFields["Enter a keyword to search older messages"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Sample\n")
        let result = element("chat-search-result-9001", app)
        XCTAssertTrue(result.waitForExistence(timeout: 8)); result.tap()
        XCTAssertTrue(app.staticTexts["Earlier reply"].waitForExistence(timeout: 8))
        let reply = element("chat-reply-text", app)
        reply.tap(); reply.typeText("New sample reply")
        element("chat-reply-send", app).tap()
        XCTAssertTrue(app.staticTexts["New sample reply"].waitForExistence(timeout: 8))
        XCTAssertFalse(element("chat-reply-send", app).isEnabled)
        screenshot(app, "Search result and confirmed thread reply")
    }

    func test本人消息编辑后显示新文字且他人没有编辑入口() {
        let app = launch(); defer { app.terminate() }
        openChat(app); app.staticTexts["Sample chat"].firstMatch.tap()
        let other = app.staticTexts["Sample message 2"].firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 8)); other.press(forDuration: 1)
        XCTAssertFalse(app.buttons["Edit"].exists)
        app.tap()
        beginEdit(app)
        replaceText(element("chat-edit-text", app), old: "Sample message 1", new: "Edited sample")
        element("chat-edit-save", app).tap()
        XCTAssertTrue(app.staticTexts["Edited sample"].waitForExistence(timeout: 8))
        screenshot(app, "Own message edit updates the conversation")
    }

    func test编辑结果中断重启后只读恢复并重新开放编辑() {
        let app = launch(state: "chat-edit-unknown")
        openChat(app); app.staticTexts["Sample chat"].firstMatch.tap(); beginEdit(app)
        replaceText(element("chat-edit-text", app), old: "Sample message 1", new: "Edited sample")
        element("chat-edit-save", app).tap()
        XCTAssertTrue(app.staticTexts["The change has not appeared yet. Refresh the conversation in a moment."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["chat-edit-save"].isEnabled)
        screenshot(app, "Interrupted edit preserves the original operation")
        app.terminate()
        app.launchEnvironment["LANSTASH_UI_STATE"] = "chat-edit-restored"
        app.launchArguments += ["--ui-preserve-transfer-fixture"]
        app.launch(); defer { app.terminate() }
        openChat(app); app.staticTexts["Sample chat"].firstMatch.tap()
        let updated = app.staticTexts["Edited sample"].firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 8)); updated.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        screenshot(app, "Restarted conversation recovers the completed edit")
    }

    func test中文深色大字号搜索空结果和失败均提供恢复路径() {
        for state in ["chat-content", "chat-search-error"] {
            let app = launch(state: state, language: "zh-Hans", dark: true)
            openChat(app, chinese: true); element("chat-search-all", app).tap()
            let field = app.searchFields["输入关键词搜索历史消息"]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("missing\n")
            let label = state == "chat-content" ? "没有找到相关消息" : "无法搜索消息"
            XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 8))
            screenshot(app, "Chinese dark search state \(state)")
            app.terminate()
        }
    }

    private func launch(state: String = "chat-content", language: String = "en", dark: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", language]
        if dark {
            app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state
        app.launch(); return app
    }

    private func openChat(_ app: XCUIApplication, chinese: Bool = false) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", title: chinese ? "App 设置" : "App settings", app)
        let toggle = element("mobile.settings.module.chat", app)
        for _ in 0..<5 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.switches.firstMatch.tap()
        navigate("chat", title: chinese ? "聊天" : "Chat", app)
        XCTAssertTrue(app.staticTexts["Sample chat"].firstMatch.waitForExistence(timeout: 8))
    }

    private func navigate(_ destination: String, title: String, _ app: XCUIApplication) {
        if app.tabBars.buttons[title].exists { app.tabBars.buttons[title].tap() }
        else { let item = element("mobile.navigation.\(destination)", app); XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap() }
    }

    private func beginEdit(_ app: XCUIApplication) {
        let original = app.staticTexts["Sample message 1"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 8)); original.press(forDuration: 1)
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        XCTAssertTrue(element("chat-edit-text", app).waitForExistence(timeout: 5))
    }

    private func replaceText(_ field: XCUIElement, old: String, new: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.05)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + new)
        XCTAssertEqual(field.value as? String, new)
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
}

import XCTest

@MainActor
final class MobileChatGroupCreationUITests: XCTestCase {
    func test新建群聊选择成员后进入对应会话() {
        let app = launch(); defer { app.terminate() }
        openChat(app); openCreator(app); fillGroup("Sample new group", app)
        element("chat-create-submit", app).tap()
        XCTAssertTrue(app.navigationBars["Sample new group"].waitForExistence(timeout: 8)
            || app.staticTexts["Sample new group"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(element("chat-group-continue", app).exists)
        XCTAssertFalse(element("chat-create-submit", app).exists)
        screenshot(app, "Created group opens its conversation")
    }

    func test加入中断重启先刷新再主动完成邀请() {
        let app = launch(state: "chat-group-join-lost")
        openChat(app); openCreator(app); fillGroup("Recover this group", app)
        element("chat-create-submit", app).tap()
        XCTAssertTrue(element("chat-group-join-status", app).waitForExistence(timeout: 8))
        XCTAssertFalse(element("chat-group-continue", app).exists)
        screenshot(app, "Interrupted join is kept before restart")
        restart(app); defer { app.terminate() }
        openChat(app); openCreator(app)
        element("chat-create-submit", app).tap()
        XCTAssertTrue(element("chat-group-continue", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("chat-group-join-status", app).label.contains("Joined"))
        screenshot(app, "Read-only refresh reveals the remaining invitation")
        element("chat-group-continue", app).tap()
        XCTAssertTrue(app.navigationBars["Recover this group"].waitForExistence(timeout: 8)
            || app.staticTexts["Recover this group"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(element("chat-group-continue", app).exists)
    }

    func test创建丢回执不认领同名群且仍可准备其他聊天() {
        let app = launch(state: "chat-group-create-lost")
        openChat(app); openCreator(app); fillGroup("Unresolved group", app)
        element("chat-create-submit", app).tap()
        XCTAssertTrue(element("chat-group-create-status", app).waitForExistence(timeout: 8))
        restart(app); defer { app.terminate() }
        openChat(app); openCreator(app); element("chat-create-submit", app).tap()
        XCTAssertTrue(element("chat-group-create-status", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("chat-group-create-status", app).label.contains("Progress unavailable"))
        XCTAssertFalse(element("chat-group-continue", app).exists); XCTAssertFalse(element("chat-group-cancel", app).exists)
        screenshot(app, "Missing creation receipt cannot claim a matching group")
        element("chat-group-another", app).tap()
        XCTAssertTrue(element("chat-create-user-2", app).waitForExistence(timeout: 5))
        element("chat-group-records", app).tap()
        let records = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-group-record-"))
        XCTAssertTrue(records.firstMatch.waitForExistence(timeout: 5)); XCTAssertEqual(records.count, 1)
        records.firstMatch.tap()
        XCTAssertTrue(element("chat-group-create-status", app).waitForExistence(timeout: 5))
        screenshot(app, "Unfinished group remains available while starting another chat")
    }

    func test中文深色大字号邀请拒绝保留已完成步骤并可继续() {
        let app = launch(state: "chat-group-invite-denied", chinese: true); defer { app.terminate() }
        openChat(app, chinese: true); openCreator(app); fillGroup("合成群聊", app, chinese: true)
        element("chat-create-submit", app).tap()
        let create = element("chat-group-create-status", app), join = element("chat-group-join-status", app)
        XCTAssertTrue(create.waitForExistence(timeout: 8)); XCTAssertTrue(create.label.contains("已创建"))
        XCTAssertTrue(join.label.contains("已加入"))
        let continueButton = element("chat-group-continue", app)
        reveal(continueButton, app); XCTAssertTrue(continueButton.isEnabled)
        screenshot(app, "Chinese dark large-text partial group creation")
        tapVisible(continueButton, app)
        XCTAssertTrue(element("chat-group-create-status", app).waitForExistence(timeout: 8))
        reveal(element("chat-group-continue", app), app)
        XCTAssertTrue(element("chat-group-continue", app).isEnabled)
        XCTAssertFalse(element("chat-group-cancel", app).exists)
    }

    private func launch(state: String = "chat-group-content", chinese: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if chinese { app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch(); return app
    }
    private func restart(_ app: XCUIApplication) {
        app.terminate(); app.launchEnvironment["LANSTASH_UI_STATE"] = "chat-group-restored"
        app.launchArguments += ["--ui-preserve-transfer-fixture"]; app.launch()
    }
    private func openChat(_ app: XCUIApplication, chinese: Bool = false) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", chinese ? "App 设置" : "App settings", app)
        MobileUITestNavigation.enableModule(app, module: "chat", test: self)
        navigate("chat", chinese ? "聊天" : "Chat", app)
        XCTAssertTrue(app.staticTexts["Sample chat"].firstMatch.waitForExistence(timeout: 8))
    }
    private func navigate(_ id: String, _ title: String, _ app: XCUIApplication) {
        if app.tabBars.buttons[title].exists { app.tabBars.buttons[title].tap() }
        else { let item = element("mobile.navigation.\(id)", app); XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap() }
    }
    private func openCreator(_ app: XCUIApplication) {
        let button = element("chat-create-conversation", app)
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
    }
    private func fillGroup(_ title: String, _ app: XCUIApplication, chinese: Bool = false) {
        let group = app.segmentedControls.buttons[chinese ? "私人群聊" : "Private Group"]
        XCTAssertTrue(group.waitForExistence(timeout: 5)); group.tap()
        let field = element("chat-create-group-name", app)
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(title)
        let first = element("chat-create-user-2", app), second = element("chat-create-user-3", app)
        tapVisible(first, app); XCTAssertTrue(first.isSelected)
        tapVisible(second, app); XCTAssertTrue(second.isSelected)
        XCTAssertTrue(element("chat-create-submit", app).isEnabled)
        screenshot(app, "Group title and selected members")
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        let form = app.collectionViews["chat-create-form"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        let navigation = app.navigationBars.containing(.button, identifier: "chat-create-submit").firstMatch
        for _ in 0..<6 {
            var visible = form.frame.intersection(app.frame)
            let top = max(visible.minY, navigation.frame.maxY)
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? min(visible.maxY, keyboard.frame.minY) : visible.maxY
            visible = CGRect(x: visible.minX, y: top, width: visible.width, height: bottom - top).insetBy(dx: 8, dy: 8)
            if element.exists, !element.frame.isEmpty, visible.contains(element.frame) { return }
            // iPad 弹窗和键盘有独立区域；只在表单的可见范围内滚动。
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: visible.midX, dy: visible.minY + visible.height * 0.8))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: visible.midX, dy: visible.minY + visible.height * 0.2)))
        }
        XCTFail("群聊表单中的目标控件未完整显示")
    }
    private func tapVisible(_ element: XCUIElement, _ app: XCUIApplication) {
        reveal(element, app)
        XCTAssertTrue(element.isEnabled)
        // 系统自动点击会错误地再次滚动；对已完整可见的控件仅点击一次，并由后续状态断言确认结果。
        let frame = element.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let value = XCTAttachment(screenshot: app.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value)
    }
}

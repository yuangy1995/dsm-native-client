import XCTest

@MainActor
final class MobileChatManagementUITests: XCTestCase {
    func test置顶公告查看附件并取消公告() {
        let app = launch(); defer { app.terminate() }; openChat(app)
        app.staticTexts["Sample message 1"].firstMatch.press(forDuration: 1)
        element("chat-pin-9001", app).tap()
        XCTAssertTrue(app.staticTexts["Announcement"].firstMatch.waitForExistence(timeout: 8))
        openAnnouncements(app)
        let original = element("chat-announcement-row-9001", app)
        let attachmentRow = element("chat-announcement-row-9002", app)
        XCTAssertTrue(original.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(attachmentRow.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(attachmentRow.buttons["Preview"].firstMatch.isEnabled, app.debugDescription)
        screenshot(app, "Announcements preserve original messages and attachments")
        attachmentRow.buttons["Preview"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["sample.png"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(element("QLPreviewControllerView", app).exists)
        screenshot(app, "Announcement attachment opens in system preview")
        let done = app.navigationBars["sample.png"].buttons["Close"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.press(forDuration: 1)
        element("chat-pin-9001", app).tap()
        // 云端录像已剩一条公告；用当前查询和系统消失等待保留原来的八秒断言。
        XCTAssertTrue(element("chat-announcement-row-9001", app).waitForNonExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(element("chat-announcement-row-9002", app).exists)
    }
    func test会话多选取消确认和关闭结果() {
        let app = launch(); defer { app.terminate() }; openChat(app)
        openManagement(app)
        element("chat-close-select-27", app).tap(); element("chat-close-select-28", app).tap()
        XCTAssertTrue(element("chat-close-select-27", app).isSelected)
        XCTAssertTrue(element("chat-close-select-28", app).isSelected)
        XCTAssertTrue(element("chat-close-submit", app).isEnabled)
        element("chat-close-submit", app).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3)); screenshot(app, "Close conversations confirms exact targets and retained messages")
        app.alerts.buttons["Cancel"].tap(); XCTAssertTrue(element("chat-close-select-27", app).isEnabled)
        element("chat-close-submit", app).tap(); app.alerts.buttons["Close conversations"].tap()
        XCTAssertTrue(app.staticTexts["Closed"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["chat-close-select-27"].exists); XCTAssertFalse(app.buttons["chat-close-select-28"].exists)
        screenshot(app, "Both conversations closed with individual results")
        app.navigationBars["Manage conversations"].buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["No Conversations"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["No Conversations"].isHittable, app.debugDescription)
        screenshot(app, "Closing current conversation returns to the conversation list")
    }
    func test置顶中断重启仅恢复原操作() {
        let app = launch(state: "chat-management-unknown"); openChat(app)
        app.staticTexts["Sample message 1"].firstMatch.press(forDuration: 1); element("chat-pin-9001", app).tap()
        let pending = "The announcement change has not appeared yet. Refresh in a moment."
        XCTAssertTrue(app.staticTexts[pending].firstMatch.waitForExistence(timeout: 8))
        app.terminate(); app.launchEnvironment["LANSTASH_UI_STATE"] = "chat-management-restored"
        app.launchArguments += ["--ui-preserve-transfer-fixture"]; app.launch(); defer { app.terminate() }
        openChat(app); openAnnouncements(app)
        XCTAssertTrue(app.staticTexts["Sample message 1"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts[pending].exists); screenshot(app, "Recovered announcement after restart")
    }
    func test中文深色大字公告筛选空状态() {
        let app = launch(chinese: true, dark: true); defer { app.terminate() }; openChat(app, chinese: true); openAnnouncements(app)
        XCTAssertTrue(app.staticTexts["sample.png"].firstMatch.waitForExistence(timeout: 8)); screenshot(app, "Chinese dark large text announcements")
        let search = app.searchFields["搜索消息"].firstMatch
        for _ in 0..<3 { if search.isHittable { break }; app.swipeDown() }
        search.tap(); search.typeText("missing")
        XCTAssertTrue(app.staticTexts["没有匹配的消息"].waitForExistence(timeout: 5)); screenshot(app, "Filtered announcements empty state")
    }
    func test公告加载空内容及错误恢复() {
        for state in ["chat-management-empty", "chat-management-error", "chat-management-loading"] {
            let app = launch(state: state); openChat(app); openAnnouncements(app)
            let text = state == "chat-management-empty" ? "No Announcements" : (state == "chat-management-error" ? "Announcements Couldn’t Be Loaded" : "Loading group announcements…")
            XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 8))
            screenshot(app, "Announcement state \(state)"); app.terminate()
        }
    }
    private func openAnnouncements(_ app: XCUIApplication) {
        let announcements = app.buttons["chat-announcements-list"]
        let menu = app.buttons["chat-more"]
        let menuReady = menu.wait(for: \.isHittable, toEqual: true, timeout: 10)
        if !menuReady { MobileUITestNavigation.capture(app, name: "Announcements menu readiness", test: self) }
        XCTAssertTrue(menuReady, "公告菜单入口尚未可操作")
        guard menuReady else { return }
        menu.tap()

        // iPad 原生菜单曾返回存在且尺寸有效、却无法计算建议点击点的 AX 按钮。
        // 公告只负责页面导航；用实际屏幕内几何位置投递触控，再由真正的公告页严格验证结果。
        func waitForAnnouncementAction() -> XCTWaiter.Result {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard announcements.exists && announcements.isEnabled else { return false }
                let frame = announcements.frame
                let viewport = app.windows.firstMatch.frame
                return frame.origin.x.isFinite && frame.origin.y.isFinite
                    && frame.width.isFinite && frame.height.isFinite
                    && frame.width > 0 && frame.height > 0
                    && viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
            }, object: app)
            return XCTWaiter.wait(for: [ready], timeout: 10)
        }
        var result = waitForAnnouncementAction()
        if result != .completed {
            MobileUITestNavigation.capture(app, name: "Announcements first presentation", test: self)
            // 只在原聊天页仍存在、没有弹层且目标菜单项完全缺失时恢复一次只读展开。
            if app.staticTexts["Sample message 1"].exists && !app.alerts.firstMatch.exists
                && !announcements.exists && menu.exists && menu.isEnabled && menu.isHittable {
                menu.press(forDuration: 0.15)
                result = waitForAnnouncementAction()
            }
        }
        if result != .completed { MobileUITestNavigation.capture(app, name: "Announcements menu presentation", test: self) }
        XCTAssertEqual(result, .completed, "公告菜单项未出现在实际屏幕内")
        guard result == .completed else { return }
        XCTAssertTrue(announcements.isEnabled)
        announcements.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let page = app.navigationBars.matching(NSPredicate(format: "identifier IN %@", ["Group Announcements", "群公告"])).firstMatch
        let appeared = page.waitForExistence(timeout: 8)
        if !appeared { MobileUITestNavigation.capture(app, name: "Announcements presentation", test: self) }
        XCTAssertTrue(appeared, "群公告页面尚未呈现")
    }
    private func openManagement(_ app: XCUIApplication) {
        let management = app.buttons["chat-manage-conversations"]
        guard MobileUITestNavigation.openMenu(app.buttons["chat-more"], showing: management, in: app, test: self) else { return }
        XCTAssertTrue(management.isEnabled); management.tap()
        XCTAssertTrue(app.navigationBars["Manage conversations"].waitForExistence(timeout: 8))
    }
    private func launch(state: String = "chat-management-content", chinese: Bool = false, dark: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if dark { app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch(); return app
    }
    private func openChat(_ app: XCUIApplication, chinese: Bool = false) {
        let folder = app.staticTexts["Sample folder"]
        if !folder.waitForExistence(timeout: 20) {
            MobileUITestNavigation.capture(app, name: "Chat fixture initial files", test: self)
            // 重启后可能停在先前选中的聊天标签；只有文件入口确实可用且未选中时才回到文件页。
            let filesTab = app.tabBars.buttons[chinese ? "文件" : "Files"]
            let filesSidebar = app.buttons["mobile.navigation.files"]
            if (filesTab.exists && filesTab.isEnabled && filesTab.isHittable && !filesTab.isSelected)
                || (filesSidebar.exists && filesSidebar.isEnabled && filesSidebar.isHittable && !filesSidebar.isSelected) {
                navigate("files", title: chinese ? "文件" : "Files", app)
            }
        }
        XCTAssertTrue(folder.waitForExistence(timeout: 5), "启动后仍未出现真实的 Sample folder")
        navigate("settings", title: chinese ? "App 设置" : "App settings", app)
        let toggle = app.switches["mobile.settings.module.chat"]
        for _ in 0..<5 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        MobileUITestNavigation.enableModule(app, module: "chat", test: self)
        navigate("chat", title: chinese ? "聊天" : "Chat", app)
        let chat = app.staticTexts["Sample chat"].firstMatch; XCTAssertTrue(chat.waitForExistence(timeout: 8)); chat.tap()
        XCTAssertTrue(app.staticTexts["Sample message 1"].firstMatch.waitForExistence(timeout: 8))
    }
    private func navigate(_ destination: String, title: String, _ app: XCUIApplication) {
        MobileUITestNavigation.open(app, destination: destination, title: title, test: self)
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let value = XCTAttachment(screenshot: app.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value)
    }
}

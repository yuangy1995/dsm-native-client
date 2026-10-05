import XCTest

@MainActor
final class MobileDownloadRSSUITests: XCTestCase {
    func test订阅条目通过统一表单创建下载并更新订阅() {
        let app = launch(); openRSS(app); openFeed(app)
        let create = element("downloads.rss.create.0", app)
        XCTAssertTrue(create.waitForExistence(timeout: 8)); create.tap()
        let uri = element("downloads.create.uri", app)
        XCTAssertTrue(uri.waitForExistence(timeout: 5)); XCTAssertEqual(uri.value as? String, "https://files.example.invalid/synthetic.torrent")
        XCTAssertTrue(element("downloads.create.destination", app).exists)
        XCTAssertFalse(element("downloads.create.feedback", app).exists)
        element("downloads.create.submit", app).tap()
        let feedback = app.collectionViews["downloads.creation.form"].descendants(matching: .any).matching(identifier: "downloads.create.feedback").firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 8)); XCTAssertTrue(feedback.label.contains("Download added"))
        screenshot("RSS item uses the shared download creation form")
        element("downloads.create.close", app).tap()
        let update = element("downloads.rss.update", app)
        XCTAssertTrue(update.waitForExistence(timeout: 5)); update.tap()
        XCTAssertTrue(app.staticTexts["Subscription updated"].waitForExistence(timeout: 8))
        XCTAssertTrue(update.isEnabled); screenshot("RSS update date read back")
    }

    func test更新已接受但未完成时重启仍禁止重复提交() {
        let app = launch(state: "downloads-rss-accepted"); openRSS(app); openFeed(app)
        let update = element("downloads.rss.update", app); update.tap()
        let receipt = app.staticTexts["Update requested. Reload to see the latest items."]
        XCTAssertTrue(receipt.waitForExistence(timeout: 8)); XCTAssertFalse(update.isEnabled)
        screenshot("RSS acknowledgement is separate from the latest items")
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch()
        openRSS(app); openFeed(app)
        XCTAssertTrue(receipt.waitForExistence(timeout: 8)); XCTAssertFalse(update.isEnabled)
        element("downloads.rss.reload-feeds", app).tap()
        XCTAssertTrue(receipt.exists); XCTAssertFalse(update.isEnabled)
    }

    func test更新中断后重启通过读取原订阅恢复() {
        let app = launch(state: "downloads-rss-unknown"); openRSS(app); openFeed(app)
        element("downloads.rss.update", app).tap()
        XCTAssertTrue(app.staticTexts["The connection was interrupted during the update. Reload to see the latest subscription status."].waitForExistence(timeout: 8))
        XCTAssertFalse(element("downloads.rss.update", app).isEnabled); screenshot("Interrupted RSS update retains its record")
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture")
        app.launchEnvironment["LANSTASH_UI_STATE"] = "downloads-rss-recover"; app.launch()
        openRSS(app); openFeed(app)
        XCTAssertTrue(app.staticTexts["Subscription updated"].waitForExistence(timeout: 8))
        XCTAssertTrue(element("downloads.rss.update", app).isEnabled); screenshot("RSS recovery reads the existing subscription")
    }

    func test中文深色大字筛选条目与取消创建支持横屏() {
        let app = launch(chinese: true); openRSS(app, chinese: true); openFeed(app)
        let search = app.textFields["download.rss.search-feeds"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("missing\n")
        XCTAssertTrue(app.staticTexts["没有匹配内容"].waitForExistence(timeout: 5)); screenshot("Chinese RSS filtered empty state")
        element("download.rss.search-feeds.clear", app).tap()
        let create = element("downloads.rss.create.0", app); scrollTo(create, app)
        XCTAssertTrue(create.waitForExistence(timeout: 5)); create.tap()
        XCTAssertTrue(element("downloads.create.uri", app).waitForExistence(timeout: 5))
        element("downloads.create.close", app).tap()
        XCTAssertFalse(element("downloads.task.sample-created", app).exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        let update = element("downloads.rss.update", app); scrollTo(update, app)
        XCTAssertTrue(update.isHittable); screenshot("Chinese dark large-text RSS landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    func test加载空内容错误和不支持均可关闭或重新读取() {
        for (state, title) in [("downloads-rss-loading", "Loading subscriptions…"),
            ("downloads-rss-empty", "No subscriptions"),
            ("downloads-rss-error", "Unable to load subscriptions or items. Check your connection and reload."),
            ("downloads-rss-unsupported", "Subscriptions are unavailable on this NAS. Manage them in Download Station on DSM.")] {
            let app = launch(state: state); openRSS(app)
            XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 8))
            XCTAssertTrue(element("downloads.rss.close", app).isEnabled)
            XCTAssertFalse(element("downloads.rss.site.7", app).exists)
            screenshot(state); app.terminate()
        }
    }

    func test空条目与更新权限拒绝保留准确状态() {
        for state in ["downloads-rss-empty-feeds", "downloads-rss-denied"] {
            let app = launch(state: state); openRSS(app); openFeed(app)
            if state.hasSuffix("empty-feeds") {
                XCTAssertTrue(app.staticTexts["No items"].waitForExistence(timeout: 8))
                XCTAssertFalse(element("downloads.rss.create.0", app).exists)
            } else {
                element("downloads.rss.update", app).tap()
                XCTAssertTrue(app.staticTexts["This account cannot update the subscription. Contact your NAS administrator."].waitForExistence(timeout: 8))
                XCTAssertFalse(app.staticTexts["Subscription updated"].exists)
            }
            screenshot(state); app.terminate()
        }
    }

    private func launch(state: String = "downloads-rss-content", chinese: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if chinese { app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch(); return app
    }
    private func openRSS(_ app: XCUIApplication, chinese: Bool = false) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", chinese ? "App 设置" : "App settings", app)
        let toggle = element("mobile.settings.module.downloads", app)
        for _ in 0..<10 { if toggle.exists && toggle.isHittable { break }; app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.switches.firstMatch.tap()
        navigate("downloads", chinese ? "下载管理" : "Downloads", app)
        let rss = element("downloads.rss.open", app)
        if rss.exists && rss.isHittable { rss.tap() }
        else {
            let overflow = app.buttons["OverflowBarButtonItem"].firstMatch
            XCTAssertTrue(overflow.waitForExistence(timeout: 8)); overflow.tap()
            let title = app.buttons[chinese ? "RSS 订阅" : "RSS subscriptions"].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap()
        }
    }
    private func openFeed(_ app: XCUIApplication) {
        let site = element("downloads.rss.site.7", app)
        XCTAssertTrue(site.waitForExistence(timeout: 8)); site.tap()
        XCTAssertTrue(element("downloads.rss.update", app).waitForExistence(timeout: 5))
    }
    private func navigate(_ id: String, _ title: String, _ app: XCUIApplication) {
        if app.tabBars.buttons[title].exists { app.tabBars.buttons[title].tap() }
        else { let item = element("mobile.navigation.\(id)", app); XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap() }
    }
    private func scrollTo(_ item: XCUIElement, _ app: XCUIApplication) {
        let list = app.collectionViews["downloads.rss.feeds"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        for _ in 0..<12 {
            let bounds = list.frame.intersection(app.frame)
            let searchBottom = app.textFields["download.rss.search-feeds"].frame.maxY
            let top = max(bounds.minY + 16, searchBottom + 8)
            let viewport = CGRect(x: bounds.minX + 12, y: top, width: bounds.width - 24, height: bounds.maxY - 16 - top)
            if item.exists && item.isHittable && viewport.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) { return }
            // 横屏时列表的辅助范围含固定搜索栏；只在实际内容区域内拖动，避免拉下整个弹窗。
            let down = item.exists && item.frame.midY < viewport.minY
            let startY = viewport.minY + viewport.height * (down ? 0.25 : 0.75)
            let endY = viewport.minY + viewport.height * (down ? 0.75 : 0.25)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: viewport.midX, dy: startY)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: viewport.midX, dy: endY)))
        }
        XCTFail("条目未进入列表可见区域")
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
}

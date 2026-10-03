import XCTest

@MainActor
final class MobileWorkspaceUITests: XCTestCase {
    func test文件下载和设置可通过原生导航到达() {
        let app = launchFixture()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("activity", title: "Activity", in: app)
        let downloads = element("mobile.module.downloads", in: app)
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        downloads.tap()
        XCTAssertTrue(app.staticTexts["Sample archive.zip"].waitForExistence(timeout: 8))
        navigate("more", title: "More", in: app)
        let settings = element("mobile.module.settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(element("mobile.settings.page", in: app).waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Workspace settings")
    }

    func test文件页加载空内容和错误均有实际呈现() {
        for state in ["loading", "empty", "error"] {
            let app = launchFixture(state: state)
            XCTAssertTrue(element("mobile.page.\(state)", in: app).waitForExistence(timeout: 8), state)
            attachScreenshot(app, name: "Files — \(state)")
            app.terminate()
        }
    }

    func test文件搜索无结果保持筛选状态() {
        let app = launchFixture()
        defer { app.terminate() }
        let folder = app.staticTexts["Sample folder"]
        XCTAssertTrue(folder.waitForExistence(timeout: 8))
        folder.tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 8))
        let search = app.searchFields.firstMatch
        if !search.exists {
            // iPad 的原生工具栏先呈现搜索按钮，点击后才创建输入框。
            let reveal = app.buttons.matching(NSPredicate(format: "label == 'Search' OR label == '搜索'")).firstMatch
            XCTAssertTrue(reveal.waitForExistence(timeout: 5))
            reveal.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("missing-fixture\n")
        XCTAssertTrue(element("mobile.page.filteredEmpty", in: app).waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Files — no search results")
    }

    func test目录上传在活动中显示逐项成功且重启保留() {
        let app = launchFixture(state: "upload")
        let start = element("mobile.upload.start", in: app)
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Sample upload/Sample upload.txt"].exists)
        start.tap()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("activity", title: "Activity", in: app)
        let tasks = element("mobile.module.transfers", in: app)
        XCTAssertTrue(tasks.waitForExistence(timeout: 5))
        tasks.tap()
        XCTAssertTrue(app.staticTexts["Sample upload/Sample upload.txt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Clear Finished Uploads"].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Folder upload completed")
        app.terminate()
        app.launchArguments.append("--ui-preserve-transfer-fixture")
        app.launch()
        navigate("activity", title: "Activity", in: app)
        let restoredTasks = element("mobile.module.transfers", in: app)
        XCTAssertTrue(restoredTasks.waitForExistence(timeout: 5))
        restoredTasks.tap()
        XCTAssertTrue(app.staticTexts["Sample upload/Sample upload.txt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Clear Finished Uploads"].exists)
        app.buttons["Clear Finished Uploads"].tap()
        XCTAssertFalse(app.staticTexts["Sample upload/Sample upload.txt"].exists)
        app.terminate()
    }

    private func launchFixture(state: String = "content") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", "en"]
        app.launchEnvironment["LANSTASH_UI_STATE"] = state
        app.launch()
        return app
    }

    private func navigate(_ destination: String, title: String, in app: XCUIApplication) {
        // iPhone 的系统标签栏按本地化标题暴露，iPad 侧栏使用稳定标识。
        let tab = app.tabBars.buttons[title]
        if tab.exists { tab.tap() }
        else {
            let item = element("mobile.navigation.\(destination)", in: app)
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            item.tap()
        }
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}

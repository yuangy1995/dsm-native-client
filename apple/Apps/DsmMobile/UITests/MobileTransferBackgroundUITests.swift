import XCTest

@MainActor
final class MobileTransferBackgroundUITests: XCTestCase {
    func test上传离开前台后返回保留结果且重启不重传() {
        let app = launch(state: "upload")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample upload/Sample upload.txt"].waitForExistence(timeout: 20))
        let start = app.buttons["mobile.upload.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 8)); XCTAssertTrue(start.isEnabled); start.tap()
        leaveAndReturn(app)
        openActivity(app, chinese: false)
        XCTAssertTrue(app.buttons["Clear Finished Uploads"].waitForExistence(timeout: 20))
        capture(app, "Background upload completed")
        app.terminate()
        app.launchArguments.append("--ui-preserve-transfer-fixture")
        app.launch()
        openActivity(app, chinese: false)
        XCTAssertTrue(app.buttons["Clear Finished Uploads"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Pause"].exists)
        app.buttons["Clear Finished Uploads"].tap()
        XCTAssertFalse(app.staticTexts["Sample upload/Sample upload.txt"].exists)
    }

    func test下载离开前台后返回可以打开系统分享() {
        let app = launch(state: "download-archive")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 10))
        app.staticTexts["Sample folder"].tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 8))
        let actions = app.buttons["files.toolbar.more"]
        if actions.exists && actions.isHittable { actions.tap() }
        else {
            app.buttons["OverflowBarButtonItem"].firstMatch.tap()
            let more = app.buttons.matching(NSPredicate(format: "label IN %@", ["More", "更多"])).firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        }
        app.buttons["Select Items"].tap()
        app.staticTexts["Sample document.txt"].tap()
        app.buttons["files.batch.more"].tap()
        app.buttons["files.batch.share"].tap()
        leaveAndReturn(app)
        let title = app.descendants(matching: .any)["LP.CaptionBar.TopCaption"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertTrue(title.label.contains("Sample document"))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        capture(app, "Background download system share")
        app.buttons["header.closeButton"].tap()
    }

    func test中文深色大字上传切回前台仍可读取完成状态() {
        let app = launch(state: "upload", chinese: true)
        defer { app.terminate() }
        let start = app.buttons["mobile.upload.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)], timeout: 20), .completed)
        let source = app.staticTexts["Sample upload/Sample upload.txt"]
        for _ in 0..<6 where !source.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(source.exists)
        start.tap()
        leaveAndReturn(app)
        openActivity(app, chinese: true)
        let clear = app.buttons["清除已结束的上传"]
        for _ in 0..<5 where !clear.isHittable { app.swipeUp() }
        XCTAssertTrue(clear.waitForExistence(timeout: 20))
        XCTAssertTrue(clear.isHittable)
        capture(app, "Background upload Chinese dark large")
    }

    private func launch(state: String, chinese: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--ui-transfer-background", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if chinese {
            app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state
        app.launch()
        return app
    }

    private func leaveAndReturn(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        // 覆盖真实系统前后台生命周期；持续任务是否获准仍由当前系统决定。
        let deadline = Date().addingTimeInterval(13)
        let elapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date() >= deadline }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [elapsed], timeout: 16), .completed)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
    }

    private func openActivity(_ app: XCUIApplication, chinese: Bool) {
        MobileUITestNavigation.open(app, destination: "files", title: chinese ? "文件" : "File", test: self)
        let tasks = app.buttons["mobile.module.transfers"]
        XCTAssertTrue(tasks.waitForExistence(timeout: 8)); tasks.tap()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

import XCTest

@MainActor
final class MobileShareExtensionUITests: XCTestCase {
    func test系统分享扩展选择目录上传完成并在主应用保留结果() {
        let app = launch(mode: "success")
        defer { app.terminate() }
        openExtension(app)
        let upload = app.buttons["mobile.share.upload"]
        XCTAssertFalse(upload.isEnabled, app.debugDescription)
        element("mobile.share.folder./Shared", app).tap()
        XCTAssertTrue(upload.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: upload)], timeout: 5), .completed)
        screenshot(app, "share-select-destination")
        upload.tap()
        XCTAssertTrue(element("mobile.share.completed", app).waitForExistence(timeout: 15))
        screenshot(app, "share-upload-completed")
        element("mobile.share.close", app).tap()
        openRecovery(app)
        XCTAssertTrue(app.buttons["Clear Finished Uploads"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sample.txt"].exists)
        screenshot(app, "share-completed-main-activity")
        app.buttons["Clear Finished Uploads"].tap()
        XCTAssertFalse(app.staticTexts["Sample.txt"].exists)
    }

    func test关闭分享上传后主应用重启保持暂停且可以明确继续() {
        let app = launch(mode: "slow")
        defer { app.terminate() }
        openExtension(app)
        element("mobile.share.folder./Shared", app).tap()
        let upload = app.buttons["mobile.share.upload"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: upload)], timeout: 5), .completed)
        upload.tap()
        XCTAssertTrue(element("mobile.share.results", app).waitForExistence(timeout: 8))
        element("mobile.share.close", app).tap()
        XCTAssertTrue(element("mobile.share.test-activity", app).waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments.append("--ui-preserve-share")
        app.launch()
        openRecovery(app)
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Paused"].exists)
        screenshot(app, "share-interrupted-restored-paused")
        app.buttons["Resume"].tap()
        XCTAssertTrue(app.buttons["Clear Finished Uploads"].waitForExistence(timeout: 35))
        screenshot(app, "share-resumed-completed")
    }

    func test分享上传丢回执在主应用刷新恢复完成() {
        let app = launch(mode: "unknown")
        defer { app.terminate() }
        openExtension(app)
        element("mobile.share.folder./Shared", app).tap()
        let upload = app.buttons["mobile.share.upload"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: upload)], timeout: 5), .completed)
        upload.tap()
        XCTAssertTrue(app.buttons["Refresh Status"].waitForExistence(timeout: 12))
        screenshot(app, "share-response-lost")
        element("mobile.share.close", app).tap()
        openRecovery(app)
        XCTAssertTrue(app.buttons["Refresh Status"].waitForExistence(timeout: 10))
        app.buttons["Refresh Status"].tap()
        XCTAssertTrue(app.buttons["Clear Finished Uploads"].waitForExistence(timeout: 12))
        screenshot(app, "share-response-readback-completed")
    }

    func test中文深色大字分享扩展可浏览上传和关闭() {
        let app = launch(mode: "success", chinese: true)
        defer { app.terminate() }
        openExtension(app)
        let folder = element("mobile.share.folder./Shared", app)
        XCTAssertTrue(folder.waitForExistence(timeout: 8)); folder.tap()
        let upload = app.buttons["mobile.share.upload"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: upload)], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["/Shared"].exists)
        screenshot(app, "share-chinese-dark-large-destination")
        let file = app.staticTexts["Sample.txt"]
        let selection = element("mobile.share.selection", app)
        // 跨进程 SwiftUI 的 isHittable 可能把视口外元素视为可点，实际滚动并检查屏幕坐标。
        selection.swipeUp()
        for _ in 0..<3 where file.frame.maxY > app.frame.maxY - 40 { selection.swipeUp() }
        XCTAssertTrue(file.isHittable)
        XCTAssertGreaterThan(file.frame.height, 0)
        XCTAssertLessThan(file.frame.maxY, app.frame.maxY - 40)
        screenshot(app, "share-chinese-dark-large-file")
        upload.tap()
        XCTAssertTrue(element("mobile.share.completed", app).waitForExistence(timeout: 15))
        screenshot(app, "share-chinese-dark-large-completed")
        element("mobile.share.close", app).tap()
        XCTAssertTrue(element("mobile.share.test-activity", app).waitForExistence(timeout: 10))
    }

    private func launch(mode: String, chinese: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-share-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if chinese { app.launchArguments += ["--ui-dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LANSTASH_SHARE_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["LANSTASH_SHARE_MODE"] = mode
        app.launch()
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchArguments = ["--ui-share-fixture", "--ui-preserve-share", "--ui-clean-share"]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mobile.share.test-cleaned").firstMatch.waitForExistence(timeout: 10))
            app.terminate()
        }
        return app
    }

    private func openExtension(_ app: XCUIApplication) {
        let start = element("mobile.share.test-open", app)
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)], timeout: 10), .completed)
        start.tap()
        let activity = app.cells.matching(NSPredicate(format: "label IN %@", ["LanStash", "岚仓"])).firstMatch
        if !activity.waitForExistence(timeout: 5) {
            let more = app.cells.matching(NSPredicate(format: "label IN %@", ["More", "更多"])).firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        }
        XCTAssertTrue(activity.waitForExistence(timeout: 8)); activity.tap()
        XCTAssertTrue(element("mobile.share.selection", app).waitForExistence(timeout: 15))
        XCTAssertTrue(element("mobile.share.folder./Shared", app).waitForExistence(timeout: 10))
    }

    private func openRecovery(_ app: XCUIApplication) {
        let activity = element("mobile.share.test-activity", app)
        XCTAssertTrue(activity.waitForExistence(timeout: 10)); activity.tap()
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

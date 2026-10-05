import XCTest
import UIKit

@MainActor
final class MobileDownloadControlUITests: XCTestCase {
    func test多选暂停与继续分别处理符合状态的任务() {
        let app = launch(); enableDownloads(app)
        selectAll(app)
        let pause = element("downloads.batch.pause", app), resume = element("downloads.batch.resume", app)
        XCTAssertTrue(pause.label.contains("2")); XCTAssertTrue(resume.label.contains("1"))
        pause.tap()
        XCTAssertTrue(element("downloads.result.sample-1.complete", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("downloads.result.sample-4.complete", app).waitForExistence(timeout: 8))
        XCTAssertFalse(element("downloads.result.sample-2.complete", app).exists)
        screenshot("Batch pause completes both active tasks")
        app.navigationBars["Recent actions"].buttons.firstMatch.tap()
        XCTAssertTrue(element("downloads.selection.close", app).waitForExistence(timeout: 5))
        element("downloads.selection.close", app).tap()
        selectAll(app)
        let resumeAll = element("downloads.batch.resume", app)
        XCTAssertTrue(resumeAll.label.contains("3")); resumeAll.tap()
        XCTAssertTrue(element("downloads.result.sample-1.complete", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("downloads.result.sample-2.complete", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("downloads.result.sample-4.complete", app).waitForExistence(timeout: 8))
        screenshot("Batch resume completes all selected paused tasks")
    }

    func test未知结果重启后只读取当前项剩余项目由继续按钮执行() {
        let app = launch(state: "downloads-controls-unknown"); enableDownloads(app)
        selectAll(app); element("downloads.batch.pause", app).tap()
        XCTAssertTrue(element("downloads.result.sample-1.submitted", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("downloads.result.sample-4.planned", app).exists)
        XCTAssertTrue(element("downloads.batch.refresh", app).waitForExistence(timeout: 5))
        screenshot("Interrupted batch retains current and unstarted tasks")
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture")
        app.launchEnvironment["LANSTASH_UI_STATE"] = "downloads-controls-recover"; app.launch(); enableDownloads(app)
        openRecord(app)
        XCTAssertTrue(element("downloads.result.sample-1.complete", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("downloads.result.sample-4.planned", app).exists)
        let proceed = element("downloads.batch.continue", app)
        scrollTo(proceed, app); XCTAssertTrue(proceed.exists); proceed.tap()
        XCTAssertTrue(element("downloads.result.sample-4.complete", app).waitForExistence(timeout: 8))
        screenshot("Explicit continue finishes remaining task after relaunch")
    }

    func test中文深色大字多选与结果支持横屏() {
        let app = launch(chinese: true); enableDownloads(app, chinese: true)
        selectAll(app)
        screenshot("Chinese large-text task selection")
        element("downloads.batch.pause", app).tap()
        let result = element("downloads.result.sample-4.complete", app)
        scrollTo(result, app); XCTAssertTrue(result.waitForExistence(timeout: 8))
        XCTAssertTrue(result.label.contains("任务已暂停"))
        screenshot("Chinese dark batch results")
        XCUIDevice.shared.orientation = .landscapeLeft
        scrollTo(result, app); XCTAssertTrue(result.exists)
        screenshot("Landscape batch results")
        XCUIDevice.shared.orientation = .portrait
    }

    func test取消剩余项目后空任务列表仍可查看与清除已结束记录() {
        let app = launch(state: "downloads-controls-unknown"); enableDownloads(app)
        selectAll(app); element("downloads.batch.pause", app).tap()
        XCTAssertTrue(element("downloads.result.sample-1.submitted", app).waitForExistence(timeout: 8))
        let cancel = element("downloads.batch.cancel", app)
        scrollTo(cancel, app); cancel.tap()
        XCTAssertTrue(element("downloads.result.sample-4.cancelled", app).waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture")
        app.launchEnvironment["LANSTASH_UI_STATE"] = "downloads-controls-empty"; app.launch(); enableDownloads(app)
        XCTAssertTrue(element("mobile.page.empty", app).waitForExistence(timeout: 8))
        openRecord(app)
        XCTAssertTrue(element("downloads.result.sample-1.failed", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("downloads.result.sample-4.cancelled", app).exists)
        screenshot("Records remain accessible after tasks disappear")
        let remove = element("downloads.batch.remove-record", app)
        scrollTo(remove, app); remove.tap()
        XCTAssertTrue(app.staticTexts["No recent actions"].firstMatch.waitForExistence(timeout: 5))
    }

    func test单任务结果暂不可用时可直接进入操作记录() {
        let app = launch(state: "downloads-controls-unknown"); enableDownloads(app)
        let task = app.staticTexts["Sample archive.zip"].firstMatch
        scrollTo(task, app); task.tap()
        let pause = element("downloads.details.pause", app)
        scrollTo(pause, app); XCTAssertTrue(pause.waitForExistence(timeout: 5)); pause.tap()
        let records = element("downloads.details.records", app)
        scrollTo(records, app); XCTAssertTrue(records.waitForExistence(timeout: 8)); records.tap()
        let record = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "downloads.record.")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 8)); record.tap()
        XCTAssertTrue(element("downloads.result.sample-1.submitted", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("downloads.batch.refresh", app).exists)
        screenshot("Single task opens its recovery record")
    }

    private func launch(state: String = "downloads-controls-content", chinese: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if chinese { app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch(); return app
    }
    private func enableDownloads(_ app: XCUIApplication, chinese: Bool = false) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", chinese ? "App 设置" : "App settings", app)
        let toggle = element("mobile.settings.module.downloads", app)
        scrollTo(toggle, app); XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.switches.firstMatch.tap()
        navigate("downloads", chinese ? "下载管理" : "Downloads", app)
    }
    private func navigate(_ id: String, _ title: String, _ app: XCUIApplication) {
        let tab = app.tabBars.buttons[title], sidebar = element("mobile.navigation.\(id)", app)
        // 启用模块后的标签栏/侧栏都以实际可点击状态作为继续条件。
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (tab.exists && tab.isHittable) || (sidebar.exists && sidebar.isHittable)
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        if tab.exists && tab.isHittable { tab.tap() }
        else { XCTAssertTrue(sidebar.exists); XCTAssertTrue(sidebar.isHittable); sidebar.tap() }
    }
    private func selectAll(_ app: XCUIApplication) {
        let select = element("downloads.select", app)
        XCTAssertTrue(select.waitForExistence(timeout: 8)); XCTAssertTrue(select.isEnabled); select.tap()
        let all = element("downloads.select-all", app)
        XCTAssertTrue(all.waitForExistence(timeout: 5)); all.tap()
    }
    private func openRecord(_ app: XCUIApplication) {
        let records = element("downloads.records", app)
        XCTAssertTrue(records.waitForExistence(timeout: 8)); records.tap()
        let record = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "downloads.record.")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 8)); record.tap()
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func scrollTo(_ item: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<18 {
            let results = app.collectionViews["downloads.batch.results"]
            let details = app.collectionViews["downloads.details.form"]
            let root = app.collectionViews["mobile.page.content"].firstMatch
            let list = results.exists ? results : (details.exists ? details : (root.exists ? root : app.collectionViews.firstMatch))
            guard list.exists else { XCTFail("找不到当前列表"); return }
            let frame = list.frame.intersection(app.frame)
            let navBottom = app.navigationBars.allElementsBoundByIndex.map(\.frame).filter { $0.intersects(frame) }.map(\.maxY).max() ?? frame.minY
            let top = max(frame.minY, navBottom) + 10
            let bottom = !results.exists && !details.exists && app.tabBars.firstMatch.exists ? min(frame.maxY, app.tabBars.firstMatch.frame.minY) - 12 : frame.maxY - 24
            let viewport = CGRect(x: frame.minX + 12, y: top, width: frame.width - 24, height: bottom - top)
            if item.exists, viewport.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) { return }
            let reverse = item.exists && item.frame.midY < viewport.minY
            let x = viewport.midX + viewport.width * 0.15, low = viewport.minY + viewport.height * 0.75, high = viewport.minY + viewport.height * 0.25
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: reverse ? high : low))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: reverse ? low : high)))
        }
        XCTFail("目标未进入当前列表可见区域")
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
}

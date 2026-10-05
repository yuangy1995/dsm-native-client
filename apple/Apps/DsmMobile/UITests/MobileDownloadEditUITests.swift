import XCTest
import UIKit

@MainActor
final class MobileDownloadEditUITests: XCTestCase {
    func test单任务选择文件夹保存后详情显示新位置() {
        let app = launch(); enableDownloads(app)
        button("downloads.task.sample-1", app).tap()
        let edit = button("downloads.details.edit", app); XCTAssertTrue(edit.waitForExistence(timeout: 8)); edit.tap()
        chooseFolder(app); button("downloads.edit.save", app).tap()
        let result = element("downloads.edit-result.sample-1.complete", app)
        XCTAssertTrue(result.waitForExistence(timeout: 8)); XCTAssertTrue(result.label.contains("Saved")); XCTAssertTrue(result.label.contains("fixture"))
        screenshot("Single task save location completed")
        button("downloads.edit.close", app).tap()
        let savedLocation = element("downloads.details.destination", app)
        scrollTo(savedLocation, app)
        XCTAssertTrue(savedLocation.waitForExistence(timeout: 8)); XCTAssertTrue(savedLocation.label.hasSuffix("fixture"), savedLocation.label)
    }
    func test多选逐项保存清楚显示部分拒绝() {
        let app = launch(state: "downloads-edit-partial"); enableDownloads(app); openBatch(app); chooseFolder(app)
        button("downloads.edit.save", app).tap()
        XCTAssertTrue(element("downloads.edit-result.sample-1.complete", app).waitForExistence(timeout: 8))
        let rejected = element("downloads.edit-result.sample-2.failed", app)
        XCTAssertTrue(rejected.waitForExistence(timeout: 8)); XCTAssertTrue(rejected.label.contains("This account cannot"))
        XCTAssertTrue(element("downloads.edit-result.sample-3.complete", app).waitForExistence(timeout: 8))
        screenshot("Batch save locations with one permission denial")
    }
    func test未知编辑重启只读完成当前项再显式继续余项() {
        let app = launch(state: "downloads-edit-unknown"); enableDownloads(app); openBatch(app); chooseFolder(app)
        button("downloads.edit.save", app).tap()
        XCTAssertTrue(element("downloads.edit-result.sample-3.submitted", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("downloads.edit-result.sample-2.planned", app).exists)
        screenshot("Unknown edit keeps unstarted tasks")
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture")
        app.launchEnvironment["LANSTASH_UI_STATE"] = "downloads-edit-recover"; app.launch(); enableDownloads(app); openRecord(app)
        XCTAssertTrue(element("downloads.edit-result.sample-3.complete", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("downloads.edit-result.sample-2.planned", app).exists)
        let proceed = button("downloads.edit.continue", app); scrollTo(proceed, app); proceed.tap()
        XCTAssertTrue(element("downloads.edit-result.sample-2.complete", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("downloads.edit-result.sample-1.complete", app).waitForExistence(timeout: 8))
        screenshot("Explicit continue completes the remaining location edits")
    }
    func test取消余项后重启不重新开始并可移除结束记录() {
        let app = launch(state: "downloads-edit-unknown"); enableDownloads(app); openBatch(app); chooseFolder(app)
        button("downloads.edit.save", app).tap()
        XCTAssertTrue(element("downloads.edit-result.sample-3.submitted", app).waitForExistence(timeout: 8))
        let cancel = button("downloads.edit.cancel", app); scrollTo(cancel, app); cancel.tap()
        XCTAssertTrue(element("downloads.edit-result.sample-2.cancelled", app).waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture")
        app.launchEnvironment["LANSTASH_UI_STATE"] = "downloads-edit-recover"; app.launch(); enableDownloads(app); openRecord(app)
        XCTAssertTrue(element("downloads.edit-result.sample-3.complete", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("downloads.edit-result.sample-2.cancelled", app).exists)
        XCTAssertFalse(element("downloads.edit.continue", app).exists)
        screenshot("Cancelled location edits remain cancelled after relaunch")
        let remove = button("downloads.edit.remove-record", app); scrollTo(remove, app); remove.tap()
        XCTAssertTrue(app.staticTexts["No recent actions"].firstMatch.waitForExistence(timeout: 8))
    }
    func test中文深色大字选择和结果支持横屏() {
        let app = launch(chinese: true); enableDownloads(app, chinese: true); openBatch(app); chooseFolder(app, chinese: true)
        screenshot("Chinese dark large-text save location form")
        button("downloads.edit.save", app).tap()
        let last = element("downloads.edit-result.sample-1.complete", app)
        scrollTo(last, app); XCTAssertTrue(last.waitForExistence(timeout: 8)); XCTAssertTrue(last.label.contains("已保存"))
        screenshot("Chinese save location results")
        XCUIDevice.shared.orientation = .landscapeLeft
        scrollTo(last, app); XCTAssertTrue(last.isHittable); XCTAssertTrue(last.label.contains("已保存"))
        screenshot("Chinese landscape location results"); XCUIDevice.shared.orientation = .portrait
    }
    func test不支持编辑时无入口且空操作记录有恢复路径() {
        let app = launch(state: "downloads-edit-unsupported"); enableDownloads(app)
        button("downloads.task.sample-1", app).tap()
        XCTAssertTrue(button("downloads.details.pause", app).waitForExistence(timeout: 8))
        XCTAssertFalse(element("downloads.details.edit", app).exists)
        button("downloads.details.close", app).tap(); toolbar("downloads.records", labels: ["Recent actions", "最近操作"], app)
        XCTAssertTrue(app.staticTexts["No recent actions"].firstMatch.waitForExistence(timeout: 8))
        screenshot("Unsupported editing preserves controls and empty action history")
    }
    private func chooseFolder(_ app: XCUIApplication, chinese: Bool = false) {
        let destination = button("downloads.edit.destination", app)
        XCTAssertTrue(destination.waitForExistence(timeout: 8)); destination.tap()
        let folder = element("files.folder-picker.folder./fixture", app)
        XCTAssertTrue(folder.waitForExistence(timeout: 8)); folder.tap()
        let choose = app.buttons[chinese ? "选择" : "Choose"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 8)); choose.tap()
        XCTAssertTrue(element("downloads.edit.destination", app).label.contains("fixture"))
        XCTAssertTrue(button("downloads.edit.save", app).isEnabled)
    }
    private func openBatch(_ app: XCUIApplication) {
        toolbar("downloads.select", labels: ["Select tasks", "选择任务"], app)
        let all = button("downloads.select-all", app); XCTAssertTrue(all.waitForExistence(timeout: 8)); all.tap()
        button("downloads.batch.edit", app).tap()
    }
    private func openRecord(_ app: XCUIApplication) {
        toolbar("downloads.records", labels: ["Recent actions", "最近操作"], app)
        let record = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "downloads.edit-record.")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 8)); record.tap()
    }
    private func toolbar(_ id: String, labels: [String], _ app: XCUIApplication) {
        let direct = element(id, app)
        if direct.exists && direct.isHittable { direct.tap(); return }
        let more = app.buttons["OverflowBarButtonItem"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 8)); more.tap()
        let item = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 8)); item.tap()
    }
    private func button(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let anchor = element(id, app)
        _ = anchor.waitForExistence(timeout: 8)
        let direct = app.buttons.matching(identifier: id).firstMatch
        if direct.exists { return direct }
        let nested = anchor.buttons.firstMatch
        return nested.exists ? nested : anchor
    }
    private func launch(state: String = "downloads-edit-content", chinese: Bool = false) -> XCUIApplication {
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
        // 模块启用会重建原生导航，等待实际目标入口完成呈现并可点击。
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (tab.exists && tab.isHittable) || (sidebar.exists && sidebar.isHittable)
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        if tab.exists && tab.isHittable { tab.tap() }
        else { XCTAssertTrue(sidebar.exists); XCTAssertTrue(sidebar.isHittable); sidebar.tap() }
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func scrollTo(_ item: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<18 {
            let results = app.collectionViews["downloads.edit.results"]
            let editForm = app.collectionViews["downloads.edit.form"]
            let details = app.collectionViews["downloads.details.form"]
            let root = app.collectionViews["mobile.page.content"].firstMatch
            let list = results.exists ? results : (editForm.exists ? editForm : (details.exists ? details : (root.exists ? root : app.collectionViews.firstMatch)))
            guard list.exists else { XCTFail("找不到当前列表"); return }
            let frame = list.frame.intersection(app.frame)
            let settingsBar = app.navigationBars.matching(NSPredicate(format: "identifier IN %@ OR label IN %@",
                ["Change save location", "更改保存位置"], ["Change save location", "更改保存位置"])).firstMatch
            let navBottom = results.exists && settingsBar.exists ? settingsBar.frame.maxY
                : app.navigationBars.allElementsBoundByIndex.map(\.frame).filter { $0.intersects(frame) }.map(\.maxY).max() ?? frame.minY
            let top = max(frame.minY, navBottom) + 10
            let bottom = !results.exists && !editForm.exists && !details.exists && app.tabBars.firstMatch.exists ? min(frame.maxY, app.tabBars.firstMatch.frame.minY) - 12 : frame.maxY - 24
            let viewport = CGRect(x: frame.minX + 12, y: top, width: frame.width - 24, height: bottom - top)
            if item.exists, viewport.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) { return }
            let reverse = item.exists && item.frame.midY < viewport.minY
            // 横屏可用高度较短；按离目标的距离移动并停稳，避免快速滑动反复越过目标。
            let distance = item.exists ? min(viewport.height * 0.5, max(20, abs(item.frame.midY - viewport.midY) * 0.5)) : viewport.height * 0.5
            let x = viewport.midX + viewport.width * 0.15, low = viewport.midY + distance / 2, high = viewport.midY - distance / 2
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: reverse ? high : low))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: reverse ? low : high)),
                       withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        let bars = app.navigationBars.allElementsBoundByIndex.map(\.frame)
        XCTFail("目标未进入当前列表可见区域：目标 \(item.frame)，导航栏 \(bars)，窗口 \(app.frame)")
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
}

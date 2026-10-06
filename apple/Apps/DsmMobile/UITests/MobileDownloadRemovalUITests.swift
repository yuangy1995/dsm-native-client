import XCTest
import UIKit

@MainActor
final class MobileDownloadRemovalUITests: XCTestCase {
    func test单项确认取消保持任务随后移除只显示任务结果() {
        let app = launch(); enableDownloads(app)
        button("downloads.task.sample-1", app).tap()
        let remove = button("downloads.details.remove", app); scrollTo(remove, app); remove.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Completed files will not be deleted")).firstMatch.waitForExistence(timeout: 8))
        screenshot("Task removal confirmation describes unfinished progress and completed files")
        button("downloads.removal.close", app).tap()
        XCTAssertTrue(button("downloads.details.remove", app).waitForExistence(timeout: 8))
        button("downloads.details.remove", app).tap(); confirm(app)
        let result = element("downloads.removal-result.sample-1.complete", app)
        scrollTo(result, app); XCTAssertTrue(result.waitForExistence(timeout: 8)); XCTAssertTrue(result.label.contains("Task removed")); XCTAssertTrue(result.label.contains("Sample archive.zip"))
        screenshot("Single removed task with no claim of file deletion")
        button("downloads.removal.close", app).tap()
        XCTAssertFalse(element("downloads.details.pause", app).exists)
        XCTAssertFalse(element("downloads.details.remove", app).exists)
        let status = element("downloads.details.status", app); scrollTo(status, app)
        XCTAssertTrue(status.waitForExistence(timeout: 8)); XCTAssertTrue(status.label.contains("Task removed"))
        screenshot("Removed task details show the final status and no remaining controls")
        button("downloads.details.close", app).tap()
        XCTAssertFalse(element("downloads.task.sample-1", app).exists)
    }
    func test结束并移出未完成文件具有独立后果确认和结果说明() {
        let app = launch(); enableDownloads(app); button("downloads.task.sample-1", app).tap()
        let force = button("downloads.details.force-remove", app); scrollTo(force, app); force.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "These files may be incomplete")).firstMatch.waitForExistence(timeout: 8))
        screenshot("Force complete explicitly moves unfinished files without deleting them")
        confirm(app)
        let result = element("downloads.removal-result.sample-1.complete", app)
        scrollTo(result, app); XCTAssertTrue(result.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Unfinished files may not open correctly")).firstMatch.exists)
        screenshot("Task removal and actual file placement remain distinct")
    }
    func test批量移除保留逐项权限拒绝和成功结果() {
        let app = launch(state: "downloads-removal-partial"); enableDownloads(app); openBatch(app); confirm(app)
        XCTAssertTrue(element("downloads.removal-result.sample-3.complete", app).waitForExistence(timeout: 8))
        let rejected = element("downloads.removal-result.sample-2.failed", app)
        scrollTo(rejected, app); XCTAssertTrue(rejected.waitForExistence(timeout: 8)); XCTAssertTrue(rejected.label.contains("You cannot remove"))
        let last = element("downloads.removal-result.sample-1.complete", app); scrollTo(last, app); XCTAssertTrue(last.waitForExistence(timeout: 8))
        screenshot("Batch task removal preserves the permission denial")
    }
    func test未知中断重启只读恢复并保持用户取消剩余项() {
        let app = launch(state: "downloads-removal-unknown"); enableDownloads(app); openBatch(app); confirm(app)
        XCTAssertTrue(element("downloads.removal-result.sample-3.submitted", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("downloads.removal-result.sample-2.planned", app).exists)
        let cancel = button("downloads.removal.cancel", app); scrollTo(cancel, app); cancel.tap()
        XCTAssertTrue(element("downloads.removal-result.sample-2.cancelled", app).waitForExistence(timeout: 8))
        screenshot("Unknown removal prevents replay and cancels the remaining tasks")
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture")
        app.launchEnvironment["LANSTASH_UI_STATE"] = "downloads-removal-recover"; app.launch(); enableDownloads(app); openRecord(app)
        XCTAssertTrue(element("downloads.removal-result.sample-3.complete", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("downloads.removal-result.sample-2.cancelled", app).exists)
        XCTAssertFalse(element("downloads.removal.continue", app).exists)
        screenshot("Read-only recovery preserves cancelled tasks after relaunch")
        let remove = button("downloads.removal.remove-record", app); scrollTo(remove, app); remove.tap()
        XCTAssertTrue(app.staticTexts["No recent actions"].firstMatch.waitForExistence(timeout: 8))
    }
    func test停止做种使用暂停后可继续并进入现有文件管理() {
        let app = launch(state: "downloads-removal-seeding"); enableDownloads(app)
        let task = button("downloads.task.sample-4", app); scrollTo(task, app); task.tap()
        let pause = button("downloads.details.pause", app); XCTAssertTrue(pause.waitForExistence(timeout: 8))
        XCTAssertTrue(pause.label.contains("Stop Seeding")); pause.tap()
        let resume = button("downloads.details.resume", app); XCTAssertTrue(resume.waitForExistence(timeout: 8))
        screenshot("Stopping seeding pauses the task and keeps Resume available")
        let files = button("downloads.details.open-files", app); scrollTo(files, app); files.tap()
        XCTAssertTrue(app.staticTexts["Sample folder"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(element("downloads.details.form", app).exists)
        screenshot("Files opens for explicit selection without guessing task ownership")
    }
    func test中文深色最大字号确认与结果支持横屏() {
        let app = launch(chinese: true); enableDownloads(app, chinese: true)
        let task = button("downloads.task.sample-1", app); scrollTo(task, app); task.tap()
        let remove = button("downloads.details.remove", app); scrollTo(remove, app); remove.tap()
        let warning = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "所选任务将从下载中心")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 8))
        screenshot("Chinese dark large-text removal consequences")
        confirm(app)
        let result = element("downloads.removal-result.sample-1.complete", app)
        scrollTo(result, app); XCTAssertTrue(result.waitForExistence(timeout: 8)); XCTAssertTrue(result.label.contains("任务已移除"))
        XCUIDevice.shared.orientation = .landscapeLeft
        scrollTo(result, app); XCTAssertTrue(result.isHittable)
        screenshot("Chinese landscape task removal result"); XCUIDevice.shared.orientation = .portrait
    }
    private func confirm(_ app: XCUIApplication) {
        let submit = button("downloads.removal.confirm", app); scrollTo(submit, app)
        XCTAssertTrue(submit.isEnabled); submit.tap()
    }
    private func openBatch(_ app: XCUIApplication) {
        toolbar("downloads.select", labels: ["Select tasks", "选择任务"], app)
        let all = button("downloads.select-all", app); XCTAssertTrue(all.waitForExistence(timeout: 8)); all.tap()
        button("downloads.batch.removal-menu", app).tap()
        let remove = app.buttons["Remove Task"].firstMatch; XCTAssertTrue(remove.waitForExistence(timeout: 8)); remove.tap()
    }
    private func openRecord(_ app: XCUIApplication) {
        toolbar("downloads.records", labels: ["Recent actions", "最近操作"], app)
        let record = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "downloads.removal-record.")).firstMatch
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
    private func launch(state: String = "downloads-removal-content", chinese: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if chinese { app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch(); return app
    }
    private func enableDownloads(_ app: XCUIApplication, chinese: Bool = false) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", chinese ? "App 设置" : "App settings", app)
        MobileUITestNavigation.enableModule(app, module: "downloads", test: self)
        navigate("downloads", chinese ? "下载管理" : "Downloads", app)
    }
    private func navigate(_ id: String, _ title: String, _ app: XCUIApplication) {
        MobileUITestNavigation.open(app, destination: id, title: title, test: self)
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func scrollTo(_ item: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<18 {
            let results = app.collectionViews["downloads.removal.results"]
            let editForm = app.collectionViews["downloads.removal.confirmation"]
            let details = app.collectionViews["downloads.details.form"]
            let root = app.collectionViews["mobile.page.content"].firstMatch
            let list = results.exists ? results : (editForm.exists ? editForm : (details.exists ? details : (root.exists ? root : app.collectionViews.firstMatch)))
            guard list.exists else { XCTFail("找不到当前列表"); return }
            let frame = list.frame.intersection(app.frame)
            let settingsBar = app.navigationBars.matching(NSPredicate(format: "identifier IN %@ OR label IN %@",
                ["Remove Tasks", "移除任务", "End and Move Unfinished Files", "结束并移出未完成文件"], ["Remove Tasks", "移除任务", "End and Move Unfinished Files", "结束并移出未完成文件"])).firstMatch
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

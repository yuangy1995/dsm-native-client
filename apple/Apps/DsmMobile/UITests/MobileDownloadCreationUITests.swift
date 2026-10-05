import XCTest
import UIKit

@MainActor
final class MobileDownloadCreationUITests: XCTestCase {
    private let uri = "https://files.example.invalid/synthetic.torrent"
    func test官方空回执添加链接后列表和重启记录可见并可移除结束记录() {
        let app = launch(); enableDownloads(app); addLink(app)
        let result = feedback(app)
        XCTAssertTrue(result.waitForExistence(timeout: 10)); XCTAssertTrue(result.label.contains("Download added"))
        screenshot("Link creation accepts the official empty response")
        button("downloads.create.close", app).tap()
        XCTAssertTrue(element("downloads.task.sample-created", app).waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture")
        app.launchEnvironment["LANSTASH_UI_STATE"] = "downloads-create-saved"; app.launch(); enableDownloads(app); openRecord(app)
        XCTAssertTrue(element("downloads.creation.status.accepted", app).waitForExistence(timeout: 8))
        screenshot("Accepted creation remains after relaunch")
        button("downloads.creation.remove", app).tap()
        XCTAssertTrue(app.staticTexts["No recent actions"].firstMatch.waitForExistence(timeout: 8))
    }
    func test回执丢失重启后只读且列表有新任务也不认领或重发() {
        let app = launch(state: "downloads-create-unknown"); enableDownloads(app); addLink(app)
        XCTAssertTrue(feedback(app).waitForExistence(timeout: 10))
        XCTAssertTrue(feedback(app).label.contains("Download status unavailable"))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture")
        app.launchEnvironment["LANSTASH_UI_STATE"] = "downloads-create-recover"; app.launch(); enableDownloads(app)
        XCTAssertTrue(element("downloads.task.sample-created", app).waitForExistence(timeout: 8))
        openRecord(app); XCTAssertTrue(element("downloads.creation.status.submitted", app).waitForExistence(timeout: 8))
        button("downloads.creation.refresh", app).tap()
        XCTAssertTrue(element("downloads.creation.status.submitted", app).exists)
        XCTAssertFalse(element("downloads.creation.remove", app).exists)
        screenshot("Lost receipt remains protected despite a matching new task")
        closeRecords(app); addLink(app)
        XCTAssertTrue(feedback(app).waitForExistence(timeout: 10))
        XCTAssertTrue(feedback(app).label.contains("Download status unavailable"))
        button("downloads.create.close", app).tap(); openRecord(app)
        XCTAssertTrue(element("downloads.creation.status.submitted", app).waitForExistence(timeout: 8))
    }
    func test目标目录权限拒绝明确提示并保留失败记录() {
        let app = launch(state: "downloads-create-denied"); enableDownloads(app); addLink(app)
        let result = feedback(app)
        XCTAssertTrue(result.waitForExistence(timeout: 10)); XCTAssertTrue(result.label.contains("permission"))
        XCTAssertTrue(result.label.contains("administrator"))
        button("downloads.create.close", app).tap(); openRecord(app)
        let failed = element("downloads.creation.status.failed", app)
        XCTAssertTrue(failed.waitForExistence(timeout: 8)); XCTAssertTrue(failed.label.contains("permission"))
        screenshot("Creation permission failure and recovery guidance")
    }
    func test中文深色大字创建结果和横屏记录可以阅读() {
        let app = launch(chinese: true); enableDownloads(app, chinese: true); addLink(app, chinese: true)
        let result = feedback(app)
        XCTAssertTrue(result.waitForExistence(timeout: 10)); scrollTo(result, app)
        XCTAssertTrue(result.label.contains("已添加下载")); XCTAssertTrue(result.isHittable)
        screenshot("Chinese dark large-text creation result")
        button("downloads.create.close", app).tap(); openRecord(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let status = element("downloads.creation.status.accepted", app); scrollTo(status, app)
        XCTAssertTrue(status.isHittable); XCTAssertTrue(status.label.contains("已添加下载"))
        screenshot("Chinese landscape accepted creation record"); XCUIDevice.shared.orientation = .portrait
    }
    private func addLink(_ app: XCUIApplication, chinese: Bool = false) {
        toolbar("downloads.create.menu", labels: ["Add Task", "添加任务"], app)
        let add = app.buttons[chinese ? "添加链接" : "Add Link"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 8)); add.tap()
        let field = element("downloads.create.uri", app); XCTAssertTrue(field.waitForExistence(timeout: 8)); field.tap(); field.typeText(uri)
        let submit = button("downloads.create.submit", app); XCTAssertTrue(submit.isEnabled); submit.tap()
    }
    private func feedback(_ app: XCUIApplication) -> XCUIElement {
        app.collectionViews["downloads.creation.form"].descendants(matching: .any).matching(identifier: "downloads.create.feedback").firstMatch
    }
    private func closeRecords(_ app: XCUIApplication) {
        if !element("downloads.records.close", app).exists {
            let bar = app.navigationBars.matching(NSPredicate(format: "identifier IN %@", ["Add Task", "添加任务"])).firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 8)); bar.buttons.firstMatch.tap()
        }
        button("downloads.records.close", app).tap()
    }
    private func openRecord(_ app: XCUIApplication) {
        toolbar("downloads.records", labels: ["Recent actions", "操作记录"], app)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "downloads.create-record.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
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
        let anchor = element(id, app); _ = anchor.waitForExistence(timeout: 8)
        let direct = app.buttons.matching(identifier: id).firstMatch
        if direct.exists { return direct }
        let nested = anchor.buttons.firstMatch; return nested.exists ? nested : anchor
    }
    private func launch(state: String = "downloads-create-content", chinese: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if chinese { app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch(); return app
    }
    private func enableDownloads(_ app: XCUIApplication, chinese: Bool = false) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", chinese ? "App 设置" : "App settings", app)
        let toggle = element("mobile.settings.module.downloads", app); scrollTo(toggle, app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.switches.firstMatch.tap()
        navigate("downloads", chinese ? "下载管理" : "Downloads", app)
    }
    private func navigate(_ id: String, _ title: String, _ app: XCUIApplication) {
        if app.tabBars.buttons[title].exists { app.tabBars.buttons[title].tap() }
        else { let item = element("mobile.navigation.\(id)", app); XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap() }
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func scrollTo(_ item: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<14 {
            let record = app.collectionViews["downloads.creation.record"], form = app.collectionViews["downloads.creation.form"]
            let list = record.exists ? record : (form.exists ? form : app.collectionViews.firstMatch)
            guard list.exists else { XCTFail("找不到当前列表"); return }
            let frame = list.frame.intersection(app.frame)
            let navBottom = app.navigationBars.allElementsBoundByIndex.map(\.frame).filter { $0.intersects(frame) }.map(\.maxY).max() ?? frame.minY
            let bottom = !record.exists && !form.exists && app.tabBars.firstMatch.exists ? min(frame.maxY, app.tabBars.firstMatch.frame.minY) - 12 : frame.maxY - 24
            let viewport = CGRect(x: frame.minX + 12, y: max(frame.minY, navBottom) + 10, width: frame.width - 24, height: bottom - max(frame.minY, navBottom) - 10)
            if item.exists, viewport.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) { return }
            let reverse = item.exists && item.frame.midY < viewport.minY
            let distance = item.exists ? min(viewport.height * 0.5, max(20, abs(item.frame.midY - viewport.midY) * 0.5)) : viewport.height * 0.5
            let x = viewport.midX + viewport.width * 0.15, low = viewport.midY + distance / 2, high = viewport.midY - distance / 2
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: reverse ? high : low))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: reverse ? low : high)),
                       withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        XCTFail("目标未进入当前列表可见区域")
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

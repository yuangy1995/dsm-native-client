import XCTest
import UIKit

@MainActor
final class MobileDownloadSettingsUITests: XCTestCase {
    func test选择默认文件夹与常规计划分步保存() {
        let app = launch(); enableDownloads(app); openSettings(app)
        let folder = element("downloads.settings.destination", app)
        XCTAssertTrue(folder.waitForExistence(timeout: 8)); folder.tap()
        let item = element("files.folder-picker.folder./fixture", app)
        XCTAssertTrue(item.waitForExistence(timeout: 8)); item.tap()
        let choose = app.buttons["Choose"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.tap()
        XCTAssertTrue(folder.label.contains("fixture"))
        toggle("autoExtract", app); toggle("schedule", app)
        saveButton(app).tap()
        assertSaved(app)
        screenshot("Default folder and download settings saved")
        element("downloads.settings.close", app).tap(); openSettings(app); assertSaved(app)
    }
    func test未知保存重启后读取常规设置再显式保存计划() {
        let app = launch(state: "downloads-settings-unknown"); enableDownloads(app); openSettings(app)
        toggle("autoExtract", app); toggle("schedule", app); saveButton(app).tap()
        let general = element("downloads.settings.result.general", app)
        scrollTo(general, app); XCTAssertTrue(general.waitForExistence(timeout: 8)); assertResult(general, title: "General", status: "Result unavailable")
        assertResult(element("downloads.settings.result.schedule", app), title: "Download schedule", status: "Not saved yet")
        screenshot("Settings interrupted between two sections")
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture")
        app.launchEnvironment["LANSTASH_UI_STATE"] = "downloads-settings-recover"; app.launch(); enableDownloads(app); openSettings(app)
        XCTAssertTrue(general.waitForExistence(timeout: 8)); assertResult(general, title: "General", status: "Saved")
        let proceed = element("downloads.settings.continue", app)
        XCTAssertTrue(proceed.waitForExistence(timeout: 8)); proceed.tap(); assertSaved(app)
        screenshot("Remaining settings saved after explicit continue")
    }
    func test中文深色大字设置与保存结果支持横屏() {
        let app = launch(chinese: true); enableDownloads(app, chinese: true); openSettings(app)
        toggle("autoExtract", app); screenshot("Chinese dark large-text download settings")
        toggle("schedule", app); saveButton(app).tap(); assertSaved(app, chinese: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        screenshot("Chinese landscape before scrolling to saved settings")
        scrollTo(element("downloads.settings.result.schedule", app), app)
        assertResult(element("downloads.settings.result.schedule", app), title: "下载计划", status: "已保存")
        screenshot("Chinese landscape settings results"); XCUIDevice.shared.orientation = .portrait
    }
    func test只读与空字段不会提供可保存的默认开关() {
        for state in ["downloads-settings-readonly", "downloads-settings-empty"] {
            let app = launch(state: state); enableDownloads(app); openSettings(app)
            let save = saveButton(app)
            XCTAssertTrue(save.waitForExistence(timeout: 8)); XCTAssertFalse(save.isEnabled)
            if state.hasSuffix("readonly") {
                let auto = element("downloads.settings.autoExtract", app)
                scrollTo(auto, app); XCTAssertTrue(auto.exists)
                XCTAssertFalse(auto.switches.firstMatch.exists ? auto.switches.firstMatch.isEnabled : auto.isEnabled)
                XCTAssertTrue(app.staticTexts["This account cannot change download settings. Contact your NAS administrator."].exists)
            } else {
                XCTAssertTrue(app.staticTexts["No download settings are available to display. Refresh to try again."].firstMatch.waitForExistence(timeout: 8))
                XCTAssertFalse(element("downloads.settings.autoExtract", app).exists)
            }
            screenshot(state); app.terminate()
        }
    }
    func test加载与错误状态可关闭或重新读取() {
        for state in ["downloads-settings-loading", "downloads-settings-error"] {
            let app = launch(state: state); enableDownloads(app); openSettings(app)
            if state.hasSuffix("loading") { XCTAssertTrue(app.staticTexts["Loading settings…"].waitForExistence(timeout: 5)) }
            else { XCTAssertTrue(app.staticTexts["Unable to read download settings. Check your connection and refresh."].waitForExistence(timeout: 8)) }
            XCTAssertFalse(saveButton(app).isEnabled)
            screenshot(state); app.terminate()
        }
    }
    private func saveButton(_ app: XCUIApplication) -> XCUIElement {
        let direct = app.buttons.matching(identifier: "downloads.settings.save").firstMatch
        return direct.exists ? direct : element("downloads.settings.save", app).buttons.firstMatch
    }
    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["downloads.settings"].firstMatch
        if settings.exists && settings.isHittable { settings.tap(); return }
        let more = app.buttons["OverflowBarButtonItem"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 8)); more.tap()
        // 系统溢出菜单保留动作标题，不保留原工具栏项目的标识。
        let menuItem = app.buttons.matching(NSPredicate(format: "label IN %@", ["Download settings", "下载设置"])).firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 8)); menuItem.tap()
    }
    private func toggle(_ field: String, _ app: XCUIApplication) {
        let item = element("downloads.settings." + field, app)
        scrollTo(item, app); XCTAssertTrue(item.waitForExistence(timeout: 8)); XCTAssertTrue(item.isEnabled)
        let control = item.switches.firstMatch
        if control.exists { control.tap() } else { item.tap() }
    }
    private func assertResult(_ item: XCUIElement, title: String, status: String) {
        // LabeledContent 的分隔标点由系统语言决定，业务标题与结果都必须准确。
        XCTAssertTrue(item.label.hasPrefix(title), item.label)
        XCTAssertTrue(item.label.hasSuffix(status), item.label)
    }
    private func assertSaved(_ app: XCUIApplication, chinese: Bool = false) {
        let general = element("downloads.settings.result.general", app), schedule = element("downloads.settings.result.schedule", app)
        scrollTo(general, app); XCTAssertTrue(general.waitForExistence(timeout: 8)); assertResult(general, title: chinese ? "常规" : "General", status: chinese ? "已保存" : "Saved")
        scrollTo(schedule, app); assertResult(schedule, title: chinese ? "下载计划" : "Download schedule", status: chinese ? "已保存" : "Saved")
        XCTAssertFalse(saveButton(app).isEnabled)
    }
    private func launch(state: String = "downloads-settings-content", chinese: Bool = false) -> XCUIApplication {
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
        if app.tabBars.buttons[title].exists { app.tabBars.buttons[title].tap() }
        else { let item = element("mobile.navigation.\(id)", app); XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap() }
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func scrollTo(_ item: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<18 {
            let results = app.collectionViews["downloads.settings.form"]
            let details = app.collectionViews["downloads.details.form"]
            let root = app.collectionViews["mobile.page.content"].firstMatch
            let list = results.exists ? results : (details.exists ? details : (root.exists ? root : app.collectionViews.firstMatch))
            guard list.exists else { XCTFail("找不到当前列表"); return }
            let frame = list.frame.intersection(app.frame)
            let settingsBar = app.navigationBars.matching(NSPredicate(format: "identifier IN %@ OR label IN %@",
                ["Download settings", "下载设置"], ["Download settings", "下载设置"])).firstMatch
            let navBottom = results.exists && settingsBar.exists ? settingsBar.frame.maxY
                : app.navigationBars.allElementsBoundByIndex.map(\.frame).filter { $0.intersects(frame) }.map(\.maxY).max() ?? frame.minY
            let top = max(frame.minY, navBottom) + 10
            let bottom = !results.exists && !details.exists && app.tabBars.firstMatch.exists ? min(frame.maxY, app.tabBars.firstMatch.frame.minY) - 12 : frame.maxY - 24
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

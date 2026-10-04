import XCTest
import UIKit

@MainActor
final class MobileDownloadInventoryUITests: XCTestCase {
    func test任务搜索无结果后可恢复完整列表() {
        let app = launch(); enableDownloads(app)
        XCTAssertTrue(element("downloads.task.sample-1", app).waitForExistence(timeout: 8))
        if !app.searchFields.firstMatch.exists {
            let searchButton = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Search", "搜索")).firstMatch
            if searchButton.exists { searchButton.tap() } else { app.swipeDown() }
        }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("No matching task")
        XCTAssertTrue(element("mobile.page.filteredEmpty", app).waitForExistence(timeout: 5))
        screenshot("Download search has no matches")
        search.buttons.firstMatch.tap()
        XCTAssertTrue(element("downloads.task.sample-2", app).waitForExistence(timeout: 5))
        let cancel = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消", "Close", "关闭"])).firstMatch
        if cancel.exists { cancel.tap() }
        XCTAssertTrue(element("downloads.filters", app).waitForExistence(timeout: 5))
        element("downloads.filters", app).tap()
        let paused = app.buttons["Paused"].firstMatch
        XCTAssertTrue(paused.waitForExistence(timeout: 5)); paused.tap()
        XCTAssertTrue(element("downloads.task.sample-2", app).exists)
        XCTAssertFalse(element("downloads.task.sample-1", app).exists)
        screenshot("Paused download filter")
    }

    func test详情读取失败可重试并展示任务文件() {
        let app = launch(state: "downloads-details-error"); enableDownloads(app)
        openDetails(app)
        let retry = element("downloads.details.retry", app)
        scrollTo(retry, app)
        XCTAssertTrue(retry.waitForExistence(timeout: 5)); retry.tap()
        let files = element("downloads.details.files", app)
        scrollTo(files, app); XCTAssertTrue(files.waitForExistence(timeout: 5)); files.tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].firstMatch.waitForExistence(timeout: 5))
        screenshot("Download files after details retry")
        let trackers = element("downloads.details.trackers", app)
        scrollTo(trackers, app); trackers.tap()
        let tracker = app.staticTexts["https://tracker.example.invalid"].firstMatch
        scrollTo(tracker, app); XCTAssertTrue(tracker.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "fixture-secret")).firstMatch.exists)
    }

    func test中文深色大字详情可阅读缺失速度保持横线() {
        let app = launch(chinese: true); enableDownloads(app, chinese: true)
        openDetails(app)
        let remaining = element("downloads.details.remaining", app)
        scrollTo(remaining, app); XCTAssertTrue(remaining.waitForExistence(timeout: 5))
        XCTAssertTrue(remaining.label.contains("剩余时间"))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "--")).firstMatch.exists)
        screenshot("Chinese dark large-text download details")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(remaining.exists)
        screenshot("Landscape download details")
        XCUIDevice.shared.orientation = .portrait
    }

    func test下载页加载空内容和错误都有恢复入口() {
        for state in ["loading", "empty", "error"] {
            let app = launch(state: "downloads-\(state)"); enableDownloads(app)
            XCTAssertTrue(element("mobile.page.\(state)", app).waitForExistence(timeout: 8), state)
            screenshot("Downloads — \(state)"); app.terminate()
        }
    }

    private func launch(state: String = "downloads-content", chinese: Bool = false) -> XCUIApplication {
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
    private func scrollTo(_ item: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<24 {
            let details = app.collectionViews["downloads.details.form"]
            let content = app.collectionViews["mobile.page.content"].firstMatch
            let list = details.exists ? details : (content.exists ? content : app.collectionViews.firstMatch)
            guard list.exists else { XCTFail("找不到当前列表"); return }
            // 仅在可见表单内滑动，避开 iPad 边栏、弹窗外侧与上下工具栏。
            let frame = list.frame.intersection(app.frame)
            let navigationBottom = app.navigationBars.allElementsBoundByIndex.map(\.frame)
                .filter { $0.intersects(frame) }.map(\.maxY).max() ?? frame.minY
            let top = max(frame.minY, navigationBottom) + 10
            let bottom = !details.exists && app.tabBars.firstMatch.exists
                ? min(frame.maxY, app.tabBars.firstMatch.frame.minY) - 12 : frame.maxY - 24
            let viewport = CGRect(x: frame.minX + 12, y: top, width: frame.width - 24, height: bottom - top)
            if item.exists, viewport.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) { return }
            let reverse = item.exists && item.frame.midY < viewport.minY
            let x = viewport.midX + viewport.width * 0.15
            let low = viewport.minY + viewport.height * 0.75
            let high = viewport.minY + viewport.height * 0.25
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: reverse ? high : low))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: x, dy: reverse ? low : high)))
        }
        XCTFail("目标未进入当前列表可见区域")
    }
    private func openDetails(_ app: XCUIApplication) {
        let task = app.staticTexts["Sample archive.zip"].firstMatch
        scrollTo(task, app); XCTAssertTrue(task.waitForExistence(timeout: 8)); task.tap()
        XCTAssertTrue(element("downloads.details.close", app).waitForExistence(timeout: 5))
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
}

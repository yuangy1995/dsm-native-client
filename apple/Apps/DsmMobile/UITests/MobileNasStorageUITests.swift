import XCTest

@MainActor
final class MobileNasStorageUITests: XCTestCase {
    func test日志翻页完整正文与本页筛选() {
        let app = launch("nas-logs"); defer { app.terminate() }
        open("logs", in: app)
        let next = element("mobile.nas.logs.next", app)
        XCTAssertTrue(next.waitForExistence(timeout: 8)); next.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mobile.nas.logs.entry.log:50:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
        let message = element("mobile.nas.logs.message", app)
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("Complete details for synthetic log 51."))
        screenshot(app, "Full log entry after paging")
        element("mobile.nas.logs.done", app).tap()
        element("mobile.nas.logs.pageSize", app).tap(); app.buttons["200"].firstMatch.tap()
        let page = element("mobile.nas.logs.pageNumber", app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Page 1 of 1"), object: page)], timeout: 8), .completed)
        XCTAssertFalse(element("mobile.nas.logs.next", app).isEnabled)
        let search = app.textFields["mobile.nas.logs.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("no-such-log")
        XCTAssertTrue(element("mobile.nas.logs.filteredEmpty", app).waitForExistence(timeout: 5))
        screenshot(app, "Log page filter has no matches")
    }

    func test日志空内容加载和错误重试分别可用() {
        for state in ["nas-logs-empty", "nas-logs-loading", "nas-logs-retry"] {
            let app = launch(state); open("logs", in: app)
            if state == "nas-logs-retry" {
                let retry = app.buttons["Try Again"]
                XCTAssertTrue(retry.waitForExistence(timeout: 8)); retry.tap()
                XCTAssertTrue(element("mobile.nas.logs.pageNumber", app).waitForExistence(timeout: 8))
            } else if state == "nas-logs-empty" {
                XCTAssertTrue(element("mobile.nas.logs.next", app).waitForExistence(timeout: 8))
                XCTAssertFalse(element("mobile.nas.logs.next", app).isEnabled)
            } else {
                XCTAssertTrue(app.staticTexts["Loading logs…"].waitForExistence(timeout: 8))
            }
            screenshot(app, state); app.terminate()
        }
    }

    func test硬盘快速检测和停止均可确认并显示实际状态() {
        let app = launch("nas-storage"); defer { app.terminate() }
        openDisk(app)
        reveal("mobile.nas.disk.quick", in: app).tap()
        XCTAssertTrue(element("mobile.nas.disk.confirm", app).waitForExistence(timeout: 5))
        screenshot(app, "Quick drive test confirmation")
        element("mobile.nas.disk.confirm", app).tap()
        assertTestState("Quick test running", app)
        reveal("mobile.nas.disk.stop", in: app).tap()
        XCTAssertTrue(element("mobile.nas.disk.confirm", app).waitForExistence(timeout: 5)); element("mobile.nas.disk.confirm", app).tap()
        assertTestState("No test running", app)
        screenshot(app, "Drive test stopped and history retained")
    }

    func test取消完整检测确认不会启动检测() {
        let app = launch("nas-storage"); defer { app.terminate() }
        openDisk(app); reveal("mobile.nas.disk.extended", in: app).tap()
        XCTAssertTrue(element("mobile.nas.disk.confirm", app).waitForExistence(timeout: 5))
        screenshot(app, "Extended drive test risk confirmation")
        element("mobile.nas.disk.cancel", app).tap()
        assertTestState("No test running", app)
        XCTAssertFalse(element("mobile.nas.disk.operation.succeeded", app).exists)
    }

    func test硬盘未知结果重启后只恢复状态() {
        let app = launch("nas-storage-unknown")
        openDisk(app); reveal("mobile.nas.disk.quick", in: app).tap()
        element("mobile.nas.disk.confirm", app).tap()
        let pending = reveal("mobile.nas.disk.operation.submitted", in: app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "temporarily unavailable"), object: pending)], timeout: 12), .completed)
        XCTAssertFalse(element("mobile.nas.disk.quick", app).exists)
        screenshot(app, "Drive test interrupted with no repeated start")
        app.terminate()
        let reopened = launch("nas-storage-recover", preserve: true); defer { reopened.terminate() }
        open("storage", in: reopened)
        XCTAssertTrue(reveal("mobile.nas.disk.activity.succeeded", in: reopened).exists)
        screenshot(reopened, "Drive test restored from original identity")
    }

    func test存储错误空内容加载和检测不可用互不混淆() {
        for state in ["nas-storage-empty", "nas-storage-error", "nas-storage-loading", "nas-storage-unsupported"] {
            let app = launch(state); open("storage", in: app)
            switch state {
            case "nas-storage-empty":
                XCTAssertFalse(element("mobile.nas.storage.disk.synthetic-disk", app).exists)
                XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 8))
            case "nas-storage-error":
                XCTAssertTrue(element("mobile.nas.storage.error", app).waitForExistence(timeout: 8))
                XCTAssertTrue(app.buttons["Try Again"].exists)
            case "nas-storage-loading":
                XCTAssertTrue(app.staticTexts["Loading storage information…"].waitForExistence(timeout: 8))
            default:
                element("mobile.nas.storage.disk.synthetic-disk", app).tap()
                XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 8))
                XCTAssertFalse(element("mobile.nas.disk.quick", app).exists)
            }
            screenshot(app, state); app.terminate()
        }
    }

    func test空间分析显示未知容量和重复文件结果() {
        let app = launch("nas-analysis"); defer { app.terminate() }
        openAnalysis(app); element("mobile.nas.analysis.start", app).tap()
        XCTAssertTrue(element("mobile.nas.analysis.scope", app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Size not fully available")).firstMatch.exists)
        screenshot(app, "Storage analysis preserves missing sizes")
        element("mobile.nas.analysis.scope", app).tap(); app.buttons["Duplicate files"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["/fixture/a.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["/fixture/a-copy.txt"].exists)
        screenshot(app, "Storage analysis duplicate results")
    }

    func test空间分析加载可取消失败可重试() {
        for state in ["nas-analysis-loading", "nas-analysis-error"] {
            let app = launch(state); openAnalysis(app); element("mobile.nas.analysis.start", app).tap()
            if state == "nas-analysis-loading" {
                let cancel = element("mobile.nas.analysis.cancel", app)
                XCTAssertTrue(cancel.waitForExistence(timeout: 5)); screenshot(app, "Storage analysis progress"); cancel.tap()
                XCTAssertTrue(element("mobile.nas.analysis.start", app).waitForExistence(timeout: 5))
                XCTAssertFalse(element("mobile.nas.analysis.scope", app).exists)
            } else {
                XCTAssertTrue(element("mobile.nas.analysis.error", app).waitForExistence(timeout: 8))
                XCTAssertTrue(element("mobile.nas.analysis.start", app).isEnabled)
                screenshot(app, "Storage analysis error recovery")
            }
            app.terminate()
        }
    }

    func test中文大字号硬盘检测入口及确认可操作() {
        let app = launch("nas-storage", chinese: true, largeText: true); defer { app.terminate() }
        openDisk(app); reveal("mobile.nas.disk.extended", in: app).tap()
        XCTAssertTrue(element("mobile.nas.disk.confirm", app).waitForExistence(timeout: 5))
        screenshot(app, "Chinese large text drive test confirmation")
        element("mobile.nas.disk.cancel", app).tap()
    }

    func test卷与存储池详情区分明确状态并可以返回() {
        let app = launch("nas-storage"); defer { app.terminate() }
        open("storage", in: app)
        let volume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sample volume")).firstMatch
        XCTAssertTrue(volume.waitForExistence(timeout: 8)); volume.tap()
        let encrypted = element("mobile.nas.volume.encrypted", app)
        XCTAssertTrue(encrypted.waitForExistence(timeout: 8)); XCTAssertEqual(encrypted.value as? String, "No")
        XCTAssertEqual(element("mobile.nas.volume.writable", app).value as? String, "Yes")
        screenshot(app, "Volume details preserve explicit encryption and write state")
        element("mobile.nas.storage.done", app).tap()
        let pool = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sample pool")).firstMatch
        XCTAssertTrue(pool.waitForExistence(timeout: 8)); pool.tap()
        let writable = element("mobile.nas.pool.writable", app)
        XCTAssertTrue(writable.waitForExistence(timeout: 8)); XCTAssertEqual(writable.value as? String, "Yes")
        XCTAssertEqual(element("mobile.nas.pool.scrubbing", app).value as? String, "No")
        screenshot(app, "Storage pool details and member drive")
    }

    private func openDisk(_ app: XCUIApplication) {
        open("storage", in: app)
        reveal("mobile.nas.storage.disk.synthetic-disk", in: app).tap()
    }
    private func openAnalysis(_ app: XCUIApplication) {
        open("storage", in: app)
        let button = element("mobile.nas.analysis.open", app)
        XCTAssertTrue(button.waitForExistence(timeout: 8)); button.tap()
        XCTAssertTrue(element("mobile.nas.analysis.start", app).waitForExistence(timeout: 5))
    }
    private func assertTestState(_ state: String, _ app: XCUIApplication) {
        let row = element("mobile.nas.disk.current", app)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", state), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }
    private func launch(_ state: String, preserve: Bool = false, chinese: Bool = false, largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if preserve { app.launchArguments.append("--ui-preserve-transfer-fixture") }
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state
        app.launch()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", title: chinese ? "App 设置" : "App settings", app)
        _ = reveal("mobile.settings.module.nasSettings", in: app)
        MobileUITestNavigation.enableModule(app, module: "nasSettings", test: self)
        navigate("nasSettings", title: chinese ? "NAS 设置" : "NAS settings", app)
        return app
    }
    private func open(_ page: String, in app: XCUIApplication) { reveal("mobile.nas.page.\(page)", in: app).tap() }
    private func navigate(_ destination: String, title: String, _ app: XCUIApplication) {
        MobileUITestNavigation.open(app, destination: destination, title: title, test: self)
    }
    private func reveal(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let value = element(id, app)
        for attempt in 0..<12 {
            let list = app.collectionViews.containing(.any, identifier: id).firstMatch
            let scroller: XCUIElement = list.exists ? list : app
            if value.waitForExistence(timeout: 1), !value.frame.isEmpty {
                let navigationBottom = app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.map { $0.frame.maxY }.max() ?? app.frame.minY + 110
                let tab = app.tabBars.firstMatch
                let bottom = tab.exists && tab.isHittable ? min(app.frame.maxY - 35, tab.frame.minY - 8) : app.frame.maxY - 35
                if value.frame.minY < navigationBottom + 8 { scroll(scroller, upward: false, in: app); continue }
                if value.frame.maxY > bottom { scroll(scroller, upward: true, in: app); continue }
                if !value.isEnabled {
                    let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: value)
                    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
                }
                if value.isHittable { return value }
            }
            scroll(scroller, upward: attempt < 6, in: app)
        }
        XCTAssertTrue(value.exists); XCTAssertTrue(value.isHittable); return value
    }
    private func scroll(_ element: XCUIElement, upward: Bool, in app: XCUIApplication) {
        let frame = element.frame.intersection(app.frame)
        let center = CGPoint(x: frame.midX, y: max(frame.minY + 160, min(frame.midY, frame.maxY - 160)))
        let distance = min(180.0, frame.height / 3)
        let offset = upward ? distance / 2 : -distance / 2
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: center.x - app.frame.minX, dy: center.y + offset - app.frame.minY))
        let end = origin.withOffset(CGVector(dx: center.x - app.frame.minX, dy: center.y - offset - app.frame.minY))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

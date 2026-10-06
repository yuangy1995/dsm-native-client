import XCTest

@MainActor
final class MobileRegionUITests: XCTestCase {
    func test格式与可搜索时区编辑保存及确认取消() {
        let app = launch("nas-region"); defer { app.terminate() }
        openEditor(app); choose12Hour(app)
        reveal("mobile.nas.region.timeZone", in: app).tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("no-such-zone")
        XCTAssertTrue(app.staticTexts["No matching items"].waitForExistence(timeout: 5))
        search.buttons.firstMatch.tap(); search.tap(); search.typeText("Shanghai")
        let zone = element("mobile.nas.region.zone.Asia/Shanghai", app)
        XCTAssertTrue(zone.waitForExistence(timeout: 5)); zone.tap()
        element("mobile.nas.region.save", app).tap()
        XCTAssertTrue(element("mobile.nas.region.confirm", app).waitForExistence(timeout: 5))
        screenshot(app, "Region and time save warning")
        element("mobile.nas.region.cancel", app).tap()
        XCTAssertTrue(element("mobile.nas.region.timeFormat", app).exists)
        element("mobile.nas.region.save", app).tap(); element("mobile.nas.region.confirm", app).tap()
        expect(reveal("mobile.nas.region.activity.succeeded", in: app), contains: "Time settings were saved")
        screenshot(app, "Region format and time zone saved")
    }

    func test网络时间服务器可编辑且部分失败后只重新校时() {
        let app = launch("nas-region-manual-sync-timeout"); defer { app.terminate() }
        openEditor(app); reveal("mobile.nas.region.network", in: app).switches.firstMatch.tap()
        let server = app.textFields["mobile.nas.region.servers"]
        XCTAssertTrue(server.waitForExistence(timeout: 5)); server.tap(); server.typeText("new.example.invalid\n")
        element("mobile.nas.region.save", app).tap(); element("mobile.nas.region.confirm", app).tap()
        expect(reveal("mobile.nas.region.activity.partial", in: app), contains: "Some changes")
        screenshot(app, "Region settings saved with synchronization incomplete")
        reveal("mobile.nas.region.synchronize", in: app).tap()
        XCTAssertTrue(element("mobile.nas.region.confirm", app).waitForExistence(timeout: 5)); element("mobile.nas.region.confirm", app).tap()
        expect(reveal("mobile.nas.region.activity.succeeded", in: app), contains: "synchronization request was accepted")
        screenshot(app, "Explicit synchronization retry completed")
    }

    func test未知保存重启恢复原设置并保护重复提交() {
        let app = launch("nas-region-unknown")
        openEditor(app); choose12Hour(app); element("mobile.nas.region.save", app).tap(); element("mobile.nas.region.confirm", app).tap()
        expect(reveal("mobile.nas.region.saveResult", in: app), contains: "temporarily unavailable")
        XCTAssertFalse(app.buttons["mobile.nas.region.save"].isEnabled)
        screenshot(app, "Unknown region change remains protected")
        app.terminate()
        let reopened = launch("nas-region-recover", preserve: true); defer { reopened.terminate() }
        expect(reveal("mobile.nas.region.activity.succeeded", in: reopened), contains: "Time settings were saved")
        screenshot(reopened, "Region settings restored after reopening")
    }

    func test手动日期选择可取消再确认保存() {
        let app = launch("nas-region-manual"); defer { app.terminate() }
        openEditor(app)
        let picker = reveal("mobile.nas.region.manualTime", in: app)
        XCTAssertTrue(picker.exists)
        let date = picker.buttons.firstMatch
        XCTAssertTrue(date.exists); date.tap()
        let day = app.buttons.containing(.staticText, identifier: "7").firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5)); day.tap()
        let navigationBars = app.navigationBars.matching(identifier: "Region & Time")
        XCTAssertGreaterThan(navigationBars.count, 0)
        if day.exists {
            // iPad 日历会覆盖标题中央；点表单标题栏左侧空白处只关闭日历，不点到表单外部。
            navigationBars.element(boundBy: navigationBars.count - 1)
                .coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: day)], timeout: 5), .completed)
        }
        screenshot(app, "Manual date selected before saving")
        XCTAssertTrue(app.buttons["mobile.nas.region.save"].isEnabled)
        app.buttons["mobile.nas.region.save"].tap()
        XCTAssertTrue(element("mobile.nas.region.confirm", app).waitForExistence(timeout: 5)); screenshot(app, "Manual NAS date edit warning")
        element("mobile.nas.region.cancel", app).tap()
        XCTAssertFalse(element("mobile.nas.region.activity.succeeded", app).exists)
        element("mobile.nas.region.save", app).tap(); element("mobile.nas.region.confirm", app).tap()
        expect(reveal("mobile.nas.region.activity.succeeded", in: app), contains: "Time settings were saved")
        expect(reveal("mobile.nas.region.clock", in: app), contains: "Oct 7")
        screenshot(app, "Manual NAS date saved and read back")
    }

    func test空响应加载错误重试和不支持均有明确恢复() {
        for state in ["nas-region-empty", "nas-region-loading", "nas-region-retry", "nas-region-unsupported"] {
            let app = launch(state)
            if state == "nas-region-loading" {
                XCTAssertTrue(app.staticTexts["Loading time settings…"].waitForExistence(timeout: 8))
            } else {
                let retry = app.buttons["Try Again"].firstMatch
                XCTAssertTrue(retry.waitForExistence(timeout: 8))
                if state == "nas-region-retry" {
                    retry.tap(); XCTAssertTrue(element("mobile.nas.region.edit", app).waitForExistence(timeout: 8))
                } else { XCTAssertFalse(element("mobile.nas.region.edit", app).exists) }
            }
            screenshot(app, state); app.terminate()
        }
    }

    func test明确权限拒绝不报告保存成功() {
        let app = launch("nas-region-denied"); defer { app.terminate() }
        openEditor(app); choose12Hour(app); element("mobile.nas.region.save", app).tap(); element("mobile.nas.region.confirm", app).tap()
        expect(reveal("mobile.nas.region.saveResult", in: app), contains: "permission")
        element("mobile.nas.region.done", app).tap(); XCTAssertFalse(element("mobile.nas.region.activity.succeeded", app).exists)
        screenshot(app, "Region save permission rejection")
    }

    func test中文大字校时确认内容和取消按钮完整可用() {
        let app = launch("nas-region", chinese: true, large: true); defer { app.terminate() }
        reveal("mobile.nas.region.synchronize", in: app).tap()
        XCTAssertTrue(element("mobile.nas.region.confirm", app).waitForExistence(timeout: 5))
        screenshot(app, "Chinese large text time synchronization confirmation")
        element("mobile.nas.region.cancel", app).tap()
        XCTAssertFalse(element("mobile.nas.region.activity.succeeded", app).exists)
        openEditor(app); screenshot(app, "Chinese large text region editor")
        element("mobile.nas.region.done", app).tap()
    }

    private func choose12Hour(_ app: XCUIApplication) {
        element("mobile.nas.region.timeFormat", app).tap()
        let option = app.buttons["12-hour clock"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
    }
    private func openEditor(_ app: XCUIApplication) { reveal("mobile.nas.region.edit", in: app).tap() }
    private func launch(_ state: String, preserve: Bool = false, chinese: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if preserve { app.launchArguments.append("--ui-preserve-transfer-fixture") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", title: chinese ? "App 设置" : "App settings", app)
        MobileUITestNavigation.enableModule(app, module: "nasSettings", test: self)
        navigate("nasSettings", title: chinese ? "NAS 设置" : "NAS settings", app)
        reveal("mobile.nas.page.region", in: app).tap()
        return app
    }
    private func navigate(_ destination: String, title: String, _ app: XCUIApplication) {
        MobileUITestNavigation.open(app, destination: destination, title: title, test: self)
    }
    private func expect(_ value: XCUIElement, contains text: String) {
        XCTAssertTrue(value.waitForExistence(timeout: 8))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: value)], timeout: 10), .completed)
    }
    private func reveal(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let value = element(id, app)
        for attempt in 0..<14 {
            let list = app.collectionViews.containing(.any, identifier: id).firstMatch
            let scroller: XCUIElement = list.exists ? list : app
            if value.waitForExistence(timeout: 1), !value.frame.isEmpty {
                let top = app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.map { $0.frame.maxY }.max() ?? app.frame.minY + 110
                let tab = app.tabBars.firstMatch
                let bottom = tab.exists && tab.isHittable ? min(app.frame.maxY - 35, tab.frame.minY - 8) : app.frame.maxY - 35
                if value.frame.minY < top + 8 { scroll(scroller, upward: false, in: app); continue }
                if value.frame.maxY > bottom { scroll(scroller, upward: true, in: app); continue }
                if value.isHittable { return value }
            }
            scroll(scroller, upward: attempt < 7, in: app)
        }
        XCTAssertTrue(value.exists); XCTAssertTrue(value.isHittable); return value
    }
    private func scroll(_ element: XCUIElement, upward: Bool, in app: XCUIApplication) {
        let frame = element.frame.intersection(app.frame)
        let center = CGPoint(x: frame.midX, y: max(frame.minY + 160, min(frame.midY, frame.maxY - 160)))
        let offset = min(180.0, frame.height / 3) / 2 * (upward ? 1 : -1)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: center.x - app.frame.minX, dy: center.y + offset - app.frame.minY))
        let end = origin.withOffset(CGVector(dx: center.x - app.frame.minX, dy: center.y - offset - app.frame.minY))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func screenshot(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}

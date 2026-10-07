import XCTest

@MainActor
final class MobileDDNSUITests: XCTestCase {
    func test新建连接测试与保存分离且修改输入清除旧测试结果() {
        let app = launch("nas-ddns-empty"); defer { app.terminate() }
        element("mobile.nas.ddns.add", app).tap(); fillNewRecord(app)
        reveal("mobile.nas.ddns.test", in: app).tap()
        let result = element("mobile.nas.ddns.testResult", app)
        expect(result, contains: "Connection test succeeded")
        screenshot(app, "DDNS connection test does not save the record")
        setUpdates(false, in: app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: result)], timeout: 5), .completed)
        setUpdates(true, in: app)
        element("mobile.nas.ddns.save", app).tap()
        let confirm = element("mobile.nas.ddns.confirm", app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); screenshot(app, "DDNS save risk confirmation"); confirm.tap()
        let record = element("mobile.nas.ddns.record.Example", app)
        XCTAssertTrue(record.waitForExistence(timeout: 8)); expect(record, contains: "created.example.invalid")
        screenshot(app, "DDNS created record and saved result")
    }

    func test已有记录保存开关并可取消或确认删除() {
        let app = launch("nas-ddns"); defer { app.terminate() }
        openRecord(app)
        setUpdates(false, in: app)
        element("mobile.nas.ddns.save", app).tap(); element("mobile.nas.ddns.confirm", app).tap()
        let record = element("mobile.nas.ddns.record.Example", app)
        expect(record, contains: "Updates Off")
        record.tap(); reveal("mobile.nas.ddns.delete", in: app).tap()
        XCTAssertTrue(element("mobile.nas.ddns.confirm", app).waitForExistence(timeout: 5))
        screenshot(app, "DDNS delete names the exact domain")
        element("mobile.nas.ddns.cancel", app).tap()
        XCTAssertTrue(element("mobile.nas.ddns.hostname", app).exists)
        reveal("mobile.nas.ddns.delete", in: app).tap(); element("mobile.nas.ddns.confirm", app).tap()
        XCTAssertTrue(app.staticTexts["No Domain Records"].waitForExistence(timeout: 8))
        XCTAssertFalse(record.exists); screenshot(app, "DDNS delete completed")
    }

    func test地址更新需要明确确认且不宣称解析已经生效() {
        let app = launch("nas-ddns"); defer { app.terminate() }
        element("mobile.nas.ddns.update", app).tap()
        XCTAssertTrue(element("mobile.nas.ddns.confirm", app).waitForExistence(timeout: 5))
        screenshot(app, "DDNS update all current records")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(element("mobile.nas.ddns.activity.succeeded", app).exists)
        element("mobile.nas.ddns.update", app).tap(); element("mobile.nas.ddns.confirm", app).tap()
        let result = reveal("mobile.nas.ddns.activity.succeeded", in: app)
        expect(result, contains: "DNS changes may take time")
    }

    func test未知保存重启只恢复原记录而不重新创建() {
        let app = launch("nas-ddns-unknown-create")
        element("mobile.nas.ddns.add", app).tap(); fillNewRecord(app)
        element("mobile.nas.ddns.save", app).tap(); element("mobile.nas.ddns.confirm", app).tap()
        let result = reveal("mobile.nas.ddns.saveResult", in: app)
        expect(result, contains: "temporarily unavailable")
        let save = app.buttons["mobile.nas.ddns.save"].firstMatch
        XCTAssertTrue(save.exists)
        screenshot(app, "DDNS unknown result keeps duplicate protection")
        XCTAssertFalse(save.isEnabled)
        app.terminate()
        let reopened = launch("nas-ddns-recover", preserve: true); defer { reopened.terminate() }
        expect(element("mobile.nas.ddns.record.Example", reopened), contains: "created.example.invalid")
        expect(reveal("mobile.nas.ddns.activity.succeeded", in: reopened), contains: "saved")
        screenshot(reopened, "DDNS restored after reopening")
    }

    func test空列表加载错误重试不支持和筛选为空各有恢复() {
        for state in ["nas-ddns-empty", "nas-ddns-loading", "nas-ddns-retry", "nas-ddns-unsupported", "nas-ddns"] {
            let app = launch(state)
            switch state {
            case "nas-ddns-empty":
                XCTAssertTrue(app.staticTexts["No Domain Records"].waitForExistence(timeout: 8))
                XCTAssertTrue(element("mobile.nas.ddns.add", app).isEnabled)
            case "nas-ddns-loading":
                XCTAssertTrue(app.staticTexts["Loading domain records…"].waitForExistence(timeout: 8))
            case "nas-ddns-retry":
                let retry = app.buttons["Try Again"].firstMatch
                XCTAssertTrue(retry.waitForExistence(timeout: 8))
                let refresh = app.buttons["mobile.nas.refresh"].firstMatch
                let returnedToMenu = !refresh.exists
                if returnedToMenu {
                    let back = app.navigationBars["Dynamic DNS"].buttons.firstMatch
                    XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
                    XCTAssertTrue(element("mobile.nas.page.ddns", app).waitForExistence(timeout: 5))
                }
                XCTAssertTrue(refresh.waitForExistence(timeout: 5)); refresh.tap()
                if returnedToMenu { reveal("mobile.nas.page.ddns", in: app).tap() }
                XCTAssertTrue(element("mobile.nas.ddns.record.Example", app).waitForExistence(timeout: 8))
            case "nas-ddns-unsupported":
                XCTAssertTrue(app.buttons["Try Again"].firstMatch.waitForExistence(timeout: 8))
                XCTAssertFalse(element("mobile.nas.ddns.add", app).exists)
            default:
                let search = app.textFields["mobile.nas.ddns.search"]
                XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("no-such-domain")
                XCTAssertTrue(element("mobile.nas.ddns.filteredEmpty", app).waitForExistence(timeout: 5))
            }
            screenshot(app, state); app.terminate()
        }
    }

    func test明确权限拒绝保留记录和失败结果() {
        let app = launch("nas-ddns-denied"); defer { app.terminate() }
        openRecord(app); reveal("mobile.nas.ddns.delete", in: app).tap(); element("mobile.nas.ddns.confirm", app).tap()
        expect(reveal("mobile.nas.ddns.saveResult", in: app), contains: "permission")
        element("mobile.nas.ddns.done", app).tap()
        XCTAssertTrue(element("mobile.nas.ddns.record.Example", app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("mobile.nas.ddns.activity.succeeded", app).exists)
        screenshot(app, "DDNS permission failure preserves the record")
    }

    func test中文大字详情与风险确认可触达并取消() {
        let app = launch("nas-ddns", chinese: true, large: true); defer { app.terminate() }
        openRecord(app); reveal("mobile.nas.ddns.delete", in: app).tap()
        XCTAssertTrue(element("mobile.nas.ddns.confirm", app).waitForExistence(timeout: 5))
        screenshot(app, "Chinese large text DDNS delete confirmation")
        element("mobile.nas.ddns.cancel", app).tap()
        element("mobile.nas.ddns.done", app).tap()
        XCTAssertTrue(element("mobile.nas.ddns.record.Example", app).waitForExistence(timeout: 5))
    }

    private func fillNewRecord(_ app: XCUIApplication) {
        let host = app.textFields["mobile.nas.ddns.hostname"]
        XCTAssertTrue(host.waitForExistence(timeout: 5)); host.tap(); host.typeText("created.example.invalid\n")
        let username = app.textFields["mobile.nas.ddns.username"]
        username.tap(); username.typeText("synthetic-user\n")
        let password = app.secureTextFields["mobile.nas.ddns.password"]
        password.tap(); password.typeText("synthetic-only\n")
    }
    private func setUpdates(_ enabled: Bool, in app: XCUIApplication) {
        let toggle = reveal("mobile.nas.ddns.enabled", in: app), control = toggle.switches.firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: control)], timeout: 10), .completed)
        // 云端录像显示中心点击后开关仍保持原值；明确拖动一次，并先断言实际值再检查结果清除。
        let from = control.coordinate(withNormalizedOffset: CGVector(dx: enabled ? 0.25 : 0.75, dy: 0.5))
        let to = control.coordinate(withNormalizedOffset: CGVector(dx: enabled ? 0.75 : 0.25, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", enabled ? "1" : "0"), object: toggle)
        let result = XCTWaiter.wait(for: [changed], timeout: 10)
        if result != .completed { screenshot(app, "DDNS switch did not reach the requested value") }
        XCTAssertEqual(result, .completed)
    }
    private func openRecord(_ app: XCUIApplication) {
        let record = element("mobile.nas.ddns.record.Example", app)
        XCTAssertTrue(record.waitForExistence(timeout: 8)); record.tap()
    }
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
        reveal("mobile.nas.page.ddns", in: app).tap()
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
        let value = XCTAttachment(screenshot: app.screenshot()); value.name = title; value.lifetime = .keepAlways; add(value)
    }
}

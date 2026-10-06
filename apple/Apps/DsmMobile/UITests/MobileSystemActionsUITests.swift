import XCTest

@MainActor final class MobileSystemActionsUITests: XCTestCase {
    func test服务及当前网页连接各自确认取消和断开() {
        let app = launch(); defer { app.terminate() }
        openConnection("sample-user", app)
        reveal("mobile.nas.connection.disconnect", app).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "transfers may stop")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "Connection interruption warning")
        app.buttons["mobile.nas.system.cancel"].tap()
        app.buttons["mobile.nas.connection.disconnect"].tap(); app.buttons["mobile.nas.system.confirm"].tap(); waitDetailClosed(app)
        XCTAssertFalse(row("sample-user", app).exists)
        expect(reveal("mobile.nas.system.activity.succeeded", app), contains: "disconnected")
        openConnection("fixture", app); app.buttons["mobile.nas.connection.disconnect"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "sign this app out")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "Current web connection warning")
        app.buttons["mobile.nas.system.confirm"].tap(); waitDetailClosed(app)
        XCTAssertFalse(row("fixture", app).exists); screenshot(app, "Connection list after disconnecting targets")
    }
    func test缺标识部分目录和受保护连接不能断开() {
        for (mode, name) in [("nas-system-missing-id", "sample-user"), ("nas-system-incomplete", "sample-user"), ("nas-system", "protected-service")] {
            let app = launch(mode); openConnection(name, app)
            XCTAssertFalse(app.buttons["mobile.nas.connection.disconnect"].isEnabled)
            XCTAssertTrue(app.buttons["mobile.nas.connection.done"].isEnabled)
            screenshot(app, mode); app.buttons["mobile.nas.connection.done"].tap(); waitDetailClosed(app); app.terminate()
        }
    }
    func test连接加载空内容错误重试缺少接口与筛选空状态() {
        for mode in ["nas-system-loading", "nas-system-empty", "nas-system-retry", "nas-system-unsupported"] {
            let app = launch(mode)
            switch mode {
            case "nas-system-loading": XCTAssertTrue(app.staticTexts["Loading connections…"].waitForExistence(timeout: 5))
            case "nas-system-empty": XCTAssertTrue(app.staticTexts["No Connections"].waitForExistence(timeout: 5))
            default:
                XCTAssertTrue(app.buttons["mobile.nas.connection.retry"].waitForExistence(timeout: 5))
                if mode == "nas-system-retry" { app.buttons["mobile.nas.connection.retry"].tap(); XCTAssertTrue(row("sample-user", app).waitForExistence(timeout: 8)) }
            }
            screenshot(app, mode); app.terminate()
        }
        let app = launch(); defer { app.terminate() }
        let search = app.textFields["mobile.nas.connection.search"]; XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("nomatch\n")
        XCTAssertTrue(element("mobile.nas.connection.filteredEmpty", app).waitForExistence(timeout: 5))
        search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "\n")
        XCTAssertTrue(row("sample-user", app).waitForExistence(timeout: 5)); screenshot(app, "Connection search restored")
    }
    func test未知断开重启后只读恢复且不能重发或清记录() {
        let app = launch("nas-system-unknown"); openConnection("sample-user", app)
        app.buttons["mobile.nas.connection.disconnect"].tap(); app.buttons["mobile.nas.system.confirm"].tap()
        expect(reveal("mobile.nas.system.activity.submitted", app), contains: "not available yet")
        XCTAssertFalse(app.buttons["mobile.nas.connection.disconnect"].isEnabled)
        XCTAssertFalse(app.buttons["mobile.nas.system.removeRecord"].exists); screenshot(app, "Unknown connection action remains protected"); app.terminate()
        let next = launch("nas-system-recover", preserve: true); defer { next.terminate() }
        expect(reveal("mobile.nas.system.activity.succeeded", next), contains: "disconnected")
        XCTAssertFalse(row("sample-user", next).exists); screenshot(next, "Connection restored by reading after relaunch")
    }
    func test关机确认取消和接受后两种电源操作都受保护() {
        let app = launch(power: true); defer { app.terminate() }
        reveal("mobile.nas.system.shutdown", app).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "All connections, file sharing")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "Shutdown interruption warning"); app.buttons["mobile.nas.system.cancel"].tap()
        XCTAssertFalse(element("mobile.nas.system.activity.accepted", app).exists)
        reveal("mobile.nas.system.shutdown", app).tap(); app.buttons["mobile.nas.system.confirm"].tap()
        expect(reveal("mobile.nas.system.activity.accepted", app), contains: "request was sent")
        XCTAssertFalse(reveal("mobile.nas.system.shutdown", app).isEnabled); XCTAssertFalse(reveal("mobile.nas.system.reboot", app).isEnabled)
        XCTAssertFalse(app.buttons["mobile.nas.system.removeRecord"].exists); screenshot(app, "Shutdown accepted without claiming completion")
    }
    func test未知重启同会话重开不重发而新登录明确恢复() {
        let app = launch("nas-system-unknown", power: true)
        reveal("mobile.nas.system.reboot", app).tap(); app.buttons["mobile.nas.system.confirm"].tap()
        expect(reveal("mobile.nas.system.activity.submitted", app), contains: "No reply")
        XCTAssertFalse(reveal("mobile.nas.system.shutdown", app).isEnabled); screenshot(app, "Restart unknown and protected"); app.terminate()
        let same = launch(power: true, preserve: true)
        XCTAssertFalse(reveal("mobile.nas.system.reboot", same).isEnabled)
        XCTAssertFalse(same.buttons["mobile.nas.system.restore"].exists); XCTAssertTrue(reveal("mobile.nas.system.relogin", same).isEnabled); same.terminate()
        let next = launch("nas-system-newsession", power: true, preserve: true); defer { next.terminate() }
        reveal("mobile.nas.system.restore", next).tap()
        XCTAssertTrue(next.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "running normally")).firstMatch.waitForExistence(timeout: 5))
        screenshot(next, "Restore power controls requires device recovery confirmation")
        next.buttons["mobile.nas.system.cancel"].tap(); XCTAssertFalse(reveal("mobile.nas.system.reboot", next).isEnabled)
        reveal("mobile.nas.system.restore", next).tap(); next.buttons["mobile.nas.system.confirm"].tap()
        expect(reveal("mobile.nas.system.activity.released", next), contains: "Whether it took effect is unknown")
        XCTAssertTrue(reveal("mobile.nas.system.reboot", next).isEnabled); screenshot(next, "Power controls restored with prior uncertainty preserved")
    }
    func test权限拒绝不显示连接成功或电源接受() {
        let app = launch("nas-system-denied"); openConnection("sample-user", app)
        app.buttons["mobile.nas.connection.disconnect"].tap(); app.buttons["mobile.nas.system.confirm"].tap()
        expect(reveal("mobile.nas.system.activity.failed", app), contains: "permission")
        XCTAssertFalse(element("mobile.nas.system.activity.succeeded", app).exists); app.terminate()
        let power = launch("nas-system-denied", power: true); defer { power.terminate() }
        reveal("mobile.nas.system.reboot", power).tap(); power.buttons["mobile.nas.system.confirm"].tap()
        expect(reveal("mobile.nas.system.activity.failed", power), contains: "permission")
        XCTAssertFalse(element("mobile.nas.system.activity.accepted", power).exists); XCTAssertFalse(reveal("mobile.nas.system.reboot", power).isEnabled)
    }
    func test电源版本不支持仍可进入连接列表() {
        let app = launch("nas-system-power-unsupported", power: true); defer { app.terminate() }
        XCTAssertFalse(reveal("mobile.nas.system.shutdown", app).isEnabled)
        XCTAssertTrue(element("mobile.nas.system.powerError", app).exists)
        openConnectionsFromPower(app); XCTAssertTrue(row("sample-user", app).waitForExistence(timeout: 8))
    }
    func test中文大字电源与当前连接确认可取消() {
        let app = launch(power: true, chinese: true, large: true); defer { app.terminate() }
        reveal("mobile.nas.system.reboot", app).tap()
        XCTAssertTrue(app.buttons["mobile.nas.system.confirm"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["mobile.nas.system.confirm"].isHittable)
        screenshot(app, "Chinese large text restart warning"); app.buttons["mobile.nas.system.cancel"].tap()
        openConnectionsFromPower(app); openConnection("fixture", app)
        app.buttons["mobile.nas.connection.disconnect"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "本 App 退出登录")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "Chinese large text current connection warning"); app.buttons["mobile.nas.system.cancel"].tap()
        XCTAssertTrue(app.buttons["mobile.nas.connection.disconnect"].isEnabled)
    }
    private func launch(_ mode: String = "nas-system", power: Bool = false, chinese: Bool = false, large: Bool = false, preserve: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if preserve { app.launchArguments.append("--ui-preserve-transfer-fixture") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = mode; app.launch()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        MobileUITestNavigation.open(app, destination: "settings", title: chinese ? "App 设置" : "App settings", test: self)
        let enabled = reveal("mobile.settings.module.nasSettings", app).switches.firstMatch
        if enabled.value as? String == "0" { enabled.tap() }
        MobileUITestNavigation.open(app, destination: "nasSettings", title: chinese ? "NAS 设置" : "NAS settings", test: self)
        if power { _ = reveal("mobile.nas.system.shutdown", app) }
        else { reveal("mobile.nas.page.connections", app).tap(); XCTAssertTrue(app.collectionViews["mobile.nas.connection.list"].waitForExistence(timeout: 8)) }
        return app
    }
    private func openConnectionsFromPower(_ app: XCUIApplication) {
        if app.frame.width < 600 {
            // 电源在系统摘要下方；先回到分类列表顶部，再按列表顺序寻找连接入口。
            let list = app.collectionViews["mobile.nas.navigation"], first = app.buttons["mobile.nas.page.storage"]
            for _ in 0..<12 {
                if first.exists && first.isHittable { break }
                list.swipeDown(velocity: .fast)
            }
            XCTAssertTrue(first.exists); XCTAssertTrue(first.isHittable)
        }
        reveal("mobile.nas.page.connections", app).tap()
    }
    private func row(_ account: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "mobile.nas.connection.row.", account)).firstMatch
    }
    private func openConnection(_ account: String, _ app: XCUIApplication) {
        let row = row(account, app); XCTAssertTrue(row.waitForExistence(timeout: 8)); XCTAssertTrue(row.isHittable); row.tap()
        XCTAssertTrue(app.collectionViews["mobile.nas.connection.detail"].waitForExistence(timeout: 5))
    }
    private func waitDetailClosed(_ app: XCUIApplication) { XCTAssertTrue(app.collectionViews["mobile.nas.connection.detail"].waitForNonExistence(timeout: 10)) }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    @discardableResult private func reveal(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let values = ["mobile.nas.system.confirmation", "mobile.nas.connection.detail", "mobile.nas.connection.list"]
        let preferred = values.map { app.collectionViews[$0] }.first { $0.exists }
        let fallback: XCUIElement
        if id.hasPrefix("mobile.nas.page.") { fallback = app.collectionViews["mobile.nas.navigation"] }
        else if app.collectionViews["mobile.nas.health"].exists { fallback = app.collectionViews["mobile.nas.health"] }
        else if app.collectionViews["mobile.nas.navigation"].exists { fallback = app.collectionViews["mobile.nas.navigation"] }
        else { fallback = app.collectionViews.containing(.any, identifier: id).firstMatch }
        let list = preferred ?? fallback
        let value = list.descendants(matching: .any).matching(identifier: id).firstMatch
        for _ in 0..<25 {
            if value.exists, !value.frame.isEmpty {
                let top = max(list.frame.minY + 30, 100), bottom = min(list.frame.maxY, app.frame.maxY - (app.tabBars.firstMatch.exists ? 90 : 20))
                if value.frame.midY > top && value.frame.midY < bottom && (value.isHittable || !value.isEnabled) { return value }
            }
            let down = value.exists && value.frame.minY < list.frame.minY + 30
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.3 : 0.8))
                .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.8 : 0.3)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "System action control hierarchy"; tree.lifetime = .keepAlways; add(tree)
        screenshot(app, "System action control unavailable"); XCTFail("控件不可操作：\(id)"); return value
    }
    private func expect(_ value: XCUIElement, contains text: String) {
        XCTAssertTrue(value.waitForExistence(timeout: 8))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: value)], timeout: 10), .completed)
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) { let value = XCTAttachment(screenshot: app.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value) }
}

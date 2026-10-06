import XCTest

@MainActor final class MobilePackageControlUITests: XCTestCase {
    func test启动取消零写后确认再停止并查看结果() {
        let app = launch(); defer { app.terminate() }; detail(app)
        expectStatus("Stopped", app); prompt("start", app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "background tasks")).firstMatch.exists)
        screenshot(app, "Package start risk and original version")
        app.buttons["mobile.package.control.cancel"].tap(); closed(app)
        expectStatus("Stopped", app); XCTAssertFalse(element("mobile.package.activity.succeeded", app).exists)
        prompt("start", app); confirm(app); expectStatus("Running", app)
        expectMessage("succeeded", "Package started", app); screenshot(app, "Package running after confirmed start")
        prompt("stop", app); screenshot(app, "Package stop interruption warning"); confirm(app)
        expectStatus("Stopped", app); expectMessage("succeeded", "Package stopped", app)
        screenshot(app, "Package stopped with persistent activity")
    }
    func test卸载风险可取消并仅确认后从安装列表消失() {
        let app = launch(); defer { app.terminate() }; detail(app); prompt("uninstall", app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "permanently remove")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Sample package"].exists)
        screenshot(app, "Package uninstall data loss warning")
        app.buttons["mobile.package.control.cancel"].tap(); closed(app)
        XCTAssertTrue(app.buttons["mobile.package.action.uninstall"].exists); XCTAssertFalse(element("mobile.package.activity.succeeded", app).exists)
        prompt("uninstall", app); confirm(app)
        XCTAssertTrue(element("mobile.package.detail.removed", app).waitForExistence(timeout: 12))
        expectMessage("succeeded", "Package uninstalled", app)
        XCTAssertFalse(app.buttons["mobile.package.action.uninstall"].exists)
        screenshot(app, "Package removed after confirmed uninstall")
    }
    func test未知启动保持保护重启后只读恢复() {
        let app = launch("nas-package-unknown"); detail(app); prompt("start", app); confirm(app)
        expectMessage("submitted", "latest package status", app)
        XCTAssertFalse(reveal("mobile.package.action.start", app).isEnabled)
        XCTAssertFalse(reveal("mobile.package.action.uninstall", app).isEnabled)
        XCTAssertEqual(reveal("mobile.package.recover", app).label, "Refresh")
        XCTAssertFalse(app.buttons["mobile.package.removeRecord"].exists)
        screenshot(app, "Unknown package start blocks repeated actions"); app.terminate()
        let next = launch("nas-package-control-recover-start", preserve: true); defer { next.terminate() }
        expectMessage("succeeded", "Package started", next); detail(next); expectStatus("Running", next)
        XCTAssertTrue(reveal("mobile.package.action.stop", next).isEnabled)
        screenshot(next, "Package start recovered by reading after relaunch")
    }
    func test拒绝结果不因外部已运行而显示成功() {
        let app = launch("nas-package-apply-denied"); defer { app.terminate() }; detail(app); prompt("start", app); confirm(app)
        expectMessage("failed", "cannot manage packages", app); expectStatus("Running", app)
        XCTAssertFalse(element("mobile.package.activity.succeeded", app).exists)
        app.buttons["mobile.package.detail.refresh"].tap()
        expectMessage("failed", "cannot manage packages", app); XCTAssertFalse(element("mobile.package.activity.succeeded", app).exists)
        screenshot(app, "Rejected package action retains failure despite current running state")
    }
    func test缺少能力与系统套件不提供危险动作() {
        let unsupported = launch("nas-package-control-unsupported"); detail(unsupported)
        XCTAssertFalse(reveal("mobile.package.action.start", unsupported).isEnabled)
        XCTAssertFalse(reveal("mobile.package.action.uninstall", unsupported).isEnabled)
        XCTAssertTrue(unsupported.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "cannot be managed")).firstMatch.exists)
        screenshot(unsupported, "Unsupported package control has recovery guidance"); unsupported.terminate()
        let system = launch("nas-package-control-system"); defer { system.terminate() }; detail(system)
        XCTAssertFalse(system.buttons["mobile.package.action.uninstall"].exists)
        XCTAssertTrue(reveal("mobile.package.action.start", system).isEnabled)
        screenshot(system, "System package cannot be uninstalled")
    }
    func test列表加载空内容失败恢复和搜索为空() {
        let loading = launch("nas-package-loading")
        XCTAssertTrue(element("mobile.package.loading", loading).waitForExistence(timeout: 5)); screenshot(loading, "Installed packages loading"); loading.terminate()
        let empty = launch("nas-package-empty")
        XCTAssertFalse(element("mobile.package.row.SyntheticPackage", empty).exists)
        XCTAssertTrue(empty.staticTexts["No packages shown"].waitForExistence(timeout: 8)); screenshot(empty, "Installed packages empty"); empty.terminate()
        let retry = launch("nas-package-retry"); defer { retry.terminate() }
        XCTAssertTrue(retry.buttons["mobile.package.retry"].waitForExistence(timeout: 8)); screenshot(retry, "Installed package list error with retry")
        retry.buttons["mobile.package.retry"].tap(); XCTAssertTrue(element("mobile.package.row.SyntheticPackage", retry).waitForExistence(timeout: 8))
        let search = retry.textFields["mobile.package.search"]; search.tap(); search.typeText("no-match\n")
        XCTAssertTrue(element("mobile.package.filteredEmpty", retry).waitForExistence(timeout: 5)); screenshot(retry, "Installed package search has no matches")
    }
    func test中文大字详情与风险确认取消均可触达() {
        let app = launch(chinese: true, large: true); defer { app.terminate() }; detail(app)
        expectStatus("已停止", app); screenshot(app, "Chinese large text package details")
        for action in ["start", "uninstall"] {
            prompt(action, app)
            XCTAssertTrue(app.buttons["mobile.package.control.confirm"].isHittable)
            XCTAssertTrue(app.buttons["mobile.package.control.cancel"].isHittable)
            let risk = action == "start" ? "后台任务" : "永久删除"
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", risk)).firstMatch.exists)
            screenshot(app, "Chinese large text package \(action) warning")
            app.buttons["mobile.package.control.cancel"].tap(); closed(app)
        }
        XCTAssertFalse(element("mobile.package.activity.succeeded", app).exists); expectStatus("已停止", app)
    }
    private func launch(_ mode: String = "nas-package-preferences", preserve: Bool = false, chinese: Bool = false, large: Bool = false) -> XCUIApplication {
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
        reveal("mobile.nas.page.packages", app).tap()
        XCTAssertTrue(app.collectionViews["mobile.package.list"].waitForExistence(timeout: 8)); return app
    }
    private func detail(_ app: XCUIApplication) {
        reveal("mobile.package.row.SyntheticPackage", app).tap(); XCTAssertTrue(app.collectionViews["mobile.package.detail"].waitForExistence(timeout: 8))
    }
    private func prompt(_ action: String, _ app: XCUIApplication) {
        let button = reveal("mobile.package.action.\(action)", app); XCTAssertTrue(button.isEnabled); button.tap()
        XCTAssertTrue(app.collectionViews["mobile.package.control.confirmation"].waitForExistence(timeout: 5))
    }
    private func confirm(_ app: XCUIApplication) { app.buttons["mobile.package.control.confirm"].tap(); closed(app) }
    private func closed(_ app: XCUIApplication) { XCTAssertTrue(app.collectionViews["mobile.package.control.confirmation"].waitForNonExistence(timeout: 8)) }
    private func expectStatus(_ text: String, _ app: XCUIApplication) {
        let value = reveal("mobile.package.detail.status", app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text), object: value)], timeout: 12), .completed)
    }
    private func expectMessage(_ phase: String, _ text: String, _ app: XCUIApplication) {
        let value = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "mobile.package.activity.\(phase)", text)).firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 12)); _ = reveal(value.identifier, app)
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    @discardableResult private func reveal(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let order = ["mobile.package.control.confirmation", "mobile.package.detail", "mobile.package.list", "mobile.nas.navigation"]
        let list = order.map { app.collectionViews[$0] }.first { $0.exists } ?? app.collectionViews.firstMatch
        let value = list.descendants(matching: .any).matching(identifier: id).firstMatch
        for _ in 0..<20 {
            if value.exists, !value.frame.isEmpty {
                let bottom = min(list.frame.maxY, app.frame.maxY - (app.tabBars.firstMatch.exists ? 90 : 20))
                if value.frame.midY > max(list.frame.minY + 25, 100) && value.frame.midY < bottom && (value.isHittable || !value.isEnabled) { return value }
            }
            let down = value.exists && value.frame.minY < list.frame.minY + 25
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.3 : 0.8)).press(forDuration: 0.1,
                thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.8 : 0.3)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "Package control hierarchy"; tree.lifetime = .keepAlways; add(tree)
        screenshot(app, "Package control unavailable"); XCTFail("控件不可操作：\(id)"); return value
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) { let value = XCTAttachment(screenshot: app.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value) }
}

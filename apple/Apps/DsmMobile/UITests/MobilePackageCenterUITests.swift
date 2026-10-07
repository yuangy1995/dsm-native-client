import XCTest

@MainActor final class MobilePackageCenterUITests: XCTestCase {
    func test普通设置单位置隐藏选择器且取消保存结果正确() {
        let app = launch(); defer { app.terminate() }; openSettings(app); editSettings(app)
        XCTAssertFalse(element("mobile.package.volume", app).exists)
        toggle("mobile.package.desktop", app).tap(); app.buttons["mobile.package.cancel"].tap(); waitClosed("mobile.package.settingsEditor", app)
        expectValue(reveal("mobile.package.summary.package.center.desktop-notifications", app), "Enabled")
        editSettings(app); toggle("mobile.package.email", app).tap(); app.buttons["mobile.package.save"].tap()
        waitClosed("mobile.package.settingsEditor", app)
        expectValue(reveal("mobile.package.summary.package.center.email-notifications", app), "Enabled")
        expectText(reveal("mobile.package.activity.succeeded", app), "Package settings saved")
        screenshot(app, "Package settings saved with one location hidden")
    }
    func test按套件自动更新需要确认且取消不提交() {
        let app = launch(); defer { app.terminate() }; openSettings(app); editSettings(app)
        reveal("mobile.package.policy", app).tap(); app.buttons["Choose for each package"].tap()
        reveal("mobile.package.policy.SyntheticPackage", app).tap(); app.buttons["Install all updates automatically"].tap()
        app.buttons["mobile.package.save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "automatically install package updates")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "Automatic package update interruption warning"); app.buttons["mobile.package.confirm.cancel"].tap()
        XCTAssertTrue(app.collectionViews["mobile.package.settingsEditor"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("mobile.package.activity.succeeded", app).exists)
        app.buttons["mobile.package.save"].tap(); app.buttons["mobile.package.confirm"].tap(); waitClosed("mobile.package.settingsEditor", app)
        expectText(reveal("mobile.package.policy.summary", app), "Choose for each package")
        editSettings(app); expectText(reveal("mobile.package.policy.SyntheticPackage", app), "Install all updates automatically")
        screenshot(app, "Per-package update choice restored after save")
    }
    func test多位置可以选择并保存默认安装位置() {
        let app = launch("nas-package-multi-volume"); defer { app.terminate() }; openSettings(app); editSettings(app)
        reveal("mobile.package.volume", app).tap(); app.buttons["Volume 2"].tap(); app.buttons["mobile.package.save"].tap()
        waitClosed("mobile.package.settingsEditor", app)
        XCTAssertTrue(app.collectionViews["mobile.package.preferences"].staticTexts["Default install location, Volume 2"].waitForExistence(timeout: 8)); screenshot(app, "Default package location saved")
    }
    func test来源地址校验信任取消以及新增编辑移除() {
        let app = launch(); defer { app.terminate() }; openSettings(app); openSources(app); addSource(app)
        replace("name", "New source", app); replace("url", "ftp://packages.example.invalid/new", app)
        XCTAssertFalse(app.buttons["mobile.package.save"].isEnabled)
        replace("url", "http://packages.example.invalid/new", app); app.buttons["mobile.package.save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "publisher certificates")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "unencrypted connection")).firstMatch.exists)
        screenshot(app, "Package source trust and unencrypted address warning"); app.buttons["mobile.package.confirm.cancel"].tap()
        replace("url", "https://packages.example.invalid/new", app); saveSource(app)
        openSource("New source", app)
        replace("name", "Renamed source", app); saveSource(app)
        openSource("Renamed source", app); reveal("mobile.package.source.remove", app).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Installed packages will remain")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "Removing a package source preserves installed packages"); app.buttons["mobile.package.confirm.cancel"].tap()
        reveal("mobile.package.source.remove", app).tap(); app.buttons["mobile.package.confirm"].tap(); waitClosed("mobile.package.source.editor", app)
        XCTAssertTrue(sourceRow("Renamed source", app).waitForNonExistence(timeout: 8)); XCTAssertTrue(sourceRow("Sample source", app).exists)
        screenshot(app, "Package sources after removing the selected source")
    }
    func test未知设置重启后只读恢复且不允许再次保存() {
        let app = launch("nas-package-unknown"); openSettings(app); editSettings(app)
        toggle("mobile.package.email", app).tap(); app.buttons["mobile.package.save"].tap()
        expectText(reveal("mobile.package.activity.submitted", app), "latest package status")
        XCTAssertFalse(app.buttons["mobile.package.save"].isEnabled); XCTAssertFalse(app.buttons["mobile.package.removeRecord"].exists)
        screenshot(app, "Unknown package settings stay protected"); app.terminate()
        let next = launch("nas-package-recover-settings", preserve: true); defer { next.terminate() }; openSettings(next)
        expectText(reveal("mobile.package.activity.succeeded", next), "Package settings saved")
        expectValue(reveal("mobile.package.summary.package.center.email-notifications", next), "Enabled")
        XCTAssertTrue(reveal("mobile.package.editSettings", next).isEnabled); screenshot(next, "Package settings restored by reading after relaunch")
    }
    func test未知来源重启后按原目标恢复且不能清记录重发() {
        let app = launch("nas-package-unknown"); openSettings(app); openSources(app); addSource(app)
        replace("name", "New source", app); replace("url", "https://packages.example.invalid/new", app)
        app.buttons["mobile.package.save"].tap(); app.buttons["mobile.package.confirm"].tap()
        expectText(reveal("mobile.package.activity.submitted", app), "latest package status")
        XCTAssertFalse(app.buttons["mobile.package.save"].isEnabled); XCTAssertFalse(app.buttons["mobile.package.removeRecord"].exists)
        screenshot(app, "Unknown package source stays protected"); app.terminate()
        let next = launch("nas-package-recover-source", preserve: true); defer { next.terminate() }; openSettings(next); openSources(next)
        XCTAssertTrue(sourceRow("New source", next).waitForExistence(timeout: 8))
        expectText(reveal("mobile.package.activity.succeeded", next), "Package source saved")
        XCTAssertTrue(next.buttons["mobile.package.source.add"].isEnabled); screenshot(next, "Package source restored after relaunch without resending")
    }
    func test未知策略部分来源和设置错误分别保留限制() {
        let unknown = launch("nas-package-unknown-preference"); openSettings(unknown); editSettings(unknown)
        toggle("mobile.package.email", unknown).tap(); XCTAssertFalse(unknown.buttons["mobile.package.save"].isEnabled)
        XCTAssertTrue(unknown.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Some package update choices are unavailable")).firstMatch.exists)
        screenshot(unknown, "Unknown package update choices cannot be overwritten"); unknown.terminate()
        let partial = launch("nas-package-source-partial"); openSettings(partial); openSources(partial)
        XCTAssertTrue(partial.buttons["mobile.package.retry"].waitForExistence(timeout: 8)); XCTAssertFalse(partial.buttons["mobile.package.source.add"].isEnabled)
        screenshot(partial, "Incomplete package source directory is not editable"); partial.terminate()
        let failed = launch("nas-package-settings-error"); defer { failed.terminate() }; openSettings(failed)
        XCTAssertTrue(failed.buttons["mobile.package.retry"].waitForExistence(timeout: 8)); openSources(failed)
        XCTAssertTrue(sourceRow("Sample source", failed).waitForExistence(timeout: 8)); XCTAssertTrue(failed.buttons["mobile.package.source.add"].isEnabled)
        screenshot(failed, "Sources remain available when package settings cannot load")
    }
    func test加载空内容错误重试与缺少设置能力() {
        for mode in ["nas-package-loading", "nas-package-empty", "nas-package-retry", "nas-package-unsupported"] {
            let app = launch(mode)
            switch mode {
            case "nas-package-loading": XCTAssertTrue(element("mobile.package.loading", app).waitForExistence(timeout: 5))
            case "nas-package-empty":
                XCTAssertTrue(app.staticTexts["No packages shown"].waitForExistence(timeout: 8)); openSettings(app); openSources(app)
                XCTAssertTrue(app.staticTexts["No package sources added"].waitForExistence(timeout: 8)); XCTAssertTrue(app.buttons["mobile.package.source.add"].isEnabled)
            case "nas-package-retry":
                XCTAssertTrue(app.buttons["mobile.package.retry"].waitForExistence(timeout: 8)); app.buttons["mobile.package.retry"].tap()
                XCTAssertTrue(element("mobile.package.row.SyntheticPackage", app).waitForExistence(timeout: 8))
            default:
                openSettings(app); XCTAssertTrue(app.buttons["mobile.package.retry"].waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["mobile.package.editSettings"].exists)
                openSources(app); XCTAssertTrue(app.buttons["mobile.package.retry"].waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["mobile.package.source.add"].isEnabled)
            }
            screenshot(app, mode); app.terminate()
        }
    }
    func test明确权限拒绝保留失败而不显示保存成功() {
        let app = launch("nas-package-denied"); defer { app.terminate() }; openSettings(app); editSettings(app)
        toggle("mobile.package.email", app).tap(); app.buttons["mobile.package.save"].tap()
        expectText(reveal("mobile.package.activity.failed", app), "cannot manage packages")
        XCTAssertFalse(element("mobile.package.activity.succeeded", app).exists); screenshot(app, "Package setting rejection remains a failure")
    }
    func test套件和来源搜索无匹配后清除可恢复原目录() {
        let app = launch(); defer { app.terminate() }
        for source in [false, true] {
            if source { openSettings(app); openSources(app) }
            let search = app.textFields[source ? "mobile.package.source.search" : "mobile.package.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("no-match\n")
            XCTAssertTrue(element(source ? "mobile.package.source.filteredEmpty" : "mobile.package.filteredEmpty", app).waitForExistence(timeout: 5))
            search.tap()
            if app.frame.width < 600 { for _ in 0..<8 { search.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: []) } }
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
            let cleared = search.value as? String ?? ""; XCTAssertTrue(cleared.isEmpty || cleared == search.placeholderValue)
            search.typeText("\n")
            XCTAssertTrue((source ? sourceRow("Sample source", app) : element("mobile.package.row.SyntheticPackage", app)).waitForExistence(timeout: 5))
            screenshot(app, source ? "Package source search restored" : "Installed package search restored")
        }
    }
    func test中文大字来源信任与未加密风险可取消() {
        let app = launch(chinese: true, large: true); defer { app.terminate() }; openSettings(app); openSources(app); addSource(app)
        replace("name", "New source", app); replace("url", "http://packages.example.invalid/new", app); app.buttons["mobile.package.save"].tap()
        XCTAssertTrue(app.buttons["mobile.package.confirm"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["mobile.package.confirm"].isHittable)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "未加密")).firstMatch.exists)
        screenshot(app, "Chinese large text package source trust warning"); app.buttons["mobile.package.confirm.cancel"].tap()
        XCTAssertTrue(app.textFields["mobile.package.source.name"].waitForExistence(timeout: 5)); XCTAssertFalse(element("mobile.package.activity.succeeded", app).exists)
    }
    private func launch(_ mode: String = "nas-package-preferences", preserve: Bool = false, chinese: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if preserve { app.launchArguments.append("--ui-preserve-transfer-fixture") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = mode; app.launch()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        MobileUITestNavigation.open(app, destination: "settings", title: chinese ? "App 设置" : "App settings", test: self)
        MobileUITestNavigation.enableModule(app, module: "nasSettings", test: self)
        MobileUITestNavigation.open(app, destination: "nasSettings", title: chinese ? "NAS 设置" : "NAS settings", test: self)
        reveal("mobile.nas.page.packages", app).tap()
        XCTAssertTrue(app.collectionViews["mobile.package.list"].waitForExistence(timeout: 8)); return app
    }
    private func openSettings(_ app: XCUIApplication) { let button = app.buttons["mobile.package.settings"]; XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap(); XCTAssertTrue(app.collectionViews["mobile.package.preferences"].waitForExistence(timeout: 5)) }
    private func editSettings(_ app: XCUIApplication) { reveal("mobile.package.editSettings", app).tap(); XCTAssertTrue(app.collectionViews["mobile.package.settingsEditor"].waitForExistence(timeout: 5)) }
    private func openSources(_ app: XCUIApplication) { reveal("mobile.package.sources", app).tap(); XCTAssertTrue(app.collectionViews["mobile.package.source.list"].waitForExistence(timeout: 5)) }
    private func addSource(_ app: XCUIApplication) { let button = app.buttons["mobile.package.source.add"]; XCTAssertTrue(button.waitForExistence(timeout: 8)); XCTAssertTrue(button.isEnabled); button.tap(); XCTAssertTrue(app.collectionViews["mobile.package.source.editor"].waitForExistence(timeout: 5)) }
    private func saveSource(_ app: XCUIApplication) { app.buttons["mobile.package.save"].tap(); XCTAssertTrue(app.buttons["mobile.package.confirm"].waitForExistence(timeout: 5)); app.buttons["mobile.package.confirm"].tap(); waitClosed("mobile.package.source.editor", app) }
    private func waitClosed(_ id: String, _ app: XCUIApplication) { XCTAssertTrue(app.collectionViews[id].waitForNonExistence(timeout: 12)) }
    private func sourceRow(_ name: String, _ app: XCUIApplication) -> XCUIElement { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "mobile.package.source.row.", name)).firstMatch }
    private func openSource(_ name: String, _ app: XCUIApplication) { let value = sourceRow(name, app); XCTAssertTrue(value.waitForExistence(timeout: 8)); XCTAssertTrue(value.isHittable); value.tap(); XCTAssertTrue(app.collectionViews["mobile.package.source.editor"].waitForExistence(timeout: 5)) }
    private func toggle(_ id: String, _ app: XCUIApplication) -> XCUIElement { let parent = reveal(id, app); return parent.switches.firstMatch.exists ? parent.switches.firstMatch : app.switches[id].firstMatch }
    private func replace(_ key: String, _ text: String, _ app: XCUIApplication) {
        let id = "mobile.package.source.\(key)", field = app.textFields[id]; _ = reveal(id, app)
        if app.frame.width > 600 { field.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.8)).tap() }
        else { field.tap() }
        let current = field.value as? String ?? "", count = current == field.placeholderValue ? 0 : current.count
        if count > 0 {
            // typeText 会把箭头符号当正文；使用真实方向键移动到单行文本末尾。
            if app.frame.width < 600 { for _ in 0..<count { field.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: []) } }
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
        }
        // 云端可能在按键仍逐字生效时返回；等原值真正清空，保留同一次输入与精确值断言。
        let empty = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let current = field.value as? String else { return false }
            return current.isEmpty || current == field.placeholderValue
        }, object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 5), .completed)
        field.typeText(text)
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed)
        if app.frame.width > 600, app.popovers.firstMatch.exists {
            app.navigationBars.containing(.button, identifier: "mobile.package.save").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
            XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        }
        let done = app.buttons["mobile.package.keyboardDone"]; if done.exists && done.isHittable { done.tap() }
        XCTAssertEqual(field.value as? String, text)
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    @discardableResult private func reveal(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let order = ["mobile.package.confirmation", "mobile.package.source.editor", "mobile.package.settingsEditor", "mobile.package.source.list", "mobile.package.preferences", "mobile.package.list"]
        let list = order.map { app.collectionViews[$0] }.first { $0.exists } ?? (app.collectionViews["mobile.nas.navigation"].exists ? app.collectionViews["mobile.nas.navigation"] : app.collectionViews.firstMatch)
        let value = list.descendants(matching: .any).matching(identifier: id).firstMatch
        for _ in 0..<20 {
            if value.exists, !value.frame.isEmpty {
                let bottom = min(list.frame.maxY, app.frame.maxY - (app.tabBars.firstMatch.exists ? 90 : 20))
                if value.frame.midY > max(list.frame.minY + 25, 100) && value.frame.midY < bottom && (value.isHittable || !value.isEnabled) { return value }
            }
            let down = value.exists && value.frame.minY < list.frame.minY + 25
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.3 : 0.8)).press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.8 : 0.3)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "Package control hierarchy"; tree.lifetime = .keepAlways; add(tree)
        screenshot(app, "Package control unavailable"); XCTFail("控件不可操作：\(id)"); return value
    }
    private func expectText(_ value: XCUIElement, _ text: String) { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: value)], timeout: 10), .completed) }
    private func expectValue(_ value: XCUIElement, _ text: String) { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: value)], timeout: 10), .completed) }
    private func screenshot(_ app: XCUIApplication, _ name: String) { let value = XCTAttachment(screenshot: app.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value) }
}

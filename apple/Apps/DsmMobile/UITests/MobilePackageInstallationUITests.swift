import XCTest

@MainActor final class MobilePackageInstallationUITests: XCTestCase {
    func test安装计划可取消再确认并回读完成() {
        let app = launch(); defer { app.terminate() }; prepare("NewPackage:stable", app)
        XCTAssertFalse(element("mobile.package.install.volume.NewPackage", app).exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "interrupt related services")).firstMatch.exists)
        screenshot(app, "Package installation confirmation with one location")
        app.buttons["mobile.package.install.close"].tap(); waitClosed("mobile.package.install.plan", app)
        XCTAssertFalse(element("mobile.package.install.record.completed", app).exists)
        app.buttons["mobile.package.install.prepare"].tap(); XCTAssertTrue(app.collectionViews["mobile.package.install.plan"].waitForExistence(timeout: 8))
        reveal("mobile.package.install.confirm", app).tap(); expectPhase("completed", app)
        screenshot(app, "Package installation completed and version read back")
    }
    func test依赖清单保持顺序并逐项完成() {
        let app = launch("nas-package-install-dependencies"); defer { app.terminate() }; prepare("NewPackage:stable", app)
        XCTAssertTrue(app.staticTexts["Dependency package"].exists); XCTAssertTrue(app.staticTexts["New package"].exists)
        screenshot(app, "Package dependency installation plan")
        reveal("mobile.package.install.confirm", app).tap(); expectPhase("completed", app)
        XCTAssertTrue(app.staticTexts["Completed 2 of 2 packages"].firstMatch.exists)
        screenshot(app, "Both package dependencies installed")
    }
    func test更新分类与多位置选择进入同一确认流程() {
        let app = launch("nas-package-install-multi-volume"); defer { app.terminate() }
        reveal("mobile.package.catalog.filter", app).tap(); app.buttons["Updates"].tap()
        XCTAssertTrue(app.buttons["mobile.package.catalog.row.SyntheticPackage:stable"].waitForExistence(timeout: 5))
        reveal("mobile.package.catalog.updateAll", app).tap()
        XCTAssertTrue(app.collectionViews["mobile.package.install.plan"].waitForExistence(timeout: 8))
        reveal("mobile.package.install.volume.SyntheticPackage", app).tap(); app.buttons["Volume 2"].tap()
        screenshot(app, "Package update with selected installation location")
        reveal("mobile.package.install.confirm", app).tap(); expectPhase("completed", app)
    }
    func test非快速安装必须同意许可并保留原生选项() {
        let app = launch(); defer { app.terminate() }; prepare("CommunityPackage:stable", app)
        reveal("mobile.package.install.confirm", app).tap()
        XCTAssertTrue(app.collectionViews["mobile.package.install.options"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.textFields["mobile.package.install.field.label"].exists)
        XCTAssertTrue(app.secureTextFields["mobile.package.install.field.secret"].exists)
        XCTAssertTrue(app.staticTexts["Package label"].exists)
        XCTAssertTrue(app.staticTexts["Package password"].exists)
        XCTAssertFalse(reveal("mobile.package.install.confirmOptions", app).isEnabled)
        toggle("mobile.package.install.license", app).tap()
        toggle("mobile.package.install.field.enabled", app).tap()
        reveal("mobile.package.install.field.mode", app).tap(); app.buttons["Extended"].tap()
        screenshot(app, "Package license and native configuration options")
        let confirm = reveal("mobile.package.install.confirmOptions", app); XCTAssertTrue(confirm.isEnabled); confirm.tap()
        expectPhase("completed", app); screenshot(app, "Configured package installed")
    }
    func test下载取消只等待原任务结束而不进入安装选项() {
        let app = launch("nas-package-install-slow"); defer { app.terminate() }; prepare("NewPackage:stable", app)
        reveal("mobile.package.install.confirm", app).tap(); expectPhase("downloading", app)
        let cancel = reveal("mobile.package.install.cancel", app); XCTAssertTrue(cancel.isEnabled)
        screenshot(app, "Package download can be cancelled"); cancel.tap(); expectPhase("cancelled", app)
        XCTAssertFalse(app.collectionViews["mobile.package.install.options"].exists); screenshot(app, "Package download cancellation completed")
    }
    func test未知安装重启只读恢复且不能清除保护() {
        let app = launch("nas-package-install-unknown"); prepare("NewPackage:stable", app)
        reveal("mobile.package.install.confirm", app).tap(); expectPhase("unverified", app)
        XCTAssertFalse(app.buttons["mobile.package.install.remove"].exists)
        screenshot(app, "Unknown package installation remains protected"); app.terminate()
        let next = launch("nas-package-install-recover", preserve: true); defer { next.terminate() }
        XCTAssertTrue(reveal("mobile.package.install.record.completed", next).exists)
        XCTAssertTrue(next.buttons["mobile.package.install.upload"].isEnabled)
        screenshot(next, "Package installation recovered by reading after relaunch")
    }
    func test目录加载空内容错误恢复搜索和第三方失败() {
        let loading = launch("nas-package-install-loading")
        XCTAssertTrue(element("mobile.package.catalog.loading", loading).waitForExistence(timeout: 5)); screenshot(loading, "Package catalog loading"); loading.terminate()
        let empty = launch("nas-package-install-empty")
        XCTAssertTrue(element("mobile.package.catalog.empty", empty).waitForExistence(timeout: 8)); screenshot(empty, "Empty package catalog"); empty.terminate()
        let retry = launch("nas-package-install-retry")
        XCTAssertTrue(retry.buttons["mobile.package.catalog.retry"].waitForExistence(timeout: 8)); screenshot(retry, "Package catalog error and recovery action")
        retry.buttons["mobile.package.catalog.retry"].tap()
        XCTAssertTrue(retry.buttons["mobile.package.catalog.row.NewPackage:stable"].waitForExistence(timeout: 8))
        let search = retry.textFields["mobile.package.catalog.search"]; search.tap(); search.typeText("no-match\n")
        XCTAssertTrue(element("mobile.package.catalog.empty", retry).waitForExistence(timeout: 5)); screenshot(retry, "Package catalog search has no matches"); retry.terminate()
        let third = launch("nas-package-install-community-error"); defer { third.terminate() }
        XCTAssertTrue(element("mobile.package.catalog.communityError", third).waitForExistence(timeout: 8))
        XCTAssertTrue(reveal("mobile.package.catalog.row.NewPackage:stable", third).exists); screenshot(third, "Official packages remain available without third-party catalog")
    }
    func test权限拒绝和专用表单限制不显示成功() {
        let denied = launch("nas-package-install-denied"); prepare("NewPackage:stable", denied)
        reveal("mobile.package.install.confirm", denied).tap(); expectPhase("failed", denied)
        XCTAssertFalse(element("mobile.package.install.record.completed", denied).exists); screenshot(denied, "Package installation denied without success"); denied.terminate()
        let special = launch("nas-package-install-custom"); defer { special.terminate() }; prepare("CommunityPackage:stable", special)
        reveal("mobile.package.install.confirm", special).tap(); expectPhase("failed", special)
        XCTAssertTrue(special.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "DSM Package Center")).firstMatch.exists)
        XCTAssertFalse(special.collectionViews["mobile.package.install.options"].exists); screenshot(special, "Unsupported package form points to DSM")
    }
    func test系统文件选择器可取消并返回目录() {
        let app = launch(); defer { app.terminate() }
        let upload = app.buttons["mobile.package.install.upload"]; XCTAssertTrue(upload.isEnabled); upload.tap()
        let panel = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8)); XCTAssertTrue(cancel.isHittable); screenshot(app, "System package file picker")
        cancel.tap(); XCTAssertTrue(panel.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.collectionViews["mobile.package.catalog.list"].exists); XCTAssertFalse(element("mobile.package.install.record.active", app).exists)
    }
    func test中文大字依赖确认与取消可完整操作() {
        let app = launch("nas-package-install-dependencies", chinese: true, large: true); defer { app.terminate() }; prepare("NewPackage:stable", app)
        let confirm = reveal("mobile.package.install.confirm", app); XCTAssertTrue(confirm.isHittable); XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "暂时中断相关服务")).firstMatch.exists)
        screenshot(app, "Chinese large text package installation confirmation")
        app.buttons["mobile.package.install.close"].tap(); waitClosed("mobile.package.install.plan", app)
        XCTAssertFalse(element("mobile.package.install.record.completed", app).exists)
    }
    private func launch(_ mode: String = "nas-package-install", preserve: Bool = false, chinese: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if preserve { app.launchArguments.append("--ui-preserve-transfer-fixture") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = mode; app.launch()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        MobileUITestNavigation.open(app, destination: "settings", title: chinese ? "App 设置" : "App settings", test: self)
        MobileUITestNavigation.enableModule(app, module: "nasSettings", test: self)
        MobileUITestNavigation.open(app, destination: "nasSettings", title: chinese ? "NAS 设置" : "NAS settings", test: self)
        reveal("mobile.nas.page.packages", app).tap(); XCTAssertTrue(app.collectionViews["mobile.package.list"].waitForExistence(timeout: 8))
        reveal("mobile.package.catalog", app).tap(); XCTAssertTrue(app.collectionViews["mobile.package.catalog.list"].waitForExistence(timeout: 8)); return app
    }
    private func prepare(_ id: String, _ app: XCUIApplication) {
        reveal("mobile.package.catalog.row.\(id)", app).tap()
        XCTAssertTrue(app.collectionViews["mobile.package.catalog.detail"].waitForExistence(timeout: 5))
        reveal("mobile.package.install.prepare", app).tap()
        XCTAssertTrue(app.collectionViews["mobile.package.install.plan"].waitForExistence(timeout: 8))
    }
    private func expectPhase(_ phase: String, _ app: XCUIApplication) { XCTAssertTrue(element("mobile.package.install.phase.\(phase)", app).waitForExistence(timeout: 15)) }
    private func waitClosed(_ id: String, _ app: XCUIApplication) { XCTAssertTrue(app.collectionViews[id].waitForNonExistence(timeout: 10)) }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func toggle(_ id: String, _ app: XCUIApplication) -> XCUIElement { let parent = reveal(id, app); return parent.switches.firstMatch.exists ? parent.switches.firstMatch : app.switches[id].firstMatch }
    @discardableResult private func reveal(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let order = ["mobile.package.install.options", "mobile.package.install.plan", "mobile.package.install.progress", "mobile.package.catalog.detail", "mobile.package.catalog.list", "mobile.package.list"]
        let list = order.map { app.collectionViews[$0] }.first { $0.exists } ?? (app.collectionViews["mobile.nas.navigation"].exists ? app.collectionViews["mobile.nas.navigation"] : app.collectionViews.firstMatch)
        let value = list.descendants(matching: .any).matching(identifier: id).firstMatch
        for _ in 0..<18 {
            if value.exists, !value.frame.isEmpty {
                // 安装表单覆盖标签栏；背景标签栏仍存在于层级中，但不能占用弹窗的可见区域。
                let tab = app.tabBars.firstMatch
                let bottom = min(list.frame.maxY, app.frame.maxY - (tab.exists && tab.isHittable ? 90 : 20))
                if value.frame.midY > max(list.frame.minY + 25, 100) && value.frame.midY < bottom && (value.isHittable || !value.isEnabled) { return value }
            }
            let down = value.exists && value.frame.minY < list.frame.minY + 25
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.3 : 0.8)).press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.8 : 0.3)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "Package installation hierarchy"; tree.lifetime = .keepAlways; add(tree)
        screenshot(app, "Package installation control unavailable"); XCTFail("控件不可操作：\(id)"); return value
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) { let value = XCTAttachment(screenshot: app.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value) }
}

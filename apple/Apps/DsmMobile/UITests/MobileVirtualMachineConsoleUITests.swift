import XCTest

@MainActor final class MobileVirtualMachineConsoleUITests: XCTestCase {
    func test触控打开输入关闭与重新连接() {
        let app = launch(); defer { app.terminate() }
        openConsole(app)
        XCTAssertTrue(app.staticTexts["Synthetic console ready"].waitForExistence(timeout: 10))
        screenshot("Virtual machine console connected light")
        let input = app.webViews.textFields["Test input"]; XCTAssertTrue(input.isHittable)
        input.tap(); input.typeText("abc")
        app.webViews.buttons["Send input"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic input received"].waitForExistence(timeout: 6))
        screenshot("Virtual machine console input received")
        app.buttons["virtual-machine.console.reconnect"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic console ready"].waitForExistence(timeout: 10))
        screenshot("Virtual machine console explicitly reconnected")
        app.buttons["virtual-machine.console.close"].tap()
        XCTAssertTrue(app.buttons["virtual-machine.console.open"].waitForExistence(timeout: 6))
    }
    func test连接失败后明确重连恢复() {
        let app = launch("vmm-console-retry"); defer { app.terminate() }; openConsole(app)
        XCTAssertTrue(element("virtual-machine.console.failed", app).waitForExistence(timeout: 10))
        screenshot("Virtual machine console connection failed")
        app.buttons["virtual-machine.console.reconnect"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic console ready"].waitForExistence(timeout: 10))
        screenshot("Virtual machine console retry restored")
        app.buttons["virtual-machine.console.close"].tap()
    }
    func test中文深色大字加载可以关闭() {
        let app = launch("vmm-console-loading", chinese: true, dark: true, large: true); defer { app.terminate() }; openConsole(app)
        XCTAssertTrue(element("virtual-machine.console.loading", app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["virtual-machine.console.close"].isHittable)
        screenshot("Chinese large dark virtual machine console loading")
        app.buttons["virtual-machine.console.close"].tap()
        XCTAssertTrue(app.buttons["virtual-machine.console.open"].waitForExistence(timeout: 6))
        screenshot("Chinese large dark virtual machine console closed")
    }
    func test中途断开不会自动重连() {
        let app = launch("vmm-console-disconnect"); defer { app.terminate() }; openConsole(app)
        XCTAssertTrue(element("virtual-machine.console.disconnected", app).waitForExistence(timeout: 10))
        screenshot("Virtual machine console disconnected after first frame")
        XCTAssertFalse(app.staticTexts["Synthetic console ready"].exists)
        app.buttons["virtual-machine.console.reconnect"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic console ready"].waitForExistence(timeout: 10))
        screenshot("Virtual machine console after manual reconnect")
    }
    func test停止的虚拟机不能打开控制台() {
        let app = launch("vmm-console-stopped"); defer { app.terminate() }
        XCTAssertFalse(app.buttons["virtual-machine.console.open"].isEnabled)
        screenshot("Stopped virtual machine console unavailable")
    }
    func test权限拒绝与身份变化提供准确恢复提示() {
        for (mode, state, message) in [
            ("vmm-console-denied", "accessDenied", "当前账号无法打开此控制台。请重新登录，或请管理员检查你的访问权限。"),
            ("vmm-console-trust", "trustRequired", "无法确认 NAS 的身份。请关闭控制台，重新连接 NAS 后再试。")
        ] {
            let app = launch(mode, chinese: true, dark: true, large: true)
            openConsole(app)
            XCTAssertTrue(element("virtual-machine.console.\(state)", app).waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts[message].exists)
            XCTAssertTrue(app.buttons["virtual-machine.console.close"].isHittable)
            screenshot("Chinese large console recovery \(state)")
            app.buttons["virtual-machine.console.close"].tap(); app.terminate()
        }
    }

    private func launch(_ mode: String = "vmm-console", chinese: Bool = false, dark: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en", "-lanstash.mobile.settings.appearance.v1", dark ? "dark" : "light"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = mode; app.launch()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        MobileUITestNavigation.open(app, destination: "settings", title: chinese ? "App 设置" : "App settings", test: self)
        MobileUITestNavigation.enableModule(app, module: "virtualMachines", test: self)
        MobileUITestNavigation.open(app, destination: "virtualMachines", title: chinese ? "虚拟机" : "Virtual machines", test: self)
        let section = element("virtual-machine.section.machines", app); XCTAssertTrue(section.waitForExistence(timeout: 10)); section.tap()
        let target = element("virtual-machine.item.synthetic-vm", app); XCTAssertTrue(target.waitForExistence(timeout: 8)); target.tap()
        XCTAssertTrue(app.buttons["virtual-machine.console.open"].waitForExistence(timeout: 8))
        return app
    }
    private func openConsole(_ app: XCUIApplication) {
        let button = app.buttons["virtual-machine.console.open"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: button)], timeout: 10), .completed)
        button.tap()
        XCTAssertTrue(app.buttons["virtual-machine.console.close"].waitForExistence(timeout: 8))
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func screenshot(_ name: String) { let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
}

import XCTest

@MainActor final class MobileVirtualMachineNetworkUITests: XCTestCase {
    func test网络详情改名搜索和完成记录() {
        let app = launch(); defer { app.terminate() }; openNetworks(app)
        screenshot("Virtual machine networks list light")
        element("virtual-machine.network.network-1", app).tap()
        XCTAssertTrue(app.staticTexts["Sample virtual machine"].waitForExistence(timeout: 6))
        screenshot("Virtual machine network detail and connected guest")
        app.buttons["virtual-machine.network.rename"].tap(); replaceName("Renamed network", app)
        screenshot("Virtual machine network rename form")
        waitEnabled(app.buttons["virtual-machine.network.save"]); app.buttons["virtual-machine.network.save"].tap()
        XCTAssertTrue(app.textFields["virtual-machine.network.name"].waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["Renamed network"].exists)
        app.navigationBars.buttons.firstMatch.tap(); openRecords(app)
        expectPhase("succeeded", app); XCTAssertTrue(app.staticTexts["Network renamed."].exists)
        screenshot("Virtual machine network rename completed")
        app.navigationBars.buttons.firstMatch.tap()
        let search = app.searchFields.firstMatch; XCTAssertTrue(search.waitForExistence(timeout: 6)); search.tap(); search.typeText("NoMatchingNetwork")
        XCTAssertTrue(element("virtual-machine.network.filtered-empty", app).waitForExistence(timeout: 6))
        screenshot("Virtual machine network filtered empty")
    }
    func test中文深色大字删除后果和取消() {
        let app = launch(chinese: true, dark: true, large: true); defer { app.terminate() }; openNetworks(app)
        element("virtual-machine.network.network-1", app).tap()
        reveal("virtual-machine.network.delete", app).tap()
        XCTAssertTrue(element("virtual-machine.network.confirmation", app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["删除这些网络可能使关联虚拟机断开连接，且无法撤销。虚拟机及其磁盘不会被删除。"].exists)
        XCTAssertTrue(app.staticTexts["Sample virtual machine"].exists)
        screenshot("Chinese large dark network deletion consequence")
        let cancel = app.buttons["virtual-machine.network.cancel"]; XCTAssertTrue(cancel.isHittable); cancel.tap()
        XCTAssertTrue(app.buttons["virtual-machine.network.delete"].waitForExistence(timeout: 6))
        screenshot("Chinese large dark network deletion cancelled")
        app.navigationBars.buttons.firstMatch.tap(); openRecords(app)
        XCTAssertTrue(app.staticTexts["暂无操作记录"].waitForExistence(timeout: 8))
    }
    func test网络多选第二项未知仍保留第一项成功() {
        let app = launch("vmm-network-partial"); defer { app.terminate() }; openNetworks(app)
        app.buttons["virtual-machine.network.selection"].tap()
        app.buttons["virtual-machine.network.select.network-1"].tap(); app.buttons["virtual-machine.network.select.network-2"].tap()
        app.buttons["virtual-machine.network.selection.delete"].tap()
        XCTAssertTrue(app.staticTexts["Networks: 2 · Virtual machines: 1"].waitForExistence(timeout: 6))
        screenshot("Virtual machine network batch delete confirmation")
        app.buttons["virtual-machine.network.confirm"].tap()
        XCTAssertTrue(app.buttons["virtual-machine.network.select.network-1"].waitForNonExistence(timeout: 15))
        app.buttons["virtual-machine.network.selection.done"].tap(); openRecords(app)
        expectPhase("succeeded", app); expectPhase("submitted", app)
        XCTAssertFalse(app.buttons["Remove Record"].exists)
        screenshot("Virtual machine network partial deletion retains both results")
    }
    func test改名丢回执重启后不允许重复操作() {
        let first = launch("vmm-network-unknown"); openNetworks(first); element("virtual-machine.network.network-1", first).tap()
        first.buttons["virtual-machine.network.rename"].tap(); replaceName("Renamed network", first)
        first.buttons["virtual-machine.network.save"].tap(); expectPhase("submitted", first)
        XCTAssertFalse(first.buttons["virtual-machine.network.save"].isEnabled)
        screenshot("Virtual machine network rename missing receipt"); first.terminate()
        let restored = launch(preserve: true); defer { restored.terminate() }; openNetworks(restored); openRecords(restored)
        expectPhase("submitted", restored); XCTAssertFalse(restored.buttons["Remove Record"].exists)
        screenshot("Virtual machine network missing receipt after restart")
        restored.navigationBars.buttons.firstMatch.tap(); element("virtual-machine.network.network-1", restored).tap()
        XCTAssertFalse(restored.buttons["virtual-machine.network.rename"].isEnabled)
        XCTAssertFalse(restored.buttons["virtual-machine.network.delete"].isEnabled)
    }
    func test已接受改名跨重启恢复且解除保护() {
        let first = launch("vmm-network-accepted-offline"); openNetworks(first); element("virtual-machine.network.network-1", first).tap()
        first.buttons["virtual-machine.network.rename"].tap(); replaceName("Renamed network", first)
        first.buttons["virtual-machine.network.save"].tap(); expectPhase("submitted", first)
        screenshot("Virtual machine network accepted before lost connection"); first.terminate()
        let restored = launch("vmm-network-renamed", preserve: true); defer { restored.terminate() }; openNetworks(restored); openRecords(restored)
        expectPhase("succeeded", restored); XCTAssertTrue(restored.staticTexts["Network renamed."].exists)
        screenshot("Virtual machine network accepted operation restored")
        restored.navigationBars.buttons.firstMatch.tap(); element("virtual-machine.network.network-1", restored).tap()
        waitEnabled(restored.buttons["virtual-machine.network.rename"])
    }
    func test网络加载空内容错误和冻结状态() {
        let loading = launch("vmm-network-loading"); openNetworks(loading, expectsList: false)
        XCTAssertTrue(element("virtual-machine.network.loading", loading).waitForExistence(timeout: 6))
        screenshot("Virtual machine networks loading"); loading.terminate()
        let empty = launch("vmm-network-empty"); openNetworks(empty, expectsList: false)
        XCTAssertTrue(element("virtual-machine.network.empty", empty).waitForExistence(timeout: 8))
        screenshot("Virtual machine networks empty with next step"); empty.terminate()
        let failed = launch("vmm-network-read-error"); openNetworks(failed, expectsList: false)
        XCTAssertTrue(element("virtual-machine.network.error", failed).waitForExistence(timeout: 8))
        screenshot("Virtual machine networks failed with refresh"); failed.terminate()
        let frozen = launch("vmm-network-frozen"); defer { frozen.terminate() }; openNetworks(frozen)
        XCTAssertFalse(frozen.buttons["virtual-machine.network.selection"].isEnabled)
        screenshot("Virtual machine networks frozen")
    }
    private func launch(_ mode: String = "vmm-network-success", preserve: Bool = false, chinese: Bool = false,
                        dark: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if preserve { app.launchArguments.append("--ui-preserve-transfer-fixture") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", dark ? "dark" : "light"]
        app.launchEnvironment["LANSTASH_UI_STATE"] = mode; app.launch()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        MobileUITestNavigation.open(app, destination: "settings", title: chinese ? "App 设置" : "App settings", test: self)
        MobileUITestNavigation.enableModule(app, module: "virtualMachines", test: self)
        MobileUITestNavigation.open(app, destination: "virtualMachines", title: chinese ? "虚拟机" : "Virtual machines", test: self)
        return app
    }
    private func openNetworks(_ app: XCUIApplication, expectsList: Bool = true) {
        let section = element("virtual-machine.section.networks", app); XCTAssertTrue(section.waitForExistence(timeout: 8)); section.tap()
        if expectsList { XCTAssertTrue(element("virtual-machine.network.list", app).waitForExistence(timeout: 10)) }
    }
    private func openRecords(_ app: XCUIApplication) {
        let link = element("virtual-machine.network.records.toolbar", app); XCTAssertTrue(link.waitForExistence(timeout: 8)); link.tap()
        XCTAssertTrue(element("virtual-machine.network.records", app).waitForExistence(timeout: 8))
    }
    private func replaceName(_ name: String, _ app: XCUIApplication) {
        let field = app.textFields["virtual-machine.network.name"]; XCTAssertTrue(field.waitForExistence(timeout: 6))
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.8)).tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ OR value == %@", "", field.placeholderValue ?? ""), object: field)], timeout: 6), .completed)
        field.typeText(name)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", name), object: field)], timeout: 6), .completed)
        if app.frame.width > 600, app.popovers.firstMatch.exists {
            app.navigationBars.containing(.button, identifier: "virtual-machine.network.cancel").firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let done = app.buttons["virtual-machine.network.keyboardDone"]; if done.exists && done.isHittable { done.tap() }
    }
    private func expectPhase(_ phase: String, _ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["virtual-machine.network.record.\(phase)"].firstMatch.waitForExistence(timeout: 15))
    }
    private func waitEnabled(_ value: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: value)], timeout: 15), .completed)
        XCTAssertTrue(value.isEnabled)
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func reveal(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let value = element(id, app)
        for _ in 0..<8 {
            if value.exists && value.isHittable { return value }
            app.swipeUp()
        }
        XCTFail("网络操作不可见：\(id)"); return value
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

import XCTest

@MainActor final class MobileVirtualMachineCreationUITests: XCTestCase {
    func test分步创建保留精确内存并显示完成记录() {
        let app = launch(); defer { app.terminate() }; openCreation(app)
        XCTAssertFalse(app.buttons["virtual-machine.creation.next"].isEnabled)
        replace("name", "New sample machine", app); screenshot("Virtual machine creation name and system light")
        next(app); XCTAssertEqual(app.textFields["virtual-machine.creation.memory"].value as? String, "512")
        XCTAssertEqual(app.textFields["virtual-machine.creation.memory"].label, "Memory (MiB)")
        replace("memory", "768", app); screenshot("Virtual machine creation exact memory and disk")
        next(app); screenshot("Virtual machine creation disconnected network and startup options")
        next(app); XCTAssertTrue(app.staticTexts["virtual-machine.creation.risk"].isHittable)
        screenshot("Virtual machine creation final configuration and storage effect")
        let submit = app.buttons["virtual-machine.creation.submit"]; waitEnabled(submit); submit.tap()
        XCTAssertTrue(app.collectionViews["virtual-machine.creation.form"].waitForNonExistence(timeout: 15))
        openRecords(app); expectPhase("succeeded", app)
        XCTAssertTrue(app.staticTexts["Virtual machine created."].exists); screenshot("Virtual machine creation completed record")
    }
    func test中文大字深色选项与创建前取消不写入() {
        let app = launch(chinese: true, large: true, dark: true); defer { app.terminate() }; openCreation(app)
        replace("name", "New sample machine", app)
        choose("system", "Microsoft Windows", app); screenshot("Chinese large dark virtual machine creation basics")
        next(app); next(app)
        choose("network", "Sample network", app); choose("image", "Sample installer.iso", app)
        choose("firmware", "UEFI", app); choose("startup", "恢复原状态", app)
        screenshot("Chinese large dark virtual machine creation options")
        next(app); waitEnabled(app.buttons["virtual-machine.creation.submit"])
        XCTAssertTrue(app.staticTexts["virtual-machine.creation.risk"].isHittable)
        screenshot("Chinese large dark virtual machine creation summary")
        app.buttons["virtual-machine.creation.cancel"].tap()
        openRecords(app); XCTAssertTrue(app.staticTexts["暂无操作记录"].waitForExistence(timeout: 8))
    }
    func test创建丢回执重启后保留记录并阻止重复名称() {
        let first = launch("vmm-create-unknown"); openCreation(first); fillDefaults(first)
        first.buttons["virtual-machine.creation.submit"].tap(); expectPhase("submitted", first)
        waitEnabled(first.buttons["virtual-machine.creation.cancel"])
        XCTAssertFalse(first.buttons["virtual-machine.creation.submit"].isEnabled)
        screenshot("Virtual machine creation unknown result"); first.terminate()
        let restored = launch("vmm-create-unknown", preserve: true); defer { restored.terminate() }
        openRecords(restored); expectPhase("submitted", restored)
        XCTAssertFalse(restored.buttons["Remove Record"].exists); screenshot("Virtual machine creation unknown restored record")
        restored.navigationBars.buttons.firstMatch.tap(); openCreation(restored)
        replace("name", "New sample machine", restored)
        XCTAssertFalse(restored.buttons["virtual-machine.creation.next"].isEnabled)
        screenshot("Virtual machine creation name remains protected after restart")
    }
    func test创建接受后断网重启仍保留原操作() {
        let first = launch("vmm-create-accepted-offline"); openCreation(first); fillDefaults(first)
        first.buttons["virtual-machine.creation.submit"].tap(); expectPhase("submitted", first)
        waitEnabled(first.buttons["virtual-machine.creation.cancel"])
        screenshot("Virtual machine creation accepted before connection loss"); first.terminate()
        let restored = launch("vmm-create-missing-task", preserve: true); defer { restored.terminate() }
        openRecords(restored); expectPhase("submitted", restored)
        XCTAssertTrue(restored.staticTexts["Creation has been accepted. Refresh the operation records later to see the result."].exists)
        XCTAssertFalse(restored.buttons["Remove Record"].exists); screenshot("Virtual machine creation accepted record survives missing task")
    }
    func test创建资源加载空内容和错误均可恢复或关闭() {
        let loading = launch("vmm-create-loading"); openCreation(loading, expectsForm: false)
        XCTAssertTrue(element("virtual-machine.creation.loading", loading).waitForExistence(timeout: 6))
        screenshot("Virtual machine creation resources loading"); loading.buttons["virtual-machine.creation.cancel"].tap(); loading.terminate()
        let empty = launch("vmm-create-empty"); openCreation(empty, expectsForm: false)
        XCTAssertTrue(element("virtual-machine.creation.error", empty).waitForExistence(timeout: 8))
        XCTAssertTrue(empty.staticTexts["No available virtual machine storage was found. Add or restore storage in Virtual Machine Manager, then refresh."].exists)
        screenshot("Virtual machine creation no available storage"); empty.buttons["virtual-machine.creation.cancel"].tap(); empty.terminate()
        let failed = launch("vmm-create-read-error"); defer { failed.terminate() }; openCreation(failed, expectsForm: false)
        XCTAssertTrue(element("virtual-machine.creation.error", failed).waitForExistence(timeout: 8))
        waitEnabled(failed.buttons["virtual-machine.creation.retry"]); screenshot("Virtual machine creation resource error and retry")
        failed.buttons["virtual-machine.creation.retry"].tap()
        XCTAssertTrue(element("virtual-machine.creation.error", failed).waitForExistence(timeout: 8))
    }
    func test创建明确拒绝显示失败且不伪装完成() {
        let app = launch("vmm-create-reject"); defer { app.terminate() }; openCreation(app); fillDefaults(app)
        app.buttons["virtual-machine.creation.submit"].tap(); expectPhase("failed", app)
        XCTAssertFalse(element("virtual-machine.creation.result.succeeded", app).exists)
        screenshot("Virtual machine creation rejected with recovery guidance")
    }
    private func launch(_ mode: String = "vmm-create-success", preserve: Bool = false, chinese: Bool = false,
                        large: Bool = false, dark: Bool = false) -> XCUIApplication {
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
    private func openCreation(_ app: XCUIApplication, expectsForm: Bool = true) {
        let button = app.buttons["virtual-machine.creation.open"]; waitEnabled(button); button.tap()
        if expectsForm { XCTAssertTrue(app.collectionViews["virtual-machine.creation.form"].waitForExistence(timeout: 10)) }
    }
    private func next(_ app: XCUIApplication) { let button = app.buttons["virtual-machine.creation.next"]; waitEnabled(button); button.tap() }
    private func fillDefaults(_ app: XCUIApplication) {
        replace("name", "New sample machine", app); next(app); next(app); next(app); waitEnabled(app.buttons["virtual-machine.creation.submit"])
    }
    private func choose(_ key: String, _ option: String, _ app: XCUIApplication) {
        reveal("virtual-machine.creation.\(key)", app).tap()
        let choice = app.buttons[option]; XCTAssertTrue(choice.waitForExistence(timeout: 6)); choice.tap()
    }
    private func replace(_ key: String, _ text: String, _ app: XCUIApplication) {
        let field = reveal("virtual-machine.creation.\(key)", app)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.8)).tap()
        let previous = field.value as? String ?? "", placeholder = field.placeholderValue ?? ""
        if previous != placeholder { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count)) }
        let empty = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ OR value == %@", "", placeholder), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 6), .completed)
        field.typeText(text)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)], timeout: 6), .completed)
        if app.frame.width > 600, app.popovers.firstMatch.exists {
            app.navigationBars.containing(.button, identifier: "virtual-machine.creation.cancel").firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        }
        let done = app.buttons["virtual-machine.creation.keyboardDone"]; if done.exists && done.isHittable { done.tap() }
        XCTAssertEqual(field.value as? String, text)
    }
    private func openRecords(_ app: XCUIApplication) {
        let root = element("virtual-machine.records.open", app); XCTAssertTrue(root.waitForExistence(timeout: 8)); root.tap()
        XCTAssertTrue(element("virtual-machine.records", app).waitForExistence(timeout: 8))
    }
    private func expectPhase(_ phase: String, _ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["virtual-machine.creation.result.\(phase)"].waitForExistence(timeout: 15))
    }
    private func waitEnabled(_ value: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: value)
        let result = XCTWaiter.wait(for: [ready], timeout: 15)
        if result != .completed { failureEvidence() }
        XCTAssertEqual(result, .completed)
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func reveal(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let list = app.collectionViews["virtual-machine.creation.form"], value = element(id, app)
        for _ in 0..<14 {
            if value.exists, !value.frame.isEmpty, value.frame.midY > max(100, list.frame.minY + 20),
               value.frame.midY < min(list.frame.maxY - 10, app.frame.maxY - 70), value.isHittable { return value }
            let down = value.exists && value.frame.minY < list.frame.minY + 20
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: down ? 0.3 : 0.8)).press(forDuration: 0.1,
                thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: down ? 0.8 : 0.3)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        failureEvidence(); XCTFail("创建表单控件不可操作：\(id)"); return value
    }
    private func failureEvidence() {
        let tree = XCTAttachment(string: XCUIApplication().debugDescription); tree.name = "Virtual machine creation control hierarchy"; tree.lifetime = .keepAlways; add(tree)
        screenshot("Virtual machine creation control unavailable")
    }
    private func screenshot(_ name: String) {
        let value = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value)
    }
}

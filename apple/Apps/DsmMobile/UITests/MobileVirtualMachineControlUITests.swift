import XCTest

@MainActor final class MobileVirtualMachineControlUITests: XCTestCase {
    func test普通套件账号开机并查看逐项结果() {
        let app = launch(); defer { app.terminate() }; detail("synthetic-vm", app)
        let power = reveal("virtual-machine.action.powerOn", app); waitEnabled(power)
        screenshot("Virtual machine controls in light appearance"); power.tap()
        XCTAssertTrue(app.staticTexts["Sample virtual machine"].exists)
        screenshot("Virtual machine power-on confirmation")
        reveal("virtual-machine.confirm", app).tap(); openRecords(app); expectPhase("succeeded", app)
        XCTAssertTrue(app.staticTexts["Powered on"].exists); screenshot("Virtual machine power-on result")
    }
    func test删除取消保留目标随后删除仍能查看记录() {
        let app = launch(); defer { app.terminate() }; detail("synthetic-vm", app)
        reveal("virtual-machine.action.delete", app).tap()
        XCTAssertTrue(app.staticTexts["Deleting these virtual machines permanently removes their virtual disks and the data stored on them. This cannot be undone."].exists)
        screenshot("Virtual machine deletion warns about virtual disks")
        app.buttons["Cancel"].tap(); XCTAssertTrue(app.collectionViews["virtual-machine.confirmation"].waitForNonExistence(timeout: 6))
        waitEnabled(reveal("virtual-machine.action.delete", app))
        reveal("virtual-machine.action.delete", app).tap(); reveal("virtual-machine.confirm", app).tap()
        openRecords(app); expectPhase("succeeded", app)
        XCTAssertTrue(app.staticTexts["Deleted"].exists); screenshot("Deleted virtual machine retains accessible result")
    }
    func test多项删除固定目标与独立结果() {
        let app = launch(); defer { app.terminate() }
        let select = app.buttons["virtual-machine.selection"]; waitEnabled(select); select.tap()
        reveal("virtual-machine.select.synthetic-vm", app).tap(); reveal("virtual-machine.select.worker-b", app).tap()
        reveal("virtual-machine.action.delete", app).tap()
        XCTAssertTrue(app.staticTexts["Sample virtual machine"].exists); XCTAssertTrue(app.staticTexts["Worker B"].exists)
        screenshot("Two virtual machine deletion confirmation")
        reveal("virtual-machine.confirm", app).tap(); app.buttons["Done"].tap(); openRecords(app)
        let completed = app.cells.containing(.any, identifier: "virtual-machine.record.succeeded")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: completed)], timeout: 12), .completed)
        screenshot("Two virtual machines deleted with individual results")
    }
    func test丢回执跨重启保持未知且状态吻合仍不重发() {
        let first = launch("vmm-unknown"); detail("synthetic-vm", first)
        reveal("virtual-machine.action.powerOn", first).tap(); reveal("virtual-machine.confirm", first).tap()
        openRecords(first); expectPhase("submitted", first); screenshot("Power result unavailable after lost response"); first.terminate()
        let next = launch("vmm-recover", preserve: true); defer { next.terminate() }; openRecords(next)
        expectPhase("submitted", next); XCTAssertFalse(next.buttons["Remove Record"].exists)
        screenshot("Observed running state does not claim lost-response success")
    }
    func test已接受后离线重启只读恢复完成() {
        let first = launch("vmm-accepted-offline"); detail("synthetic-vm", first)
        reveal("virtual-machine.action.powerOn", first).tap(); reveal("virtual-machine.confirm", first).tap()
        openRecords(first); expectPhase("submitted", first); first.terminate()
        let next = launch("vmm-recover", preserve: true); defer { next.terminate() }; openRecords(next)
        expectPhase("succeeded", next); XCTAssertTrue(next.staticTexts["Powered on"].exists)
        screenshot("Accepted power operation restored without resubmission")
    }
    func test内部重启只显示接受且阻止重复操作() {
        let app = launch("vmm-restart"); defer { app.terminate() }; detail("synthetic-vm", app)
        reveal("virtual-machine.action.restart", app).tap(); reveal("virtual-machine.confirm", app).tap()
        openRecords(app); expectPhase("submitted", app)
        XCTAssertTrue(app.staticTexts["The restart request was accepted. Its completion status is not available; view the virtual machine in Virtual Machine Manager."].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["Remove Record"].exists); screenshot("Restart acceptance remains distinct from completion")
    }
    func test中文大字深色强制断电确认与取消可用() {
        let app = launch("vmm-running", chinese: true, large: true, dark: true); defer { app.terminate() }; detail("synthetic-vm", app)
        reveal("virtual-machine.action.powerOff", app).tap(); waitEnabled(reveal("virtual-machine.confirm", app))
        XCTAssertTrue(app.staticTexts["强制断电会立即中断这些虚拟机，可能丢失未保存的数据或损坏虚拟磁盘。"].exists)
        screenshot("Chinese large text dark forced power-off warning")
        app.buttons["取消"].tap(); XCTAssertTrue(app.collectionViews["virtual-machine.confirmation"].waitForNonExistence(timeout: 6))
        waitEnabled(reveal("virtual-machine.action.shutdown", app))
    }
    func test旋转后详情和关机确认保持可用() {
        let app = launch("vmm-running"); defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }; detail("synthetic-vm", app)
        XCUIDevice.shared.orientation = .landscapeLeft; waitEnabled(reveal("virtual-machine.action.shutdown", app))
        screenshot("Landscape virtual machine controls")
        XCUIDevice.shared.orientation = .portrait; reveal("virtual-machine.action.shutdown", app).tap()
        waitEnabled(reveal("virtual-machine.confirm", app)); screenshot("Virtual machine shutdown confirmation after rotation")
        // 云端旋转后短点击未关闭确认页；明确按下/抬起一次，不重试危险操作。
        app.buttons["Cancel"].press(forDuration: 0.15); XCTAssertTrue(app.collectionViews["virtual-machine.confirmation"].waitForNonExistence(timeout: 6))
    }
    func test加载空列表恢复与筛选五态() {
        let loading = launch("vmm-loading"); XCTAssertTrue(element("virtual-machine.loading", loading).waitForExistence(timeout: 8)); screenshot("Virtual machines loading"); loading.terminate()
        let empty = launch("vmm-empty"); section(empty)
        XCTAssertTrue(empty.staticTexts["No Virtual Machines"].waitForExistence(timeout: 8)); screenshot("Empty virtual machine list"); empty.terminate()
        let retry = launch("vmm-retry"); section(retry)
        let button = retry.buttons["Try Again"]; XCTAssertTrue(button.waitForExistence(timeout: 8)); screenshot("Virtual machine read failure recovery"); button.tap()
        XCTAssertTrue(element("virtual-machine.item.synthetic-vm", retry).waitForExistence(timeout: 10))
        reveal("virtual-machine.filter", retry).tap(); retry.buttons["Needs Attention"].tap()
        XCTAssertTrue(retry.buttons["Show All"].waitForExistence(timeout: 6)); screenshot("Virtual machine filter has no results")
        retry.buttons["Show All"].tap(); XCTAssertTrue(element("virtual-machine.item.synthetic-vm", retry).exists); retry.terminate()
    }
    func test编辑名称说明与精确内存保存后显示记录() {
        let app = launch("vmm-settings"); defer { app.terminate() }; openSettings(app)
        XCTAssertEqual(app.textFields["virtual-machine.settings.memory"].value as? String, "512")
        XCTAssertFalse(app.buttons["virtual-machine.settings.save"].isEnabled)
        screenshot("Virtual machine edit settings light appearance")
        replaceSetting("name", "Updated virtual machine", app)
        replaceSetting("description", "Updated synthetic description", app)
        replaceSetting("memory", "768", app)
        waitEnabled(app.buttons["virtual-machine.settings.save"]); screenshot("Virtual machine edit exact memory and changed fields")
        app.buttons["virtual-machine.settings.save"].tap()
        XCTAssertTrue(app.collectionViews["virtual-machine.settings.form"].waitForNonExistence(timeout: 12))
        openRecords(app); expectPhase("succeeded", app)
        XCTAssertTrue(app.staticTexts["Changes saved"].exists); screenshot("Virtual machine settings saved result")
    }
    func test编辑中文大字深色运行中硬件禁用与取消() {
        let app = launch("vmm-settings-running", chinese: true, large: true, dark: true); defer { app.terminate() }; openSettings(app)
        XCTAssertFalse(reveal("virtual-machine.settings.cpu", app).isEnabled)
        XCTAssertFalse(reveal("virtual-machine.settings.memory", app).isEnabled)
        XCTAssertTrue(app.staticTexts["修改 CPU 核心数或内存前，请先关闭虚拟机。"].exists)
        screenshot("Chinese large dark running virtual machine settings")
        reveal("virtual-machine.settings.priority", app).tap()
        XCTAssertTrue(app.buttons["高"].waitForExistence(timeout: 6)); app.buttons["高"].tap()
        reveal("virtual-machine.settings.startup", app).tap()
        XCTAssertTrue(app.buttons["恢复原状态"].waitForExistence(timeout: 6)); app.buttons["恢复原状态"].tap()
        waitEnabled(app.buttons["virtual-machine.settings.save"]); screenshot("Chinese priority and startup selections")
        app.buttons["virtual-machine.settings.cancel"].tap()
        XCTAssertTrue(app.collectionViews["virtual-machine.settings.form"].waitForNonExistence(timeout: 6))
        openRecords(app); XCTAssertTrue(app.staticTexts["暂无操作记录"].waitForExistence(timeout: 8))
    }
    func test编辑丢回执跨重启仍保护原目标() {
        let first = launch("vmm-settings-unknown"); openSettings(first)
        replaceSetting("description", "Updated synthetic description", first); first.buttons["virtual-machine.settings.save"].tap()
        XCTAssertTrue(first.staticTexts["virtual-machine.settings.result"].waitForExistence(timeout: 12))
        XCTAssertFalse(first.buttons["virtual-machine.settings.save"].isEnabled)
        screenshot("Virtual machine edit result unavailable after lost response"); first.terminate()
        let next = launch("vmm-settings-recovered", preserve: true); defer { next.terminate() }
        detail("synthetic-vm", next)
        XCTAssertFalse(reveal("virtual-machine.action.edit", next).isEnabled)
        XCTAssertFalse(reveal("virtual-machine.action.delete", next).isEnabled)
        openRecords(next); expectPhase("submitted", next)
        XCTAssertFalse(next.buttons["Remove Record"].exists); screenshot("Virtual machine edit lost response remains protected")
    }
    func test编辑接受后断网跨重启只读恢复() {
        let first = launch("vmm-settings-accepted-offline"); openSettings(first)
        replaceSetting("description", "Updated synthetic description", first); first.buttons["virtual-machine.settings.save"].tap()
        XCTAssertTrue(first.staticTexts["virtual-machine.settings.result"].waitForExistence(timeout: 12)); first.terminate()
        let next = launch("vmm-settings-recovered", preserve: true); defer { next.terminate() }; openRecords(next)
        expectPhase("succeeded", next); XCTAssertTrue(next.staticTexts["Changes saved"].exists)
        screenshot("Virtual machine edit accepted result restored")
    }
    func test编辑读取加载与错误可关闭重试() {
        let loading = launch("vmm-settings-loading"); detail("synthetic-vm", loading)
        reveal("virtual-machine.action.edit", loading).tap()
        XCTAssertTrue(element("virtual-machine.settings.loading", loading).waitForExistence(timeout: 6)); screenshot("Virtual machine settings loading")
        loading.buttons["virtual-machine.settings.cancel"].tap(); loading.terminate()
        let failed = launch("vmm-settings-error"); defer { failed.terminate() }; detail("synthetic-vm", failed)
        reveal("virtual-machine.action.edit", failed).tap()
        XCTAssertTrue(element("virtual-machine.settings.error", failed).waitForExistence(timeout: 8))
        waitEnabled(failed.buttons["virtual-machine.settings.retry"]); screenshot("Virtual machine settings read error recovery")
        failed.buttons["virtual-machine.settings.retry"].tap()
        XCTAssertTrue(element("virtual-machine.settings.error", failed).waitForExistence(timeout: 8))
        failed.buttons["virtual-machine.settings.cancel"].tap()
    }
    private func openSettings(_ app: XCUIApplication) {
        detail("synthetic-vm", app); reveal("virtual-machine.action.edit", app).tap()
        XCTAssertTrue(app.collectionViews["virtual-machine.settings.form"].waitForExistence(timeout: 10))
    }
    private func replaceSetting(_ key: String, _ text: String, _ app: XCUIApplication) {
        let field = reveal("virtual-machine.settings.\(key)", app)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.8)).tap()
        let previous = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        // 键盘事件返回后文本仍可能在变化，等到实际清空后再继续输入，保留完整值断言。
        let empty = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ OR value == %@", "", field.placeholderValue ?? ""), object: field)
        let cleared = XCTWaiter.wait(for: [empty], timeout: 6)
        if cleared != .completed { screenshot("Virtual machine setting did not finish clearing") }
        XCTAssertEqual(cleared, .completed, "输入框未清空：\(field.value as? String ?? "")")
        field.typeText(text)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)], timeout: 6), .completed)
        if app.frame.width > 600, app.popovers.firstMatch.exists {
            app.navigationBars.containing(.button, identifier: "virtual-machine.settings.save").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
            XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        }
        let done = app.buttons["virtual-machine.settings.keyboardDone"]; if done.exists && done.isHittable { done.tap() }
        XCTAssertEqual(field.value as? String, text)
    }
    private func launch(_ mode: String = "vmm-control", preserve: Bool = false, chinese: Bool = false,
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
    private func section(_ app: XCUIApplication) {
        let value = element("virtual-machine.section.machines", app); XCTAssertTrue(value.waitForExistence(timeout: 12)); value.tap()
    }
    private func detail(_ id: String, _ app: XCUIApplication) {
        section(app); let value = element("virtual-machine.item.\(id)", app)
        XCTAssertTrue(value.waitForExistence(timeout: 8)); value.tap()
        XCTAssertTrue(app.collectionViews["virtual-machine.detail"].waitForExistence(timeout: 8))
    }
    private func openRecords(_ app: XCUIApplication) {
        let detail = element("virtual-machine.detail.records", app)
        if detail.exists { reveal("virtual-machine.detail.records", app).tap() }
        else { let root = element("virtual-machine.records.open", app); XCTAssertTrue(root.waitForExistence(timeout: 8)); root.tap() }
        XCTAssertTrue(element("virtual-machine.records", app).waitForExistence(timeout: 8))
    }
    private func expectPhase(_ phase: String, _ app: XCUIApplication) { XCTAssertTrue(element("virtual-machine.record.\(phase)", app).waitForExistence(timeout: 12)) }
    private func waitEnabled(_ value: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: value)
        let result = XCTWaiter.wait(for: [ready], timeout: 12)
        if result != .completed {
            let tree = XCTAttachment(string: XCUIApplication().debugDescription); tree.name = "Virtual machine unavailable control hierarchy"; tree.lifetime = .keepAlways; add(tree)
            screenshot("Virtual machine expected control is unavailable")
        }
        XCTAssertEqual(result, .completed)
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    @discardableResult private func reveal(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let list = ["virtual-machine.settings.form", "virtual-machine.confirmation", "virtual-machine.selection.list", "virtual-machine.detail", "virtual-machine.items"].map { app.collectionViews[$0] }.first { $0.exists } ?? app.collectionViews.firstMatch
        let value = element(id, app)
        if !list.exists { waitEnabled(value); return value }
        for _ in 0..<14 {
            if value.exists, !value.frame.isEmpty, value.frame.midY > max(100, list.frame.minY + 20),
               value.frame.midY < min(list.frame.maxY - 10, app.frame.maxY - 35), value.isHittable || !value.isEnabled { return value }
            let down = value.exists && value.frame.minY < list.frame.minY + 20
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: down ? 0.3 : 0.8)).press(forDuration: 0.1,
                thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: down ? 0.8 : 0.3)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "Virtual machine hierarchy"; tree.lifetime = .keepAlways; add(tree)
        screenshot("Virtual machine control unavailable"); XCTFail("控件不可操作：\(id)"); return value
    }
    private func screenshot(_ name: String) {
        let value = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value)
    }
}

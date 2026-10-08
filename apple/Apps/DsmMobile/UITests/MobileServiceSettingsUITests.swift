import XCTest

@MainActor
final class MobileServiceSettingsUITests: XCTestCase {
    func test硬件五组编辑确认取消与保存结果() {
        let app = launch("nas-services", kind: "hardware"); defer { app.terminate() }
        screenshot(app, "Hardware current settings"); openEditor(app)
        reveal("mobile.nas.hardware.powerRecovery", in: app).switches.firstMatch.tap()
        increaseBrightness(app)
        reveal("mobile.nas.hardware.fan", in: app).tap()
        let cool = app.buttons["cool mode"]; XCTAssertTrue(cool.waitForExistence(timeout: 5)); cool.tap()
        reveal("mobile.nas.hardware.volumeFailure", in: app).switches.firstMatch.tap()
        reveal("mobile.nas.hardware.wakeLog", in: app).switches.firstMatch.tap()
        screenshot(app, "Hardware sound and sleep controls")
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "starts automatically")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "Hardware concrete risks and selected values")
        element("mobile.nas.service.cancel", app).tap()
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap(); waitEditorClosed(app)
        expect(reveal("mobile.nas.hardware.summary.powerRecovery", in: app), contains: "On")
        expect(reveal("mobile.nas.hardware.summary.brightness", in: app), contains: "5")
        expect(reveal("mobile.nas.hardware.summary.fan", in: app), contains: "cool mode")
        expect(reveal("mobile.nas.hardware.summary.volumeFailure", in: app), contains: "Off")
        expect(reveal("mobile.nas.hardware.summary.wakeLog", in: app), contains: "On")
        expect(reveal("mobile.nas.service.activity.succeeded", in: app), contains: "saved")
        screenshot(app, "Hardware all changed groups saved")
    }
    func testUPS网络连接等待时间校验及保存() {
        let app = launch("nas-services", kind: "hardware"); defer { app.terminate() }; openEditor(app)
        reveal("mobile.nas.hardware.upsEnabled", in: app).switches.firstMatch.tap()
        reveal("mobile.nas.hardware.upsMode", in: app).tap()
        let mode = app.buttons["Network UPS server"]; XCTAssertTrue(mode.waitForExistence(timeout: 5)); mode.tap()
        XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        let address = app.textFields["mobile.nas.hardware.upsNetwork"]; _ = reveal("mobile.nas.hardware.upsNetwork", in: app)
        address.tap(); address.typeText("192.0.2.20"); finishTextEditing(app)
        XCTAssertEqual(address.value as? String, "192.0.2.20")
        replace("upsDelay", text: "604801", app, prefix: "mobile.nas.hardware", separateLabel: true)
        XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        replace("upsDelay", text: "180", app, prefix: "mobile.nas.hardware", separateLabel: true)
        reveal("mobile.nas.hardware.upsShutdown", in: app).switches.firstMatch.tap()
        screenshot(app, "UPS native configuration")
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "leave data unprotected")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "UPS protection risk and chosen connection")
        element("mobile.nas.service.confirm", app).tap(); waitEditorClosed(app)
        expect(reveal("mobile.nas.hardware.summary.upsEnabled", in: app), contains: "On")
        expect(reveal("mobile.nas.hardware.summary.upsMode", in: app), contains: "Network UPS server")
        expect(reveal("mobile.nas.hardware.summary.upsDelay", in: app), contains: "180")
        expect(reveal("mobile.nas.hardware.summary.upsNetwork", in: app), contains: "192.0.2.20")
        screenshot(app, "UPS saved configuration")
    }
    func test灯光单独保存直接完成且无需额外确认() {
        let app = launch("nas-services", kind: "hardware"); defer { app.terminate() }
        openEditor(app); increaseBrightness(app); app.buttons["mobile.nas.service.save"].tap()
        XCTAssertFalse(element("mobile.nas.service.confirm", app).exists); waitEditorClosed(app)
        expect(reveal("mobile.nas.hardware.summary.brightness", in: app), contains: "5")
        expect(reveal("mobile.nas.service.activity.succeeded", in: app), contains: "saved")
        screenshot(app, "Indicator brightness saved without an extra confirmation")
    }
    func test灯光应用被拒绝后可明确继续而不重新设置亮度() {
        let app = launch("nas-services-hardware-led-denied-once", kind: "hardware"); defer { app.terminate() }
        openEditor(app); increaseBrightness(app)
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertFalse(element("mobile.nas.service.confirm", app).exists)
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "permission")
        element("mobile.nas.service.done", app).tap(); waitEditorClosed(app)
        screenshot(app, "Indicator brightness saved with application refused")
        reveal("mobile.nas.hardware.continueLED", in: app).tap()
        XCTAssertTrue(element("mobile.nas.hardware.continueLED", app).waitForNonExistence(timeout: 5))
        XCTAssertFalse(element("mobile.nas.service.confirm", app).exists)
        XCTAssertFalse(element("mobile.nas.hardware.continueLED", app).exists)
        expect(reveal("mobile.nas.service.activity.succeeded", in: app), contains: "saved")
        screenshot(app, "Indicator application completed explicitly")
    }
    func test灯光应用缺回执重启仍保护并提供刷新() {
        let app = launch("nas-services-hardware-led-update-unknown", kind: "hardware"); openEditor(app); increaseBrightness(app)
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertFalse(element("mobile.nas.service.confirm", app).exists)
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "Use DSM"); app.terminate()
        let next = launch("nas-services-hardware-led-recover", kind: "hardware", preserve: true); defer { next.terminate() }
        XCTAssertFalse(reveal("mobile.nas.service.edit", in: next).isEnabled)
        XCTAssertFalse(element("mobile.nas.hardware.continueLED", next).exists)
        expect(reveal("mobile.nas.service.activity.submitted", in: next), contains: "Use DSM")
        reveal("mobile.nas.service.recover", in: next).tap()
        expect(reveal("mobile.nas.service.activity.submitted", in: next), contains: "Use DSM")
        XCTAssertFalse(element("mobile.nas.service.removeRecord", next).exists)
        screenshot(next, "Indicator missing receipt remains protected after restart")
    }
    func test灯光接受后断线重启只恢复保存状态且主动应用() {
        let app = launch("nas-services-accepted-offline", kind: "hardware"); openEditor(app); increaseBrightness(app)
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertFalse(element("mobile.nas.service.confirm", app).exists)
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "not available yet"); app.terminate()
        let next = launch("nas-services-hardware-led-recover", kind: "hardware", preserve: true); defer { next.terminate() }
        _ = reveal("mobile.nas.hardware.continueLED", in: next)
        expect(reveal("mobile.nas.hardware.summary.brightness", in: next), contains: "5")
        screenshot(next, "Saved indicator brightness can be applied explicitly")
        reveal("mobile.nas.hardware.continueLED", in: next).tap()
        XCTAssertFalse(element("mobile.nas.service.confirm", next).exists)
        expect(reveal("mobile.nas.service.activity.succeeded", in: next), contains: "saved")
    }
    func test硬件加载空内容错误与不支持分别显示() {
        for (state, label) in [("nas-services-loading", "Loading settings"), ("nas-services-empty", "No settings"),
                               ("nas-services-error", "Unable to load"), ("nas-services-hardware-incomplete", "Unable to load"),
                               ("nas-services-unsupported", "not supported")] {
            let app = launch(state, kind: "hardware")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(element("mobile.nas.service.edit", app).exists)
            screenshot(app, "Hardware state " + state); app.terminate()
        }
    }
    func test硬件未知范围保持只读且账号权限限制可见() {
        let limited = launch("nas-services-hardware-limited", kind: "hardware"); openEditor(limited)
        XCTAssertFalse(limited.steppers["mobile.nas.hardware.brightness"].exists)
        XCTAssertTrue(limited.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "supported range")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(element("mobile.nas.hardware.fan", limited).exists)
        XCTAssertFalse(element("mobile.nas.hardware.resetSound", limited).exists)
        screenshot(limited, "Hardware missing device ranges remains readable"); limited.terminate()
        let readOnly = launch("nas-services-readonly", kind: "hardware"); defer { readOnly.terminate() }
        XCTAssertFalse(reveal("mobile.nas.service.edit", in: readOnly).isEnabled)
        expect(reveal("mobile.nas.service.error", in: readOnly), contains: "permission")
        screenshot(readOnly, "Hardware permissions prevent changes")
    }
    func test硬件中文大字表单风险和取消均可触达() {
        let app = launch("nas-services", kind: "hardware", chinese: true, large: true); defer { app.terminate() }; openEditor(app)
        reveal("mobile.nas.hardware.powerRecovery", in: app).switches.firstMatch.tap()
        screenshot(app, "Chinese large Hardware form")
        reveal("mobile.nas.hardware.upsEnabled", in: app).switches.firstMatch.tap()
        replace("upsDelay", text: "180", app, prefix: "mobile.nas.hardware", separateLabel: true)
        screenshot(app, "Chinese large UPS controls")
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertTrue(element("mobile.nas.service.confirm", app).waitForExistence(timeout: 5))
        screenshot(app, "Chinese large Hardware protection warning")
        element("mobile.nas.service.cancel", app).tap(); element("mobile.nas.service.done", app).tap(); waitEditorClosed(app)
        XCTAssertFalse(element("mobile.nas.service.activity.succeeded", app).exists)
    }
    private func increaseBrightness(_ app: XCUIApplication) {
        _ = reveal("mobile.nas.hardware.brightness", in: app)
        let stepper = app.steppers["mobile.nas.hardware.brightness"]
        XCTAssertTrue(stepper.exists); stepper.buttons.element(boundBy: 1).tap(); stepper.buttons.element(boundBy: 1).tap()
    }

    func test安全四组编辑输入校验风险取消及完整保存() {
        let app = launch("nas-services", kind: "security"); defer { app.terminate() }
        screenshot(app, "Security current configuration"); openEditor(app)
        reveal("mobile.nas.security.autoBlock", in: app).switches.firstMatch.tap()
        replace("attempts", text: "0", app, prefix: "mobile.nas.security")
        XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        expect(reveal("mobile.nas.service.invalid", in: app), contains: "login attempts")
        replace("attempts", text: "6", app, prefix: "mobile.nas.security")
        reveal("mobile.nas.security.expiration", in: app).switches.firstMatch.tap()
        replace("expirationDays", text: "7", app, prefix: "mobile.nas.security")
        reveal("mobile.nas.security.dos.eth0", in: app).switches.firstMatch.tap()
        reveal("mobile.nas.security.firewall", in: app).switches.firstMatch.tap()
        reveal("mobile.nas.security.notifications", in: app).switches.firstMatch.tap()
        screenshot(app, "Security native form before saving")
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "block your account")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "Security blocking and disconnect warning")
        element("mobile.nas.service.cancel", app).tap()
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap(); waitEditorClosed(app)
        expect(reveal("mobile.nas.security.summary.autoBlock", in: app), contains: "On")
        expect(reveal("mobile.nas.security.summary.attempts", in: app), contains: "6")
        expect(reveal("mobile.nas.security.summary.expirationDays", in: app), contains: "7")
        expect(reveal("mobile.nas.security.summary.dos.eth0", in: app), contains: "On")
        expect(reveal("mobile.nas.security.summary.firewall", in: app), contains: "On")
        expect(reveal("mobile.nas.security.summary.notifications", in: app), contains: "On")
        expect(reveal("mobile.nas.service.activity.succeeded", in: app), contains: "saved")
        screenshot(app, "Security all groups saved")
    }
    func test防火墙中断重启查询原任务后恢复保存结果() {
        let app = launch("nas-services-security-task-offline", kind: "security")
        openEditor(app); reveal("mobile.nas.security.firewall", in: app).switches.firstMatch.tap()
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap()
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "not available yet")
        XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        screenshot(app, "Firewall interrupted keeps operation protected"); app.terminate()
        let next = launch("nas-services-security-task-recover", kind: "security", preserve: true); defer { next.terminate() }
        expect(reveal("mobile.nas.security.summary.firewall", in: next), contains: "On")
        expect(reveal("mobile.nas.service.activity.succeeded", in: next), contains: "saved")
        screenshot(next, "Firewall original task recovered without another apply")
    }
    func test防火墙缺回执重启仍保留保护和刷新入口() {
        let app = launch("nas-services-security-lost-receipt", kind: "security")
        openEditor(app); reveal("mobile.nas.security.firewall", in: app).switches.firstMatch.tap()
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap()
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "not available yet"); app.terminate()
        let next = launch("nas-services-security-task-recover", kind: "security", preserve: true); defer { next.terminate() }
        XCTAssertFalse(reveal("mobile.nas.service.edit", in: next).isEnabled)
        expect(reveal("mobile.nas.service.activity.submitted", in: next), contains: "not available yet")
        reveal("mobile.nas.service.recover", in: next).tap()
        XCTAssertFalse(element("mobile.nas.service.removeRecord", next).exists)
        expect(reveal("mobile.nas.service.activity.submitted", in: next), contains: "not available yet")
        screenshot(next, "Firewall missing receipt cannot claim current switch as completion")
    }
    func test安全后组拒绝显示部分保存且原值可读() {
        let app = launch("nas-services-partial", kind: "security"); defer { app.terminate() }
        openEditor(app); reveal("mobile.nas.security.autoBlock", in: app).switches.firstMatch.tap()
        reveal("mobile.nas.security.dos.eth0", in: app).switches.firstMatch.tap()
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap()
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "permission")
        element("mobile.nas.service.done", app).tap(); waitEditorClosed(app)
        expect(reveal("mobile.nas.security.summary.autoBlock", in: app), contains: "On")
        expect(reveal("mobile.nas.security.summary.dos.eth0", in: app), contains: "Off")
        expect(reveal("mobile.nas.service.activity.partial", in: app), contains: "permission")
        screenshot(app, "Security partial result preserves each group")
    }
    func test安全加载缺字段错误不支持无网卡及权限状态() {
        for (state, label) in [("nas-services-loading", "Reading settings"), ("nas-services-security-incomplete", "Unable to load settings"), ("nas-services-error", "Unable to load settings"), ("nas-services-unsupported", "not supported"), ("nas-services-security-no-adapters", "no available network adapter")] {
            let app = launch(state, kind: "security")
            if state == "nas-services-loading" { XCTAssertTrue(app.activityIndicators.firstMatch.waitForExistence(timeout: 5)) }
            else { XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch.waitForExistence(timeout: 5)) }
            screenshot(app, "Security state " + state); app.terminate()
        }
        let app = launch("nas-services-readonly", kind: "security"); defer { app.terminate() }
        XCTAssertFalse(reveal("mobile.nas.service.edit", in: app).isEnabled)
        expect(reveal("mobile.nas.security.summary.autoBlock", in: app), contains: "Off")
        screenshot(app, "Security restricted account keeps current state readable")
    }
    func test安全中文大字表单和危险确认完整可操作() {
        let app = launch("nas-services", kind: "security", chinese: true, large: true); defer { app.terminate() }
        openEditor(app); reveal("mobile.nas.security.autoBlock", in: app).switches.firstMatch.tap()
        replace("attempts", text: "8", app, prefix: "mobile.nas.security")
        screenshot(app, "Chinese large Security input")
        reveal("mobile.nas.security.firewall", in: app).switches.firstMatch.tap()
        reveal("mobile.nas.security.notifications", in: app).switches.firstMatch.tap()
        screenshot(app, "Chinese large Security firewall controls")
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertTrue(element("mobile.nas.service.confirm", app).waitForExistence(timeout: 5))
        screenshot(app, "Chinese large Security risk confirmation")
        element("mobile.nas.service.cancel", app).tap(); element("mobile.nas.service.done", app).tap(); waitEditorClosed(app)
        XCTAssertFalse(element("mobile.nas.service.activity.succeeded", app).exists)
    }

    func test内存压缩确认取消后保存且不自动重启() {
        let app = launch("nas-services", kind: "zram"); defer { app.terminate() }
        openEditor(app)
        reveal("mobile.nas.power.compression", in: app).switches.firstMatch.tap()
        reveal("mobile.nas.power.compression", in: app).switches.firstMatch.tap()
        XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        reveal("mobile.nas.power.compression", in: app).switches.firstMatch.tap()
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "will not restart")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "Memory compression restart warning")
        element("mobile.nas.service.cancel", app).tap()
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap(); waitEditorClosed(app)
        XCTAssertEqual(reveal("mobile.nas.zram.status", in: app).value as? String, "Enabled")
        expect(reveal("mobile.nas.service.activity.succeeded", in: app), contains: "saved")
        XCTAssertFalse(element("mobile.nas.power.continue", app).exists)
        screenshot(app, "Memory compression saved without restarting")
    }
    func test内存压缩部分保存可单独继续后一步() {
        let app = launch("nas-services-partial", kind: "zram"); defer { app.terminate() }
        openEditor(app); reveal("mobile.nas.power.compression", in: app).switches.firstMatch.tap()
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap()
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "permission")
        element("mobile.nas.service.done", app).tap(); waitEditorClosed(app)
        screenshot(app, "Memory compression partial save keeps explicit continuation")
        reveal("mobile.nas.power.continue", in: app).tap()
        XCTAssertTrue(app.buttons["mobile.nas.service.save"].isEnabled)
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap(); waitEditorClosed(app)
        XCTAssertEqual(reveal("mobile.nas.zram.status", in: app).value as? String, "Enabled")
        expect(reveal("mobile.nas.service.activity.succeeded", in: app), contains: "saved")
        XCTAssertFalse(element("mobile.nas.power.continue", app).exists)
    }
    func test内存压缩未知标记重启只读恢复() {
        let app = launch("nas-services-zram-marker-unknown", kind: "zram")
        openEditor(app); reveal("mobile.nas.power.compression", in: app).switches.firstMatch.tap()
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap()
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "not available yet")
        XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled); app.terminate()
        let next = launch("nas-services-zram-recover", kind: "zram", preserve: true); defer { next.terminate() }
        expect(reveal("mobile.nas.service.activity.succeeded", in: next), contains: "saved")
        XCTAssertEqual(reveal("mobile.nas.zram.status", in: next).value as? String, "Enabled")
        screenshot(next, "Memory compression recovered after relaunch")
    }
    func test电源计划空清单新增草稿取消和整体保存() {
        let app = launch("nas-services", kind: "powerSchedule"); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["No Power Schedules"].waitForExistence(timeout: 5)); openEditor(app)
        reveal("mobile.nas.power.add", in: app).tap(); element("mobile.nas.power.cancelEntry", app).tap()
        XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        reveal("mobile.nas.power.add", in: app).tap()
        pickPower("action", value: "Shut down", app)
        reveal("mobile.nas.power.entryEnabled", in: app).switches.firstMatch.tap()
        pickPower("hour", value: "9", app); pickPower("minute", value: "5", app)
        applyPowerEntry(app)
        screenshot(app, "Power schedule draft before saving")
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Shutdown interrupts")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "Power schedule full list warning")
        element("mobile.nas.service.cancel", app).tap(); app.buttons["mobile.nas.service.save"].tap()
        element("mobile.nas.service.confirm", app).tap(); waitEditorClosed(app)
        XCTAssertTrue(app.staticTexts["Shut down"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "9:05")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Disabled"].exists)
        screenshot(app, "Power schedule saved using NAS wall clock")
    }
    func test电源计划启停编辑星期移除还原与清空() {
        let app = launch("nas-services-power-content", kind: "powerSchedule"); defer { app.terminate() }
        openEditor(app)
        reveal("mobile.nas.power.enabled.startup-0", in: app).switches.firstMatch.tap()
        reveal("mobile.nas.power.edit.startup-0", in: app).tap()
        pickPower("hour", value: "9", app)
        for day in 1...5 { reveal("mobile.nas.power.day.\(day)", in: app).switches.firstMatch.tap() }
        XCTAssertFalse(app.buttons["mobile.nas.power.applyEntry"].isEnabled)
        reveal("mobile.nas.power.day.0", in: app).switches.firstMatch.tap(); applyPowerEntry(app)
        XCTAssertTrue(app.buttons["mobile.nas.service.save"].isEnabled)
        reveal("mobile.nas.power.remove.shutdown-0", in: app).tap()
        reveal("mobile.nas.power.revert", in: app).tap()
        XCTAssertTrue(app.staticTexts["Shut down"].exists); XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        reveal("mobile.nas.power.remove.startup-0", in: app).tap(); reveal("mobile.nas.power.remove.shutdown-0", in: app).tap()
        app.buttons["mobile.nas.service.save"].tap(); screenshot(app, "Clear complete power schedule confirmation")
        element("mobile.nas.service.confirm", app).tap(); waitEditorClosed(app)
        XCTAssertTrue(app.staticTexts["No Power Schedules"].waitForExistence(timeout: 5))
        expect(reveal("mobile.nas.service.activity.succeeded", in: app), contains: "saved")
    }
    func test电源计划停用条目也不能与相同时间重叠() {
        let app = launch("nas-services-power-content", kind: "powerSchedule"); defer { app.terminate() }
        openEditor(app); reveal("mobile.nas.power.add", in: app).tap()
        reveal("mobile.nas.power.entryEnabled", in: app).switches.firstMatch.tap(); applyPowerEntry(app)
        XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        expect(reveal("mobile.nas.service.invalid", in: app), contains: "overlap")
        screenshot(app, "Disabled power schedule still rejects overlapping time")
        reveal("mobile.nas.power.revert", in: app).tap(); XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        element("mobile.nas.service.done", app).tap(); waitEditorClosed(app)
        XCTAssertFalse(element("mobile.nas.service.activity.succeeded", app).exists)
    }
    func test电源计划未知保存重启只读恢复() {
        let app = launch("nas-services-unknown", kind: "powerSchedule")
        openEditor(app); reveal("mobile.nas.power.add", in: app).tap(); applyPowerEntry(app)
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap()
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "not available yet")
        XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled); app.terminate()
        let next = launch("nas-services-power-ui-recover", kind: "powerSchedule", preserve: true); defer { next.terminate() }
        expect(reveal("mobile.nas.service.activity.succeeded", in: next), contains: "saved")
        XCTAssertTrue(app.staticTexts["Start up"].exists); screenshot(next, "Power schedule recovered without resubmission")
    }
    func test电源清单不完整和压缩字段未知保留读取与限制() {
        for (mode, kind, text) in [("nas-services-power-incomplete", "powerSchedule", "complete editable schedule"),
                                   ("nas-services-power-summary-empty", "powerSchedule", "complete editable schedule"),
                                   ("nas-services-zram-incomplete", "zram", "settings needed to change")] {
            let app = launch(mode, kind: kind)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(element("mobile.nas.service.edit", app).exists)
            screenshot(app, "Incomplete \(kind) keeps available information"); app.terminate()
        }
    }
    func test中文大字内存与电源确认可取消() {
        for kind in ["zram", "powerSchedule"] {
            let app = launch("nas-services", kind: kind, chinese: true, large: true)
            openEditor(app)
            if kind == "zram" { reveal("mobile.nas.power.compression", in: app).switches.firstMatch.tap() }
            else { reveal("mobile.nas.power.add", in: app).tap(); screenshot(app, "Chinese large power schedule entry editor"); applyPowerEntry(app) }
            screenshot(app, "Chinese large \(kind) editor")
            app.buttons["mobile.nas.service.save"].tap(); XCTAssertTrue(element("mobile.nas.service.confirm", app).waitForExistence(timeout: 5))
            screenshot(app, "Chinese large \(kind) warning")
            element("mobile.nas.service.cancel", app).tap(); element("mobile.nas.service.done", app).tap(); waitEditorClosed(app)
            XCTAssertFalse(element("mobile.nas.service.activity.succeeded", app).exists); app.terminate()
        }
    }
    private func pickPower(_ field: String, value: String, _ app: XCUIApplication) {
        reveal("mobile.nas.power.\(field)", in: app).tap()
        let item = app.buttons[value].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
    }
    private func applyPowerEntry(_ app: XCUIApplication) {
        let apply = app.buttons["mobile.nas.power.applyEntry"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5)); XCTAssertTrue(apply.isEnabled); apply.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: apply)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }
    func test文件服务端口校验确认取消和保存回读() {
        let app = launch("nas-services"); defer { app.terminate() }
        openEditor(app); toggle("smb", in: app); toggle("ftps", in: app)
        replace("ftpPort", text: "0", app); XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        replace("ftpPort", text: "2121", app)
        reveal("mobile.nas.service.timeMachine", in: app).switches.firstMatch.tap()
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertTrue(element("mobile.nas.service.confirm", app).waitForExistence(timeout: 5)); screenshot(app, "File services change warning")
        element("mobile.nas.service.cancel", app).tap()
        XCTAssertTrue(app.buttons["mobile.nas.service.save"].isEnabled)
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap()
        waitEditorClosed(app)
        expect(reveal("mobile.nas.service.row.smb", in: app), contains: "On")
        expect(reveal("mobile.nas.service.row.ftpPort", in: app), contains: "2121")
        expect(reveal("mobile.nas.service.activity.succeeded", in: app), contains: "saved")
        screenshot(app, "File services saved")
    }
    func test终端端口校验Telnet风险及保存回读() {
        let app = launch("nas-services", kind: "terminal"); defer { app.terminate() }
        openEditor(app); toggle("ssh", in: app); toggle("telnet", in: app)
        replace("sshPort", text: "65536", app); XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        replace("sshPort", text: "2222", app); screenshot(app, "Terminal settings editor")
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "without encryption")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "Terminal access warning")
        element("mobile.nas.service.confirm", app).tap(); waitEditorClosed(app)
        expect(reveal("mobile.nas.service.row.sshPort", in: app), contains: "2222")
        expect(reveal("mobile.nas.service.row.telnet", in: app), contains: "On")
        screenshot(app, "Terminal settings saved")
    }
    func test代理地址校验保存并关闭代理() {
        let app = launch("nas-services", kind: "proxy"); defer { app.terminate() }
        openEditor(app); toggle("proxyEnabled", in: app)
        replace("proxyHost", text: "https://proxy.example.invalid/path", app, selectAll: true); XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        replace("proxyHost", text: "outbound.example.invalid", app, selectAll: true); replace("proxyPort", text: "8080", app)
        XCTAssertTrue(app.buttons["mobile.nas.service.save"].isEnabled)
        XCTAssertTrue(app.buttons["mobile.nas.service.save"].isHittable)
        app.buttons["mobile.nas.service.save"].tap(); screenshot(app, "Proxy connection warning")
        element("mobile.nas.service.cancel", app).tap(); app.buttons["mobile.nas.service.save"].tap()
        confirmServiceChanges(app); waitEditorClosed(app)
        expect(reveal("mobile.nas.service.row.proxyHost", in: app), contains: "outbound.example.invalid")
        openEditor(app); toggle("proxyEnabled", in: app)
        XCTAssertFalse(app.textFields["mobile.nas.service.proxyHost"].isEnabled)
        app.buttons["mobile.nas.service.save"].tap(); confirmServiceChanges(app); waitEditorClosed(app)
        expect(reveal("mobile.nas.service.row.proxyEnabled", in: app), contains: "Off")
        screenshot(app, "Proxy disabled with original address retained")
    }
    func test多组保存部分完成不会误报全部成功() {
        let app = launch("nas-services-partial"); defer { app.terminate() }
        openEditor(app); toggle("smb", in: app); toggle("nfs", in: app)
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap()
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "permission")
        screenshot(app, "File service save stopped after partial completion")
        element("mobile.nas.service.done", app).tap(); waitEditorClosed(app)
        expect(reveal("mobile.nas.service.row.smb", in: app), contains: "On")
        expect(reveal("mobile.nas.service.row.nfs", in: app), contains: "Off")
        expect(reveal("mobile.nas.service.activity.partial", in: app), contains: "Some settings were saved")
        XCTAssertFalse(element("mobile.nas.service.activity.succeeded", app).exists)
    }
    func test终端未知结果重启后只读恢复() {
        let app = launch("nas-services-unknown", kind: "terminal")
        openEditor(app); toggle("ssh", in: app)
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap()
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "not available yet")
        XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled); screenshot(app, "Unknown terminal result protected")
        app.terminate()
        let reopened = launch("nas-services-recover", kind: "terminal", preserve: true); defer { reopened.terminate() }
        expect(reveal("mobile.nas.service.activity.succeeded", in: reopened), contains: "saved")
        XCTAssertTrue(reveal("mobile.nas.service.edit", in: reopened).isEnabled); screenshot(reopened, "Terminal result recovered")
    }
    func test缺失字段和只读权限显示真实限制() {
        let app = launch("nas-services-missing"); openEditor(app)
        XCTAssertFalse(element("mobile.nas.service.ftps", app).exists)
        XCTAssertFalse(element("mobile.nas.service.ftpPort", app).exists); XCTAssertFalse(element("mobile.nas.service.sftpPort", app).exists)
        screenshot(app, "Missing fields not offered for editing"); app.terminate()
        let readonly = launch("nas-services-readonly", kind: "terminal"); defer { readonly.terminate() }
        XCTAssertFalse(reveal("mobile.nas.service.edit", in: readonly).isEnabled)
        expect(reveal("mobile.nas.service.error", in: readonly), contains: "permission")
        screenshot(readonly, "Terminal settings read only")
    }
    func test明确拒绝保存保持失败和原设置() {
        let app = launch("nas-services-denied", kind: "terminal"); defer { app.terminate() }
        openEditor(app); toggle("ssh", in: app)
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap()
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "permission")
        element("mobile.nas.service.done", app).tap(); waitEditorClosed(app)
        expect(reveal("mobile.nas.service.row.ssh", in: app), contains: "Off")
        XCTAssertFalse(element("mobile.nas.service.activity.succeeded", app).exists)
    }
    func test五态搜索与读取失败恢复() {
        for state in ["nas-services", "nas-services-empty", "nas-services-loading", "nas-services-retry", "nas-services-unsupported"] {
            let app = launch(state)
            switch state {
            case "nas-services":
                let search = app.textFields["mobile.nas.service.search"]; XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("SMB\n")
                XCTAssertTrue(element("mobile.nas.service.row.smb", app).waitForExistence(timeout: 5)); XCTAssertFalse(element("mobile.nas.service.row.nfs", app).exists)
                search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "no-such-service\n")
                XCTAssertTrue(app.staticTexts["No matching items"].waitForExistence(timeout: 5))
            case "nas-services-empty": XCTAssertTrue(app.staticTexts["No settings available"].waitForExistence(timeout: 8))
            case "nas-services-loading": XCTAssertTrue(app.staticTexts["Loading settings…"].waitForExistence(timeout: 8))
            default:
                let retry = app.buttons["Try Again"].firstMatch; XCTAssertTrue(retry.waitForExistence(timeout: 8))
                if state == "nas-services-retry" { retry.tap(); XCTAssertTrue(element("mobile.nas.service.row.smb", app).waitForExistence(timeout: 8)) }
            }
            screenshot(app, state); app.terminate()
        }
    }
    func test中文大字终端表单与风险说明可操作() {
        let app = launch("nas-services", kind: "terminal", chinese: true, large: true); defer { app.terminate() }
        openEditor(app); toggle("telnet", in: app); screenshot(app, "Chinese large text terminal editor")
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertTrue(element("mobile.nas.service.confirm", app).waitForExistence(timeout: 5)); screenshot(app, "Chinese large text terminal warning")
        element("mobile.nas.service.cancel", app).tap(); element("mobile.nas.service.done", app).tap(); waitEditorClosed(app)
        expect(reveal("mobile.nas.service.row.telnet", in: app), contains: "已关闭")
    }
    func test远程访问双项确认取消保存与回读() {
        let app = launch("nas-services", kind: "remoteAccess"); defer { app.terminate() }
        openEditor(app); toggle("relay", in: app); toggle("routerConfiguration", in: app)
        app.buttons["mobile.nas.service.save"].tap(); screenshot(app, "Remote access changes warning")
        element("mobile.nas.service.cancel", app).tap(); XCTAssertTrue(app.buttons["mobile.nas.service.save"].isEnabled)
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap(); waitEditorClosed(app)
        expect(reveal("mobile.nas.service.row.relay", in: app), contains: "Off")
        expect(reveal("mobile.nas.service.row.routerConfiguration", in: app), contains: "On")
        expect(reveal("mobile.nas.service.activity.succeeded", in: app), contains: "saved"); screenshot(app, "Remote access saved")
    }
    func test远程中继连接保护和路由器独立操作() {
        let app = launch("nas-services-remote-relay", kind: "remoteAccess"); defer { app.terminate() }
        openEditor(app)
        XCTAssertFalse(reveal("mobile.nas.service.relay", in: app).isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "connect directly")).firstMatch.exists)
        toggle("routerConfiguration", in: app); screenshot(app, "Active relay protected with router setting available")
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap(); waitEditorClosed(app)
        expect(reveal("mobile.nas.service.row.relay", in: app), contains: "On")
        expect(reveal("mobile.nas.service.row.routerConfiguration", in: app), contains: "On")
    }
    func test远程单项读取失败仍可编辑另一项() {
        let app = launch("nas-services-remote-partial-read", kind: "remoteAccess"); defer { app.terminate() }
        XCTAssertTrue(element("mobile.nas.service.relayReadFailed", app).waitForExistence(timeout: 8))
        openEditor(app); XCTAssertFalse(element("mobile.nas.service.relay", app).exists)
        toggle("routerConfiguration", in: app); app.buttons["mobile.nas.service.save"].tap()
        element("mobile.nas.service.confirm", app).tap(); waitEditorClosed(app)
        expect(reveal("mobile.nas.service.row.routerConfiguration", in: app), contains: "On")
        XCTAssertTrue(element("mobile.nas.service.relayReadFailed", app).exists); screenshot(app, "Independent remote access read failure")
    }
    func test远程未知记录重启后只读恢复() {
        let app = launch("nas-services-remote-unknown", kind: "remoteAccess")
        openEditor(app); toggle("routerConfiguration", in: app)
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap()
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "not available yet")
        XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled); screenshot(app, "Remote access unknown protected"); app.terminate()
        let reopened = launch("nas-services-remote-recover", kind: "remoteAccess", preserve: true); defer { reopened.terminate() }
        expect(reveal("mobile.nas.service.activity.succeeded", in: reopened), contains: "saved")
        expect(reveal("mobile.nas.service.row.routerConfiguration", in: reopened), contains: "On"); screenshot(reopened, "Remote access restored")
    }
    func test远程加载空内容错误不可用及恢复() {
        for state in ["nas-services-empty", "nas-services-loading", "nas-services-remote-retry", "nas-services-unsupported"] {
            let app = launch(state, kind: "remoteAccess")
            if state == "nas-services-empty" { XCTAssertTrue(app.staticTexts["No settings available"].waitForExistence(timeout: 8)); XCTAssertFalse(element("mobile.nas.service.edit", app).exists) }
            else if state == "nas-services-loading" { XCTAssertTrue(app.staticTexts["Loading settings…"].waitForExistence(timeout: 8)) }
            else {
                let retry = app.buttons["Try Again"].firstMatch; XCTAssertTrue(retry.waitForExistence(timeout: 8))
                if state == "nas-services-remote-retry" { retry.tap(); XCTAssertTrue(element("mobile.nas.service.row.relay", app).waitForExistence(timeout: 8)) }
            }
            screenshot(app, "Remote " + state); app.terminate()
        }
    }
    func test远程中文大字表单和连接风险可操作() {
        let app = launch("nas-services", kind: "remoteAccess", chinese: true, large: true); defer { app.terminate() }
        openEditor(app); toggle("routerConfiguration", in: app); screenshot(app, "Chinese large remote access editor")
        app.buttons["mobile.nas.service.save"].tap(); XCTAssertTrue(element("mobile.nas.service.confirm", app).waitForExistence(timeout: 5))
        screenshot(app, "Chinese large remote access warning")
        element("mobile.nas.service.cancel", app).tap(); element("mobile.nas.service.done", app).tap(); waitEditorClosed(app)
        expect(reveal("mobile.nas.service.row.routerConfiguration", in: app), contains: "已关闭")
    }
    func test网卡编辑校验风险取消后只保存所选配置() {
        let app = launch("nas-services", kind: "ethernet"); defer { app.terminate() }
        openEthernetEditor(app)
        replace("mtu", text: "9001", app, prefix: "mobile.nas.ethernet")
        XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        replace("mtu", text: "1400", app, prefix: "mobile.nas.ethernet")
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "may disconnect")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "Ethernet connection loss warning")
        element("mobile.nas.service.cancel", app).tap(); XCTAssertTrue(app.buttons["mobile.nas.service.save"].isEnabled)
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap()
        waitEditorClosed(app, editID: "mobile.nas.ethernet.edit.eth0")
        expect(reveal("mobile.nas.service.activity.succeeded", in: app), contains: "saved")
        _ = reveal("mobile.nas.ethernet.edit.eth0", in: app)
        XCTAssertTrue(app.staticTexts["MTU, 1400"].exists); screenshot(app, "Ethernet saved with target configuration")
    }
    func test网卡静态地址和VLAN表单完整保存() {
        let app = launch("nas-services", kind: "ethernet"); defer { app.terminate() }; openEthernetEditor(app)
        reveal("mobile.nas.ethernet.dhcp", in: app).switches.firstMatch.tap()
        replace("address", text: "192.0.2.42", app, prefix: "mobile.nas.ethernet")
        reveal("mobile.nas.ethernet.vlanEnabled", in: app).switches.firstMatch.tap()
        XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        let field = app.textFields["mobile.nas.ethernet.vlan"]; _ = reveal("mobile.nas.ethernet.vlan", in: app); field.tap(); field.typeText("12")
        finishTextEditing(app)
        XCTAssertEqual(field.value as? String, "12")
        XCTAssertTrue(app.buttons["mobile.nas.service.save"].isEnabled); XCTAssertTrue(app.buttons["mobile.nas.service.save"].isHittable)
        app.buttons["mobile.nas.service.save"].tap()
        XCTAssertTrue(element("mobile.nas.service.confirm", app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["IP address, 192.0.2.42"].exists); XCTAssertTrue(app.staticTexts["VLAN ID, 12"].exists)
        screenshot(app, "Static address and VLAN confirmation")
        element("mobile.nas.service.confirm", app).tap(); waitEditorClosed(app, editID: "mobile.nas.ethernet.edit.eth0")
        expect(reveal("mobile.nas.service.activity.succeeded", in: app), contains: "saved")
        _ = reveal("mobile.nas.ethernet.edit.eth0", in: app)
        XCTAssertTrue(app.staticTexts["IP address, 192.0.2.42"].exists)
    }
    func test网卡未知保存重启后只读恢复且不可重发() {
        let app = launch("nas-services-unknown", kind: "ethernet"); openEthernetEditor(app)
        replace("mtu", text: "1400", app, prefix: "mobile.nas.ethernet")
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap()
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "not available yet")
        XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled); screenshot(app, "Ethernet unknown result remains protected"); app.terminate()
        let next = launch("nas-services-ethernet-recover", kind: "ethernet", preserve: true); defer { next.terminate() }
        expect(reveal("mobile.nas.service.activity.succeeded", in: next), contains: "saved")
        XCTAssertTrue(reveal("mobile.nas.ethernet.edit.eth0", in: next).isEnabled); screenshot(next, "Ethernet recovered by reading original interface")
    }
    func test网卡新地址重新登录后明确恢复原记录() {
        let app = launch("nas-services-unknown", kind: "ethernet"); openEthernetEditor(app)
        replace("mtu", text: "1400", app, prefix: "mobile.nas.ethernet")
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap()
        expect(reveal("mobile.nas.service.editorResult", in: app), contains: "not available yet"); app.terminate()
        let next = launch("nas-services-ethernet-new-address", kind: "ethernet", preserve: true); defer { next.terminate() }
        XCTAssertFalse(reveal("mobile.nas.ethernet.edit.eth0", in: next).isEnabled)
        reveal("mobile.nas.service.recover", in: next).tap()
        XCTAssertTrue(next.buttons["Read Saved Result"].waitForExistence(timeout: 5)); screenshot(next, "Explicit result reading after new address login")
        next.buttons["Read Saved Result"].tap()
        expect(reveal("mobile.nas.service.activity.succeeded", in: next), contains: "saved")
        XCTAssertTrue(reveal("mobile.nas.ethernet.edit.eth0", in: next).isEnabled)
    }
    func test网卡加载空内容错误与不支持可恢复() {
        for (state, label) in [("nas-services-loading", "Reading settings"), ("nas-services-empty", "No physical interfaces available"), ("nas-services-ethernet-incomplete", "Unable to load settings"), ("nas-services-unsupported", "not supported")] {
            let app = launch(state, kind: "ethernet")
            if state == "nas-services-loading" { XCTAssertTrue(app.activityIndicators.firstMatch.waitForExistence(timeout: 5)) }
            else { XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch.waitForExistence(timeout: 5)) }
            XCTAssertFalse(element("mobile.nas.ethernet.edit.eth0", app).exists)
            screenshot(app, "Ethernet state " + state); app.terminate()
        }
    }
    func test网卡搜索无结果与权限限制() {
        let app = launch("nas-services-readonly", kind: "ethernet")
        XCTAssertFalse(reveal("mobile.nas.ethernet.edit.eth0", in: app).isEnabled)
        let search = app.textFields["mobile.nas.ethernet.search"]; _ = reveal("mobile.nas.ethernet.search", in: app)
        search.tap(); search.typeText("no-such-interface\n")
        XCTAssertTrue(element("mobile.nas.ethernet.filteredEmpty", app).waitForExistence(timeout: 5)); screenshot(app, "Ethernet filtered empty with restricted account"); app.terminate()
    }
    func test网卡中文大字表单风险和取消均可触达() {
        let app = launch("nas-services", kind: "ethernet", chinese: true, large: true); defer { app.terminate() }; openEthernetEditor(app)
        replace("mtu", text: "1400", app, prefix: "mobile.nas.ethernet")
        screenshot(app, "Chinese large Ethernet form")
        app.buttons["mobile.nas.service.save"].tap(); XCTAssertTrue(element("mobile.nas.service.confirm", app).waitForExistence(timeout: 5))
        screenshot(app, "Chinese large Ethernet warning")
        element("mobile.nas.service.cancel", app).tap(); element("mobile.nas.service.done", app).tap()
        waitEditorClosed(app, editID: "mobile.nas.ethernet.edit.eth0")
        XCTAssertFalse(element("mobile.nas.service.activity.succeeded", app).exists)
    }
    private func openEthernetEditor(_ app: XCUIApplication) {
        reveal("mobile.nas.ethernet.edit.eth0", in: app).tap(); XCTAssertTrue(app.buttons["mobile.nas.service.save"].waitForExistence(timeout: 5))
    }
    private func openEditor(_ app: XCUIApplication) { reveal("mobile.nas.service.edit", in: app).tap(); XCTAssertTrue(app.buttons["mobile.nas.service.save"].waitForExistence(timeout: 5)) }
    private func toggle(_ key: String, in app: XCUIApplication) { reveal("mobile.nas.service.\(key)", in: app).switches.firstMatch.tap() }
    private func replace(_ key: String, text: String, _ app: XCUIApplication, prefix: String = "mobile.nas.service", separateLabel: Bool = false, selectAll: Bool = false) {
        let field = app.textFields["\(prefix).\(key)"]; _ = reveal("\(prefix).\(key)", in: app)
        if selectAll {
            // 长地址使用系统全选快捷键，避免光标位置、连续退格和隐藏的编辑菜单影响替换范围。
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8)).tap()
            field.typeKey("a", modifierFlags: .command)
            field.typeText(text)
        } else if app.frame.width > 600 || separateLabel {
            // 独立标题的左对齐短数字框使用控件点击；iPad 行内值仍定位末尾，不依赖长按菜单。
            if separateLabel { field.tap() }
            else { field.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.8)).tap() }
            let previous = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
            // 空 TextField 的辅助功能值可能是占位提示，不能把它当作残留输入。
            let cleared = field.value as? String ?? ""
            XCTAssertTrue(cleared.isEmpty || cleared == field.placeholderValue, "输入框未清空：\(cleared)")
            // 保留焦点继续输入；iPad 浮动数字键盘可覆盖原输入框，再点原位置会误敲数字。
            if !text.isEmpty { field.typeText(text) }
        } else {
            // LabeledContent 的辅助功能框同时包含标签和值，须点入下方实际输入区。
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8)).tap()
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8)).press(forDuration: 1.2)
            let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label == %@", "Select All", "全选")).firstMatch
            if !selectAll.waitForExistence(timeout: 3) {
                let attachment = XCTAttachment(string: app.debugDescription); attachment.name = "Service text selection hierarchy"; add(attachment)
                screenshot(app, "Service text selection")
            }
            XCTAssertTrue(selectAll.exists); selectAll.tap(); field.typeText(text)
        }
        XCTAssertEqual(field.value as? String, text)
        finishTextEditing(app)
        XCTAssertEqual(field.value as? String, text)
    }
    private func finishTextEditing(_ app: XCUIApplication) {
        if app.frame.width > 600, app.popovers.firstMatch.exists {
            // 数字键盘的弹出层会拦截底部完成按钮，先点击编辑器标题栏空白处收起它。
            let bar = app.navigationBars.containing(.button, identifier: "mobile.nas.service.save").firstMatch
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
            XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        }
        let done = app.buttons["mobile.nas.service.keyboardDone"]
        if done.exists && done.isHittable { done.tap() }
    }
    private func confirmServiceChanges(_ app: XCUIApplication) {
        // 云端命中了确认按钮的外层 Other，但确认页未关闭；只操作实际按钮且不重发。
        let confirm = app.buttons["mobile.nas.service.confirm"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertTrue(confirm.isEnabled)
        confirm.press(forDuration: 0.15)
    }
    private func waitEditorClosed(_ app: XCUIApplication, editID: String = "mobile.nas.service.edit") {
        let edit = app.buttons[editID]
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: edit)], timeout: 10)
        if result != .completed { let attachment = XCTAttachment(string: app.debugDescription); attachment.name = "Service editor result hierarchy"; add(attachment); screenshot(app, "Service editor result") }
        XCTAssertEqual(result, .completed); XCTAssertFalse(app.collectionViews["mobile.nas.service.editor"].exists)
    }
    private func launch(_ state: String, kind: String = "fileServices", preserve: Bool = false, chinese: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if preserve { app.launchArguments.append("--ui-preserve-transfer-fixture") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", title: chinese ? "App 设置" : "App settings", app)
        _ = reveal("mobile.settings.module.nasSettings", in: app)
        MobileUITestNavigation.enableModule(app, module: "nasSettings", test: self)
        navigate("nasSettings", title: chinese ? "NAS 设置" : "NAS settings", app)
        reveal("mobile.nas.page.\(kind)", in: app).tap()
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
            let forms = ["mobile.nas.power.entryEditor", "mobile.nas.service.confirmation", "mobile.nas.service.editor",
                         "mobile.nas.service.list", "mobile.nas.navigation", "mobile.settings.page"]
                .map { app.collectionViews[$0] }
            // 结果行可能尚未被惰性表单创建；滚动容器不能依赖这行先存在。
            // 表单内控件禁用后，容器可能不可点击但仍可滚动；按最上层表单的稳定标识选区域。
            let scroller = forms.first(where: { $0.exists })
                ?? app
            if value.waitForExistence(timeout: 1), !value.frame.isEmpty {
                let top = app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.map { $0.frame.maxY }.max() ?? app.frame.minY + 110
                let tab = app.tabBars.firstMatch
                let keyboard = app.keyboards.firstMatch
                let keyboardTop = keyboard.exists ? keyboard.frame.minY - 8 : app.frame.maxY - 35
                let visibleBottom = min(keyboardTop, scroller.frame.maxY - 12)
                let bottom = tab.exists && tab.isHittable ? min(visibleBottom, tab.frame.minY - 8) : visibleBottom
                if value.frame.minY < top + 8 { scroll(scroller, upward: false, in: app); continue }
                if value.frame.maxY > bottom { scroll(scroller, upward: true, in: app); continue }
                if value.isHittable || !value.isEnabled { return value }
            }
            scroll(scroller, upward: attempt < 7, in: app)
        }
        XCTAssertTrue(value.exists); XCTAssertTrue(value.isHittable); return value
    }
    private func scroll(_ element: XCUIElement, upward: Bool, in app: XCUIApplication) {
        var frame = element.frame.intersection(app.frame)
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { frame.size.height = max(0, min(frame.maxY, keyboard.frame.minY - 8) - frame.minY) }
        let center = CGPoint(x: frame.maxX - 12, y: frame.midY)
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

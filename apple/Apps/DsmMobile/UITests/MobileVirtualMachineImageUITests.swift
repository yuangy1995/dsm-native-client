import XCTest

@MainActor final class MobileVirtualMachineImageUITests: XCTestCase {
    func test映像详情单项删除记录和搜索空态() {
        let app = launch(); defer { app.terminate() }; openImages(app)
        screenshot("Virtual machine images list light")
        element("virtual-machine.image.image-1", app).tap()
        XCTAssertTrue(app.staticTexts["Type, Installation image"].waitForExistence(timeout: 6))
        screenshot("Virtual machine image details")
        reveal("virtual-machine.image.delete", app).tap()
        XCTAssertTrue(element("virtual-machine.image.confirmation", app).waitForExistence(timeout: 8))
        screenshot("Virtual machine single image deletion confirmation")
        app.buttons["virtual-machine.image.confirm"].tap()
        XCTAssertTrue(app.staticTexts["Image unavailable"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.firstMatch.tap(); openRecords(app)
        expectPhase("succeeded", app); XCTAssertTrue(app.staticTexts["Image deleted"].exists)
        screenshot("Virtual machine image deletion completed")
        app.navigationBars.buttons.firstMatch.tap()
        let search = app.searchFields.firstMatch; XCTAssertTrue(search.waitForExistence(timeout: 6)); search.tap(); search.typeText("NoMatchingImage")
        XCTAssertTrue(element("virtual-machine.image.filtered-empty", app).waitForExistence(timeout: 6))
        screenshot("Virtual machine image filtered empty")
    }
    func test中文深色大字删除后果取消零操作() {
        let app = launch(chinese: true, dark: true, large: true); defer { app.terminate() }; openImages(app)
        element("virtual-machine.image.image-1", app).tap(); reveal("virtual-machine.image.delete", app).tap()
        XCTAssertTrue(element("virtual-machine.image.confirmation", app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["所选映像及其存储副本将被永久删除，之后无法再用它们安装或创建虚拟机。此操作无法撤销。"].exists)
        screenshot("Chinese large dark virtual machine image deletion consequence")
        let cancel = app.buttons["virtual-machine.image.cancel"]; XCTAssertTrue(cancel.isHittable); cancel.tap()
        XCTAssertTrue(app.buttons["virtual-machine.image.delete"].waitForExistence(timeout: 6))
        screenshot("Chinese large dark virtual machine image deletion cancelled")
        app.navigationBars.buttons.firstMatch.tap(); openRecords(app)
        XCTAssertTrue(app.staticTexts["暂无操作记录"].waitForExistence(timeout: 8))
    }
    func test多选删除保留部分完成和未知结果() {
        let app = launch("vmm-image-partial"); defer { app.terminate() }; openImages(app)
        app.buttons["virtual-machine.image.selection"].tap()
        app.buttons["virtual-machine.image.select.image-1"].tap(); app.buttons["virtual-machine.image.select.image-2"].tap()
        let openConfirmation = app.buttons["virtual-machine.image.selection.delete"]
        let confirmation = element("virtual-machine.image.confirmation", app)
        openConfirmation.tap()
        if !confirmation.waitForExistence(timeout: 6) {
            // 云端曾取消此触控；只恢复打开确认页，最终删除按钮仍严格单次提交。
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Image confirmation first navigation"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            screenshot("Image confirmation first navigation state")
            if openConfirmation.exists && openConfirmation.isEnabled && openConfirmation.isHittable && !confirmation.exists {
                openConfirmation.tap()
            }
        }
        XCTAssertTrue(confirmation.waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["Selected images: 2"].waitForExistence(timeout: 6))
        screenshot("Virtual machine batch image deletion confirmation")
        app.buttons["virtual-machine.image.confirm"].tap()
        XCTAssertTrue(app.buttons["virtual-machine.image.select.image-1"].waitForNonExistence(timeout: 15))
        app.buttons["virtual-machine.image.selection.done"].tap(); openRecords(app)
        expectPhase("succeeded", app); expectPhase("submitted", app)
        XCTAssertFalse(app.buttons["Remove Record"].exists)
        screenshot("Virtual machine partial image deletion retains both results")
    }
    func test丢回执重启后不能再次删除() {
        let first = launch("vmm-image-unknown"); openImages(first); element("virtual-machine.image.image-1", first).tap()
        first.buttons["virtual-machine.image.delete"].tap(); first.buttons["virtual-machine.image.confirm"].tap()
        XCTAssertTrue(element("virtual-machine.image.confirmation", first).waitForNonExistence(timeout: 8))
        first.navigationBars.buttons.firstMatch.tap(); openRecords(first); expectPhase("submitted", first)
        screenshot("Virtual machine image deletion missing receipt"); first.terminate()
        let restored = launch(preserve: true); defer { restored.terminate() }; openImages(restored); openRecords(restored)
        expectPhase("submitted", restored); XCTAssertFalse(restored.buttons["Remove Record"].exists)
        screenshot("Virtual machine image missing receipt after restart")
        restored.navigationBars.buttons.firstMatch.tap(); element("virtual-machine.image.image-1", restored).tap()
        XCTAssertFalse(restored.buttons["virtual-machine.image.delete"].isEnabled)
    }
    func test接受后断网跨重启只读恢复() {
        let first = launch("vmm-image-accepted-offline"); openImages(first); element("virtual-machine.image.image-1", first).tap()
        first.buttons["virtual-machine.image.delete"].tap(); first.buttons["virtual-machine.image.confirm"].tap()
        XCTAssertTrue(element("virtual-machine.image.confirmation", first).waitForNonExistence(timeout: 8))
        first.navigationBars.buttons.firstMatch.tap(); openRecords(first); expectPhase("submitted", first)
        screenshot("Virtual machine image accepted before lost connection"); first.terminate()
        let restored = launch("vmm-image-deleted", preserve: true); defer { restored.terminate() }; openImages(restored); openRecords(restored)
        expectPhase("succeeded", restored); XCTAssertTrue(restored.staticTexts["Image deleted"].exists)
        screenshot("Virtual machine image accepted deletion restored")
    }
    func test加载空内容错误冻结及占用状态() {
        let loading = launch("vmm-image-loading"); openImages(loading, expectsList: false)
        XCTAssertTrue(element("virtual-machine.image.loading", loading).waitForExistence(timeout: 6))
        screenshot("Virtual machine images loading"); loading.terminate()
        let empty = launch("vmm-image-empty"); openImages(empty, expectsList: false)
        XCTAssertTrue(element("virtual-machine.image.empty", empty).waitForExistence(timeout: 8))
        screenshot("Virtual machine images empty with next step"); empty.terminate()
        let failed = launch("vmm-image-read-error"); openImages(failed, expectsList: false)
        XCTAssertTrue(element("virtual-machine.image.error", failed).waitForExistence(timeout: 8))
        screenshot("Virtual machine images read error"); failed.terminate()
        let frozen = launch("vmm-image-frozen"); openImages(frozen)
        XCTAssertFalse(frozen.buttons["virtual-machine.image.selection"].isEnabled)
        screenshot("Virtual machine images frozen"); frozen.terminate()
        let occupied = launch("vmm-image-in-use"); defer { occupied.terminate() }; openImages(occupied)
        element("virtual-machine.image.image-1", occupied).tap()
        XCTAssertFalse(occupied.buttons["virtual-machine.image.delete"].isEnabled)
        XCTAssertTrue(occupied.staticTexts["A virtual machine is using this image. Eject it in Virtual Machine Manager before deleting."].exists)
        screenshot("Virtual machine image mounted by stopped guest")
    }
    private func launch(_ mode: String = "vmm-image-success", preserve: Bool = false, chinese: Bool = false,
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
    private func openImages(_ app: XCUIApplication, expectsList: Bool = true) {
        let section = element("virtual-machine.section.images", app); XCTAssertTrue(section.waitForExistence(timeout: 8)); section.tap()
        if expectsList { XCTAssertTrue(element("virtual-machine.image.list", app).waitForExistence(timeout: 10)) }
    }
    private func openRecords(_ app: XCUIApplication) {
        let link = element("virtual-machine.image.records.toolbar", app); XCTAssertTrue(link.waitForExistence(timeout: 8)); link.tap()
        XCTAssertTrue(element("virtual-machine.image.records", app).waitForExistence(timeout: 8))
    }
    private func expectPhase(_ phase: String, _ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["virtual-machine.image.record.\(phase)"].firstMatch.waitForExistence(timeout: 15))
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
        XCTFail("映像操作不可见：\(id)"); return value
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

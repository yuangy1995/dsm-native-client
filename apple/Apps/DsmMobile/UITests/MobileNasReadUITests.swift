import XCTest

@MainActor
final class MobileNasReadUITests: XCTestCase {
    func test外接存储切换筛选不把无匹配当设备消失() {
        let app = launch(); defer { app.terminate() }
        open("externalStorage", in: app)
        XCTAssertTrue(app.staticTexts["Sample USB"].waitForExistence(timeout: 8))
        element("mobile.nas.externalStorage.filter", in: app).tap()
        app.buttons["eSATA"].firstMatch.tap()
        XCTAssertTrue(element("mobile.nas.read.filteredEmpty", in: app).waitForExistence(timeout: 5))
        element("mobile.nas.externalStorage.filter", in: app).tap()
        app.buttons["All"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Sample USB"].waitForExistence(timeout: 5))
        screenshot(app, "External storage and connection filter")
    }

    func test系统活动搜索能显示与清除无匹配状态() {
        let app = launch(); defer { app.terminate() }
        open("processes", in: app)
        XCTAssertTrue(app.staticTexts["Sample process"].waitForExistence(timeout: 8))
        let search = app.textFields["mobile.nas.read.search"]
        search.tap(); search.typeText("no-such-process")
        XCTAssertTrue(element("mobile.nas.read.filteredEmpty", in: app).waitForExistence(timeout: 5))
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "no-such-process".count))
        XCTAssertTrue(app.staticTexts["Sample process"].waitForExistence(timeout: 5))
        screenshot(app, "System activity search")
    }

    func test共享访问使用当前账号列表且未知权限不当可写() {
        let app = launch(); defer { app.terminate() }
        open("shareAccess", in: app)
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Access could not be determined"].exists)
        XCTAssertFalse(app.staticTexts["Read and write"].exists)
        screenshot(app, "Share access preserves unknown permissions")
    }

    func test电源计划保留NAS时间并区分停用项目() {
        let app = launch(); defer { app.terminate() }
        open("powerSchedule", in: app)
        XCTAssertTrue(app.staticTexts["Start up"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Shut down"].exists)
        XCTAssertTrue(app.staticTexts["NAS time zone: Asia/Taipei"].exists)
        element("mobile.nas.powerSchedule.filter", in: app).tap()
        app.buttons["Disabled"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Shut down"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Start up"].exists)
        screenshot(app, "NAS wall clock and disabled schedule")
    }

    func test读取错误可重试且未知开关不显示关闭() {
        let app = launch(state: "nas-read-retry"); defer { app.terminate() }
        open("zram", in: app)
        XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 8))
        app.buttons["Try Again"].tap()
        let status = element("mobile.nas.zram.status", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertEqual(status.value as? String, "Enabled")
        screenshot(app, "Memory compression recovers after retry")
    }

    func test空计划与缺少接口分别展示() {
        for (state, page, text) in [
            ("nas-read-empty", "powerSchedule", "No Power Schedules"),
            ("nas-read-unsupported", "zram", "Details aren’t available"),
            ("nas-read-loading", "zram", "Loading memory compression…")
        ] {
            let app = launch(state: state)
            open(page, in: app)
            XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 8))
            screenshot(app, state); app.terminate()
        }
    }

    func test部分接口失败仍显示可用设备() {
        let app = launch(state: "nas-read-partial"); defer { app.terminate() }
        open("externalStorage", in: app)
        XCTAssertTrue(app.staticTexts["Sample USB"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["eSATA information is not available from this NAS. Other devices can still be viewed."].exists)
        screenshot(app, "Partial external storage remains usable")
    }

    func test中文大字号未知开关有独立状态() {
        let app = launch(state: "nas-read-unknown", chinese: true, largeText: true); defer { app.terminate() }
        open("zram", in: app)
        XCTAssertTrue(element("mobile.nas.zram.status", in: app).waitForExistence(timeout: 8))
        XCTAssertEqual(element("mobile.nas.zram.status", in: app).value as? String, "状态不可用")
        XCTAssertFalse(app.staticTexts["已停用"].exists)
        screenshot(app, "Chinese large text unknown memory setting")
    }

    private func launch(state: String = "nas-read-content", chinese: Bool = false, largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state
        app.launch()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", title: chinese ? "App 设置" : "App settings", in: app)
        let toggle = element("mobile.settings.module.nasSettings", in: app)
        for _ in 0..<4 {
            if toggle.exists && toggle.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        toggle.switches.firstMatch.tap()
        navigate("nasSettings", title: chinese ? "NAS 设置" : "NAS settings", in: app)
        return app
    }

    private func open(_ page: String, in app: XCUIApplication) {
        let link = element("mobile.nas.page.\(page)", in: app)
        let list = app.collectionViews["mobile.nas.navigation"]
        XCTAssertTrue(list.waitForExistence(timeout: 8))
        for _ in 0..<14 {
            if link.exists && link.isHittable { break }
            // iPad 分类列表左侧可被主侧栏覆盖，使用它实际可见的右侧滚动。
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.7))
                .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.4)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(link.waitForExistence(timeout: 8))
        XCTAssertTrue(link.isHittable); link.tap()
    }

    private func navigate(_ destination: String, title: String, in app: XCUIApplication) {
        MobileUITestNavigation.open(app, destination: destination, title: title, test: self)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

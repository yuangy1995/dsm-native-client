import XCTest

@MainActor
final class MobileFilesProviderUITests: XCTestCase {
    func test默认只读位置通过系统文件下载() {
        let app = launch()
        defer { app.terminate() }
        addLocation(app)
        activateSystemLocation()
        app.activate()
        XCTAssertTrue(element("mobile.files-location.row", app).waitForExistence(timeout: 8))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let browse = element("mobile.files.test-browse", app)
        XCTAssertTrue(browse.waitForExistence(timeout: 8), app.debugDescription); browse.tap()
        openLocation(app)
        let shared = sharedFolder(in: app)
        XCTAssertTrue(shared.waitForExistence(timeout: 15), app.debugDescription); shared.tap()
        let file = app.cells["Sample, txt"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15), app.debugDescription); file.tap()
        let contents = element("mobile.files.test-contents", app)
        XCTAssertTrue(contents.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(element("mobile.files.test-filename", app).label, "Sample.txt")
        XCTAssertTrue(contents.label.contains("Initial sample"))
        screenshot(app, "files-read-only-downloaded")
    }

    func test系统文件位置可浏览下载并从外部编辑后上传() {
        let app = launch()
        defer { app.terminate() }
        addLocation(app)
        element("mobile.files-location.row", app).tap()
        let editing = app.switches["mobile.files-location.editing"]
        XCTAssertTrue(editing.waitForExistence(timeout: 8)); tapSwitch(editing)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Allow editing"].tap()
        waitValue(editing, "1")
        screenshot(app, "files-location-editing-enabled")
        activateSystemLocation()
        app.activate()
        XCTAssertTrue(editing.waitForExistence(timeout: 8))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("mobile.files-location.row", app).waitForExistence(timeout: 8))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let browse = element("mobile.files.test-browse", app)
        XCTAssertTrue(browse.waitForExistence(timeout: 8), app.debugDescription); browse.tap()
        openLocation(app)
        let shared = sharedFolder(in: app)
        XCTAssertTrue(shared.waitForExistence(timeout: 15), app.debugDescription); shared.tap()
        // “文件”默认隐藏扩展名，完整类型仍保留在项目的可访问标识中。
        let file = app.cells["Sample, txt"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15), app.debugDescription)
        screenshot(app, "files-native-folder")
        file.tap()
        let contents = element("mobile.files.test-contents", app)
        XCTAssertTrue(contents.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(element("mobile.files.test-filename", app).label, "Sample.txt")
        XCTAssertTrue(contents.label.contains("Initial sample"))
        screenshot(app, "files-downloaded-open-in-place")
        element("mobile.files.test-edit", app).tap()
        XCTAssertTrue(element("mobile.files.test-saved", app).waitForExistence(timeout: 35), app.debugDescription)
        screenshot(app, "files-system-edit-uploaded")
    }

    func test中文深色大字位置权限确认暂停恢复与取消移除() {
        let app = launch(chinese: true)
        defer { app.terminate() }
        addLocation(app, chinese: true)
        element("mobile.files-location.row", app).tap()
        let deleting = app.switches["mobile.files-location.deleting"]
        XCTAssertTrue(deleting.waitForExistence(timeout: 8)); XCTAssertFalse(deleting.isEnabled)
        tapSwitch(app.switches["mobile.files-location.editing"])
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "files-chinese-edit-confirmation")
        scrollConfirmation(app, name: "files-chinese-edit-consequence")
        app.alerts.buttons["允许编辑"].tap()
        tapSwitch(deleting)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "files-chinese-delete-confirmation")
        scrollConfirmation(app, name: "files-chinese-delete-consequence")
        app.alerts.buttons["取消"].tap()
        XCTAssertEqual(deleting.value as? String, "0")
        let pause = app.switches["mobile.files-location.pause"]
        tapSwitch(pause)
        waitValue(pause, "1")
        screenshot(app, "files-chinese-paused-large")
        tapSwitch(pause)
        waitValue(pause, "0")
        let remove = app.buttons["mobile.files-location.remove"]
        for _ in 0..<4 where !remove.isHittable { app.swipeUp() }
        remove.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "files-chinese-remove-consequence")
        scrollConfirmation(app, name: "files-chinese-remove-retained-files")
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["mobile.files-location.remove"].exists)
    }

    private func launch(chinese: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-files-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if chinese { app.launchArguments += ["--ui-dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LANSTASH_FILES_RUN_ID"] = UUID().uuidString
        app.launch()
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchArguments = ["--ui-files-fixture", "--ui-clean-files"]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mobile.files.test-cleaned").firstMatch.waitForExistence(timeout: 20), app.debugDescription)
            app.terminate()
        }
        return app
    }

    private func addLocation(_ app: XCUIApplication, chinese: Bool = false) {
        let settings = element("mobile.files.test-settings", app)
        XCTAssertTrue(settings.waitForExistence(timeout: 15), app.debugDescription); settings.tap()
        let add = app.buttons["mobile.files-location.add"]
        // 首次载入期间按钮已存在但不可用；必须等真实可操作状态后再提交一次。
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: add)], timeout: 10), .completed)
        for _ in 0..<4 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isHittable); add.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        app.alerts.buttons[chinese ? "关闭" : "Close"].tap()
        XCTAssertTrue(element("mobile.files-location.row", app).waitForExistence(timeout: 10))
        screenshot(app, chinese ? "files-chinese-location-added" : "files-location-added")
    }

    private func activateSystemLocation() {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        openLocation(files, enable: true)
        XCTAssertTrue(sharedFolder(in: files).waitForExistence(timeout: 20), files.debugDescription)
        screenshot(files, "files-system-location-enabled")
    }

    private func sharedFolder(in app: XCUIApplication) -> XCUIElement {
        // iPad 侧栏也有 Shared；只接受目录列表中的合成文件夹，不能误入系统共享页。
        app.cells.matching(NSPredicate(format: "NOT identifier BEGINSWITH %@", "DOC.sidebar."))
            .containing(.staticText, identifier: "Shared").firstMatch
    }

    private func openLocation(_ app: XCUIApplication, enable: Bool = false) {
        let sidebar = app.buttons["ToggleSideBar"]
        if sidebar.waitForExistence(timeout: 3) { sidebar.tap() }
        let identifiers = ["DOC.sidebar.item.岚仓", "DOC.sidebar.item.LanStash", "DOC.sidebar.item.Sample NAS"]
        let provider = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", identifiers)).firstMatch
        let ready = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@ OR (elementType == %d AND label IN %@)",
            identifiers, XCUIElement.ElementType.button.rawValue, ["Browse", "浏览"])).firstMatch
        for _ in 0..<3 {
            let back = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            let tab = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            // 标签切换、返回位置列表是不同导航步骤，各自等待；不能耗尽后续步骤的期限。
            XCTAssertTrue(ready.waitForExistence(timeout: 8), app.debugDescription)
            if provider.exists { break }
            if back.exists { back.tap() }
            else if tab.exists { tab.tap() }
        }
        if provider.waitForExistence(timeout: 8) {
            if enable {
                let more = app.buttons.matching(NSPredicate(format: "label IN %@", ["More", "更多"])).firstMatch
                XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription); more.tap()
                let edit = app.buttons.matching(NSPredicate(format: "label IN %@", ["Edit Sidebar", "编辑边栏", "Edit", "编辑"])).firstMatch
                XCTAssertTrue(edit.waitForExistence(timeout: 5), app.debugDescription); edit.tap()
                // 系统未给位置开关独立标识，按同一行的实际坐标匹配，不能误触其他位置。
                let locationSwitch = app.switches.allElementsBoundByIndex.first {
                    abs($0.frame.midY - provider.frame.midY) < 2
                }
                XCTAssertNotNil(locationSwitch, app.debugDescription)
                if let locationSwitch {
                    // 同时验证用户可以从系统关闭再开启本测试位置，不触碰其他提供器。
                    if locationSwitch.value as? String == "1" { locationSwitch.tap(); waitValue(locationSwitch, "0") }
                    locationSwitch.tap(); waitValue(locationSwitch, "1")
                }
                app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成"])).firstMatch.tap()
            }
            screenshot(app, "files-native-locations")
            provider.tap()
        } else {
            let name = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Sample NAS", "岚仓", "LanStash"])).firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 8), app.debugDescription)
            screenshot(app, "files-native-locations")
            name.tap()
        }
        // 系统选择器可能再次要求启用本测试提供器；只处理已观察到的专属确认。
        let activation = app.alerts["Turn On “LanStash”?"]
        if activation.waitForExistence(timeout: 3) {
            let turnOn = activation.buttons["Turn On"]
            XCTAssertTrue(turnOn.isEnabled); XCTAssertTrue(turnOn.isHittable)
            screenshot(app, "files-system-picker-enable-confirmation")
            turnOn.press(forDuration: 0.15)
            XCTAssertTrue(activation.waitForNonExistence(timeout: 5), app.debugDescription)
        }
    }

    private func tapSwitch(_ row: XCUIElement) {
        // 系统 AX 将 SwiftUI 开关行和实际开关分别暴露；点击行中心不会改变开关。
        let control = row.switches.firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        control.tap()
    }

    private func scrollConfirmation(_ app: XCUIApplication, name: String) {
        // 最大字号下系统确认正文可滚动；实际滚动查看末尾风险及保留范围。
        let message = app.alerts.firstMatch.scrollViews.firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.swipeUp()
        screenshot(app, name)
        XCTAssertTrue(app.alerts.buttons["取消"].isHittable)
    }

    private func waitValue(_ element: XCUIElement, _ value: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element)], timeout: 10), .completed)
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

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
        if !shared.waitForExistence(timeout: 15) { MobileUITestNavigation.capture(app, name: "Read-only shared folder missing", test: self) }
        XCTAssertTrue(shared.exists, app.debugDescription); shared.tap()
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
        confirmEditing(editing, in: app, title: "Allow editing")
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
        // 冷启动的系统缩略图读取曾占用协调锁约 78 秒；先核对实际写入，再按原期限核对上传。
        XCTAssertTrue(contents.wait(for: \.label, toEqual: "Edited in another app\n", timeout: 120), app.debugDescription)
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
        let editing = app.switches["mobile.files-location.editing"]
        tapSwitch(editing)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "files-chinese-edit-confirmation")
        scrollConfirmation(app, name: "files-chinese-edit-consequence")
        confirmEditing(editing, in: app, title: "允许编辑")
        tapSwitch(deleting)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "files-chinese-delete-confirmation")
        scrollConfirmation(app, name: "files-chinese-delete-consequence")
        app.alerts.buttons["取消"].tap()
        XCTAssertEqual(deleting.value as? String, "0")
        let pause = app.switches["mobile.files-location.pause"]
        tapSwitch(pause)
        waitValue(pause, "1", in: app)
        screenshot(app, "files-chinese-paused-large")
        tapSwitch(pause)
        waitValue(pause, "0", in: app)
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
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mobile.files.test-cleaned").firstMatch.waitForExistence(timeout: 90), app.debugDescription)
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
        // 云端曾丢弃首次添加点击且未产生任何添加结果；无提示时补一次同一按钮点击。
        if !app.alerts.firstMatch.waitForExistence(timeout: 5) { XCTAssertTrue(add.isHittable); add.tap() }
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        app.alerts.buttons[chinese ? "关闭" : "Close"].tap()
        XCTAssertTrue(element("mobile.files-location.row", app).waitForExistence(timeout: 10))
        screenshot(app, chinese ? "files-chinese-location-added" : "files-location-added")
    }

    private func activateSystemLocation() {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        // 先结束本测试启动的系统浏览会话，再执行 launch 注册的位置清理；不干预业务断言。
        addTeardownBlock { @MainActor in files.terminate() }
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
        let identifiers = ["DOC.sidebar.item.岚仓", "DOC.sidebar.item.LanStash", "DOC.sidebar.item.Sample NAS"]
        let provider = app.cells.matching(NSPredicate(format: "identifier IN %@", identifiers)).firstMatch
        let ready = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@ OR (elementType == %d AND label IN %@)",
            identifiers, XCUIElement.ElementType.button.rawValue, ["Browse", "浏览"])).firstMatch
        // 系统远程选择器冷启动曾约 35 秒才显示导航；先等真实控件，再按原期限切换目录。
        let navigation = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@ OR (elementType == %d AND label IN %@)",
            identifiers + ["ToggleSideBar"], XCUIElement.ElementType.button.rawValue, ["Browse", "浏览"])).firstMatch
        // iPhone 的系统选取器曾停在“最近项目”，底部实际有“浏览”按钮，
        // 但复合 AX 谓词未命中该按钮；按原生标签进入位置列表后再核验提供器。
        if !navigation.waitForExistence(timeout: 8) {
            let browseTab = app.tabBars.buttons.matching(NSPredicate(
                format: "label IN %@", ["Browse", "浏览"])).firstMatch
            XCTAssertTrue(browseTab.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertTrue(browseTab.isHittable, app.debugDescription)
            if !browseTab.isSelected { browseTab.tap() }
            XCTAssertTrue(provider.waitForExistence(timeout: 25), app.debugDescription)
        }
        if sidebar.exists { sidebar.tap() }
        for _ in 0..<3 {
            let back = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            let tab = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            // 标签切换、返回位置列表是不同导航步骤，各自等待；不能耗尽后续步骤的期限。
            XCTAssertTrue(ready.waitForExistence(timeout: 8), app.debugDescription)
            if provider.exists { break }
            if back.exists {
                // 冷启动时返回按钮先于目录页面出现；等搜索栏载入，避免在空白过渡页耗尽导航步骤。
                XCTAssertTrue(app.navigationBars.searchFields.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
                back.tap()
            }
            else if tab.exists { tab.tap() }
        }
        let location: XCUIElement
        if provider.waitForExistence(timeout: 8) {
            if enable {
                let more = app.buttons.matching(NSPredicate(format: "label IN %@", ["More", "更多"])).firstMatch
                XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription); more.tap()
                let edit = app.buttons.matching(NSPredicate(format: "label IN %@", ["Edit Sidebar", "编辑边栏", "Edit", "编辑"])).firstMatch
                XCTAssertTrue(edit.waitForExistence(timeout: 5), app.debugDescription); edit.tap()
                // 系统未给位置开关独立标识，按同一行的实际坐标匹配，不能误触其他位置。
                func locationSwitch() -> XCUIElement? {
                    // 系统 AX 索引可能在状态改变后更新；每次按本位置行重新定位。
                    let rowY = provider.frame.midY
                    return app.switches.allElementsBoundByIndex.first { abs($0.frame.midY - rowY) < 2 }
                }
                guard let current = locationSwitch() else { XCTFail("无法定位本提供器的系统开关"); return }
                if current.value as? String == "1" {
                    current.tap()
                    waitValue(current, "0", in: app)
                }
                guard let enabling = locationSwitch() else { XCTFail("关闭后无法重新定位本提供器开关"); return }
                XCTAssertTrue(enabling.isHittable)
                enabling.press(forDuration: 0.15)
                waitValue(enabling, "1", in: app)
                app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成"])).firstMatch.tap()
            }
            screenshot(app, "files-native-locations")
            location = provider
        } else {
            let name = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Sample NAS", "岚仓", "LanStash"])).firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 8), app.debugDescription)
            screenshot(app, "files-native-locations")
            location = name
        }
        location.tap()
        // iPad 的内嵌“文件”选择器曾在首次点击本提供器后仍选中 Recents。
        // 仅当真实目录未出现、Recents 仍选中且提供器可点击时，补一次只读位置选择。
        if !sharedFolder(in: app).waitForExistence(timeout: 8) {
            let recents = app.cells["DOC.sidebar.item.Recents"]
            if recents.exists && recents.isSelected &&
                provider.exists && !provider.isSelected && provider.isHittable &&
                !app.alerts["Turn On “LanStash”?"].exists {
                MobileUITestNavigation.capture(app, name: "Files picker stayed on Recents", test: self)
                provider.press(forDuration: 0.15)
            }
        }
        // 系统选择器可能再次要求启用本测试提供器；只处理已观察到的专属确认。
        let activation = app.alerts["Turn On “LanStash”?"]
        // 系统启用确认可能在首次选中和导航恢复后的再次选中分别出现。
        // 只响应实际存在的本提供器专属提示；每次提示只确认一次，不重发其他写操作。
        func acceptActivation(ifPresentedWithin timeout: TimeInterval) -> Bool {
            guard activation.waitForExistence(timeout: timeout) else { return false }
            let turnOn = activation.buttons["Turn On"]
            XCTAssertTrue(turnOn.isEnabled); XCTAssertTrue(turnOn.isHittable)
            screenshot(app, "files-system-picker-enable-confirmation")
            turnOn.press(forDuration: 0.15)
            let dismissed = activation.waitForNonExistence(timeout: 5)
            XCTAssertTrue(dismissed, app.debugDescription)
            return dismissed
        }
        if acceptActivation(ifPresentedWithin: 15) {
            // 启用后的系统导航可能仍在进行；先检查目录，避免用旧页面坐标点击正在变化的位置列表。
            if !sharedFolder(in: app).waitForExistence(timeout: 8) {
                MobileUITestNavigation.capture(app, name: "Files enabled location navigation", test: self)
                // 系统曾恢复“我的 iPhone”且位置行已消失，须先返回“浏览”，再重新查找同一提供器。
                if !location.exists || !location.isHittable {
                    let back = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
                    XCTAssertTrue(back.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
                    back.press(forDuration: 0.15)
                }
                XCTAssertTrue(location.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
                location.press(forDuration: 0.15)
                // 恢复导航重新选择位置后，系统可能再次弹出独立的开启提示。
                _ = acceptActivation(ifPresentedWithin: 5)
            }
        }
        // 系统文件应用曾在选中提供器后仍停留“我的 iPhone”空目录。
        // 只在确认实际落入本机目录且共享文件夹不存在时，返回位置列表并重新选择同一提供器。
        let localStorageRoot = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage")).firstMatch
        if !sharedFolder(in: app).waitForExistence(timeout: 20), localStorageRoot.exists {
            MobileUITestNavigation.capture(app, name: "Files location remained in local storage", test: self)
            let back = app.navigationBars.buttons.matching(NSPredicate(
                format: "label IN %@", ["Browse", "浏览"])).firstMatch
            XCTAssertTrue(back.wait(for: \.isHittable, toEqual: true, timeout: 8), app.debugDescription)
            back.press(forDuration: 0.15)
            let selected = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier IN %@", identifiers)).firstMatch
            XCTAssertTrue(selected.wait(for: \.isHittable, toEqual: true, timeout: 8), app.debugDescription)
            selected.press(forDuration: 0.15)
            // #448 的失败层级明确显示此时仍有“Turn On LanStash”系统弹窗遮挡共享目录。
            _ = acceptActivation(ifPresentedWithin: 5)
        }
        // 仍要求真正进入系统 File Provider 目录，不以点过位置项替代内容验收。
        XCTAssertTrue(sharedFolder(in: app).waitForExistence(timeout: 20), app.debugDescription)
    }

    private func tapSwitch(_ row: XCUIElement) {
        // 系统 AX 将 SwiftUI 开关行和实际开关分别暴露；点击行中心不会改变开关。
        let control = row.switches.firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        control.tap()
    }

    private func confirmEditing(_ row: XCUIElement, in app: XCUIApplication, title: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let confirmation = app.alerts.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        let button = confirmation.buttons[title]
        XCTAssertTrue(button.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription, file: file, line: line)
        XCTAssertTrue(button.isEnabled, file: file, line: line)
        // 确认只提交一次；先核对提示确已关闭，再等待系统授权完成后的开关状态。
        button.press(forDuration: 0.15)
        let dismissed = confirmation.waitForNonExistence(timeout: 5)
        if !dismissed { MobileUITestNavigation.capture(app, name: "Files editing confirmation retained", test: self) }
        XCTAssertTrue(dismissed, "编辑授权确认尚未关闭", file: file, line: line)
        waitValue(row, "1", in: app, file: file, line: line)
    }

    private func scrollConfirmation(_ app: XCUIApplication, name: String) {
        // 最大字号下系统确认正文可滚动；实际滚动查看末尾风险及保留范围。
        let message = app.alerts.firstMatch.scrollViews.firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.swipeUp()
        screenshot(app, name)
        XCTAssertTrue(app.alerts.buttons["取消"].isHittable)
    }

    private func waitValue(_ element: XCUIElement, _ value: String, in app: XCUIApplication,
                           file: StaticString = #filePath, line: UInt = #line) {
        // SwiftUI 外层是开关行；与点击使用同一实际控件，并等待授权回读结束后恢复可用。
        // 系统 Files 的原生开关没有嵌套控件，直接读取其自身。
        let nested = element.switches.firstMatch
        let control = nested.exists ? nested : element
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND value == %@", value), object: control)], timeout: 10)
        if result != .completed { MobileUITestNavigation.capture(app, name: "Files switch state \(value)", test: self) }
        XCTAssertEqual(result, .completed, "文件位置开关尚未完成状态更新", file: file, line: line)
        XCTAssertEqual(element.value as? String, value, "文件位置开关行与实际控件的状态不一致", file: file, line: line)
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

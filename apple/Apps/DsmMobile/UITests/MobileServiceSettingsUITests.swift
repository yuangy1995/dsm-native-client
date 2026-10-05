import XCTest

@MainActor
final class MobileServiceSettingsUITests: XCTestCase {
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
        replace("proxyHost", text: "https://proxy.example.invalid/path", app); XCTAssertFalse(app.buttons["mobile.nas.service.save"].isEnabled)
        replace("proxyHost", text: "outbound.example.invalid", app); replace("proxyPort", text: "8080", app)
        app.buttons["mobile.nas.service.save"].tap(); screenshot(app, "Proxy connection warning")
        element("mobile.nas.service.cancel", app).tap(); app.buttons["mobile.nas.service.save"].tap()
        element("mobile.nas.service.confirm", app).tap(); waitEditorClosed(app)
        expect(reveal("mobile.nas.service.row.proxyHost", in: app), contains: "outbound.example.invalid")
        openEditor(app); toggle("proxyEnabled", in: app)
        XCTAssertFalse(app.textFields["mobile.nas.service.proxyHost"].isEnabled)
        app.buttons["mobile.nas.service.save"].tap(); element("mobile.nas.service.confirm", app).tap(); waitEditorClosed(app)
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
    private func openEditor(_ app: XCUIApplication) { reveal("mobile.nas.service.edit", in: app).tap(); XCTAssertTrue(app.buttons["mobile.nas.service.save"].waitForExistence(timeout: 5)) }
    private func toggle(_ key: String, in app: XCUIApplication) { reveal("mobile.nas.service.\(key)", in: app).switches.firstMatch.tap() }
    private func replace(_ key: String, text: String, _ app: XCUIApplication) {
        let field = app.textFields["mobile.nas.service.\(key)"]; _ = reveal("mobile.nas.service.\(key)", in: app)
        if app.frame.width > 600 {
            // iPad 可连接硬件键盘；将光标放在可见值末尾后删除原值，不依赖长按菜单。
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.8)).tap()
            let previous = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + text)
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
        let done = element("mobile.nas.service.keyboardDone", app)
        if done.exists && done.isHittable { done.tap() }
    }
    private func waitEditorClosed(_ app: XCUIApplication) {
        let edit = app.buttons["mobile.nas.service.edit"]
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
        reveal("mobile.settings.module.nasSettings", in: app).switches.firstMatch.tap()
        navigate("nasSettings", title: chinese ? "NAS 设置" : "NAS settings", app)
        reveal("mobile.nas.page.\(kind)", in: app).tap()
        return app
    }
    private func navigate(_ destination: String, title: String, _ app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        if tab.exists { tab.tap() } else {
            let button = element("mobile.navigation.\(destination)", app); XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
        }
    }
    private func expect(_ value: XCUIElement, contains text: String) {
        XCTAssertTrue(value.waitForExistence(timeout: 8))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: value)], timeout: 10), .completed)
    }
    private func reveal(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let value = element(id, app)
        for attempt in 0..<14 {
            let list = app.collectionViews.containing(.any, identifier: id).firstMatch
            let form = app.collectionViews["mobile.nas.service.editor"]
            let scroller: XCUIElement = list.exists ? list : (form.exists ? form : app)
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

import XCTest

@MainActor
final class MobileDirectoryUITests: XCTestCase {
    func test账号编辑群组选择保存取消及删除确认() {
        let app = launch("nas-directory"); defer { app.terminate() }
        reveal("mobile.nas.directory.row.sample-user", in: app).tap()
        replaceDescription(app)
        reveal("mobile.nas.directory.chooseGroups", in: app).tap()
        let group = app.collectionViews["mobile.nas.directory.groupPicker"].switches["mobile.nas.directory.group.sample-team"]
        XCTAssertTrue(group.waitForExistence(timeout: 5)); XCTAssertTrue(group.isHittable)
        XCTAssertTrue(group.isEnabled); XCTAssertEqual(group.value as? String, "0")
        group.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: group)], timeout: 5), .completed)
        app.buttons["mobile.nas.directory.groupsDone"].tap()
        XCTAssertTrue(app.collectionViews["mobile.nas.directory.groupPicker"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sample-team"].exists)
        app.buttons["mobile.nas.directory.save"].tap()
        XCTAssertTrue(element("mobile.nas.directory.confirm", app).waitForExistence(timeout: 5)); screenshot(app, "Account and group changes confirmation")
        element("mobile.nas.directory.cancel", app).tap()
        XCTAssertTrue(app.buttons["mobile.nas.directory.save"].isEnabled)
        app.buttons["mobile.nas.directory.save"].tap(); element("mobile.nas.directory.confirm", app).tap()
        waitEditorClosed(app)
        expect(reveal("mobile.nas.directory.activity.succeeded", in: app), contains: "saved")
        reveal("mobile.nas.directory.row.sample-user", in: app).tap()
        XCTAssertTrue(app.staticTexts["sample-team"].waitForExistence(timeout: 5))
        reveal("mobile.nas.directory.delete", in: app).tap()
        screenshot(app, "Account deletion warning")
        element("mobile.nas.directory.cancel", app).tap()
        XCTAssertTrue(element("mobile.nas.directory.delete", app).exists)
        element("mobile.nas.directory.delete", app).tap(); element("mobile.nas.directory.confirm", app).tap()
        waitEditorClosed(app)
        expect(reveal("mobile.nas.directory.activity.succeeded", in: app), contains: "deleted")
        XCTAssertFalse(element("mobile.nas.directory.row.sample-user", app).exists)
        screenshot(app, "Account deletion completed")
    }
    func test创建账号密码不匹配不能保存且成功后显示新账号() {
        let app = launch("nas-directory-password"); defer { app.terminate() }
        reveal("mobile.nas.directory.add", in: app).tap()
        let name = app.textFields["mobile.nas.directory.name"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("created-user\n")
        enterPassword("mobile.nas.directory.password", text: "synthetic-only", in: app)
        enterPassword("mobile.nas.directory.confirmPassword", text: "different", in: app)
        XCTAssertFalse(app.buttons["mobile.nas.directory.save"].isEnabled)
        enterPassword("mobile.nas.directory.confirmPassword", text: "synthetic-only", in: app)
        if !app.buttons["mobile.nas.directory.save"].isEnabled {
            let attachment = XCTAttachment(string: app.debugDescription); attachment.name = "Synthetic password entry hierarchy"; add(attachment)
            screenshot(app, "Synthetic password confirmation failure")
        }
        XCTAssertTrue(app.buttons["mobile.nas.directory.save"].isEnabled)
        app.buttons["mobile.nas.directory.save"].tap(); element("mobile.nas.directory.confirm", app).tap()
        waitEditorClosed(app)
        XCTAssertTrue(reveal("mobile.nas.directory.row.created-user", in: app).waitForExistence(timeout: 8))
        screenshot(app, "New account created")
    }
    func test群组创建编辑和删除() {
        let app = launch("nas-directory"); defer { app.terminate() }
        element("mobile.nas.directory.scope", app).buttons["Groups"].tap()
        reveal("mobile.nas.directory.add", in: app).tap()
        let name = app.textFields["mobile.nas.directory.name"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("created-group\n")
        app.buttons["mobile.nas.directory.save"].tap()
        waitEditorClosed(app)
        reveal("mobile.nas.directory.row.created-group", in: app).tap()
        let field = reveal("mobile.nas.directory.description", in: app); field.tap(); field.typeText("Updated group")
        app.buttons["mobile.nas.directory.save"].tap()
        waitEditorClosed(app)
        reveal("mobile.nas.directory.row.created-group", in: app).tap()
        XCTAssertEqual(element("mobile.nas.directory.description", app).value as? String, "Updated group")
        reveal("mobile.nas.directory.delete", in: app).tap(); screenshot(app, "Group deletion warning")
        element("mobile.nas.directory.confirm", app).tap()
        waitEditorClosed(app)
        expect(reveal("mobile.nas.directory.activity.succeeded", in: app), contains: "deleted")
        XCTAssertFalse(element("mobile.nas.directory.row.created-group", app).exists)
    }
    func test当前账号保护和未知所属组仍可查看() {
        let app = launch("nas-directory-missing-groups"); defer { app.terminate() }
        reveal("mobile.nas.directory.row.fixture", in: app).tap()
        XCTAssertFalse(element("mobile.nas.directory.disabled", app).isEnabled)
        XCTAssertFalse(reveal("mobile.nas.directory.delete", in: app).isEnabled)
        XCTAssertFalse(reveal("mobile.nas.directory.chooseGroups", in: app).isEnabled)
        screenshot(app, "Current account protection")
        element("mobile.nas.directory.done", app).tap(); waitEditorClosed(app)
        reveal("mobile.nas.directory.row.sample-user", in: app).tap()
        XCTAssertTrue(app.staticTexts["Group membership could not be read. It will be kept unchanged."].waitForExistence(timeout: 5))
        replaceDescription(app); XCTAssertTrue(app.buttons["mobile.nas.directory.save"].isEnabled)
    }
    func test资料保存未知后重启只读恢复() {
        let app = launch("nas-directory-unknown")
        reveal("mobile.nas.directory.row.sample-user", in: app).tap(); replaceDescription(app)
        app.buttons["mobile.nas.directory.save"].tap()
        expect(reveal("mobile.nas.directory.saveResult", in: app), contains: "temporarily unavailable")
        XCTAssertFalse(app.buttons["mobile.nas.directory.save"].isEnabled); screenshot(app, "Unknown account save protected")
        app.terminate()
        let reopened = launch("nas-directory-recover", preserve: true); defer { reopened.terminate() }
        expect(reveal("mobile.nas.directory.activity.succeeded", in: reopened), contains: "saved")
        screenshot(reopened, "Account recovered without replay")
    }
    func test缺失资料只显示已知字段并提供查看方式() {
        let app = launch("nas-directory-readonly"); defer { app.terminate() }
        reveal("mobile.nas.directory.row.sample-user", in: app).tap()
        XCTAssertTrue(app.staticTexts["This account or group cannot be edited here. Use DSM to view more details."].waitForExistence(timeout: 5))
        XCTAssertFalse(element("mobile.nas.directory.disabled", app).exists)
        XCTAssertFalse(element("mobile.nas.directory.password", app).exists)
        XCTAssertFalse(app.buttons["mobile.nas.directory.save"].isEnabled)
        screenshot(app, "Unknown account fields remain read only")
    }
    func test明确拒绝保持失败而不是成功() {
        let app = launch("nas-directory-denied"); defer { app.terminate() }
        reveal("mobile.nas.directory.row.sample-user", in: app).tap(); replaceDescription(app)
        app.buttons["mobile.nas.directory.save"].tap()
        expect(reveal("mobile.nas.directory.saveResult", in: app), contains: "permission")
        screenshot(app, "Account change rejected")
    }
    func test列表五态搜索和读取失败恢复() {
        for state in ["nas-directory", "nas-directory-empty", "nas-directory-loading", "nas-directory-retry", "nas-directory-unsupported"] {
            let app = launch(state)
            if state == "nas-directory" {
                let search = app.textFields["mobile.nas.directory.search"]; XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("no-such-account\n")
                XCTAssertTrue(app.staticTexts["No matching items"].waitForExistence(timeout: 5))
            } else if state == "nas-directory-empty" {
                XCTAssertTrue(app.staticTexts["No accounts or groups"].waitForExistence(timeout: 8)); XCTAssertTrue(app.buttons["mobile.nas.directory.add"].isEnabled)
            } else if state == "nas-directory-loading" {
                XCTAssertTrue(app.staticTexts["Loading accounts and groups…"].waitForExistence(timeout: 8))
            } else {
                let retry = app.buttons["Try Again"].firstMatch; XCTAssertTrue(retry.waitForExistence(timeout: 8))
                if state == "nas-directory-retry" { retry.tap(); XCTAssertTrue(element("mobile.nas.directory.row.sample-user", app).waitForExistence(timeout: 8)) }
            }
            screenshot(app, state); app.terminate()
        }
    }
    func test中文大字表单和删除风险说明可完整使用() {
        let app = launch("nas-directory", chinese: true, large: true); defer { app.terminate() }
        reveal("mobile.nas.directory.row.sample-user", in: app).tap(); screenshot(app, "Chinese large text account editor")
        reveal("mobile.nas.directory.delete", in: app).tap()
        XCTAssertTrue(element("mobile.nas.directory.confirm", app).waitForExistence(timeout: 5))
        screenshot(app, "Chinese large text account deletion warning")
        element("mobile.nas.directory.cancel", app).tap(); element("mobile.nas.directory.done", app).tap(); waitEditorClosed(app)
        XCTAssertTrue(reveal("mobile.nas.directory.row.sample-user", in: app).exists)
    }
    private func waitEditorClosed(_ app: XCUIApplication) {
        let list = app.buttons["mobile.nas.directory.add"]
        // 二级确认关闭时父表单可能短暂不在辅助功能树中；要等底层列表实际恢复可操作。
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: list)], timeout: 10)
        if result != .completed {
            let attachment = XCTAttachment(string: app.debugDescription); attachment.name = "Directory editor completion hierarchy"; add(attachment)
            screenshot(app, "Directory editor completion state")
        }
        XCTAssertEqual(result, .completed)
        let editor = app.collectionViews["mobile.nas.directory.editor"]
        XCTAssertFalse(editor.exists)
    }
    private func enterPassword(_ id: String, text: String, in app: XCUIApplication) {
        let field = reveal(id, in: app); field.tap()
        // 此场景验证手动输入；先关闭系统强密码建议，避免建议值替换测试的两次输入。
        let suggestion = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "强密码", "Strong Password")).firstMatch
        if suggestion.waitForExistence(timeout: 8) {
            let close = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "关闭", "Close")).firstMatch
            if !close.exists {
                let attachment = XCTAttachment(string: app.debugDescription); attachment.name = "System password suggestion hierarchy"; add(attachment)
            }
            XCTAssertTrue(close.exists); close.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: suggestion)], timeout: 5), .completed)
            field.tap()
        }
        let previous = (field.value as? String)?.count ?? 0
        if previous > 0 {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.8)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous))
            field.tap()
        }
        field.typeText(text)
        field.typeText("\n")
    }
    private func replaceDescription(_ app: XCUIApplication) {
        let field = reveal("mobile.nas.directory.description", in: app)
        field.tap()
        let previous = field.value as? String ?? ""
        // 三击在 iPad 可能只选中一个词；原合成值为单行，明确移至末尾后清空。
        for _ in previous { field.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: []) }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        XCTAssertTrue((field.value as? String ?? "").isEmpty)
        field.tap()
        field.typeText("Updated account")
        XCTAssertEqual(field.value as? String, "Updated account")
    }
    private func launch(_ state: String, preserve: Bool = false, chinese: Bool = false, large: Bool = false) -> XCUIApplication {
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
        reveal("mobile.nas.page.accounts", in: app).tap()
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
        var value = element(id, app)
        for attempt in 0..<14 {
            let forms = ["confirmation", "groupPicker", "editor", "list"].map { app.collectionViews["mobile.nas.directory.\($0)"] }
            let scroller = forms.first(where: { $0.exists }) ?? app.collectionViews.containing(.any, identifier: id).firstMatch
            value = scroller.descendants(matching: .any).matching(identifier: id).firstMatch
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

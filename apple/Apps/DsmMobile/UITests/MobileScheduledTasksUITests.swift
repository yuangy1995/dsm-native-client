import XCTest

@MainActor
final class MobileScheduledTasksUITests: XCTestCase {
    func test空目录新建完整表单与确认取消再保存() {
        let app = launch("nas-tasks-empty"); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["No Tasks"].waitForExistence(timeout: 5)); app.buttons["mobile.nas.task.create"].tap()
        XCTAssertFalse(app.buttons["mobile.nas.task.save"].isEnabled)
        replace("name", text: "New Task", app)
        reveal("mobile.nas.task.enabled", in: app).switches.firstMatch.tap()
        pick("hour", value: "9", app); pick("minute", value: "5", app)
        reveal("mobile.nas.task.day.0", in: app).switches.firstMatch.tap()
        replace("script", text: "echo created", app)
        reveal("mobile.nas.task.notifyError", in: app).switches.firstMatch.tap(); replace("emails", text: "sample@example.invalid", app)
        screenshot(app, "Task editor includes script and notification options")
        app.buttons["mobile.nas.task.save"].tap(); expect(element("mobile.nas.task.warning", app), contains: "change files")
        screenshot(app, "Create task warning previews submitted contents")
        tap("mobile.nas.task.cancel", app); app.buttons["mobile.nas.task.save"].tap(); tap("mobile.nas.task.confirm", app); waitClosed(app)
        XCTAssertTrue(app.staticTexts["New Task"].waitForExistence(timeout: 5))
        openTask("20", app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "9:05")).firstMatch.exists)
        expect(reveal("mobile.nas.task.scriptPreview", in: app), contains: "echo created")
        screenshot(app, "Saved task details retain NAS schedule")
    }
    func test启停运行删除各自确认且运行只显示请求已发送() {
        let app = launch(); defer { app.terminate() }
        openTask("12", app); reveal("mobile.nas.task.enable", in: app).tap(); tap("mobile.nas.task.cancel", app)
        reveal("mobile.nas.task.enable", in: app).tap(); tap("mobile.nas.task.confirm", app); waitClosed(app)
        expect(element("mobile.nas.task.row.12", app), contains: "Disabled")
        openTask("12", app); reveal("mobile.nas.task.enable", in: app).tap(); expect(reveal("mobile.nas.task.scriptPreview", in: app), contains: "echo initial")
        tap("mobile.nas.task.confirm", app); waitClosed(app)
        openTask("12", app); reveal("mobile.nas.task.run", in: app).tap(); tap("mobile.nas.task.cancel", app)
        reveal("mobile.nas.task.run", in: app).tap(); tap("mobile.nas.task.confirm", app); waitClosed(app)
        expect(reveal("mobile.nas.task.activity.accepted", in: app), contains: "request was sent"); screenshot(app, "Run request accepted without claiming execution success")
        openTask("12", app); reveal("mobile.nas.task.delete", in: app).tap(); tap("mobile.nas.task.cancel", app)
        reveal("mobile.nas.task.delete", in: app).tap(); tap("mobile.nas.task.confirm", app); waitClosed(app)
        XCTAssertFalse(element("mobile.nas.task.row.12", app).exists); XCTAssertTrue(app.staticTexts["No Tasks"].exists)
    }
    func test编辑未知重启后完整回读恢复() {
        let app = launch("nas-tasks-unknown")
        openTask("12", app); reveal("mobile.nas.task.edit", in: app).tap()
        replace("name", text: "Updated Task", app); replace("script", text: "echo updated", app)
        app.buttons["mobile.nas.task.save"].tap(); tap("mobile.nas.task.confirm", app)
        // 提交后确认页会关闭，先等原编辑页恢复，再查找其中的操作结果。
        XCTAssertTrue(app.collectionViews["mobile.nas.task.confirmation"].waitForNonExistence(timeout: 8))
        expect(reveal("mobile.nas.task.operationResult", in: app), contains: "not available yet")
        XCTAssertFalse(app.buttons["mobile.nas.task.save"].isEnabled); screenshot(app, "Unknown task edit keeps its operation record"); app.terminate()
        let next = launch("nas-tasks-recover", preserve: true); defer { next.terminate() }
        expect(reveal("mobile.nas.task.activity.succeeded", in: next), contains: "saved")
        openTask("12", next); XCTAssertTrue(next.staticTexts["Updated Task"].exists)
        expect(reveal("mobile.nas.task.scriptPreview", in: next), contains: "echo updated"); screenshot(next, "Task edit restored by readback after relaunch")
    }
    func test未知运行重启后仍不可重复且可查看运行记录() {
        let app = launch("nas-tasks-run-unknown")
        openTask("12", app); reveal("mobile.nas.task.run", in: app).tap(); tap("mobile.nas.task.confirm", app)
        expect(reveal("mobile.nas.task.operationResult", in: app), contains: "may have reached"); app.terminate()
        let next = launch(preserve: true); defer { next.terminate() }
        expect(reveal("mobile.nas.task.activity.submitted", in: next), contains: "may have reached")
        openTask("12", next); XCTAssertFalse(reveal("mobile.nas.task.run", in: next).isEnabled)
        reveal("mobile.nas.task.results", in: next).tap(); XCTAssertTrue(element("mobile.nas.task.result.result-1", next).waitForExistence(timeout: 5))
        tap("mobile.nas.task.resultsDone", next); XCTAssertFalse(reveal("mobile.nas.task.run", in: next).isEnabled)
        screenshot(next, "Unknown run remains protected despite existing history")
    }
    func test权限撤回与明确拒绝保持失败() {
        let app = launch("nas-tasks-denied")
        openTask("12", app); reveal("mobile.nas.task.run", in: app).tap(); tap("mobile.nas.task.confirm", app)
        expect(reveal("mobile.nas.task.operationResult", in: app), contains: "cannot perform"); XCTAssertFalse(element("mobile.nas.task.activity.accepted", app).exists); app.terminate()
        let readonly = launch("nas-tasks-readonly"); defer { readonly.terminate() }
        expect(element("mobile.nas.task.error", readonly), contains: "cannot perform")
        XCTAssertFalse(readonly.buttons["mobile.nas.task.create"].isEnabled)
        openTask("12", readonly); XCTAssertFalse(reveal("mobile.nas.task.run", in: readonly).isEnabled)
        screenshot(readonly, "Task permissions revoked without losing readable details")
    }
    func test主动查看记录和完整输出() {
        let app = launch(); defer { app.terminate() }
        openTask("12", app); reveal("mobile.nas.task.results", in: app).tap()
        let record = element("mobile.nas.task.result.result-1", app); XCTAssertTrue(record.waitForExistence(timeout: 5)); record.tap()
        let output = element("mobile.nas.task.output", app)
        expect(output, contains: "SYNTHETIC OUTPUT END")
        expect(element("mobile.nas.task.command", app), contains: "echo synthetic output")
        for _ in 0..<4 { app.collectionViews.firstMatch.swipeUp() }
        screenshot(app, "Full task output remains scrollable to final line")
    }
    func test目录五态筛选和未知开关() {
        for mode in ["nas-tasks", "nas-tasks-loading", "nas-tasks-retry", "nas-tasks-unsupported", "nas-tasks-unknown-enabled"] {
            let app = launch(mode)
            switch mode {
            case "nas-tasks":
                let search = app.textFields["mobile.nas.task.search"]; search.tap(); search.typeText("missing-task\n")
                XCTAssertTrue(element("mobile.nas.task.filteredEmpty", app).waitForExistence(timeout: 5))
                replace("search", text: "Sample", app)
                reveal("mobile.nas.task.filter", in: app).tap(); app.buttons["Disabled"].firstMatch.tap()
                XCTAssertTrue(element("mobile.nas.task.filteredEmpty", app).waitForExistence(timeout: 5))
            case "nas-tasks-loading": XCTAssertTrue(app.staticTexts["Loading tasks…"].waitForExistence(timeout: 8))
            case "nas-tasks-retry": tap("mobile.nas.task.retry", app); XCTAssertTrue(element("mobile.nas.task.row.12", app).waitForExistence(timeout: 8))
            case "nas-tasks-unsupported": XCTAssertTrue(element("mobile.nas.task.retry", app).waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["mobile.nas.task.create"].isEnabled)
            default: expect(element("mobile.nas.task.row.12", app), contains: "Status unavailable")
            }
            screenshot(app, mode); app.terminate()
        }
    }
    func test没有运行记录与读取失败分别呈现() {
        for mode in ["nas-tasks-noresults", "nas-tasks-results-error"] {
            let app = launch(mode); openTask("12", app); reveal("mobile.nas.task.results", in: app).tap()
            if mode == "nas-tasks-noresults" { XCTAssertTrue(app.staticTexts["No Run History"].waitForExistence(timeout: 5)) }
            else { XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 5)); XCTAssertFalse(app.staticTexts["No Run History"].exists) }
            screenshot(app, mode); app.terminate()
        }
    }
    func test仅v3可停用且非脚本任务保留运行入口() {
        let app = launch("nas-tasks-v3")
        XCTAssertFalse(app.buttons["mobile.nas.task.create"].isEnabled); openTask("12", app)
        XCTAssertFalse(element("mobile.nas.task.edit", app).exists)
        let disable = reveal("mobile.nas.task.enable", in: app); XCTAssertTrue(disable.isEnabled); disable.tap(); tap("mobile.nas.task.confirm", app); waitClosed(app)
        expect(element("mobile.nas.task.row.12", app), contains: "Disabled"); app.terminate()
        let other = launch("nas-tasks-non-script"); defer { other.terminate() }
        openTask("12", other); XCTAssertFalse(element("mobile.nas.task.edit", other).exists)
        reveal("mobile.nas.task.run", in: other).tap(); tap("mobile.nas.task.confirm", other); waitClosed(other)
        expect(reveal("mobile.nas.task.activity.accepted", in: other), contains: "request was sent")
    }
    func test中文大字编辑与脚本风险确认可取消() {
        let app = launch(chinese: true, large: true); defer { app.terminate() }
        openTask("12", app); reveal("mobile.nas.task.edit", in: app).tap()
        reveal("mobile.nas.task.enabled", in: app).switches.firstMatch.tap(); screenshot(app, "Chinese large task editor")
        app.buttons["mobile.nas.task.save"].tap(); XCTAssertTrue(element("mobile.nas.task.confirm", app).waitForExistence(timeout: 5))
        expect(element("mobile.nas.task.warning", app), contains: "文件或系统设置"); screenshot(app, "Chinese large task script warning")
        tap("mobile.nas.task.cancel", app); tap("mobile.nas.task.done", app)
        XCTAssertTrue(reveal("mobile.nas.task.results", in: app).isHittable); tap("mobile.nas.task.done", app); waitClosed(app)
        XCTAssertFalse(element("mobile.nas.task.activity.succeeded", app).exists)
    }
    private func openTask(_ id: String, _ app: XCUIApplication) {
        reveal("mobile.nas.task.row.\(id)", in: app).tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["mobile.nas.task.done"].exists && !self.element("mobile.nas.task.detailLoading", app).exists
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
    }
    private func pick(_ field: String, value: String, _ app: XCUIApplication) {
        reveal("mobile.nas.task.\(field)", in: app).tap(); let item = app.buttons[value].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
    }
    private func replace(_ id: String, text: String, _ app: XCUIApplication) {
        let field: XCUIElement = id == "script" ? app.textViews["mobile.nas.task.script"] : app.textFields["mobile.nas.task.\(id)"]
        _ = reveal("mobile.nas.task.\(id)", in: app); field.tap()
        let original = field.value as? String ?? ""
        if original.isEmpty || original == field.placeholderValue { field.typeText(text) }
        else {
            // 合成原值均为单行：点入末尾后退格替换，并严格核对完整文本，不依赖全选菜单或快捷键。
            if id == "script", app.frame.width < 600 {
                // iPhone 的 TextEditor 点击空白后可能仍在行首，用方向键明确移动到原值末尾。
                for _ in original { field.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: []) }
            } else {
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: id == "script" ? 0.12 : 0.8)).tap()
            }
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count) + text)
        }
        XCTAssertEqual(field.value as? String, text)
        let done = element("mobile.nas.task.keyboardDone", app)
        if done.exists && done.isHittable { done.tap() }
        else if id == "search" { field.typeText("\n") }
    }
    private func waitClosed(_ app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.collectionViews["mobile.nas.task.editor"].exists && app.buttons["mobile.nas.task.create"].isHittable
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }
    private func tap(_ id: String, _ app: XCUIApplication) {
        let query = app.buttons.matching(identifier: id)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in query.allElementsBoundByIndex.contains { $0.isHittable } }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        guard let button = query.allElementsBoundByIndex.last(where: { $0.isHittable }) else { return XCTFail("当前弹窗按钮不可点击") }; button.tap()
    }
    private func launch(_ state: String = "nas-tasks", preserve: Bool = false, chinese: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if preserve { app.launchArguments.append("--ui-preserve-transfer-fixture") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", title: chinese ? "App 设置" : "App settings", app)
        _ = reveal("mobile.settings.module.nasSettings", in: app)
        MobileUITestNavigation.enableModule(app, module: "nasSettings", test: self)
        navigate("nasSettings", title: chinese ? "NAS 设置" : "NAS settings", app)
        let link = element("mobile.nas.page.scheduledTasks", app)
        let list = app.collectionViews["mobile.nas.navigation"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        for _ in 0..<14 {
            if link.exists && link.isHittable { break }
            scroll(list, upward: !link.exists || link.frame.minY > list.frame.minY, in: app)
        }
        XCTAssertTrue(link.waitForExistence(timeout: 8)); XCTAssertTrue(link.isHittable); link.tap()
        XCTAssertTrue(app.buttons["mobile.nas.task.create"].waitForExistence(timeout: 8)); return app
    }
    private func navigate(_ destination: String, title: String, _ app: XCUIApplication) {
        MobileUITestNavigation.open(app, destination: destination, title: title, test: self)
    }
    private func expect(_ value: XCUIElement, contains text: String) {
        XCTAssertTrue(value.waitForExistence(timeout: 8))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: value)], timeout: 10), .completed)
    }
    private func reveal(_ id: String, in app: XCUIApplication) -> XCUIElement {
        var value = element(id, app)
        for attempt in 0..<14 {
            // 确认页、编辑页和详情可能同时留在辅助功能树中，不按树顺序猜测当前弹窗。
            let forms = ["confirmation", "editor", "detail", "directory"].map { app.collectionViews["mobile.nas.task.\($0)"] }
            let scroller = forms.first(where: { $0.exists }) ?? app.collectionViews.containing(.any, identifier: id).firstMatch
            value = scroller.descendants(matching: .any).matching(identifier: id).firstMatch
            if value.waitForExistence(timeout: 1), !value.frame.isEmpty {
                let top = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? scroller.frame.minY
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

import XCTest

/// 导航重建期间以真实按钮的可操作状态为准，并在失败时保留当前界面证据。
@MainActor
enum MobileUITestNavigation {
    static func enableModule(_ app: XCUIApplication, module: String, test: XCTestCase,
                             file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.switches["mobile.settings.module.\(module)"]
        revealModule(toggle, in: app)
        let control = toggle.switches.firstMatch
        // 外层等待须覆盖系统的 30 秒查询期限；同为 30 秒时，云端查询曾在 29.2 秒被提前中断。
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: control)
        let readyResult = XCTWaiter.wait(for: [ready], timeout: 45)
        if readyResult != .completed { capture(app, name: "Enable \(module) readiness", test: test) }
        XCTAssertEqual(readyResult, .completed, "功能开关尚未可操作：\(module)", file: file, line: line)
        guard readyResult == .completed else { return }
        let isEnabled = control.isEnabled
        if !isEnabled { capture(app, name: "Enable \(module) disabled", test: test) }
        XCTAssertTrue(isEnabled, "功能开关当前不可用：\(module)", file: file, line: line)
        guard isEnabled else { return }
        // 云端已观察到触控分发延后约 0.31 秒；按住后再拖动，为原生开关接收起始触控留出时间。
        // 仍只操作一次，不在失败后重试，随后检查真实开启状态。
        if toggle.value as? String == "0" {
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).press(forDuration: 0.5,
                thenDragTo: control.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        // 开启聊天会插入通知区域；大字号下原开关会移出可见列表，先滚回原控件再读取新值。
        revealModule(toggle, in: app)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        var result = XCTWaiter.wait(for: [enabled], timeout: 10)
        if result != .completed {
            capture(app, name: "Enable \(module) initial gesture", test: test)
            // 首次滑动未改变本地功能开关时，先核实仍为关闭再补一次原生点击；绝不盲目反向切换。
            revealModule(toggle, in: app)
            if toggle.value as? String == "0", control.exists, control.isEnabled, control.isHittable {
                control.tap()
                // XCTest 不允许同一个 expectation 再次 wait；补点击后必须重新创建等待对象。
                let retried = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
                result = XCTWaiter.wait(for: [retried], timeout: 10)
            }
        }
        if result != .completed { capture(app, name: "Enable \(module)", test: test) }
        XCTAssertEqual(result, .completed, "功能开关没有开启：\(module)", file: file, line: line)
    }

    static func open(_ app: XCUIApplication, destination: String, title: String, test: XCTestCase,
                     file: StaticString = #filePath, line: UInt = #line) {
        let tab = app.tabBars.buttons[title]
        let sidebar = app.buttons["mobile.navigation.\(destination)"]
        let more = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["More", "更多"])).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (tab.exists && tab.isHittable) || (sidebar.exists && sidebar.isHittable) || (more.exists && more.isHittable)
        }, object: app)
        // 云端整轮查询曾耗时约十秒，可点击结果比外层超时晚三毫秒返回；须留出完整查询与再次核对的余量。
        let result = XCTWaiter.wait(for: [ready], timeout: 30)
        if result != .completed { capture(app, name: "Navigation to \(destination)", test: test) }
        XCTAssertEqual(result, .completed, "目标导航按钮尚未可操作：\(destination)", file: file, line: line)
        guard result == .completed else { return }
        // 云端曾在一次瞬时点击后仍停留原页；使用完整按下/抬起，并检查设置页确已呈现。
        if tab.exists && tab.isHittable {
            tab.press(forDuration: 0.15)
            var selected = tab.wait(for: \.isSelected, toEqual: true, timeout: 10)
            if !selected {
                // iPhone 标签栏也已观察到 HID 丢弃并取消触控；仅恢复一次未完成的只读导航。
                capture(app, name: "Tab first selection to \(destination)", test: test)
                if tab.exists && tab.isEnabled && tab.isHittable && !tab.isSelected {
                    tab.press(forDuration: 0.15)
                }
                selected = tab.wait(for: \.isSelected, toEqual: true, timeout: 10)
            }
            if !selected { capture(app, name: "Tab selection to \(destination)", test: test) }
            XCTAssertTrue(selected, "标签栏尚未切换到目标功能：\(destination)", file: file, line: line)
            guard selected else { return }
        }
        else if sidebar.exists && sidebar.isHittable {
            // 保留完整按下/抬起；侧栏同样检查选中状态并恢复已观察到的触控取消。
            sidebar.press(forDuration: 0.4)
            var selected = sidebar.wait(for: \.isSelected, toEqual: true, timeout: 10)
            if !selected {
                // 云端 HID 重复登记会丢弃抬起并取消本次触控；延长按压不能补回事件。
                // 先封存第一次未切换的证据，再至多补一次只读导航；不用于任何业务提交。
                capture(app, name: "Sidebar first selection to \(destination)", test: test)
                if sidebar.exists && sidebar.isEnabled && sidebar.isHittable && !sidebar.isSelected {
                    sidebar.press(forDuration: 0.4)
                }
                selected = sidebar.wait(for: \.isSelected, toEqual: true, timeout: 10)
            }
            if !selected { capture(app, name: "Sidebar selection to \(destination)", test: test) }
            XCTAssertTrue(selected, "侧栏尚未切换到目标功能：\(destination)", file: file, line: line)
            guard selected else { return }
        }
        else {
            XCTAssertTrue(more.exists, file: file, line: line); XCTAssertTrue(more.isHittable, file: file, line: line); more.tap()
            let item = app.staticTexts[title].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10), file: file, line: line)
            XCTAssertTrue(item.isHittable, file: file, line: line); item.tap()
        }
        if destination == "settings" {
            let page = app.collectionViews["mobile.settings.page"]
            let appeared = page.waitForExistence(timeout: 10)
            if !appeared { capture(app, name: "Settings presentation", test: test) }
            XCTAssertTrue(appeared, "设置页尚未呈现", file: file, line: line)
        }
    }

    /// 菜单展开是独立的只读导航步骤；等实际菜单项出现后才允许调用方继续操作。
    @discardableResult
    static func openMenu(_ menu: XCUIElement, showing item: XCUIElement, in app: XCUIApplication,
                         test: XCTestCase, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ready = menu.wait(for: \.isHittable, toEqual: true, timeout: 10)
        if !ready { capture(app, name: "Menu readiness", test: test) }
        XCTAssertTrue(ready, "菜单入口尚未可操作", file: file, line: line)
        guard ready else { return false }
        menu.tap()
        // 系统菜单已暴露标识时仍可能返回无限坐标或零尺寸；此时不能提交点击。
        let itemReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard item.exists else { return false }
            let frame = item.frame
            return frame.origin.x.isFinite && frame.origin.y.isFinite
                && frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
                && item.isHittable
        }, object: item)
        let result = XCTWaiter.wait(for: [itemReady], timeout: 10)
        if result != .completed { capture(app, name: "Menu presentation", test: test) }
        XCTAssertEqual(result, .completed, "菜单项尚未完成布局或不可操作", file: file, line: line)
        return result == .completed
    }

    static func capture(_ app: XCUIApplication, name: String, test: XCTestCase) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) hierarchy"; hierarchy.lifetime = .keepAlways; test.add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name) state"; screenshot.lifetime = .keepAlways; test.add(screenshot)
    }

    private static func revealModule(_ toggle: XCUIElement, in app: XCUIApplication) {
        let settings = app.collectionViews["mobile.settings.page"]
        for _ in 0..<8 {
            // 外层 SwiftUI 开关行可命中，并不代表其中接收触控的原生 Switch 已在屏幕内。
            // 须同时核对实际控件，避免在不可操作的子控件上耗尽 XCTest 查询时间。
            let control = toggle.switches.firstMatch
            if toggle.exists && toggle.isHittable && control.exists && control.isHittable { return }
            settings.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8)).press(forDuration: 0.1,
                thenDragTo: settings.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.3)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
        }
    }
}

import XCTest

/// 导航重建期间以真实按钮的可操作状态为准，并在失败时保留当前界面证据。
@MainActor
enum MobileUITestNavigation {
    static func enableModule(_ app: XCUIApplication, module: String, test: XCTestCase,
                             file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.switches["mobile.settings.module.\(module)"]
        revealModule(toggle, in: app)
        let control = toggle.switches.firstMatch
        // 云端单次查询已实测超过十秒，不能在快照返回前中断；仍断言真实可点击状态。
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: control)
        let readyResult = XCTWaiter.wait(for: [ready], timeout: 30)
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
        let result = XCTWaiter.wait(for: [enabled], timeout: 10)
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
        // 云端一次辅助功能快照可耗时数秒，须留出再次读取重建后按钮的机会。
        let result = XCTWaiter.wait(for: [ready], timeout: 10)
        if result != .completed { capture(app, name: "Navigation to \(destination)", test: test) }
        XCTAssertEqual(result, .completed, "目标导航按钮尚未可操作：\(destination)", file: file, line: line)
        guard result == .completed else { return }
        // 云端曾在一次瞬时点击后仍停留原页；使用完整按下/抬起，并检查设置页确已呈现。
        if tab.exists && tab.isHittable { tab.press(forDuration: 0.15) }
        else if sidebar.exists && sidebar.isHittable {
            // iPad 的 0.15 秒按压仍曾留在原页；给已观察到的触控分发延迟留出余量。
            sidebar.press(forDuration: 0.4)
            let selected = sidebar.wait(for: \.isSelected, toEqual: true, timeout: 10)
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

    private static func capture(_ app: XCUIApplication, name: String, test: XCTestCase) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) hierarchy"; hierarchy.lifetime = .keepAlways; test.add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name) state"; screenshot.lifetime = .keepAlways; test.add(screenshot)
    }

    private static func revealModule(_ toggle: XCUIElement, in app: XCUIApplication) {
        let settings = app.collectionViews["mobile.settings.page"]
        for _ in 0..<8 {
            if toggle.exists && toggle.isHittable { return }
            settings.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8)).press(forDuration: 0.1,
                thenDragTo: settings.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.3)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
        }
    }
}

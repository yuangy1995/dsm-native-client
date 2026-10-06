import XCTest

/// 导航重建期间以真实按钮的可操作状态为准，并在失败时保留当前界面证据。
@MainActor
enum MobileUITestNavigation {
    static func enableModule(_ app: XCUIApplication, module: String, test: XCTestCase,
                             file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.switches["mobile.settings.module.\(module)"]
        let control = toggle.switches.firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, file: file, line: line)
        // 外层辅助功能框包含整行，中心不是开关；在实际控件上完成一次按下/抬起后检查状态。
        if toggle.value as? String == "0" { control.press(forDuration: 0.15) }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        let result = XCTWaiter.wait(for: [enabled], timeout: 10)
        if result != .completed {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Enable \(module) hierarchy"; hierarchy.lifetime = .keepAlways; test.add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Enable \(module) state"; screenshot.lifetime = .keepAlways; test.add(screenshot)
        }
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
        if result != .completed {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Navigation to \(destination) hierarchy"; hierarchy.lifetime = .keepAlways; test.add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Navigation to \(destination) state"; screenshot.lifetime = .keepAlways; test.add(screenshot)
        }
        XCTAssertEqual(result, .completed, "目标导航按钮尚未可操作：\(destination)", file: file, line: line)
        guard result == .completed else { return }
        if tab.exists && tab.isHittable { tab.tap() }
        else if sidebar.exists && sidebar.isHittable { sidebar.tap() }
        else {
            XCTAssertTrue(more.exists, file: file, line: line); XCTAssertTrue(more.isHittable, file: file, line: line); more.tap()
            let item = app.staticTexts[title].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10), file: file, line: line)
            XCTAssertTrue(item.isHittable, file: file, line: line); item.tap()
        }
    }
}

import XCTest

@MainActor final class MobileContainerNetworkUITests: XCTestCase {
    func test自动创建进入记录并显示地址详情() {
        let app = launch(); defer { app.terminate() }
        openCreation(app); fill("name", "sample-new", app)
        screenshot("Automatic container network creation")
        app.buttons["network.create.submit"].tap(); phase("succeeded", app)
        screenshot("Network creation completed")
        networks(app); app.buttons["network.details.sample-new"].tap()
        XCTAssertTrue(element("network.details", app).waitForExistence(timeout: 8))
        detailValue("Subnet", "192.0.2.0/24", app); detailValue("Gateway", "192.0.2.1", app)
        screenshot("Network address and connection details")
    }
    func test手动IPv4IPv6与伪装完整填写可创建() {
        let app = launch(); defer { app.terminate() }
        openCreation(app); fill("name", "sample-new", app)
        toggle("network.create.ipv4", app); fill("subnet", "192.0.2.0/24", app)
        fill("range", "192.0.2.128/25", app); fill("gateway", "192.0.2.1", app)
        toggle("network.create.ipv6", app); fill("ipv6-subnet", "2001:db8::/64", app)
        fill("ipv6-gateway", "2001:db8::1", app); toggle("network.create.masquerade", app)
        ready(app.buttons["network.create.submit"]); screenshot("Manual IPv4 IPv6 and masquerading form")
        app.buttons["network.create.submit"].tap(); phase("succeeded", app)
        networks(app); reveal("network.details.sample-new", app, list: "network.list").tap()
        XCTAssertTrue(element("network.details", app).waitForExistence(timeout: 8))
        detailValue("IP range", "192.0.2.128/25", app); detailValue("IPv6", "Enabled", app)
        screenshot("Created manual network details")
    }
    func test默认占用网络禁删取消零改变再批量删除() {
        let app = launch(); defer { app.terminate() }
        XCTAssertFalse(app.buttons["network.select.bridge"].isEnabled)
        XCTAssertFalse(app.buttons["network.select.in-use"].isEnabled)
        select("sample-a", app); select("sample-b", app); confirm(app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "The selected networks will be removed from your NAS and cannot be restored automatically. Only networks with no connected containers can be deleted. Containers, images, and files will remain.")).firstMatch.exists)
        screenshot("Network deletion consequences and selected targets")
        app.buttons["Cancel"].tap(); XCTAssertTrue(app.buttons["network.details.sample-a"].waitForExistence(timeout: 8))
        confirm(app); submit(app); phase("succeeded", app)
        XCTAssertEqual(app.cells.containing(.any, identifier: "network.record.succeeded").count, 2)
        screenshot("Two networks deleted with separate results")
        networks(app); XCTAssertFalse(app.buttons["network.details.sample-a"].exists)
        XCTAssertTrue(app.buttons["network.details.bridge"].exists)
    }
    func test未知创建重启同名只显示存在不重发() {
        let app = launch("containers-networks-unknown")
        openCreation(app); fill("name", "sample-new", app); app.buttons["network.create.submit"].tap(); phase("submitted", app)
        XCTAssertFalse(app.buttons["Remove this record"].exists); screenshot("Creation result unknown remains protected"); app.terminate()
        let next = launch("containers-networks-created", preserve: true); defer { next.terminate() }
        records(next); phase("existing", next)
        XCTAssertFalse(element("network.record.succeeded", next).exists)
        screenshot("Existing network after lost creation receipt is not claimed as created")
    }
    func test未知删除重启不重放原网络消失只显示当前结果() {
        let app = launch("containers-networks-unknown")
        select("sample-a", app); confirm(app); submit(app); phase("submitted", app); app.terminate()
        let protected = launch(preserve: true)
        XCTAssertFalse(protected.buttons["network.select.sample-a"].isEnabled)
        records(protected); phase("submitted", protected); screenshot("Unknown deletion retains protection after relaunch"); protected.terminate()
        let restored = launch("containers-networks-recovered", preserve: true); defer { restored.terminate() }
        records(restored); phase("absent", restored)
        XCTAssertFalse(element("network.record.succeeded", restored).exists)
        screenshot("Original network no longer listed after unknown deletion")
    }
    func test部分删除保留成功和权限拒绝() {
        let app = launch("containers-networks-partial"); defer { app.terminate() }
        select("sample-a", app); select("sample-b", app); confirm(app); submit(app)
        phase("rejected", app); phase("succeeded", app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Check your Container Manager permissions")).firstMatch.exists)
        screenshot("Partial network deletion keeps success and refusal separate")
    }
    func test加载空列表错误重试与搜索为空() {
        let loading = launch("containers-networks-loading", waitForList: false)
        XCTAssertTrue(element("network.loading", loading).waitForExistence(timeout: 8)); screenshot("Network loading"); loading.terminate()
        let empty = launch("containers-networks-empty", waitForList: false)
        XCTAssertTrue(element("network.empty", empty).waitForExistence(timeout: 8)); ready(empty.buttons["network.create.open"])
        screenshot("No networks with available creation action"); empty.terminate()
        let retry = launch("containers-networks-read-error", waitForList: false); defer { retry.terminate() }
        XCTAssertTrue(element("network.load-error", retry).waitForExistence(timeout: 8)); screenshot("Network load failure and retry")
        retry.buttons["Try Again"].tap(); XCTAssertTrue(retry.collectionViews["network.list"].waitForExistence(timeout: 8))
        retry.searchFields.firstMatch.tap(); retry.searchFields.firstMatch.typeText("no-matching-network")
        XCTAssertTrue(element("network.filtered-empty", retry).waitForExistence(timeout: 8)); screenshot("Network search has no matches")
    }
    func test中文大字风险与横竖屏创建按钮可达() {
        let app = launch(chinese: true, large: true); defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        select("sample-a", app); confirm(app)
        ready(reveal("network.delete.submit", app, list: "network.delete.form"))
        XCTAssertTrue(app.staticTexts["所选网络将从 NAS 删除，无法自动恢复。只能删除没有连接容器的网络，容器、映像和文件会保留。"].exists)
        screenshot("Chinese large text network deletion confirmation"); app.buttons["取消"].tap()
        openCreation(app); fill("name", "sample-new", app)
        XCUIDevice.shared.orientation = .landscapeLeft; ready(app.buttons["network.create.submit"])
        screenshot("Landscape large text network creation")
        app.buttons["取消"].tap(); XCTAssertTrue(app.collectionViews["network.list"].waitForExistence(timeout: 8))
    }
    private func launch(_ mode: String = "containers-networks", preserve: Bool = false, chinese: Bool = false,
                        large: Bool = false, waitForList: Bool = true) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if preserve { app.launchArguments.append("--ui-preserve-transfer-fixture") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = mode; app.launch()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        MobileUITestNavigation.open(app, destination: "settings", title: chinese ? "App 设置" : "App settings", test: self)
        MobileUITestNavigation.enableModule(app, module: "containers", test: self)
        MobileUITestNavigation.open(app, destination: "containers", title: chinese ? "容器管理" : "Containers", test: self)
        ready(app.buttons["network.open"]); app.buttons["network.open"].tap()
        XCTAssertTrue(app.segmentedControls["network.section"].waitForExistence(timeout: 8))
        if waitForList { XCTAssertTrue(app.collectionViews["network.list"].waitForExistence(timeout: 8)) }
        return app
    }
    private func openCreation(_ app: XCUIApplication) {
        ready(app.buttons["network.create.open"]); app.buttons["network.create.open"].tap()
        XCTAssertTrue(app.collectionViews["network.create.form"].waitForExistence(timeout: 8))
    }
    private func fill(_ id: String, _ text: String, _ app: XCUIApplication) {
        let field = reveal("network.create.\(id)", app, list: "network.create.form")
        ready(field); field.tap(); field.typeText(text)
    }
    private func toggle(_ id: String, _ app: XCUIApplication) {
        let row = reveal(id, app, list: "network.create.form"), control = row.switches.firstMatch
        ready(control); control.press(forDuration: 0.15)
        _ = reveal(id, app, list: "network.create.form")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: row)
        let result = XCTWaiter.wait(for: [enabled], timeout: 8)
        if result != .completed {
            let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = "Network toggle hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            screenshot("Network toggle did not change")
        }
        XCTAssertEqual(result, .completed)
    }
    private func select(_ name: String, _ app: XCUIApplication) { let control = reveal("network.select.\(name)", app, list: "network.list"); ready(control); control.tap() }
    private func confirm(_ app: XCUIApplication) { ready(app.buttons["network.delete.confirm"]); app.buttons["network.delete.confirm"].tap(); XCTAssertTrue(app.collectionViews["network.delete.form"].waitForExistence(timeout: 8)) }
    private func submit(_ app: XCUIApplication) { let button = reveal("network.delete.submit", app, list: "network.delete.form"); ready(button); button.tap() }
    private func records(_ app: XCUIApplication) { app.segmentedControls["network.section"].buttons["Activity"].tap() }
    private func networks(_ app: XCUIApplication) { app.segmentedControls["network.section"].buttons["Networks"].tap(); XCTAssertTrue(app.collectionViews["network.list"].waitForExistence(timeout: 8)) }
    private func phase(_ value: String, _ app: XCUIApplication) { XCTAssertTrue(element("network.record.\(value)", app).waitForExistence(timeout: 15)) }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func ready(_ element: XCUIElement) {
        // 云端每次 AX 查询可耗时数秒；只轮询可点击状态，避免三次串行查询耗尽同一期限。
        XCTAssertTrue(element.wait(for: \.isHittable, toEqual: true, timeout: 12))
        XCTAssertTrue(element.exists); XCTAssertTrue(element.isEnabled)
    }
    private func detailValue(_ label: String, _ value: String, _ app: XCUIApplication) {
        let detail = element("network.details", app)
        let field = detail.staticTexts.matching(NSPredicate(format: "label == %@", "\(label), \(value)")).firstMatch
        let exists = field.waitForExistence(timeout: 8)
        if !exists {
            let attachment = XCTAttachment(string: app.debugDescription); attachment.name = "Network detail hierarchy"; attachment.lifetime = .keepAlways; add(attachment)
            screenshot("Network detail value unavailable")
        }
        XCTAssertTrue(exists, "缺少网络详情值：\(value)")
    }
    private func reveal(_ id: String, _ app: XCUIApplication, list: String) -> XCUIElement {
        let target = element(id, app), container = app.collectionViews[list]
        for _ in 0..<12 {
            let frame = container.frame
            let top = max(frame.minY, app.navigationBars.allElementsBoundByIndex.last?.frame.maxY ?? frame.minY)
            var bottom = frame.maxY
            for blocker in [app.keyboards.firstMatch, app.otherElements["SystemInputAssistantView"]] where blocker.exists {
                let edge = blocker.frame.minY
                if edge > top { bottom = min(bottom, edge) }
            }
            if target.exists && target.isHittable && target.frame.minY > top + 10 && target.frame.maxY < bottom - 10 { return target }
            let above = target.exists && target.frame.minY < top + 10
            let start = (top + (bottom - top) * (above ? 0.25 : 0.78) - frame.minY) / frame.height
            let end = (top + (bottom - top) * (above ? 0.60 : 0.38) - frame.minY) / frame.height
            container.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: start))
                .press(forDuration: 0.05, thenDragTo: container.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: end)), withVelocity: .slow, thenHoldForDuration: 0.05)
        }
        return target
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

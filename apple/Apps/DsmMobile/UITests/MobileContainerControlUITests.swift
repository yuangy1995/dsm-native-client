import XCTest

@MainActor final class MobileContainerControlUITests: XCTestCase {
    func test普通套件账号可以启动并查看结果() {
        let app = launch(); defer { app.terminate() }
        detail("synthetic-id", app)
        let start = reveal("container.action.start", app); waitEnabled(start); start.tap()
        XCTAssertTrue(app.staticTexts["Sample container"].exists)
        reveal("container.confirm", app).tap()
        openRecords(app); expectPhase("succeeded", app)
        XCTAssertTrue(app.staticTexts["Started"].exists)
        screenshot(app, "Container started by a non-administrator account")
    }
    func test停止确认取消不改变状态重新确认后停止() {
        let app = launch("containers-running"); defer { app.terminate() }; detail("synthetic-id", app)
        reveal("container.action.stop", app).tap()
        XCTAssertTrue(app.staticTexts["Stopping these containers will make their services unavailable."].exists)
        screenshot(app, "Container stop service interruption confirmation")
        app.buttons["Cancel"].tap(); XCTAssertTrue(app.collectionViews["container.confirmation"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(reveal("container.action.stop", app).isEnabled)
        reveal("container.action.stop", app).tap(); reveal("container.confirm", app).tap()
        openRecords(app); expectPhase("succeeded", app); XCTAssertTrue(app.staticTexts["Stopped"].exists)
        screenshot(app, "Container stopped and read back")
    }
    func test重新启动完成后显示实际结果() {
        let app = launch("containers-running"); detail("synthetic-id", app)
        reveal("container.action.restart", app).tap(); reveal("container.confirm", app).tap()
        openRecords(app); expectPhase("succeeded", app); XCTAssertTrue(app.staticTexts["Restarted"].exists)
        screenshot(app, "Container restart verified by changed start time"); app.terminate()
    }
    func test多项启动保留逐项结果与托管限制() {
        let app = launch(); defer { app.terminate() }
        let select = app.buttons["container.selection"]; waitEnabled(select); select.tap()
        XCTAssertFalse(reveal("container.select.managed-id", app).isEnabled)
        reveal("container.select.synthetic-id", app).tap(); reveal("container.select.worker-b", app).tap()
        reveal("container.action.start", app).tap()
        XCTAssertTrue(app.staticTexts["Sample container"].exists); XCTAssertTrue(app.staticTexts["Worker B"].exists)
        screenshot(app, "Two containers selected for start")
        reveal("container.confirm", app).tap(); app.buttons["Done"].tap()
        openRecords(app); expectPhase("succeeded", app)
        let completed = app.cells.containing(.any, identifier: "container.record.succeeded")
        let two = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: completed)
        XCTAssertEqual(XCTWaiter.wait(for: [two], timeout: 8), .completed)
        XCTAssertTrue(completed.element(boundBy: 0).staticTexts["Sample container"].exists)
        XCTAssertTrue(completed.element(boundBy: 1).staticTexts["Worker B"].exists)
        screenshot(app, "Both container results are visible")
    }
    func test未知结果跨重启恢复而非再次提交() {
        let app = launch("containers-unknown"); detail("synthetic-id", app)
        reveal("container.action.start", app).tap(); reveal("container.confirm", app).tap()
        openRecords(app); expectPhase("submitted", app)
        XCTAssertFalse(app.buttons["Remove this record"].exists)
        screenshot(app, "Unknown container action remains protected"); app.terminate()
        let next = launch("containers-recover", preserve: true); defer { next.terminate() }
        openRecords(next); expectPhase("succeeded", next)
        XCTAssertTrue(next.buttons["Remove this record"].exists)
        screenshot(next, "Container action recovered by read after relaunch")
    }
    func test活动记录包含正文和用户且详情可返回() {
        let app = launch(); defer { app.terminate() }
        section("events", app)
        let item = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Sample container was started.")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 8)); item.tap()
        XCTAssertTrue(app.staticTexts["User, Sample user"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sample container was started."].exists)
        screenshot(app, "Container activity message and user detail")
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
    }
    func test加载空目录错误恢复与筛选为空() {
        let loading = launch("containers-loading")
        XCTAssertTrue(element("container.loading", loading).waitForExistence(timeout: 5)); screenshot(loading, "Container loading"); loading.terminate()
        let empty = launch("containers-empty"); section("containers", empty)
        XCTAssertTrue(element("container.empty", empty).waitForExistence(timeout: 8)); screenshot(empty, "Empty container inventory"); empty.terminate()
        let retry = launch("containers-retry"); section("containers", retry)
        let retryButton = retry.buttons["Try Again"].firstMatch
        XCTAssertTrue(retryButton.waitForExistence(timeout: 8)); screenshot(retry, "Container loading failed with recovery action")
        retryButton.tap(); XCTAssertTrue(element("container.item.synthetic-id", retry).waitForExistence(timeout: 8))
        reveal("container.filter", retry).tap(); retry.buttons["Needs Attention"].tap()
        XCTAssertTrue(retry.buttons["Show All"].waitForExistence(timeout: 5)); screenshot(retry, "Container filter has no matches")
        retry.buttons["Show All"].tap(); XCTAssertTrue(element("container.item.synthetic-id", retry).exists); retry.terminate()
    }
    func test中文大字停止确认按钮和正文完整可用() {
        let app = launch("containers-running", chinese: true, large: true); defer { app.terminate() }; detail("synthetic-id", app)
        reveal("container.action.stop", app).tap()
        let confirm = reveal("container.confirm", app); XCTAssertTrue(confirm.isHittable); XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(app.staticTexts["停止后，容器提供的服务将不可用。"].exists)
        screenshot(app, "Chinese large text container stop confirmation")
        app.buttons["取消"].tap(); XCTAssertTrue(app.collectionViews["container.confirmation"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(reveal("container.action.stop", app).isEnabled)
    }

    func test托管和运行字段缺失均不能提交控制() {
        let managed = launch(); detail("managed-id", managed)
        XCTAssertTrue(managed.staticTexts["This container is managed by a package. Manage that package in Package Center."].exists)
        for action in ["start", "stop", "restart"] { XCTAssertFalse(reveal("container.action.\(action)", managed).isEnabled) }
        screenshot(managed, "Package-managed container explains its restriction"); managed.terminate()
        let missing = launch("containers-missing-state"); defer { missing.terminate() }; detail("synthetic-id", missing)
        for action in ["start", "stop", "restart"] { XCTAssertFalse(reveal("container.action.\(action)", missing).isEnabled) }
        screenshot(missing, "Missing runtime fields never become writable defaults")
    }
    func test旋转后容器详情和确认仍可操作() {
        let app = launch("containers-running"); defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        detail("synthetic-id", app); XCUIDevice.shared.orientation = .landscapeLeft
        waitEnabled(reveal("container.action.stop", app)); screenshot(app, "Landscape container detail")
        XCUIDevice.shared.orientation = .portrait
        reveal("container.action.stop", app).tap(); waitEnabled(reveal("container.confirm", app))
        screenshot(app, "Container confirmation after rotation"); app.buttons["Cancel"].tap()
        XCTAssertTrue(app.collectionViews["container.confirmation"].waitForNonExistence(timeout: 5))
    }

    func test删除明确后果取消零改变再确认删除() {
        let app = launch(); defer { app.terminate() }; detail("synthetic-id", app)
        reveal("container.action.delete", app).tap()
        XCTAssertTrue(app.staticTexts["Deleting a container permanently removes it and any files stored only inside it. Images and data in shared folders are kept."].exists)
        screenshot(app, "Container deletion warns about files stored only inside")
        app.buttons["Cancel"].tap(); XCTAssertTrue(app.collectionViews["container.confirmation"].waitForNonExistence(timeout: 5))
        waitEnabled(reveal("container.action.delete", app))
        reveal("container.action.delete", app).tap(); reveal("container.confirm", app).tap()
        openRecords(app); expectPhase("succeeded", app); XCTAssertTrue(app.staticTexts["Deleted"].exists)
        XCTAssertTrue(app.staticTexts["Sample container"].exists)
        screenshot(app, "Container deletion result remains accessible after the target disappears")
    }
    func test多项删除逐项展示完成且托管容器不可选() {
        let app = launch(); defer { app.terminate() }
        let select = app.buttons["container.selection"]; waitEnabled(select); select.tap()
        XCTAssertFalse(reveal("container.select.managed-id", app).isEnabled)
        reveal("container.select.synthetic-id", app).tap(); reveal("container.select.worker-b", app).tap()
        reveal("container.action.delete", app).tap()
        XCTAssertTrue(app.staticTexts["Sample container"].exists); XCTAssertTrue(app.staticTexts["Worker B"].exists)
        screenshot(app, "Fixed two-container deletion confirmation")
        reveal("container.confirm", app).tap(); app.buttons["Done"].tap(); openRecords(app)
        expectPhase("succeeded", app)
        let completed = app.cells.containing(.any, identifier: "container.record.succeeded")
        let two = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: completed)
        XCTAssertEqual(XCTWaiter.wait(for: [two], timeout: 8), .completed)
        screenshot(app, "Two deleted containers retain separate results")
    }
    func test删除未知跨重启只读恢复且原记录不能移除() {
        let app = launch("containers-unknown"); detail("synthetic-id", app)
        reveal("container.action.delete", app).tap(); reveal("container.confirm", app).tap()
        openRecords(app); expectPhase("submitted", app)
        XCTAssertFalse(app.buttons["Remove this record"].exists)
        screenshot(app, "Unknown container deletion remains protected"); app.terminate()
        let next = launch("containers-delete-recovered", preserve: true); defer { next.terminate() }
        openRecords(next); expectPhase("succeeded", next); XCTAssertTrue(next.staticTexts["Deleted"].exists)
        screenshot(next, "Container deletion recovered without another write after relaunch")
    }
    func test删除被拒绝显示失败而不会显示已删除() {
        let app = launch("containers-reject"); defer { app.terminate() }; detail("synthetic-id", app)
        reveal("container.action.delete", app).tap(); reveal("container.confirm", app).tap()
        openRecords(app); expectPhase("failed", app); XCTAssertFalse(app.staticTexts["Deleted"].exists)
        screenshot(app, "Container deletion permission denial preserves the failed result")
    }
    func test批量删除第二项未知保留第一项完成() {
        let app = launch("containers-partial"); defer { app.terminate() }
        let select = app.buttons["container.selection"]; waitEnabled(select); select.tap()
        reveal("container.select.synthetic-id", app).tap(); reveal("container.select.worker-b", app).tap()
        reveal("container.action.delete", app).tap(); reveal("container.confirm", app).tap()
        app.buttons["Done"].tap(); openRecords(app); expectPhase("succeeded", app); expectPhase("submitted", app)
        XCTAssertFalse(app.buttons["Remove this record"].exists)
        screenshot(app, "Partial container deletion separates completed and unknown targets")
    }
    func test运行托管与缺失状态均不能删除() {
        for mode in ["containers-running", "containers-control", "containers-missing-state"] {
            let app = launch(mode); detail(mode == "containers-control" ? "managed-id" : "synthetic-id", app)
            XCTAssertFalse(reveal("container.action.delete", app).isEnabled)
            screenshot(app, "Unavailable container deletion \(mode)"); app.terminate()
        }
    }
    func test中文大字删除风险完整可读且取消按钮可用() {
        let app = launch(chinese: true, large: true); defer { app.terminate() }; detail("synthetic-id", app)
        reveal("container.action.delete", app).tap()
        XCTAssertTrue(app.staticTexts["删除后，容器及仅保存在容器内部的文件将无法恢复。映像和共享文件夹中的数据会保留。"].exists)
        waitEnabled(reveal("container.confirm", app)); screenshot(app, "Chinese large text container deletion risk and action")
        app.buttons["取消"].tap(); XCTAssertTrue(app.collectionViews["container.confirmation"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(reveal("container.action.delete", app).isEnabled)
    }

    private func launch(_ mode: String = "containers-control", preserve: Bool = false, chinese: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if preserve { app.launchArguments.append("--ui-preserve-transfer-fixture") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = mode; app.launch()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        MobileUITestNavigation.open(app, destination: "settings", title: chinese ? "App 设置" : "App settings", test: self)
        MobileUITestNavigation.enableModule(app, module: "containers", test: self)
        MobileUITestNavigation.open(app, destination: "containers", title: chinese ? "容器管理" : "Containers", test: self)
        return app
    }
    private func section(_ name: String, _ app: XCUIApplication) {
        let value = element("container.section.\(name)", app); XCTAssertTrue(value.waitForExistence(timeout: 12)); value.tap()
    }
    private func detail(_ id: String, _ app: XCUIApplication) {
        section("containers", app); let value = element("container.item.\(id)", app)
        XCTAssertTrue(value.waitForExistence(timeout: 8)); value.tap()
        XCTAssertTrue(app.collectionViews["container.detail"].waitForExistence(timeout: 8))
    }
    private func openRecords(_ app: XCUIApplication) {
        let root = app.buttons["container.records.open"]
        if root.exists && root.isHittable { root.tap() }
        else { let link = app.buttons["Activity"].firstMatch; XCTAssertTrue(link.waitForExistence(timeout: 8)); link.tap() }
        XCTAssertTrue(element("container.records", app).waitForExistence(timeout: 8))
    }
    private func expectPhase(_ phase: String, _ app: XCUIApplication) { XCTAssertTrue(element("container.record.\(phase)", app).waitForExistence(timeout: 12)) }
    private func waitEnabled(_ value: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: value)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 12), .completed)
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    @discardableResult private func reveal(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let list = ["container.confirmation", "container.selection.list", "container.detail", "container.items"].map { app.collectionViews[$0] }.first { $0.exists } ?? app.collectionViews.firstMatch
        let value = element(id, app)
        for _ in 0..<14 {
            if value.exists, !value.frame.isEmpty, value.frame.midY > max(100, list.frame.minY + 20),
               value.frame.midY < min(list.frame.maxY - 10, app.frame.maxY - 35), value.isHittable || !value.isEnabled { return value }
            let down = value.exists && value.frame.minY < list.frame.minY + 20
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: down ? 0.3 : 0.8)).press(forDuration: 0.1,
                thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: down ? 0.8 : 0.3)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "Container hierarchy"; tree.lifetime = .keepAlways; add(tree)
        screenshot(app, "Container control unavailable"); XCTFail("控件不可操作：\(id)"); return value
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        // 捕获整个设备，避免旋转后的应用窗口裁切横屏附件。
        let value = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value)
    }
}

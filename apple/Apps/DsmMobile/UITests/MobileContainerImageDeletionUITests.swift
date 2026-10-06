import XCTest

@MainActor final class MobileContainerImageDeletionUITests: XCTestCase {
    func test多标签确认取消后删除并保留其他标签() {
        let app = launch(); defer { app.terminate() }
        select("sample/web", "stable", app); select("sample/web", "v1", app); confirm(app)
        XCTAssertTrue(app.staticTexts["The selected tags will be deleted from your NAS. This cannot be undone. Other tags for the same image will remain."].exists)
        screenshot("Two image tags with explicit deletion consequences")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["image-delete.select.sample/web.stable"].waitForExistence(timeout: 8))
        confirm(app); submit(app); phase("succeeded", app)
        XCTAssertEqual(app.cells.containing(.any, identifier: "image-delete.record.succeeded").count, 2)
        screenshot("Selected tags deleted with individual results")
        app.segmentedControls["image-delete.section"].buttons["Images"].tap()
        XCTAssertTrue(app.buttons["image-delete.select.sample/web.latest"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["image-delete.select.sample/web.stable"].exists)
        XCTAssertFalse(app.buttons["image-delete.select.sample/web.v1"].exists)
    }
    func test停止容器占用不可删除而无标签映像明确整体删除() {
        let app = launch(); defer { app.terminate() }
        XCTAssertFalse(reveal("image-delete.select.sample/used.latest", app, list: "image-delete.images").isEnabled)
        select("sample/cache", "<none>", app); confirm(app)
        XCTAssertTrue(app.staticTexts["Untagged images will be deleted entirely. This cannot be undone."].exists)
        screenshot("Untagged image requires complete deletion confirmation")
        submit(app); phase("succeeded", app)
        app.segmentedControls["image-delete.section"].buttons["Images"].tap()
        XCTAssertTrue(app.buttons["image-delete.select.sample/web.latest"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["image-delete.select.sample/cache.<none>"].exists)
    }
    func test部分删除跨重启只恢复剩余结果() {
        let app = launch("containers-image-delete-partial")
        select("sample/web", "stable", app); select("sample/web", "v1", app); confirm(app); submit(app)
        phase("submitted", app); phase("succeeded", app)
        XCTAssertEqual(app.cells.containing(.any, identifier: "image-delete.record.succeeded").count, 1)
        XCTAssertFalse(app.buttons["Remove this record"].exists)
        screenshot("Partial image deletion preserves unfinished targets"); app.terminate()
        let next = launch("containers-image-delete-recovered", preserve: true); defer { next.terminate() }
        records(next); phase("succeeded", next)
        XCTAssertEqual(next.cells.containing(.any, identifier: "image-delete.record.succeeded").count, 2)
        for name in ["Image 1", "Image 2"] {
            XCTAssertTrue(next.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.exists)
        }
        screenshot("Original deletion results restored after relaunch")
        next.buttons["Remove this record"].tap(); XCTAssertTrue(next.staticTexts["No activity yet"].waitForExistence(timeout: 8))
    }
    func test无回执重启后保留保护且不能重复删除() {
        let app = launch("containers-image-delete-unknown")
        select("sample/web", "stable", app); confirm(app); submit(app); phase("submitted", app); app.terminate()
        let next = launch(preserve: true); defer { next.terminate() }
        records(next); phase("submitted", next)
        XCTAssertFalse(next.buttons["Remove this record"].exists); screenshot("Unknown deletion remains protected after relaunch")
        next.segmentedControls["image-delete.section"].buttons["Images"].tap()
        XCTAssertFalse(reveal("image-delete.select.sample/web.stable", next, list: "image-delete.images").isEnabled)
    }
    func test明确拒绝显示权限原因且可移除终态记录() {
        let app = launch("containers-image-delete-denied"); defer { app.terminate() }
        select("sample/web", "stable", app); confirm(app); submit(app); phase("rejected", app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Check your Container Manager permissions")).firstMatch.exists)
        screenshot("Image deletion denied with permission recovery guidance")
        app.buttons["Remove this record"].tap(); XCTAssertTrue(app.staticTexts["No activity yet"].waitForExistence(timeout: 8))
    }
    func test加载空内容错误重试和搜索为空() {
        let loading = launch("containers-image-delete-loading", waitForList: false)
        XCTAssertTrue(element("image-delete.loading", loading).waitForExistence(timeout: 8)); screenshot("Image deletion list loading"); loading.terminate()
        let empty = launch("containers-image-delete-empty", waitForList: false)
        XCTAssertTrue(element("image-delete.empty", empty).waitForExistence(timeout: 8)); screenshot("Image deletion list is empty"); empty.terminate()
        let retry = launch("containers-image-delete-read-error", waitForList: false); defer { retry.terminate() }
        XCTAssertTrue(element("image-delete.load-error", retry).waitForExistence(timeout: 8)); screenshot("Image deletion list error")
        retry.buttons["Try Again"].tap(); XCTAssertTrue(retry.collectionViews["image-delete.images"].waitForExistence(timeout: 8))
        let field = retry.searchFields.firstMatch; field.tap(); field.typeText("no-matching-image")
        XCTAssertTrue(element("image-delete.filtered-empty", retry).waitForExistence(timeout: 8))
        XCTAssertFalse(retry.buttons["image-delete.selection.confirm"].isEnabled); screenshot("Image deletion filter has no matches")
    }
    func test中文大字确认目标风险和取消可达() {
        let app = launch(chinese: true, large: true); defer { app.terminate() }
        select("sample/web", "stable", app); confirm(app)
        let button = reveal("image-delete.submit", app, list: "image-delete.confirmation"); waitEnabled(button)
        XCTAssertTrue(app.staticTexts["所选标签将从 NAS 删除，无法撤销。同一映像的其他标签会保留。"].exists)
        XCTAssertTrue(app.staticTexts["sample/web:stable"].exists); screenshot("Chinese large text image deletion confirmation")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["image-delete.select.sample/web.stable"].waitForExistence(timeout: 8))
    }
    func test横竖屏删除确认与返回可用() {
        let app = launch(); defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        select("sample/web", "stable", app); confirm(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitEnabled(reveal("image-delete.submit", app, list: "image-delete.confirmation")); screenshot("Landscape image deletion confirmation")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Cancel"].tap(); XCTAssertTrue(app.buttons["image-delete.select.sample/web.stable"].waitForExistence(timeout: 8))
    }
    func test未结束删除阻止同标签下载并说明原因() {
        let app = launch("containers-image-delete-unknown"); defer { app.terminate() }
        select("sample/web", "stable", app); confirm(app); submit(app); phase("submitted", app)
        app.buttons["Close"].tap(); waitEnabled(app.buttons["image-pull.open"]); app.buttons["image-pull.open"].tap()
        let field = app.searchFields.firstMatch; XCTAssertTrue(field.waitForExistence(timeout: 8)); field.tap(); field.typeText("sample\n")
        let image = element("image-pull.result.docker.io/sample/web", app); XCTAssertTrue(image.waitForExistence(timeout: 8)); image.tap()
        XCTAssertTrue(app.collectionViews["image-pull.target"].waitForExistence(timeout: 8))
        waitEnabled(app.buttons["image-pull.tag-picker"]); app.buttons["image-pull.tag-picker"].tap()
        waitEnabled(app.buttons["stable"]); app.buttons["stable"].tap()
        let download = reveal("image-pull.download", app, list: "image-pull.target")
        XCTAssertFalse(download.isEnabled)
        XCTAssertTrue(app.staticTexts["This image has an unfinished deletion. Refresh its deletion records before downloading it."].exists)
        screenshot("Pending image deletion prevents downloading the same tag")
    }
    private func launch(_ mode: String = "containers-image-delete", preserve: Bool = false, chinese: Bool = false,
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
        waitEnabled(app.buttons["image-delete.open"]); app.buttons["image-delete.open"].tap()
        XCTAssertTrue(app.segmentedControls["image-delete.section"].waitForExistence(timeout: 8))
        if waitForList { XCTAssertTrue(app.collectionViews["image-delete.images"].waitForExistence(timeout: 8)) }
        return app
    }
    private func select(_ repository: String, _ tag: String, _ app: XCUIApplication) {
        let button = reveal("image-delete.select.\(repository).\(tag)", app, list: "image-delete.images"); waitEnabled(button); button.tap()
    }
    private func confirm(_ app: XCUIApplication) {
        let button = app.buttons["image-delete.selection.confirm"]; waitEnabled(button); button.tap()
        XCTAssertTrue(app.collectionViews["image-delete.confirmation"].waitForExistence(timeout: 8))
    }
    private func submit(_ app: XCUIApplication) {
        let button = reveal("image-delete.submit", app, list: "image-delete.confirmation"); waitEnabled(button); button.tap()
    }
    private func records(_ app: XCUIApplication) { app.segmentedControls["image-delete.section"].buttons["Activity"].tap() }
    private func phase(_ value: String, _ app: XCUIApplication) { XCTAssertTrue(element("image-delete.record.\(value)", app).waitForExistence(timeout: 15)) }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func waitEnabled(_ value: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: value)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 12), .completed)
    }
    private func reveal(_ id: String, _ app: XCUIApplication, list listID: String) -> XCUIElement {
        let list = app.collectionViews[listID], button = app.buttons[id]
        for _ in 0..<12 {
            if button.exists, !button.frame.isEmpty, button.frame.midY > max(100, list.frame.minY + 20),
               button.frame.midY < min(list.frame.maxY - 10, app.frame.maxY - 35), button.isHittable || !button.isEnabled { return button }
            let down = button.exists && button.frame.minY < list.frame.minY + 20
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: down ? 0.3 : 0.8)).press(forDuration: 0.1,
                thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: down ? 0.8 : 0.3)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "Image deletion hierarchy"; tree.lifetime = .keepAlways; add(tree)
        screenshot("Image deletion control unavailable"); XCTFail("控件不可操作：\(id)"); return button
    }
    private func screenshot(_ name: String) {
        let value = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value)
    }
}

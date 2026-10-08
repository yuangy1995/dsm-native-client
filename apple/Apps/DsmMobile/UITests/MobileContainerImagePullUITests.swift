import XCTest

@MainActor final class MobileContainerImagePullUITests: XCTestCase {
    func test搜索选择标签下载完成并移除记录() {
        let app = launch(); defer { app.terminate() }
        search(app); openImage(app); chooseStable(app)
        XCTAssertTrue(app.staticTexts["Downloading uses NAS storage and may update an existing tag. Leaving this page does not stop the download."].exists)
        screenshot("Selected image and tag before download")
        download(app); phase("ready", app)
        XCTAssertTrue(app.staticTexts["sample/web:stable"].exists)
        screenshot("Image download finished with the original task")
        app.buttons["Remove this record"].tap(); XCTAssertTrue(app.staticTexts["No downloads yet"].waitForExistence(timeout: 8))
    }
    func test带回执下载跨重启后读取完成() {
        let app = launch("containers-images-offline"); search(app); openImage(app); chooseStable(app); download(app)
        phase("needsReview", app); XCTAssertFalse(app.buttons["Remove this record"].exists)
        screenshot("Download with receipt remains protected while offline"); app.terminate()
        let next = launch("containers-images-recovered", preserve: true); defer { next.terminate() }
        let downloads = next.segmentedControls["image-pull.section"].buttons["Downloads"]
        waitEnabled(downloads); downloads.press(forDuration: 0.15)
        XCTAssertTrue(next.collectionViews["image-pull.downloads"].waitForExistence(timeout: 8), next.debugDescription)
        phase("ready", next)
        XCTAssertTrue(next.staticTexts["sample/web:stable"].exists)
        screenshot("Original image download recovered after relaunch")
    }
    func test无回执下载重启后保持保护且不能重发() {
        let app = launch("containers-images-unknown"); search(app); openImage(app); chooseStable(app); download(app)
        phase("awaitingReceipt", app); app.terminate()
        let next = launch("containers-images-recovered", preserve: true); defer { next.terminate() }
        next.buttons["Downloads"].tap(); phase("awaitingReceipt", next)
        XCTAssertFalse(next.buttons["Remove this record"].exists)
        screenshot("No receipt never adopts an old matching image")
        next.buttons["Search images"].tap(); search(next); openImage(next); chooseStable(next)
        XCTAssertFalse(reveal("image-pull.download", next).isEnabled)
    }
    func test明确拒绝与实际下载失败均保留失败原因() {
        for mode in ["containers-images-rejected", "containers-images-failed"] {
            let app = launch(mode); search(app); openImage(app); chooseStable(app); download(app); phase("rejected", app)
            let message = mode.hasSuffix("rejected") ? "Your account cannot start this download. Check your Container Manager permissions."
                : "The NAS could not download this image. Check its network connection and available storage, or open Container Manager for details."
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", message)).firstMatch.exists)
            screenshot("Image download failure with recovery guidance"); app.terminate()
        }
    }
    func test搜索加载空结果错误和重试() {
        let loading = launch("containers-images-loading"); search(loading, waitForResult: false)
        XCTAssertTrue(element("image-pull.loading", loading).waitForExistence(timeout: 8)); screenshot("Image search loading"); loading.terminate()
        let empty = launch("containers-images-empty"); search(empty, waitForResult: false)
        XCTAssertTrue(empty.staticTexts["No matching images"].waitForExistence(timeout: 8)); screenshot("Image search has no results"); empty.terminate()
        let retry = launch("containers-images-search-error"); search(retry, waitForResult: false)
        XCTAssertTrue(retry.buttons["Search again"].waitForExistence(timeout: 8)); screenshot("Image search error with retry")
        retry.buttons["Search again"].tap(); XCTAssertTrue(element("image-pull.result.docker.io/sample/web", retry).waitForExistence(timeout: 8))
        retry.terminate()
    }
    func test标签失败重试空标签与筛选为空() {
        let retry = launch("containers-images-tags-error"); search(retry); openImage(retry, waitForTarget: false)
        XCTAssertTrue(retry.buttons["Reload tags"].waitForExistence(timeout: 8)); retry.buttons["Reload tags"].tap()
        XCTAssertTrue(element("image-pull.tag-picker", retry).waitForExistence(timeout: 8)); element("image-pull.tag-picker", retry).tap()
        let field = retry.searchFields.firstMatch; XCTAssertTrue(field.waitForExistence(timeout: 8)); field.tap(); field.typeText("no-match")
        XCTAssertFalse(retry.buttons["stable"].exists); screenshot("Tag filter has no matches"); retry.terminate()
        let empty = launch("containers-images-no-tags"); defer { empty.terminate() }; search(empty); openImage(empty, waitForTarget: false)
        XCTAssertTrue(element("image-pull.tags-empty", empty).waitForExistence(timeout: 8)); XCTAssertFalse(empty.buttons["image-pull.download"].exists)
        screenshot("Image without available tags")
    }
    func test中文大字下载按钮与风险说明可用() {
        let app = launch(chinese: true, large: true); defer { app.terminate() }; search(app); openImage(app)
        let button = reveal("image-pull.download", app); waitEnabled(button)
        XCTAssertTrue(app.staticTexts["下载会占用 NAS 存储空间，也可能更新现有标签。离开页面不会停止下载。"].exists)
        screenshot("Chinese large text image download form")
        button.tap(); phase("ready", app)
        XCTAssertTrue(app.staticTexts["sample/web:latest"].exists)
    }
    func test横竖屏目标选择与返回可用() {
        let app = launch(); defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }; search(app); openImage(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitEnabled(reveal("image-pull.download", app)); screenshot("Landscape image download form")
        XCUIDevice.shared.orientation = .portrait
        chooseStable(app); waitEnabled(reveal("image-pull.download", app))
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(element("image-pull.result.docker.io/sample/web", app).waitForExistence(timeout: 8))
        app.buttons["Downloads"].tap(); XCTAssertTrue(app.staticTexts["No downloads yet"].waitForExistence(timeout: 8))
    }
    private func launch(_ mode: String = "containers-images", preserve: Bool = false, chinese: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if preserve { app.launchArguments.append("--ui-preserve-transfer-fixture") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = mode; app.launch()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        MobileUITestNavigation.open(app, destination: "settings", title: chinese ? "App 设置" : "App settings", test: self)
        MobileUITestNavigation.enableModule(app, module: "containers", test: self)
        MobileUITestNavigation.open(app, destination: "containers", title: chinese ? "容器管理" : "Containers", test: self)
        let open = app.buttons["image-pull.open"]; waitEnabled(open); open.tap()
        XCTAssertTrue(app.segmentedControls["image-pull.section"].waitForExistence(timeout: 8))
        return app
    }
    private func search(_ app: XCUIApplication, waitForResult: Bool = true) {
        let field = app.searchFields.firstMatch; XCTAssertTrue(field.waitForExistence(timeout: 8)); field.tap(); field.typeText("sample\n")
        if waitForResult { XCTAssertTrue(element("image-pull.result.docker.io/sample/web", app).waitForExistence(timeout: 8)) }
    }
    private func openImage(_ app: XCUIApplication, waitForTarget: Bool = true) {
        element("image-pull.result.docker.io/sample/web", app).tap()
        if waitForTarget { XCTAssertTrue(app.collectionViews["image-pull.target"].waitForExistence(timeout: 8)) }
    }
    private func chooseStable(_ app: XCUIApplication) {
        reveal("image-pull.tag-picker", app).tap(); let stable = app.buttons["stable"]; waitEnabled(stable); stable.tap()
        XCTAssertTrue(app.collectionViews["image-pull.target"].waitForExistence(timeout: 8))
        XCTAssertEqual(element("image-pull.tag-picker", app).value as? String, "stable")
    }
    private func download(_ app: XCUIApplication) { let button = reveal("image-pull.download", app); waitEnabled(button); button.tap() }
    private func phase(_ name: String, _ app: XCUIApplication) { XCTAssertTrue(element("image-pull.record.\(name)", app).waitForExistence(timeout: 15)) }
    private func waitEnabled(_ value: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: value)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 12), .completed)
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func reveal(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let list = app.collectionViews["image-pull.target"], value = element(id, app)
        for _ in 0..<12 {
            if value.exists, !value.frame.isEmpty, value.frame.midY > max(100, list.frame.minY + 20),
               value.frame.midY < min(list.frame.maxY - 10, app.frame.maxY - 35), value.isHittable || !value.isEnabled { return value }
            let down = value.exists && value.frame.minY < list.frame.minY + 20
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: down ? 0.3 : 0.8)).press(forDuration: 0.1,
                thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: down ? 0.8 : 0.3)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "Image pull hierarchy"; tree.lifetime = .keepAlways; add(tree)
        screenshot("Image pull control unavailable"); XCTFail("控件不可操作：\(id)"); return value
    }
    private func screenshot(_ name: String) {
        let value = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value)
    }
}

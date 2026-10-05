import XCTest

@MainActor
final class MobileWorkspaceUITests: XCTestCase {

    func test照片批量原件交给系统文件面板并能取消() {
        let app = launchFixture(state: "photo-export"); defer { app.terminate() }
        openPhotos(app)
        let first = app.buttons["Sample 1.jpg"], second = app.buttons["Sample 2.jpg"]
        XCTAssertTrue(first.waitForExistence(timeout: 8)); XCTAssertTrue(second.waitForExistence(timeout: 8))
        XCTAssertEqual(first.frame.width, first.frame.height, accuracy: 1)
        XCTAssertFalse(first.frame.intersects(second.frame))
        attachScreenshot(app, name: "Wide photo thumbnails stay inside square cells")
        selectPhotoItems(app)
        element("mobile.photos.selection.actions", in: app).tap()
        element("mobile.photos.export.save", in: app).tap(); element("mobile.photos.export.original", in: app).tap()
        XCTAssertTrue(element("mobile.documents.export-panel", in: app).waitForExistence(timeout: 10))
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "保存"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        attachScreenshot(app, name: "Multiple photo originals in system file export")
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        var cancelled = false
        // 系统面板会恢复上次目录；先等待保存入口，再按实际目录层次回到取消按钮。
        for _ in 0..<4 {
            if cancel.waitForExistence(timeout: 1), cancel.isHittable { cancel.tap(); cancelled = true; break }
            let back = app.buttons["BackButton"]; XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: element("mobile.documents.export-panel", in: app))], timeout: 5), .completed)
        XCTAssertTrue(element("mobile.photos.selection.actions", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Sample 1.jpg"].exists)
    }

    func test整个照片文件夹可直接下载归档到系统面板() {
        let app = launchFixture(state: "photo-export"); defer { app.terminate() }
        openPhotos(app); openPhotoSection("Folders", app: app)
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.export.archive", in: app).tap()
        element("mobile.photos.export.archiveOriginal", in: app).tap()
        XCTAssertTrue(element("mobile.documents.export-panel", in: app).waitForExistence(timeout: 10))
        attachScreenshot(app, name: "Entire photo folder archive in system file export")
    }

    func test照片分享交给系统并在部分失败后保留准确说明() {
        let app = launchFixture(state: "photo-export-partial"); defer { app.terminate() }
        openPhotos(app); selectPhotoItems(app)
        element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.export.share", in: app).tap()
        let panel = element("ActivityListView", in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 10)); attachScreenshot(app, name: "Completed photo subset in system sharing")
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭"])).firstMatch
        if close.exists { close.tap() } else { panel.swipeDown() }
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Prepared 1 of 3 items")).firstMatch.exists)
        attachScreenshot(app, name: "Accurate partial photo export result")
    }

    func test照片导出加载可取消失败可恢复而不出现系统面板() {
        for state in ["photo-export-loading", "photo-export-error"] {
            let app = launchFixture(state: state); openPhotos(app); selectPhotoItems(app)
            element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.export.share", in: app).tap()
            if state == "photo-export-loading" {
                XCTAssertTrue(element("mobile.photos.export.cancel", in: app).waitForExistence(timeout: 5))
                attachScreenshot(app, name: state); element("mobile.photos.export.cancel", in: app).tap()
                XCTAssertFalse(element("mobile.photos.export.cancel", in: app).exists)
            } else {
                XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); attachScreenshot(app, name: state)
            }
            XCTAssertFalse(element("ActivityListView", in: app).exists); app.terminate()
        }
    }

    func test幻灯片暂停手动前后切换及退出回到原生预览() {
        let app = launchFixture(state: "photo-export"); defer { app.terminate() }
        openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.slideshow.start", in: app).tap()
        let playback = element("mobile.photos.slideshow.playback", in: app)
        XCTAssertTrue(playback.waitForExistence(timeout: 5)); playback.tap(); XCTAssertEqual(playback.label, "Resume slideshow")
        XCTAssertTrue(element("mobile.photos.slideshow.image", in: app).waitForExistence(timeout: 5))
        let before = element("mobile.photos.slideshow.filename", in: app).label
        element("mobile.photos.slideshow.next", in: app).tap()
        XCTAssertTrue(NSPredicate(format: "label != %@", before).evaluate(with: element("mobile.photos.slideshow.filename", in: app)))
        element("mobile.photos.slideshow.previous", in: app).tap()
        XCTAssertEqual(element("mobile.photos.slideshow.filename", in: app).label, before)
        attachScreenshot(app, name: "Photo slideshow with touch playback controls")
        element("mobile.photos.slideshow.stop", in: app).tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5)); app.buttons["Close"].tap()
        XCTAssertTrue(element("mobile.photos.actions", in: app).waitForExistence(timeout: 5))
    }

    func test中文大字号缩略图调节及按日选择不隐藏导出入口() {
        let app = launchFixture(state: "photo-export", language: "zh-Hans"); app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]; app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); navigate("settings", title: "App 设置", in: app)
        let toggle = element("mobile.settings.module.photos", in: app)
        for _ in 0..<8 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
        toggle.switches.firstMatch.tap(); navigate("photos", title: "照片", in: app)
        XCTAssertTrue(element("mobile.photos.actions", in: app).waitForExistence(timeout: 8))
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.thumbnail.size", in: app).tap()
        element("mobile.photos.thumbnail.larger", in: app).tap()
        element("mobile.photos.selection.begin", in: app).tap(); element("mobile.photos.selection.day", in: app).tap()
        XCTAssertTrue(app.staticTexts["已选择 3 项"].waitForExistence(timeout: 5))
        element("mobile.photos.selection.actions", in: app).tap()
        XCTAssertTrue(element("mobile.photos.export.save", in: app).exists); XCTAssertTrue(element("mobile.photos.export.share", in: app).isEnabled)
        attachScreenshot(app, name: "Chinese accessibility photo selection and export")
    }

    func test相似预览更换代表照片移出与撤销均保留原件() {
        let app = launchFixture(state: "photo-similar"); defer { app.terminate() }
        openSimilarPhotos(app); app.buttons["Sample 1.jpg"].tap()
        element("mobile.photos.similar.open", in: app).tap()
        let second = element("mobile.photos.similar.photo.2", in: app)
        for _ in 0..<5 { if second.exists && second.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(second.isHittable); second.tap()
        element("mobile.photos.similar.open", in: app).tap()
        element("mobile.photos.similar.topPick", in: app).tap(); app.alerts.firstMatch.buttons["mobile.photos.similar.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Groups updated: 1. Not changed: 0."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["mobile.photos.similar.topPick"].isEnabled)
        attachScreenshot(app, name: "Similar group with a new top pick")
        element("mobile.photos.similar.remove", in: app).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Remove the 1 selected photos from this group? The originals will be kept, and you can undo this change.")).firstMatch.waitForExistence(timeout: 5))
        app.alerts.firstMatch.buttons["mobile.photos.similar.confirm"].firstMatch.tap()
        let panel = element("mobile.photos.similar.panel", in: app)
        let undo = panel.buttons["mobile.photos.similar.undo"].firstMatch
        for _ in 0..<5 { if undo.exists && undo.isHittable { break }; panel.swipeUp() }
        XCTAssertTrue(undo.isEnabled); XCTAssertTrue(undo.isHittable); undo.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.firstMatch.buttons["Confirm changes"].firstMatch.tap()
        XCTAssertTrue(element("mobile.photos.similar.photo.1", in: app).waitForExistence(timeout: 8))
        XCTAssertFalse(panel.buttons["mobile.photos.similar.undo"].firstMatch.exists)
    }

    func test相似批量拆组中断重启后不重发并能取消剩余项() {
        let app = launchFixture(state: "photo-similar-unknown"); openSimilarPhotos(app); selectPhotoItems(app)
        element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.similar.batch", in: app).tap()
        XCTAssertTrue(app.staticTexts["Ungroup the 3 selected groups? All original photos will be kept, and completed group changes can be undone."].waitForExistence(timeout: 5))
        app.alerts.firstMatch.buttons["mobile.photos.similar.batchConfirm"].firstMatch.tap()
        XCTAssertTrue(element("mobile.photos.similar.continue", in: app).waitForExistence(timeout: 8)); XCTAssertFalse(element("mobile.photos.similar.continue", in: app).isEnabled)
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch(); defer { app.terminate() }
        openPhotos(app)
        XCTAssertTrue(app.staticTexts["Groups updated: 0. Remaining: 2."].waitForExistence(timeout: 8))
        XCTAssertFalse(element("mobile.photos.similar.continue", in: app).isEnabled)
        attachScreenshot(app, name: "Unfinished group changes restored without replay")
        element("mobile.photos.similar.cancelRemaining", in: app).tap()
        XCTAssertFalse(element("mobile.photos.similar.continue", in: app).exists)
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).exists)
    }

    func test相似清理确认可取消并只删除未保留原件() {
        let app = launchFixture(state: "photo-similar"); defer { app.terminate() }
        openSimilarPhotos(app); app.buttons["Sample 1.jpg"].tap(); element("mobile.photos.similar.open", in: app).tap()
        element("mobile.photos.similar.cleanup", in: app).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Keep the 1 selected photos and delete the other 2 photos in this group from the NAS? Deleted originals will also be removed from their albums. Recovery depends on your NAS settings.")).firstMatch.waitForExistence(timeout: 8))
        app.alerts.firstMatch.buttons["Cancel"].tap()
        XCTAssertTrue(element("mobile.photos.similar.photo.2", in: app).exists)
        XCTAssertEqual(element("mobile.photos.similar.select.1", in: app).value as? String, "Selected")
        element("mobile.photos.similar.cleanup", in: app).tap()
        XCTAssertTrue(app.alerts.firstMatch.buttons["mobile.photos.deletion.confirm"].firstMatch.waitForExistence(timeout: 8)); app.alerts.firstMatch.buttons["mobile.photos.deletion.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Deleted: 2."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Sample 1.jpg"].exists); XCTAssertTrue(app.buttons["Sample 4.jpg"].exists)
        openPhotoSection("Timeline", app: app)
        XCTAssertTrue(app.buttons["Sample 1.jpg"].waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["Sample 2.jpg"].exists); XCTAssertFalse(app.buttons["Sample 3.jpg"].exists)
        attachScreenshot(app, name: "Only unselected originals removed")
    }

    func test相似分类空内容加载失败与无写权限保留正确入口() {
        for state in ["photo-similar-empty", "photo-similar-loading", "photo-similar-error", "photo-similar-readonly"] {
            let app = launchFixture(state: state); openSimilarPhotos(app, expectPhotos: false)
            if state.hasSuffix("empty") { XCTAssertTrue(app.staticTexts["No similar photos found. You can refresh to check again."].waitForExistence(timeout: 8)) }
            else if state.hasSuffix("loading") { XCTAssertTrue(element("mobile.photos.loading", in: app).waitForExistence(timeout: 5)) }
            else if state.hasSuffix("error") { XCTAssertTrue(app.buttons["Try again"].firstMatch.waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["Sample 1.jpg"].exists) }
            else {
                XCTAssertTrue(app.buttons["Sample 1.jpg"].waitForExistence(timeout: 8)); app.buttons["Sample 1.jpg"].tap(); element("mobile.photos.similar.open", in: app).tap()
                XCTAssertTrue(element("mobile.photos.similar.ungroup", in: app).waitForExistence(timeout: 8)); XCTAssertFalse(element("mobile.photos.similar.ungroup", in: app).isEnabled)
                XCTAssertFalse(element("mobile.photos.similar.cleanup", in: app).isEnabled)
            }
            attachScreenshot(app, name: state); app.terminate()
        }
    }

    func test相似照片中文最大字号选择与确认可触达() {
        let app = launchFixture(state: "photo-similar", language: "zh-Hans"); app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]; app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); navigate("settings", title: "App 设置", in: app)
        let toggle = element("mobile.settings.module.photos", in: app)
        for _ in 0..<8 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
        toggle.switches.firstMatch.tap(); navigate("photos", title: "照片", in: app)
        XCTAssertTrue(element("mobile.photos.actions", in: app).waitForExistence(timeout: 8)); openPhotoSection("相册", app: app)
        let category = app.buttons["相似照片"].firstMatch
        for _ in 0..<8 { if category.exists && category.isHittable { break }; app.swipeUp() }
        category.tap()
        let photo = app.buttons["Sample 1.jpg"]
        for _ in 0..<8 { if photo.exists && photo.isHittable { break }; app.swipeUp() }
        photo.tap(); element("mobile.photos.similar.open", in: app).tap()
        let checkbox = element("mobile.photos.similar.select.2", in: app)
        for _ in 0..<10 { if checkbox.exists && checkbox.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(checkbox.isHittable); checkbox.tap(); XCTAssertEqual(checkbox.value as? String, "已选择")
        attachScreenshot(app, name: "相似照片中文大字选择")
        let ungroup = element("mobile.photos.similar.ungroup", in: app)
        let panel = element("mobile.photos.similar.panel", in: app)
        for _ in 0..<10 {
            if ungroup.exists && ungroup.isHittable && ungroup.frame.minY > app.navigationBars["相似照片"].frame.maxY + 4 { break }
            panel.swipeDown()
        }
        XCTAssertTrue(ungroup.isHittable); ungroup.tap()
        let confirm = app.alerts.firstMatch.buttons["mobile.photos.similar.confirm"].firstMatch
        let available = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 5), .completed)
        XCTAssertTrue(confirm.isHittable)
        attachScreenshot(app, name: "相似照片中文大字拆组确认"); app.alerts.firstMatch.buttons["取消"].tap()
    }

    private func openSimilarPhotos(_ app: XCUIApplication, expectPhotos: Bool = true) {
        openPhotos(app); openPhotoSection("Albums", app: app)
        let category = app.buttons["Similar Photos"].firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 8)); category.tap()
        if expectPhotos { XCTAssertTrue(app.buttons["Sample 1.jpg"].waitForExistence(timeout: 8)) }
    }

    func test照片完整批量删除确认可取消且删除全部选择() {
        let app = launchFixture(state: "photo-deletion"); defer { app.terminate() }
        openPhotos(app); selectPhotoItems(app); beginPhotoDeletion(in: app)
        XCTAssertTrue(app.staticTexts["Delete these 3 photos from your NAS? This also removes them from albums. Recovery depends on your NAS settings."].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Delete all three originals confirmation")
        app.alerts.firstMatch.buttons["Cancel"].tap(); XCTAssertTrue(app.buttons["Sample 1.jpg"].exists); XCTAssertTrue(app.buttons["Sample 3.jpg"].exists)
        beginPhotoDeletion(in: app); app.alerts.firstMatch.buttons["mobile.photos.deletion.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Deleted: 3."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Sample 1.jpg"].exists); XCTAssertFalse(app.buttons["Sample 2.jpg"].exists); XCTAssertFalse(app.buttons["Sample 3.jpg"].exists)
        XCTAssertFalse(element("mobile.photos.selection.actions", in: app).exists)
        attachScreenshot(app, name: "All selected originals deleted")
    }
    func test照片删除未知重启后只能刷新或取消剩余项目() {
        let app = launchFixture(state: "photo-deletion-unknown"); defer { app.terminate() }
        openPhotos(app); selectPhotoItems(app); beginPhotoDeletion(in: app)
        app.alerts.firstMatch.buttons["mobile.photos.deletion.confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["mobile.photos.deletion.refresh"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["mobile.photos.deletion.continue"].isEnabled)
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch(); openPhotos(app)
        XCTAssertTrue(app.buttons["mobile.photos.deletion.refresh"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["mobile.photos.deletion.continue"].isEnabled)
        app.buttons["mobile.photos.deletion.cancelRemaining"].tap()
        XCTAssertFalse(app.buttons["mobile.photos.deletion.continue"].exists); XCTAssertTrue(app.buttons["mobile.photos.deletion.refresh"].exists)
        attachScreenshot(app, name: "Interrupted deletion keeps submitted item after cancel remaining")
    }
    func test照片部分删除中文只继续未提交项且不误报全部成功() {
        let app = launchFixture(state: "photo-deletion-partial", language: "zh-Hans"); defer { app.terminate() }
        openPhotos(app, chinese: true); selectPhotoItems(app); beginPhotoDeletion(in: app)
        app.alerts.firstMatch.buttons["mobile.photos.deletion.confirm"].firstMatch.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 8)); app.alerts.firstMatch.buttons["关闭"].tap()
        let resume = app.buttons["mobile.photos.deletion.continue"]; XCTAssertTrue(resume.waitForExistence(timeout: 8))
        XCTAssertEqual(resume.label, "继续删除 1 张照片"); resume.tap()
        XCTAssertTrue(app.staticTexts["要从 NAS 删除“Sample 3.jpg”吗？它也将从所属相册中移除。能否恢复取决于 NAS 的设置。"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "仅继续尚未提交的一张照片")
        app.alerts.firstMatch.buttons["mobile.photos.deletion.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已删除 2 张照片，1 张未删除。"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Sample 2.jpg"].exists); XCTAssertFalse(app.buttons["Sample 1.jpg"].exists); XCTAssertFalse(app.buttons["Sample 3.jpg"].exists)
    }
    func test照片删除预检加载和连接错误不弹出删除确认() {
        for state in ["photo-deletion-loading", "photo-deletion-error", "photo-deletion-denied"] {
            let app = launchFixture(state: state); openPhotos(app); selectPhotoItems(app)
            element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.selection.delete", in: app).tap()
            if state.hasSuffix("loading") { XCTAssertTrue(element("mobile.photos.deletion.loading", in: app).waitForExistence(timeout: 5)); XCTAssertFalse(app.alerts.firstMatch.exists) }
            else { XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 8)); XCTAssertFalse(app.alerts.firstMatch.buttons["mobile.photos.deletion.confirm"].exists) }
            attachScreenshot(app, name: state); app.terminate()
        }
    }
    func test预览删除单张后仍保留其余照片() {
        let app = launchFixture(state: "photo-deletion"); defer { app.terminate() }
        openPhotos(app); app.buttons["Sample 1.jpg"].tap()
        let share = app.buttons["mobile.photos.preview.actions"]; XCTAssertTrue(share.waitForExistence(timeout: 5)); share.tap()
        let action = element("mobile.photos.preview.delete", in: app); XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.firstMatch.buttons["mobile.photos.deletion.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Deleted: 1."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Sample 1.jpg"].exists); XCTAssertTrue(app.buttons["Sample 2.jpg"].exists); XCTAssertTrue(app.buttons["Sample 3.jpg"].exists)
    }
    func test照片删除中文大字确认和剩余操作仍可触达() {
        let app = launchFixture(state: "photo-deletion-unknown", language: "zh-Hans"); app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]; app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); navigate("settings", title: "App 设置", in: app)
        let toggle = element("mobile.settings.module.photos", in: app)
        for _ in 0..<8 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(toggle.exists); toggle.switches.firstMatch.tap(); navigate("photos", title: "照片", in: app)
        XCTAssertTrue(element("mobile.photos.actions", in: app).waitForExistence(timeout: 8))
        let photo = app.buttons["Sample 1.jpg"]
        for _ in 0..<8 { if photo.exists && photo.isHittable { break }; app.swipeUp() }
        selectPhotoItems(app); beginPhotoDeletion(in: app)
        let confirm = app.alerts.firstMatch.buttons["mobile.photos.deletion.confirm"].firstMatch
        XCTAssertTrue(confirm.isHittable); attachScreenshot(app, name: "照片删除中文大字完整确认"); confirm.tap()
        let controls = app.scrollViews["mobile.photos.deletion.controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 8)); attachScreenshot(app, name: "照片删除中文大字完整进度")
        let cancel = app.buttons["mobile.photos.deletion.cancelRemaining"]
        for _ in 0..<6 { if cancel.exists && cancel.isHittable { break }; scrollPhotoDeletionControls(controls, in: app) }
        XCTAssertTrue(cancel.exists); XCTAssertTrue(cancel.isHittable, "操作区 \(controls.frame)，按钮 \(cancel.frame)")
        XCTAssertFalse(app.buttons["mobile.photos.deletion.continue"].isEnabled); attachScreenshot(app, name: "照片删除中文大字恢复操作"); cancel.tap()
        let refresh = app.buttons["mobile.photos.deletion.refresh"]
        for _ in 0..<6 { if refresh.exists && refresh.isHittable { break }; scrollPhotoDeletionControls(controls, in: app) }
        XCTAssertTrue(refresh.isHittable)
    }
    private func scrollPhotoDeletionControls(_ controls: XCUIElement, in app: XCUIApplication) {
        let frame = controls.frame.intersection(app.frame)
        let bottom = min(frame.maxY, app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY)
        let height = bottom - frame.minY
        XCTAssertGreaterThan(height, 40)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + height * 0.75)).press(forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + height * 0.25)))
    }
    private func beginPhotoDeletion(in app: XCUIApplication) {
        element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.selection.delete", in: app).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 8))
    }

    func test人物显示隐藏与主题搜索() {
        let app = launchFixture(state: "photo-recognition"); defer { app.terminate() }
        openPhotos(app); openPhotoRecognition("peopleVisibility", in: app)
        XCTAssertTrue(app.switches["mobile.photos.recognition.selection.77"].waitForExistence(timeout: 5))
        let hide = app.segmentedControls.buttons["Hide people"]; XCTAssertTrue(hide.waitForExistence(timeout: 5)); hide.tap()
        app.switches["mobile.photos.recognition.selection.77"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        attachScreenshot(app, name: "People visibility selection"); app.buttons["mobile.photos.recognition.save"].tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        openPhotoRecognition("conceptVisibility", in: app)
        let search = app.searchFields["Search topics"]; XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Hidden")
        XCTAssertTrue(app.switches["mobile.photos.recognition.selection.32"].waitForExistence(timeout: 5)); XCTAssertFalse(app.switches["mobile.photos.recognition.selection.31"].exists)
        attachScreenshot(app, name: "Hidden topics searchable")
    }

    func test人物中文改名合并取消及确认() {
        let app = launchFixture(state: "photo-recognition", language: "zh-Hans"); defer { app.terminate() }
        openPhotos(app, chinese: true); openPhotoSection("相册", app: app); app.buttons["人物"].tap()
        let actions = app.buttons["mobile.photos.person.actions.77"]; XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap()
        element("mobile.photos.recognition.rename", in: app).tap()
        let name = app.textFields["mobile.photos.recognition.name"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Sample person".count) + "Family")
        app.buttons["mobile.photos.recognition.save"].tap(); XCTAssertTrue(app.staticTexts["Family"].waitForExistence(timeout: 8))
        actions.tap(); element("mobile.photos.recognition.merge", in: app).tap()
        let selected = app.switches["mobile.photos.recognition.selection.78"]; XCTAssertTrue(selected.waitForExistence(timeout: 5))
        selected.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); app.buttons["mobile.photos.recognition.save"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); attachScreenshot(app, name: "人物合并保留原照片确认")
        app.alerts.firstMatch.buttons["取消"].tap(); app.buttons["mobile.photos.recognition.save"].tap()
        app.alerts.firstMatch.buttons["mobile.photos.recognition.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["操作已完成。"].waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["mobile.photos.collection.78"].exists)
    }

    func test主题移出提示分类数量并保留原照片() {
        let app = launchFixture(state: "photo-recognition"); defer { app.terminate() }
        openPhotos(app); openPhotoSection("Albums", app: app); app.buttons["Subjects"].tap()
        let topic = app.buttons["mobile.photos.collection.31"]; XCTAssertTrue(topic.waitForExistence(timeout: 5)); topic.tap()
        selectPhotoItems(app); element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.recognition.removeConceptItems", in: app).tap()
        XCTAssertTrue(app.buttons["mobile.photos.recognition.save"].waitForExistence(timeout: 5)); attachScreenshot(app, name: "Topic removal keeps photos")
        app.buttons["mobile.photos.recognition.save"].tap(); XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.firstMatch.buttons["mobile.photos.recognition.confirm"].firstMatch.tap(); XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        openPhotoSection("Timeline", app: app); XCTAssertTrue(app.buttons["Sample 1.jpg"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["Sample 2.jpg"].exists)
    }

    func test人脸触控框选移动与辅助控件保存() {
        let app = launchFixture(state: "photo-recognition"); defer { app.terminate() }
        openPhotos(app); openPhotoFaceEditor(in: app)
        let add = app.buttons["mobile.photos.faces.centered"]; XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
        let name = app.textFields["mobile.photos.faces.name"]; revealPhotoFaceField(name, in: app); name.tap(); name.typeText("New face\n")
        let horizontal = app.sliders["mobile.photos.faces.horizontal"]; revealPhotoFaceField(horizontal, in: app); horizontal.adjust(toNormalizedSliderPosition: 0.25)
        attachScreenshot(app, name: "Face box with accessible position controls")
        let remove = app.buttons["mobile.photos.faces.remove"]; revealPhotoFaceField(remove, in: app); remove.tap()
        XCTAssertFalse(app.buttons["mobile.photos.faces.save"].isEnabled)
        app.buttons["mobile.photos.faces.draw"].tap()
        let canvas = element("mobile.photos.faces.canvas", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)))
        revealPhotoFaceField(name, in: app); name.tap(); name.typeText("Drawn face")
        XCTAssertTrue(app.buttons["mobile.photos.faces.save"].isEnabled); attachScreenshot(app, name: "Drawn face ready to save")
        app.buttons["mobile.photos.faces.save"].tap(); XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        element("mobile.photos.edit.preview", in: app).tap(); element("mobile.photos.faces.begin", in: app).tap()
        let saved = app.buttons.containing(.staticText, identifier: "Drawn face").firstMatch
        revealPhotoFaceField(saved, in: app); XCTAssertTrue(saved.exists)
        attachScreenshot(app, name: "Saved face reopened")
    }

    func test人物加载空内容错误正常与筛选无结果() {
        for state in ["photo-recognition-loading", "photo-recognition-empty", "photo-recognition-error", "photo-recognition"] {
            let app = launchFixture(state: state); openPhotos(app); openPhotoRecognition("peopleVisibility", in: app)
            if state.hasSuffix("loading") { XCTAssertTrue(element("mobile.photos.recognition.loading", in: app).waitForExistence(timeout: 5)) }
            else if state.hasSuffix("empty") { XCTAssertTrue(app.staticTexts["No matching people"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["mobile.photos.recognition.save"].isEnabled) }
            else if state.hasSuffix("error") {
                XCTAssertTrue(app.staticTexts["Could not load people or topics. Check your connection and try again."].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["Try again"].exists)
            } else {
                XCTAssertTrue(app.switches["mobile.photos.recognition.selection.77"].waitForExistence(timeout: 5)); attachScreenshot(app, name: "People normal state")
                let search = app.searchFields["Search people"]; search.tap(); search.typeText("missing-person")
                XCTAssertTrue(app.staticTexts["No matching people"].waitForExistence(timeout: 5))
            }
            attachScreenshot(app, name: state + "-people"); app.terminate()
        }
    }

    func test人物保存中断重启不可重复提交() {
        let app = launchFixture(state: "photo-recognition-unknown"); defer { app.terminate() }
        openPhotos(app); openPhotoRecognition("peopleVisibility", in: app)
        let hide = app.segmentedControls.buttons["Hide people"]; XCTAssertTrue(hide.waitForExistence(timeout: 5)); hide.tap()
        let item = app.switches["mobile.photos.recognition.selection.77"]; XCTAssertTrue(item.waitForExistence(timeout: 5)); item.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        app.buttons["mobile.photos.recognition.save"].tap(); XCTAssertTrue(app.buttons["mobile.photos.album.refresh"].waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch(); openPhotos(app)
        XCTAssertTrue(app.buttons["mobile.photos.album.refresh"].waitForExistence(timeout: 8)); element("mobile.photos.actions", in: app).tap()
        XCTAssertFalse(element("mobile.photos.recognition.peopleVisibility", in: app).exists); attachScreenshot(app, name: "People save recovery after relaunch")
    }

    func test人脸大字中文空内容仍可命名保存() {
        let app = launchFixture(state: "photo-recognition-empty", language: "zh-Hans"); app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); navigate("settings", title: "App 设置", in: app)
        let toggle = element("mobile.settings.module.photos", in: app)
        for _ in 0..<8 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(toggle.exists); toggle.switches.firstMatch.tap(); navigate("photos", title: "照片", in: app)
        XCTAssertTrue(element("mobile.photos.actions", in: app).waitForExistence(timeout: 8))
        let photo = app.buttons["Sample 1.jpg"]
        for _ in 0..<8 { if photo.exists && photo.isHittable { break }; app.swipeUp() }
        openPhotoFaceEditor(in: app)
        let add = app.buttons["mobile.photos.faces.centered"]; XCTAssertTrue(add.waitForExistence(timeout: 5)); XCTAssertTrue(add.isHittable); add.tap()
        let name = app.textFields["mobile.photos.faces.name"]; revealPhotoFaceField(name, in: app); name.tap(); name.typeText("Family")
        let save = app.buttons["mobile.photos.faces.save"]; XCTAssertTrue(save.isEnabled); XCTAssertTrue(save.isHittable)
        attachScreenshot(app, name: "人脸编辑中文无障碍大字"); save.tap()
        XCTAssertTrue(app.staticTexts["操作已完成。"].waitForExistence(timeout: 8))
    }

    private func revealPhotoFaceField(_ item: XCUIElement, in app: XCUIApplication) {
        let inspector = element("mobile.photos.faces.inspector", in: app)
        for _ in 0..<12 {
            let upper = inspector.frame.minY
            if item.exists && item.isHittable && item.frame.minY >= upper { return }
            let down = item.exists && item.frame.minY < upper
            inspector.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).press(forDuration: 0.05,
                thenDragTo: inspector.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: down ? 0.72 : 0.28)))
        }
        XCTAssertTrue(item.exists); XCTAssertTrue(item.isHittable)
    }

    private func openPhotoRecognition(_ action: String, in app: XCUIApplication) {
        element("mobile.photos.actions", in: app).tap(); let item = element("mobile.photos.recognition.\(action)", in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
    }
    private func openPhotoFaceEditor(in app: XCUIApplication) {
        let photo = app.buttons["Sample 1.jpg"]; XCTAssertTrue(photo.waitForExistence(timeout: 8)); photo.tap()
        let menu = element("mobile.photos.edit.preview", in: app); XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        let item = element("mobile.photos.faces.begin", in: app)
        // 辅助大字下系统菜单会滚动，从当前可见的日期项向上方动作移动。
        for _ in 0..<6 {
            if item.waitForExistence(timeout: 1) && item.isHittable { break }
            let date = element("mobile.photos.edit.date", in: app)
            if date.exists { date.swipeDown() } else { app.swipeDown() }
        }
        XCTAssertTrue(item.exists); XCTAssertTrue(item.isHittable); item.tap()
    }

    func test照片共享设置中文确认取消和保存() {
        let app = launchFixture(state: "photo-admin", language: "zh-Hans"); defer { app.terminate() }
        openPhotos(app, chinese: true); openPhotoAdministration("shared", in: app)
        let toggle = app.switches["photos.sharedSettings.allow_root_folder_public"]; XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); app.buttons["mobile.photos.administration.save"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); attachScreenshot(app, name: "共享顶层文件夹公开权限确认")
        app.alerts.firstMatch.buttons["取消"].tap(); app.buttons["mobile.photos.administration.save"].tap()
        app.alerts.firstMatch.buttons["mobile.photos.administration.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["操作已完成。"].waitForExistence(timeout: 8))
        openPhotoAdministration("shared", in: app); XCTAssertEqual(app.switches["photos.sharedSettings.allow_root_folder_public"].value as? String, "1")
        attachScreenshot(app, name: "共享照片管理员设置中文")
    }

    func test照片全局格式保留未知项及缓存清理() {
        let app = launchFixture(state: "photo-admin"); defer { app.terminate() }
        openPhotos(app); openPhotoAdministration("global", in: app)
        let formats = element("mobile.photos.administration.excluded", in: app); revealPhotoAdministration(formats, in: app); formats.tap()
        let legacy = app.switches["LEGACY"]; revealPhotoAdministration(legacy, in: app); XCTAssertEqual(legacy.value as? String, "1")
        legacy.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(legacy.value as? String, "0")
        attachScreenshot(app, name: "Preserved unknown excluded photo format")
        app.navigationBars["Excluded file formats"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["mobile.photos.administration.save"].isEnabled); app.buttons["mobile.photos.administration.save"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.firstMatch.buttons["mobile.photos.administration.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        openPhotoAdministration("global", in: app)
        let clear = app.buttons["mobile.photos.administration.clearCache"]; revealPhotoAdministration(clear, in: app); clear.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); attachScreenshot(app, name: "Conversion cache clear confirmation")
        app.alerts.firstMatch.buttons["Cancel"].tap(); clear.tap(); app.alerts.firstMatch.buttons["mobile.photos.administration.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        openPhotoAdministration("global", in: app); revealPhotoAdministration(clear, in: app); XCTAssertFalse(clear.isEnabled)
    }

    func test照片添加自定义成员并编辑目录后统一保存() {
        let app = launchFixture(state: "photo-admin"); defer { app.terminate() }
        openPhotos(app); openPhotoAdministration("members", in: app)
        XCTAssertTrue(app.staticTexts["System administrators group"].waitForExistence(timeout: 5))
        app.buttons["photos.members.add"].tap(); XCTAssertTrue(app.buttons["New member"].waitForExistence(timeout: 5)); app.buttons["New member"].tap()
        app.buttons["Custom Access"].tap()
        let folder = element("mobile.photos.administration.folder.9", in: app); XCTAssertTrue(folder.waitForExistence(timeout: 8)); folder.tap()
        app.buttons["Download"].tap(); attachScreenshot(app, name: "Member folder permission draft")
        app.buttons["mobile.photos.administration.folders.done"].tap()
        let save = app.buttons["mobile.photos.administration.save"]; XCTAssertTrue(save.waitForExistence(timeout: 5)); XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); attachScreenshot(app, name: "Shared member permission confirmation")
        app.alerts.firstMatch.buttons["mobile.photos.administration.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        openPhotoAdministration("members", in: app)
        let search = app.searchFields["Search members"]; XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("New member")
        XCTAssertTrue(app.staticTexts["New member"].waitForExistence(timeout: 5)); attachScreenshot(app, name: "Saved member filtered on mobile")
    }

    func test照片管理员空内容失败加载停用及搜索无结果() {
        for state in ["photo-admin-empty", "photo-admin-error", "photo-admin-loading", "photo-admin-disabled", "photo-admin"] {
            let app = launchFixture(state: state); openPhotos(app); openPhotoAdministration("members", in: app)
            if state.hasSuffix("empty") { XCTAssertTrue(app.staticTexts["No Shared Space Members"].waitForExistence(timeout: 5)) }
            else if state.hasSuffix("error") { XCTAssertTrue(app.staticTexts["Couldn’t load members. Check your connection and try again."].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["Try again"].exists) }
            else if state.hasSuffix("loading") { XCTAssertTrue(element("mobile.photos.administration.loading", in: app).waitForExistence(timeout: 5)) }
            else if state.hasSuffix("disabled") { XCTAssertTrue(app.staticTexts["Shared Space Is Off"].waitForExistence(timeout: 5)) }
            else {
                let search = app.searchFields["Search members"]; XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("missing-member")
                XCTAssertTrue(app.staticTexts["No Matches"].waitForExistence(timeout: 5))
            }
            attachScreenshot(app, name: state + "-administration"); app.terminate()
        }
    }

    func test照片共享最后图库与正在清理缓存保持限制() {
        for state in ["photo-admin-last", "photo-admin-busy"] {
            let app = launchFixture(state: state); openPhotos(app); openPhotoAdministration(state.hasSuffix("last") ? "shared" : "global", in: app)
            let control = app.buttons[state.hasSuffix("last") ? "mobile.photos.administration.sharedSwitch" : "mobile.photos.administration.clearCache"]
            revealPhotoAdministration(control, in: app); XCTAssertFalse(control.isEnabled)
            XCTAssertTrue(app.staticTexts[state.hasSuffix("last") ? "Enable My photos before turning off shared photos." : "Clearing cache…"].exists)
            attachScreenshot(app, name: state + "-restriction"); app.terminate()
        }
    }

    func test照片管理员未知保存重启仍禁止再次提交() {
        let app = launchFixture(state: "photo-admin-unknown"); defer { app.terminate() }
        openPhotos(app); openPhotoAdministration("global", in: app)
        let toggle = app.switches["photos.global.display_photo_info_to_guest"]; XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); app.buttons["mobile.photos.administration.save"].tap()
        app.alerts.firstMatch.buttons["mobile.photos.administration.confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["mobile.photos.album.refresh"].waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch(); openPhotos(app)
        XCTAssertTrue(app.buttons["mobile.photos.album.refresh"].waitForExistence(timeout: 8)); openPhotoAdministration("global", in: app)
        XCTAssertTrue(app.buttons["mobile.photos.administration.save"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["mobile.photos.administration.save"].isEnabled)
        XCTAssertFalse(app.switches["photos.global.display_photo_info_to_guest"].isEnabled); attachScreenshot(app, name: "Global settings recovery after relaunch")
    }

    func test照片全局部分完成重新打开保留剩余修改() {
        let app = launchFixture(state: "photo-admin-partial"); defer { app.terminate() }
        openPhotos(app); openPhotoAdministration("global", in: app)
        let toggle = app.switches["photos.global.enable_person"]; XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); app.buttons["mobile.photos.administration.save"].tap()
        app.alerts.firstMatch.buttons["mobile.photos.administration.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Some settings were saved. Reopen Global settings to review the current state and finish the remaining changes."].waitForExistence(timeout: 8))
        openPhotoAdministration("global", in: app); XCTAssertEqual(app.switches["photos.global.enable_person"].value as? String, "0")
        XCTAssertTrue(app.buttons["mobile.photos.administration.save"].isEnabled); attachScreenshot(app, name: "Partial global settings remain editable")
    }

    private func openPhotoAdministration(_ page: String, in app: XCUIApplication) {
        element("mobile.photos.actions", in: app).tap()
        let item = element("mobile.photos.administration.\(page)", in: app); XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
    }
    private func revealPhotoAdministration(_ item: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if item.exists && item.isHittable {
                // 浮动导航栏下的行仍可能报告可点击，先把整行移到标题下方。
                if let bar = app.navigationBars.allElementsBoundByIndex.last(where: { $0.isHittable }), item.frame.minY < bar.frame.maxY {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05,
                        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)))
                    continue
                }
                return
            }
            app.swipeUp()
        }
        XCTAssertTrue(item.exists && item.isHittable)
    }

    func test自动预览处理中暂停再继续保持可操作() {
        let app = launchFixture(state: "photo-preview-automatic-slow"); defer { app.terminate() }
        openPhotos(app)
        let pause = app.buttons["mobile.photos.automatic.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 12)); pause.tap()
        XCTAssertTrue(app.staticTexts["Preview generation paused"].waitForExistence(timeout: 5))
        let resume = app.buttons["mobile.photos.automatic.resume"]; XCTAssertTrue(resume.isEnabled)
        attachScreenshot(app, name: "Paused foreground preview generation")
        resume.tap(); XCTAssertTrue(pause.waitForExistence(timeout: 12)); pause.tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5)); XCTAssertTrue(resume.isEnabled)
    }

    func test自动预览中文开关保存后前台生成() {
        let app = launchFixture(state: "photo-preview", language: "zh-Hans"); defer { app.terminate() }
        openPhotos(app, chinese: true); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.preferences.automatic", in: app).tap()
        let toggle = app.switches["photos.automatic.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["mobile.photos.preferences.save"].isEnabled)
        XCTAssertTrue(app.staticTexts["打开照片页面时补齐缺少的预览，离开页面或切到后台会暂停。原件保持不变。"].exists)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        attachScreenshot(app, name: "自动预览前台设置")
        app.buttons["mobile.photos.preferences.save"].tap()
        XCTAssertTrue(app.staticTexts["已生成 1 项预览"].waitForExistence(timeout: 12))
        attachScreenshot(app, name: "前台自动预览完成")
    }

    func test照片库维护确认取消和共享来源() {
        let app = launchFixture(state: "photo-preview-admin"); defer { app.terminate() }
        openPhotos(app); element("mobile.photos.source", in: app).tap(); app.buttons["Shared Photos"].tap()
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.preferences.maintenance", in: app).tap()
        let start = app.buttons["mobile.photos.maintenance.basic"]; XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); XCTAssertTrue(app.alerts.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Shared Photos")).firstMatch.exists)
        attachScreenshot(app, name: "Shared photo library maintenance confirmation")
        app.alerts.firstMatch.buttons["Cancel"].tap(); start.tap(); app.alerts.firstMatch.buttons["mobile.photos.preferences.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
    }

    func test新格式部分完成只能补关闭提示() {
        let app = launchFixture(state: "photo-preview-partial"); defer { app.terminate() }
        openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.preferences.codec", in: app).tap()
        XCTAssertTrue(app.buttons["mobile.photos.codec.generate"].waitForExistence(timeout: 5)); attachScreenshot(app, name: "New format preview generation")
        app.buttons["mobile.photos.codec.generate"].tap(); XCTAssertTrue(app.buttons["mobile.photos.album.continue"].waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch(); openPhotos(app)
        XCTAssertTrue(app.buttons["mobile.photos.album.refresh"].waitForExistence(timeout: 8)); app.buttons["mobile.photos.album.refresh"].tap()
        XCTAssertTrue(app.buttons["mobile.photos.album.continue"].waitForExistence(timeout: 8)); attachScreenshot(app, name: "Codec generation accepted before restart")
        app.buttons["mobile.photos.album.continue"].tap()
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.preferences.codec", in: app).tap()
        XCTAssertTrue(app.staticTexts["There are no new format support messages."].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["mobile.photos.codec.generate"].exists)
    }

    func test预览设置空内容错误与加载状态() {
        for state in ["photo-preview-empty", "photo-preview-error", "photo-preview-loading", "photo-preview-nohome"] {
            let app = launchFixture(state: state)
            openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.preferences.codec", in: app).tap()
            if state.hasSuffix("empty") { XCTAssertTrue(app.staticTexts["There are no new format support messages."].waitForExistence(timeout: 5)) }
            else if state.hasSuffix("error") { XCTAssertTrue(app.staticTexts["Couldn’t load photo settings. Try again."].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["Try again"].exists) }
            else if state.hasSuffix("loading") { XCTAssertTrue(element("mobile.photos.preferences.loading", in: app).waitForExistence(timeout: 5)) }
            else { XCTAssertTrue(app.buttons["mobile.photos.codec.dismiss"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["mobile.photos.codec.generate"].exists) }
            attachScreenshot(app, name: state); app.terminate()
        }
    }

    func test维护忙碌与不支持预览仍显示真实限制() {
        for state in ["photo-preview-running", "photo-preview-unsupported"] {
            let app = launchFixture(state: state)
            openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.preferences.maintenance", in: app).tap()
            XCTAssertTrue(app.buttons["mobile.photos.maintenance.thumbnail"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["mobile.photos.maintenance.thumbnail"].isEnabled)
            XCTAssertTrue(app.buttons["mobile.photos.maintenance.basic"].isEnabled)
            attachScreenshot(app, name: state); app.terminate()
        }
    }

    func test自动预览设置未知重启后禁止再次保存() {
        let app = launchFixture(state: "photo-preview-unknown"); defer { app.terminate() }
        openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.preferences.automatic", in: app).tap()
        let toggle = app.switches["photos.automatic.enabled"]; XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); app.buttons["mobile.photos.preferences.save"].tap()
        XCTAssertTrue(app.buttons["mobile.photos.album.refresh"].waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch(); openPhotos(app)
        XCTAssertTrue(app.buttons["mobile.photos.album.refresh"].waitForExistence(timeout: 8))
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.preferences.automatic", in: app).tap()
        XCTAssertTrue(app.buttons["mobile.photos.preferences.save"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["mobile.photos.preferences.save"].isEnabled)
        attachScreenshot(app, name: "Automatic preview setting recovery")
    }

    func test照片所选重建和单张预览重建() {
        let app = launchFixture(state: "photo-repair"); defer { app.terminate() }
        openPhotos(app); selectPhotoItems(app)
        element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.repair.selection", in: app).tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Selected photo previews regenerated")
        element("mobile.photos.selection.begin", in: app).tap()
        app.buttons["Sample 1.jpg"].tap(); XCTAssertTrue(element("mobile.photos.edit.preview", in: app).waitForExistence(timeout: 5))
        element("mobile.photos.edit.preview", in: app).tap(); element("mobile.photos.repair.preview", in: app).tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Single preview regenerated")
    }

    func test照片未完成预览中文搜索选择与继续() {
        let app = launchFixture(state: "photo-repair", language: "zh-Hans"); defer { app.terminate() }
        openPhotos(app, chinese: true); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.repair.begin", in: app).tap()
        XCTAssertTrue(element("mobile.photos.repair.item.1", in: app).waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch; search.tap(); search.typeText("no-match")
        XCTAssertTrue(app.staticTexts["没有找到匹配的照片，请换个关键词搜索。"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "未完成预览搜索为空")
        search.tap(); search.buttons.firstMatch.tap(); search.tap(); search.typeText("2.jpg")
        element("mobile.photos.repair.select", in: app).tap()
        XCTAssertFalse(element("mobile.photos.repair.item.1", in: app).exists)
        XCTAssertTrue(element("mobile.photos.repair.item.2", in: app).exists)
        attachScreenshot(app, name: "未完成预览按文件名选择")
        if !app.buttons["mobile.photos.repair.resume"].exists {
            let closeSearch = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭"])).firstMatch
            XCTAssertTrue(closeSearch.waitForExistence(timeout: 5)); closeSearch.tap()
        }
        app.buttons["mobile.photos.repair.resume"].tap(); XCTAssertTrue(app.staticTexts["操作已完成。"].waitForExistence(timeout: 8))
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.repair.begin", in: app).tap()
        XCTAssertTrue(element("mobile.photos.repair.item.1", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("mobile.photos.repair.item.2", in: app).exists)
    }

    func test照片未完成预览来源切换和清除选择() {
        let app = launchFixture(state: "photo-repair"); defer { app.terminate() }
        openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.repair.begin", in: app).tap()
        XCTAssertTrue(element("mobile.photos.repair.item.2", in: app).waitForExistence(timeout: 5))
        element("mobile.photos.repair.clear", in: app).tap(); XCTAssertFalse(app.buttons["mobile.photos.repair.resume"].isEnabled)
        app.segmentedControls.buttons["Shared Photos"].tap()
        XCTAssertTrue(app.buttons["Shared sample.jpg"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("mobile.photos.repair.item.2", in: app).exists)
        XCTAssertTrue(app.buttons["mobile.photos.repair.resume"].isEnabled)
        attachScreenshot(app, name: "Shared unfinished previews")
        app.buttons["mobile.photos.repair.resume"].tap(); XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
    }

    func test照片未完成预览空内容错误与加载状态() {
        for state in ["photo-repair-empty", "photo-repair-error", "photo-repair-loading"] {
            let app = launchFixture(state: state)
            openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.repair.begin", in: app).tap()
            XCTAssertTrue(app.buttons["mobile.photos.repair.resume"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["mobile.photos.repair.resume"].isEnabled)
            if state.hasSuffix("empty") { XCTAssertTrue(app.staticTexts["No unfinished previews"].waitForExistence(timeout: 5)) }
            else if state.hasSuffix("error") { XCTAssertTrue(app.staticTexts["Unable to load unfinished previews. Check your connection and try again."].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["Try again"].exists) }
            else { XCTAssertTrue(element("mobile.photos.repair.loading", in: app).waitForExistence(timeout: 5)) }
            attachScreenshot(app, name: state); app.terminate()
        }
    }

    func test照片预览重建未知重启不再次发送() {
        let app = launchFixture(state: "photo-repair-unknown"); defer { app.terminate() }
        openPhotos(app); selectPhotoItems(app)
        element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.repair.selection", in: app).tap()
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch(); openPhotos(app)
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.repair.begin", in: app).tap()
        XCTAssertTrue(element("mobile.photos.repair.item.1", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mobile.photos.repair.resume"].isEnabled)
        attachScreenshot(app, name: "Preview repair restart keeps submission blocked")
    }

    func test照片重复默认覆盖确认可取消再保存() {
        let app = launchFixture(state: "photo-preferences"); defer { app.terminate() }
        openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.preferences.duplicates", in: app).tap()
        let transfer = element("mobile.photos.preferences.transfer", in: app)
        XCTAssertTrue(transfer.waitForExistence(timeout: 5)); transfer.tap(); app.buttons["Overwrite existing items"].tap()
        app.buttons["mobile.photos.preferences.save"].tap(); XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Future moves and copies will default to replacing items with the same name at the destination. You can change this option for each operation.")).firstMatch.exists)
        attachScreenshot(app, name: "Default duplicate overwrite consequences")
        app.alerts.firstMatch.buttons["Cancel"].firstMatch.tap(); app.buttons["mobile.photos.preferences.save"].tap(); app.alerts.firstMatch.buttons["mobile.photos.preferences.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
    }

    func test照片显示偏好中文保存及预览默认资料() {
        let app = launchFixture(state: "photo-preferences", language: "zh-Hans"); defer { app.terminate() }
        openPhotos(app, chinese: true); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.preferences.display", in: app).tap()
        XCTAssertTrue(element("mobile.photos.preferences.grouping", in: app).waitForExistence(timeout: 5))
        element("mobile.photos.preferences.grouping", in: app).tap(); app.buttons["按月"].tap()
        let info = app.switches["mobile.photos.preferences.info"]
        for _ in 0..<3 where !info.isHittable { app.swipeUp() }
        info.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        attachScreenshot(app, name: "照片显示设置")
        app.buttons["mobile.photos.preferences.save"].tap(); XCTAssertTrue(app.staticTexts["操作已完成。"].waitForExistence(timeout: 8))
        app.buttons["Sample 1.jpg"].tap(); XCTAssertTrue(app.staticTexts["拍摄时间"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "照片预览默认显示资料")
    }

    func test照片预览旋转并显示保存后的尺寸() {
        let app = launchFixture(state: "photo-preferences"); defer { app.terminate() }
        openPhotos(app); XCTAssertTrue(app.buttons["Sample 1.jpg"].waitForExistence(timeout: 8)); app.buttons["Sample 1.jpg"].tap()
        XCTAssertTrue(element("mobile.photos.edit.preview", in: app).waitForExistence(timeout: 5)); element("mobile.photos.edit.preview", in: app).tap()
        let rotate = element("mobile.photos.rotate", in: app); XCTAssertTrue(rotate.waitForExistence(timeout: 5)); XCTAssertTrue(rotate.isEnabled); rotate.tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        app.buttons["Details"].tap()
        let resolution = app.staticTexts["80 × 100 pixels"]
        for _ in 0..<3 where !resolution.isHittable { app.swipeUp() }
        XCTAssertTrue(resolution.waitForExistence(timeout: 5)); attachScreenshot(app, name: "Saved photo rotation and dimensions")
    }

    func test照片智能分类权限与空内容错误和加载状态() {
        for state in ["photo-preferences-restricted", "photo-preferences-empty", "photo-preferences-error", "photo-preferences-loading"] {
            let app = launchFixture(state: state)
            openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.preferences.recognition", in: app).tap()
            let save = app.buttons["mobile.photos.preferences.save"]; XCTAssertTrue(save.waitForExistence(timeout: 5)); XCTAssertFalse(save.isEnabled)
            if state.hasSuffix("restricted") {
                let person = app.switches["mobile.photos.preferences.enable_person"]
                XCTAssertTrue(person.waitForExistence(timeout: 5)); XCTAssertTrue(person.isEnabled)
                XCTAssertFalse(app.switches["mobile.photos.preferences.enable_similar"].isEnabled)
                person.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); XCTAssertTrue(save.isEnabled)
            } else if state.hasSuffix("empty") { XCTAssertTrue(app.staticTexts["No recognition settings available"].waitForExistence(timeout: 5)) }
            else if state.hasSuffix("error") { XCTAssertTrue(app.staticTexts["Couldn’t load photo settings. Try again."].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["Try again"].exists) }
            else { XCTAssertTrue(element("mobile.photos.preferences.loading", in: app).waitForExistence(timeout: 5)) }
            attachScreenshot(app, name: state); app.terminate()
        }
    }

    func test照片偏好未知重启保留恢复入口与保存限制() {
        let app = launchFixture(state: "photo-preferences-unknown"); defer { app.terminate() }
        openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.preferences.display", in: app).tap()
        let info = app.switches["mobile.photos.preferences.info"]; XCTAssertTrue(info.waitForExistence(timeout: 5))
        for _ in 0..<3 where !info.isHittable { app.swipeUp() }
        info.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); app.buttons["mobile.photos.preferences.save"].tap()
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch(); openPhotos(app)
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.preferences.display", in: app).tap()
        XCTAssertTrue(app.buttons["mobile.photos.preferences.save"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["mobile.photos.preferences.save"].isEnabled)
        attachScreenshot(app, name: "Photo preferences recovery after restart")
    }


    func test照片文件夹权限共享范围与覆盖子目录确认() {
        let app = launchFixture(state: "photo-folder-sharing"); defer { app.terminate() }
        openPhotos(app); element("mobile.photos.source", in: app).tap(); app.buttons["Shared Photos"].tap(); openPhotoSection("Folders", app: app)
        XCTAssertTrue(element("mobile.photos.collection.actions.2", in: app).waitForExistence(timeout: 5))
        element("mobile.photos.collection.actions.2", in: app).tap(); element("mobile.photos.folderSharing.begin", in: app).tap()
        let access = element("mobile.photos.folderSharing.access", in: app)
        XCTAssertTrue(access.waitForExistence(timeout: 5)); access.tap(); app.buttons["Anyone with the link can view and download"].tap()
        let apply = app.switches["mobile.photos.folderSharing.apply"]
        revealInForm(apply, in: app)
        XCTAssertTrue(apply.isHittable); apply.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(apply.value as? String, "1")
        app.buttons["mobile.photos.folderSharing.save"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Change access to “Source” and all its subfolders? Existing subfolder permissions will be replaced, and people may gain or lose access.")).firstMatch.exists)
        attachScreenshot(app, name: "Folder permissions and subfolder warning")
        app.alerts.buttons["Cancel"].firstMatch.tap(); app.buttons["mobile.photos.folderSharing.save"].tap()
        app.alerts.buttons["mobile.photos.folderSharing.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
    }

    func test照片文件夹权限中文成员搜索及普通收紧保存() {
        let app = launchFixture(state: "photo-folder-sharing", language: "zh-Hans"); defer { app.terminate() }
        openPhotos(app, chinese: true); element("mobile.photos.source", in: app).tap(); app.buttons["共享照片"].tap(); openPhotoSection("文件夹", app: app)
        XCTAssertTrue(element("mobile.photos.collection.actions.2", in: app).waitForExistence(timeout: 5))
        element("mobile.photos.collection.actions.2", in: app).tap(); element("mobile.photos.folderSharing.begin", in: app).tap()
        let members = element("mobile.photos.folderSharing.members", in: app)
        XCTAssertTrue(members.waitForExistence(timeout: 5)); for _ in 0..<3 where !members.isHittable { app.swipeUp() }; members.tap()
        XCTAssertTrue(app.buttons["Sample group"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        if !search.exists {
            let reveal = app.buttons.matching(NSPredicate(format: "label == 'Search' OR label == '搜索'")).firstMatch
            XCTAssertTrue(reveal.waitForExistence(timeout: 5)); reveal.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("group")
        XCTAssertTrue(app.buttons["Sample group"].exists); XCTAssertFalse(app.buttons["Sample member"].exists)
        attachScreenshot(app, name: "Folder permission member search Chinese")
        search.typeText("\n")
        let closeSearch = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭"])).firstMatch
        if closeSearch.exists && closeSearch.isHittable { closeSearch.tap() }
        XCTAssertTrue(app.navigationBars["选择用户或群组"].waitForExistence(timeout: 5))
        app.navigationBars["选择用户或群组"].buttons.firstMatch.tap()
        let access = element("mobile.photos.folderSharing.access", in: app)
        XCTAssertTrue(access.waitForExistence(timeout: 5))
        for _ in 0..<3 where !access.isHittable { app.swipeDown() }; access.tap(); app.buttons["仅限拥有完整访问权限的用户"].tap()
        app.buttons["mobile.photos.folderSharing.save"].tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["操作已完成。"].waitForExistence(timeout: 8))
    }

    func test照片文件夹权限加载失败与父目录限制() {
        for state in ["photo-folder-sharing-error", "photo-folder-sharing-parent"] {
            let app = launchFixture(state: state); defer { app.terminate() }
            openPhotos(app); element("mobile.photos.source", in: app).tap(); app.buttons["Shared Photos"].tap(); openPhotoSection("Folders", app: app)
            if state.hasSuffix("-parent") { app.buttons["mobile.photos.collection.2"].tap() }
            let id = state.hasSuffix("-parent") ? "200" : "2"
            XCTAssertTrue(element("mobile.photos.collection.actions.\(id)", in: app).waitForExistence(timeout: 5))
            element("mobile.photos.collection.actions.\(id)", in: app).tap(); element("mobile.photos.folderSharing.begin", in: app).tap()
            if state.hasSuffix("-parent") {
                XCTAssertTrue(app.staticTexts["The parent folder is restricted to full-access users. Change its permissions before sharing this folder."].waitForExistence(timeout: 5))
                XCTAssertFalse(element("mobile.photos.folderSharing.access", in: app).isEnabled)
            } else { XCTAssertTrue(app.staticTexts["Could not load folder permissions. Check your connection and try again."].waitForExistence(timeout: 5)) }
            XCTAssertFalse(app.buttons["mobile.photos.folderSharing.save"].isEnabled)
            attachScreenshot(app, name: state); app.buttons["Cancel"].firstMatch.tap()
        }
    }

    func test照片后台任务筛选错误与取消后保留进度() {
        let app = launchFixture(state: "photo-tasks"); defer { app.terminate() }
        openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.tasks.begin", in: app).tap()
        XCTAssertTrue(element("mobile.photos.tasks.cancel.41", in: app).waitForExistence(timeout: 5))
        element("mobile.photos.tasks.errors.42", in: app).tap()
        XCTAssertTrue(app.staticTexts["Your storage quota is full. Free up space or contact your administrator."].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Photo task error details"); app.buttons["mobile.photos.tasks.errors.close"].tap()
        XCTAssertTrue(app.buttons["mobile.photos.tasks.errors.close"].waitForNonExistence(timeout: 5))
        app.segmentedControls.buttons["In Progress"].tap(); element("mobile.photos.tasks.cancel.41", in: app).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["Completed copies or moves will remain. The remaining work will stop."].exists)
        attachScreenshot(app, name: "Photo task cancellation consequences")
        app.alerts.buttons["mobile.photos.tasks.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No Matching Tasks"].waitForExistence(timeout: 8))
        app.segmentedControls.buttons["Finished"].tap()
        XCTAssertTrue(app.staticTexts["Canceled"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Processed 2 of 5 · Failed 0 · Skipped 0 · Replaced 0"].exists)
    }

    func test照片后台任务清除记录和打开原目标() {
        let app = launchFixture(state: "photo-tasks"); defer { app.terminate() }
        openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.tasks.begin", in: app).tap()
        XCTAssertTrue(element("mobile.photos.tasks.open.43", in: app).waitForExistence(timeout: 5))
        let open = element("mobile.photos.tasks.open.43", in: app); for _ in 0..<3 where !open.isHittable { app.swipeUp() }; open.tap()
        XCTAssertTrue(app.navigationBars["Destination"].waitForExistence(timeout: 8))
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.tasks.begin", in: app).tap()
        XCTAssertTrue(element("mobile.photos.tasks.actions", in: app).waitForExistence(timeout: 5)); element("mobile.photos.tasks.actions", in: app).tap()
        element("mobile.photos.tasks.clearCompleted", in: app).tap()
        XCTAssertTrue(app.staticTexts["Only the selected task records will be cleared. Photos and folders will remain."].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Photo task record clearing warning"); app.alerts.buttons["mobile.photos.tasks.confirm"].firstMatch.tap()
        app.segmentedControls.buttons["Finished"].tap(); XCTAssertTrue(app.staticTexts["No Matching Tasks"].waitForExistence(timeout: 8))
        app.segmentedControls.buttons["All"].tap(); XCTAssertTrue(element("mobile.photos.tasks.cancel.41", in: app).exists)
    }

    func test照片后台任务未知重启仅刷新状态() {
        let app = launchFixture(state: "photo-tasks-unknown"); defer { app.terminate() }
        openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.tasks.begin", in: app).tap()
        XCTAssertTrue(element("mobile.photos.tasks.cancel.41", in: app).waitForExistence(timeout: 5)); element("mobile.photos.tasks.cancel.41", in: app).tap()
        app.alerts.buttons["mobile.photos.tasks.confirm"].firstMatch.tap()
        XCTAssertTrue(element("mobile.photos.tasks.resume", in: app).waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch(); openPhotos(app)
        XCTAssertTrue(element("mobile.photos.actions", in: app).waitForExistence(timeout: 8)); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.tasks.begin", in: app).tap()
        XCTAssertTrue(element("mobile.photos.tasks.resume", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("mobile.photos.tasks.cancel.41", in: app).isEnabled)
        attachScreenshot(app, name: "Photo task restart recovery")
    }

    func test照片后台任务空内容与错误有恢复操作() {
        for state in ["photo-tasks-empty", "photo-tasks-error"] {
            let app = launchFixture(state: state); defer { app.terminate() }
            openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.tasks.begin", in: app).tap()
            XCTAssertTrue(app.staticTexts[state.hasSuffix("-empty") ? "No Background Tasks" : "Could not retrieve the latest tasks. Check your connection and refresh."].waitForExistence(timeout: 5))
            if state.hasSuffix("-error") { XCTAssertTrue(app.buttons["Try again"].exists) }
            attachScreenshot(app, name: state); app.buttons["Close"].firstMatch.tap()
        }
    }

    func test照片目录新建重命名与排序() {
        let app = launchFixture(state: "photo-folders"); defer { app.terminate() }
        openPhotos(app); openPhotoSection("Folders", app: app)
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.folder.create", in: app).tap()
        let name = app.textFields["mobile.photos.folder.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Trip")
        app.buttons["mobile.photos.folder.submit"].tap()
        let created = app.buttons["mobile.photos.collection.101"]
        XCTAssertTrue(created.waitForExistence(timeout: 8)); created.tap()
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.folder.rename", in: app).tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "Renamed")
        attachScreenshot(app, name: "Photo folder rename")
        app.buttons["mobile.photos.folder.submit"].tap()
        XCTAssertTrue(app.navigationBars["Renamed"].waitForExistence(timeout: 8))
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.folder.sort", in: app).tap()
        XCTAssertTrue(element("mobile.photos.folder.sortField", in: app).waitForExistence(timeout: 5))
        element("mobile.photos.folder.sortField", in: app).tap(); app.buttons["Name"].tap()
        attachScreenshot(app, name: "Photo folder sorting")
        app.buttons["mobile.photos.folder.submit"].tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
    }

    func test照片目录混合选择复制覆盖确认可取消再保存() {
        let app = launchFixture(state: "photo-folders"); defer { app.terminate() }
        openPhotos(app); openPhotoSection("Folders", app: app)
        element("mobile.photos.selection.begin", in: app).tap()
        app.buttons["mobile.photos.collection.2"].tap(); app.buttons["Sample 1.jpg"].tap()
        element("mobile.photos.selection.actions", in: app).tap()
        XCTAssertFalse(element("mobile.photos.selection.create", in: app).exists)
        XCTAssertFalse(element("mobile.photos.edit.rating", in: app).exists)
        element("mobile.photos.folder.copy", in: app).tap()
        XCTAssertTrue(app.buttons["mobile.photos.folder.child.3"].waitForExistence(timeout: 5)); app.buttons["mobile.photos.folder.child.3"].tap()
        XCTAssertTrue(element("mobile.photos.folder.empty", in: app).waitForExistence(timeout: 5))
        element("mobile.photos.folder.duplicate", in: app).tap(); app.buttons["Overwrite existing items"].tap()
        app.buttons["mobile.photos.folder.submit"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); attachScreenshot(app, name: "Photo folder overwrite confirmation")
        app.alerts.buttons["Cancel"].firstMatch.tap(); XCTAssertTrue(app.buttons["mobile.photos.folder.submit"].exists)
        app.buttons["mobile.photos.folder.submit"].tap(); app.alerts.buttons["mobile.photos.folder.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["mobile.photos.collection.2"].exists); XCTAssertTrue(app.buttons["Sample 1.jpg"].exists)
    }

    func test照片目录中文封面从子目录选片() {
        let app = launchFixture(state: "photo-folders", language: "zh-Hans"); defer { app.terminate() }
        openPhotos(app, chinese: true); openPhotoSection("文件夹", app: app)
        XCTAssertTrue(app.buttons["mobile.photos.collection.2"].waitForExistence(timeout: 5)); app.buttons["mobile.photos.collection.2"].tap()
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.folder.cover", in: app).tap()
        XCTAssertTrue(app.buttons["mobile.photos.folder.child.200"].waitForExistence(timeout: 5)); app.buttons["mobile.photos.folder.child.200"].tap()
        let photo = app.buttons["mobile.photos.folder.cover.3"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5)); photo.tap(); attachScreenshot(app, name: "照片目录子目录封面选择")
        app.buttons["mobile.photos.folder.submit"].tap()
        XCTAssertTrue(app.staticTexts["操作已完成。"].waitForExistence(timeout: 8))
    }

    func test照片目录批量删除确认包含照片和文件夹() {
        let app = launchFixture(state: "photo-folders"); defer { app.terminate() }
        openPhotos(app); openPhotoSection("Folders", app: app)
        element("mobile.photos.selection.begin", in: app).tap(); element("mobile.photos.selection.loaded", in: app).tap()
        element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.selection.delete", in: app).tap()
        app.buttons["mobile.photos.folder.submit"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 folders and 2 photos")).firstMatch.exists)
        attachScreenshot(app, name: "Photo folder mixed deletion confirmation")
        app.alerts.buttons["mobile.photos.folder.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["mobile.photos.collection.2"].exists); XCTAssertFalse(app.buttons["Sample 1.jpg"].exists)
    }

    func test照片目录任务未知重启不重新复制() {
        let app = launchFixture(state: "photo-folders-unknown"); defer { app.terminate() }
        openPhotos(app); selectPhotoItems(app)
        element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.folder.copy", in: app).tap()
        XCTAssertTrue(app.buttons["mobile.photos.folder.child.3"].waitForExistence(timeout: 5)); app.buttons["mobile.photos.folder.child.3"].tap()
        app.buttons["mobile.photos.folder.submit"].tap()
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch(); openPhotos(app)
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Photo folder task restored after restart")
    }

    func test照片目录目标加载失败等待空内容与取消() {
        for state in ["photo-folders-loading", "photo-folders-error", "photo-folders-empty"] {
            let app = launchFixture(state: state)
            openPhotos(app); selectPhotoItems(app)
            element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.folder.copy", in: app).tap()
            if state.hasSuffix("loading") { XCTAssertTrue(element("mobile.photos.folder.loading", in: app).waitForExistence(timeout: 5)) }
            else if state.hasSuffix("error") { XCTAssertTrue(app.staticTexts["Could not load the folder. Check your connection and try again."].waitForExistence(timeout: 5)) }
            else { XCTAssertTrue(element("mobile.photos.folder.empty", in: app).waitForExistence(timeout: 5)) }
            XCTAssertFalse(app.buttons["mobile.photos.folder.submit"].isEnabled)
            attachScreenshot(app, name: state); app.buttons["Cancel"].tap(); app.terminate()
        }
    }

    func test照片目录拖放后选择目标并提交移动() {
        let app = launchFixture(state: "photo-folders"); defer { app.terminate() }
        openPhotos(app); openPhotoSection("Folders", app: app)
        let source = app.buttons["mobile.photos.collection.2"], target = app.buttons["mobile.photos.collection.3"]
        XCTAssertTrue(source.waitForExistence(timeout: 5)); XCTAssertTrue(target.exists)
        source.press(forDuration: 1.0, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 1.0)
        XCTAssertTrue(app.buttons["mobile.photos.folder.submit"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["mobile.photos.folder.submit"].isEnabled)
        attachScreenshot(app, name: "Photo folder drag destination")
        app.buttons["mobile.photos.folder.submit"].tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["mobile.photos.collection.2"].exists)
    }

    func test照片资料批量描述保存与日期表单() {
        let app = launchFixture(state: "photo-edit"); defer { app.terminate() }
        openPhotos(app); openPhotoEditForm("description", app: app)
        let text = app.textViews["mobile.photos.edit.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap(); text.typeText("Trip description")
        attachScreenshot(app, name: "Photo description batch editing")
        app.buttons["mobile.photos.edit.submit"].tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.edit.date", in: app).tap()
        XCTAssertTrue(element("mobile.photos.edit.dateValue", in: app).waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Photo date editor")
        app.buttons["mobile.photos.edit.submit"].tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
    }

    func test照片资料预览可评分并显示标签() {
        let app = launchFixture(state: "photo-edit"); defer { app.terminate() }
        openPhotos(app); XCTAssertTrue(app.buttons["Sample 1.jpg"].waitForExistence(timeout: 8)); app.buttons["Sample 1.jpg"].tap()
        XCTAssertTrue(element("mobile.photos.edit.preview", in: app).waitForExistence(timeout: 5)); element("mobile.photos.edit.preview", in: app).tap()
        element("mobile.photos.edit.rating", in: app).tap()
        let stars = app.buttons["4 stars"]
        XCTAssertTrue(stars.waitForExistence(timeout: 5)); stars.tap()
        app.buttons["mobile.photos.edit.submit"].tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        app.buttons["Details"].tap()
        XCTAssertTrue(app.staticTexts["4 stars"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sample tag"].exists)
        app.scrollViews.containing(.staticText, identifier: "Sample tag").firstMatch.swipeUp()
        XCTAssertTrue(app.staticTexts["Sample tag"].isHittable)
        attachScreenshot(app, name: "Photo preview edited rating and tags")
    }

    func test照片资料中文时间偏移与标签移除() {
        let app = launchFixture(state: "photo-edit", language: "zh-Hans"); defer { app.terminate() }
        openPhotos(app, chinese: true); openPhotoEditForm("shiftDates", app: app)
        XCTAssertTrue(element("mobile.photos.edit.direction", in: app).waitForExistence(timeout: 5))
        let amount = app.textFields["mobile.photos.edit.amount"]
        amount.tap(); amount.typeText(XCUIKeyboardKey.delete.rawValue + "2")
        attachScreenshot(app, name: "照片批量时间偏移")
        app.buttons["mobile.photos.edit.submit"].tap()
        XCTAssertTrue(app.staticTexts["操作已完成。"].waitForExistence(timeout: 8))
        element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.edit.tagsRemove", in: app).tap()
        let tag = app.switches["mobile.photos.edit.tag.8"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5)); tag.tap()
        attachScreenshot(app, name: "照片标签移除")
        app.buttons["mobile.photos.edit.submit"].tap()
        XCTAssertTrue(app.staticTexts["操作已完成。"].waitForExistence(timeout: 8))
    }

    func test照片资料标签创建后可只继续剩余添加() {
        let app = launchFixture(state: "photo-edit-tag-partial"); defer { app.terminate() }
        openPhotos(app); openPhotoEditForm("tagsCreate", app: app)
        let name = app.textFields["mobile.photos.edit.text"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Trip tag")
        app.buttons["mobile.photos.edit.submit"].tap()
        let retry = element("mobile.photos.album.continue", in: app)
        XCTAssertTrue(retry.waitForExistence(timeout: 8)); attachScreenshot(app, name: "Created tag with remaining photos")
        retry.tap(); XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        XCTAssertFalse(element("mobile.photos.album.continue", in: app).exists)
    }

    func test照片资料标签读取等待失败与空内容() {
        for state in ["photo-edit-tags-loading", "photo-edit-tags-error", "photo-edit-tags-empty"] {
            let app = launchFixture(state: state)
            openPhotos(app); openPhotoEditForm("tagsAdd", app: app)
            XCTAssertFalse(app.buttons["mobile.photos.edit.submit"].isEnabled)
            if state.hasSuffix("loading") { XCTAssertTrue(element("mobile.photos.edit.loading", in: app).waitForExistence(timeout: 5)) }
            else if state.hasSuffix("error") { XCTAssertTrue(app.staticTexts["Photo details could not be loaded. Reconnect and try again."].waitForExistence(timeout: 5)) }
            else { XCTAssertTrue(app.staticTexts["There are no tags to choose from. Close this form and create a tag first."].waitForExistence(timeout: 5)) }
            attachScreenshot(app, name: state); app.buttons["Cancel"].tap(); app.terminate()
        }
    }

    func test照片资料未知重启保留记录并限制再次编辑() {
        let app = launchFixture(state: "photo-edit-unknown"); defer { app.terminate() }
        openPhotos(app); openPhotoEditForm("shiftDates", app: app)
        app.buttons["mobile.photos.edit.submit"].tap()
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch(); openPhotos(app)
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        element("mobile.photos.actions", in: app).tap()
        XCTAssertFalse(element("mobile.photos.edit.createEmptyTag", in: app).isEnabled)
    }

    private func openPhotoEditForm(_ action: String, app: XCUIApplication) {
        let selection = element("mobile.photos.selection.begin", in: app)
        XCTAssertTrue(selection.waitForExistence(timeout: 8)); selection.tap()
        element("mobile.photos.selection.loaded", in: app).tap()
        element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.edit.\(action)", in: app).tap()
        XCTAssertTrue(app.buttons["mobile.photos.edit.submit"].waitForExistence(timeout: 5))
    }

    func test冻结相册普通恢复与不支持规则展示() {
        let app = launchFixture(state: "photo-frozen-no-condition")
        defer { app.terminate() }
        openFrozenForm(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "People, Recently added")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(element("mobile.photos.frozen.action", in: app).exists)
        XCTAssertFalse(app.textFields["mobile.photos.condition.name"].exists)
        attachScreenshot(app, name: "Frozen album regular restoration")
        app.buttons["mobile.photos.condition.save"].tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        element("mobile.photos.actions", in: app).tap(); XCTAssertFalse(element("mobile.photos.frozen.restore", in: app).exists)
    }
    func test冻结相册重建确认取消后再提交() {
        let app = launchFixture(state: "photo-frozen")
        defer { app.terminate() }
        openFrozenForm(app)
        element("mobile.photos.frozen.action", in: app).tap(); app.buttons["Conditional album"].tap()
        XCTAssertTrue(app.textFields["mobile.photos.condition.name"].waitForExistence(timeout: 5))
        app.buttons["mobile.photos.condition.save"].tap()
        XCTAssertTrue(app.staticTexts["Replace the frozen album?"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Frozen album replacement confirmation")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["mobile.photos.condition.save"].waitForExistence(timeout: 5))
        app.buttons["mobile.photos.condition.save"].tap(); app.alerts.buttons["Replace album"].tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
    }
    func test冻结相册中文重建保留旧册显示部分结果() {
        let app = launchFixture(state: "photo-frozen-partial", language: "zh-Hans")
        defer { app.terminate() }
        openFrozenForm(app, chinese: true)
        element("mobile.photos.frozen.action", in: app).tap(); app.buttons["条件相册"].tap()
        attachScreenshot(app, name: "冻结相册中文重建规则")
        app.buttons["mobile.photos.condition.save"].tap(); app.alerts.buttons["替换相册"].tap()
        XCTAssertTrue(app.staticTexts["新相册已创建，但旧相册未能移除。请检查两册内容，再手动移除旧相册。"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["此相册暂无可显示的照片，请刷新后重试。"].exists)
        XCTAssertFalse(app.staticTexts["暂时没有相册。请在 Synology Photos 中创建相册，然后刷新。"].exists)
        attachScreenshot(app, name: "冻结相册保留两册结果")
    }
    func test冻结相册读取等待失败与未知重启() {
        for state in ["photo-frozen-loading", "photo-frozen-error", "photo-frozen-unknown"] {
            let app = launchFixture(state: state)
            openFrozenForm(app)
            if state.hasSuffix("unknown") {
                app.buttons["mobile.photos.condition.save"].tap()
                XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
                app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch(); openPhotos(app)
                XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
            } else {
                XCTAssertFalse(app.buttons["mobile.photos.condition.save"].isEnabled)
                if state.hasSuffix("error") { XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 5)) }
                attachScreenshot(app, name: state); app.buttons["Cancel"].tap()
            }
            app.terminate()
        }
    }
    private func openFrozenForm(_ app: XCUIApplication, chinese: Bool = false) {
        openPhotos(app, chinese: chinese); openPhotoSection(chinese ? "相册" : "Albums", app: app)
        XCTAssertTrue(app.buttons["Sample frozen album"].waitForExistence(timeout: 8)); app.buttons["Sample frozen album"].tap()
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.frozen.restore", in: app).tap()
        XCTAssertTrue(app.buttons["mobile.photos.condition.save"].waitForExistence(timeout: 5))
    }

    func test条件相册创建添加关键词预览并保存() {
        let app = launchFixture(state: "photo-condition")
        defer { app.terminate() }
        openConditionForm(app)
        let title = app.textFields["mobile.photos.condition.name"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["mobile.photos.condition.save"].isEnabled)
        title.tap(); title.typeText("Trip rules")
        let keyword = app.textFields["mobile.photos.condition.search"]
        reveal(keyword, in: app); keyword.tap(); keyword.typeText("summer")
        let add = app.buttons["mobile.photos.condition.add"]; reveal(add, in: app); add.tap()
        XCTAssertTrue(app.staticTexts["summer"].waitForExistence(timeout: 5))
        let preview = app.buttons["mobile.photos.condition.preview"]; reveal(preview, in: app); preview.tap()
        XCTAssertTrue(app.staticTexts["3 photos and videos"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["3 photos and videos"], in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        attachScreenshot(app, name: "Conditional album rules and match count")
        app.buttons["mobile.photos.condition.save"].tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        openPhotoSection("Albums", app: app); XCTAssertTrue(app.buttons["Trip rules"].waitForExistence(timeout: 8))
    }

    func test条件相册编辑保留缺名规则并取消不写入() {
        let app = launchFixture(state: "photo-condition")
        defer { app.terminate() }
        openConditionForm(app, editing: true)
        XCTAssertFalse(app.buttons["mobile.photos.condition.save"].isEnabled)
        XCTAssertTrue(app.staticTexts["Keep existing types"].exists)
        let reference = app.staticTexts["Existing condition 77"]; reveal(reference, in: app)
        attachScreenshot(app, name: "Existing conditional rules remain editable")
        let keyword = app.textFields["mobile.photos.condition.search"]; reveal(keyword, in: app); keyword.tap(); keyword.typeText("extra")
        let add = app.buttons["mobile.photos.condition.add"]; reveal(add, in: app); add.tap()
        XCTAssertTrue(app.buttons["mobile.photos.condition.save"].isEnabled); app.buttons["Cancel"].tap()
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.condition.edit", in: app).tap()
        XCTAssertTrue(app.buttons["mobile.photos.condition.save"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mobile.photos.condition.save"].isEnabled)
        let media = element("mobile.photos.condition.media", in: app); media.tap(); app.buttons["Videos"].tap()
        app.buttons["mobile.photos.condition.save"].tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
    }

    func test条件相册中文建议搜索空结果与选择人物() {
        let app = launchFixture(state: "photo-condition", language: "zh-Hans")
        defer { app.terminate() }
        openConditionForm(app, chinese: true)
        let title = app.textFields["mobile.photos.condition.name"]; title.tap(); title.typeText("People")
        let field = element("mobile.photos.condition.field", in: app); reveal(field, in: app); field.tap(); app.buttons["人物"].tap()
        let keyword = app.textFields["mobile.photos.condition.search"]; reveal(keyword, in: app); keyword.tap(); keyword.typeText("no-match")
        let find = app.buttons["mobile.photos.condition.find"]; reveal(find, in: app); find.tap()
        XCTAssertTrue(app.staticTexts["没有匹配项，请换个关键词查找。"].waitForExistence(timeout: 5))
        keyword.tap(); keyword.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "no-match".count))
        XCTAssertEqual(keyword.value as? String, "关键词")
        // 收起键盘后先滚动到实际按钮，避免自动点按仍使用键盘出现时的位置。
        reveal(find, in: app); find.tap(); let person = app.buttons["Sample person"]; XCTAssertTrue(person.waitForExistence(timeout: 5)); reveal(person, in: app); person.tap()
        attachScreenshot(app, name: "条件相册中文建议与人物规则")
        app.buttons["mobile.photos.condition.save"].tap()
        XCTAssertTrue(app.staticTexts["操作已完成。"].waitForExistence(timeout: 8))
    }

    func test条件相册共享目录选择与空子目录导航() {
        let app = launchFixture(state: "photo-condition-nohome")
        defer { app.terminate() }
        openConditionForm(app)
        XCTAssertFalse(element("mobile.photos.condition.source", in: app).exists)
        let title = app.textFields["mobile.photos.condition.name"]; title.tap(); title.typeText("Shared rules")
        element("mobile.photos.condition.folders", in: app).tap()
        XCTAssertTrue(app.buttons["Sample folder"].waitForExistence(timeout: 5)); app.cells.buttons["Sample folder"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No subfolders. You can use this folder or choose a parent folder."].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Conditional shared folder navigation")
        element("mobile.photos.condition.addFolder", in: app).tap()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 5)); app.buttons["mobile.photos.condition.save"].tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
    }

    func test条件相册未知重启限制重复创建() {
        let app = launchFixture(state: "photo-condition-unknown")
        openConditionForm(app)
        let title = app.textFields["mobile.photos.condition.name"]; title.tap(); title.typeText("Pending rules")
        app.buttons["mobile.photos.condition.save"].tap()
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch()
        defer { app.terminate() }
        openPhotos(app)
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        element("mobile.photos.actions", in: app).tap(); XCTAssertFalse(element("mobile.photos.condition.create", in: app).isEnabled)
    }

    func test条件相册读取等待与失败支持退出重试() {
        for state in ["photo-condition-loading", "photo-condition-error"] {
            let app = launchFixture(state: state)
            openConditionForm(app, editing: true)
            if state.hasSuffix("loading") { XCTAssertTrue(app.staticTexts["Loading album conditions…"].waitForExistence(timeout: 5)) }
            else {
                XCTAssertTrue(app.staticTexts["Unable to load album conditions. Try again."].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["Try again"].exists)
            }
            XCTAssertFalse(app.buttons["mobile.photos.condition.save"].isEnabled)
            attachScreenshot(app, name: state)
            app.buttons["Cancel"].tap(); XCTAssertTrue(element("mobile.photos.actions", in: app).exists)
            app.terminate()
        }
    }

    private func openConditionForm(_ app: XCUIApplication, editing: Bool = false, chinese: Bool = false) {
        openPhotos(app, chinese: chinese)
        if editing {
            openPhotoSection(chinese ? "相册" : "Albums", app: app)
            XCTAssertTrue(app.buttons["Sample conditional album"].waitForExistence(timeout: 8)); app.buttons["Sample conditional album"].tap()
        }
        element("mobile.photos.actions", in: app).tap()
        element(editing ? "mobile.photos.condition.edit" : "mobile.photos.condition.create", in: app).tap()
        XCTAssertTrue(app.buttons["mobile.photos.condition.save"].waitForExistence(timeout: 5))
    }
    func test照片收集创建并显示可分享链接() {
        let app = launchFixture(state: "photo-request")
        defer { app.terminate() }
        openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.request.create", in: app).tap()
        let title = app.textFields["mobile.photos.request.subject"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["mobile.photos.request.save"].isEnabled)
        title.tap(); title.typeText("Trip photos")
        attachScreenshot(app, name: "Photo request creation form")
        app.buttons["mobile.photos.request.save"].tap()
        XCTAssertTrue(element("mobile.photos.sharing.sendLink", in: app).waitForExistence(timeout: 8))
        openPhotoRequests(app)
        XCTAssertTrue(app.staticTexts["Trip photos"].waitForExistence(timeout: 5))
    }

    func test照片收集编辑和删除确认保留已收内容() {
        let app = launchFixture(state: "photo-request")
        defer { app.terminate() }
        openPhotos(app); openPhotoRequests(app)
        element("mobile.photos.request.actions", in: app).tap(); element("mobile.photos.request.edit", in: app).tap()
        let title = app.textFields["mobile.photos.request.subject"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["mobile.photos.request.save"].isEnabled)
        title.tap(); title.typeText(" updated")
        app.buttons["mobile.photos.request.save"].tap()
        XCTAssertTrue(app.staticTexts["Sample request updated"].waitForExistence(timeout: 8))
        element("mobile.photos.request.actions", in: app).tap(); element("mobile.photos.request.delete", in: app).tap()
        XCTAssertTrue(app.buttons["mobile.photos.request.save"].waitForExistence(timeout: 5)); app.buttons["mobile.photos.request.save"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts["This link will stop accepting photos and videos. Photos and videos already collected will be kept."].exists)
        attachScreenshot(app, name: "Photo request deletion keeps collected originals")
        app.alerts.buttons["Cancel"].tap(); app.buttons["mobile.photos.request.save"].tap()
        app.alerts.buttons.matching(identifier: "mobile.photos.request.confirmDelete").firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Sample request updated"].waitForExistence(timeout: 3))
    }

    func test照片收集选择共享目录并显示空子目录恢复入口() {
        let app = launchFixture(state: "photo-request-nohome")
        defer { app.terminate() }
        openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.request.create", in: app).tap()
        let title = app.textFields["mobile.photos.request.subject"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Shared collection")
        XCTAssertFalse(element("mobile.photos.request.space", in: app).exists)
        element("mobile.photos.request.folder", in: app).tap()
        XCTAssertTrue(app.buttons["Sample folder"].waitForExistence(timeout: 5))
        // 列表中的子目录和工具栏中的根目录同名，选取列表里的触控行。
        app.cells.buttons["Sample folder"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No subfolders. You can use this folder or choose a parent folder."].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Photo request shared destination")
        element("mobile.photos.request.useFolder", in: app).tap()
        XCTAssertTrue(app.staticTexts["/Sample folder"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mobile.photos.request.save"].isEnabled); app.buttons["mobile.photos.request.save"].tap()
        XCTAssertTrue(element("mobile.photos.sharing.sendLink", in: app).waitForExistence(timeout: 8))
    }

    func test照片收集中文搜索空结果可清除并取消编辑() {
        let app = launchFixture(state: "photo-request", language: "zh-Hans")
        defer { app.terminate() }
        openPhotos(app, chinese: true); openPhotoRequests(app, chinese: true)
        let search = app.textFields["mobile.photos.request.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("missing-request")
        XCTAssertTrue(app.staticTexts["没有找到匹配的照片收集，请换个关键词。"].waitForExistence(timeout: 5))
        app.buttons["清除搜索"].tap(); XCTAssertTrue(app.staticTexts["Sample request"].exists)
        element("mobile.photos.request.actions", in: app).tap(); element("mobile.photos.request.edit", in: app).tap()
        XCTAssertTrue(app.textFields["mobile.photos.request.subject"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "照片收集中文编辑")
        app.buttons["取消"].tap(); XCTAssertTrue(app.staticTexts["Sample request"].waitForExistence(timeout: 5))
    }

    func test照片收集未知重启限制重放且不显示成功链接() {
        let app = launchFixture(state: "photo-request-unknown")
        openPhotos(app); element("mobile.photos.actions", in: app).tap(); element("mobile.photos.request.create", in: app).tap()
        let title = app.textFields["mobile.photos.request.subject"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Pending collection")
        app.buttons["mobile.photos.request.save"].tap()
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch()
        defer { app.terminate() }
        openPhotos(app)
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Your previous changes are not finished. Reconnect and refresh the status to continue."].waitForExistence(timeout: 5))
        XCTAssertFalse(element("mobile.photos.sharing.sendLink", in: app).exists)
        element("mobile.photos.actions", in: app).tap(); XCTAssertFalse(element("mobile.photos.request.create", in: app).isEnabled)
    }

    func test照片收集读取等待和错误允许取消或重试() {
        for state in ["photo-request-loading", "photo-request-error"] {
            let app = launchFixture(state: state)
            openPhotos(app); openPhotoRequests(app)
            element("mobile.photos.request.actions", in: app).tap(); element("mobile.photos.request.edit", in: app).tap()
            if state.hasSuffix("loading") { XCTAssertTrue(app.staticTexts["Loading photo request…"].waitForExistence(timeout: 5)) }
            else {
                XCTAssertTrue(app.staticTexts["Could not load this photo request. Reconnect and try again."].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["Try again"].exists)
            }
            XCTAssertFalse(app.buttons["mobile.photos.request.save"].isEnabled)
            attachScreenshot(app, name: state)
            app.buttons["Cancel"].tap(); XCTAssertTrue(app.staticTexts["Sample request"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    private func openPhotoRequests(_ app: XCUIApplication, chinese: Bool = false) {
        openPhotoSection(chinese ? "共享" : "Sharing", app: app)
        let scope = element("mobile.photos.sharing.scope", in: app)
        XCTAssertTrue(scope.waitForExistence(timeout: 5)); scope.tap()
        app.buttons[chinese ? "照片请求" : "Photo requests"].tap()
    }

    func test所选照片创建临时分享并设置公开范围() {
        let app = launchFixture(state: "photo-temporary")
        defer { app.terminate() }
        openTemporarySelection(app)
        let name = app.textFields["mobile.photos.temporary.name"]
        name.tap(); name.typeText("Selected photos")
        app.buttons["mobile.photos.temporary.create"].tap()
        XCTAssertTrue(app.navigationBars["Manage sharing"].waitForExistence(timeout: 8))
        XCTAssertTrue(element("mobile.photos.sharing.access", in: app).waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Temporary selection sharing setup")
        element("mobile.photos.sharing.access", in: app).tap(); app.buttons["Anyone with the link can view"].tap()
        app.buttons["mobile.photos.sharing.save"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons.matching(identifier: "mobile.photos.sharing.confirm").firstMatch.tap()
        XCTAssertTrue(element("mobile.photos.sharing.sendLink", in: app).waitForExistence(timeout: 8))
        XCTAssertFalse(element("mobile.photos.temporary.resume", in: app).exists)
    }

    func test临时分享停止可保留普通相册且原照片仍可见() {
        let app = launchFixture(state: "photo-temporary-existing")
        defer { app.terminate() }
        openAlbumSharing(app)
        element("mobile.photos.sharing.access", in: app).tap(); app.buttons["Turn off sharing"].tap()
        app.buttons["mobile.photos.sharing.save"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label == %@", "The temporary album will be removed. You can keep a copy as a regular album. Your original photos will not be deleted.")).firstMatch.exists)
        attachScreenshot(app, name: "Stop temporary sharing and keep an album")
        app.alerts.buttons.matching(identifier: "mobile.photos.temporary.keep").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Sharing stopped and a copy was saved as an album."].waitForExistence(timeout: 8))
        openPhotoSection("Timeline", app: app)
        XCTAssertTrue(app.buttons["Sample 1.jpg"].waitForExistence(timeout: 8)); XCTAssertTrue(app.buttons["Sample 2.jpg"].exists)
    }

    func test取消临时分享设置会清理相册并保留原照片() {
        let app = launchFixture(state: "photo-temporary")
        defer { app.terminate() }
        openTemporarySelection(app)
        let name = app.textFields["mobile.photos.temporary.name"]
        name.tap(); name.typeText("Cancelled selection"); app.buttons["mobile.photos.temporary.create"].tap()
        XCTAssertTrue(element("mobile.photos.sharing.access", in: app).waitForExistence(timeout: 8))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Sharing stopped. Your photos are kept."].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Sample 1.jpg"].exists); XCTAssertTrue(app.buttons["Sample 2.jpg"].exists)
        XCTAssertFalse(element("mobile.photos.temporary.resume", in: app).exists)
        attachScreenshot(app, name: "Cancelled temporary sharing keeps originals")
    }

    func test临时分享创建未知重启不再次创建或显示可用链接() {
        let app = launchFixture(state: "photo-temporary-unknown")
        openTemporarySelection(app)
        let name = app.textFields["mobile.photos.temporary.name"]
        name.tap(); name.typeText("Pending selection"); app.buttons["mobile.photos.temporary.create"].tap()
        XCTAssertTrue(app.buttons["Refresh"].waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch()
        defer { app.terminate() }
        openPhotos(app)
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        XCTAssertFalse(element("mobile.photos.sharing.sendLink", in: app).exists)
        XCTAssertFalse(element("mobile.photos.temporary.resume", in: app).exists)
        attachScreenshot(app, name: "Temporary sharing creation restored without replay")
    }

    func test临时分享中文设置可取消且保留原件() {
        let app = launchFixture(state: "photo-temporary", language: "zh-Hans")
        defer { app.terminate() }
        openTemporarySelection(app, chinese: true)
        let name = app.textFields["mobile.photos.temporary.name"]
        name.tap(); name.typeText("Chinese selection"); app.buttons["mobile.photos.temporary.create"].tap()
        XCTAssertTrue(app.navigationBars["管理分享"].waitForExistence(timeout: 8))
        XCTAssertTrue(element("mobile.photos.sharing.access", in: app).waitForExistence(timeout: 5))
        attachScreenshot(app, name: "临时分享中文设置")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["已停止分享，原照片已保留。"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Sample 1.jpg"].exists); XCTAssertTrue(app.buttons["Sample 2.jpg"].exists)
    }

    private func openTemporarySelection(_ app: XCUIApplication, chinese: Bool = false) {
        openPhotos(app, chinese: chinese); selectPhotoItems(app)
        element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.temporary.begin", in: app).tap()
        XCTAssertTrue(app.textFields["mobile.photos.temporary.name"].waitForExistence(timeout: 5))
    }

    func test相册分享公开下载和移除密码说明后果再保存() {
        let app = launchFixture(state: "photo-sharing")
        defer { app.terminate() }
        openAlbumSharing(app)
        XCTAssertFalse(app.buttons["mobile.photos.sharing.save"].isEnabled)
        element("mobile.photos.sharing.access", in: app).tap(); app.buttons["Anyone with the link can view and download"].tap()
        element("mobile.photos.sharing.passwordChoice", in: app).tap(); app.buttons["Remove password protection"].tap()
        app.buttons["mobile.photos.sharing.save"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label == %@", "Anyone with this link will be able to view and download these photos.\n\nThe album’s sharing password will be removed. People with access will no longer need it.")).firstMatch.exists)
        attachScreenshot(app, name: "Album public access and password removal confirmation")
        app.alerts.buttons.matching(identifier: "mobile.photos.sharing.confirm").firstMatch.tap()
        XCTAssertTrue(element("mobile.photos.sharing.sendLink", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("mobile.photos.sharing.copyLink", in: app).exists)
    }

    func test相册分享选择具名成员并保存权限() {
        let app = launchFixture(state: "photo-sharing")
        defer { app.terminate() }
        openAlbumSharing(app)
        let choose = element("mobile.photos.sharing.members", in: app)
        for _ in 0..<3 where !choose.isHittable { app.swipeUp() }
        choose.tap()
        XCTAssertTrue(app.buttons["Sample member"].waitForExistence(timeout: 5)); app.buttons["Sample member"].tap()
        XCTAssertTrue(app.staticTexts["Sample member"].waitForExistence(timeout: 5))
        app.buttons["mobile.photos.sharing.save"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.buttons.matching(identifier: "mobile.photos.sharing.confirm").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Album named member changes saved")
    }

    func test相册分享未知跨重启只显示刷新而不重复保存() {
        let app = launchFixture(state: "photo-sharing-unknown")
        openAlbumSharing(app)
        element("mobile.photos.sharing.access", in: app).tap(); app.buttons["Anyone with the link can view"].tap()
        app.buttons["mobile.photos.sharing.save"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.buttons.matching(identifier: "mobile.photos.sharing.confirm").firstMatch.tap()
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch()
        defer { app.terminate() }
        openPhotos(app)
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        XCTAssertFalse(element("mobile.photos.sharing.sendLink", in: app).exists)
        attachScreenshot(app, name: "Pending album sharing restored")
    }

    func test相册分享部分完成明确保持关闭并可重新编辑() {
        let app = launchFixture(state: "photo-sharing-partial")
        defer { app.terminate() }
        openAlbumSharing(app)
        element("mobile.photos.sharing.access", in: app).tap(); app.buttons["Anyone with the link can view"].tap()
        app.buttons["mobile.photos.sharing.save"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.buttons.matching(identifier: "mobile.photos.sharing.confirm").firstMatch.tap()
        let message = app.staticTexts.matching(NSPredicate(format: "label == %@", "Some sharing settings could not be saved. Sharing remains off. Open sharing settings again to continue.")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 8))
        XCTAssertFalse(element("mobile.photos.sharing.sendLink", in: app).exists)
        attachScreenshot(app, name: "Sharing stays off after a partial update")
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.sharing.begin", in: app).tap()
        XCTAssertTrue(element("mobile.photos.sharing.access", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mobile.photos.sharing.save"].isEnabled)
    }

    func test相册分享中文加载失败和成员空内容可恢复() {
        for state in ["photo-sharing-loading", "photo-sharing-error", "photo-sharing-members-empty", "photo-sharing-members-error"] {
            let app = launchFixture(state: state, language: "zh-Hans")
            openAlbumSharing(app, chinese: true)
            if state == "photo-sharing-loading" {
                XCTAssertTrue(element("mobile.photos.sharing.loading", in: app).waitForExistence(timeout: 5))
            } else if state == "photo-sharing-error" {
                XCTAssertTrue(app.staticTexts["无法载入分享设置。请检查连接和相册权限，然后重试。"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["重试"].exists)
            } else {
                let choose = element("mobile.photos.sharing.members", in: app)
                for _ in 0..<3 where !choose.isHittable { app.swipeUp() }
                choose.tap()
                if state == "photo-sharing-members-empty" { XCTAssertTrue(app.staticTexts["没有可添加的用户或群组，可尝试其他搜索词。"].waitForExistence(timeout: 5)) }
                else { XCTAssertTrue(app.staticTexts["无法加载用户和群组，请检查连接后重试。"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["重试"].exists) }
            }
            attachScreenshot(app, name: state); app.terminate()
        }
    }

    private func openAlbumSharing(_ app: XCUIApplication, chinese: Bool = false) {
        openPhotos(app, chinese: chinese); openPhotoSection(chinese ? "相册" : "Albums", app: app)
        XCTAssertTrue(app.buttons["Sample album"].waitForExistence(timeout: 8)); app.buttons["Sample album"].tap()
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.sharing.begin", in: app).tap()
        XCTAssertTrue(app.navigationBars[chinese ? "管理分享" : "Manage sharing"].waitForExistence(timeout: 5))
    }

    func test仅有相册权限可以管理相册且不显示图库权限错误() {
        let app = launchFixture(state: "photo-albums-only")
        defer { app.terminate() }
        openPhotos(app); openPhotoSection("Albums", app: app)
        XCTAssertTrue(app.buttons["Sample album"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["You cannot access these photos. Ask your NAS administrator to check your photo permissions, then try again."].exists)
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.album.create", in: app).tap()
        let name = app.textFields["mobile.photos.album.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Album only")
        app.buttons["mobile.photos.album.submit"].tap()
        XCTAssertTrue(app.buttons["Album only"].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Albums remain available without a photo library")
    }

    func test照片多选创建相册并可改名() {
        let app = launchFixture(state: "photo-albums")
        defer { app.terminate() }
        openPhotos(app)
        selectPhotoItems(app)
        element("mobile.photos.selection.actions", in: app).tap()
        element("mobile.photos.selection.create", in: app).tap()
        let name = app.textFields["mobile.photos.album.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Created album")
        app.buttons["mobile.photos.album.submit"].tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        openPhotoSection("Albums", app: app)
        XCTAssertTrue(app.buttons["Created album"].waitForExistence(timeout: 8)); app.buttons["Created album"].tap()
        element("mobile.photos.actions", in: app).tap()
        element("mobile.photos.album.rename", in: app).tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Created album".count) + "Renamed album")
        app.buttons["mobile.photos.album.submit"].tap()
        XCTAssertTrue(app.navigationBars["Renamed album"].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Selected photos and renamed album")
    }

    func test照片从相册移除及删除相册都保留图库原件() {
        let app = launchFixture(state: "photo-albums")
        defer { app.terminate() }
        openPhotos(app); openPhotoSection("Albums", app: app)
        XCTAssertTrue(app.buttons["Sample album"].waitForExistence(timeout: 8)); app.buttons["Sample album"].tap()
        selectPhotoItems(app)
        element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.selection.remove", in: app).tap()
        XCTAssertTrue(app.staticTexts["Remove these photos from this album? The originals and other albums will stay unchanged."].waitForExistence(timeout: 5))
        app.buttons["mobile.photos.album.submit"].tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.album.delete", in: app).tap()
        XCTAssertTrue(app.staticTexts["Delete this album and its sharing link. Original photos will be kept."].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Album deletion keeps original photos")
        app.buttons["mobile.photos.album.submit"].tap()
        openPhotoSection("Timeline", app: app)
        XCTAssertTrue(app.buttons["Sample 1.jpg"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Sample 2.jpg"].exists)
    }

    func test相册成员部分失败可继续剩余照片() {
        let app = launchFixture(state: "photo-albums-partial")
        defer { app.terminate() }
        openPhotos(app); openPhotoSection("Albums", app: app)
        XCTAssertTrue(app.buttons["Sample album"].waitForExistence(timeout: 8)); app.buttons["Sample album"].tap()
        selectPhotoItems(app)
        element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.selection.remove", in: app).tap()
        app.buttons["mobile.photos.album.submit"].tap()
        XCTAssertTrue(element("mobile.photos.album.continue", in: app).waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Album remaining photos can continue")
        element("mobile.photos.album.continue", in: app).tap()
        XCTAssertTrue(app.staticTexts["Operation completed."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Sample 1.jpg"].exists); XCTAssertFalse(app.buttons["Sample 2.jpg"].exists)
    }

    func test相册创建未知跨重启仅显示刷新入口() {
        let app = launchFixture(state: "photo-albums-unknown")
        openPhotos(app)
        element("mobile.photos.actions", in: app).tap(); element("mobile.photos.album.create", in: app).tap()
        let name = app.textFields["mobile.photos.album.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Pending album")
        app.buttons["mobile.photos.album.submit"].tap()
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch()
        defer { app.terminate() }
        openPhotos(app)
        XCTAssertTrue(element("mobile.photos.album.refresh", in: app).waitForExistence(timeout: 8))
        element("mobile.photos.actions", in: app).tap()
        XCTAssertFalse(app.buttons["mobile.photos.album.create"].isEnabled)
        attachScreenshot(app, name: "Pending album restored without another create")
    }

    func test加入相册候选加载空内容和失败中文可恢复() {
        for state in ["photo-albums-loading", "photo-albums-empty", "photo-albums-error"] {
            let app = launchFixture(state: state, language: "zh-Hans")
            openPhotos(app, chinese: true); selectPhotoItems(app)
            element("mobile.photos.selection.actions", in: app).tap(); element("mobile.photos.selection.add", in: app).tap()
            XCTAssertTrue(app.navigationBars["加入相册"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["mobile.photos.album.submit"].isEnabled)
            if state == "photo-albums-loading" { XCTAssertTrue(element("mobile.photos.album.loading", in: app).waitForExistence(timeout: 5)) }
            else if state == "photo-albums-empty" {
                XCTAssertTrue(app.staticTexts["暂无可加入的相册。请先创建相册，再添加照片。"].waitForExistence(timeout: 5))
            } else { XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 5)) }
            attachScreenshot(app, name: state)
            app.terminate()
        }
    }

    private func selectPhotoItems(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Sample 1.jpg"].waitForExistence(timeout: 8))
        element("mobile.photos.selection.begin", in: app).tap()
        element("mobile.photos.selection.loaded", in: app).tap()
    }
    private func openPhotoSection(_ title: String, app: XCUIApplication) {
        if app.segmentedControls.buttons[title].exists { app.segmentedControls.buttons[title].tap() }
        else { element("mobile.photos.section", in: app).tap(); app.buttons[title].tap() }
    }

    func test照片选择上传显示逐项结果且可清理记录() {
        let app = launchFixture(state: "photo-upload")
        defer { app.terminate() }
        openPhotos(app)
        beginPhotoUpload(app)
        XCTAssertTrue(app.staticTexts["Sample image.jpg"].waitForExistence(timeout: 8))
        element("mobile.photos.upload.submit", in: app).tap()
        XCTAssertTrue(element("mobile.photos.upload.state.completed", in: app).waitForExistence(timeout: 10))
        attachScreenshot(app, name: "Photos upload completed")
        element("mobile.photos.upload.clear", in: app).tap()
        XCTAssertTrue(app.staticTexts["No upload tasks"].waitForExistence(timeout: 5))
    }

    func test照片相册加入失败可单独继续完成() {
        let app = launchFixture(state: "photo-album-failure")
        defer { app.terminate() }
        openPhotos(app)
        if app.segmentedControls.buttons["Albums"].exists { app.segmentedControls.buttons["Albums"].tap() }
        else { element("mobile.photos.section", in: app).tap(); app.buttons["Albums"].tap() }
        XCTAssertTrue(app.buttons["Sample album"].waitForExistence(timeout: 8)); app.buttons["Sample album"].tap()
        beginPhotoUpload(app)
        XCTAssertTrue(app.staticTexts["Sample image.jpg"].waitForExistence(timeout: 8))
        element("mobile.photos.upload.submit", in: app).tap()
        XCTAssertTrue(app.buttons["Retry adding to album"].waitForExistence(timeout: 10))
        attachScreenshot(app, name: "Photos album addition retry")
        app.buttons["Retry adding to album"].tap()
        XCTAssertTrue(element("mobile.photos.upload.state.completed", in: app).waitForExistence(timeout: 10))
    }

    func test照片上传未知重启保留原任务且不显示重传() {
        let app = launchFixture(state: "photo-unknown")
        openPhotos(app); beginPhotoUpload(app)
        XCTAssertTrue(app.staticTexts["Sample image.jpg"].waitForExistence(timeout: 8))
        element("mobile.photos.upload.submit", in: app).tap()
        XCTAssertTrue(element("mobile.photos.upload.state.pendingReview", in: app).waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments.append("--ui-preserve-transfer-fixture")
        app.launch()
        defer { app.terminate() }
        openPhotos(app)
        element("mobile.photos.actions", in: app).tap()
        element("mobile.photos.upload.queue", in: app).tap()
        XCTAssertTrue(element("mobile.photos.upload.state.pendingReview", in: app).waitForExistence(timeout: 8))
        XCTAssertFalse(element("mobile.photos.upload.retry", in: app).exists)
        XCTAssertFalse(element("mobile.photos.upload.clear", in: app).exists)
        XCTAssertTrue(element("mobile.photos.upload.refresh", in: app).isEnabled)
        attachScreenshot(app, name: "Photos pending upload restored")
    }

    func test照片上传中文表单与系统文件选择器() {
        let app = launchFixture(state: "photo-picker", language: "zh-Hans")
        defer { app.terminate() }
        openPhotos(app, chinese: true); beginPhotoUpload(app)
        XCTAssertTrue(app.buttons["选择照片和视频"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mobile.photos.upload.submit"].isEnabled)
        element("mobile.photos.upload.chooseFiles", in: app).tap()
        let picker = app.otherElements["Browse View (Picker)"]
        let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 8) || browse.exists)
        attachScreenshot(app, name: "Photos system file chooser Chinese")
    }

    private func openPhotos(_ app: XCUIApplication, chinese: Bool = false) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", title: chinese ? "App 设置" : "App settings", in: app)
        let toggle = element("mobile.settings.module.photos", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        toggle.switches.firstMatch.tap()
        navigate("photos", title: chinese ? "照片" : "Photos", in: app)
        XCTAssertTrue(element("mobile.photos.actions", in: app).waitForExistence(timeout: 8))
    }

    private func beginPhotoUpload(_ app: XCUIApplication) {
        element("mobile.photos.actions", in: app).tap()
        let begin = element("mobile.photos.upload.begin", in: app)
        XCTAssertTrue(begin.waitForExistence(timeout: 8)); XCTAssertTrue(begin.isEnabled); begin.tap()
    }

    func test默认仅文件与App设置并按当前账号筛选开关() {
        let app = launchFixture()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        assertOnlyDefaultNavigation(app)
        navigate("settings", title: "App settings", in: app)
        let downloads = element("mobile.settings.module.downloads", in: app)
        XCTAssertTrue(downloads.waitForExistence(timeout: 8))
        XCTAssertEqual(downloads.value as? String, "0")
        for name in ["photos", "chat", "containers", "virtualMachines", "nasSettings"] {
            XCTAssertFalse(element("mobile.settings.module.\(name)", in: app).exists)
        }
        downloads.switches.firstMatch.tap()
        navigate("downloads", title: "Downloads", in: app)
        XCTAssertTrue(app.staticTexts["Sample archive.zip"].waitForExistence(timeout: 8))
        navigate("settings", title: "App settings", in: app)
        downloads.switches.firstMatch.tap()
        assertOnlyDefaultNavigation(app)
        attachScreenshot(app, name: "Account features and two default destinations")
    }

    func test权限刷新撤销入口并且不能残留旧开关() {
        let app = launchFixture(state: "modules-revoke")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", title: "App settings", in: app)
        let downloads = element("mobile.settings.module.downloads", in: app)
        XCTAssertTrue(downloads.waitForExistence(timeout: 8)); downloads.switches.firstMatch.tap()
        navigate("downloads", title: "Downloads", in: app)
        XCTAssertTrue(app.staticTexts["Sample archive.zip"].waitForExistence(timeout: 8))
        navigate("settings", title: "App settings", in: app)
        XCTAssertTrue(element("mobile.settings.modules.empty", in: app).waitForExistence(timeout: 8))
        XCTAssertFalse(downloads.exists)
        assertOnlyDefaultNavigation(app)
        attachScreenshot(app, name: "Revoked module removed")
    }

    func test可开启模块加载空内容和失败具有实际呈现() {
        for state in ["modules-loading", "modules-none", "modules-failed"] {
            let app = launchFixture(state: state)
            XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
            navigate("settings", title: "App settings", in: app)
            if state == "modules-loading" {
                XCTAssertTrue(app.staticTexts["Loading available features…"].waitForExistence(timeout: 5))
                XCTAssertFalse(element("mobile.settings.modules.refresh", in: app).isEnabled)
            } else {
                let id = state == "modules-none" ? "empty" : "failed"
                XCTAssertTrue(element("mobile.settings.modules.\(id)", in: app).waitForExistence(timeout: 8))
                XCTAssertTrue(element("mobile.settings.modules.refresh", in: app).isEnabled)
            }
            assertOnlyDefaultNavigation(app)
            attachScreenshot(app, name: state)
            app.terminate()
        }
    }

    func test管理员六种模块均需开启且设置始终可达() {
        let app = launchFixture(state: "modules-all")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        assertOnlyDefaultNavigation(app)
        navigate("settings", title: "App settings", in: app)
        for name in ["photos", "chat", "downloads", "containers", "virtualMachines", "nasSettings"] {
            let toggle = element("mobile.settings.module.\(name)", in: app)
            XCTAssertTrue(toggle.waitForExistence(timeout: 8))
            if !toggle.isHittable { app.swipeUp() }
            XCTAssertEqual(toggle.value as? String, "0")
            toggle.switches.firstMatch.tap()
            XCTAssertEqual(toggle.value as? String, "1")
        }
        navigate("files", title: "File", in: app)
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", title: "App settings", in: app)
        XCTAssertTrue(element("mobile.settings.page", in: app).waitForExistence(timeout: 8))
        attachScreenshot(app, name: "All authorized features enabled")
    }

    private func assertOnlyDefaultNavigation(_ app: XCUIApplication) {
        if app.tabBars.firstMatch.exists {
            XCTAssertEqual(app.tabBars.buttons.count, 2)
            XCTAssertTrue(app.tabBars.buttons["File"].exists)
            XCTAssertTrue(app.tabBars.buttons["App settings"].exists)
        } else {
            XCTAssertTrue(element("mobile.navigation.files", in: app).exists)
            XCTAssertTrue(element("mobile.navigation.settings", in: app).exists)
            for name in ["photos", "chat", "downloads", "containers", "virtualMachines", "nasSettings"] {
                XCTAssertFalse(element("mobile.navigation.\(name)", in: app).exists)
            }
        }
    }

    func test文件活动可返回并直接切换App设置() {
        let app = launchFixture()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        element("mobile.module.transfers", in: app).tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 8))
        navigate("settings", title: "App settings", in: app)
        XCTAssertTrue(element("mobile.settings.page", in: app).waitForExistence(timeout: 8))
        navigate("files", title: "File", in: app)
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        element("mobile.module.transfers", in: app).tap()
        let back = app.navigationBars["Activity"].buttons["File"]
        XCTAssertTrue(back.waitForExistence(timeout: 8)); back.tap()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
    }

    func test中文模块设置可开启功能并保留原始文件名() {
        let app = launchFixture(language: "zh-Hans")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", title: "App 设置", in: app)
        XCTAssertTrue(app.staticTexts["可开启的功能"].waitForExistence(timeout: 8))
        let toggle = element("mobile.settings.module.downloads", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 8)); toggle.switches.firstMatch.tap()
        navigate("downloads", title: "下载管理", in: app)
        XCTAssertTrue(app.staticTexts["Sample archive.zip"].waitForExistence(timeout: 8))
        navigate("settings", title: "App 设置", in: app)
        XCTAssertEqual(toggle.value as? String, "1")
        attachScreenshot(app, name: "Chinese module settings")
    }

    func test文件下载和设置可通过原生导航到达() {
        let app = launchFixture()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", title: "App settings", in: app)
        XCTAssertTrue(element("mobile.settings.page", in: app).waitForExistence(timeout: 5))
        let toggle = element("mobile.settings.module.downloads", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.switches.firstMatch.tap()
        navigate("downloads", title: "Downloads", in: app)
        XCTAssertTrue(app.staticTexts["Sample archive.zip"].waitForExistence(timeout: 8))
        navigate("settings", title: "App settings", in: app)
        attachScreenshot(app, name: "Workspace settings")
    }

    func test文件页加载空内容和错误均有实际呈现() {
        for state in ["loading", "empty", "error"] {
            let app = launchFixture(state: state)
            XCTAssertTrue(element("mobile.page.\(state)", in: app).waitForExistence(timeout: 8), state)
            attachScreenshot(app, name: "Files — \(state)")
            app.terminate()
        }
    }

    func test文件搜索无结果保持筛选状态() {
        let app = launchFixture()
        defer { app.terminate() }
        assertFileSearch(app)
    }

    func test文件搜索中文深色大字号仍可输入与清除() {
        let app = launchFixture(language: "zh-Hans")
        app.terminate()
        app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); defer { app.terminate() }
        assertFileSearch(app)
    }

    private func assertFileSearch(_ app: XCUIApplication) {
        let folder = app.staticTexts["Sample folder"]
        XCTAssertTrue(folder.waitForExistence(timeout: 8))
        folder.tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 8))
        let inlineSearch = app.textFields["files.search.input"]
        let search = inlineSearch.exists ? inlineSearch : app.searchFields.firstMatch
        if !search.exists {
            // 窄屏的系统搜索可能先呈现按钮，点击后才创建输入框。
            let reveal = app.buttons.matching(NSPredicate(format: "label == 'Search' OR label == '搜索'")).firstMatch
            if !reveal.exists {
                let overflow = app.buttons["OverflowBarButtonItem"].firstMatch
                XCTAssertTrue(overflow.waitForExistence(timeout: 5)); overflow.tap()
            }
            XCTAssertTrue(reveal.waitForExistence(timeout: 5))
            reveal.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("missing-fixture\n")
        XCTAssertTrue(element("mobile.page.filteredEmpty", in: app).waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Files — no search results")
        if inlineSearch.exists {
            let clear = app.buttons["files.search.clear"]
            XCTAssertTrue(clear.isHittable); clear.tap()
            XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 8))
        }
    }

    func test目录上传在活动中显示逐项成功且重启保留() {
        let app = launchFixture(state: "upload")
        let start = element("mobile.upload.start", in: app)
        // 目录副本仍在准备时上传按钮尚不可操作，先等待实际文件清单。
        XCTAssertTrue(app.staticTexts["Sample upload/Sample upload.txt"].waitForExistence(timeout: 20))
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Sample upload/Sample upload.txt"].exists)
        XCTAssertTrue(start.isEnabled)
        start.tap()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("files", title: "File", in: app)
        let tasks = element("mobile.module.transfers", in: app)
        XCTAssertTrue(tasks.waitForExistence(timeout: 5))
        tasks.tap()
        XCTAssertTrue(app.staticTexts["Sample upload/Sample upload.txt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Clear Finished Uploads"].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Folder upload completed")
        app.terminate()
        app.launchArguments.append("--ui-preserve-transfer-fixture")
        app.launch()
        navigate("files", title: "File", in: app)
        let restoredTasks = element("mobile.module.transfers", in: app)
        XCTAssertTrue(restoredTasks.waitForExistence(timeout: 5))
        restoredTasks.tap()
        XCTAssertTrue(app.staticTexts["Sample upload/Sample upload.txt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Clear Finished Uploads"].exists)
        app.buttons["Clear Finished Uploads"].tap()
        XCTAssertFalse(app.staticTexts["Sample upload/Sample upload.txt"].exists)
        app.terminate()
    }

    func test高级搜索通过文件夹选择应用条件并显示部分正文提示() {
        let app = launchFixture(state: "advanced")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        let filters = app.buttons["Sort and filter"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        filters.tap()
        let advanced = element("files.search.advanced", in: app)
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.tap()
        let name = element("files.search.name", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        if app.buttons["Continue"].waitForExistence(timeout: 1) { app.buttons["Continue"].tap() }
        name.typeText("term")
        let contents = app.switches["Search file contents"]
        XCTAssertTrue(contents.exists)
        // 系统开关的可访问性元素包含整行；点击右侧开关本体，避免只结束输入焦点。
        contents.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(contents.value as? String, "1")
        element("files.search.addLocation", in: app).tap()
        let folder = element("files.folder-picker.folder./fixture", in: app)
        XCTAssertTrue(folder.waitForExistence(timeout: 8))
        folder.tap()
        let choose = app.buttons["Choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.tap()
        let apply = element("files.search.apply", in: app)
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(apply.isEnabled)
        attachScreenshot(app, name: "Advanced search conditions")
        apply.tap()
        XCTAssertTrue(app.staticTexts["Filtered result.txt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Search Filters Active"].exists)
        XCTAssertFalse(app.staticTexts["Storage Visible to This Account"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'not been indexed'")).firstMatch.exists)
        attachScreenshot(app, name: "Advanced search results")
    }

    func test原生压缩创建文件且活动保存完成结果() {
        let app = launchFixture(state: "archive")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        app.staticTexts["Sample folder"].tap()
        openItemActions("Sample archive.zip", in: app)
        app.buttons["Compress"].tap()
        XCTAssertTrue(element("files.archive.source./fixture/Sample archive.zip", in: app).waitForExistence(timeout: 5))
        let name = element("files.archive.name", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Created archive")
        attachScreenshot(app, name: "Compression form")
        element("files.archive.start-compression", in: app).tap()
        XCTAssertTrue(app.staticTexts["Created archive.zip"].waitForExistence(timeout: 8))
        navigate("files", title: "File", in: app)
        element("mobile.module.transfers", in: app).tap()
        XCTAssertTrue(element("files.archive.phase.completed", in: app).waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Archive completed in Transfers")
    }

    func test原生压缩包浏览及解压完成() {
        let app = launchFixture(state: "archive")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        app.staticTexts["Sample folder"].tap()
        openItemActions("Sample archive.zip", in: app)
        app.buttons["Extract"].tap()
        XCTAssertTrue(app.staticTexts["Extracted document.txt"].waitForExistence(timeout: 8))
        let start = element("files.archive.start-extraction", in: app)
        XCTAssertTrue(start.isEnabled)
        attachScreenshot(app, name: "Archive contents and extraction options")
        start.tap()
        XCTAssertTrue(app.staticTexts["Sample archive"].waitForExistence(timeout: 8))
        navigate("files", title: "File", in: app)
        element("mobile.module.transfers", in: app).tap()
        XCTAssertTrue(element("files.archive.phase.completed", in: app).waitForExistence(timeout: 8))
    }

    func testNAS原任务停止及移除记录需要确认并刷新() throws {
        let app = launchFixture(state: "archive")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("files", title: "File", in: app)
        element("mobile.module.transfers", in: app).tap()
        let stop = app.buttons["Stop this task"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8)); stop.tap()
        let confirmations = app.buttons.matching(identifier: "Stop this task")
        let confirmation = try XCTUnwrap(confirmations.allElementsBoundByIndex.first(where: { $0.isHittable }))
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.tap()
        let clear = app.buttons["Clear this record"]
        XCTAssertTrue(clear.waitForExistence(timeout: 8))
        attachScreenshot(app, name: "NAS task stopped")
        clear.tap()
        let clears = app.buttons.matching(identifier: "Clear this record")
        try XCTUnwrap(clears.allElementsBoundByIndex.first(where: { $0.isHittable })).tap()
        XCTAssertTrue(app.staticTexts["No transfer tasks yet"].waitForExistence(timeout: 8))
    }

    func test权限编辑保留继承规则并保存后重新读取() {
        let app = launchFixture(state: "permissions-acl")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        app.buttons["Actions for Inbox"].tap(); app.buttons["Owner and permissions"].tap()
        let rule = app.buttons["Sample member, Allow"]
        XCTAssertTrue(rule.waitForExistence(timeout: 8)); rule.tap()
        let write = app.switches["files.permissions.rule.0.write_data"]
        XCTAssertTrue(write.waitForExistence(timeout: 5))
        write.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        element("files.permissions.save", in: app).tap()
        XCTAssertTrue(app.staticTexts["These changes apply to this item and may change who can access it."].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Permission change confirmation")
        element("files.permissions.confirm", in: app).tap()
        XCTAssertTrue(app.staticTexts["Permissions saved."].waitForExistence(timeout: 8))
        XCTAssertEqual(write.value as? String, "1")
        attachScreenshot(app, name: "Explicit permissions saved")
    }

    func test基础权限修改需确认移除访问且准确回读() {
        let app = launchFixture(state: "permissions-posix")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        openItemActions("Sample document.txt", in: app); app.buttons["Owner and permissions"].tap()
        let write = app.switches["files.permissions.posix.0.2"]
        XCTAssertTrue(write.waitForExistence(timeout: 8))
        write.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        element("files.permissions.save", in: app).tap()
        XCTAssertTrue(app.staticTexts["Some accounts will lose part or all of their current access."].waitForExistence(timeout: 5))
        element("files.permissions.confirm", in: app).tap()
        XCTAssertTrue(app.staticTexts["Permissions saved."].waitForExistence(timeout: 8))
        XCTAssertEqual(write.value as? String, "0")
        attachScreenshot(app, name: "Basic permissions saved")
    }

    func test共享根权限只读且仍可展开继承规则() {
        let app = launchFixture(state: "permissions-acl")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        app.buttons["Actions for Sample folder"].tap(); app.buttons["Owner and permissions"].tap()
        XCTAssertTrue(app.staticTexts["Permissions are read-only here. Manage permissions for this location in DSM."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["files.permissions.save"].isEnabled)
        let rule = app.buttons["Sample member, Allow"]
        XCTAssertTrue(rule.exists); rule.tap()
        XCTAssertFalse(app.switches["files.permissions.rule.0.write_data"].isEnabled)
        app.staticTexts["Sample member"].firstMatch.tap()
        let inherited = element("files.permissions.inherited.0", in: app)
        for _ in 0..<3 where !inherited.isHittable { app.swipeUp() }
        XCTAssertTrue(inherited.isHittable); inherited.tap()
        let inheritedRead = app.staticTexts["Read files / list folders"]
        for _ in 0..<3 where !inheritedRead.isHittable { app.swipeUp() }
        XCTAssertTrue(inheritedRead.waitForExistence(timeout: 5))
        XCTAssertTrue(inheritedRead.isHittable)
        attachScreenshot(app, name: "Shared root permissions remain read-only")
    }

    func test文件多选可批量创建并保留逐项链接() {
        let app = launchFixture(state: "sharing")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 5))
        openFileActions(app)
        attachScreenshot(app, name: "Batch selection toolbar")
        app.buttons["Select Items"].tap()
        app.staticTexts["Sample document.txt"].tap(); app.staticTexts["Inbox"].tap()
        let more = element("files.batch.more", in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        app.buttons["Create sharing link"].tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].exists); XCTAssertTrue(app.staticTexts["Inbox"].exists)
        let submit = element("sharing.create.submit", in: app)
        for _ in 0..<3 where !submit.isHittable { app.swipeUp() }
        XCTAssertTrue(submit.isHittable); submit.tap()
        XCTAssertTrue(element("sharing.results", in: app).waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Completed").count, 2)
        XCTAssertTrue(app.buttons["Copy selected links"].exists)
        attachScreenshot(app, name: "Batch sharing links created")
    }

    func test分享创建文件收集后可展示二维码和返回管理() {
        let app = launchFixture(state: "sharing")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        app.staticTexts["Sample folder"].tap()
        let actions = app.buttons["Actions for Inbox"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap()
        app.buttons["Create sharing link"].tap()
        let collection = app.switches["Create a file request link"]
        XCTAssertTrue(collection.waitForExistence(timeout: 5))
        collection.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let name = app.textFields["Collection name"]
        XCTAssertTrue(name.exists); name.tap(); name.typeText("Sample collection")
        let submit = element("sharing.create.submit", in: app)
        for _ in 0..<4 where !submit.isHittable { app.swipeUp() }
        XCTAssertTrue(submit.isHittable); submit.tap()
        let confirm = app.alerts.buttons["Create link"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.staticTexts["Link ready"].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "File collection link ready")
        app.buttons["Show QR code"].tap()
        XCTAssertTrue(app.images["Show QR code"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Local sharing QR code")
    }

    func test全部分享链接编辑密码并撤销原链接() {
        let app = launchFixture(state: "sharing")
        defer { app.terminate() }
        openAllSharing(app)
        let actions = element("sharing.row.more.fixture-existing", in: app)
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap()
        app.buttons["Edit shared links"].tap()
        let mode = element("sharing.edit.passwordMode", in: app)
        XCTAssertTrue(mode.waitForExistence(timeout: 5)); mode.tap()
        app.buttons["Set a new password"].tap()
        let password = element("sharing.edit.password", in: app)
        XCTAssertTrue(password.waitForExistence(timeout: 5)); password.tap(); password.typeText("synthetic-only")
        element("sharing.edit.save", in: app).tap()
        XCTAssertTrue(element("sharing.results", in: app).waitForExistence(timeout: 8))
        let result = element("sharing.results", in: app).cells.containing(.staticText, identifier: "Sample document.txt").firstMatch
        XCTAssertTrue(result.staticTexts["Completed"].exists)
        attachScreenshot(app, name: "Sharing password updated")
        app.buttons["Back to links"].tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap()
        app.buttons["Cancel sharing"].tap()
        let confirm = app.buttons["Cancel sharing"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.buttons["Back to links"].waitForExistence(timeout: 8)); app.buttons["Back to links"].tap()
        XCTAssertFalse(actions.exists)
        XCTAssertTrue(element("sharing.row.more.fixture-folder", in: app).exists)
        attachScreenshot(app, name: "Sharing original link removed")
    }

    func test分享访问次数可编辑并保留原链接() {
        let app = launchFixture(state: "sharing")
        defer { app.terminate() }
        openAllSharing(app)
        let actions = element("sharing.row.more.fixture-existing", in: app)
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap()
        app.buttons["Access and collection settings"].tap()
        let audience = element("sharing.access.audience", in: app)
        XCTAssertTrue(audience.waitForExistence(timeout: 5)); audience.tap()
        app.buttons["Selected users and groups"].tap()
        app.buttons["Choose users and groups"].tap()
        XCTAssertTrue(app.buttons["Sample member"].waitForExistence(timeout: 5)); app.buttons["Sample member"].tap()
        app.buttons["Done"].tap()
        let limit = app.switches["Change access limit"]
        XCTAssertTrue(limit.waitForExistence(timeout: 5)); limit.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let count = app.textFields["Access count"]
        XCTAssertTrue(count.exists); count.tap(); count.typeText(XCUIKeyboardKey.delete.rawValue + "5")
        element("sharing.access.save", in: app).tap()
        XCTAssertTrue(app.alerts.buttons["Save changes"].waitForExistence(timeout: 5)); app.alerts.buttons["Save changes"].tap()
        XCTAssertTrue(element("sharing.results", in: app).waitForExistence(timeout: 8))
        let result = element("sharing.results", in: app).cells.containing(.staticText, identifier: "Sample document.txt").firstMatch
        XCTAssertTrue(result.staticTexts["Completed"].exists)
        app.buttons["Back to links"].tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap(); app.buttons["Access and collection settings"].tap()
        XCTAssertTrue(limit.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Sharing access limit saved")
        limit.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(count.value as? String, "5")
    }

    func test远程位置可浏览原始目录并显示筛选为空() throws {
        let app = launchFixture(state: "remote")
        defer { app.terminate() }
        openRemoteLocations(app)
        app.buttons["files.remote.profile.fixture-remote"].tap()
        XCTAssertTrue(app.staticTexts["Remote sample.txt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Download"].exists)
        attachScreenshot(app, name: "Remote directory and download")
        let search = app.searchFields["Filter files in this folder"]
        if !search.exists {
            let reveal = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label == 'Search' OR label == '搜索'"))
                .allElementsBoundByIndex.first(where: { $0.isHittable }))
            reveal.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("missing-file\n")
        XCTAssertTrue(app.staticTexts["No files to show"].waitForExistence(timeout: 5))
    }

    func test远程服务器完整地址创建断开再移除配置() {
        let app = launchFixture(state: "remote")
        defer { app.terminate() }
        openRemoteLocations(app)
        app.buttons["files.remote.add"].tap(); app.buttons["FTP, WebDAV and cloud connections"].tap()
        let alias = app.textFields["files.remote.vfs.alias"]
        XCTAssertTrue(alias.waitForExistence(timeout: 5)); alias.tap(); alias.typeText("New remote")
        let address = app.textFields["files.remote.vfs.hostname"]
        address.tap(); address.typeText("https://new.example.invalid:8443/webdav")
        attachScreenshot(app, name: "Remote server form")
        app.buttons["files.remote.vfs.save"].tap()
        let profile = app.buttons["files.remote.profile.fixture-created"]
        XCTAssertTrue(profile.waitForExistence(timeout: 8))
        app.buttons["files.remote.actions.fixture-created"].tap(); app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.alerts.staticTexts["You will need to reconnect to browse files. No files will be deleted."].exists)
        app.alerts.buttons["Disconnect"].tap()
        XCTAssertTrue(app.staticTexts["Disconnected"].waitForExistence(timeout: 8))
        app.buttons["files.remote.actions.fixture-created"].tap(); app.buttons["Remove connection"].tap()
        app.alerts.buttons["Remove connection"].tap()
        XCTAssertTrue(app.staticTexts["The connection change is complete."].waitForExistence(timeout: 8))
        XCTAssertFalse(profile.exists)
        attachScreenshot(app, name: "Saved remote connection removed")
    }

    func testSMB连接使用目录选择并断开后恢复普通目录() {
        let app = launchFixture(state: "remote")
        defer { app.terminate() }
        openRemoteLocations(app)
        app.buttons["files.remote.add"].tap(); app.buttons["SMB / NFS shared folder"].tap()
        let server = app.textFields["files.remote.mount.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 5)); server.tap(); server.typeText("remote.example.invalid")
        let folder = app.textFields["files.remote.mount.folder"]
        folder.tap(); folder.typeText("Media")
        element("files.remote.mount.destination", in: app).tap()
        chooseRemoteDestination(app)
        app.buttons["files.remote.mount.save"].tap()
        XCTAssertTrue(app.staticTexts["//remote.example.invalid/Media"].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "SMB connection created")
        app.buttons["files.remote.mount-actions./fixture/Inbox"].tap(); app.buttons["Disconnect"].tap()
        app.alerts.buttons["Disconnect"].tap()
        XCTAssertTrue(app.staticTexts["The connection change is complete."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["files.remote.mount-actions./fixture/Inbox"].exists)
    }

    func testISO选择空目录加载并可卸载() {
        let app = launchFixture(state: "remote")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        openItemActions("Sample image.iso", in: app); app.buttons["Mount ISO"].tap()
        let destination = app.buttons["files.remote.iso.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5)); destination.tap()
        chooseRemoteDestination(app)
        app.buttons["files.remote.iso.save"].tap()
        XCTAssertTrue(app.staticTexts["Sample image.iso"].waitForExistence(timeout: 8))
        openFileActions(app); app.buttons["files.remote.manage"].tap()
        let unmount = app.buttons["Unmount ISO"]
        XCTAssertTrue(unmount.waitForExistence(timeout: 8)); unmount.tap()
        attachScreenshot(app, name: "ISO unmount consequence")
        app.buttons["files.remote.iso.save"].tap()
        XCTAssertTrue(app.staticTexts["The connection change is complete."].waitForExistence(timeout: 8))
        XCTAssertFalse(unmount.exists)
    }

    func test云授权使用系统浏览器且取消后返回原表单() throws {
        let app = launchFixture(state: "remote")
        defer { app.terminate() }
        openRemoteLocations(app)
        app.buttons["files.remote.add"].tap(); app.buttons["FTP, WebDAV and cloud connections"].tap()
        let type = element("files.remote.vfs.protocol", in: app)
        XCTAssertTrue(type.waitForExistence(timeout: 5)); type.tap(); app.buttons["Google Drive"].tap()
        app.buttons["Authorize cloud account"].tap()
        XCTAssertTrue(app.staticTexts["Sign in and authorize access on the cloud service page, then return here to save the connection."].waitForExistence(timeout: 5))
        // 仅打开官方公开授权起始页；不选择账号、不填写凭据、不授权或创建云连接。
        app.buttons["files.remote.cloud.start"].tap()
        XCTAssertTrue(app.buttons["URL"].waitForExistence(timeout: 8))
        let systemBrowser = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'BrowserView?'")).firstMatch
        let done = systemBrowser.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成", "Close", "关闭"])).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        attachScreenshot(app, name: "System browser cloud sign-in")
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["The sign-in page was closed before authorization completed. Close this window and try again."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["files.remote.cloud.start"].isEnabled)
        XCTAssertFalse(app.buttons["files.remote.cloud.save"].exists)
    }

    func test文件夹收藏可进入并从位置列表移除() {
        let app = launchFixture(state: "favorites")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        app.buttons["Actions for Sample folder"].tap(); app.buttons["add to favorites"].tap()
        XCTAssertTrue(app.staticTexts["Added to favorites."].waitForExistence(timeout: 8))
        app.buttons["Show locations"].tap()
        let row = app.buttons["files.favorite./fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 8))
        app.buttons["Show locations"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.press(forDuration: 1)
        app.buttons["Remove from favorites"].tap()
        XCTAssertTrue(app.staticTexts["Removed from favorites."].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Favorite removed from locations")
        XCTAssertFalse(row.exists)
    }

    func test文件收藏打开现有预览且不作为文件夹导航() {
        let app = launchFixture(state: "favorites")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        openItemActions("Sample document.txt", in: app); app.buttons["add to favorites"].tap()
        XCTAssertTrue(app.staticTexts["Added to favorites."].waitForExistence(timeout: 8))
        app.buttons["Show locations"].tap()
        let row = app.buttons["files.favorite./fixture/Sample document.txt"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["No text content"].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Favorite file uses preview")
        XCTAssertFalse(app.alerts.staticTexts["Could not open location"].exists)
    }

    func test文件设置普通保存后可以继续修改并回读() {
        let app = launchFixture(state: "file-settings")
        defer { app.terminate() }
        openFileSettings(app); app.buttons["General"].tap()
        let toggle = app.switches["Record file transfers"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8)); XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let save = app.buttons["files.settings.save"]
        reveal(save, in: app); XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["Settings saved."].waitForExistence(timeout: 8)); XCTAssertFalse(save.isEnabled)
        app.swipeDown(); app.swipeDown()
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        reveal(save, in: app); XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["Settings saved."].waitForExistence(timeout: 8)); XCTAssertFalse(save.isEnabled)
        attachScreenshot(app, name: "File settings saved twice")
    }

    func test文件设置扩大账号权限显示后果且取消不会保存() {
        let app = launchFixture(state: "file-settings")
        defer { app.terminate() }
        openFileSettings(app); app.buttons["Remote access"].tap()
        app.buttons["Manage account permissions"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample member'")).firstMatch.waitForExistence(timeout: 8))
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample member'")).firstMatch.tap()
        let toggle = app.switches["Allow remote connections"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        app.buttons["files.settings.save"].tap()
        XCTAssertTrue(app.staticTexts["More accounts will be able to use remote connections."].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["files.settings.save"].isEnabled)
        app.buttons["files.settings.save"].tap()
        // 系统将同一警告按钮暴露为外层和 SwiftUI 子元素，限定警告作用域。
        app.alerts.buttons["files.settings.confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample member' AND label CONTAINS 'Access allowed'")).firstMatch.waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Remote access saved with explicit consequence")
    }

    func test限速保留群组继承并可用触控编辑每周时间表() {
        let app = launchFixture(state: "file-settings")
        defer { app.terminate() }
        openFileSettings(app); app.buttons["Speed limits"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample member'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); XCTAssertTrue(row.label.contains("Use group limits")); row.tap()
        XCTAssertFalse(app.buttons["files.settings.save"].isEnabled)
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'When to apply speed limits'")).firstMatch.tap()
        app.buttons["Follow a schedule"].tap()
        app.buttons["Follow a schedule"].tap()
        let hour = app.buttons["files.settings.hour.0"]
        XCTAssertTrue(hour.waitForExistence(timeout: 5)); XCTAssertTrue(hour.label.contains("Default limit"))
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Apply to selected hours'")).firstMatch.tap()
        app.buttons["Custom limit"].tap(); hour.tap()
        XCTAssertTrue(hour.label.contains("Custom limit"))
        attachScreenshot(app, name: "Accessible hourly bandwidth schedule")
        app.navigationBars["Follow a schedule"].buttons["BackButton"].tap()
        reveal(app.buttons["files.settings.save"], in: app); app.buttons["files.settings.save"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 8)); XCTAssertTrue(row.label.contains("Follow a schedule"))
    }

    func test分享页面选择内置背景后保存并保留外观() {
        let app = launchFixture(state: "file-settings")
        defer { app.terminate() }
        openFileSettings(app); app.buttons["Sharing page"].tap()
        XCTAssertTrue(app.buttons["Choose background"].waitForExistence(timeout: 8)); app.buttons["Choose background"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Image source'")).firstMatch.tap()
        app.buttons["Built-in backgrounds"].tap()
        app.buttons["Background 1"].tap()
        let choose = app.buttons["Use this image"]
        reveal(choose, in: app); XCTAssertTrue(choose.isEnabled); choose.tap()
        XCTAssertEqual(app.switches["Use a custom background"].value as? String, "1")
        let save = app.buttons["files.settings.save"]; reveal(save, in: app); XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["Settings saved."].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Sharing page background applied")
    }

    func test文件设置读取错误和普通账号只读有实际呈现() {
        for state in ["file-settings-error", "file-settings-readonly", "file-settings-loading"] {
            let app = launchFixture(state: state)
            openFileSettings(app); app.buttons["General"].tap()
            if state.hasSuffix("loading") {
                XCTAssertTrue(element("files.settings.loading", in: app).waitForExistence(timeout: 8))
            } else if state.hasSuffix("error") {
                XCTAssertTrue(app.staticTexts["Could not load these settings"].waitForExistence(timeout: 8)); XCTAssertTrue(app.buttons["Retry"].exists)
            } else {
                let toggle = app.switches["Record file transfers"]
                XCTAssertTrue(toggle.waitForExistence(timeout: 8)); XCTAssertFalse(toggle.isEnabled)
                reveal(app.buttons["files.settings.save"], in: app); XCTAssertFalse(app.buttons["files.settings.save"].isEnabled)
            }
            attachScreenshot(app, name: state); app.terminate()
        }
    }

    func test限速名单空内容和搜索无结果提供恢复路径() {
        let app = launchFixture(state: "file-settings")
        defer { app.terminate() }
        openFileSettings(app); app.buttons["Speed limits"].tap()
        let type = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Account type'")).firstMatch
        XCTAssertTrue(type.waitForExistence(timeout: 8)); type.tap(); app.buttons["Local groups"].tap()
        XCTAssertTrue(app.staticTexts["No accounts were returned for this type. Choose another account type or refresh."].waitForExistence(timeout: 5))
        type.tap(); app.buttons["Local accounts"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample member'")).firstMatch.waitForExistence(timeout: 5))
        let search = app.searchFields["Search accounts"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("missing-fixture")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample member'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Try another search or ask an administrator to check your access to the account list."].exists)
        attachScreenshot(app, name: "Bandwidth list filtered empty")
    }

    private func openItemActions(_ name: String, in app: XCUIApplication) {
        let actions = app.buttons["Actions for " + name]
        XCTAssertTrue(actions.waitForExistence(timeout: 8))
        let search = app.textFields["files.search.input"]
        if search.exists {
            XCTAssertGreaterThanOrEqual(actions.frame.minY, search.frame.maxY,
                "搜索栏不能覆盖第一行文件及其操作按钮")
        }
        actions.tap()
    }

    private func openFileActions(_ app: XCUIApplication) {
        let direct = element("files.toolbar.more", in: app)
        if direct.exists && direct.isHittable { direct.tap(); return }
        let overflow = app.buttons["OverflowBarButtonItem"].firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 5)); overflow.tap()
        // 原生溢出菜单保留动作标题，不保留原 ToolbarItem 的标识。
        let more = app.buttons.matching(NSPredicate(format: "label IN %@", ["More", "更多"])).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
    }

    private func openFileSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        openFileActions(app); app.buttons["files.settings.open"].tap()
        XCTAssertTrue(app.buttons["General"].waitForExistence(timeout: 5))
    }
    private func revealInForm(_ item: XCUIElement, in app: XCUIApplication) {
        let form = app.collectionViews.containing(.any, identifier: item.identifier).firstMatch
        guard form.waitForExistence(timeout: 5) else { XCTFail("找不到包含该控件的表单"); return }
        for _ in 0..<10 {
            let viewport = form.frame.intersection(app.frame).insetBy(dx: 12, dy: 16)
            if item.exists && item.isHittable && viewport.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) { return }
            form.swipeUp()
        }
        XCTFail("表单控件没有滚动到可见区域")
    }

    private func reveal(_ item: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<7 { if item.exists && item.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(item.exists && item.isHittable)
    }

    private func openRemoteLocations(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        openFileActions(app); app.buttons["files.remote.manage"].tap()
        XCTAssertTrue(app.buttons["files.remote.profile.fixture-remote"].waitForExistence(timeout: 8))
    }
    private func chooseRemoteDestination(_ app: XCUIApplication) {
        let share = element("files.folder-picker.folder./fixture", in: app)
        XCTAssertTrue(share.waitForExistence(timeout: 5)); share.tap()
        let folder = element("files.folder-picker.folder./fixture/Inbox", in: app)
        XCTAssertTrue(folder.waitForExistence(timeout: 5)); folder.tap()
        app.buttons["Choose"].tap()
    }

    private func openAllSharing(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        openFileActions(app)
        element("files.sharing.all", in: app).tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 8))
    }

    func test批量复制文件和文件夹逐项成功且源内容保留() {
        let app = launchFixture(state: "copy-move")
        defer { app.terminate() }
        beginCopyMoveBatch(app, move: false)
        XCTAssertTrue(app.staticTexts["Batch complete"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Completed: 2 · Failed: 0 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].exists)
        XCTAssertTrue(app.staticTexts["Sample document.txt"].exists); XCTAssertTrue(app.staticTexts["Inbox"].exists)
        attachScreenshot(app, name: "Mixed file and folder copy results")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Inbox"].exists)
    }

    func test批量移动文件和文件夹后源列表为空() {
        let app = launchFixture(state: "copy-move")
        defer { app.terminate() }
        beginCopyMoveBatch(app, move: true)
        XCTAssertTrue(app.staticTexts["Completed: 2 · Failed: 0 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].waitForExistence(timeout: 10))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["This position is empty"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Move refreshes the source folder")
    }

    func test批量同名冲突保留失败原因并继续其他文件夹() {
        let app = launchFixture(state: "copy-conflict")
        defer { app.terminate() }
        beginCopyMoveBatch(app, move: false)
        XCTAssertTrue(app.staticTexts["Completed: 1 · Failed: 1 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sample document.txt, An item with this name already exists"].exists)
        XCTAssertTrue(app.staticTexts["Inbox, Completed"].exists)
        attachScreenshot(app, name: "Partial copy keeps per-item outcomes")
    }

    func test批量未知结果保留未开始项且重启不重放() {
        let app = launchFixture(state: "copy-unknown")
        defer { app.terminate() }
        beginCopyMoveBatch(app, move: false)
        XCTAssertTrue(app.staticTexts["Completed: 0 · Failed: 0 · Result unavailable: 1 · Cancelled: 0 · Not started: 1"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Sample document.txt, Not started"].exists)
        attachScreenshot(app, name: "Unknown copy stops remaining items")
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch()
        beginCopyMoveBatch(app, move: false)
        XCTAssertTrue(app.staticTexts["Result unavailable"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(element("files.copy-move.submit", in: app).exists)
    }

    func test批量复制无写入权限显示逐项失败与恢复说明() {
        let app = launchFixture(state: "copy-readonly")
        defer { app.terminate() }
        beginCopyMoveBatch(app, move: false)
        XCTAssertTrue(app.staticTexts["Completed: 0 · Failed: 2 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Inbox, No permission"].exists)
        XCTAssertTrue(app.staticTexts["Sample document.txt, No permission"].exists)
        XCTAssertTrue(app.staticTexts["You don’t have permission to use this destination. Choose another folder or ask an administrator for access."].exists)
        attachScreenshot(app, name: "Copy respects actual destination permissions")
    }

    func test文件夹下载ZIP后打开系统保存面板() {
        let app = launchFixture(state: "download-archive"); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        openItemActions("Inbox", in: app)
        element("files.item.download-archive", in: app).tap()
        XCTAssertTrue(element("mobile.documents.export-panel", in: app).waitForExistence(timeout: 10))
        let save = app.buttons.matching(NSPredicate(format: "label == 'Save' OR label == '保存'")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        attachScreenshot(app, name: "Folder ZIP system export")
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
        if !cancel.exists {
            let back = app.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        }
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(app.staticTexts["Inbox"].waitForExistence(timeout: 5))
    }

    func test只读文件夹和多文件可打包并交给系统分享() {
        let app = launchFixture(state: "download-readonly"); defer { app.terminate() }
        beginDownloadSelection(app, singleFile: false)
        element("files.batch.more", in: app).tap()
        let share = element("files.batch.share", in: app)
        XCTAssertTrue(share.isEnabled); share.tap()
        XCTAssertTrue(element("ActivityListView", in: app).waitForExistence(timeout: 10))
        let title = element("LP.CaptionBar.TopCaption", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 10)); XCTAssertEqual(title.label, "2 items")
        XCTAssertTrue(element("LP.CaptionBar.BottomCaption", in: app).label.contains("ZIP"))
        attachScreenshot(app, name: "Read-only mixed selection ZIP share")
        app.buttons["header.closeButton"].tap()
        let panel = element("ActivityListView", in: app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: panel)], timeout: 5), .completed)
    }

    func test多选仅一个文件保持原格式且下载失败能从活动重试() {
        let app = launchFixture(state: "download-failure"); defer { app.terminate() }
        beginDownloadSelection(app, singleFile: true)
        element("files.batch.more", in: app).tap(); element("files.batch.download", in: app).tap()
        // 错误文案及重试入口由现有前台下载流程提供。
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        attachScreenshot(app, name: "Download failure recovery")
        app.alerts.buttons.firstMatch.tap()
        navigate("files", title: "File", in: app)
        element("mobile.module.transfers", in: app).tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Start Over"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["1 items.zip"].exists)
    }

    private func beginDownloadSelection(_ app: XCUIApplication, singleFile: Bool) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 5))
        openFileActions(app); app.buttons["Select Items"].tap()
        app.staticTexts["Sample document.txt"].tap()
        if !singleFile { app.staticTexts["Inbox"].tap() }
    }

    func test批量删除文件和文件夹明确后果且刷新源列表() {
        let app = launchFixture(state: "recycle-delete"); defer { app.terminate() }
        beginRecycleBatch(app, restore: false)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "The selected items and folder contents will be deleted. Depending on the NAS recycle bin settings, they may be permanently deleted.")).firstMatch.exists)
        element("files.recycle.submit", in: app).tap()
        XCTAssertTrue(app.staticTexts["Completed: 2 · Failed: 0 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Inbox, Completed"].exists)
        attachScreenshot(app, name: "Delete per-item results")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["This position is empty"].waitForExistence(timeout: 5))
    }

    func test批量永久删除回收站项目明确无法恢复() {
        let app = launchFixture(state: "recycle-permanent"); defer { app.terminate() }
        beginRecycleBatch(app, restore: false, recycle: true)
        XCTAssertTrue(app.staticTexts["These items are in the recycle bin. Deleting them also deletes all folder contents and cannot be undone."].exists)
        attachScreenshot(app, name: "Permanent deletion consequence")
        element("files.recycle.submit", in: app).tap()
        XCTAssertTrue(app.staticTexts["Completed: 2 · Failed: 0 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].waitForExistence(timeout: 10))
    }

    func test批量恢复文件夹和文件返回原位置并保留同名冲突() {
        let app = launchFixture(state: "recycle-restore-conflict"); defer { app.terminate() }
        beginRecycleBatch(app, restore: true, recycle: true)
        element("files.recycle.submit", in: app).tap()
        XCTAssertTrue(app.staticTexts["Completed: 1 · Failed: 1 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Inbox, Completed"].exists)
        XCTAssertTrue(app.staticTexts["Sample document.txt, The item or destination changed"].exists)
        attachScreenshot(app, name: "Restore keeps existing destination")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Inbox"].exists)
    }

    func test批量删除无权限零写并提供恢复方法() {
        let app = launchFixture(state: "recycle-readonly"); defer { app.terminate() }
        beginRecycleBatch(app, restore: false); element("files.recycle.submit", in: app).tap()
        XCTAssertTrue(app.staticTexts["Completed: 0 · Failed: 2 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Inbox, You don’t have permission"].exists)
        XCTAssertTrue(app.staticTexts["Your account can’t change this item. Ask an administrator for access, then refresh the folder."].exists)
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sample document.txt"].exists)
    }

    func test批量删除未知停止余项且重启不重放() {
        let app = launchFixture(state: "recycle-unknown"); defer { app.terminate() }
        beginRecycleBatch(app, restore: false); element("files.recycle.submit", in: app).tap()
        let summary = "Completed: 0 · Failed: 0 · Result unavailable: 1 · Cancelled: 0 · Not started: 1"
        XCTAssertTrue(app.staticTexts[summary].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sample document.txt, Not started"].exists)
        attachScreenshot(app, name: "Unknown deletion stops remaining items")
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch()
        beginRecycleBatch(app, restore: false); element("files.recycle.submit", in: app).tap()
        XCTAssertTrue(app.staticTexts[summary].waitForExistence(timeout: 6))
        XCTAssertFalse(element("files.recycle.submit", in: app).exists)
    }

    func test跨NAS混合复制与移动删源分开确认() {
        let app = launchFixture(state: "cross-copy"); defer { app.terminate() }
        beginCrossNAS(app, move: true)
        let start = app.buttons["files.cross.start"]
        XCTAssertTrue(start.isEnabled); start.tap()
        openTransfers(app)
        XCTAssertTrue(app.staticTexts["Copy Complete"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Sample NAS → Destination NAS"].exists)
        attachScreenshot(app, name: "Cross NAS verified copy before removal")
        let remove = app.buttons["files.cross.remove"]
        XCTAssertTrue(remove.exists); remove.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Remove the copied originals from “Sample NAS” and keep the copies on “Destination NAS”. Removal may be permanent. Do not edit these files at the same time.")).firstMatch.waitForExistence(timeout: 5))
        let confirmations = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Remove Originals", "files.cross.remove"))
        XCTAssertEqual(confirmations.count, 1)
        confirmations.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Move Complete"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["files.cross.remove"].exists)
        attachScreenshot(app, name: "Cross NAS move completed")
        navigate("files", title: "File", in: app)
        XCTAssertTrue(app.staticTexts["This position is empty"].waitForExistence(timeout: 8))
    }

    func test跨NAS断线刷新后继续未开始项目() {
        let app = launchFixture(state: "cross-unknown"); defer { app.terminate() }
        beginCrossNAS(app, move: false); app.buttons["files.cross.start"].tap()
        openTransfers(app)
        XCTAssertTrue(app.staticTexts["Transfer Interrupted"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["files.cross.resume"].exists)
        XCTAssertFalse(app.buttons["files.cross.remove"].exists)
        app.buttons["files.cross.refresh"].tap()
        let resume = app.buttons["files.cross.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 8)); resume.tap()
        XCTAssertTrue(app.staticTexts["Copy Complete"].waitForExistence(timeout: 12))
        attachScreenshot(app, name: "Cross NAS recovered without duplicate upload")
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch()
        openTransfers(app)
        XCTAssertTrue(app.staticTexts["Copy Complete"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["files.cross.remove"].exists)
    }

    func test跨NAS重名和只读目标保留来源并给出恢复方法() {
        for state in ["cross-conflict", "cross-readonly"] {
            let app = launchFixture(state: state)
            beginCrossNAS(app, move: false); app.buttons["files.cross.start"].tap()
            let error = element("files.cross.error", in: app)
            XCTAssertTrue(error.waitForExistence(timeout: 8))
            XCTAssertTrue(error.label.contains(state == "cross-conflict" ? "same name" : "permissions"))
            XCTAssertTrue(app.buttons["files.cross.start"].isEnabled)
            attachScreenshot(app, name: state)
            app.terminate()
        }
    }

    private func beginCrossNAS(_ app: XCUIApplication, move: Bool) {
        beginDownloadSelection(app, singleFile: false)
        app.buttons["files.batch.more"].tap(); element("files.batch.cross-nas", in: app).tap()
        let destination = app.buttons["files.cross.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 8)); destination.tap()
        let folder = app.buttons["files.folder-picker.folder./output"]
        XCTAssertTrue(folder.waitForExistence(timeout: 8)); folder.tap()
        app.buttons["Choose"].tap()
        if move { app.segmentedControls.buttons["Move to…"].tap() }
    }

    private func openTransfers(_ app: XCUIApplication) {
        navigate("files", title: "File", in: app)
        let tasks = element("mobile.module.transfers", in: app)
        if tasks.waitForExistence(timeout: 5) { tasks.tap() }
    }

    private func beginRecycleBatch(_ app: XCUIApplication, restore: Bool, recycle: Bool = false) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        if recycle {
            XCTAssertTrue(app.staticTexts["#recycle"].waitForExistence(timeout: 5)); app.staticTexts["#recycle"].tap()
        }
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 5))
        openFileActions(app); app.buttons["Select Items"].tap()
        app.staticTexts["Sample document.txt"].tap(); app.staticTexts["Inbox"].tap()
        element("files.batch.more", in: app).tap()
        let operation = element(restore ? "files.batch.restore" : "files.batch.delete", in: app)
        XCTAssertTrue(operation.waitForExistence(timeout: 5)); XCTAssertTrue(operation.isEnabled); operation.tap()
        XCTAssertTrue(element("files.recycle.submit", in: app).waitForExistence(timeout: 5))
    }

    private func beginCopyMoveBatch(_ app: XCUIApplication, move: Bool) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 5))
        openFileActions(app); app.buttons["Select Items"].tap()
        app.staticTexts["Sample document.txt"].tap(); app.staticTexts["Inbox"].tap()
        let operation = element(move ? "files.batch.move" : "files.batch.copy", in: app)
        XCTAssertTrue(operation.isEnabled); operation.tap()
        XCTAssertTrue(app.buttons["output"].waitForExistence(timeout: 5)); app.buttons["output"].tap()
        let submit = element("files.copy-move.submit", in: app)
        XCTAssertTrue(submit.waitForExistence(timeout: 5)); XCTAssertTrue(submit.isEnabled); submit.tap()
    }

    func testOffice预览并交给系统分享及文件选择器() {
        let app = launchFixture(state: "office-preview"); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        XCTAssertTrue(app.staticTexts["Document.docx"].waitForExistence(timeout: 5)); app.staticTexts["Document.docx"].tap()
        let edit = element("files.office.preview.edit", in: app)
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        let rendered = app.staticTexts["Office preview sample"]
        XCTAssertTrue(rendered.waitForExistence(timeout: 15))
        attachScreenshot(app, name: "Office native Quick Look")
        edit.tap()
        XCTAssertTrue(app.staticTexts["Editing copy ready"].waitForExistence(timeout: 10))
        element("files.office.export", in: app).tap()
        XCTAssertTrue(element("ActivityListView", in: app).waitForExistence(timeout: 10))
        let sharedFilename = element("ActivityListView", in: app).descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@ AND label CONTAINS %@", ["LP.CaptionBar.TopCaption", "LP.CaptionBar.BottomCaption"], "Document")).firstMatch
        XCTAssertTrue(sharedFilename.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Office system editing handoff")
        app.buttons["header.closeButton"].tap()
        element("files.office.import", in: app).tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        attachScreenshot(app, name: "Office system document picker")
        cancel.tap()
        XCTAssertTrue(app.staticTexts["Editing copy ready"].waitForExistence(timeout: 5))
    }

    func testOffice主动保存并从活动中心继续编辑() {
        let app = launchFixture(state: "office-save"); defer { app.terminate() }
        openOfficeEditor(app)
        XCTAssertTrue(app.staticTexts["Changes ready to save"].waitForExistence(timeout: 10))
        element("files.office.save", in: app).tap()
        XCTAssertTrue(app.staticTexts["Changes saved to NAS"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("files.office.save", in: app).exists)
        attachScreenshot(app, name: "Office changes saved")
        app.buttons["Done"].tap(); openTransfers(app)
        let document = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'files.office.activity.'")).firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 8)); document.tap()
        XCTAssertTrue(app.staticTexts["Changes saved to NAS"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["files.office.import"].waitForExistence(timeout: 5))
    }

    func testOffice丢回执后刷新恢复且不显示再次保存() {
        let app = launchFixture(state: "office-unknown"); defer { app.terminate() }
        openOfficeEditor(app)
        XCTAssertTrue(element("files.office.save", in: app).waitForExistence(timeout: 10)); element("files.office.save", in: app).tap()
        XCTAssertTrue(app.staticTexts["Save not yet complete"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("files.office.save", in: app).exists)
        XCTAssertFalse(element("files.office.import", in: app).exists)
        XCTAssertFalse(element("files.office.discard", in: app).exists)
        element("files.office.refresh", in: app).tap()
        XCTAssertTrue(app.staticTexts["Changes saved to NAS"].waitForExistence(timeout: 10))
        attachScreenshot(app, name: "Office lost receipt recovery")
    }

    func testOffice冲突权限与相同内容保留正确操作() {
        for state in ["office-conflict", "office-readonly", "office-unchanged"] {
            let app = launchFixture(state: state)
            openOfficeEditor(app)
            if state == "office-unchanged" {
                XCTAssertTrue(app.staticTexts["Content unchanged. No save needed."].waitForExistence(timeout: 10))
                XCTAssertFalse(element("files.office.save", in: app).exists)
            } else {
                XCTAssertTrue(element("files.office.save", in: app).waitForExistence(timeout: 10)); element("files.office.save", in: app).tap()
                if state == "office-conflict" {
                    XCTAssertTrue(app.staticTexts["Original file changed"].waitForExistence(timeout: 10))
                    XCTAssertFalse(element("files.office.save", in: app).exists)
                } else {
                    let error = element("files.office.error", in: app)
                    XCTAssertTrue(error.waitForExistence(timeout: 10)); XCTAssertTrue(error.label.contains("permission"))
                }
            }
            XCTAssertTrue(element("files.office.export", in: app).isEnabled)
            attachScreenshot(app, name: state); app.terminate()
        }
    }

    private func openOfficeEditor(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        openItemActions("Document.docx", in: app)
        let edit = element("files.office.open", in: app)
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
    }

    private func launchFixture(state: String = "content", language: String = "en") -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", language]
        app.launchEnvironment["LANSTASH_UI_STATE"] = state
        app.launch()
        return app
    }

    func test文件读取等待时仍能打开本机设置() {
        let app = launchFixture(state: "loading"); defer { app.terminate() }
        XCTAssertTrue(element("mobile.page.loading", in: app).waitForExistence(timeout: 8))
        navigate("settings", title: "App settings", in: app)
        XCTAssertTrue(element("mobile.settings.page", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars["App settings"].exists)
        attachScreenshot(app, name: "App settings remain available while file reading waits")
    }

    private func navigate(_ destination: String, title: String, in app: XCUIApplication) {
        MobileUITestNavigation.open(app, destination: destination, title: title, test: self)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}

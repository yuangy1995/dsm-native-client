@testable import DsmMobile
import Foundation
import XCTest

final class MobileFileRecycleActionPresentationTests: XCTestCase {
    func test回收站动作使用原生Sheet确认提交核对与可访问状态() throws {
        let view = try sourceFile("Sources/Features/Files/Recycle/MobileFileRecycleActionView.swift")
        XCTAssertTrue(view.contains("NavigationStack"))
        XCTAssertTrue(view.contains("Form {"))
        XCTAssertTrue(view.contains("ContentUnavailableView"))
        XCTAssertTrue(view.contains(".interactiveDismissDisabled"))
        XCTAssertTrue(view.contains(".frame(minWidth: 44, minHeight: 44)"))
        XCTAssertTrue(view.contains(".accessibilityLabel"))
        XCTAssertTrue(view.contains("mobile.files.recycle.move.folder.message"))
        XCTAssertTrue(view.contains("mobile.files.recycle.restore.folder.message"))
        XCTAssertTrue(view.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertFalse(view.contains(".font(.system(size:"))
    }

    func test浏览器菜单只通过三门接入移入回收站与恢复() throws {
        let browser = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        XCTAssertTrue(browser.contains("if canMoveToRecycle(item)"))
        XCTAssertTrue(browser.contains("beginMoveToRecycle(item)"))
        XCTAssertTrue(browser.contains("if canRestoreFromRecycle(item)"))
        XCTAssertTrue(browser.contains("beginRestoreFromRecycle(item)"))
        XCTAssertTrue(browser.contains("guard canMoveToRecycle(item)"))
        XCTAssertTrue(browser.contains("guard canRestoreFromRecycle(item)"))
        XCTAssertTrue(browser.contains("MobileFileRecycleActionModel.canMoveToRecycle("))
        XCTAssertTrue(browser.contains("MobileFileRecycleActionModel.canRestoreFromRecycle("))
        XCTAssertTrue(browser.contains("MobileFileRecycleActionView("))
        XCTAssertTrue(browser.contains("recycleAction.deactivate()"))
    }

    func test共享写契约只在RecycleAction模型内调用且核对态无重试() throws {
        let browser = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        let model = try sourceFile("Sources/Features/Files/Recycle/MobileFileRecycleActionModel.swift")
        let view = try sourceFile("Sources/Features/Files/Recycle/MobileFileRecycleActionView.swift")
        XCTAssertFalse(browser.contains("moveToRecycleResult("))
        XCTAssertFalse(browser.contains("restoreFromRecycleResult("))
        XCTAssertTrue(model.contains("repository.moveToRecycleResult("))
        XCTAssertTrue(model.contains("repository.restoreFromRecycleResult("))
        XCTAssertTrue(model.contains("MobileFileRecycleActionReviewBlocker"))
        XCTAssertTrue(model.contains("isSupportedRecycleItem(item)"))
        XCTAssertTrue(model.contains("isConfirmedItemIdentity(item, source: snapshot.source)"))
        let review = try slice(view, from: "private var reviewView", to: "@ToolbarContentBuilder")
        XCTAssertFalse(review.contains("submit"))
        XCTAssertFalse(review.contains("retry"))
    }

    func test位置清单仍不包含恢复或删除写入口() throws {
        let locations = try sourceFile("Sources/Features/Files/Locations/MobileFileLocationsView.swift")
        XCTAssertFalse(locations.contains("moveToRecycleResult"))
        XCTAssertFalse(locations.contains("restoreFromRecycleResult"))
        XCTAssertFalse(locations.contains("beginRestoreFromRecycle"))
        XCTAssertFalse(locations.contains("beginMoveToRecycle"))
    }

    func testPhotos不把FileStation回收站当作照片删除而Files保留安全回收站() throws {
        let photos = try sourceFile("Sources/Features/Photos/MobilePhotosView.swift")
        let preview = try sourceFile("Sources/Features/Photos/MobileSynologyPhotoPreview.swift")
        let model = try sourceFile("Sources/Features/Photos/MobileSynologyPhotosModel.swift")
        for token in ["beginMoveToRecycle", "beginRestoreFromRecycle", "MobileFileRecycleActionView", "confirmDeletion"] {
            XCTAssertFalse((photos + preview + model).contains(token), token)
        }
        XCTAssertTrue(preview.contains("photos.readOnly.message"))
        let files = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        XCTAssertTrue(files.contains("MobileFileRecycleActionView("))
    }

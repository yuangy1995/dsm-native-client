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

    func test照片页复用共享移入回收站与恢复流程() throws {
        let photos = try sourceFile("Sources/Features/Photos/MobilePhotosView.swift")
        let grid = try sourceFile("Sources/Features/Photos/MobilePhotoGrid.swift")
        let cell = try sourceFile("Sources/Features/Photos/MobilePhotoCell.swift")
        let timeline = try sourceFile("Sources/Features/Photos/Timeline/MobilePhotoTimelineView.swift")
        let viewer = try sourceFile("Sources/Features/Photos/Viewer/MobilePhotoViewerView.swift")

        XCTAssertTrue(photos.contains("@State private var recycleAction = MobileFileRecycleActionModel()"))
        XCTAssertTrue(photos.contains("MobileFileRecycleActionView("))
        XCTAssertTrue(photos.contains("isMoveToRecycleAvailable: canMoveToRecycle"))
        XCTAssertTrue(photos.contains("MobileFileRecycleActionModel.canMoveToRecycle("))
        XCTAssertTrue(photos.contains("recycleAction.beginMoveToRecycle("))
        XCTAssertTrue(photos.contains("source: .browser"))
        XCTAssertTrue(photos.contains("onRestoreFromRecycle: beginRestoreFromRecycle"))
        XCTAssertTrue(photos.contains("MobileFileRecycleActionModel.canRestoreFromRecycle("))
        XCTAssertTrue(photos.contains("source: .recycle"))
        XCTAssertTrue(photos.contains("recycleActionDidConfirm"))
        XCTAssertTrue(photos.contains("repositoryIdentity: repositoryIdentity"))
        XCTAssertTrue(photos.contains("await timeline.refresh()"))
        XCTAssertTrue(photos.contains("await library.reload()"))
        XCTAssertTrue(photos.contains("recycleAction.deactivate()"))
        XCTAssertTrue(photos.contains("model.fileBrowserModel.locations.activate("))
        XCTAssertTrue(photos.contains("let locationLoadTask: Task<Void, Never>?"))
        XCTAssertTrue(photos.contains("locationLoadTask = Task {"))
        XCTAssertTrue(photos.contains("model.fileBrowserModel.locations.loadIfNeeded(repository: fileRepository)"))
        let activation = try slice(photos, from: "private func activatePhotoContext()", to: "private var activationIdentity")
        XCTAssertLessThan(
            try XCTUnwrap(activation.range(of: "await library.activate(")?.lowerBound),
            try XCTUnwrap(activation.range(of: "await locationLoadTask?.value")?.lowerBound)
        )
        XCTAssertTrue(photos.contains("model.fileRepository.map(ObjectIdentifier.init) == repositoryIdentity"))
        XCTAssertFalse(photos.contains("moveToRecycleResult("))
        XCTAssertFalse(photos.contains("restoreFromRecycleResult("))

        XCTAssertTrue(grid.contains("isMoveToRecycleAvailable(item) ? onMoveToRecycle : nil"))
        XCTAssertTrue(grid.contains("item.fileItem.isRecyclePath"))
        XCTAssertTrue(grid.contains("restoreDestinationPath(for: item.path)"))
        XCTAssertTrue(cell.contains("\"mobile.files.recycle.move.action\""))
        XCTAssertTrue(cell.contains("\"mobile.files.recycle.restore.action\""))
        XCTAssertTrue(timeline.contains("\"mobile.files.recycle.move.action\""))
        XCTAssertTrue(timeline.contains("\"mobile.files.recycle.restore.action\""))
        XCTAssertTrue(viewer.contains("onMoveToRecycle"))
        XCTAssertTrue(viewer.contains("onRestoreFromRecycle"))
        XCTAssertTrue(viewer.contains("\"mobile.files.recycle.move.action\""))
        XCTAssertTrue(viewer.contains("\"mobile.files.recycle.restore.action\""))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound)
        let endIndex = try XCTUnwrap(source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound)
        return String(source[startIndex..<endIndex])
    }
}

@testable import DsmMobile
import Foundation
import XCTest

final class MobileFileCopyMovePresentationTests: XCTestCase {
    func test原生Sheet目标浏览44ptVoiceOver动态文字与ReduceMotion护栏() throws {
        let view = try sourceFile("Sources/Features/Files/CopyMove/MobileFileCopyMoveView.swift")
        XCTAssertTrue(view.contains("NavigationStack"))
        XCTAssertTrue(view.contains("List {"))
        XCTAssertTrue(view.contains("ContentUnavailableView"))
        XCTAssertTrue(view.contains(".interactiveDismissDisabled"))
        XCTAssertTrue(view.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(view.contains(".accessibilityLabel"))
        XCTAssertTrue(view.contains(".accessibilityValue(folder.path)"))
        XCTAssertTrue(view.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertFalse(view.contains(".font(.system(size:"))
    }

    func test浏览器菜单有可见复制移动入口且UI和handler均调用同一三门() throws {
        let browser = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        XCTAssertTrue(browser.contains("if canCopyMove(item)"))
        XCTAssertTrue(browser.contains("beginCopyMove(.copy, item: item)"))
        XCTAssertTrue(browser.contains("beginCopyMove(.move, item: item)"))
        XCTAssertTrue(browser.contains("guard canCopyMove(item)"))
        XCTAssertTrue(browser.contains("MobileFileCopyMoveModel.canBegin("))
        XCTAssertTrue(browser.contains("copyMove.deactivate()"))
        XCTAssertTrue(browser.contains("MobileFileCopyMoveView("))
        XCTAssertTrue(browser.contains(".task(id: activationIdentity)"))
        XCTAssertTrue(browser.contains("model.fileRepository.map { ObjectIdentifier($0) }"))
    }

    func test未知核对态无重试且上传预览分享入口保持() throws {
        let view = try sourceFile("Sources/Features/Files/CopyMove/MobileFileCopyMoveView.swift")
        let browser = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        XCTAssertTrue(view.contains("mobile.files.copy-move.review.message"))
        XCTAssertTrue(view.contains("mobile.files.copy-move.review.dismiss"))
        let review = try slice(view, from: "private var reviewView", to: "@ToolbarContentBuilder")
        XCTAssertFalse(review.contains("retry"))
        XCTAssertFalse(review.contains("submit"))
        XCTAssertTrue(browser.contains("mobile.documents.upload"))
        XCTAssertTrue(browser.contains("mobile.files.share-link.action.create"))
        XCTAssertTrue(browser.contains("MobileFilePreviewView"))
    }

    func test业务保持在CopyMove目录且主浏览器不直接调用共享写契约() throws {
        let browser = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        let model = try sourceFile("Sources/Features/Files/CopyMove/MobileFileCopyMoveModel.swift")
        XCTAssertFalse(browser.contains("copyMoveResult("))
        XCTAssertTrue(model.contains("repository.copyMoveResult(request)"))
        XCTAssertTrue(model.contains("overwrite: false"))
        XCTAssertTrue(model.contains("ObjectIdentifier(repository)"))
        XCTAssertTrue(model.contains("MobileFileCopyMoveReviewBlocker"))
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

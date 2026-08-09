@testable import DsmMobile
import Foundation
import XCTest

final class MobileFileItemMutationPresentationTests: XCTestCase {
    func test变更界面使用系统FormSheet确认与无障碍护栏() throws {
        let view = try sourceFile(
            "Sources/Features/Files/Mutation/MobileFileItemMutationView.swift"
        )
        XCTAssertTrue(view.contains("Form {"))
        XCTAssertTrue(view.contains(".confirmationDialog("))
        XCTAssertTrue(view.contains(".interactiveDismissDisabled"))
        XCTAssertTrue(view.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(view.contains(".accessibilityLabel("))
        XCTAssertTrue(view.contains("ContentUnavailableView"))
        XCTAssertTrue(view.contains(".fillsAvailableContentArea(alignment: .center)"))
    }

    func test未知结果只有关闭与核对文案没有重试入口() throws {
        let view = try sourceFile(
            "Sources/Features/Files/Mutation/MobileFileItemMutationView.swift"
        )
        XCTAssertTrue(view.contains("mobile.files.mutation.review.message"))
        XCTAssertTrue(view.contains("mobile.files.mutation.review.dismiss"))
        XCTAssertFalse(view.contains("mutation.retry"))
    }

    func test浏览页同时具备工具栏新建与项目重命名且保留既有入口() throws {
        let browser = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        XCTAssertTrue(browser.contains("folder.badge.plus"))
        XCTAssertTrue(browser.contains("beginCreateFolder"))
        XCTAssertTrue(browser.contains("beginRename(item)"))
        XCTAssertTrue(browser.contains("MobileFileItemMutationModel.canMutate"))
        XCTAssertTrue(browser.contains("MobileFileItemMutationModel.canRename"))
        XCTAssertTrue(browser.contains("mobile.documents.upload"))
        XCTAssertTrue(browser.contains("mobile.files.share-link.action.create"))
        XCTAssertTrue(browser.contains("MobileDocumentExporter"))
        XCTAssertTrue(browser.contains("MobileShareSheet"))
    }

    func test所有变更可见文案均使用冻结资源键() throws {
        let view = try sourceFile(
            "Sources/Features/Files/Mutation/MobileFileItemMutationView.swift"
        )
        for key in [
            "mobile.files.mutation.create.title",
            "mobile.files.mutation.rename.title",
            "mobile.files.mutation.rename.confirm.title",
            "mobile.files.mutation.name.label",
            "mobile.files.mutation.name.help",
            "mobile.files.mutation.cancel",
            "mobile.files.mutation.working",
            "mobile.files.mutation.review.title",
            "mobile.files.mutation.review.message",
            "mobile.files.mutation.review.dismiss",
            "mobile.files.mutation.path.accessibility",
        ] {
            XCTAssertTrue(view.contains("L10n.string(\"\(key)\""), key)
        }
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

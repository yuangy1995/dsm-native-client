@testable import DsmMobile
import Foundation
import XCTest

final class MobileFileBrowserPresentationTests: XCTestCase {
    func test文件浏览使用统一五态与系统搜索() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        XCTAssertTrue(source.contains("MobilePageStateView("))
        XCTAssertTrue(source.contains(".searchable("))
        XCTAssertTrue(source.contains(".refreshable"))
        XCTAssertFalse(source.contains("files.isEmpty"))
    }

    func test移动文件页面只通过结果型变更模型接入写操作() throws {
        let view = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        let model = try sourceFile("Sources/Features/Files/MobileAppModel+Files.swift")
        let mutation = try sourceFile(
            "Sources/Features/Files/Mutation/MobileFileItemMutationModel.swift"
        )
        for forbidden in ["delete(", "isCreatingFolder", "itemToRename", "itemToDelete"] {
            XCTAssertFalse(view.contains(forbidden), forbidden)
            XCTAssertFalse(model.contains(forbidden), forbidden)
        }
        XCTAssertTrue(mutation.contains("createFolderResult("))
        XCTAssertTrue(mutation.contains("renameResult("))
        XCTAssertFalse(mutation.contains("repository.createFolder(parentPath:"))
        XCTAssertFalse(mutation.contains("repository.rename(path:"))
    }

    func test文件行主操作与更多菜单不是嵌套按钮() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        XCTAssertTrue(source.contains("HStack(spacing: 8)"))
        XCTAssertTrue(source.contains("private func itemMenu"))
        XCTAssertFalse(source.contains("Button {\n                        if item.isDirectory"))
    }

    func test保留文档上传保存副本和分享() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        XCTAssertTrue(source.contains(".fileImporter("))
        XCTAssertTrue(source.contains("mobile.documents.save-copy"))
        XCTAssertTrue(source.contains("mobile.documents.share"))
        XCTAssertTrue(source.contains("MobileDocumentExporter"))
        XCTAssertTrue(source.contains("MobileShareSheet"))
    }

    func test紧凑与常规宽度都能使用列表和网格() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        XCTAssertTrue(source.contains("if state.layout == .grid"))
        XCTAssertFalse(source.contains("state.layout == .grid && horizontalSizeClass == .regular"))
        XCTAssertTrue(source.contains("horizontalSizeClass == .regular ? 150 : 120"))
    }

    func test排序筛选使用系统菜单与Picker并提供筛选恢复动作() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        XCTAssertTrue(source.contains("private var sortAndFilterMenu"))
        XCTAssertTrue(source.contains("Menu {"))
        XCTAssertTrue(source.contains("Picker(L10n.string(\"mobile.files.sort-by\")"))
        XCTAssertTrue(source.contains("Picker(L10n.string(\"mobile.files.sort-direction\")"))
        XCTAssertTrue(source.contains("Picker(L10n.string(\"mobile.files.filter\")"))
        XCTAssertTrue(source.contains("mobile.files.filter.show-all"))
        XCTAssertTrue(source.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(source.contains(".fillsAvailableContentArea(alignment: .center)"))
        XCTAssertTrue(source.contains("L10n.string(\"mobile.files.item-actions\", item.name)"))
    }

    func test排序筛选没有移植桌面交互且可见文案均引用资源键() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        for forbidden in ["onHover", "contextMenu", "doubleClick", "rightClick"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        for key in [
            "mobile.files.sort-filter",
            "mobile.files.sort.name",
            "mobile.files.sort.size",
            "mobile.files.sort.modified",
            "mobile.files.sort.ascending",
            "mobile.files.sort.descending",
            "mobile.files.filter.all",
            "mobile.files.filter.files",
            "mobile.files.filter.folders",
            "mobile.files.filter-empty.title",
            "mobile.files.filter-empty.message"
        ] {
            XCTAssertTrue(source.contains("L10n.string(\"\(key)\")"), key)
        }
    }

    func test共享根容量使用系统进度与动态布局并合并无障碍摘要() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        XCTAssertTrue(source.contains("state.currentPath.isEmpty"))
        XCTAssertTrue(source.contains("storageSummaryView"))
        XCTAssertTrue(source.contains("ProgressView(value: summary.usedFraction)"))
        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(source.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(source.contains("mobile.files.storage.accessibility"))
        XCTAssertTrue(source.contains("mobile.files.storage.refresh-failed"))
        XCTAssertTrue(source.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(source.contains(".minimumScaleFactor(0.75)"))
        XCTAssertFalse(source.contains("realPath"))
        XCTAssertFalse(source.contains("volumeIdentity"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

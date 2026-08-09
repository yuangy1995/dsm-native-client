@testable import DsmMobile
import Foundation
import XCTest

final class MobilePhotoImportPresentationTests: XCTestCase {
    func test照片导入使用系统PhotosPicker且仅允许图片视频单项() throws {
        let source = try sourceFile("Sources/Features/Photos/Import/MobilePhotoImportView.swift")
        XCTAssertTrue(source.contains("PhotosPicker("))
        XCTAssertTrue(source.contains("matching: .any(of: [.images, .videos])"))
        XCTAssertTrue(source.contains("selection: $selection"))
        XCTAssertFalse(source.contains("maxSelectionCount"))
    }

    func test导入复用既有受控上传链且没有整库权限或平行网络实现() throws {
        let model = try sourceFile("Sources/Features/Photos/Import/MobilePhotoImportModel.swift")
        let view = try sourceFile("Sources/Features/Photos/Import/MobilePhotoImportView.swift")
        let combined = model + view
        XCTAssertTrue(combined.contains("controller.handlePickedFile("))
        XCTAssertTrue(combined.contains("MobileFileTransferService(repository: repository)"))
        XCTAssertFalse(combined.contains("PHPhotoLibrary.requestAuthorization"))
        XCTAssertFalse(combined.contains("URLSession"))
        XCTAssertFalse(combined.contains("repository.upload("))
    }

    func test照片页所有状态均保留工具栏导入入口并绑定当前空间目标() throws {
        let source = try sourceFile("Sources/Features/Photos/MobilePhotosView.swift")
        XCTAssertTrue(source.contains("MobilePhotoImportButton("))
        XCTAssertTrue(source.contains("let folderPath = browseMode == .timeline ? space.rootPath : state.currentPath"))
        XCTAssertTrue(source.contains("photoImport.activate("))
        XCTAssertTrue(source.contains("photoImport.cancelPreparation()"))
    }

    func test导入控件具备44点目标可访问目标说明和本地化反馈() throws {
        let source = try sourceFile("Sources/Features/Photos/Import/MobilePhotoImportView.swift")
        XCTAssertTrue(source.contains("frame(minWidth: 44, minHeight: 44)"))
        XCTAssertTrue(source.contains(".accessibilityHint("))
        XCTAssertTrue(source.contains("mobile.photos.import.target"))
        XCTAssertTrue(source.contains("mobile.photos.import.queued.title"))
        XCTAssertTrue(source.contains("mobile.photos.import.failed.title"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

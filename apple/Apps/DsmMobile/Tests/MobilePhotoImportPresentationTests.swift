@testable import DsmMobile
import Foundation
import XCTest

final class MobilePhotoImportPresentationTests: XCTestCase {
    func test系统选择器允许多张图片视频并保留原格式() throws {
        let source = try sourceFile("MobilePhotoUploadViews.swift")
        XCTAssertTrue(source.contains("[PhotosPickerItem]"))
        XCTAssertTrue(source.contains("PhotosPicker(selection: $selection"))
        XCTAssertTrue(source.contains("matching: .any(of: [.images, .videos])"))
        XCTAssertTrue(source.contains("preferredItemEncoding: .current"))
    }

    func test导入经共享上传队列而不申请整库权限或另建网络层() throws {
        let source = try sourceFile("MobilePhotoUploadImportModel.swift") + sourceFile("MobilePhotoUploadViews.swift")
        XCTAssertTrue(source.contains("model.enqueueUploads("))
        XCTAssertTrue(source.contains("artifacts.forEach { $0.release() }"))
        XCTAssertFalse(source.contains("PHPhotoLibrary.requestAuthorization"))
        XCTAssertFalse(source.contains("URLSession"))
        XCTAssertFalse(source.contains("MobileFileTransferService"))
    }

    func test上传入口使用当前目标与实际权限而不把照片转换为路径() throws {
        let source = try sourceFile("MobileSynologyPhotosView.swift")
        let model = try sourceFile("MobilePhotoUploadImportModel.swift")
        XCTAssertTrue(source.contains("uploads.begin()"))
        XCTAssertTrue(source.contains("disabled(!uploads.canBegin)"))
        XCTAssertTrue(model.contains("destination == currentDestination"))
        XCTAssertTrue(model.contains("model.canUploadPhotos"))
        XCTAssertFalse(model.contains("spaceRootPath"))
    }

    func test表单目的地错误与恢复由本地化和系统控件呈现() throws {
        let source = try sourceFile("MobilePhotoUploadViews.swift")
        for token in ["Form {", "photos.upload.destination", "mobile.photos.upload.choosePhotos", "mobile.photos.upload.chooseFiles",
                      "uploads.error", "mobile.photos.import.failed.item", "uploads.cancel()", "disabled(!uploads.canSubmit)"] {
            XCTAssertTrue(source.contains(token), token)
        }
    }

    private func sourceFile(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Features/Photos/" + file), encoding: .utf8)
    }
}

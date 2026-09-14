@testable import DsmMobile
import Foundation
import XCTest

final class MobilePhotoViewerPresentationTests: XCTestCase {
    func test查看器使用原生前后按钮键盘与VoiceOver且没有手势专用入口() throws {
        let source = try sourceFile("Sources/Features/Photos/Viewer/MobilePhotoViewerView.swift")

        XCTAssertTrue(source.contains("frame(width: 44, height: 44)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(shortcut, modifiers: [])"))
        XCTAssertTrue(source.contains("shortcut: .leftArrow"))
        XCTAssertTrue(source.contains("shortcut: .rightArrow"))
        XCTAssertTrue(source.contains("shortcut: \"s\""))
        XCTAssertTrue(source.contains(".accessibilityLabel(L10n.string(key))"))
        XCTAssertFalse(source.contains("DragGesture"))
        XCTAssertFalse(source.contains("onTapGesture"))
    }

    func test基础元数据仅解析已验证本地产物且字段使用白名单() throws {
        let source = try sourceFile("Sources/Features/Photos/Viewer/MobilePhotoViewerModel.swift")

        XCTAssertTrue(source.contains("preview.content == .quickLook"))
        XCTAssertTrue(source.contains("let artifactURL = preview.artifactURL"))
        XCTAssertTrue(source.contains("CGImageSourceCreateWithURL"))
        XCTAssertTrue(source.contains("kCGImagePropertyPixelWidth"))
        XCTAssertTrue(source.contains("kCGImagePropertyExifDateTimeOriginal"))
        XCTAssertTrue(source.contains("kCGImagePropertyTIFFMake"))
        XCTAssertTrue(source.contains("kCGImagePropertyTIFFModel"))
        for forbidden in ["GPSDictionary", "MakerNote", "mediaStreamSource(", "getInfo("] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    func test底层预览完成门比较完整FileItem而不是只比较路径() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFilePreviewModel.swift")

        XCTAssertTrue(source.contains("state.selectedItem == item"))
        XCTAssertFalse(source.contains("state.selectedItem?.path == item.path"))
    }

    func testiPhone和iPad复用同一Photos预览且属性面板原生适配() throws {
        let source = try sourceFile("Sources/Features/Photos/MobilePhotosView.swift")
        let preview = try sourceFile("Sources/Features/Photos/MobileSynologyPhotoPreview.swift")
        XCTAssertTrue(source.contains("MobileSynologyPhotoPreview(library: library)"))
        XCTAssertTrue(source.contains(".fullScreenCover("))
        XCTAssertTrue(preview.contains(".inspector(isPresented: $showsInformation)"))
        XCTAssertTrue(preview.contains("library.previewPhoto"))
        XCTAssertTrue(preview.contains(".task(id: library.previewRevision)"))
        XCTAssertTrue(preview.contains("library.clearExport()"))
        XCTAssertFalse(preview.contains("fileRepository"))
    }

    func test新版Photos查看器仅开放本地保存不沿用FileStation破坏性入口() throws {
        let preview = try sourceFile("Sources/Features/Photos/MobileSynologyPhotoPreview.swift")
        XCTAssertTrue(preview.contains("library.exportOriginal(photo)"))
        XCTAssertTrue(preview.contains("photos.readOnly.message"))
        XCTAssertFalse(preview.contains("role: .destructive"))
        XCTAssertFalse(preview.contains("beginMoveToRecycle"))
    }

    func test全部可见文案由待补双语资源键提供() throws {
        let source = try sourceFile("Sources/Features/Photos/Viewer/MobilePhotoViewerView.swift")
        for key in [
            "mobile.photos.viewer.action.previous",
            "mobile.photos.viewer.action.next",
            "mobile.photos.viewer.position",
            "mobile.photos.viewer.metadata.loading",
            "mobile.photos.viewer.metadata.unavailable.title",
            "mobile.photos.viewer.metadata.unavailable.message",
            "mobile.photos.viewer.metadata.failed.title",
            "mobile.photos.viewer.metadata.failed.message",
            "mobile.photos.viewer.metadata.section.file",
            "mobile.photos.viewer.metadata.section.photo",
            "mobile.photos.viewer.metadata.section.camera",
            "mobile.photos.viewer.metadata.name",
            "mobile.photos.viewer.metadata.kind",
            "mobile.photos.viewer.metadata.kind.image",
            "mobile.photos.viewer.metadata.kind.video",
            "mobile.photos.viewer.metadata.size",
            "mobile.photos.viewer.metadata.created",
            "mobile.photos.viewer.metadata.modified",
            "mobile.photos.viewer.metadata.dimensions",
            "mobile.photos.viewer.metadata.dimensions.value",
            "mobile.photos.viewer.metadata.captured",
            "mobile.photos.viewer.metadata.camera.make",
            "mobile.photos.viewer.metadata.camera.model"
        ] {
            XCTAssertTrue(source.contains("\"\(key)\""), key)
        }
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

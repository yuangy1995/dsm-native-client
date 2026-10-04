@testable import DsmMobile
import Foundation
import XCTest

final class MobilePhotoViewerPresentationTests: XCTestCase {
    func test预览前后按钮支持触控键盘及明确名称() throws {
        let source = try preview()
        for token in ["minWidth: 44, minHeight: 44", ".keyboardShortcut(.leftArrow", ".keyboardShortcut(.rightArrow",
                      ".keyboardShortcut(.cancelAction)", "photos.media.previous", "photos.media.next"] {
            XCTAssertTrue(source.contains(token), token)
        }
    }

    func test详情只呈现当前Photos对象而不解析本地路径或原始EXIF() throws {
        let source = try preview()
        for token in ["if let photo = model.previewPhoto", "photo.filename", "photo.takenAt", "photo.indexedAt", "photo.width", "photo.camera", "photo.tags"] {
            XCTAssertTrue(source.contains(token), token)
        }
        for forbidden in ["MobilePhotoMetadata", "CGImageSourceCreateWithURL", "MakerNote", "FileItem"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    func testiPad宽布局并列详情而iPhone垂直排布共用预览() throws {
        let source = try preview()
        XCTAssertTrue(source.contains("sizeClass == .regular && showsInfo"))
        XCTAssertTrue(source.contains("HStack(spacing: 0)"))
        XCTAssertTrue(source.contains("VStack(spacing: 0)"))
        XCTAssertTrue(source.contains("details.frame(maxHeight: 300)"))
    }

    func test删除保留Photos原件权限与明确确认() throws {
        let source = try preview()
        for token in ["model.canDeletePhotos([photo])", "model.requestDeletion(photo)", "photos.delete.confirm", "role: .destructive"] {
            XCTAssertTrue(source.contains(token), token)
        }
        XCTAssertFalse(source.contains("moveToRecycle"))
    }

    func test媒体通过受控播放器和本机图片不直接交付远端URL() throws {
        let source = try preview()
        XCTAssertTrue(source.contains("MobileMediaPlayer(source: source"))
        XCTAssertTrue(source.contains("MobileSynologyPhotoZoomView(image:"))
        XCTAssertTrue(source.contains("MobileSynologyPhotoImage.decode"))
        XCTAssertTrue(source.contains("guard !Task.isCancelled"))
        XCTAssertFalse(source.contains("AVPlayer(url:"))
        XCTAssertFalse(source.contains("AsyncImage(url:"))
    }

    func test保存分享失败和信息均使用双语资源入口() throws {
        let source = try preview()
        for key in ["photos.media.close", "photos.media.previous", "photos.media.next", "photos.media.info", "photos.media.failed",
                    "photos.retry", "photos.media.save", "photos.detail.taken", "photos.detail.camera", "photos.detail.size"] {
            XCTAssertTrue(source.contains("\"\(key)\""), key)
        }
        XCTAssertTrue(source.contains("MobileDocumentExporter"))
        XCTAssertTrue(source.contains("MobileShareSheet"))
    }

    private func preview() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Features/Photos/MobileSynologyPhotoPreview.swift"), encoding: .utf8)
    }
}

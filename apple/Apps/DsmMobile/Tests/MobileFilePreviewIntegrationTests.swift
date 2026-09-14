@testable import DsmMobile
import DsmCore
import DsmNetwork
import Foundation
import XCTest

private actor PreviewIntegrationSessionStore: SessionSecureStoring {
    func save(_ session: AuthSession, for profileID: UUID) async throws {}
    func load(for profileID: UUID) async throws -> AuthSession? { nil }
    func remove(for profileID: UUID) async throws {}
}

private actor PreviewIntegrationPasswordStore: PasswordSecureStoring {
    func save(_ password: String, for profileID: UUID) async throws {}
    func load(for profileID: UUID) async throws -> String? { nil }
    func remove(for profileID: UUID) async throws {}
}

private actor PreviewIntegrationService: MobileFilePreviewServing {
    nonisolated let profileID: UUID
    private let item: FileItem?

    init(profileID: UUID, item: FileItem? = nil) {
        self.profileID = profileID
        self.item = item
    }

    func getInfo(paths: [String]) async throws -> [FileItem] {
        guard let item, paths.contains(item.path) else { return [] }
        return [item]
    }

    func mediaStreamSource(
        remotePath: String,
        fileExtension: String?,
        expectedContentLength: Int64?
    ) async throws -> MediaStreamSource {
        MediaStreamSource(
            request: URLRequest(url: URL(string: "https://nas.invalid/file")!),
            fileExtension: fileExtension,
            expectedContentLength: expectedContentLength,
            expectedHost: "nas.invalid",
            pinnedCertificateSHA256: nil
        )
    }
}

final class MobileFilePreviewIntegrationTests: XCTestCase {
    func testAppModel单一持有预览模型并随活动Profile切换() throws {
        let source = try sourceFile("Sources/AppShell/MobileAppModel.swift")

        XCTAssertEqual(source.components(separatedBy: "let filePreviewModel = MobileFilePreviewModel()").count - 1, 1)
        XCTAssertTrue(source.contains("filePreviewModel.activate(profileID: activeProfile?.id)"))
    }

    func test文件主操作进入预览而目录继续钻取() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")

        XCTAssertTrue(source.contains("if item.isDirectory {\n            openDirectory(item)"))
        XCTAssertTrue(source.contains("} else {\n            openPreview(item)"))
        XCTAssertTrue(source.contains("Task { await preview.open(item, service: repository) }"))
        XCTAssertFalse(source.contains("if item.isDirectory { openDirectory(item) } else { itemForActions = item }"))
    }

    func test紧凑宽度全屏且常规宽度使用Inspector并可放大全屏() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")

        XCTAssertTrue(source.contains(".inspector(isPresented: $showsPreviewInspector)"))
        XCTAssertTrue(source.contains(".fullScreenCover(isPresented: $showsPreviewFullScreen"))
        XCTAssertTrue(source.contains("if horizontalSizeClass == .regular"))
        XCTAssertTrue(source.contains("showsPreviewInspector = true"))
        XCTAssertTrue(source.contains("showsPreviewFullScreen = true"))
        XCTAssertTrue(source.contains(".onChange(of: horizontalSizeClass)"))
        XCTAssertTrue(source.contains("adaptPreviewPresentation(to: sizeClass)"))
        XCTAssertTrue(source.contains("restoresPreviewInspectorAfterFullScreen = true\n        showsPreviewInspector = false"))
        XCTAssertTrue(source.contains("await Task.yield()"))
        XCTAssertTrue(source.contains("showsPreviewInspector = !showsPreviewFullScreen"))
        XCTAssertTrue(source.contains("if horizontalSizeClass == .regular,\n               preview.state.phase != .inactive {\n                showsPreviewInspector = true\n                return"))
        XCTAssertFalse(source.contains("openWindow"))
    }

    func testFiles保留互斥预览而Photos使用独立全屏媒体与属性Inspector() throws {
        let files = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        for token in ["restoresPreviewInspectorAfterFullScreen = true", "guard !showsPreviewFullScreen else { return }", "horizontalSizeClass == .regular", "preview.state.phase != .inactive"] {
            XCTAssertTrue(files.contains(token), token)
        }
        let photos = try sourceFile("Sources/Features/Photos/MobilePhotosView.swift")
        let preview = try sourceFile("Sources/Features/Photos/MobileSynologyPhotoPreview.swift")
        XCTAssertTrue(photos.contains(".fullScreenCover("))
        XCTAssertTrue(preview.contains(".inspector(isPresented: $showsInformation)"))
        XCTAssertFalse(photos.contains("filePreviewModel"))
        XCTAssertTrue(photos.contains("library.closePreview(); library.clearExport()"))
    }

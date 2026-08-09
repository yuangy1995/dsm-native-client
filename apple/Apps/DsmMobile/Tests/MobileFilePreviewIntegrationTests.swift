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

    func testFiles与Photos从Inspector放大全屏时容器互斥并仅按条件恢复() throws {
        for path in [
            "Sources/Features/Files/MobileFileBrowser.swift",
            "Sources/Features/Photos/MobilePhotosView.swift"
        ] {
            let source = try sourceFile(path)
            XCTAssertTrue(source.contains("restoresPreviewInspectorAfterFullScreen = true"), path)
            XCTAssertTrue(source.contains("showsPreviewInspector = false\n        Task { @MainActor in"), path)
            XCTAssertTrue(source.contains("guard !showsPreviewFullScreen else { return }"), path)
            XCTAssertTrue(source.contains("horizontalSizeClass == .regular"), path)
            XCTAssertTrue(source.contains("preview.state.phase != .inactive"), path)
            XCTAssertTrue(source.contains("restoresPreviewInspectorAfterFullScreen = false\n        showsPreviewFullScreen = false\n        showsPreviewInspector = false"), path)
        }
    }

    func test系统关闭显式关闭与Profile变化都清理展示状态() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")

        XCTAssertTrue(source.contains("onDismiss: previewPresentationDidDismiss"))
        XCTAssertTrue(source.contains(".onChange(of: showsPreviewInspector)"))
        XCTAssertTrue(source.contains(".onChange(of: model.activeProfile?.id)"))
        XCTAssertTrue(source.contains("private func closePreview()"))
        XCTAssertTrue(source.contains("preview.close()"))
        XCTAssertTrue(source.contains("private func resetPreviewPresentation()"))
    }

    func test预览接线保留文档导入导出分享且不共享其展示队列() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")

        XCTAssertTrue(source.contains(".fileImporter("))
        XCTAssertTrue(source.contains("MobileDocumentExporter"))
        XCTAssertTrue(source.contains("MobileShareSheet"))
        XCTAssertFalse(source.contains("let filePreviewModel = MobileFilePreviewModel()"))
        XCTAssertFalse(source.contains("documentTransferController.presentation ="))
    }

    func test详情导航提供44点触控目标和本地化辅助标签() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")

        XCTAssertTrue(source.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(source.contains("L10n.string(\"mobile.files.back\")"))
        XCTAssertTrue(source.contains("L10n.string(\"mobile.files.preview.action.close\")"))
    }

    @MainActor
    func test离开文件模块关闭预览并清除媒体源() async throws {
        let fixture = makeAppModel()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let profileID = UUID()
        let item = FileItem(
            profileID: profileID,
            name: "movie.mp4",
            path: "/movie.mp4",
            kind: .file,
            sizeBytes: 7
        )
        let service = PreviewIntegrationService(profileID: profileID, item: item)
        fixture.model.filePreviewModel.activate(profileID: profileID)
        await fixture.model.filePreviewModel.open(item, service: service)
        XCTAssertNotNil(fixture.model.filePreviewModel.mediaSource)

        fixture.model.selectModule(.chat)

        XCTAssertNil(fixture.model.filePreviewModel.state.selectedItem)
        XCTAssertNil(fixture.model.filePreviewModel.state.artifactURL)
        XCTAssertNil(fixture.model.filePreviewModel.mediaSource)
    }

    @MainActor
    func test留在或重新选择文件模块不关闭当前预览() async throws {
        let fixture = makeAppModel()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let profileID = UUID()
        let item = FileItem(
            profileID: profileID,
            name: "movie.mp4",
            path: "/movie.mp4",
            kind: .file,
            sizeBytes: 7
        )
        let service = PreviewIntegrationService(profileID: profileID, item: item)
        fixture.model.filePreviewModel.activate(profileID: profileID)
        await fixture.model.filePreviewModel.open(item, service: service)
        let source = try XCTUnwrap(fixture.model.filePreviewModel.mediaSource)

        fixture.model.selectModule(.files)
        fixture.model.selectTopLevel(.files)

        XCTAssertEqual(fixture.model.filePreviewModel.state.selectedItem?.path, item.path)
        XCTAssertEqual(fixture.model.filePreviewModel.mediaSource?.request.url, source.request.url)

        fixture.model.filePreviewModel.close()
    }

    @MainActor
    private func makeAppModel() -> (model: MobileAppModel, defaults: UserDefaults, suiteName: String) {
        let suiteName = "MobileFilePreviewIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: PreviewIntegrationSessionStore(),
            passwordStore: PreviewIntegrationPasswordStore()
        )
        return (model, defaults, suiteName)
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

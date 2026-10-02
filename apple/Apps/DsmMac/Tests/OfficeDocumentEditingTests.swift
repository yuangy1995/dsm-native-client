import CryptoKit
import DsmCore
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class OfficeDocumentEditingTests: XCTestCase {
    func testOffice分类只扩展Mac且不改变图片文本预览() {
        let profile = UUID()
        for ext in ["doc", "DOCX", "xls", "xlsx", "ppt", "PPTX"] {
            let item = FileItem(profileID: profile, name: "sample." + ext, path: "/synthetic/sample." + ext, kind: .file)
            XCTAssertTrue(OfficeDocumentFormat.supports(item))
            XCTAssertTrue(OfficeDocumentFormat.canPreview(item))
            XCTAssertEqual(PreviewKind.classify(item), .unsupported, "其他平台的共享分类保持原状")
        }
        XCTAssertFalse(OfficeDocumentFormat.supports(.init(profileID: profile, name: "folder.docx", path: "/folder.docx", kind: .directory)))
        for ext in ["pdf", "txt", "png"] {
            let item = FileItem(profileID: profile, name: "sample." + ext, path: "/synthetic/sample." + ext, kind: .file)
            XCTAssertFalse(OfficeDocumentFormat.supports(item)); XCTAssertTrue(OfficeDocumentFormat.canPreview(item))
        }
    }

    func test工作区预览只下载且关闭后删除临时副本不启用自动保存() async throws {
        let repository = OfficeEditingTestRepository()
        let item = await repository.currentItem()
        let profile = try NasProfile(id: repository.profileID, displayName: "Synthetic", host: "example.invalid", port: 5001)
        let model = WorkspaceModel(profile: profile, repository: repository, transferNotifier: NoopTransferNotifier(), preparePreviewCache: {})
        defer { model.cancelAllWork() }
        model.items = [item]; model.selection = [item.id]
        model.preparePreview()
        for _ in 0..<100 {
            if case .office = model.preview { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .office(let url) = model.preview else { return XCTFail("必须进入 Office 原生预览") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(OfficeEditingCoordinator.shared.session(for: item))
        model.dismissPreview()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let writes = await repository.uploads; XCTAssertTrue(writes.isEmpty)
    }

    func test关闭预览后迟到下载不能重新打开且删除其副本() async throws {
        let repository = OfficeEditingTestRepository()
        await repository.holdDownload()
        let item = await repository.currentItem()
        let profile = try NasProfile(id: repository.profileID, displayName: "Synthetic", host: "example.invalid", port: 5001)
        let model = WorkspaceModel(profile: profile, repository: repository, transferNotifier: NoopTransferNotifier(), preparePreviewCache: {})
        defer { model.cancelAllWork() }
        model.items = [item]; model.selection = [item.id]; model.preparePreview()
        for _ in 0..<100 {
            if await repository.isDownloadHeld { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let downloadedTo = await repository.downloadDestination
        let destination = try XCTUnwrap(downloadedTo)
        model.dismissPreview()
        await repository.releaseDownload()
        for _ in 0..<100 {
            if await repository.partialCleanupCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .empty = model.preview else { return XCTFail("关闭后不能被迟到下载覆盖") }
        XCTAssertFalse(model.isPreviewPresented)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func test打开未编辑及保存相同内容不会上传() async throws {
        let fixture = try await fixture(); defer { fixture.clean() }
        for second in 0..<8 { await fixture.session.poll(now: Date(timeIntervalSince1970: Double(second))) }
        try Data("original".utf8).write(to: fixture.url, options: .atomic)
        await detectSave(fixture.session)
        let writes = await fixture.repository.uploads
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(fixture.session.phase, .watching)
    }

    func test编辑保存稳定后自动上传原NAS文件名并核对内容() async throws {
        let fixture = try await fixture(); defer { fixture.clean() }
        try Data("edited".utf8).write(to: fixture.url, options: .atomic)
        let now = Date()
        await fixture.session.poll(now: now)
        await fixture.session.poll(now: now.addingTimeInterval(1))
        let early = await fixture.repository.uploads; XCTAssertTrue(early.isEmpty)
        await fixture.session.poll(now: now.addingTimeInterval(3))
        let writes = await fixture.repository.uploads
        XCTAssertEqual(writes, [Data("edited".utf8)])
        let names = await fixture.repository.uploadNames
        XCTAssertEqual(names, ["report.docx"], "本机副本可以改名，回传仍绑定原 NAS 文件名")
        XCTAssertEqual(fixture.session.phase, .saved)
        XCTAssertNotNil(fixture.session.lastSavedAt)
        await detectSave(fixture.session)
        let repeated = await fixture.repository.uploads; XCTAssertEqual(repeated.count, 1)
    }

    func test连续保存只上传最终稳定内容并识别原子替换() async throws {
        let fixture = try await fixture(); defer { fixture.clean() }
        let now = Date()
        try Data("part-one".utf8).write(to: fixture.url, options: .atomic)
        await fixture.session.poll(now: now)
        try Data("final-two".utf8).write(to: fixture.url, options: .atomic)
        await fixture.session.poll(now: now.addingTimeInterval(1))
        await fixture.session.poll(now: now.addingTimeInterval(2))
        let early = await fixture.repository.uploads; XCTAssertTrue(early.isEmpty)
        await fixture.session.poll(now: now.addingTimeInterval(4))
        let writes = await fixture.repository.uploads; XCTAssertEqual(writes, [Data("final-two".utf8)])
    }

    func test远端并发改动不被自动覆盖且保留本机修改() async throws {
        let fixture = try await fixture(); defer { fixture.clean() }
        try Data("local-edits".utf8).write(to: fixture.url)
        await fixture.repository.replaceRemote(Data("remote-edits".utf8))
        await detectSave(fixture.session)
        XCTAssertEqual(fixture.session.phase, .conflict)
        let writes = await fixture.repository.uploads; XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.url), Data("local-edits".utf8))
    }

    func test远端时间大小未变但内容变动仍拒绝覆盖() async throws {
        let fixture = try await fixture(); defer { fixture.clean() }
        try Data("local-new".utf8).write(to: fixture.url)
        await fixture.repository.replaceRemote(Data("changed!".utf8), changeTime: false)
        await detectSave(fixture.session)
        XCTAssertEqual(fixture.session.phase, .conflict)
        let writes = await fixture.repository.uploads; XCTAssertTrue(writes.isEmpty)
    }

    func test写权限失效只暂停并且可在修复后重试() async throws {
        let fixture = try await fixture(); defer { fixture.clean() }
        try Data("changed".utf8).write(to: fixture.url)
        await fixture.repository.setWritable(false)
        await detectSave(fixture.session)
        XCTAssertEqual(fixture.session.phase, .paused)
        let writes = await fixture.repository.uploads; XCTAssertTrue(writes.isEmpty)
        await fixture.repository.setWritable(true)
        await fixture.session.retry(); await fixture.session.poll(now: Date().addingTimeInterval(4))
        XCTAssertEqual(fixture.session.phase, .saved)
        let retried = await fixture.repository.uploads; XCTAssertEqual(retried.count, 1)
    }

    func test超时但已写入通过内容核对确认且不重传() async throws {
        let fixture = try await fixture(); defer { fixture.clean() }
        await fixture.repository.setBehavior(.timeoutAfterWrite)
        try Data("saved-without-ack".utf8).write(to: fixture.url)
        await detectSave(fixture.session)
        XCTAssertEqual(fixture.session.phase, .saved)
        await detectSave(fixture.session)
        let writes = await fixture.repository.uploads; XCTAssertEqual(writes.count, 1)
    }

    func test结果未知只核查不重传并可恢复后续自动保存() async throws {
        let fixture = try await fixture(); defer { fixture.clean() }
        await fixture.repository.setBehavior(.timeoutBeforeWrite)
        let modified = Data("pending".utf8)
        try modified.write(to: fixture.url)
        await detectSave(fixture.session)
        XCTAssertEqual(fixture.session.phase, .needsReview)
        await fixture.session.retry(); await detectSave(fixture.session); await fixture.session.review()
        let uncertainWrites = await fixture.repository.uploads; XCTAssertEqual(uncertainWrites.count, 1)
        XCTAssertEqual(fixture.session.phase, .needsReview)
        await fixture.repository.replaceRemote(modified)
        await fixture.session.review()
        XCTAssertEqual(fixture.session.phase, .saved)
        await fixture.repository.setBehavior(.success)
        try Data("next-save".utf8).write(to: fixture.url)
        await detectSave(fixture.session)
        let resumed = await fixture.repository.uploads; XCTAssertEqual(resumed.count, 2)
    }

    func test上传期间继续编辑不会改变在途快照且下次自动保存新版本() async throws {
        let fixture = try await fixture(); defer { fixture.clean() }
        await fixture.repository.setBehavior(.held)
        try Data("version-one".utf8).write(to: fixture.url)
        let pending = Task { await detectSave(fixture.session) }
        for _ in 0..<200 {
            if await fixture.repository.isHeld { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let isHeld = await fixture.repository.isHeld; XCTAssertTrue(isHeld)
        try Data("version-two".utf8).write(to: fixture.url, options: .atomic)
        await fixture.session.poll(now: Date().addingTimeInterval(10))
        await fixture.repository.releaseUpload(); await pending.value
        let first = await fixture.repository.remoteData; XCTAssertEqual(first, Data("version-one".utf8))
        await detectSave(fixture.session)
        let writes = await fixture.repository.uploads
        XCTAssertEqual(writes, [Data("version-one".utf8), Data("version-two".utf8)])
    }

    func test停止和断开保留副本并禁止下一次上传() async throws {
        let fixture = try await fixture(); defer { fixture.clean() }
        fixture.session.stop()
        try Data("kept-locally".utf8).write(to: fixture.url)
        await detectSave(fixture.session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url.path))
        XCTAssertTrue(fixture.session.isStopped)
        let writes = await fixture.repository.uploads; XCTAssertTrue(writes.isEmpty)
    }

    func test实际监测循环自动回传且停止后不再上传() async throws {
        let fixture = try await fixture(); defer { fixture.clean() }
        fixture.session.startMonitoring()
        try Data("timer-save".utf8).write(to: fixture.url, options: .atomic)
        for _ in 0..<80 {
            if fixture.session.phase == .saved { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(fixture.session.phase, .saved)
        let writes = await fixture.repository.uploads; XCTAssertEqual(writes, [Data("timer-save".utf8)])
        fixture.session.stop()
    }

    func test准备期间断开会话不启动编辑且保留下载副本() async throws {
        let repository = OfficeEditingTestRepository()
        await repository.holdDownload()
        let item = await repository.currentItem()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("office-preparing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(item.name)
        let coordinator = OfficeEditingCoordinator()
        let preparing = Task { try await coordinator.begin(item: item, localURL: url, repository: repository, monitor: false) }
        for _ in 0..<100 {
            if await repository.isDownloadHeld { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(coordinator.hasBusySessions)
        coordinator.stop(profileID: item.profileID)
        await repository.releaseDownload()
        do { _ = try await preparing.value; XCTFail("断开后不能启动编辑") } catch is CancellationError { }
        XCTAssertFalse(coordinator.hasActiveSessions)
        XCTAssertTrue(coordinator.sessions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test断开期间在途上传仍受退出保护并完成核查() async throws {
        let fixture = try await fixture(); defer { fixture.clean() }
        let coordinator = OfficeEditingCoordinator()
        let session = try await coordinator.begin(item: fixture.item, localURL: fixture.root.appendingPathComponent("busy.docx"),
                                                  repository: fixture.repository, monitor: false)
        defer { session.stop() }
        await fixture.repository.setBehavior(.held)
        try Data("in-flight".utf8).write(to: session.localURL)
        let uploading = Task { await detectSave(session) }
        for _ in 0..<100 {
            if await fixture.repository.isHeld { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        coordinator.stop(profileID: fixture.item.profileID)
        XCTAssertTrue(coordinator.hasActiveSessions)
        XCTAssertTrue(coordinator.hasBusySessions)
        do {
            _ = try await coordinator.begin(item: fixture.item, localURL: fixture.root.appendingPathComponent("reopened.docx"),
                                            repository: fixture.repository, monitor: false)
            XCTFail("在途上传完成核查前不能为同一文档开启新会话")
        } catch OfficeEditingError.invalidTarget { }
        await fixture.repository.releaseUpload(); await uploading.value
        XCTAssertFalse(coordinator.hasActiveSessions)
        XCTAssertEqual(session.phase, .stopped)
        let saved = await fixture.repository.remoteData; XCTAssertEqual(saved, Data("in-flight".utf8))
    }

    func test同一文档不能重复开启且准备完成就触发退出保护() async throws {
        let fixture = try await fixture(); defer { fixture.clean() }
        let coordinator = OfficeEditingCoordinator()
        let session = try await coordinator.begin(item: fixture.item, localURL: fixture.root.appendingPathComponent("another.docx"),
                                                  repository: fixture.repository, monitor: false)
        defer { session.stop() }
        XCTAssertTrue(coordinator.hasActiveSessions)
        XCTAssertFalse(coordinator.hasBusySessions)
        do {
            _ = try await coordinator.begin(item: fixture.item, localURL: fixture.root.appendingPathComponent("duplicate.docx"),
                                            repository: fixture.repository, monitor: false)
            XCTFail("不能重复开启")
        } catch OfficeEditingError.invalidTarget { }
        coordinator.stop(profileID: fixture.item.profileID)
        XCTAssertFalse(coordinator.hasActiveSessions)
    }

    func test本机文件被换成符号链接时不上传链接目标() async throws {
        let fixture = try await fixture(); defer { fixture.clean() }
        let outside = fixture.root.appendingPathComponent("outside")
        try Data("not-selected".utf8).write(to: outside)
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: outside)
        await detectSave(fixture.session)
        XCTAssertEqual(fixture.session.phase, .paused)
        let writes = await fixture.repository.uploads; XCTAssertTrue(writes.isEmpty)
    }

    private func detectSave(_ session: OfficeEditingSession) async {
        let now = Date(); await session.poll(now: now); await session.poll(now: now.addingTimeInterval(3))
    }

    private struct Fixture {
        let root: URL
        let url: URL
        let item: FileItem
        let repository: OfficeEditingTestRepository
        let session: OfficeEditingSession
        @MainActor func clean() { session.stop(); try? FileManager.default.removeItem(at: root) }
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("office-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = OfficeEditingTestRepository()
        let item = await repository.currentItem()
        let url = root.appendingPathComponent("local-copy.docx")
        let session = OfficeEditingSession(item: item, localURL: url, repository: repository)
        do { try await session.prepare() }
        catch { try? FileManager.default.removeItem(at: root); throw error }
        return Fixture(root: root, url: url, item: item, repository: repository, session: session)
    }
}

actor OfficeEditingTestRepository: FileRepository {
    enum UploadBehavior { case success, timeoutBeforeWrite, timeoutAfterWrite, held }
    let profileID = UUID()
    let allowsVerifiedRestore = false
    private(set) var uploads: [Data] = []
    private(set) var uploadNames: [String] = []
    private(set) var remoteData = Data("original".utf8)
    private var revision: Double = 0
    private var writable = true
    private var behavior = UploadBehavior.success
    private var uploadContinuation: CheckedContinuation<Void, Never>?
    private var holdsDownload = false
    private var downloadContinuation: CheckedContinuation<Void, Never>?
    private(set) var downloadDestination: URL?
    private(set) var partialCleanupCount = 0
    var isHeld: Bool { uploadContinuation != nil }
    var isDownloadHeld: Bool { downloadContinuation != nil }
    func holdDownload() { holdsDownload = true }
    func releaseDownload() { holdsDownload = false; downloadContinuation?.resume(); downloadContinuation = nil }
    func setBehavior(_ value: UploadBehavior) { behavior = value }
    func setWritable(_ value: Bool) { writable = value }
    func replaceRemote(_ data: Data, changeTime: Bool = true) { remoteData = data; if changeTime { revision += 1 } }
    func releaseUpload() { behavior = .success; uploadContinuation?.resume(); uploadContinuation = nil }
    func currentItem() -> FileItem {
        .init(profileID: profileID, name: "report.docx", path: "/synthetic/report.docx", kind: .file,
              sizeBytes: Int64(remoteData.count), times: .init(modifiedAt: Date(timeIntervalSince1970: 100 + revision), createdAt: nil, accessedAt: nil))
    }
    func getInfo(paths: [String]) -> [FileItem] { paths == ["/synthetic/report.docx"] ? [currentItem()] : [] }
    func fileMD5(remotePath: String) -> String { Insecure.MD5.hash(data: remoteData).map { String(format: "%02x", $0) }.joined() }
    func checkWritePermission(folderPath: String, filename: String, createOnly: Bool) throws {
        // 模拟 DSM 的已记录限制：已有文件名及 create_only=false 不能作为覆盖前置条件。
        guard writable, folderPath == "/synthetic", filename.hasPrefix("LanStash-Write-Check-"),
              filename.hasSuffix(".tmp"), createOnly else { throw URLError(.noPermissionsToReadFile) }
    }
    func download(remotePath: String, to localURL: URL, expectedSize: Int64?, progress: @escaping FileTransferProgress) async throws {
        downloadDestination = localURL
        if holdsDownload { await withCheckedContinuation { downloadContinuation = $0 } }
        try remoteData.write(to: localURL, options: .atomic)
    }
    func upload(localURL: URL, to folderPath: String, overwrite: Bool, progress: @escaping FileTransferProgress) async throws {
        guard folderPath == "/synthetic", overwrite else { throw OfficeEditingError.invalidTarget }
        let value = try Data(contentsOf: localURL)
        uploads.append(value); uploadNames.append(localURL.lastPathComponent)
        if behavior == .timeoutBeforeWrite { throw URLError(.timedOut) }
        if behavior == .held { await withCheckedContinuation { uploadContinuation = $0 } }
        remoteData = value; revision += 1
        if behavior == .timeoutAfterWrite { throw URLError(.timedOut) }
    }
    func listShares(offset: Int, limit: Int) -> FilePage { .init(folderPath: "/", items: [], offset: 0, total: 0, hasMore: false) }
    func listFolder(path: String, offset: Int, limit: Int) -> FilePage { .init(folderPath: path, items: [currentItem()], offset: 0, total: 1, hasMore: false) }
    func getThumbnail(path: String, size: ThumbnailSize) throws -> Data { throw OfficeEditingError.invalidTarget }
    func mediaStreamSource(remotePath: String, fileExtension: String?, expectedContentLength: Int64?) throws -> MediaStreamSource { throw OfficeEditingError.invalidTarget }
    func downloadArchive(remotePaths: [String], to localURL: URL, progress: @escaping FileTransferProgress) throws { throw OfficeEditingError.invalidTarget }
    func removePartialDownload(to localURL: URL) { partialCleanupCount += 1 }
    func delete(paths: [String], progress: @escaping FileTransferProgress) throws { throw OfficeEditingError.invalidTarget }
    func deleteResult(paths: [String], progress: @escaping FileTransferProgress) throws -> MutationResult { throw OfficeEditingError.invalidTarget }
    func createFolder(parentPath: String, name: String) throws { throw OfficeEditingError.invalidTarget }
    func copy(paths: [String], to destinationFolder: String, overwrite: Bool, progress: @escaping FileTransferProgress) throws { throw OfficeEditingError.invalidTarget }
    func move(paths: [String], to destinationFolder: String, overwrite: Bool, progress: @escaping FileTransferProgress) throws { throw OfficeEditingError.invalidTarget }
    func search(folderPath: String, query: String) -> [FileItem] { [] }
    func listFavorites() -> [FavoriteLocation] { [] }
    func addFavorite(path: String, name: String) throws { throw OfficeEditingError.invalidTarget }
    func addFavoriteResult(path: String, name: String) throws -> MutationResult { throw OfficeEditingError.invalidTarget }
    func removeFavorite(path: String) throws { throw OfficeEditingError.invalidTarget }
    func listShareLinks() -> [FileShareLink] { [] }
    func createShareLink(paths: [String], password: String?, expiresAt: String?) throws -> FileShareLink { throw OfficeEditingError.invalidTarget }
    func deleteShareLinks(ids: [String]) throws { throw OfficeEditingError.invalidTarget }
}

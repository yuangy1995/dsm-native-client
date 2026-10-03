import DsmCore
import DsmFileFeature
@testable import DsmMobile
import Foundation
import XCTest

@MainActor
final class MobileFileArchiveTests: XCTestCase {
    @MainActor private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveTests-\(UUID())")
        let profile = try! NasProfile(displayName: "Synthetic", host: "synthetic.invalid", port: 5001, usernameHint: "fixture")
        let repository: ArchiveRepository
        let queue: MobileFileArchiveQueue
        init() {
            repository = ArchiveRepository(profileID: profile.id)
            queue = MobileFileArchiveQueue(rootURL: root)
            queue.configure(profile: profile, repository: repository)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
    private func settled(_ queue: MobileFileArchiveQueue) async throws {
        for _ in 0..<200 {
            if !queue.records.contains(where: { queue.isRunning($0.id) }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("归档任务未结束")
    }
    private func submit(_ fixture: Fixture, name: String = "result") -> Bool {
        fixture.queue.compress(items: [fixture.repository.source], destination: "/target", name: name,
            format: .zip, level: .best, password: "test-only-password")
    }

    func test压缩完成回读并保留记录且不保存密码() async throws {
        let f = Fixture(); defer { f.cleanup() }
        XCTAssertTrue(submit(f)); try await settled(f.queue)
        XCTAssertEqual(f.queue.records.first?.phase, .completed)
        let calls = await f.repository.calls
        XCTAssertEqual(calls, 1)
        let text = try String(contentsOf: f.root.appendingPathComponent("archives-v1.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("test-only-password")); XCTAssertFalse(text.contains("password"))
        let restored = MobileFileArchiveQueue(rootURL: f.root)
        restored.configure(profile: f.profile, repository: f.repository)
        XCTAssertEqual(restored.records.first?.phase, .completed)
        XCTAssertEqual(restored.records.first?.id, f.queue.records.first?.id)
    }
    func test重复点击中断及重启不能重发同一输出() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.repository.setMode(.unknown)
        XCTAssertTrue(submit(f)); XCTAssertFalse(submit(f))
        try await settled(f.queue)
        XCTAssertEqual(f.queue.records.first?.phase, .interrupted)
        XCTAssertFalse(f.queue.records.first?.acknowledged ?? true)
        let restored = MobileFileArchiveQueue(rootURL: f.root)
        restored.configure(profile: f.profile, repository: f.repository)
        XCTAssertFalse(restored.compress(items: [f.repository.source], destination: "/target", name: "result", format: .zip, level: .best, password: nil))
        if let id = restored.records.first?.id { await restored.refresh(id); restored.removeFinished(id) }
        XCTAssertEqual(restored.records.first?.phase, .interrupted)
        let calls = await f.repository.calls; XCTAssertEqual(calls, 1)
    }
    func test已有完成回执但输出暂失恢复只查询() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.repository.setMode(.missingOutput)
        XCTAssertTrue(submit(f)); try await settled(f.queue)
        let record = try XCTUnwrap(f.queue.records.first)
        XCTAssertTrue(record.acknowledged); XCTAssertEqual(record.phase, .interrupted)
        let restored = MobileFileArchiveQueue(rootURL: f.root)
        restored.configure(profile: f.profile, repository: f.repository)
        await f.repository.setMode(.success); await restored.refresh(record.id)
        XCTAssertEqual(restored.records.first?.phase, .completed)
        let calls = await f.repository.calls; XCTAssertEqual(calls, 1)
    }
    func test同名冲突权限失败及源变化均不提交() async throws {
        for mode in [ArchiveRepository.Mode.existing, .permission, .changed] {
            let f = Fixture(); defer { f.cleanup() }
            await f.repository.setMode(mode); XCTAssertTrue(submit(f)); try await settled(f.queue)
            XCTAssertEqual(f.queue.records.first?.phase, .failed)
            XCTAssertNotNil(f.queue.error)
            let calls = await f.repository.calls; XCTAssertEqual(calls, 0)
        }
    }
    func test持久化失败与非法目标均不提交() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try Data().write(to: f.root)
        XCTAssertFalse(submit(f))
        XCTAssertNotNil(f.queue.recoveryError)
        XCTAssertFalse(f.queue.compress(items: [f.repository.source], destination: "/", name: "x", format: .zip, level: .best, password: nil))
        XCTAssertNil(MobileFileArchiveQueue.filename("../escape", format: .zip))
        XCTAssertEqual(MobileFileArchiveQueue.filename("photo", format: .sevenZip), "photo.7z")
        let calls = await f.repository.calls; XCTAssertEqual(calls, 0)
    }
    func test切换账号取消旧任务且不显示旧记录() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.repository.setMode(.wait)
        XCTAssertTrue(submit(f))
        for _ in 0..<100 { if await f.repository.calls == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
        let other = try NasProfile(displayName: "Other", host: "other.invalid", port: 5001, usernameHint: "other")
        f.queue.configure(profile: other, repository: ArchiveRepository(profileID: other.id))
        XCTAssertTrue(f.queue.records.isEmpty)
        for _ in 0..<100 { if await f.repository.cancelled { break }; try await Task.sleep(for: .milliseconds(5)) }
        let cancelled = await f.repository.cancelled; XCTAssertTrue(cancelled)
        f.queue.configure(profile: f.profile, repository: f.repository)
        try await settled(f.queue)
        XCTAssertEqual(f.queue.records.first?.phase, .interrupted)
        XCTAssertFalse(submit(f))
    }
    func test共享归档浏览分页选择及扁平重名拒绝() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let browser = FileArchiveBrowserModel(item: f.repository.source, destination: "/target", repository: f.repository)
        await browser.reload(); XCTAssertEqual(browser.items.count, 1); XCTAssertTrue(browser.hasMore)
        await browser.more(); XCTAssertEqual(browser.items.count, 2)
        browser.extractAll = false; browser.selected[1] = browser.items[0]
        let (request, inventory) = try await browser.prepare()
        XCTAssertEqual(inventory.count, 1)
        XCTAssertEqual(request.selection, .items([browser.items[0]]))
        browser.extractAll = true; browser.keepDirectories = false
        await f.repository.setMode(.flattenConflict)
        do { _ = try await browser.prepare(); XCTFail("同名扁平输出必须拒绝") } catch {}
    }
    func test解压原包变化与越界路径拒绝且正确输出才成功() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let inventory = [ArchiveItem(id: 1, name: "a.txt", path: "a.txt", isDirectory: false, sizeBytes: 7)]
        let request = FileExtractionRequest(filePath: f.repository.source.path, destination: "/target")
        XCTAssertFalse(f.queue.extract(item: f.repository.source, request: request,
            inventory: [.init(id: 2, name: "escape", path: "../escape", isDirectory: false)]))
        XCTAssertTrue(f.queue.extract(item: f.repository.source, request: request, inventory: inventory))
        try await settled(f.queue)
        XCTAssertEqual(f.queue.records.first?.phase, .completed)
        let extracted = await f.repository.extraction; XCTAssertEqual(extracted?.destination, "/target")
        XCTAssertEqual(extracted?.createSubfolder, true)
    }
    func test解压不替换时已有文件不得被当成本次成功() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.repository.setMode(.existing)
        XCTAssertTrue(f.queue.extract(item: f.repository.source,
            request: .init(filePath: f.repository.source.path, destination: "/target"),
            inventory: [.init(id: 1, name: "a.txt", path: "a.txt", isDirectory: false, sizeBytes: 7)]))
        try await settled(f.queue)
        XCTAssertEqual(f.queue.records.first?.phase, .failed)
        let calls = await f.repository.calls; XCTAssertEqual(calls, 0)
    }
    func test扁平解压拒绝含路径的文件名() async throws {
        let f = Fixture(); defer { f.cleanup() }
        XCTAssertFalse(f.queue.extract(item: f.repository.source,
            request: .init(filePath: f.repository.source.path, destination: "/target", keepDirectories: false),
            inventory: [.init(id: 1, name: "../escape", path: "safe.txt", isDirectory: false)]))
        let calls = await f.repository.calls; XCTAssertEqual(calls, 0)
    }
    func test损坏记录不覆盖不写入() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let file = f.root.appendingPathComponent("archives-v1.json"), data = Data("invalid".utf8)
        try data.write(to: file)
        let queue = MobileFileArchiveQueue(rootURL: f.root); queue.configure(profile: f.profile, repository: f.repository)
        XCTAssertNotNil(queue.recoveryError)
        XCTAssertFalse(queue.compress(items: [f.repository.source], destination: "/target", name: "a", format: .zip, level: .best, password: nil))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
}

private actor ArchiveRepository: FileRepository {
    enum Mode { case success, unknown, missingOutput, existing, permission, changed, wait, flattenConflict }
    nonisolated let profileID: UUID
    nonisolated let source: FileItem
    private var mode: Mode = .success
    private(set) var calls = 0
    private(set) var cancelled = false
    private(set) var extraction: FileExtractionRequest?
    init(profileID: UUID) {
        self.profileID = profileID
        source = FileItem(profileID: profileID, name: "source.zip", path: "/source/source.zip", kind: .file, sizeBytes: 12)
    }
    nonisolated var allowsVerifiedRestore: Bool { false }
    private func unused() -> URLError { URLError(.unsupportedURL) }
    func getThumbnail(path: String, size: ThumbnailSize) async throws -> Data { throw unused() }
    func mediaStreamSource(remotePath: String, fileExtension: String?, expectedContentLength: Int64?) async throws -> MediaStreamSource { throw unused() }
    func download(remotePath: String, to localURL: URL, expectedSize: Int64?, progress: @escaping FileTransferProgress) async throws { throw unused() }
    func downloadArchive(remotePaths: [String], to localURL: URL, progress: @escaping FileTransferProgress) async throws { throw unused() }
    func removePartialDownload(to localURL: URL) async {}
    func upload(localURL: URL, to folderPath: String, overwrite: Bool, progress: @escaping FileTransferProgress) async throws { throw unused() }
    func delete(paths: [String], progress: @escaping FileTransferProgress) async throws { throw unused() }
    func deleteResult(paths: [String], progress: @escaping FileTransferProgress) async throws -> MutationResult { throw unused() }
    func createFolder(parentPath: String, name: String) async throws { throw unused() }
    func copy(paths: [String], to destinationFolder: String, overwrite: Bool, progress: @escaping FileTransferProgress) async throws { throw unused() }
    func move(paths: [String], to destinationFolder: String, overwrite: Bool, progress: @escaping FileTransferProgress) async throws { throw unused() }
    func search(folderPath: String, query: String) async throws -> [FileItem] { throw unused() }
    func listFavorites() async throws -> [FavoriteLocation] { throw unused() }
    func addFavorite(path: String, name: String) async throws { throw unused() }
    func addFavoriteResult(path: String, name: String) async throws -> MutationResult { throw unused() }
    func removeFavorite(path: String) async throws { throw unused() }
    func listShareLinks() async throws -> [FileShareLink] { throw unused() }
    func createShareLink(paths: [String], password: String?, expiresAt: String?) async throws -> FileShareLink { throw unused() }
    func deleteShareLinks(ids: [String]) async throws { throw unused() }
    func setMode(_ mode: Mode) { self.mode = mode }
    func listShares(offset: Int, limit: Int) async throws -> FilePage { try await listFolder(path: "/target", offset: offset, limit: limit) }
    func listFolder(path: String, offset: Int, limit: Int) async throws -> FilePage {
        let items = mode == .existing ? [FileItem(profileID: profileID, name: "result.zip", path: "/target/result.zip", kind: .file)] : []
        return FilePage(folderPath: path, items: items, offset: offset, total: items.count, hasMore: false)
    }
    func getInfo(paths: [String]) async throws -> [FileItem] {
        if paths == [source.path] {
            return mode == .changed ? [] : [source]
        }
        if calls == 0 && mode != .existing { return [] }
        if mode == .missingOutput { throw URLError(.notConnectedToInternet) }
        return paths.map { FileItem(profileID: profileID, name: ($0 as NSString).lastPathComponent, path: $0, kind: .file, sizeBytes: 7) }
    }
    func checkWritePermission(folderPath: String, filename: String, createOnly: Bool) async throws {
        if mode == .permission { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "fixture") }
    }
    func compress(paths: [String], destinationFilePath: String, format: ArchiveFormat, level: ArchiveCompressionLevel,
                  password: String?, progress: @escaping FileTransferProgress) async throws {
        calls += 1
        if mode == .unknown { throw URLError(.timedOut) }
        if mode == .wait {
            do { try await Task.sleep(for: .seconds(60)) } catch { cancelled = true; throw error }
        }
        progress(100, 100)
    }
    func extract(_ request: FileExtractionRequest, progress: @escaping FileTransferProgress) async throws { extraction = request; calls += 1 }
    func listArchivePage(filePath: String, parentID: Int, offset: Int, limit: Int, codepage: String?, password: String?) async throws -> ArchiveItemPage {
        let entries: [ArchiveItem] = mode == .flattenConflict ? [
            .init(id: 1, name: "a.txt", path: "one/a.txt", isDirectory: false),
            .init(id: 2, name: "a.txt", path: "two/a.txt", isDirectory: false)
        ] : [
            .init(id: 1, name: "a.txt", path: "a.txt", isDirectory: false, sizeBytes: 7),
            .init(id: 2, name: "b.txt", path: "b.txt", isDirectory: false, sizeBytes: 7)
        ]
        return ArchiveItemPage(items: [entries[offset]], offset: offset, total: 2, hasMore: offset == 0)
    }
}

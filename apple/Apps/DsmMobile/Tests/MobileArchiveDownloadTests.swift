@testable import DsmMobile
import DsmCore
import DsmNetwork
import Foundation
import XCTest

private actor ArchiveDownloadTransport: DsmBinaryHTTPTransport {
    let items: [FileItem]
    var failOnce: Bool
    private var holdsDownloads: Bool
    private var completions: [CheckedContinuation<Void, Never>] = []
    private(set) var paths: [[String]] = []
    private(set) var reads: [[String]] = []
    private(set) var ranged = false

    init(items: [FileItem], failOnce: Bool = false, holdsDownloads: Bool = false) {
        self.items = items; self.failOnce = failOnce; self.holdsDownloads = holdsDownloads
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []
        func field(_ key: String) -> String { fields.first { $0.name == key }?.value ?? "" }
        guard field("api") == DsmAPIName.fileStationList, field("method") == "getinfo" else {
            throw URLError(.unsupportedURL)
        }
        let selected = try JSONDecoder().decode([String].self, from: Data(field("path").utf8))
        reads.append(selected)
        let rows: [[String: Any]] = items.filter { selected.contains($0.path) }.map { item in
            ["name": item.name, "path": item.path, "isdir": item.isDirectory,
             "additional": ["size": 12, "perm": ["adv_right": ["read": item.permissions?.canRead ?? true, "write": false, "delete": false]]]]
        }
        return .init(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": ["files": rows]]), statusCode: 200)
    }
    func download(_ request: URLRequest, to url: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        let fields = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = fields.first { $0.name == "path" }?.value ?? ""
        paths.append(try JSONDecoder().decode([String].self, from: Data(value.utf8)))
        ranged = ranged || request.value(forHTTPHeaderField: "Range") != nil
        if holdsDownloads {
            // 由测试在取消或重复提交检查后放行，确保回调时序不依赖机器速度。
            await withCheckedContinuation { completions.append($0) }
        }
        if failOnce { failOnce = false; throw URLError(.networkConnectionLost) }
        let data = Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18))
        try data.write(to: url); progress(Int64(data.count), Int64(data.count))
        return .init(data: Data(), statusCode: 200, headers: ["Content-Type": "application/zip", "Content-Length": String(data.count)])
    }
    func upload(_ request: URLRequest, from url: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        throw URLError(.unsupportedURL)
    }
    func finishDownloads() {
        holdsDownloads = false
        let pending = completions
        completions.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class ArchiveProtectionFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var lastProtection: FileProtectionType?
    private var lastPath: String?
    let rejectsProtection: Bool
    init(rejectsProtection: Bool = false) { self.rejectsProtection = rejectsProtection; super.init() }
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        lock.lock()
        lastProtection = attributes[.protectionKey] as? FileProtectionType; lastPath = path
        lock.unlock()
        if rejectsProtection { throw CocoaError(.fileWriteNoPermission) }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
    func observedProtection() -> (FileProtectionType?, String?) {
        lock.lock(); defer { lock.unlock() }; return (lastProtection, lastPath)
    }
}

@MainActor
final class MobileArchiveDownloadTests: XCTestCase {
    func test只读文件和目录可选择且原路径包含尾空格保持不变() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let sources = try XCTUnwrap(MobileArchiveDownloadSelection.sources(f.items, profileID: f.profile.id))
        XCTAssertEqual(sources.map(\.path), ["/sample/Folder", "/sample/report.txt "])
        XCTAssertTrue(MobileArchiveDownloadSelection.canSelect(f.items[1], profileID: f.profile.id))
        XCTAssertEqual(MobileArchiveDownloadSelection.identity(sources), MobileArchiveDownloadSelection.identity(sources.reversed()))
        XCTAssertNotEqual(MobileArchiveDownloadSelection.identity(sources), MobileArchiveDownloadSelection.identity([
            sources[0], .init(path: "/sample/report.txt", isDirectory: false)]))
        XCTAssertNil(MobileArchiveDownloadSelection.sources([f.items[1]], profileID: f.profile.id))
        XCTAssertNil(MobileArchiveDownloadSelection.sources(f.items, profileID: UUID()))
        XCTAssertNil(MobileArchiveDownloadSelection.sources([f.items[0], f.items[0]], profileID: f.profile.id))
        XCTAssertFalse(MobileArchiveDownloadSelection.isValid([.init(path: "/sample/Folder", isDirectory: true),
            .init(path: "/sample/Folder/child", isDirectory: false)]))
        XCTAssertFalse(MobileArchiveDownloadSelection.isValid([.init(path: "/sample/../private", isDirectory: true)]))
        XCTAssertFalse(MobileArchiveDownloadSelection.isValid([.init(path: "/", isDirectory: true)]))
        XCTAssertFalse(MobileArchiveDownloadSelection.isValid((0..<21).map { .init(path: "/sample/\($0)", isDirectory: false) }))
    }

    func test实际Repository下载整个原始清单且无写请求和字节续传() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let transport = ArchiveDownloadTransport(items: f.items)
        let fileManager = ArchiveProtectionFileManager()
        let service = try f.service(transport, fileManager: fileManager)
        try await service.download(f.request) { _, _ in }
        let paths = await transport.paths, reads = await transport.reads, ranged = await transport.ranged
        XCTAssertEqual(paths, [f.items.map(\.path)]); XCTAssertEqual(reads, [f.items.map(\.path)])
        XCTAssertFalse(ranged)
        XCTAssertEqual(try Data(contentsOf: f.request.temporaryURL).prefix(4), Data([0x50, 0x4b, 0x05, 0x06]))
        // 模拟器不提供真实加密状态；检查实际服务在交付前调用保护设置，真机另验锁屏行为。
        let protection = fileManager.observedProtection()
        XCTAssertEqual(protection.0, .complete); XCTAssertEqual(protection.1, f.request.temporaryURL.path)
        await service.removePartialDownload(f.request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.request.temporaryURL.path))
    }

    func test最终副本无法设置保护时清理文件并禁止系统交付() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let coordinator = MobileTransferCoordinator(recoveryStore: f.store)
        await coordinator.activateContext(f.identity)
        let controller = MobileDocumentTransferController(transferCoordinator: coordinator, recoveryStore: f.store)
        controller.setActiveProfile(f.profile.id)
        let fileManager = ArchiveProtectionFileManager(rejectsProtection: true)
        let transport = ArchiveDownloadTransport(items: f.items)
        let value = await controller.startDownload(context: f.context(controller),
            service: try f.service(transport, fileManager: fileManager))
        let id = try XCTUnwrap(value)
        try await wait { await coordinator.task(id: id)?.status == .failed }
        let savedRequest = await coordinator.request(id: id)
        let request = try XCTUnwrap(savedRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.localURL.path))
        XCTAssertNil(controller.presentation)
        XCTAssertEqual(fileManager.observedProtection().0, .complete)
    }

    func test目录变成文件或读取权限撤销时不下载() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        for denied in [false, true] {
            let changed = FileItem(profileID: f.profile.id, name: "Folder", path: f.items[0].path,
                kind: denied ? .directory : .file,
                permissions: .init(canRead: !denied, canWrite: false, canDelete: false, posixMode: nil))
            let transport = ArchiveDownloadTransport(items: [changed, f.items[1]])
            do { try await f.service(transport).download(f.request) { _, _ in }; XCTFail("不应下载过期或无权限选择") }
            catch let error as AppError { XCTAssertEqual(error.category, denied ? .permissionDenied : .conflict) }
            let requests = await transport.paths; XCTAssertTrue(requests.isEmpty)
        }
    }

    func test新增记录版本保留全清单旧单文件记录仍能读取() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let record = f.record(status: .running)
        try f.store.save([record])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: f.store.recordsURL)) as! [String: Any]
        XCTAssertEqual(json["version"] as? Int, 2)
        let restored = try XCTUnwrap(f.store.load().first)
        XCTAssertEqual(restored.request, .download(f.request))
        // 旧版的单文件请求没有 archiveSources，版本 1 原件继续读取。
        let old = MobileDownloadRequest(profileID: f.profile.id, remotePath: "/sample/old.txt",
            temporaryURL: f.request.temporaryURL, stableTarget: "/sample/old.txt", intent: .share)
        var task = record.task
        task = .init(id: task.id, createdAt: task.createdAt, profileID: f.profile.id, source: .app,
            sourceIdentifier: nil, operation: .appDownload, stableTarget: old.stableTarget, progress: .zero,
            status: .queued, retryPolicy: .restartFromBeginning, mutationResult: nil)
        try f.store.save([.init(context: f.identity.storageIdentifier, task: task, request: .download(old))])
        let oldJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: f.store.recordsURL)) as! [String: Any]
        XCTAssertEqual(oldJSON["version"] as? Int, 1)
        XCTAssertEqual(try f.store.load().first?.request, .download(old))
    }

    func test打包重启后只在原账号主动重试保留分享意图与显示名称() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let record = f.record(status: .running)
        try f.store.save([record])
        let coordinator = MobileTransferCoordinator(recoveryStore: f.store)
        let transport = ArchiveDownloadTransport(items: f.items)
        let service = try f.service(transport)
        let other = MobileWorkspaceIdentity(try NasProfile(id: f.profile.id, displayName: "Other",
            host: "fixture.example.invalid", port: 5001, usernameHint: "other"))
        await coordinator.activateContext(other)
        await coordinator.retryFromBeginning(record.task.id, using: service)
        let hidden = await coordinator.tasks(profileID: f.profile.id), before = await transport.paths
        XCTAssertTrue(hidden.isEmpty); XCTAssertTrue(before.isEmpty)
        await coordinator.activateContext(f.identity)
        let controller = MobileDocumentTransferController(transferCoordinator: coordinator, recoveryStore: f.store)
        controller.setActiveProfile(f.profile.id)
        await controller.continueTransfer(record.task.id, service: service)
        try await wait { controller.presentation != nil }
        XCTAssertEqual(controller.presentation?.intent, .share)
        XCTAssertEqual(controller.presentation?.url.lastPathComponent, "Selected.zip")
        let task = await coordinator.task(id: record.task.id), paths = await transport.paths
        XCTAssertEqual(task?.artifactName, "Selected.zip"); XCTAssertEqual(paths, [f.items.map(\.path)])
        controller.requestDismiss(taskID: record.task.id); controller.presentationDidDismiss()
        try await wait { await coordinator.task(id: record.task.id)?.retryPolicy == MobileTransferRetryPolicy.none }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.request.temporaryURL.path))
    }

    func test网络失败可从头重试完整清单且不会自动弹出残缺副本() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let coordinator = MobileTransferCoordinator(recoveryStore: f.store)
        await coordinator.activateContext(f.identity)
        let controller = MobileDocumentTransferController(transferCoordinator: coordinator, recoveryStore: f.store)
        controller.setActiveProfile(f.profile.id)
        let transport = ArchiveDownloadTransport(items: f.items, failOnce: true), service = try f.service(transport)
        let value = await controller.startDownload(context: f.context(controller), service: service)
        let id = try XCTUnwrap(value)
        try await wait { await coordinator.task(id: id)?.status == .failed }
        XCTAssertNil(controller.presentation)
        await controller.continueTransfer(id, service: service)
        try await wait { controller.presentation?.taskID == id }
        let paths = await transport.paths; XCTAssertEqual(paths, [f.items.map(\.path), f.items.map(\.path)])
        controller.requestDismiss(taskID: id); controller.presentationDidDismiss()
    }

    func test取消与切换账号的迟到下载不显示旧文件且清理副本() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let coordinator = MobileTransferCoordinator(recoveryStore: f.store)
        await coordinator.activateContext(f.identity)
        let controller = MobileDocumentTransferController(transferCoordinator: coordinator, recoveryStore: f.store)
        controller.setActiveProfile(f.profile.id)
        let context = f.context(controller), transport = ArchiveDownloadTransport(items: f.items, holdsDownloads: true)
        addTeardownBlock { await transport.finishDownloads() }
        let service = try f.service(transport)
        let value = await controller.startDownload(context: context, service: service)
        let id = try XCTUnwrap(value)
        try await wait { !(await transport.paths).isEmpty }
        controller.resetForDisconnectedWorkspace(); controller.setActiveProfile(UUID())
        let stale = await controller.startDownload(context: context, service: service)
        XCTAssertNil(stale)
        try await wait { await coordinator.task(id: id)?.status == .cancelling }
        await transport.finishDownloads()
        try await wait { await coordinator.task(id: id)?.status == .cancelled }
        let request = await coordinator.request(id: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(request).localURL.path))
        XCTAssertNil(controller.presentation)
        let paths = await transport.paths; XCTAssertEqual(paths.count, 1)
    }

    func test同一选择重复点击只启动一个下载且不受文件名影响() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let coordinator = MobileTransferCoordinator(recoveryStore: f.store)
        await coordinator.activateContext(f.identity)
        let transport = ArchiveDownloadTransport(items: f.items, holdsDownloads: true), service = try f.service(transport)
        addTeardownBlock { await transport.finishDownloads() }
        let first = await coordinator.enqueueDownload(f.request)
        await coordinator.start(first, using: service)
        try await wait { !(await transport.paths).isEmpty }
        var second = f.request
        second = .init(profileID: second.profileID, remotePath: second.remotePath,
            temporaryURL: second.temporaryURL.deletingLastPathComponent().appendingPathComponent("Another.zip"),
            stableTarget: second.stableTarget, intent: .exportCopy, archiveSources: second.archiveSources)
        let duplicate = await coordinator.enqueueDownload(second)
        await coordinator.start(duplicate, using: service)
        try await wait { await coordinator.task(id: duplicate)?.status == .cancelledBeforeSubmission }
        await transport.finishDownloads()
        try await wait { await coordinator.task(id: first)?.status == .succeeded }
        let paths = await transport.paths; XCTAssertEqual(paths.count, 1)
    }

    func test不合法打包选择不创建任务或目录() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let coordinator = MobileTransferCoordinator(recoveryStore: f.store)
        let controller = MobileDocumentTransferController(transferCoordinator: coordinator, recoveryStore: f.store)
        controller.setActiveProfile(f.profile.id)
        var context = f.context(controller); context.archiveSources = []
        let transport = ArchiveDownloadTransport(items: f.items)
        let task = await controller.startDownload(context: context, service: try f.service(transport))
        XCTAssertNil(task)
        let tasks = await coordinator.allTasks(); XCTAssertTrue(tasks.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.store.artifactsURL.path).isEmpty)
    }

    func test版本不匹配或损坏选择保留恢复原件且零下载() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.store.save([f.record(status: .queued)])
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: f.store.recordsURL)) as! [String: Any]
        json["version"] = 1
        let original = try JSONSerialization.data(withJSONObject: json)
        try original.write(to: f.store.recordsURL)
        XCTAssertThrowsError(try f.store.load())
        let coordinator = MobileTransferCoordinator(recoveryStore: f.store)
        await coordinator.activateContext(f.identity)
        let transport = ArchiveDownloadTransport(items: f.items), service = try f.service(transport)
        let id = await coordinator.enqueueDownload(f.request); await coordinator.start(id, using: service)
        let paths = await transport.paths; XCTAssertTrue(paths.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.store.recordsURL), original)
        let failed = await coordinator.recoveryFailure; XCTAssertTrue(failed)
    }

    private struct Fixture {
        let profile: NasProfile
        let store: MobileTransferRecoveryStore
        let items: [FileItem]
        var identity: MobileWorkspaceIdentity { .init(profile) }
        var sources: [MobileArchiveDownloadSource] { items.map { .init(path: $0.path, isDirectory: $0.isDirectory) } }
        var request: MobileDownloadRequest { .init(profileID: profile.id, remotePath: items[0].path,
            temporaryURL: store.artifactsURL.appendingPathComponent("owned/Selected.zip"),
            stableTarget: MobileArchiveDownloadSelection.identity(sources), intent: .share, archiveSources: sources) }
        init() throws {
            profile = try NasProfile(displayName: "Fixture", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
            store = .init(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("archive-download-\(UUID())"))
            let id = profile.id, permission = FilePermissions(canRead: true, canWrite: false, canDelete: false, posixMode: nil)
            items = [.init(profileID: id, name: "Folder", path: "/sample/Folder", kind: .directory, permissions: permission),
                .init(profileID: id, name: "report.txt ", path: "/sample/report.txt ", kind: .file, permissions: permission)]
            try MobileTransferRecoveryStore.prepareDirectory(store.artifactsURL)
        }
        func cleanup() { try? FileManager.default.removeItem(at: store.rootURL) }
        @MainActor func context(_ controller: MobileDocumentTransferController) -> MobileDocumentDownloadContext {
            .init(contextID: controller.contextID, profileID: profile.id, remotePath: items[0].path,
                fileName: "Selected.zip", intent: .share, archiveSources: sources)
        }
        func service(_ transport: ArchiveDownloadTransport, fileManager: ArchiveProtectionFileManager? = nil) throws -> MobileFileTransferService {
            let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: [DsmAPIName.fileStationList, DsmAPIName.fileStationDownload].map {
                ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2,
                    requestFormat: .form, selectedVersion: 2, verified: false))
            }))
            let repository = try DsmFileRepository(profile: profile, capabilities: capabilities,
                session: .init(sid: "fixture-only", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
            if let fileManager {
                return .init(repository: repository, applyProtection: { url, protection in
                    try fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
                })
            }
            return .init(repository: repository)
        }
        func record(status: MobileTransferStatus) -> MobileTransferRecoveryStore.Record {
            .init(context: identity.storageIdentifier, task: .init(id: UUID(), createdAt: Date(), profileID: profile.id,
                source: .app, sourceIdentifier: nil, operation: .appDownload, stableTarget: request.stableTarget,
                progress: .zero, status: status, retryPolicy: .restartFromBeginning, mutationResult: nil, artifactName: "Selected.zip"),
                request: .download(request))
        }
    }
    private func wait(file: StaticString = #filePath, line: UInt = #line, _ predicate: () async -> Bool) async throws {
        for _ in 0..<200 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("下载状态未结束", file: file, line: line)
    }
}

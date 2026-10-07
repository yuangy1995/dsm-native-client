import DsmCore
import DsmNetwork
import DsmFileFeature
@testable import DsmMobile
import Foundation
import XCTest

@MainActor
final class MobileFileUploadQueueTests: XCTestCase {
    func test系统到期暂停当前及后续批次重启不自动上传() async throws {
        let fixture = try Fixture(uploadDelay: .seconds(30))
        defer { fixture.cleanup() }
        let driver = BackgroundDriverFixture()
        let background = MobileTransferBackgroundExecution(driver: driver)
        let queue = MobileFileUploadQueue(rootURL: fixture.root, backgroundExecution: background)
        queue.configure(profile: fixture.profile, repository: fixture.repository)
        try await ready(queue)
        for name in ["first.txt", "second.txt"] {
            let file = fixture.base.appendingPathComponent(name)
            try Data().write(to: file)
            await queue.prepare([file], destination: "/synthetic")
            await queue.submit(overwrite: false)
        }
        for _ in 0..<100 {
            if await fixture.transport.uploadCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let before = await fixture.transport.uploadCount
        XCTAssertEqual(before, 1)
        XCTAssertEqual(queue.batches.count, 2)
        await driver.limitedExpirations[0]()
        for batch in queue.batches { try await settled(batch) }
        XCTAssertTrue(queue.batches.allSatisfy(\.isPaused))
        XCTAssertTrue(queue.batches.allSatisfy { $0.entries.allSatisfy { $0.state == .paused } })
        XCTAssertEqual(driver.limited[0].completions, [false])
        XCTAssertTrue(background.modes.isEmpty)
        let restored = MobileFileUploadQueue(rootURL: fixture.root, backgroundExecution: background)
        restored.configure(profile: fixture.profile, repository: fixture.repository)
        try await ready(restored)
        XCTAssertEqual(restored.batches.count, 2)
        XCTAssertTrue(restored.batches.allSatisfy(\.isPaused))
        let writes = await fixture.transport.uploadCount
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(driver.jobs.count, 1)
    }

    func test上传完成归还后台资格且结果重启保留() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = fixture.base.appendingPathComponent("sample.txt")
        try Data().write(to: file)
        let driver = BackgroundDriverFixture()
        let background = MobileTransferBackgroundExecution(driver: driver)
        let queue = MobileFileUploadQueue(rootURL: fixture.root, backgroundExecution: background)
        queue.configure(profile: fixture.profile, repository: fixture.repository)
        try await ready(queue)
        await queue.prepare([file], destination: "/synthetic")
        await queue.submit(overwrite: false)
        let batch = try XCTUnwrap(queue.batches.first)
        let continuous = BackgroundLeaseFixture()
        driver.jobs[0].started(continuous)
        try await settled(batch)
        XCTAssertEqual(batch.entries.map(\.state), [.succeeded])
        XCTAssertEqual(continuous.completions, [true])
        XCTAssertTrue(background.modes.isEmpty)
        await driver.jobs[0].expiration()
        XCTAssertFalse(batch.isPaused)
        let restored = MobileFileUploadQueue(rootURL: fixture.root)
        restored.configure(profile: fixture.profile, repository: fixture.repository)
        try await ready(restored)
        XCTAssertEqual(restored.batches.first?.entries.map(\.state), [.succeeded])
    }

    func test后台上传切换账号停止旧网络且不启动旧队列() async throws {
        let fixture = try Fixture(uploadDelay: .seconds(30))
        defer { fixture.cleanup() }
        let file = fixture.base.appendingPathComponent("sample.txt")
        try Data().write(to: file)
        let driver = BackgroundDriverFixture()
        let background = MobileTransferBackgroundExecution(driver: driver)
        let queue = MobileFileUploadQueue(rootURL: fixture.root, backgroundExecution: background)
        queue.configure(profile: fixture.profile, repository: fixture.repository)
        try await ready(queue)
        await queue.prepare([file], destination: "/synthetic")
        await queue.submit(overwrite: false)
        for _ in 0..<100 {
            if await fixture.transport.uploadCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        queue.configure(profile: nil, repository: nil)
        try await ready(queue)
        XCTAssertTrue(queue.batches.isEmpty)
        XCTAssertTrue(background.modes.isEmpty)
        XCTAssertEqual(driver.limited[0].completions, [false])
        await driver.jobs[0].expiration()
        let writes = await fixture.transport.uploadCount
        XCTAssertEqual(writes, 1)
    }

    func test未开始批次可暂停且只有主动继续才提交() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = fixture.base.appendingPathComponent("sample.txt")
        try Data().write(to: file)
        let sources = try FileUploadPlan.collect([file])
        let batch = FileUploadBatch(sources: sources, destination: "/synthetic", overwrite: false, repository: fixture.repository)
        batch.pause()
        XCTAssertTrue(batch.isPaused)
        XCTAssertEqual(batch.entries.map(\.state), [.paused])
        batch.start()
        let before = await fixture.transport.uploadCount
        XCTAssertEqual(before, 0)
        batch.resume(); batch.start()
        try await settled(batch)
        let after = await fixture.transport.uploadCount
        XCTAssertEqual(after, 1)
        XCTAssertEqual(batch.entries.map(\.state), [.succeeded])
    }

    func test共享根或无效目标不能准备及提交上传() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = fixture.base.appendingPathComponent("sample.txt")
        try Data().write(to: file)
        let queue = MobileFileUploadQueue(rootURL: fixture.root)
        queue.configure(profile: fixture.profile, repository: fixture.repository)
        try await ready(queue)
        for destination in ["", "/", "relative", "/synthetic/../other"] {
            await queue.prepare([file], destination: destination)
            XCTAssertFalse(queue.isPresented)
            await queue.submit(overwrite: false)
        }
        XCTAssertTrue(queue.batches.isEmpty)
        let count = await fixture.transport.uploadCount
        XCTAssertEqual(count, 0)
    }

    func test目录上传保留空目录隐藏文件且跳过符号链接() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = fixture.base.appendingPathComponent("Selection")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(".hidden"))
        try Data().write(to: folder.appendingPathComponent("document.txt"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: folder)
        let queue = MobileFileUploadQueue(rootURL: fixture.root)
        queue.configure(profile: fixture.profile, repository: fixture.repository)
        try await ready(queue)
        await queue.prepare([folder], destination: "/synthetic")
        XCTAssertEqual(queue.sources.count, 5)
        await queue.submit(overwrite: false)
        let batch = try XCTUnwrap(queue.batches.first)
        try await settled(batch)
        XCTAssertEqual(batch.entries.filter { $0.state == .succeeded }.count, 4)
        XCTAssertEqual(batch.entries.filter { $0.state == .skipped }.count, 1)
        let uploads = await fixture.transport.uploadCount
        let folders = await fixture.transport.createdFolders
        XCTAssertEqual(uploads, 2)
        XCTAssertEqual(folders, ["Selection", "Selection/Empty"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("document.txt").path))
        XCTAssertTrue(batch.entries.filter { $0.source.kind == .file }.allSatisfy { $0.source.url.path.hasPrefix(fixture.root.path) })
        XCTAssertEqual(try fixture.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func test上传完成重启后保留逐项结果且不重复上传() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = fixture.base.appendingPathComponent("sample.txt")
        try Data().write(to: file)
        let first = MobileFileUploadQueue(rootURL: fixture.root)
        first.configure(profile: fixture.profile, repository: fixture.repository)
        try await ready(first)
        await first.prepare([file], destination: "/synthetic")
        await first.submit(overwrite: false)
        let original = try XCTUnwrap(first.batches.first)
        try await settled(original)
        let second = MobileFileUploadQueue(rootURL: fixture.root)
        second.configure(profile: fixture.profile, repository: fixture.repository)
        try await ready(second)
        let restored = try XCTUnwrap(second.batches.first)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.entries.map(\.state), [.succeeded])
        second.resume(restored)
        second.retryFailed(restored)
        let uploads = await fixture.transport.uploadCount
        XCTAssertEqual(uploads, 1)
        let copy = restored.entries[0].source.url
        second.removeFinished(restored)
        XCTAssertTrue(second.batches.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func test中断上传重启后只查询而不会自动发送() async throws {
        let fixture = try Fixture(failsUpload: true)
        defer { fixture.cleanup() }
        let file = fixture.base.appendingPathComponent("unknown.txt")
        try Data().write(to: file)
        let first = MobileFileUploadQueue(rootURL: fixture.root)
        first.configure(profile: fixture.profile, repository: fixture.repository)
        try await ready(first)
        await first.prepare([file], destination: "/synthetic")
        await first.submit(overwrite: false)
        let original = try XCTUnwrap(first.batches.first)
        try await settled(original)
        XCTAssertEqual(original.entries[0].state, .unverified)
        let second = MobileFileUploadQueue(rootURL: fixture.root)
        second.configure(profile: fixture.profile, repository: fixture.repository)
        try await ready(second)
        let restored = try XCTUnwrap(second.batches.first)
        await second.refresh(restored)
        second.resume(restored)
        second.retryFailed(restored)
        let uploads = await fixture.transport.uploadCount
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(restored.entries[0].state, .unverified)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.entries[0].source.url.path))
    }

    func test切换账号丢弃尚未确认的选择且不上传() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = fixture.base.appendingPathComponent("private.txt")
        try Data().write(to: file)
        let queue = MobileFileUploadQueue(rootURL: fixture.root)
        queue.configure(profile: fixture.profile, repository: fixture.repository)
        try await ready(queue)
        await queue.prepare([file], destination: "/synthetic")
        XCTAssertTrue(queue.isPresented)
        queue.configure(profile: nil, repository: nil)
        await queue.submit(overwrite: false)
        try await ready(queue)
        XCTAssertFalse(queue.isPresented)
        XCTAssertTrue(queue.sources.isEmpty)
        XCTAssertTrue(queue.batches.isEmpty)
        let uploads = await fixture.transport.uploadCount
        XCTAssertEqual(uploads, 0)
    }

    func test重复来源路径不会覆盖已有副本或发送重复目标() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.base.appendingPathComponent("one/same.txt")
        let second = fixture.base.appendingPathComponent("two/same.txt")
        for url in [first, second] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let queue = MobileFileUploadQueue(rootURL: fixture.root)
        queue.configure(profile: fixture.profile, repository: fixture.repository)
        try await ready(queue)
        await queue.prepare([first, second], destination: "/synthetic")
        await queue.submit(overwrite: true)
        let batch = try XCTUnwrap(queue.batches.first)
        XCTAssertEqual(batch.entries.map(\.state), [.conflict, .conflict])
        XCTAssertTrue(batch.entries.allSatisfy { !$0.retryAllowed })
        let uploads = await fixture.transport.uploadCount
        XCTAssertEqual(uploads, 0)
    }

    func test上传回读必须完整内容一致且不会发送第二次上传() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = fixture.base.appendingPathComponent("hash.txt")
        try Data().write(to: file)
        try await fixture.repository.upload(localURL: file, to: "/synthetic", overwrite: false) { _, _ in }
        let service = MobileFileTransferService(repository: fixture.repository)
        let request = MobileUploadRequest(profileID: fixture.profile.id, localURL: file,
            folderPath: "/synthetic", overwrite: false, stableTarget: "/synthetic/hash.txt")
        let matched = try await service.reviewUpload(request)
        XCTAssertEqual(matched?.status, .confirmedSuccess)
        await fixture.transport.setMD5("00000000000000000000000000000000")
        let mismatched = try await service.reviewUpload(request)
        XCTAssertNil(mismatched)
        let uploads = await fixture.transport.uploadCount
        XCTAssertEqual(uploads, 1)
    }

    func test恢复拒绝路径穿越和空路径() {
        for path in ["", "/absolute", "../escape", "a/../escape", "a//b", "a/./b"] {
            XCTAssertFalse(MobileFileUploadQueue.validRelativePath(path))
        }
        XCTAssertTrue(MobileFileUploadQueue.validRelativePath("资料/.hidden"))
    }

    private func ready(_ queue: MobileFileUploadQueue) async throws {
        for _ in 0..<100 where queue.isConfiguring { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(queue.isConfiguring)
    }
    private func settled(_ batch: FileUploadBatch) async throws {
        for _ in 0..<300 where batch.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(batch.isRunning)
    }
    private struct Fixture {
        let base: URL
        let root: URL
        let profile: NasProfile
        let transport: MobileUploadQueueTransport
        let repository: DsmFileRepository
        init(failsUpload: Bool = false, uploadDelay: Duration = .milliseconds(40)) throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-upload-\(UUID().uuidString)")
            root = base.appendingPathComponent("Queue")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            profile = try NasProfile(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
            transport = MobileUploadQueueTransport(failsUpload: failsUpload, uploadDelay: uploadDelay)
            let names = [DsmAPIName.fileStationList, DsmAPIName.fileStationUpload, DsmAPIName.fileStationCheckPermission, DsmAPIName.fileStationCreateFolder, DsmAPIName.fileStationMD5]
            let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: names.map {
                ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .form, selectedVersion: 2))
            }))
            repository = try DsmFileRepository(profile: profile, capabilities: capabilities,
                session: AuthSession(sid: "fixture-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        }
        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }
}

private actor MobileUploadQueueTransport: DsmBinaryHTTPTransport {
    var existing: [String: Bool]
    private var md5 = "d41d8cd98f00b204e9800998ecf8427e"
    func setMD5(_ value: String) { md5 = value }
    let failsUpload: Bool
    let uploadDelay: Duration
    private(set) var uploadCount = 0
    private(set) var createdFolders: [String] = []
    private var concurrent = 0
    private(set) var maximumConcurrent = 0
    init(existing: [String: Bool] = [:], failsUpload: Bool = false, uploadDelay: Duration = .milliseconds(40)) {
        self.existing = existing; self.failsUpload = failsUpload; self.uploadDelay = uploadDelay
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let fields = URLComponents(string: "?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!
            .replacingOccurrences(of: "+", with: "%20"))?.queryItems ?? []
        let parameters = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
        let method = parameters["method"]
        if parameters["api"] == DsmAPIName.fileStationMD5 {
            if method == "start" { return try response(["taskid": "fixture-md5"]) }
            if method == "status" { return try response(["finished": true, "md5": md5]) }
        }
        if method == "write" { return try response([:]) }
        if method == "getinfo" {
            let paths = try JSONDecoder().decode([String].self, from: Data((parameters["path"] ?? "[]").utf8))
            return try response(["files": paths.compactMap { path -> [String: Any]? in
                let relative = String(path.dropFirst("/synthetic/".count))
                if path == "/synthetic" { return item(path, directory: true) }
                guard let directory = existing[relative] else { return nil }
                return item(path, directory: directory)
            }])
        }
        if method == "create", let folder = parameters["folder_path"], let name = parameters["name"] {
            let relative = String((folder + "/" + name).dropFirst("/synthetic/".count))
            existing[relative] = true; createdFolders.append(relative)
            return try response([:])
        }
        guard method == "list" else { throw URLError(.unsupportedURL) }
        let children = existing.filter { (("/synthetic/" + $0.key) as NSString).deletingLastPathComponent == parameters["folder_path"] }
        return try response(["offset": 0, "total": children.count,
            "files": children.map { item("/synthetic/" + $0.key, directory: $0.value) }])
    }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        uploadCount += 1; concurrent += 1; maximumConcurrent = max(concurrent, maximumConcurrent)
        defer { concurrent -= 1 }
        try await Task.sleep(for: uploadDelay)
        if failsUpload { throw URLError(.timedOut) }
        let body = try String(contentsOf: bodyFileURL, encoding: .utf8)
        let marker = "filename=\""
        guard let start = body.range(of: marker)?.upperBound, let end = body[start...].firstIndex(of: "\"") else { throw URLError(.badServerResponse) }
        let pathMarker = "name=\"path\"\r\n\r\n"
        guard let pathStart = body.range(of: pathMarker)?.upperBound,
              let pathEnd = body[pathStart...].range(of: "\r\n")?.lowerBound else { throw URLError(.badServerResponse) }
        let path = String(body[pathStart..<pathEnd]) + "/" + String(body[start..<end])
        existing[String(path.dropFirst("/synthetic/".count))] = false
        return try response([:])
    }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { throw URLError(.unsupportedURL) }
    private func item(_ path: String, directory: Bool) -> [String: Any] {
        ["name": (path as NSString).lastPathComponent, "path": path, "isdir": directory,
         "additional": ["size": 0, "perm": ["adv_right": ["write": true, "read": true]]]]
    }
    private func response(_ data: [String: Any]) throws -> DsmHTTPResponse {
        DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
}

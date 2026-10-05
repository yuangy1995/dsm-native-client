@testable import DsmMobile
import DsmCore
import DsmLocalization
import DsmNetwork
import Foundation
import XCTest

@MainActor
final class MobileDownloadCreationTests: XCTestCase {
    private let uri = "https://synthetic:secret@files.example.invalid/task?key=private"
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadCreationTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func profile(_ username: String = "synthetic") throws -> NasProfile { try .init(displayName: "合成", host: "nas.example.invalid", port: 5001, usernameHint: username) }
    private func repository(_ transport: CreationMobileTransport, profile: NasProfile, version: Int = 3) throws -> DsmServiceManagementRepository {
        try .init(profile: profile, capabilities: CapabilitySet([
            DsmAPIName.downloadStationTask: .init(name: DsmAPIName.downloadStationTask, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version)]),
            session: .init(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func model(_ root: URL, transport: CreationMobileTransport, profile: NasProfile? = nil, version: Int = 3) throws -> MobileDownloadsModel {
        let profile = try profile ?? self.profile(), model = MobileDownloadsModel(transferCoordinator: MobileTransferCoordinator(), controlRoot: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile, version: version))
        model.downloadSnapshot = .init(source: .official, tasks: [], defaultDestination: "synthetic-downloads", isComplete: true)
        return model
    }
    private func create(_ model: MobileDownloadsModel, uri: String? = nil) async {
        model.createDownloadTask(uri: uri ?? self.uri); await model.downloadCreateTask?.value
    }
    func test草稿创建本身不写入且显式目录与NAS默认分别提交() async throws {
        let transport = CreationMobileTransport(), model = try model(root(), transport: transport)
        let draft = MobileDownloadCreateDraft(activation: model.editActivation, source: .link(uri))
        XCTAssertTrue(model.createEntries.isEmpty); XCTAssertNil(model.downloadCreateTask)
        var calls = await transport.writes; XCTAssertTrue(calls.isEmpty)
        model.createDownloadTask(draft: draft, uri: uri, destination: " shared/folder ", unzipPassword: "ignored")
        await model.downloadCreateTask?.value
        calls = await transport.writes; XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls[0]["destination"], " shared/folder ")
        XCTAssertNil(calls[0]["unzip_password"])
        model.createDownloadTask(draft: draft, uri: uri, destination: nil, unzipPassword: "")
        await model.downloadCreateTask?.value
        calls = await transport.writes; XCTAssertEqual(calls.count, 2); XCTAssertNil(calls[1]["destination"])
        model.deactivate()
    }
    func test旧草稿不能跨账号或同账号重连且无效目录不提交() async throws {
        let profile = try profile(), first = CreationMobileTransport(), model = try model(root(), transport: first, profile: profile)
        let draft = MobileDownloadCreateDraft(activation: model.editActivation, source: .link(uri))
        model.createDownloadTask(draft: draft, uri: uri, destination: "../wrong", unzipPassword: "")
        XCTAssertNil(model.downloadCreateTask)
        for nextProfile in [profile, try self.profile("other")] {
            let next = CreationMobileTransport()
            model.configure(profile: nextProfile, repository: try repository(next, profile: nextProfile))
            model.createDownloadTask(draft: draft, uri: uri, destination: nil, unzipPassword: "")
            XCTAssertNil(model.downloadCreateTask); XCTAssertNil(model.downloadCreateFeedback)
            XCTAssertTrue(model.createEntries.isEmpty); let calls = await next.writes; XCTAssertTrue(calls.isEmpty)
        }
        let calls = await first.writes; XCTAssertTrue(calls.isEmpty); model.deactivate()
    }
    func test文件表单保留目录及密码空格而记录与副本清理不泄露原值() async throws {
        let root = root(), transport = CreationMobileTransport(), model = try model(root, transport: transport)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Private input.torrent"), bytes = Data("synthetic content".utf8)
        try bytes.write(to: file)
        let draft = MobileDownloadCreateDraft(activation: model.editActivation, source: .file(file))
        model.createDownloadTask(draft: draft, uri: "", destination: " shared/folder ", unzipPassword: "  synthetic secret  ")
        await model.downloadCreateTask?.value
        XCTAssertEqual(model.downloadCreateFeedback?.kind, .success)
        let bodies = await transport.bodies, calls = await transport.writes
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls[0]["version"], "2")
        let body = try XCTUnwrap(String(data: XCTUnwrap(bodies.first), encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"destination\"\r\n\r\n shared/folder \r\n"))
        XCTAssertTrue(body.contains("name=\"unzip_password\"\r\n\r\n  synthetic secret  \r\n"))
        let saved = try String(contentsOf: root.appendingPathComponent("creations-v1.json"), encoding: .utf8)
        for value in ["synthetic secret", "shared/folder", "Private input", "synthetic content"] { XCTAssertFalse(saved.contains(value)) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("creation-inputs").path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), bytes); model.deactivate()
    }
    func test未知文件换密码和显式目录也不能重新提交() async throws {
        let root = root(), profile = try profile(), transport = CreationMobileTransport(unknown: true)
        let model = try model(root, transport: transport, profile: profile)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("input.torrent"); try Data("synthetic".utf8).write(to: file)
        model.createDownloadTask(draft: .init(activation: model.editActivation, source: .file(file)), uri: "", destination: "first", unzipPassword: "first-password")
        await model.downloadCreateTask?.value; model.deactivate()
        let restored = try self.model(root, transport: transport, profile: profile)
        restored.createDownloadTask(draft: .init(activation: restored.editActivation, source: .file(file)), uri: "", destination: "second", unzipPassword: "second-password")
        await restored.downloadCreateTask?.value
        XCTAssertEqual(restored.downloadCreateFeedback?.kind, .needsReview)
        XCTAssertEqual(restored.createEntries.count, 1); XCTAssertEqual(restored.createEntries.first?.phase, .submitted)
        let calls = await transport.writes; XCTAssertEqual(calls.count, 1); restored.deactivate()
    }
    func test任务文件已不可读取时不创建且提示重新选择输入() async throws {
        let root = root(), transport = CreationMobileTransport(), model = try model(root, transport: transport)
        model.createDownloadTask(draft: .init(activation: model.editActivation, source: .file(root.appendingPathComponent("missing.torrent"))),
                                 uri: "", destination: nil, unzipPassword: "synthetic-secret")
        await model.downloadCreateTask?.value
        XCTAssertEqual(model.downloadCreateFeedback?.kind, .failure)
        XCTAssertEqual(model.createErrorKey, "shared.51bdbefbc0c88421")
        XCTAssertTrue(model.createEntries.isEmpty); XCTAssertFalse(model.createRecovery.failed)
        let calls = await transport.writes; XCTAssertTrue(calls.isEmpty); model.deactivate()
    }
    func test搜索结果格式错误提示重试搜索而非文件上传失败() async throws {
        let name = DsmAPIName.downloadStationBTSearch
        let repo = try DsmServiceManagementRepository(profile: profile(), capabilities: CapabilitySet([
            name: .init(name: name, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form, selectedVersion: 1)]),
            session: .init(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false),
            transport: MobileDownloadUITransport(state: "downloads-create-bt-invalid"))
        let search = MobileDownloadBTSearchModel(); search.activate(repository: repo)
        var deadline = Date().addingTimeInterval(2)
        while search.isLoadingCatalog && Date() < deadline { await Task.yield() }
        search.keyword = "synthetic"; XCTAssertTrue(search.canSearch); search.search()
        deadline = Date().addingTimeInterval(2)
        while search.isSearching && Date() < deadline { await Task.yield() }
        XCTAssertFalse(search.isSearching); XCTAssertTrue(search.results.isEmpty)
        XCTAssertEqual(search.errorMessage, L10n.string("mobile.downloads.bt-search.search.error")); search.close()
    }
    func test官方空回执保存后显示已添加且重启保留记录() async throws {
        let root = root(), profile = try profile(), transport = CreationMobileTransport(), model = try model(root, transport: transport, profile: profile)
        await create(model)
        XCTAssertEqual(model.downloadCreateFeedback?.kind, .success)
        XCTAssertEqual(model.createEntries.map(\.phase), [.accepted])
        let calls = await transport.writes; XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls[0]["version"], "3")
        let restored = try self.model(root, transport: transport, profile: profile)
        XCTAssertEqual(restored.createEntries.map(\.phase), [.accepted])
        let text = try String(contentsOf: root.appendingPathComponent("creations-v1.json"), encoding: .utf8)
        for value in ["files.example.invalid", "REDACTED_SESSION", "secret", "private", "synthetic-downloads", "nas.example.invalid"] { XCTAssertFalse(text.contains(value)) }
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let id = try XCTUnwrap(restored.createEntries.first?.id); restored.removeDownloadCreation(id)
        XCTAssertTrue(restored.createEntries.isEmpty); XCTAssertTrue(MobileDownloadCreateStore(root: root).entries.isEmpty)
        model.deactivate(); restored.deactivate()
    }
    func test未知重启只读取且换目录也不能重发相同链接() async throws {
        let root = root(), profile = try profile(), transport = CreationMobileTransport(unknown: true)
        let first = try model(root, transport: transport, profile: profile); await create(first)
        XCTAssertEqual(first.createEntries.map(\.phase), [.submitted]); first.deactivate()
        let restored = try model(root, transport: transport, profile: profile)
        await restored.load(); XCTAssertEqual(restored.createEntries.map(\.phase), [.submitted])
        restored.downloadSnapshot = .init(source: .official, tasks: [], defaultDestination: "other", isComplete: true)
        await create(restored); XCTAssertEqual(restored.downloadCreateFeedback?.kind, .needsReview)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        let id = try XCTUnwrap(restored.createEntries.first?.id); restored.removeDownloadCreation(id)
        XCTAssertNotNil(restored.createRecovery.entry(id, context: try XCTUnwrap(restored.controlContext)))
        XCTAssertFalse(restored.createRecovery.failed); restored.deactivate()
    }
    func test真实文件副本发送完成清理且原输入不变() async throws {
        let root = root(), transport = CreationMobileTransport(), model = try model(root, transport: transport)
        let original = root.appendingPathComponent("Private original.torrent")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("d4:infod4:name9:syntheticee".utf8); try bytes.write(to: original)
        model.createDownloadTask(fileURL: original); await model.downloadCreateTask?.value
        XCTAssertEqual(model.downloadCreateFeedback?.kind, .success); XCTAssertEqual(model.createEntries.first?.source, .file)
        let bodies = await transport.bodies; XCTAssertEqual(bodies.count, 1); XCTAssertNotNil(bodies[0].range(of: bytes))
        XCTAssertFalse(String(data: bodies[0], encoding: .utf8)!.contains("Private original"))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("creation-inputs").path).isEmpty)
        model.deactivate()
    }
    func test未知文件改名换目录仍受保护但同大小不同内容允许添加() async throws {
        let root = root(), profile = try profile(), transport = CreationMobileTransport(unknown: true)
        let first = try model(root, transport: transport, profile: profile)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.torrent"), b = root.appendingPathComponent("b.torrent")
        try Data("AAAA".utf8).write(to: a); try Data("AAAA".utf8).write(to: b)
        first.createDownloadTask(fileURL: a); await first.downloadCreateTask?.value; first.deactivate()
        let restored = try model(root, transport: transport, profile: profile)
        restored.downloadSnapshot = .init(source: .official, tasks: [], defaultDestination: "other", isComplete: true)
        restored.createDownloadTask(fileURL: b); await restored.downloadCreateTask?.value
        var calls = await transport.writes; XCTAssertEqual(calls.count, 1); XCTAssertEqual(restored.downloadCreateFeedback?.kind, .needsReview)
        try Data("BBBB".utf8).write(to: b); await transport.setUnknown(false)
        restored.createDownloadTask(fileURL: b); await restored.downloadCreateTask?.value
        calls = await transport.writes; XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Set(restored.createEntries.map(\.phase)), [.submitted, .accepted]); restored.deactivate()
    }
    func test发送前记录写入失败零创建且损坏记录不覆盖() async throws {
        let root = root(), transport = CreationMobileTransport(), model = try model(root, transport: transport)
        try Data("occupied".utf8).write(to: root); await create(model)
        XCTAssertTrue(model.createRecovery.failed); XCTAssertEqual(model.createErrorKey, "download.edit.storage-error")
        let calls = await transport.writes; XCTAssertTrue(calls.isEmpty)
        let another = self.root(); try FileManager.default.createDirectory(at: another, withIntermediateDirectories: true)
        let url = another.appendingPathComponent("creations-v1.json"), bytes = Data("broken synthetic".utf8); try bytes.write(to: url)
        let orphan = another.appendingPathComponent("creation-inputs/orphan.torrent")
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic private input".utf8).write(to: orphan)
        let broken = try self.model(another, transport: transport); await create(broken)
        XCTAssertFalse(broken.canCreateDownloadTask); XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        model.deactivate(); broken.deactivate()
    }
    func test明确权限拒绝留失败记录且同来源可以重新尝试() async throws {
        let transport = CreationMobileTransport(code: 402), model = try model(root(), transport: transport)
        await create(model); XCTAssertEqual(model.createEntries.first?.phase, .failed); XCTAssertEqual(model.createEntries.first?.failure, .denied)
        await transport.setCode(nil); await create(model)
        XCTAssertEqual(model.downloadCreateFeedback?.kind, .success)
        let calls = await transport.writes; XCTAssertEqual(calls.count, 2); model.deactivate()
    }
    func test重复点击仅创建一次且旧账号迟到成功只写原记录() async throws {
        let root = root(), original = try profile(), transport = CreationMobileTransport(holdWrite: true)
        let model = try model(root, transport: transport, profile: original)
        model.createDownloadTask(uri: uri); let operation = model.downloadCreateTask
        await transport.waitForWrite(); model.createDownloadTask(uri: uri)
        let other = try profile("other")
        model.configure(profile: other, repository: try repository(CreationMobileTransport(), profile: other))
        XCTAssertTrue(model.createEntries.isEmpty); XCTAssertNil(model.downloadCreateFeedback)
        await transport.release(); await operation?.value
        XCTAssertTrue(model.createEntries.isEmpty); XCTAssertNil(model.downloadCreateFeedback)
        XCTAssertEqual(model.createRecovery.entries.map(\.phase), [.accepted])
        let calls = await transport.writes; XCTAssertEqual(calls.count, 1)
        model.configure(profile: original, repository: try repository(CreationMobileTransport(), profile: original))
        XCTAssertEqual(model.createEntries.map(\.phase), [.accepted]); model.deactivate()
    }
    func test同账号新连接不解除旧请求在途保护() async throws {
        let profile = try profile(), transport = CreationMobileTransport(holdWrite: true), model = try model(root(), transport: transport, profile: profile)
        model.createDownloadTask(uri: uri); let original = model.downloadCreateTask; await transport.waitForWrite()
        let next = CreationMobileTransport(); model.configure(profile: profile, repository: try repository(next, profile: profile))
        await create(model); XCTAssertEqual(model.downloadCreateFeedback?.kind, .needsReview)
        let calls = await next.writes; XCTAssertTrue(calls.isEmpty)
        await transport.release(); await original?.value
        XCTAssertEqual(model.createEntries.first?.phase, .accepted); XCTAssertEqual(model.downloadCreateFeedback?.kind, .needsReview)
        model.deactivate()
    }
    func test取消预检未发送不留未知记录() async throws {
        let transport = CreationMobileTransport(holdRead: true), model = try model(root(), transport: transport)
        model.createDownloadTask(uri: uri); let operation = model.downloadCreateTask; await transport.waitForRead()
        model.deactivate(); await transport.release(); await operation?.value
        XCTAssertTrue(model.createRecovery.entries.isEmpty); let calls = await transport.writes; XCTAssertTrue(calls.isEmpty)
    }
    func test回执保存失败保留提交记录并锁住创建() async throws {
        let root = root(), transport = CreationMobileTransport(holdWrite: true), model = try model(root, transport: transport)
        model.createDownloadTask(uri: uri); let operation = model.downloadCreateTask; await transport.waitForWrite()
        let url = root.appendingPathComponent("creations-v1.json")
        try FileManager.default.removeItem(at: url); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        await transport.release(); await operation?.value
        XCTAssertTrue(model.createRecovery.failed); XCTAssertEqual(model.createEntries.first?.phase, .submitted)
        XCTAssertFalse(model.canCreateDownloadTask); XCTAssertEqual(model.downloadCreateFeedback?.kind, .needsReview)
        model.deactivate()
    }
    func test任务文件副本不会在新存储实例初始化时删掉且重启遗留副本会清理() async throws {
        let root = root(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("input.torrent"); try Data("synthetic".utf8).write(to: source)
        let store = MobileDownloadCreateStore(root: root), copy = try await store.copyInput(source, id: UUID())
        _ = MobileDownloadCreateStore(root: root); XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        store.removeInput(copy); XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        let orphan = copy.deletingLastPathComponent().appendingPathComponent("orphan.torrent"); try Data("synthetic".utf8).write(to: orphan)
        _ = MobileDownloadCreateStore(root: root); XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func test系统支持时输入和发送副本使用完整文件保护() async throws {
        let root = root(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("input.torrent")
        try Data("synthetic".utf8).write(to: source, options: [.atomic, .completeFileProtection])
        #if targetEnvironment(simulator)
        // 独立系统写入也不返回此属性的模拟器不能证明锁屏保护；业务测试仍完整执行。
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: source.path)
        if try FileManager.default.attributesOfItem(atPath: source.path)[.protectionKey] == nil {
            throw XCTSkip("PENDING_USER_VALIDATION：模拟器独立写入不返回文件保护属性，需在两种真机验证创建输入与发送副本的锁屏保护；本项不能计作通过。")
        }
        #endif
        let store = MobileDownloadCreateStore(root: root), copy = try await store.copyInput(source, id: UUID())
        defer { store.removeInput(copy) }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: copy.path)[.protectionKey] as? String, FileProtectionType.complete.rawValue)
        let transport = CreationMobileTransport(), model = try model(root, transport: transport)
        model.createDownloadTask(fileURL: source); await model.downloadCreateTask?.value
        let protections = await transport.bodyProtections; XCTAssertEqual(protections, [FileProtectionType.complete.rawValue])
        model.deactivate()
    }
}

private actor CreationMobileTransport: DsmBinaryHTTPTransport {
    private var unknown: Bool, code: Int?, holdWrite: Bool, holdRead: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var reading = false
    private(set) var writes: [[String: String]] = []
    private(set) var bodies: [Data] = []
    private(set) var bodyProtections: [String?] = []
    init(unknown: Bool = false, code: Int? = nil, holdWrite: Bool = false, holdRead: Bool = false) {
        self.unknown = unknown; self.code = code; self.holdWrite = holdWrite; self.holdRead = holdRead
    }
    func setUnknown(_ value: Bool) { unknown = value }
    func setCode(_ value: Int?) { code = value }
    func waitForWrite() async { while writes.isEmpty || (holdWrite && gate == nil) { await Task.yield() } }
    func waitForRead() async { while !reading || (holdRead && gate == nil) { await Task.yield() } }
    func release() { holdWrite = false; holdRead = false; gate?.resume(); gate = nil }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let form = URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems ?? []
        let p = Dictionary((query + form).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
        if p["method"] == "create" {
            writes.append(p)
            if holdWrite { await withCheckedContinuation { gate = $0 } }
            if unknown { throw URLError(.timedOut) }
            if let code { return .init(data: Data("{\"success\":false,\"error\":{\"code\":\(code)}}".utf8), statusCode: 200) }
            return .init(data: Data(#"{"success":true}"#.utf8), statusCode: 200)
        }
        reading = true
        if holdRead { await withCheckedContinuation { gate = $0 } }
        return .init(data: Data(#"{"success":true,"data":{"tasks":[],"total":0,"offset":0}}"#.utf8), statusCode: 200)
    }
    func upload(_ request: URLRequest, from url: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        bodyProtections.append(try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? String)
        bodies.append(try Data(contentsOf: url)); return try await send(request)
    }
    func download(_ request: URLRequest, to url: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { throw URLError(.unsupportedURL) }
}

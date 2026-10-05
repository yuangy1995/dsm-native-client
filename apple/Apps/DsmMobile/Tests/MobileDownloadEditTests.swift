@testable import DsmMobile
import DsmCore
import DsmNetwork
import Foundation
import XCTest

@MainActor
final class MobileDownloadEditTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadEditTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func profile() throws -> NasProfile { try NasProfile(displayName: "合成设备", host: "nas.example.invalid", port: 5001, usernameHint: "synthetic") }
    private func model(_ root: URL, transport: DownloadEditTransport, profile: NasProfile? = nil, version: Int = 3) throws -> MobileDownloadsModel {
        let profile = try profile ?? self.profile(), model = MobileDownloadsModel(transferCoordinator: MobileTransferCoordinator(), controlRoot: root)
        let repository = try DsmServiceManagementRepository(profile: profile,
            capabilities: CapabilitySet([DsmAPIName.downloadStationTask: .init(name: DsmAPIName.downloadStationTask, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version)]),
            session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        model.configure(profile: profile, repository: repository)
        model.downloadSnapshot = .init(source: .official, tasks: tasks(), isComplete: true); return model
    }
    private func tasks() -> [DownloadStationTask] { ["one", "two", "three"].map { .init(id: $0, title: "Private synthetic \($0)", status: "downloading", sizeBytes: 4096, destination: "old") } }
    private func start(_ model: MobileDownloadsModel, destination: String = "new") throws -> UUID {
        try XCTUnwrap(model.startDownloadEdit(tasks(), destination: destination, activation: model.editActivation))
    }
    func test批量真实仓库逐项保存记录保护与重复提交() async throws {
        let root = root(), transport = DownloadEditTransport(), model = try model(root, transport: transport)
        _ = try start(model); let operation = model.downloadEditTask
        XCTAssertNil(model.startDownloadEdit(tasks(), destination: "elsewhere", activation: model.editActivation))
        XCTAssertFalse(model.canPauseDownloadTask(tasks()[0])); XCTAssertFalse(model.canDeleteDownloadTask(tasks()[0]))
        await operation?.value
        XCTAssertEqual(model.editEntries.first?.items.map(\.phase), [.complete, .complete, .complete])
        XCTAssertEqual(model.downloadSnapshot?.tasks.map(\.destination), ["new", "new", "new"])
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["id"] }, ["one", "two", "three"])
        XCTAssertTrue(writes.allSatisfy { $0["version"] == "2" && $0["destination"] == "new" })
        let restored = MobileDownloadEditStore(root: root); XCTAssertEqual(restored.entries.first?.items.map(\.phase), [.complete, .complete, .complete])
        let text = try String(contentsOf: root.appendingPathComponent("edits-v1.json"), encoding: .utf8)
        for value in ["Private synthetic", "nas.example.invalid", "REDACTED_SESSION", "synoToken", "\"synthetic\""] { XCTAssertFalse(text.contains(value)) }
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
    func test未知结果阻止后续项重启先读再由用户继续() async throws {
        let root = root(), profile = try profile(), transport = DownloadEditTransport(unknown: true)
        let first = try model(root, transport: transport, profile: profile), id = try start(first)
        await first.downloadEditTask?.value
        XCTAssertEqual(first.editEntries.first?.items.map(\.phase), [.submitted, .planned, .planned])
        XCTAssertFalse(first.canPauseDownloadTask(tasks()[0])); XCTAssertFalse(first.canDeleteDownloadTask(tasks()[0]))
        await transport.reconnect()
        let restored = try model(root, transport: transport, profile: profile)
        restored.runDownloadEdit(id, continuePlanned: true); await restored.downloadEditTask?.value
        XCTAssertEqual(restored.editEntries.first?.items.map(\.phase), [.complete, .planned, .planned])
        let count = await transport.writes.count; XCTAssertEqual(count, 1)
        restored.runDownloadEdit(id, continuePlanned: true); await restored.downloadEditTask?.value
        XCTAssertEqual(restored.editEntries.first?.items.map(\.phase), [.complete, .complete, .complete])
        let finalCount = await transport.writes.count; XCTAssertEqual(finalCount, 3)
    }
    func test取消未开始项目立即保存未知项保持只读() async throws {
        let root = root(), profile = try profile(), transport = DownloadEditTransport(unknown: true)
        let model = try model(root, transport: transport, profile: profile), id = try start(model)
        await model.downloadEditTask?.value; model.cancelRemainingDownloadEdits(id)
        XCTAssertEqual(MobileDownloadEditStore(root: root).entries.first?.items.map(\.phase), [.submitted, .cancelled, .cancelled])
        await transport.reconnect(); model.runDownloadEdit(id, continuePlanned: true); await model.downloadEditTask?.value
        XCTAssertEqual(model.editEntries.first?.items.map(\.phase), [.complete, .cancelled, .cancelled])
        let count = await transport.writes.count; XCTAssertEqual(count, 1)
    }
    func test逐项明确拒绝保留成功项目而不是误报全成全败() async throws {
        let transport = DownloadEditTransport(reject: "two"), model = try model(root(), transport: transport)
        _ = try start(model); await model.downloadEditTask?.value
        XCTAssertEqual(model.editEntries.first?.items.map(\.phase), [.complete, .failed, .complete])
        XCTAssertEqual(model.editEntries.first?.items[1].failure, .denied)
        XCTAssertEqual(model.downloadSnapshot?.tasks.map(\.destination), ["new", "old", "new"])
        let count = await transport.writes.count; XCTAssertEqual(count, 3)
    }
    func test写前任务已改变不修改新对象() async throws {
        let transport = DownloadEditTransport(changed: "one"), model = try model(root(), transport: transport)
        _ = try start(model); await model.downloadEditTask?.value
        XCTAssertEqual(model.editEntries.first?.items.map(\.phase), [.failed, .complete, .complete])
        XCTAssertEqual(model.editEntries.first?.items.first?.failure, .changed)
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["id"] }, ["two", "three"])
    }
    func test切换账号后迟到成功只结束原记录不污染新列表() async throws {
        let root = root(), transport = DownloadEditTransport(holdWrite: true), model = try model(root, transport: transport)
        let context = try XCTUnwrap(model.controlContext), id = try start(model), operation = model.downloadEditTask
        await transport.waitUntilHeld(); model.cancelRemainingDownloadEdits(id)
        model.deactivate(); await transport.release(); await operation?.value
        XCTAssertNil(model.activeProfile); XCTAssertNil(model.downloadSnapshot); XCTAssertNil(model.editErrorKey)
        let entry = MobileDownloadEditStore(root: root).entry(id, context: context)
        XCTAssertEqual(entry?.items.map(\.phase), [.submitted, .cancelled, .cancelled])
        let count = await transport.writes.count; XCTAssertEqual(count, 1)
    }
    func test同账号重连旧请求未结束仍不能执行恢复或新操作() async throws {
        let root = root(), profile = try profile(), transport = DownloadEditTransport(holdWrite: true)
        let first = try model(root, transport: transport, profile: profile), id = try start(first), operation = first.downloadEditTask
        await transport.waitUntilHeld()
        first.configure(profile: profile, repository: try model(self.root(), transport: transport, profile: profile).serviceRepository)
        first.runDownloadEdit(id, continuePlanned: true)
        XCTAssertNil(first.downloadEditTask); XCTAssertTrue(first.isEditingDownloadTask)
        await transport.release(); await operation?.value
        first.runDownloadEdit(id, continuePlanned: false); await first.downloadEditTask?.value
        XCTAssertEqual(first.editEntries.first?.items.map(\.phase), [.complete, .planned, .planned])
        let count = await transport.writes.count; XCTAssertEqual(count, 1)
    }
    func test写前读取期间取消剩余项零写且取消不会变成失败() async throws {
        let transport = DownloadEditTransport(holdRead: true), model = try model(root(), transport: transport), id = try start(model)
        await transport.waitUntilHeld(); model.cancelRemainingDownloadEdits(id); await transport.release(); await model.downloadEditTask?.value
        XCTAssertEqual(model.editEntries.first?.items.map(\.phase), [.cancelled, .cancelled, .cancelled]); XCTAssertNil(model.editErrorKey)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test存储损坏和无法写入都不得发送编辑() async throws {
        let root = root(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = Data("not valid data".utf8); try corrupt.write(to: root.appendingPathComponent("edits-v1.json"))
        let transport = DownloadEditTransport(), broken = try model(root, transport: transport)
        XCTAssertTrue(broken.editRecovery.failed); XCTAssertFalse(broken.canEditDownloadTask(tasks()[0]))
        XCTAssertNil(broken.startDownloadEdit(tasks(), destination: "new", activation: broken.editActivation))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("edits-v1.json")), corrupt)
        let blocked = self.root(); try Data().write(to: blocked)
        let full = try model(blocked, transport: transport)
        XCTAssertNil(full.startDownloadEdit(tasks(), destination: "new", activation: full.editActivation)); XCTAssertTrue(full.editRecovery.failed)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test现存控制记录与旧表单隔离阻止修改() async throws {
        let transport = DownloadEditTransport(), model = try model(root(), transport: transport)
        let context = try XCTUnwrap(model.controlContext)
        let entry = MobileDownloadControlStore.Entry(id: UUID(), context: context, createdAt: Date(), action: .pause,
            items: [MobileDownloadControlStore.Item(task: tasks()[0])])
        try model.controlRecovery.reserve(entry)
        XCTAssertFalse(model.canEditDownloadTask(tasks()[0]))
        XCTAssertNil(model.startDownloadEdit(tasks(), destination: "new", activation: model.editActivation))
        XCTAssertNil(model.startDownloadEdit([tasks()[1]], destination: "new", activation: UUID()))
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test未完成记录不可删除完成后可清理且同位置任务不发送() async throws {
        let transport = DownloadEditTransport(unknown: true), model = try model(root(), transport: transport)
        let id = try start(model); await model.downloadEditTask?.value
        model.removeDownloadEditRecord(id); XCTAssertEqual(model.editEntries.first?.id, id)
        model.cancelRemainingDownloadEdits(id); await transport.reconnect(); model.runDownloadEdit(id, continuePlanned: false); await model.downloadEditTask?.value
        model.removeDownloadEditRecord(id); XCTAssertTrue(model.editEntries.isEmpty)
        XCTAssertNil(model.startDownloadEdit([tasks()[1]], destination: "old", activation: model.editActivation))
        let count = await transport.writes.count; XCTAssertEqual(count, 1)
    }
    func test损坏重复占用与非法目录记录不覆盖既有文件() throws {
        let root = root(), store = MobileDownloadEditStore(root: root), context = String(repeating: "a", count: 64)
        let entry = MobileDownloadEditStore.Entry(id: UUID(), context: context, createdAt: Date(),
            items: [.init(change: .init(task: tasks()[0], destination: "new"))])
        try store.reserve(entry)
        let bytes = try Data(contentsOf: root.appendingPathComponent("edits-v1.json"))
        XCTAssertThrowsError(try store.reserve(entry))
        let invalid = MobileDownloadEditStore.Entry(id: UUID(), context: context, createdAt: Date(),
            items: [.init(change: .init(task: tasks()[1], destination: "../other"))])
        XCTAssertThrowsError(try store.reserve(invalid))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("edits-v1.json")), bytes)
    }
}

private actor DownloadEditTransport: DsmHTTPTransport {
    private(set) var writes: [[String: String]] = []
    private var destinations: [String: String] = [:]
    private var unknown: Bool
    private var offline = false
    private let reject: String?
    private let changed: String?
    private var holdWrite: Bool
    private var holdRead: Bool
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(unknown: Bool = false, reject: String? = nil, changed: String? = nil, holdWrite: Bool = false, holdRead: Bool = false) {
        self.unknown = unknown; self.reject = reject; self.changed = changed; self.holdWrite = holdWrite; self.holdRead = holdRead
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let data: Any
        switch fields["method"] {
        case "list":
            if holdRead { holdRead = false; await hold() }
            if offline { throw URLError(.notConnectedToInternet) }
            let tasks: [[String: Any]] = ["one", "two", "three"].map { id in
                ["id": id, "title": changed == id ? "Replaced synthetic" : "Private synthetic \(id)", "status": "downloading", "size": "4096",
                 "additional": ["detail": ["destination": destinations[id] ?? "old"]]]
            }
            data = ["tasks": tasks, "total": tasks.count, "offset": 0]
        case "edit":
            writes.append(fields)
            if holdWrite { holdWrite = false; await hold() }
            let id = fields["id"]!, code = id == reject ? 402 : 0
            if code == 0 { destinations[id] = fields["destination"]! }
            if unknown { unknown = false; offline = true; throw URLError(.timedOut) }
            data = [["id": id, "error": code]]
        default: throw URLError(.badServerResponse)
        }
        return .init(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
    func reconnect() { offline = false }
    private func hold() async {
        held = true; waiters.forEach { $0.resume() }; waiters = []
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilHeld() async { if !held { await withCheckedContinuation { waiters.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}

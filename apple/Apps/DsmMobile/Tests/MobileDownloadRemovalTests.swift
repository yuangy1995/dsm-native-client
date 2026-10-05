@testable import DsmMobile
import DsmCore
import DsmNetwork
import Foundation
import XCTest

@MainActor
final class MobileDownloadRemovalTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadRemovalTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func profile() throws -> NasProfile { try NasProfile(displayName: "合成设备", host: "nas.example.invalid", port: 5001, usernameHint: "synthetic") }
    private func tasks() -> [DownloadStationTask] { DownloadRemovalTransport.samples }
    private func model(_ root: URL, transport: DownloadRemovalTransport, profile: NasProfile? = nil) throws -> MobileDownloadsModel {
        let profile = try profile ?? self.profile(), model = MobileDownloadsModel(transferCoordinator: MobileTransferCoordinator(), controlRoot: root)
        model.configure(profile: profile, repository: try makeDownloadRemovalRepository(profile: profile, transport: transport))
        model.downloadSnapshot = .init(source: .official, tasks: tasks(), isComplete: true); return model
    }
    private func start(_ model: MobileDownloadsModel, force: Bool = false) throws -> UUID {
        try XCTUnwrap(model.startDownloadRemoval(tasks(), forceComplete: force, activation: model.editActivation))
    }
    func test两种动作逐项保存防重复与名称路径凭据不落盘() async throws {
        for force in [false, true] {
            let root = root(), transport = DownloadRemovalTransport(), model = try model(root, transport: transport)
            _ = try start(model, force: force); let operation = model.downloadDeleteTask
            XCTAssertNil(model.startDownloadRemoval(tasks(), forceComplete: !force, activation: model.editActivation))
            XCTAssertFalse(model.canPauseDownloadTask(tasks()[0])); XCTAssertFalse(model.canEditDownloadTask(tasks()[0]))
            await operation?.value
            XCTAssertEqual(model.removalEntries.first?.items.map(\.phase), [.complete, .complete, .complete])
            XCTAssertTrue(model.downloadSnapshot?.tasks.isEmpty == true)
            XCTAssertFalse(model.canPauseDownloadTask(tasks()[0])); XCTAssertFalse(model.canDeleteDownloadTask(tasks()[0]))
            XCTAssertFalse(model.canEditDownloadTask(tasks()[0]))
            let writes = await transport.writes; XCTAssertEqual(writes.map { $0["id"] }, ["one", "two", "three"])
            XCTAssertTrue(writes.allSatisfy { $0["version"] == "1" && $0["force_complete"] == (force ? "true" : "false") })
            XCTAssertEqual(MobileDownloadRemovalStore(root: root).entries.first?.items.map(\.phase), [.complete, .complete, .complete])
            let text = try String(contentsOf: root.appendingPathComponent("removals-v1.json"), encoding: .utf8)
            for value in ["Private synthetic", "private-folder", "nas.example.invalid", "REDACTED_SESSION", "synoToken", "\"synthetic\""] { XCTAssertFalse(text.contains(value)) }
            XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
    }
    func test未知重启只读恢复首项再明确继续其余() async throws {
        let root = root(), profile = try profile(), transport = DownloadRemovalTransport(unknown: true)
        let first = try model(root, transport: transport, profile: profile), id = try start(first)
        await first.downloadDeleteTask?.value
        XCTAssertEqual(first.removalEntries.first?.items.map(\.phase), [.submitted, .planned, .planned])
        XCTAssertFalse(first.canPauseDownloadTask(tasks()[0])); XCTAssertFalse(first.canEditDownloadTask(tasks()[0]))
        XCTAssertFalse(first.canDeleteDownloadTask(tasks()[0]))
        await transport.reconnect(); let restored = try model(root, transport: transport, profile: profile)
        restored.runDownloadRemoval(id, continuePlanned: true); await restored.downloadDeleteTask?.value
        XCTAssertEqual(restored.removalEntries.first?.items.map(\.phase), [.complete, .planned, .planned])
        let firstCount = await transport.writes.count; XCTAssertEqual(firstCount, 1)
        restored.runDownloadRemoval(id, continuePlanned: true); await restored.downloadDeleteTask?.value
        XCTAssertEqual(restored.removalEntries.first?.items.map(\.phase), [.complete, .complete, .complete])
        let count = await transport.writes.count; XCTAssertEqual(count, 3)
    }
    func test取消剩余项立即保存且已提交项重启不重发() async throws {
        let root = root(), transport = DownloadRemovalTransport(unknown: true), model = try model(root, transport: transport)
        let id = try start(model); await model.downloadDeleteTask?.value; model.cancelRemainingDownloadRemovals(id)
        XCTAssertEqual(MobileDownloadRemovalStore(root: root).entries.first?.items.map(\.phase), [.submitted, .cancelled, .cancelled])
        model.removeDownloadRemovalRecord(id); XCTAssertEqual(model.removalEntries.first?.id, id)
        await transport.reconnect(); model.runDownloadRemoval(id, continuePlanned: true); await model.downloadDeleteTask?.value
        XCTAssertEqual(model.removalEntries.first?.items.map(\.phase), [.complete, .cancelled, .cancelled])
        let count = await transport.writes.count; XCTAssertEqual(count, 1)
        model.removeDownloadRemovalRecord(id); XCTAssertTrue(model.removalEntries.isEmpty)
    }
    func test逐项权限拒绝保留准确的部分结果() async throws {
        let transport = DownloadRemovalTransport(reject: "two"), model = try model(root(), transport: transport)
        _ = try start(model); await model.downloadDeleteTask?.value
        XCTAssertEqual(model.removalEntries.first?.items.map(\.phase), [.complete, .failed, .complete])
        XCTAssertEqual(model.removalEntries.first?.items[1].failure, .denied)
        XCTAssertEqual(model.downloadSnapshot?.tasks.map(\.id), ["two"])
        let count = await transport.writes.count; XCTAssertEqual(count, 3)
    }
    func test原任务变更不移除同编号新对象且旧确认被拒绝() async throws {
        let transport = DownloadRemovalTransport(changed: "one"), model = try model(root(), transport: transport)
        XCTAssertNil(model.startDownloadRemoval(tasks(), forceComplete: false, activation: UUID()))
        let old = tasks()[0]
        model.replaceDownloadTask(.init(id: old.id, title: old.title, status: old.status, sizeBytes: old.sizeBytes, destination: "new-folder"))
        XCTAssertFalse(model.canDeleteDownloadTask(old))
        model.replaceDownloadTask(old); _ = try start(model); await model.downloadDeleteTask?.value
        XCTAssertEqual(model.removalEntries.first?.items.map(\.phase), [.failed, .complete, .complete])
        XCTAssertEqual(model.removalEntries.first?.items.first?.failure, .changed)
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["id"] }, ["two", "three"])
    }
    func test切换账号迟到结果只留原记录不污染新列表() async throws {
        let root = root(), transport = DownloadRemovalTransport(holdWrite: true), model = try model(root, transport: transport)
        let context = try XCTUnwrap(model.controlContext), id = try start(model), operation = model.downloadDeleteTask
        await transport.waitUntilHeld(); model.cancelRemainingDownloadRemovals(id); model.deactivate()
        await transport.release(); await operation?.value
        XCTAssertNil(model.activeProfile); XCTAssertNil(model.downloadSnapshot); XCTAssertNil(model.removalErrorKey)
        XCTAssertEqual(MobileDownloadRemovalStore(root: root).entry(id, context: context)?.items.map(\.phase), [.submitted, .cancelled, .cancelled])
        let count = await transport.writes.count; XCTAssertEqual(count, 1)
    }
    func test同账号重连在途记录不能再次执行() async throws {
        let root = root(), profile = try profile(), transport = DownloadRemovalTransport(holdWrite: true)
        let model = try model(root, transport: transport, profile: profile), id = try start(model), operation = model.downloadDeleteTask
        await transport.waitUntilHeld(); model.configure(profile: profile, repository: try makeDownloadRemovalRepository(profile: profile, transport: transport))
        model.runDownloadRemoval(id, continuePlanned: true)
        XCTAssertNil(model.downloadDeleteTask); XCTAssertTrue(model.isDeletingDownloadTask)
        await transport.release(); await operation?.value
        model.runDownloadRemoval(id, continuePlanned: false); await model.downloadDeleteTask?.value
        XCTAssertEqual(model.removalEntries.first?.items.map(\.phase), [.complete, .planned, .planned])
        let count = await transport.writes.count; XCTAssertEqual(count, 1)
    }
    func test提交前取消立即保存并保持零写() async throws {
        let transport = DownloadRemovalTransport(holdRead: true), model = try model(root(), transport: transport), id = try start(model)
        await transport.waitUntilHeld(); model.cancelRemainingDownloadRemovals(id)
        await transport.release(); await model.downloadDeleteTask?.value
        XCTAssertEqual(model.removalEntries.first?.items.map(\.phase), [.cancelled, .cancelled, .cancelled]); XCTAssertNil(model.removalErrorKey)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test存储损坏保留原字节无法保存不发送移除() async throws {
        let root = root(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = Data("invalid record".utf8); try corrupt.write(to: root.appendingPathComponent("removals-v1.json"))
        let transport = DownloadRemovalTransport(), broken = try model(root, transport: transport)
        XCTAssertTrue(broken.removalRecovery.failed); XCTAssertFalse(broken.canDeleteDownloadTask(tasks()[0]))
        XCTAssertFalse(broken.canPauseDownloadTask(tasks()[0])); XCTAssertFalse(broken.canEditDownloadTask(tasks()[0]))
        XCTAssertNil(broken.startDownloadRemoval(tasks(), forceComplete: false, activation: broken.editActivation))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("removals-v1.json")), corrupt)
        let blocked = self.root(); try Data().write(to: blocked)
        let full = try model(blocked, transport: transport)
        XCTAssertNil(full.startDownloadRemoval(tasks(), forceComplete: false, activation: full.editActivation)); XCTAssertTrue(full.removalRecovery.failed)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test已有编辑与控制记录阻止相同任务移除() throws {
        let transport = DownloadRemovalTransport(), model = try model(root(), transport: transport), context = try XCTUnwrap(model.controlContext)
        try model.controlRecovery.reserve(.init(id: UUID(), context: context, createdAt: Date(), action: .pause, items: [.init(task: tasks()[0])]))
        try model.editRecovery.reserve(.init(id: UUID(), context: context, createdAt: Date(), items: [.init(change: .init(task: tasks()[1], destination: "new"))]))
        XCTAssertFalse(model.canDeleteDownloadTask(tasks()[0])); XCTAssertFalse(model.canDeleteDownloadTask(tasks()[1]))
        XCTAssertTrue(model.canDeleteDownloadTask(tasks()[2]))
        XCTAssertNil(model.startDownloadRemoval(tasks(), forceComplete: false, activation: model.editActivation))
    }
    func test重复占用混合动作与非法身份均不能覆盖记录() throws {
        let root = root(), store = MobileDownloadRemovalStore(root: root), context = String(repeating: "a", count: 64)
        let entry = MobileDownloadRemovalStore.Entry(id: UUID(), context: context, createdAt: Date(), items: [.init(removal: .init(task: tasks()[0], forceComplete: false))])
        try store.reserve(entry); let bytes = try Data(contentsOf: root.appendingPathComponent("removals-v1.json"))
        XCTAssertThrowsError(try store.reserve(entry))
        let mixed = MobileDownloadRemovalStore.Entry(id: UUID(), context: context, createdAt: Date(), items: [
            .init(removal: .init(task: tasks()[1], forceComplete: true)), .init(removal: .init(task: tasks()[2], forceComplete: false))])
        XCTAssertThrowsError(try store.reserve(mixed))
        let invalid = MobileDownloadRemovalStore.Entry(id: UUID(), context: context, createdAt: Date(), items: [
            .init(removal: .init(task: .init(id: "one,two", title: "Synthetic", status: "finished"), forceComplete: false))])
        XCTAssertThrowsError(try store.reserve(invalid)); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("removals-v1.json")), bytes)
    }
}

func makeDownloadRemovalRepository(profile: NasProfile, transport: DownloadRemovalTransport) throws -> DsmServiceManagementRepository {
    try DsmServiceManagementRepository(profile: profile,
        capabilities: CapabilitySet([DsmAPIName.downloadStationTask: .init(name: DsmAPIName.downloadStationTask, path: "entry.cgi", minVersion: 1, maxVersion: 3, requestFormat: .form, selectedVersion: 3)]),
        session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
}
actor DownloadRemovalTransport: DsmHTTPTransport {
    static let samples: [DownloadStationTask] = ["one", "two", "three"].map { .init(id: $0, title: "Private synthetic \($0)", status: "downloading", sizeBytes: 4096, destination: "private-folder") }
    private(set) var writes: [[String: String]] = []
    private var tasks: [DownloadStationTask]
    private var unknown: Bool
    private var offline = false
    private let reject: String?
    private let changed: String?
    private var holdWrite: Bool
    private var holdRead: Bool
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(tasks: [DownloadStationTask] = samples, unknown: Bool = false, reject: String? = nil, changed: String? = nil, holdWrite: Bool = false, holdRead: Bool = false) {
        self.tasks = tasks; self.unknown = unknown; self.reject = reject; self.changed = changed; self.holdWrite = holdWrite; self.holdRead = holdRead
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let data: Any
        switch fields["method"] {
        case "list":
            if holdRead { holdRead = false; await hold() }
            if offline { throw URLError(.notConnectedToInternet) }
            let values: [[String: Any]] = tasks.map { task in
                var value: [String: Any] = ["id": task.id, "title": changed == task.id ? "Replaced synthetic" : task.title, "status": task.status]
                if let size = task.sizeBytes { value["size"] = size }
                if let destination = task.destination { value["additional"] = ["detail": ["destination": destination]] }
                return value
            }
            data = ["tasks": values, "total": values.count, "offset": 0]
        case "delete":
            writes.append(fields)
            if holdWrite { holdWrite = false; await hold() }
            let id = fields["id"]!, code = id == reject ? 402 : 0
            if code == 0 { tasks.removeAll { $0.id == id } }
            if unknown { unknown = false; offline = true; throw URLError(.timedOut) }
            data = [["id": id, "error": code]]
        default: throw URLError(.badServerResponse)
        }
        return .init(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
    func reconnect() { offline = false }
    private func hold() async { held = true; waiters.forEach { $0.resume() }; waiters = []; await withCheckedContinuation { continuation = $0 } }
    func waitUntilHeld() async { if !held { await withCheckedContinuation { waiters.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}

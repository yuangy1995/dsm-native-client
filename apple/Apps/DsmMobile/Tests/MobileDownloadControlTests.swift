@testable import DsmMobile
import DsmCore
import DsmNetwork
import Foundation
import XCTest

@MainActor
final class MobileDownloadControlTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadControlTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func makeModel(_ root: URL, tasks: [DownloadStationTask], profile: NasProfile? = nil) throws -> MobileDownloadsModel {
        let model = MobileDownloadsModel(transferCoordinator: MobileTransferCoordinator(), controlRoot: root)
        model.activeProfile = try profile ?? NasProfile(displayName: "合成设备", host: "nas.example.invalid", port: 5001, usernameHint: "synthetic")
        model.downloadSnapshot = .init(source: .official, tasks: tasks, isComplete: true)
        return model
    }
    private func task(_ id: String, status: String = "downloading", title: String = "合成文件") -> DownloadStationTask {
        .init(id: id, title: title, status: status, sizeBytes: 4096, destination: "synthetic-downloads")
    }

    func test批量逐项完成且磁盘只保存摘要不保存名称路径账号() async throws {
        let root = root(), tasks = [task("one", title: "Private synthetic name"), task("two")]
        let model = try makeModel(root, tasks: tasks), writer = DownloadControlTestWriter()
        model.downloadStationControlOverride = { try await writer.submit($0) }
        let id = try XCTUnwrap(model.startDownloadControlBatch(tasks, action: .pause))
        let operation = model.downloadControlTask
        XCTAssertNil(model.startDownloadControlBatch(tasks, action: .pause), "重复点击不能追加批次")
        await operation?.value
        let requests = await writer.requests
        XCTAssertEqual(requests.map(\.task.id), ["one", "two"])
        XCTAssertEqual(model.controlEntries.first?.items.map(\.phase), [.complete, .complete])
        XCTAssertEqual(model.downloadSnapshot?.tasks.map(\.status), ["paused", "paused"])
        let restored = MobileDownloadControlStore(root: root)
        XCTAssertEqual(restored.entries.first?.id, id)
        XCTAssertEqual(restored.entries.first?.items.map(\.phase), [.complete, .complete])
        let contents = try String(contentsOf: root.appendingPathComponent("controls-v1.json"), encoding: .utf8)
        for forbidden in ["Private synthetic name", "synthetic-downloads", "nas.example.invalid", "\"synthetic\"", "synoToken", "sid"] {
            XCTAssertFalse(contents.contains(forbidden), forbidden)
        }
    }

    func test未知结果停止批次重启继续按钮先只读再允许显式继续() async throws {
        let root = root(), tasks = [task("one"), task("two")]
        let first = try makeModel(root, tasks: tasks), writer = DownloadControlTestWriter(unknownIDs: ["one"])
        first.downloadStationControlOverride = { try await writer.submit($0) }
        let id = try XCTUnwrap(first.startDownloadControlBatch(tasks, action: .pause))
        await first.downloadControlTask?.value
        XCTAssertEqual(first.controlEntries.first?.items.map(\.phase), [.submitted, .planned])
        XCTAssertFalse(first.canPauseDownloadTask(tasks[0]))
        XCTAssertFalse(first.canDeleteDownloadTask(tasks[0]))

        let recoveredTasks = [task("one", status: "paused"), tasks[1]]
        let restored = try makeModel(root, tasks: recoveredTasks, profile: first.activeProfile), reads = DownloadControlTestReads(recoveredTasks)
        restored.downloadStationControlOverride = { try await writer.submit($0) }
        restored.downloadControlReadOverride = { await reads.read($0) }
        restored.runDownloadControlBatch(id, continuePlanned: true)
        await restored.downloadControlTask?.value
        XCTAssertEqual(restored.controlEntries.first?.items.map(\.phase), [.complete, .planned])
        let beforeContinue = await writer.requests, readIDs = await reads.ids
        XCTAssertEqual(beforeContinue.map(\.task.id), ["one"])
        XCTAssertEqual(readIDs, ["one"])
        restored.runDownloadControlBatch(id, continuePlanned: true)
        await restored.downloadControlTask?.value
        let afterContinue = await writer.requests
        XCTAssertEqual(afterContinue.map(\.task.id), ["one", "two"])
        XCTAssertEqual(restored.controlEntries.first?.items.map(\.phase), [.complete, .complete])
    }

    func test取消剩余操作保留当前已完成结果() async throws {
        let tasks = [task("one"), task("two")]
        let model = try makeModel(root(), tasks: tasks), writer = DownloadControlTestWriter(hold: true)
        model.downloadStationControlOverride = { try await writer.submit($0) }
        let id = try XCTUnwrap(model.startDownloadControlBatch(tasks, action: .pause))
        let operation = model.downloadControlTask
        await writer.waitUntilStarted()
        model.cancelRemainingDownloadControls(id)
        await writer.release(); await operation?.value
        let requests = await writer.requests
        XCTAssertEqual(requests.map(\.task.id), ["one"])
        XCTAssertEqual(model.controlEntries.first?.items.map(\.phase), [.complete, .cancelled])
        XCTAssertEqual(model.downloadTask(id: "one")?.status, "paused")
        XCTAssertEqual(model.downloadTask(id: "two")?.status, "downloading")
    }

    func test取消当前异步任务仍保留服务器返回的成功且不发送下一项() async throws {
        let tasks = [task("one"), task("two")]
        let model = try makeModel(root(), tasks: tasks), writer = DownloadControlTestWriter(hold: true)
        model.downloadStationControlOverride = { try await writer.submit($0) }
        _ = model.startDownloadControlBatch(tasks, action: .pause)
        let operation = model.downloadControlTask
        await writer.waitUntilStarted(); operation?.cancel()
        await writer.release(); await operation?.value
        XCTAssertEqual(model.controlEntries.first?.items.map(\.phase), [.complete, .planned])
        XCTAssertEqual(model.downloadControlFeedback?.kind, .success)
        let requests = await writer.requests; XCTAssertEqual(requests.count, 1)
    }

    func test切换账号迟到成功只结束原记录不覆盖新页面() async throws {
        let root = root(), tasks = [task("one"), task("two")]
        let model = try makeModel(root, tasks: tasks), writer = DownloadControlTestWriter(hold: true)
        let firstProfile = try XCTUnwrap(model.activeProfile), firstContext = try XCTUnwrap(model.controlContext)
        model.downloadStationControlOverride = { try await writer.submit($0) }
        let id = try XCTUnwrap(model.startDownloadControlBatch(tasks, action: .pause))
        let operation = model.downloadControlTask
        await writer.waitUntilStarted()
        let secondProfile = try NasProfile(id: firstProfile.id, displayName: "合成设备", host: "nas.example.invalid", port: 5001, usernameHint: "another")
        model.configure(profile: secondProfile, repository: nil)
        model.downloadSnapshot = .init(source: .official, tasks: [task("one", status: "finished", title: "New account")])
        await writer.release(); await operation?.value
        XCTAssertTrue(model.controlEntries.isEmpty)
        XCTAssertNil(model.downloadControlFeedback)
        XCTAssertEqual(model.downloadTask(id: "one")?.title, "New account")
        XCTAssertEqual(model.controlRecovery.entry(id, context: firstContext)?.items.map(\.phase), [.complete, .planned])
        let requests = await writer.requests; XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(model.controlRecovery.isExecuting(id))
    }

    func test重新选择不能绕过未知保护不同动作也受约束() async throws {
        let original = task("one"), model = try makeModel(root(), tasks: [task("one")])
        let writer = DownloadControlTestWriter(unknownIDs: ["one"])
        model.downloadStationControlOverride = { try await writer.submit($0) }
        _ = model.startDownloadControlBatch([original], action: .pause)
        await model.downloadControlTask?.value
        model.downloadSnapshot = .init(source: .official, tasks: [task("one", status: "paused")])
        XCTAssertFalse(model.canResumeDownloadTask(task("one", status: "paused")))
        XCTAssertNil(model.startDownloadControlBatch([task("one", status: "paused")], action: .resume))
        let id = try XCTUnwrap(model.controlEntries.first?.id)
        model.cancelRemainingDownloadControls(id); model.removeDownloadControlRecord(id)
        XCTAssertEqual(model.controlEntries.first?.items.first?.phase, .submitted)
        let requests = await writer.requests; XCTAssertEqual(requests.count, 1)
    }

    func test继续时原任务已被替换不会发送请求() async throws {
        let original = task("one"), model = try makeModel(root(), tasks: [task("one", title: "Changed task")])
        let entry = MobileDownloadControlStore.Entry(id: UUID(), context: try XCTUnwrap(model.controlContext), createdAt: Date(), action: .pause,
            items: [.init(task: original)])
        try model.controlRecovery.reserve(entry)
        let writer = DownloadControlTestWriter(); model.downloadStationControlOverride = { try await writer.submit($0) }
        model.runDownloadControlBatch(entry.id, continuePlanned: true); await model.downloadControlTask?.value
        XCTAssertEqual(model.controlEntries.first?.items.first?.phase, .failed)
        XCTAssertEqual(model.controlEntries.first?.items.first?.failure, .changed)
        let requests = await writer.requests; XCTAssertTrue(requests.isEmpty)
    }

    func test恢复读取同编号新内容不会把旧操作误报成功() async throws {
        let root = root(), original = task("one"), writer = DownloadControlTestWriter(unknownIDs: ["one"])
        let first = try makeModel(root, tasks: [original]); first.downloadStationControlOverride = { try await writer.submit($0) }
        let id = try XCTUnwrap(first.startDownloadControlBatch([original], action: .pause)); await first.downloadControlTask?.value
        let changed = task("one", status: "paused", title: "Changed task")
        let restored = try makeModel(root, tasks: [changed], profile: first.activeProfile), reads = DownloadControlTestReads([changed])
        restored.downloadControlReadOverride = { await reads.read($0) }
        restored.runDownloadControlBatch(id, continuePlanned: false); await restored.downloadControlTask?.value
        XCTAssertEqual(restored.controlEntries.first?.items.first?.failure, .changed)
        XCTAssertEqual(restored.downloadControlFeedback?.kind, .conflict)
        let requests = await writer.requests; XCTAssertEqual(requests.count, 1)
    }

    func test损坏记录和无法保存均阻止控制请求() async throws {
        for corrupt in [false, true] {
            let root = root()
            if corrupt {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("{invalid}".utf8).write(to: root.appendingPathComponent("controls-v1.json"))
            } else { try Data("file blocks directory".utf8).write(to: root) }
            let original = task("one"), model = try makeModel(root, tasks: [task("one")]), writer = DownloadControlTestWriter()
            model.downloadStationControlOverride = { try await writer.submit($0) }
            XCTAssertNil(model.startDownloadControlBatch([original], action: .pause))
            XCTAssertTrue(model.controlRecovery.failed)
            XCTAssertFalse(model.canDeleteDownloadTask(original))
            let requests = await writer.requests; XCTAssertTrue(requests.isEmpty)
        }
    }

    func test发送后异常保留记录且读取失败不能解除保护() async throws {
        let original = task("one"), model = try makeModel(root(), tasks: [task("one")])
        model.downloadStationControlOverride = { _ in throw URLError(.timedOut) }
        let id = try XCTUnwrap(model.startDownloadControlBatch([original], action: .pause)); await model.downloadControlTask?.value
        XCTAssertEqual(model.controlEntries.first?.items.first?.phase, .submitted)
        model.downloadControlReadOverride = { _ in throw URLError(.notConnectedToInternet) }
        model.runDownloadControlBatch(id, continuePlanned: false); await model.downloadControlTask?.value
        XCTAssertEqual(model.controlEntries.first?.items.first?.phase, .submitted)
        XCTAssertEqual(model.downloadControlFeedback?.kind, .needsReview)
        model.downloadControlReadOverride = { _ in throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "合成权限拒绝") }
        model.runDownloadControlBatch(id, continuePlanned: false); await model.downloadControlTask?.value
        XCTAssertEqual(model.controlEntries.first?.items.first?.phase, .submitted)
        XCTAssertEqual(model.controlErrorKey, "mobile.downloads.batch.denied")
    }

    func test明确拒绝记录逐项失败并继续其他项目() async throws {
        let tasks = [task("one"), task("two")], model = try makeModel(root(), tasks: [task("one"), task("two")])
        let writer = DownloadControlTestWriter(deniedIDs: ["one"])
        model.downloadStationControlOverride = { try await writer.submit($0) }
        _ = model.startDownloadControlBatch(tasks, action: .pause); await model.downloadControlTask?.value
        XCTAssertEqual(model.controlEntries.first?.items.map(\.phase), [.failed, .complete])
        XCTAssertEqual(model.controlEntries.first?.items.first?.failure, .denied)
        let requests = await writer.requests; XCTAssertEqual(requests.map(\.task.id), ["one", "two"])
    }

    func test真实仓储写前读到同编号不同内容时不发送控制() async throws {
        let original = task("one"), model = try makeModel(root(), tasks: [task("one")])
        let transport = DownloadControlSnapshotTransport(pages: [task("one", title: "Changed before send")])
        try attach(transport, to: model, tasks: [original])
        XCTAssertTrue(model.canDeleteDownloadTask(original))
        _ = model.startDownloadControlBatch([original], action: .pause); await model.downloadControlTask?.value
        XCTAssertEqual(model.controlEntries.first?.items.first?.failure, .changed)
        let methods = await transport.methods; XCTAssertEqual(methods, ["list"])
    }

    func test同一连接恢复结束后再次暂停会发送新请求() async throws {
        let original = task("one"), model = try makeModel(root(), tasks: [task("one")])
        let transport = DownloadControlSnapshotTransport(pages: [original, original, task("one", status: "paused"),
            original, task("one", status: "paused")])
        try attach(transport, to: model, tasks: [original])
        let first = try XCTUnwrap(model.startDownloadControlBatch([original], action: .pause)); await model.downloadControlTask?.value
        XCTAssertEqual(model.controlEntries.first?.items.first?.phase, .submitted)
        XCTAssertFalse(model.canDeleteDownloadTask(original))
        model.runDownloadControlBatch(first, continuePlanned: false); await model.downloadControlTask?.value
        XCTAssertEqual(model.controlEntries.first?.items.first?.phase, .complete)
        model.downloadSnapshot = .init(source: .official, tasks: [original], isComplete: true)
        let next = try XCTUnwrap(model.startDownloadControlBatch([original], action: .pause)); await model.downloadControlTask?.value
        XCTAssertNotEqual(first, next)
        XCTAssertEqual(model.controlEntries.first?.items.first?.phase, .complete)
        let methods = await transport.methods
        XCTAssertEqual(methods, ["list", "pause", "list", "list", "list", "pause", "list"])
    }

    func test取消剩余后切换账号不会丢失已保存的取消决定() async throws {
        let root = root(), tasks = [task("one"), task("two")], model = try makeModel(root, tasks: [task("one"), task("two")])
        let writer = DownloadControlTestWriter(hold: true), context = try XCTUnwrap(model.controlContext)
        model.downloadStationControlOverride = { try await writer.submit($0) }
        let id = try XCTUnwrap(model.startDownloadControlBatch(tasks, action: .pause)), operation = model.downloadControlTask
        await writer.waitUntilStarted(); model.cancelRemainingDownloadControls(id); model.deactivate()
        let storedBeforeReturn = MobileDownloadControlStore(root: root)
        XCTAssertEqual(storedBeforeReturn.entry(id, context: context)?.items.map(\.phase), [.submitted, .cancelled])
        await writer.release(); await operation?.value
        XCTAssertEqual(MobileDownloadControlStore(root: root).entry(id, context: context)?.items.map(\.phase), [.complete, .cancelled])
    }

    private func attach(_ transport: DownloadControlSnapshotTransport, to model: MobileDownloadsModel, tasks: [DownloadStationTask]) throws {
        let profile = try XCTUnwrap(model.activeProfile)
        let repository = try DsmServiceManagementRepository(profile: profile,
            capabilities: CapabilitySet([DsmAPIName.downloadStationTask: ApiCapability(name: DsmAPIName.downloadStationTask,
                path: "entry.cgi", minVersion: 1, maxVersion: 3, requestFormat: .form, selectedVersion: 1)]),
            session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        model.configure(profile: profile, repository: repository)
        model.downloadSnapshot = .init(source: .official, tasks: tasks, isComplete: true)
    }
}

private actor DownloadControlTestWriter {
    private(set) var requests: [DownloadTaskControlRequest] = []
    private let unknownIDs: Set<String>
    private let deniedIDs: Set<String>
    private var hold: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(unknownIDs: Set<String> = [], deniedIDs: Set<String> = [], hold: Bool = false) {
        self.unknownIDs = unknownIDs; self.deniedIDs = deniedIDs; self.hold = hold
    }
    func submit(_ request: DownloadTaskControlRequest) async throws -> DownloadTaskControlOutcome {
        requests.append(request); let waiting = waiters; waiters = []; waiting.forEach { $0.resume() }
        if hold { await withCheckedContinuation { continuation = $0 } }
        let unknown = unknownIDs.contains(request.task.id), denied = deniedIDs.contains(request.task.id)
        let status: MutationResultStatus = unknown ? .submittedButUnverified : (denied ? .permissionDenied : .confirmedSuccess)
        let result = try MutationResult(status: status, operation: "downloadPause", submitted: true, requiresRefresh: true,
            counts: .init(succeeded: unknown || denied ? 0 : 1, failed: denied ? 1 : 0, unknown: unknown ? 1 : 0),
            errorCategory: denied ? .permission : (unknown ? .network : nil))
        let task = request.task
        return .init(result: result, taskID: task.id, task: unknown || denied ? nil : .init(id: task.id, title: task.title,
            status: request.action == .pause ? "paused" : "downloading", sizeBytes: task.sizeBytes, destination: task.destination))
    }
    func waitUntilStarted() async { if requests.isEmpty { await withCheckedContinuation { waiters.append($0) } } }
    func release() { hold = false; continuation?.resume(); continuation = nil }
}
private actor DownloadControlTestReads {
    let tasks: [DownloadStationTask]
    private(set) var ids: [String] = []
    init(_ tasks: [DownloadStationTask]) { self.tasks = tasks }
    func read(_ id: String) -> DownloadStationTask? { ids.append(id); return tasks.first { $0.id == id } }
}

private actor DownloadControlSnapshotTransport: DsmHTTPTransport {
    private var pages: [DownloadStationTask]
    private(set) var methods: [String] = []
    init(pages: [DownloadStationTask]) { self.pages = pages }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let fields = URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems ?? []
        let method = fields.first { $0.name == "method" }?.value ?? ""
        methods.append(method)
        let data: [String: Any]
        if method == "list", !pages.isEmpty {
            let task = pages.removeFirst()
            data = ["tasks": [["id": task.id, "title": task.title, "status": task.status, "size": task.sizeBytes ?? 0,
                "additional": ["detail": ["destination": task.destination ?? ""]]]], "total": 1, "offset": 0]
        } else if method == "pause" || method == "resume" { data = [:] }
        else { throw URLError(.badServerResponse) }
        return .init(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
}

import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileNasStorageTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = self.roots; self.roots = []; return values }
        for root in values { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    func test检测启动与停止经过确认快照和持久记录() async throws {
        let (model, transport, _, _) = try makeModel()
        await model.refresh(); await model.refreshStatus("synthetic-disk")
        let quick = try XCTUnwrap(model.request(.quick, diskID: "synthetic-disk"))
        model.perform(quick, activation: model.activation)
        await wait {
            model.entries.first?.phase == .succeeded
                && model.statuses["synthetic-disk"]?.value?.runningType == .quick
                && model.statuses["synthetic-disk"]?.isRefreshing == false
        }
        XCTAssertEqual(model.statuses["synthetic-disk"]?.value?.runningType, .quick)
        let stop = try XCTUnwrap(model.request(.stop, diskID: "synthetic-disk"))
        model.perform(stop, activation: model.activation)
        await wait {
            model.entries.first?.action == .stop && model.entries.first?.phase == .succeeded
                && model.statuses["synthetic-disk"]?.value?.isRunning == false
                && model.statuses["synthetic-disk"]?.isRefreshing == false
        }
        XCTAssertEqual(model.statuses["synthetic-disk"]?.value?.isRunning, false)
        let writes = await transport.requests().filter { $0.method == "do_smart_test" }
        XCTAssertEqual(writes.map { $0.fields["type"] }, ["quick", "stop"])
        XCTAssertEqual(writes.map { $0.fields["device"] }, ["synthetic-device", "synthetic-device"])
    }

    func test重复点击只创建一次记录和请求() async throws {
        let (model, transport, _, _) = try makeModel()
        await model.refresh(); await model.refreshStatus("synthetic-disk")
        let change = try XCTUnwrap(model.request(.extended, diskID: "synthetic-disk")), token = model.activation
        model.perform(change, activation: token); model.perform(change, activation: token)
        await wait { model.entries.first?.phase == .succeeded }
        let writes = await transport.requests().filter { $0.method == "do_smart_test" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertNil(model.error)
    }

    func test确认后权限撤回零写且不保留可操作身份() async throws {
        let (model, transport, gate, _) = try makeModel()
        await model.refresh(); await model.refreshStatus("synthetic-disk")
        let change = try XCTUnwrap(model.request(.quick, diskID: "synthetic-disk"))
        await gate.set(false)
        model.perform(change, activation: model.activation)
        await wait { model.entries.first?.phase == .failed }
        XCTAssertEqual(model.entries.first?.failure, .denied)
        XCTAssertFalse(model.isAdministrator)
        let requests = await transport.requests()
        XCTAssertFalse(requests.contains { $0.method == "do_smart_test" })
    }

    func test确认后换盘零写且保留明确失败() async throws {
        let (model, transport, _, _) = try makeModel()
        await model.refresh(); await model.refreshStatus("synthetic-disk")
        let change = try XCTUnwrap(model.request(.quick, diskID: "synthetic-disk"))
        await transport.replaceDevice()
        model.perform(change, activation: model.activation)
        await wait { model.entries.first?.phase == .failed }
        let requests = await transport.requests()
        XCTAssertFalse(requests.contains { $0.method == "do_smart_test" })
        XCTAssertEqual(model.entries.first?.failure, .changed)
        await wait { model.statuses["synthetic-disk"]?.hasRefreshError == true }
        XCTAssertNil(model.request(.quick, diskID: "synthetic-disk"))
    }

    func test本机记录无法保存时不发检测请求() async throws {
        let root = makeRoot()
        try Data("synthetic-blocker".utf8).write(to: root)
        let (model, transport, _, _) = try makeModel(root: root)
        await model.refresh(); await model.refreshStatus("synthetic-disk")
        let change = try XCTUnwrap(model.request(.quick, diskID: "synthetic-disk"))
        model.perform(change, activation: model.activation)
        XCTAssertTrue(model.recovery.failed)
        XCTAssertEqual(model.error, .storage)
        let requests = await transport.requests()
        XCTAssertFalse(requests.contains { $0.method == "do_smart_test" })
    }

    func test写前保存失败保持零写而非未知提交() async throws {
        let root = makeRoot()
        let (model, transport, _, _) = try makeModel(root: root)
        await model.refresh(); await model.refreshStatus("synthetic-disk")
        let change = try XCTUnwrap(model.request(.quick, diskID: "synthetic-disk"))
        await transport.blockNext("get_smart_test_log")
        model.perform(change, activation: model.activation)
        await wait { await transport.requests().filter { $0.method == "get_smart_test_log" }.count >= 2 }
        let record = root.appendingPathComponent("disk-tests-v1.json")
        try FileManager.default.moveItem(at: record, to: root.appendingPathComponent("planned-record"))
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        await transport.release()
        await wait { model.recovery.failed }
        XCTAssertEqual(model.entries.first?.phase, .planned)
        let requests = await transport.requests()
        XCTAssertFalse(requests.contains { $0.method == "do_smart_test" })
    }

    func test未知启动跨重启只查询并保留精确类型() async throws {
        let root = makeRoot(), profile = try profile()
        let (model, transport, _, _) = try makeModel(root: root, profile: profile, mode: "nas-storage-unknown")
        await model.refresh(); await model.refreshStatus("synthetic-disk")
        model.perform(try XCTUnwrap(model.request(.quick, diskID: "synthetic-disk")), activation: model.activation)
        await wait { model.entries.first?.phase == .submitted && model.error == .pending }
        await wait { model.entries.first.map { !model.recovery.isExecuting($0.id) } == true }
        let stored = try String(contentsOf: root.appendingPathComponent("disk-tests-v1.json"), encoding: .utf8)
        for secret in ["synthetic-device", "synthetic-disk", "nas.example.invalid", "synthetic-user", "synthetic-session", "synthetic-serial", "synthetic-firmware"] {
            XCTAssertFalse(stored.contains(secret))
        }
        XCTAssertNil(model.request(.quick, diskID: "synthetic-disk"))
        let (reopened, reread, _, _) = try makeModel(root: root, profile: profile)
        await reread.setRunning(.extended)
        await reopened.refresh()
        XCTAssertEqual(reopened.entries.first?.phase, .submitted)
        XCTAssertNil(reopened.request(.stop, diskID: "synthetic-disk"))
        await reread.setRunning(.quick)
        await reopened.refreshStatus("synthetic-disk")
        XCTAssertEqual(reopened.entries.first?.phase, .succeeded)
        let writes = await transport.requests().filter { $0.method == "do_smart_test" }
        let recoveredCalls = await reread.requests()
        XCTAssertEqual(writes.count, 1)
        XCTAssertFalse(recoveredCalls.contains { $0.method == "do_smart_test" })
    }

    func test过期确认不改变新账号状态或写入() async throws {
        let (model, transport, _, _) = try makeModel()
        await model.refresh(); await model.refreshStatus("synthetic-disk")
        let change = try XCTUnwrap(model.request(.quick, diskID: "synthetic-disk")), oldToken = model.activation
        let other = try profile(), replacement = MobileNasStorageUITransport()
        let repos = try repositories(profile: other, transport: replacement)
        model.configure(profile: other, repository: repos.0, fileRepository: repos.1, authorize: { true })
        model.perform(change, activation: oldToken)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.error)
        let requests = await transport.requests() + replacement.requests()
        XCTAssertFalse(requests.contains { $0.method == "do_smart_test" })
    }

    func test同账号重连的迟到存储不覆盖新快照() async throws {
        let (model, transport, _, original) = try makeModel()
        await transport.blockNext("load_info")
        let old = Task { await model.refresh() }
        await wait { await transport.requests().contains { $0.method == "load_info" } }
        let replacement = MobileNasStorageUITransport(); await replacement.replaceDevice()
        let repos = try repositories(profile: original, transport: replacement)
        model.configure(profile: original, repository: repos.0, fileRepository: repos.1, authorize: { true })
        await model.refresh(); await transport.release(); await old.value
        XCTAssertEqual(model.storage.value?.disks.first?.deviceID, "replacement-device")
        XCTAssertTrue(model.statuses.isEmpty)
    }

    func test提交后退出保留原账号记录且不污染新账号() async throws {
        let (model, transport, _, _) = try makeModel()
        await model.refresh(); await model.refreshStatus("synthetic-disk")
        await transport.blockNext("do_smart_test")
        model.perform(try XCTUnwrap(model.request(.quick, diskID: "synthetic-disk")), activation: model.activation)
        await wait { await transport.requests().contains { $0.method == "do_smart_test" } }
        XCTAssertEqual(model.entries.first?.phase, .submitted)
        model.deactivate()
        let other = try profile(), replacement = MobileNasStorageUITransport()
        let repos = try repositories(profile: other, transport: replacement)
        model.configure(profile: other, repository: repos.0, fileRepository: repos.1, authorize: { true })
        await transport.release()
        await wait { model.recovery.entries.first.map { !model.recovery.isExecuting($0.id) } == true }
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.recovery.entries.first?.phase, .submitted)
    }

    func test分析复用共享引擎并保留缺少大小与重复文件() async throws {
        let (model, transport, _, _) = try makeModel()
        model.startAnalysis()
        await wait { !model.isAnalyzing }
        let report = try XCTUnwrap(model.analysis)
        XCTAssertEqual(report.scannedFileCount, 4)
        XCTAssertEqual(report.scannedBytes, 16384)
        XCTAssertEqual(report.unmeasuredFileCount, 1)
        XCTAssertEqual(report.shares.first?.unmeasuredFileCount, 1)
        XCTAssertEqual(report.categories.first(where: { $0.kind == .other })?.unmeasuredFileCount, 1)
        XCTAssertEqual(report.duplicateGroups.count, 1)
        XCTAssertEqual(report.duplicateGroups.first?.reclaimableBytes, 4096)
        let methods = await transport.requests().map(\.method)
        XCTAssertFalse(methods.contains("do_smart_test"))
    }

    func test分析取消不接收迟到报告() async throws {
        let (model, transport, _, _) = try makeModel()
        await transport.blockNext("list")
        model.startAnalysis()
        await wait { await transport.requests().contains { $0.method == "list" } }
        model.cancelAnalysis(); await transport.release()
        await wait { !model.isAnalyzing }
        XCTAssertNil(model.analysis)
        XCTAssertNil(model.analysisError)
        XCTAssertNil(model.analysisProgress)
    }

    func test分析失败可恢复而空结果不伪造失败() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-analysis-error")
        model.startAnalysis(); await wait { !model.isAnalyzing }
        XCTAssertNil(model.analysis)
        XCTAssertNotNil(model.analysisError)
        await transport.setMode("nas-analysis-empty")
        model.startAnalysis(); await wait { !model.isAnalyzing }
        XCTAssertEqual(model.analysis?.scannedFileCount, 0)
        XCTAssertNil(model.analysisError)
    }

    func test部分文件比较失败明确保留不完整状态() async throws {
        let (model, _, _, _) = try makeModel(mode: "nas-analysis-partial")
        model.startAnalysis(); await wait { !model.isAnalyzing }
        XCTAssertEqual(model.analysis?.failedDuplicateChecks, 2)
        XCTAssertEqual(model.analysis?.duplicateGroups.count, 0)
    }

    func test未完成共享分页不形成空报告() async throws {
        let (model, _, _, _) = try makeModel(mode: "nas-analysis-incomplete")
        model.startAnalysis(); await wait { !model.isAnalyzing }
        XCTAssertNil(model.analysis)
        XCTAssertNotNil(model.analysisError)
    }

    func test权限读取失败不冒报明确拒绝() async throws {
        let (model, _, permission, _) = try makeModel()
        await permission.setUnavailable(true)
        await model.refresh()
        XCTAssertFalse(model.isAdministrator)
        XCTAssertEqual(model.permissionError, .read)
        XCTAssertEqual(model.storage.phase, .content)
    }

    func test硬盘不支持检测时不试探检测接口() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-storage-no-smart")
        await model.refresh(); await model.refreshStatus("synthetic-disk")
        XCTAssertNil(model.request(.quick, diskID: "synthetic-disk"))
        let calls = await transport.requests()
        XCTAssertFalse(calls.contains { $0.api == DsmAPIName.coreStorageDisk })
    }

    func test历史时间使用App语言且不猜未知格式() {
        let en = Locale(identifier: "en_US"), zh = Locale(identifier: "zh_Hans")
        let iso = "2026-10-01T00:00:00Z"
        let date = ISO8601DateFormatter().date(from: iso)!
        let seconds = String(date.timeIntervalSince1970), milliseconds = String(date.timeIntervalSince1970 * 1000)
        let english = MobileNasStorageFormatting.historyTime(iso, locale: en)
        XCTAssertNotEqual(english, iso)
        XCTAssertNotEqual(english, MobileNasStorageFormatting.historyTime(iso, locale: zh))
        XCTAssertEqual(english, MobileNasStorageFormatting.historyTime(seconds, locale: en))
        XCTAssertEqual(english, MobileNasStorageFormatting.historyTime(milliseconds, locale: en))
        XCTAssertEqual(MobileNasStorageFormatting.historyTime("unrecognized original", locale: en), "unrecognized original")
        XCTAssertNil(MobileNasStorageFormatting.historyTime(nil))
    }

    func test损坏记录保留原文件并关闭写入() throws {
        let root = makeRoot(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("disk-tests-v1.json"), data = Data("invalid synthetic record".utf8)
        try data.write(to: file)
        let store = MobileNasDiskTestStore(root: root)
        XCTAssertTrue(store.failed)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func test未提交记录重启后取消而未知记录不能删除() throws {
        let root = makeRoot(), store = MobileNasDiskTestStore(root: root)
        let context = String(repeating: "a", count: 64), disk = String(repeating: "b", count: 64)
        let entry = try store.reserve(context: context, disk: disk, action: .quick)
        store.end(entry.id)
        let reopened = MobileNasDiskTestStore(root: root)
        XCTAssertEqual(reopened.entry(entry.id)?.phase, .cancelled)
        let pending = try reopened.reserve(context: context, disk: disk, action: .quick)
        try reopened.progress(pending.id, phase: .submitted); reopened.end(pending.id)
        XCTAssertThrowsError(try reopened.remove(pending.id, context: context))
        XCTAssertEqual(reopened.entry(pending.id)?.phase, .submitted)
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M6a2-\(UUID())")
        roots.append(root); return root
    }
    private func profile() throws -> NasProfile { try .init(displayName: "Synthetic", host: "nas.example.invalid", port: 5001, usernameHint: "synthetic-user") }
    private func makeModel(root: URL? = nil, profile: NasProfile? = nil, mode: String = "nas-storage") throws -> (MobileNasStorageModel, MobileNasStorageUITransport, StoragePermission, NasProfile) {
        let root = root ?? makeRoot(), profile = try profile ?? self.profile()
        let transport = MobileNasStorageUITransport(mode: mode), permission = StoragePermission()
        let repos = try repositories(profile: profile, transport: transport)
        let model = MobileNasStorageModel(root: root)
        model.configure(profile: profile, repository: repos.0, fileRepository: repos.1, authorize: { try await permission.read() })
        return (model, transport, permission, profile)
    }
    private func repositories(profile: NasProfile, transport: MobileNasStorageUITransport) throws -> (DsmNasAdministrationRepository, DsmFileRepository) {
        let names = [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk, DsmAPIName.fileStationList, DsmAPIName.fileStationSearch, DsmAPIName.fileStationMD5]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: names.map { name in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .form, selectedVersion: name.hasPrefix("SYNO.FileStation") ? 2 : 1))
        }))
        let session = AuthSession(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false)
        return (try DsmNasAdministrationRepository(profile: profile, capabilities: capabilities, session: session, transport: transport),
                try DsmFileRepository(profile: profile, capabilities: capabilities, session: session, transport: transport))
    }
    private func wait(_ condition: @escaping @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("合成流程未完成", file: file, line: line)
    }
}

private actor StoragePermission {
    private var allowed = true
    private var unavailable = false
    func set(_ allowed: Bool) { self.allowed = allowed }
    func setUnavailable(_ unavailable: Bool) { self.unavailable = unavailable }
    func read() throws -> Bool {
        if unavailable { throw URLError(.notConnectedToInternet) }
        return allowed
    }
}

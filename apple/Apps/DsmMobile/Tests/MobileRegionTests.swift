import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileRegionTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = self.roots; self.roots = []; return values }
        for root in values { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }
    func test普通格式保存不触发校时且完整更新页面() async throws {
        let (model, transport, _, _) = try makeModel(); await model.refresh()
        let change = try formatChange(model)
        let id = try XCTUnwrap(model.perform(change, activation: model.activation))
        await wait { !model.isOperating }
        XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded)
        XCTAssertEqual(model.settings.value?.timeFormat, "h:i a")
        let writes = await transport.requests().filter { ["set", "sync"].contains($0.method) }
        XCTAssertEqual(writes.map(\.method), ["set"])
    }
    func test网络服务器变化后保存和校时分别有接受回执() async throws {
        let (model, transport, _, _) = try makeModel(); await model.refresh()
        let original = try XCTUnwrap(model.settings.value); var desired = original; desired.timeServers = ["new.example.invalid"]
        let id = try XCTUnwrap(model.perform(.save(original: original, desired: desired, editsManualTime: false), activation: model.activation))
        await wait { !model.isOperating }
        let entry = try XCTUnwrap(model.recovery.entry(id))
        XCTAssertEqual(entry.phase, .succeeded); XCTAssertTrue(entry.saveAccepted); XCTAssertTrue(entry.syncAccepted)
        let calls = await transport.requests(); XCTAssertEqual(calls.filter { ["set", "sync"].contains($0.method) }.map(\.method), ["set", "sync"])
    }
    func test写前落盘只存摘要且再次点击不能重复提交() async throws {
        let (model, transport, _, root) = try makeModel(); await model.refresh(); let change = try formatChange(model)
        await transport.blockNext("set")
        let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await transport.waitFor("set")
        XCTAssertEqual(model.recovery.entry(id)?.phase, .saving)
        let text = try String(contentsOf: root.appendingPathComponent("region-operations-v1.json"), encoding: .utf8)
        for forbidden in ["time.example.invalid", "UTC", "date_format", "synthetic-user", "nas.example.invalid"] { XCTAssertFalse(text.contains(forbidden)) }
        XCTAssertNil(model.perform(change, activation: model.activation))
        await transport.release(); await wait { !model.isOperating }
        let calls = await transport.requests(); XCTAssertEqual(calls.filter { $0.method == "set" }.count, 1)
    }
    func test配置未知重启按原摘要恢复且不重放() async throws {
        let (model, transport, _, root) = try makeModel(mode: "nas-region-unknown"); await model.refresh()
        let id = try XCTUnwrap(model.perform(try formatChange(model), activation: model.activation))
        await wait { !model.isOperating }; XCTAssertEqual(model.recovery.entry(id)?.phase, .saving)
        model.deactivate()
        let (reopened, second, _, _) = try makeModel(mode: "nas-region-recover", root: root)
        await reopened.refresh(); XCTAssertEqual(reopened.recovery.entry(id)?.phase, .succeeded)
        let firstCalls = await transport.requests(), calls = await second.requests()
        XCTAssertEqual(firstCalls.filter { $0.method == "set" }.count, 1)
        XCTAssertTrue(calls.allSatisfy { ["get", "listzone"].contains($0.method) })
    }
    func test校时未知后新的明确校时只重试第二步() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-region-sync-timeout"); await model.refresh()
        let original = try XCTUnwrap(model.settings.value); var desired = original; desired.timeServers = ["new.example.invalid"]
        let first = try XCTUnwrap(model.perform(.save(original: original, desired: desired, editsManualTime: false), activation: model.activation))
        await wait { !model.isOperating }
        XCTAssertEqual(model.recovery.entry(first)?.phase, .partial); XCTAssertTrue(model.canEdit)
        await model.refresh()
        let before = await transport.requests(); XCTAssertEqual(before.filter { $0.method == "sync" }.count, 1)
        let second = try XCTUnwrap(model.perform(.synchronize(expected: try XCTUnwrap(model.settings.value)), activation: model.activation))
        await wait { !model.isOperating }; XCTAssertEqual(model.recovery.entry(second)?.phase, .succeeded)
        let calls = await transport.requests()
        XCTAssertEqual(calls.filter { $0.method == "set" }.count, 1); XCTAssertEqual(calls.filter { $0.method == "sync" }.count, 2)
    }
    func test手动改时缺少回执不能仅凭相同配置与近似时钟成功() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-region-manual-unknown"); await model.refresh()
        let original = try XCTUnwrap(model.settings.value); var desired = original; desired.manualDate = original.manualDate!.addingTimeInterval(60)
        let change = NasRegionChange.save(original: original, desired: desired, editsManualTime: true)
        let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await wait { !model.isOperating }
        await transport.setMode("nas-region-manual"); await model.refresh()
        XCTAssertEqual(model.recovery.entry(id)?.phase, .saving); XCTAssertFalse(model.canEdit)
        model.removeRecord(id); XCTAssertNotNil(model.recovery.entry(id))
        let calls = await transport.requests(); XCTAssertEqual(calls.filter { $0.method == "set" }.count, 1)
    }
    func test手动改时有回执但离线时恢复仍要比较时间() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-region-accepted-offline"); await model.refresh()
        let original = try XCTUnwrap(model.settings.value); var desired = original
        desired.isNetworkTimeEnabled = false; desired.manualDate = original.manualDate!.addingTimeInterval(3_600)
        let id = try XCTUnwrap(model.perform(.save(original: original, desired: desired, editsManualTime: true), activation: model.activation))
        await wait { !model.isOperating }; XCTAssertTrue(model.recovery.entry(id)?.saveAccepted == true)
        await transport.setMode("nas-region-manual"); await transport.changeClock(hour: 8); await model.refresh()
        XCTAssertEqual(model.recovery.entry(id)?.phase, .saving)
        await transport.changeClock(hour: 9); await model.refresh()
        XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded)
    }
    func test未编辑手动时间不回写打开页面时的旧小时() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-region-manual"); await model.refresh()
        let change = try formatChange(model); await transport.changeClock(hour: 18)
        _ = try XCTUnwrap(model.perform(change, activation: model.activation)); await wait { !model.isOperating }
        let write = await transport.requests().first { $0.method == "set" }; XCTAssertEqual(write?.fields["hour"], "18")
    }
    func test确认后权限撤回和设置变化均不写入() async throws {
        for denied in [true, false] {
            let (model, transport, gate, _) = try makeModel(); await model.refresh(); let change = try formatChange(model)
            if denied { await gate.set(false) } else { await transport.changeConfiguration() }
            let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await wait { !model.isOperating }
            XCTAssertEqual(model.recovery.entry(id)?.phase, .failed)
            XCTAssertEqual(model.recovery.entry(id)?.failure, denied ? .denied : .changed)
            let calls = await transport.requests(); XCTAssertFalse(calls.contains { ["set", "sync"].contains($0.method) })
        }
    }
    func test配置已保存后权限撤回不校时且保留第一步() async throws {
        let (model, transport, gate, _) = try makeModel(); await model.refresh()
        let original = try XCTUnwrap(model.settings.value); var desired = original; desired.timeServers = ["new.example.invalid"]
        await transport.blockNext("set")
        let id = try XCTUnwrap(model.perform(.save(original: original, desired: desired, editsManualTime: false), activation: model.activation))
        await transport.waitFor("set"); await gate.set(false); await transport.release(); await wait { !model.isOperating }
        XCTAssertEqual(model.recovery.entry(id)?.phase, .partial)
        XCTAssertEqual(model.settings.value?.timeServers, ["new.example.invalid"])
        let calls = await transport.requests(); XCTAssertFalse(calls.contains { $0.method == "sync" })
    }

    func test校时明确拒绝分别保留已保存配置和单独操作失败() async throws {
        for savesFirst in [true, false] {
            let (model, transport, _, _) = try makeModel(mode: "nas-region-sync-denied"); await model.refresh()
            let original = try XCTUnwrap(model.settings.value); var desired = original; desired.timeServers = ["new.example.invalid"]
            let change: NasRegionChange = savesFirst ? .save(original: original, desired: desired, editsManualTime: false) : .synchronize(expected: original)
            let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await wait { !model.isOperating }
            XCTAssertEqual(model.recovery.entry(id)?.phase, savesFirst ? .partial : .failed)
            XCTAssertEqual(model.recovery.entry(id)?.failure, .denied)
            let calls = await transport.requests(); XCTAssertEqual(calls.filter { $0.method == "set" }.count, savesFirst ? 1 : 0)
        }
    }
    func test恢复文件损坏或不可写均不修改NAS() async throws {
        for damaged in [true, false] {
            let root = makeRoot()
            if damaged {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("damaged".utf8).write(to: root.appendingPathComponent("region-operations-v1.json"))
            } else { try Data("blocker".utf8).write(to: root) }
            let (model, transport, _, _) = try makeModel(root: root); await model.refresh()
            XCTAssertNil(model.perform(try formatChange(model), activation: model.activation))
            let calls = await transport.requests(); XCTAssertTrue(calls.allSatisfy { ["get", "listzone"].contains($0.method) })
        }
    }
    func test取消读取与同配置重连丢弃迟到响应() async throws {
        let (model, transport, _, _) = try makeModel(); await transport.blockNext("get")
        let task = Task { await model.refresh() }; await transport.waitFor("get")
        let token = model.activation, other = MobileRegionUITransport(mode: "nas-region-recover"), profile = try profile()
        model.configure(profile: profile, repository: try repository(other, profile: profile), authorize: { true })
        await model.refresh(); await transport.release(); await task.value
        XCTAssertNotEqual(model.activation, token); XCTAssertEqual(model.settings.value?.timeFormat, "h:i a")
    }
    func test切换账号后的迟到回执只留在原账号记录() async throws {
        let (model, transport, _, root) = try makeModel(); await model.refresh(); await transport.blockNext("set")
        let id = try XCTUnwrap(model.perform(try formatChange(model), activation: model.activation)); await transport.waitFor("set")
        let next = try profile(username: "different"), second = MobileRegionUITransport()
        model.configure(profile: next, repository: try repository(second, profile: next), authorize: { true })
        await model.refresh(); await transport.release(); await wait { !model.recovery.isExecuting(id) }
        XCTAssertTrue(model.entries.isEmpty); XCTAssertEqual(model.settings.value?.timeFormat, "H:i")
        XCTAssertNotNil(MobileRegionOperationStore(root: root).entry(id))
    }
    func test空响应读取失败与不支持不伪造默认设置() async throws {
        for mode in ["nas-region-empty", "nas-region-error"] {
            let (model, _, _, _) = try makeModel(mode: mode); await model.refresh()
            XCTAssertEqual(model.settings.phase, .error); XCTAssertNil(model.settings.value); XCTAssertFalse(model.canEdit)
        }
        let (model, transport, _, _) = try makeModel(version: 2); await model.refresh()
        XCTAssertEqual(model.settings.phase, .unavailable); let calls = await transport.requests(); XCTAssertTrue(calls.isEmpty)
    }
    func test相同NAS墙上时间在不同设备时区下得到相同持久比较值() {
        func date(_ zone: String) -> Date {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
            return calendar.date(from: .init(year: 2026, month: 10, day: 5, hour: 8, minute: 15, second: 0))!
        }
        XCTAssertEqual(NasRegionChange.wallTime(date("Asia/Shanghai"), timeZone: TimeZone(identifier: "Asia/Shanghai")!),
            NasRegionChange.wallTime(date("America/New_York"), timeZone: TimeZone(identifier: "America/New_York")!))
    }
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileRegionTests-\(UUID())"); roots.append(root); return root
    }
    private func profile(username: String = "synthetic-user") throws -> NasProfile {
        try NasProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!, displayName: "Synthetic", host: "nas.example.invalid", port: 5001, usernameHint: username)
    }
    private func makeModel(mode: String = "nas-region", root: URL? = nil, version: Int = 3) throws -> (MobileRegionModel, MobileRegionUITransport, RegionPermissionGate, URL) {
        let root = root ?? makeRoot(), transport = MobileRegionUITransport(mode: mode), profile = try profile(), gate = RegionPermissionGate()
        let model = MobileRegionModel(root: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile, version: version), authorize: { await gate.allowed })
        return (model, transport, gate, root)
    }
    private func repository(_ transport: MobileRegionUITransport, profile: NasProfile, version: Int = 3) throws -> DsmNasAdministrationRepository {
        let capability = ApiCapability(name: DsmAPIName.coreRegionNTP, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version)
        return try DsmNasAdministrationRepository(profile: profile, capabilities: CapabilitySet([DsmAPIName.coreRegionNTP: capability]),
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func formatChange(_ model: MobileRegionModel) throws -> NasRegionChange {
        let original = try XCTUnwrap(model.settings.value); var desired = original; desired.timeFormat = "h:i a"
        return .save(original: original, desired: desired, editsManualTime: false)
    }
    private func wait(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 { if condition() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), "操作没有到达预期状态", file: file, line: line)
    }
}
private actor RegionPermissionGate {
    var allowed = true
    func set(_ value: Bool) { allowed = value }
}

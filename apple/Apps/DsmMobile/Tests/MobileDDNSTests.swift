import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileDDNSTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = self.roots; self.roots = []; return values }
        for root in values { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    func test测试保存更新和删除各执行自己的动作() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-ddns-empty")
        await model.refresh()
        let testID = try XCTUnwrap(model.perform(.test(original: nil, draft: draft()), activation: model.activation))
        await wait { model.recovery.entry(testID)?.phase == .succeeded && !model.isOperating }
        XCTAssertTrue(model.directory.value?.records.isEmpty == true)
        let saveID = try XCTUnwrap(model.perform(.save(original: nil, draft: draft()), activation: model.activation))
        await wait { model.recovery.entry(saveID)?.phase == .succeeded && !model.isOperating }
        let record = try XCTUnwrap(model.directory.value?.records.first)
        let updateID = try XCTUnwrap(model.perform(.updateAddress(providerIDs: [record.providerID]), activation: model.activation))
        await wait { model.recovery.entry(updateID)?.phase == .succeeded && !model.isOperating }
        let deleteID = try XCTUnwrap(model.perform(.delete(record), activation: model.activation))
        await wait { model.recovery.entry(deleteID)?.phase == .succeeded && !model.isOperating }
        XCTAssertTrue(model.directory.value?.records.isEmpty == true)
        let calls = await transport.requests()
        XCTAssertEqual(calls.filter { $0.method != "list" }.map(\.method), ["test", "create", "update_ip_address", "delete"])
    }

    func test写入之前记录已经持久保存且不含凭据和目标正文() async throws {
        let (model, transport, _, root) = try makeModel(mode: "nas-ddns-empty")
        await model.refresh(); await transport.blockNext("create")
        let id = try XCTUnwrap(model.perform(.save(original: nil, draft: draft()), activation: model.activation))
        await transport.waitFor("create")
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted)
        let text = try String(contentsOf: root.appendingPathComponent("ddns-operations-v1.json"), encoding: .utf8)
        for forbidden in ["Example", "created.example.invalid", "synthetic-user", "synthetic-only", "passwd", "hostname"] { XCTAssertFalse(text.contains(forbidden)) }
        await transport.release()
        await wait { model.recovery.entry(id)?.phase == .succeeded && !model.isOperating }
    }

    func test重复点击和同服务商其他动作不能绕过在途记录() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-ddns-empty")
        await model.refresh(); await transport.blockNext("create")
        let change = NasDDNSChange.save(original: nil, draft: draft())
        let id = try XCTUnwrap(model.perform(change, activation: model.activation))
        await transport.waitFor("create")
        XCTAssertNil(model.perform(change, activation: model.activation))
        XCTAssertFalse(model.canPerform(.test(original: nil, draft: draft())))
        XCTAssertEqual(model.entries.count, 1)
        await transport.release(); await wait { !model.recovery.isExecuting(id) }
        let calls = await transport.requests(); XCTAssertEqual(calls.filter { $0.method == "create" }.count, 1)
    }

    func test确认后权限撤回和记录变化均零写() async throws {
        for denied in [true, false] {
            let (model, transport, gate, _) = try makeModel()
            await model.refresh(); let record = try XCTUnwrap(model.directory.value?.records.first)
            if denied { await gate.set(false) } else { await transport.replaceRecord() }
            let id = try XCTUnwrap(model.perform(.delete(record), activation: model.activation))
            await wait { !model.recovery.isExecuting(id) }
            XCTAssertEqual(model.recovery.entry(id)?.phase, .failed)
            XCTAssertEqual(model.recovery.entry(id)?.failure, denied ? .denied : .changed)
            let calls = await transport.requests(); XCTAssertFalse(calls.contains { $0.method != "list" })
        }
    }

    func test结果未知后重启只读取原保存结果() async throws {
        let (model, transport, _, root) = try makeModel(mode: "nas-ddns-unknown-create")
        await model.refresh()
        let id = try XCTUnwrap(model.perform(.save(original: nil, draft: draft()), activation: model.activation))
        await wait { !model.recovery.isExecuting(id) }
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted)
        model.deactivate()
        let (reopened, second, _, _) = try makeModel(mode: "nas-ddns-recover", root: root)
        await reopened.refresh()
        XCTAssertEqual(reopened.recovery.entry(id)?.phase, .succeeded)
        let writes = await transport.requests().filter { $0.method == "create" }; XCTAssertEqual(writes.count, 1)
        let reads = await second.requests(); XCTAssertTrue(reads.allSatisfy { $0.method == "list" })
    }

    func test仅换密码没有回执不能用相同配置解除保护() async throws {
        let (model, _, _, root) = try makeModel(mode: "nas-ddns-unknown-save")
        await model.refresh(); let record = try XCTUnwrap(model.directory.value?.records.first)
        let change = NasDDNSChange.save(original: record, draft: draft(original: "Example", hostname: record.hostname))
        let id = try XCTUnwrap(model.perform(change, activation: model.activation))
        await wait { !model.recovery.isExecuting(id) }
        XCTAssertTrue(model.recovery.entry(id)?.needsCredentialAcknowledgement == true)
        model.deactivate()
        let (reopened, transport, _, _) = try makeModel(root: root)
        await reopened.refresh()
        XCTAssertEqual(reopened.recovery.entry(id)?.phase, .submitted)
        XCTAssertFalse(reopened.canPerform(change))
        reopened.removeRecord(id); XCTAssertNotNil(reopened.recovery.entry(id))
        let calls = await transport.requests(); XCTAssertTrue(calls.allSatisfy { $0.method == "list" })
    }

    func test已保存的成功回执可在重启后结束凭据操作() async throws {
        let (model, _, _, root) = try makeModel(mode: "nas-ddns-accepted-offline")
        await model.refresh(); let record = try XCTUnwrap(model.directory.value?.records.first)
        let change = NasDDNSChange.save(original: record, draft: draft(original: "Example", hostname: record.hostname))
        let id = try XCTUnwrap(model.perform(change, activation: model.activation))
        await wait { !model.recovery.isExecuting(id) }
        XCTAssertTrue(model.recovery.entry(id)?.accepted == true)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted)
        model.deactivate()
        let (reopened, _, _, _) = try makeModel(root: root)
        await reopened.refresh(); XCTAssertEqual(reopened.recovery.entry(id)?.phase, .succeeded)
    }

    func test瞬时动作结果未知只允许新的显式操作不自动重发() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-ddns-instant-unknown")
        await model.refresh(); let original = try XCTUnwrap(model.directory.value?.records.first)
        let change = NasDDNSChange.test(original: original, draft: draft(original: "Example", hostname: original.hostname))
        let id = try XCTUnwrap(model.perform(change, activation: model.activation))
        await wait { !model.recovery.isExecuting(id) }
        XCTAssertEqual(model.recovery.entry(id)?.phase, .unconfirmed)
        XCTAssertTrue(model.canPerform(change))
        await model.refresh()
        let calls = await transport.requests(); XCTAssertEqual(calls.filter { $0.method == "test" }.count, 1)
    }

    func test保存恢复信息失败不提交() async throws {
        let root = makeRoot(); try Data("synthetic-blocker".utf8).write(to: root)
        let (model, transport, _, _) = try makeModel(mode: "nas-ddns-empty", root: root)
        await model.refresh()
        XCTAssertNil(model.perform(.save(original: nil, draft: draft()), activation: model.activation))
        XCTAssertEqual(model.error, .storage)
        let calls = await transport.requests(); XCTAssertTrue(calls.allSatisfy { $0.method == "list" })
    }

    func test损坏恢复文件不能解锁写入() async throws {
        let root = makeRoot(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: root.appendingPathComponent("ddns-operations-v1.json"))
        let (model, transport, _, _) = try makeModel(mode: "nas-ddns-empty", root: root)
        await model.refresh()
        XCTAssertTrue(model.recovery.failed); XCTAssertFalse(model.canEdit)
        XCTAssertNil(model.perform(.save(original: nil, draft: draft()), activation: model.activation))
        let calls = await transport.requests(); XCTAssertTrue(calls.allSatisfy { $0.method == "list" })
    }

    func test取消读取后迟到响应不覆盖新会话() async throws {
        let (model, transport, _, _) = try makeModel()
        await transport.blockNext("list")
        let task = Task { await model.refresh() }
        await transport.waitFor("list")
        model.deactivate(); await transport.release(); await task.value
        XCTAssertNil(model.context); XCTAssertNil(model.directory.value); XCTAssertFalse(model.isAdministrator)
    }

    func test换账号后的迟到写结果只留在原记录() async throws {
        let (model, transport, _, root) = try makeModel(mode: "nas-ddns-empty")
        await model.refresh(); await transport.blockNext("create")
        let id = try XCTUnwrap(model.perform(.save(original: nil, draft: draft()), activation: model.activation))
        await transport.waitFor("create")
        let other = try profile(username: "different-user"), next = MobileDDNSUITransport(mode: "nas-ddns-empty")
        model.configure(profile: other, repository: try repository(next, profile: other), authorize: { true })
        await model.refresh(); await transport.release()
        await wait { !model.recovery.isExecuting(id) }
        XCTAssertTrue(model.entries.isEmpty); XCTAssertTrue(model.directory.value?.records.isEmpty == true)
        XCTAssertEqual(model.context, MobileWorkspaceIdentity(other).storageIdentifier)
        let saved = MobileDDNSOperationStore(root: root); XCTAssertNotNil(saved.entry(id))
        let calls = await next.requests(); XCTAssertTrue(calls.allSatisfy { $0.method == "list" })
    }

    func test明确拒绝保留失败且不会报保存成功() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-ddns-denied")
        await model.refresh(); let record = try XCTUnwrap(model.directory.value?.records.first)
        let id = try XCTUnwrap(model.perform(.delete(record), activation: model.activation))
        await wait { !model.recovery.isExecuting(id) }
        XCTAssertEqual(model.recovery.entry(id)?.phase, .failed)
        XCTAssertEqual(model.recovery.entry(id)?.failure, .denied)
        XCTAssertEqual(model.directory.value?.records.count, 1)
        let calls = await transport.requests(); XCTAssertEqual(calls.filter { $0.method == "delete" }.count, 1)
    }

    func test空列表读取失败与不完整响应分别表示() async throws {
        for (mode, phase) in [("nas-ddns-empty", MobileNasDetailsPhase.empty), ("nas-ddns-error", .error), ("nas-ddns-incomplete", .error)] {
            let (model, _, _, _) = try makeModel(mode: mode); await model.refresh()
            XCTAssertEqual(model.directory.phase, phase)
            XCTAssertEqual(model.canEdit, phase == .empty)
        }
    }

    private func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MobileDDNSTests-\(UUID())")
        roots.append(url); return url
    }
    private func profile(username: String = "synthetic-user") throws -> NasProfile {
        try NasProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!, displayName: "Synthetic", host: "nas.example.invalid", port: 5001, usernameHint: username)
    }
    private func makeModel(mode: String = "nas-ddns", root: URL? = nil) throws -> (MobileDDNSModel, MobileDDNSUITransport, DDNSPermissionGate, URL) {
        let root = root ?? makeRoot(), profile = try profile(), transport = MobileDDNSUITransport(mode: mode), gate = DDNSPermissionGate()
        let model = MobileDDNSModel(root: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile), authorize: { await gate.allowed })
        return (model, transport, gate, root)
    }
    private func repository(_ transport: MobileDDNSUITransport, profile: NasProfile) throws -> DsmNasAdministrationRepository {
        let names = [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: names.map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form, selectedVersion: 1)) }))
        return try DsmNasAdministrationRepository(profile: profile, capabilities: capabilities,
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func draft(original: String? = nil, hostname: String = "created.example.invalid") -> NasDDNSDraft {
        .init(originalProviderID: original, providerID: "Example", hostname: hostname, username: "synthetic-user", password: "synthetic-only")
    }
    private func wait(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 { if condition() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), "操作没有到达预期状态", file: file, line: line)
    }
}
private actor DDNSPermissionGate {
    var allowed = true
    func set(_ value: Bool) { allowed = value }
}

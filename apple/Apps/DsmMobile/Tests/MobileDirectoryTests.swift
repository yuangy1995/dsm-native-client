import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileDirectoryTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = self.roots; self.roots = []; return values }
        for root in values { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }
    func test账号和群组完整创建修改删除() async throws {
        let (model, transport, _, _) = try makeModel()
        await model.refresh()
        for user in [true, false] {
            let name = user ? "created-user" : "created-group"
            let create: NasDirectoryChange = user ? .saveUser(original: nil,
                draft: .init(name: name, description: "Created", email: "created@example.invalid", password: "synthetic-only", passwordConfirmation: "synthetic-only"), groups: nil)
                : .saveGroup(original: nil, draft: .init(name: name, description: "Created"))
            let created = try XCTUnwrap(model.perform(create, activation: model.activation)); await model.waitForOperation(created)
            XCTAssertFalse(model.isOperating)
            XCTAssertEqual(model.recovery.entry(created)?.phase, .succeeded)
            let original = try XCTUnwrap((user ? model.directory.value?.users : model.directory.value?.groups)?.first { $0.name == name })
            let edit: NasDirectoryChange = user ? .saveUser(original: original, draft: draft(original), groups: nil)
                : .saveGroup(original: original, draft: .init(originalName: name, name: name, description: "Updated group"))
            let edited = try XCTUnwrap(model.perform(edit, activation: model.activation)); await model.waitForOperation(edited)
            XCTAssertEqual(model.recovery.entry(edited)?.phase, .succeeded)
            let saved = try XCTUnwrap((user ? model.directory.value?.users : model.directory.value?.groups)?.first { $0.name == name })
            let deleted = try XCTUnwrap(model.perform(.delete(saved), activation: model.activation)); await model.waitForOperation(deleted)
            XCTAssertEqual(model.recovery.entry(deleted)?.phase, .succeeded)
        }
        let calls = await transport.requests(); XCTAssertEqual(calls.filter { $0.method != "list" }.map(\.method), ["create", "set", "delete", "create", "set", "delete"])
    }
    func test成员选择原组保留与明确新选择() async throws {
        let (model, transport, _, _) = try makeModel(); await model.refresh()
        let original = try original(model); var value = draft(original); value.groups = ["sample-team", "users"]
        let id = try XCTUnwrap(model.perform(.saveUser(original: original, draft: value, groups: model.directory.value?.groups), activation: model.activation))
        await wait { !model.isOperating }; XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded)
        XCTAssertEqual(try self.original(model).groups?.sorted(), ["sample-team", "users"])
        let calls = await transport.requests(); XCTAssertEqual(calls.first { $0.method == "set" }?.fields["groups"], "[\"sample-team\",\"users\"]")
    }
    func test未知所属组不会被空数组覆盖() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-directory-missing-groups"); await model.refresh()
        let original = try original(model); XCTAssertNil(original.groups)
        let id = try XCTUnwrap(model.perform(.saveUser(original: original, draft: draft(original), groups: nil), activation: model.activation))
        await wait { !model.isOperating }; XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded)
        let calls = await transport.requests(); XCTAssertNil(calls.first { $0.method == "set" }?.fields["groups"])
    }
    func test写前记录只含摘要且阻止同目标重复操作() async throws {
        let (model, transport, _, root) = try makeModel(); await model.refresh()
        let original = try original(model), change = NasDirectoryChange.saveUser(original: original, draft: draft(original, password: "synthetic-only"), groups: nil)
        await transport.blockNext("set")
        let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await transport.waitFor("set")
        XCTAssertNil(model.perform(change, activation: model.activation)); XCTAssertFalse(model.canPerform(.delete(original)))
        let text = try String(contentsOf: root.appendingPathComponent("directory-operations-v1.json"), encoding: .utf8)
        for word in ["sample-user", "member@example.invalid", "Updated account", "synthetic-only", "sample-team", "fixture.example.invalid"] { XCTAssertFalse(text.contains(word), word) }
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted)
        await transport.release(); await wait { !model.isOperating }
    }
    func test确认后权限撤销与对象替换均零写() async throws {
        for denied in [true, false] {
            let (model, transport, gate, _) = try makeModel(); await model.refresh(); let original = try original(model)
            if denied { await gate.set(false) } else { await transport.replaceUser() }
            let id = try XCTUnwrap(model.perform(.delete(original), activation: model.activation)); await wait { !model.isOperating }
            XCTAssertEqual(model.recovery.entry(id)?.failure, denied ? .denied : .changed)
            let calls = await transport.requests(); XCTAssertTrue(calls.allSatisfy { $0.method == "list" })
        }
    }
    func test当前账号和保留群组不能删除当前账号不能停用改组() async throws {
        let (model, transport, _, _) = try makeModel(); await model.refresh()
        let current = try XCTUnwrap(model.directory.value?.users.first { $0.name == "fixture" })
        XCTAssertTrue(model.isCurrent(current)); XCTAssertFalse(model.canPerform(.delete(current)))
        var disabled = draft(current); disabled.isExpired = true
        XCTAssertFalse(model.canPerform(.saveUser(original: current, draft: disabled, groups: nil)))
        var membership = draft(current); membership.groups = ["sample-team"]
        XCTAssertFalse(model.canPerform(.saveUser(original: current, draft: membership, groups: model.directory.value?.groups)))
        let group = try XCTUnwrap(model.directory.value?.groups.first { $0.name == "users" }); XCTAssertFalse(model.canPerform(.delete(group)))
        let calls = await transport.requests(); XCTAssertTrue(calls.allSatisfy { $0.method == "list" })
    }
    func test普通资料未知后重启只读恢复原对象() async throws {
        let (model, transport, _, root) = try makeModel(mode: "nas-directory-unknown"); await model.refresh(); let original = try original(model)
        let id = try XCTUnwrap(model.perform(.saveUser(original: original, draft: draft(original), groups: nil), activation: model.activation)); await wait { !model.isOperating }
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); model.deactivate()
        let (reopened, next, _, _) = try makeModel(mode: "nas-directory-recover", root: root); await reopened.refresh()
        XCTAssertEqual(reopened.recovery.entry(id)?.phase, .succeeded)
        let writes = await transport.requests().filter { $0.method != "list" }; XCTAssertEqual(writes.count, 1)
        let reads = await next.requests(); XCTAssertTrue(reads.allSatisfy { $0.method == "list" })
    }
    func test改密码即使资料改变也必须有接受回执() async throws {
        for accepted in [false, true] {
            let (model, _, _, root) = try makeModel(mode: accepted ? "nas-directory-accepted-offline" : "nas-directory-unknown"); await model.refresh()
            let original = try original(model), change = NasDirectoryChange.saveUser(original: original, draft: draft(original, password: "synthetic-only"), groups: nil)
            let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await wait { !model.isOperating }; model.deactivate()
            let (reopened, transport, _, _) = try makeModel(mode: "nas-directory-recover", root: root); await reopened.refresh()
            XCTAssertEqual(reopened.recovery.entry(id)?.phase, accepted ? .succeeded : .submitted)
            if !accepted { XCTAssertFalse(reopened.canPerform(.delete(try self.original(reopened))))
                reopened.removeRecord(id); XCTAssertNotNil(reopened.recovery.entry(id)) }
            let calls = await transport.requests(); XCTAssertTrue(calls.allSatisfy { $0.method == "list" })
        }
    }
    func test同名不同数字身份不能结束原保存记录() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-directory-unknown"); await model.refresh(); let original = try original(model)
        let id = try XCTUnwrap(model.perform(.saveUser(original: original, draft: draft(original), groups: nil), activation: model.activation)); await wait { !model.isOperating }
        await transport.setMode("nas-directory"); await transport.replaceUser(); await model.refresh()
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted)
    }
    func test损坏记录和无法写入的目录均禁止提交() async throws {
        for corrupt in [true, false] {
            let root = makeRoot()
            if corrupt { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("invalid-record".utf8).write(to: root.appendingPathComponent("directory-operations-v1.json"))
            } else { try Data("blocked-directory".utf8).write(to: root) }
            let (model, transport, _, _) = try makeModel(root: root); await model.refresh(); let original = try original(model)
            XCTAssertNil(model.perform(.delete(original), activation: model.activation))
            let calls = await transport.requests(); XCTAssertTrue(calls.allSatisfy { $0.method == "list" })
        }
    }
    func test准备阶段重启取消且不发送请求() async throws {
        let (model, transport, _, root) = try makeModel(); await model.refresh(); let original = try original(model)
        let id = try model.recovery.reserve(.delete(original), context: try XCTUnwrap(model.context)).id
        model.recovery.end(id)
        let restored = MobileDirectoryOperationStore(root: root); XCTAssertEqual(restored.entry(id)?.phase, .cancelled)
        let calls = await transport.requests(); XCTAssertTrue(calls.allSatisfy { $0.method == "list" })
    }
    func test创建记录不能通过缺少回执字段绕过恢复保护() throws {
        let root = makeRoot(), store = MobileDirectoryOperationStore(root: root)
        let context = MobileWorkspaceIdentity(try profile()).storageIdentifier
        let id = try store.reserve(.saveGroup(original: nil, draft: .init(name: "new-team", description: "Synthetic")), context: context).id
        try store.checkpoint(id, stage: .willSubmit); store.end(id)
        let url = root.appendingPathComponent("directory-operations-v1.json")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(envelope["entries"] as? [[String: Any]])
        entries[0]["requiresAcknowledgement"] = false; envelope["entries"] = entries
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        XCTAssertTrue(MobileDirectoryOperationStore(root: root).failed)
    }
    func test同配置重连使旧确认失效() async throws {
        let (model, _, _, _) = try makeModel(); await model.refresh(); let original = try original(model), token = model.activation
        let profile = try profile(), transport = MobileDirectoryUITransport()
        model.configure(profile: profile, repository: try repository(transport, profile: profile), authorize: { true }); await model.refresh()
        XCTAssertNil(model.perform(.delete(original), activation: token))
        let calls = await transport.requests(); XCTAssertTrue(calls.allSatisfy { $0.method == "list" })
    }
    func test切账号后迟到回执只写原账号记录() async throws {
        let (model, transport, _, root) = try makeModel(); await model.refresh(); let original = try original(model)
        await transport.blockNext("set")
        let id = try XCTUnwrap(model.perform(.saveUser(original: original, draft: draft(original), groups: nil), activation: model.activation)); await transport.waitFor("set")
        let other = try profile(username: "another"), next = MobileDirectoryUITransport(mode: "nas-directory-empty")
        model.configure(profile: other, repository: try repository(next, profile: other), authorize: { true }); await model.refresh(); await transport.release()
        await wait { !model.recovery.isExecuting(id) }
        XCTAssertTrue(model.entries.isEmpty); XCTAssertEqual(model.directory.value?.users.count, 0)
        XCTAssertNotNil(MobileDirectoryOperationStore(root: root).entry(id))
        let calls = await next.requests(); XCTAssertTrue(calls.allSatisfy { $0.method == "list" })
    }
    func test明确拒绝保留失败不报告删除成功() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-directory-denied"); await model.refresh(); let original = try original(model)
        let id = try XCTUnwrap(model.perform(.delete(original), activation: model.activation)); await wait { !model.isOperating }
        XCTAssertEqual(model.recovery.entry(id)?.phase, .failed); XCTAssertEqual(model.recovery.entry(id)?.failure, .denied)
        XCTAssertNotNil(model.directory.value?.users.first { $0.name == original.name })
        let calls = await transport.requests(); XCTAssertEqual(calls.filter { $0.method == "delete" }.count, 1)
    }
    func test空列表失败和畸形响应有不同状态() async throws {
        for (mode, phase) in [("nas-directory-empty", MobileNasDetailsPhase.empty), ("nas-directory-error", .error), ("nas-directory-malformed", .error)] {
            let (model, _, _, _) = try makeModel(mode: mode); await model.refresh()
            XCTAssertEqual(model.directory.phase, phase); XCTAssertEqual(model.canEdit, phase == .empty)
        }
    }
    func test未知资料不能以默认值进入编辑或删除() async throws {
        let (model, transport, _, _) = try makeModel(mode: "nas-directory-readonly"); await model.refresh()
        let original = try original(model)
        XCTAssertNil(original.description); XCTAssertNil(original.email); XCTAssertFalse(original.canEdit)
        XCTAssertFalse(model.canPerform(.saveUser(original: original, draft: draft(original), groups: nil)))
        XCTAssertFalse(model.canPerform(.delete(original)))
        let calls = await transport.requests(); XCTAssertTrue(calls.allSatisfy { $0.method == "list" })
    }
    private func original(_ model: MobileDirectoryModel) throws -> NasAccount { try XCTUnwrap(model.directory.value?.users.first { $0.name == "sample-user" }) }
    private func draft(_ original: NasAccount, password: String = "") -> NasAccountDraft {
        .init(originalName: original.name, name: original.name, description: "Updated account", email: original.email ?? "", isExpired: original.isExpired, password: password, passwordConfirmation: password)
    }
    private func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MobileDirectoryTests-\(UUID())"); roots.append(url); return url
    }
    private func profile(username: String = "fixture") throws -> NasProfile {
        try .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: username)
    }
    private func repository(_ transport: MobileDirectoryUITransport, profile: NasProfile) throws -> DsmNasAdministrationRepository {
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: [DsmAPIName.coreUser, DsmAPIName.coreGroup].map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form, selectedVersion: 1)) }))
        return try .init(profile: profile, capabilities: capabilities, session: .init(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func makeModel(mode: String = "nas-directory", root: URL? = nil) throws -> (MobileDirectoryModel, MobileDirectoryUITransport, DirectoryPermissionGate, URL) {
        let root = root ?? makeRoot(), transport = MobileDirectoryUITransport(mode: mode), gate = DirectoryPermissionGate(), profile = try profile()
        let model = MobileDirectoryModel(root: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile), authorize: { await gate.allowed })
        return (model, transport, gate, root)
    }
    private func wait(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 { if condition() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), "操作没有到达预期状态", file: file, line: line)
    }
}
private actor DirectoryPermissionGate { var allowed = true; func set(_ value: Bool) { allowed = value } }

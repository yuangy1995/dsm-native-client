import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileScheduledTasksTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = self.roots; self.roots = []; return values }
        for root in values { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }
    func test创建编辑启停运行删除均走实际适配并刷新结果() async throws {
        let (model, transport, _, _) = try make(); await model.refresh()
        for action in [NasScheduledTaskAction.create, .save, .disable, .enable, .run, .delete] {
            let change = try await change(model, action)
            let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.phase, action == .run ? .accepted : .succeeded)
            XCTAssertFalse(model.isOperating)
        }
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["create", "set", "set_enable", "set_enable", "run", "delete"])
        XCTAssertFalse(model.tasks.value?.contains { $0.id == "12" } == true)
    }
    func test空目录仍可新建且新草稿使用当前账号默认值() async throws {
        let (model, transport, _, _) = try make(mode: "nas-tasks-empty"); await model.refresh()
        XCTAssertEqual(model.tasks.phase, .empty); XCTAssertTrue(model.canCreate)
        let draft = try await model.newDraft(); XCTAssertEqual(draft.owner, "operator"); XCTAssertTrue(draft.script.isEmpty)
        let requested = try await change(model, .create); let id = try XCTUnwrap(model.perform(requested, activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .succeeded); XCTAssertEqual(model.tasks.value?.count, 1)
        let calls = await transport.calls; XCTAssertFalse(calls.contains { $0["id"] == "-1" })
    }
    func test保存前权限撤销时零写并保留明确原因() async throws {
        let (model, transport, gate, _) = try make(); await model.refresh(); let change = try await change(model, .save)
        await gate.set(false)
        let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .failed); XCTAssertEqual(model.recovery.entry(id)?.failure, .denied)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty); XCTAssertFalse(model.permission)
    }
    func test原脚本在编辑期间变化不能覆盖() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); let change = try await change(model, .save)
        await transport.changeScript()
        let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.failure, .changed); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test同一配置重新连接使旧确认失效() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); let change = try await change(model, .run), token = model.activation
        let profile = try profile(); model.configure(profile: profile, repository: try repository(transport, profile: profile), authorize: { true }); await model.refresh()
        XCTAssertNotEqual(token, model.activation); XCTAssertNil(model.perform(change, activation: token)); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test未知运行阻止同目标所有动作且不能移除记录() async throws {
        let (model, transport, _, _) = try make(mode: "nas-tasks-run-unknown"); await model.refresh(); let task = try XCTUnwrap(model.tasks.value?.first)
        let requested = try await change(model, .run); let id = try XCTUnwrap(model.perform(requested, activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); XCTAssertFalse(model.canManage(task))
        XCTAssertNil(model.perform(.delete(task: task), activation: model.activation)); model.removeRecord(id)
        XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted); let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test未知运行重启后不能靠历史成功记录解除保护() async throws {
        let (model, transport, _, root) = try make(mode: "nas-tasks-run-unknown"); await model.refresh()
        let requested = try await change(model, .run); let id = try XCTUnwrap(model.perform(requested, activation: model.activation)); await model.waitForOperation(id); model.deactivate()
        let (next, nextTransport, _, _) = try make(root: root); await next.refresh(); let task = try XCTUnwrap(next.tasks.value?.first)
        let results = try await next.results(task); XCTAssertEqual(results.first?.exitCode, 0)
        await next.refresh(); XCTAssertEqual(next.recovery.entry(id)?.phase, .submitted); XCTAssertFalse(next.canManage(task))
        let writes = await transport.writes, replayed = await nextTransport.writes; XCTAssertEqual(writes.count, 1); XCTAssertTrue(replayed.isEmpty)
    }
    func test已接受的运行回执在重启后保留已发送语义() async throws {
        let (model, transport, _, root) = try make(); await model.refresh(); let change = try await change(model, .run)
        let entry = try model.recovery.reserve(change, context: try XCTUnwrap(model.context))
        try model.recovery.checkpoint(entry.id, .willSubmit(existingIDs: [])); try model.recovery.checkpoint(entry.id, .accepted); model.recovery.end(entry.id); model.deactivate()
        let (next, nextTransport, _, _) = try make(root: root); await next.refresh()
        XCTAssertEqual(next.recovery.entry(entry.id)?.phase, .accepted)
        let writes = await transport.writes, replayed = await nextTransport.writes; XCTAssertTrue(writes.isEmpty); XCTAssertTrue(replayed.isEmpty)
    }
    func test创建有回执且唯一新增详情匹配才可重启恢复() async throws {
        let (model, transport, _, root) = try make(mode: "nas-tasks-accepted-offline"); await model.refresh()
        let requested = try await change(model, .create); let id = try XCTUnwrap(model.perform(requested, activation: model.activation)); await model.waitForOperation(id)
        XCTAssertTrue(model.recovery.entry(id)?.accepted == true); XCTAssertEqual(model.recovery.entry(id)?.existingIDs, [12]); model.deactivate()
        let (next, nextTransport, _, _) = try make(mode: "nas-tasks-create-recover", root: root); await next.refresh()
        XCTAssertEqual(next.recovery.entry(id)?.phase, .succeeded); XCTAssertTrue(next.canCreate)
        let writes = await transport.writes, replayed = await nextTransport.writes; XCTAssertEqual(writes.count, 1); XCTAssertTrue(replayed.isEmpty)
    }
    func test创建缺回执不认领同名且保护其他任务操作() async throws {
        let (model, _, _, root) = try make(mode: "nas-tasks-unknown"); await model.refresh()
        let requested = try await change(model, .create); let id = try XCTUnwrap(model.perform(requested, activation: model.activation)); await model.waitForOperation(id); model.deactivate()
        let (next, transport, _, _) = try make(mode: "nas-tasks-create-recover", root: root); await next.refresh()
        XCTAssertEqual(next.recovery.entry(id)?.phase, .submitted); XCTAssertFalse(next.canCreate)
        for task in next.tasks.value ?? [] { XCTAssertFalse(next.canManage(task)); XCTAssertNil(next.perform(.delete(task: task), activation: next.activation)) }
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        XCTAssertThrowsError(try next.recovery.finish(id, phase: .succeeded))
        let file = root.appendingPathComponent("scheduled-tasks-v1.json")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var entries = try XCTUnwrap(envelope["entries"] as? [[String: Any]])
        entries[0]["phase"] = "succeeded"; envelope["entries"] = entries
        let corrupted = try JSONSerialization.data(withJSONObject: envelope); try corrupted.write(to: file)
        next.recovery.reload()
        XCTAssertTrue(next.recovery.failed); XCTAssertFalse(next.canCreate)
        XCTAssertEqual(try Data(contentsOf: file), corrupted)
    }
    func test编辑未知结果重启匹配全部字段而不重发() async throws {
        let (model, _, _, root) = try make(mode: "nas-tasks-unknown"); await model.refresh()
        let requested = try await change(model, .save); let id = try XCTUnwrap(model.perform(requested, activation: model.activation)); await model.waitForOperation(id); model.deactivate()
        let (next, transport, _, _) = try make(mode: "nas-tasks-recover", root: root); await next.refresh()
        XCTAssertEqual(next.recovery.entry(id)?.phase, .succeeded); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test停用恢复不需要获取脚本并核对原目标全部元数据() async throws {
        let (model, _, _, root) = try make(mode: "nas-tasks-unknown"); await model.refresh()
        let requested = try await change(model, .disable); let id = try XCTUnwrap(model.perform(requested, activation: model.activation)); await model.waitForOperation(id); model.deactivate()
        let (next, transport, _, _) = try make(root: root, maximum: 3); await transport.setEnabled(false); await next.refresh()
        XCTAssertEqual(next.recovery.entry(id)?.phase, .succeeded)
        let calls = await transport.calls; XCTAssertFalse(calls.contains { $0["method"] == "get" }); XCTAssertFalse(next.supportsEditing)
    }
    func test删除重启不能把同编号更换所有者当作消失() async throws {
        let (model, _, _, root) = try make(mode: "nas-tasks-unknown"); await model.refresh()
        let requested = try await change(model, .delete); let id = try XCTUnwrap(model.perform(requested, activation: model.activation)); await model.waitForOperation(id); model.deactivate()
        let (next, transport, _, _) = try make(root: root); await transport.changeOwner(); await next.refresh()
        XCTAssertEqual(next.recovery.entry(id)?.phase, .submitted)
        await transport.removeTask(); await next.refresh(); XCTAssertEqual(next.recovery.entry(id)?.phase, .succeeded)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test准备阶段重启取消且摘要文件不包含任务正文() async throws {
        let (model, transport, _, root) = try make(); await model.refresh(); let change = try await change(model, .save)
        let id = try model.recovery.reserve(change, context: try XCTUnwrap(model.context)).id; model.recovery.end(id)
        let text = try String(contentsOf: root.appendingPathComponent("scheduled-tasks-v1.json"), encoding: .utf8)
        for secret in ["Sample Task", "Updated Task", "echo updated", "operator", "fixture.example.invalid", "notify_mail", "week_day"] { XCTAssertFalse(text.contains(secret)) }
        model.deactivate(); let (next, _, _, _) = try make(root: root); await next.refresh()
        XCTAssertEqual(next.recovery.entry(id)?.phase, .cancelled); XCTAssertTrue(next.canCreate)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test损坏与无法写入记录均零提交并保留原件() async throws {
        for corrupt in [false, true] {
            let root = makeRoot()
            if corrupt { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try Data("broken".utf8).write(to: root.appendingPathComponent("scheduled-tasks-v1.json")) }
            else { try Data("retained".utf8).write(to: root) }
            let (model, transport, _, _) = try make(root: root); await model.refresh(); let change = try await change(model, .delete)
            XCTAssertNil(model.perform(change, activation: model.activation)); XCTAssertTrue(model.recovery.failed)
            let path = corrupt ? root.appendingPathComponent("scheduled-tasks-v1.json") : root
            XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), corrupt ? "broken" : "retained")
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test跨账号迟到只更新原记录且新账号不接收正文() async throws {
        let (model, transport, _, root) = try make(); await model.refresh(); let change = try await change(model, .run)
        await transport.suspendWrites(); let id = try XCTUnwrap(model.perform(change, activation: model.activation))
        await wait { await transport.writes.count == 1 }
        let profile = try profile(username: "another"), next = MobileScheduledTaskUITransport(username: "another")
        model.configure(profile: profile, repository: try repository(next, profile: profile), authorize: { true }); await model.refresh()
        await transport.resumeWrites(); await model.waitForOperation(id)
        XCTAssertTrue(model.entries.isEmpty); XCTAssertTrue(model.tasks.value?.allSatisfy { $0.owner == "another" } == true)
        XCTAssertNotNil(MobileScheduledTaskStore(root: root).entry(id)); let writes = await next.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test未知启用字段与真实空目录分别显示() async throws {
        let (model, _, _, _) = try make(mode: "nas-tasks-unknown-enabled"); await model.refresh()
        let task = try XCTUnwrap(model.tasks.value?.first); XCTAssertFalse(task.isEnabledKnown); XCTAssertEqual(model.tasks.phase, .content)
        XCTAssertNil(model.perform(.delete(task: task), activation: model.activation))
    }
    func test结果只在主动读取时获取且保留完整输出() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); let task = try XCTUnwrap(model.tasks.value?.first)
        let before = await transport.calls; XCTAssertFalse(before.contains { $0["api"] == DsmAPIName.coreEventScheduler })
        let results = try await model.results(task); let id = try XCTUnwrap(results.first?.id)
        let after = await transport.calls; XCTAssertFalse(after.contains { $0["method"] == "result_get_file" })
        let output = try await model.output(task, resultID: id); XCTAssertTrue(output.output?.hasSuffix("SYNTHETIC OUTPUT END") == true)
    }
    func test连接身份异常保留原提交记录并停止管理() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); let change = try await change(model, .run)
        await transport.setMode("nas-tasks-trust-write")
        let id = try XCTUnwrap(model.perform(change, activation: model.activation)); await model.waitForOperation(id)
        XCTAssertEqual(model.error, .trust); XCTAssertFalse(model.permission); XCTAssertEqual(model.recovery.entry(id)?.phase, .submitted)
        let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "run")
    }
    private func change(_ model: MobileScheduledTasksModel, _ action: NasScheduledTaskAction) async throws -> NasScheduledTaskChange {
        if action == .create {
            let draft = try await model.newDraft(); var desired = draft; desired.name = "New Task"; desired.script = "echo created"
            return .save(task: nil, original: draft, desired: desired)
        }
        let task = try XCTUnwrap(model.tasks.value?.first { $0.id == "12" })
        if action == .delete { return .delete(task: task) }
        if action == .disable { return .setEnabled(task: task, original: nil, enabled: false) }
        let value = try await model.inspect(task), draft = try XCTUnwrap(value)
        if action == .run { return .run(task: task, original: draft) }
        if action == .enable { return .setEnabled(task: task, original: draft, enabled: true) }
        var desired = draft; desired.name = "Updated Task"; desired.script = "echo updated"
        return .save(task: task, original: draft, desired: desired)
    }
    private func makeRoot() -> URL { let value = FileManager.default.temporaryDirectory.appendingPathComponent("ScheduledTasksTests-\(UUID())"); roots.append(value); return value }
    private func profile(username: String = "operator") throws -> NasProfile { try .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: username) }
    private func repository(_ transport: MobileScheduledTaskUITransport, profile: NasProfile, maximum: Int = 4) throws -> DsmNasAdministrationRepository {
        let capabilities = CapabilitySet([DsmAPIName.coreTaskScheduler: .init(name: DsmAPIName.coreTaskScheduler, path: "entry.cgi", minVersion: 1, maxVersion: maximum, requestFormat: .form, selectedVersion: maximum), DsmAPIName.coreEventScheduler: .init(name: DsmAPIName.coreEventScheduler, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form, selectedVersion: 1)])
        return try .init(profile: profile, capabilities: capabilities, session: .init(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func make(mode: String = "nas-tasks", root: URL? = nil, maximum: Int = 4) throws -> (MobileScheduledTasksModel, MobileScheduledTaskUITransport, ScheduledTaskPermissionGate, URL) {
        let root = root ?? makeRoot(), profile = try profile(), transport = MobileScheduledTaskUITransport(mode: mode), gate = ScheduledTaskPermissionGate()
        let model = MobileScheduledTasksModel(root: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile, maximum: maximum), authorize: { await gate.check() })
        return (model, transport, gate, root)
    }
    private func wait(_ condition: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<2_000 { if await condition() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        let result = await condition(); XCTAssertTrue(result)
    }
}
private actor ScheduledTaskPermissionGate { private var allowed = true; func set(_ value: Bool) { allowed = value }; func check() -> Bool { allowed } }

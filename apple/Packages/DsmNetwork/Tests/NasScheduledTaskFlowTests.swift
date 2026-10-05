import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class NasScheduledTaskFlowTests: XCTestCase {
    func test新建任务需要接受回执并完整读取唯一新增配置() async throws {
        let transport = ScheduledTaskFlowTransport(), repo = try repository(transport), log = TaskCheckpointLog()
        let original = try await repo.loadScheduledTaskDraft(id: nil, realOwner: nil)
        var desired = original; desired.name = " New Task "; desired.script = "echo created"; desired.owner = " operator "
        let result = try await repo.changeScheduledTaskResult(.save(task: nil, original: original, desired: desired)) { await log.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes, stages = await log.values
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["method"], "create"); XCTAssertEqual(writes[0]["version"], "4")
        XCTAssertEqual(writes[0]["name"], "New Task"); XCTAssertNil(writes[0]["id"])
        XCTAssertEqual(stages, [.willSubmit(existingIDs: [12]), .accepted])
    }
    func test编辑只用原编码并保留日期和重复策略() async throws {
        let transport = ScheduledTaskFlowTransport(), repo = try repository(transport)
        let (task, original) = try await original(repo)
        var desired = original; desired.name = "Updated Task"; desired.script = "echo updated"; desired.schedule.hour = 9; desired.schedule.weekDays = "0,6"; desired.notifyOnError = true; desired.notificationEmails = "sample@example.invalid"
        let result = try await repo.changeScheduledTaskResult(.save(task: task, original: original, desired: desired)) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["version"], "4")
        let schedule = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(writes[0]["schedule"]).utf8)) as? [String: Any])
        XCTAssertEqual(schedule["hour"] as? Int, 9); XCTAssertEqual(schedule["date"] as? String, "2026-10-07")
        XCTAssertEqual(schedule["repeat_date"] as? Int, 1002); XCTAssertEqual(schedule["monthly_week"] as? [Int], [1,3]); XCTAssertEqual(schedule["last_work_hour"] as? Int, 18)
        let saved = try await repo.loadScheduledTaskDraft(id: 12, realOwner: "operator"); XCTAssertEqual(saved.savedFields, desired.savedFields)
    }
    func test执行和启用前脚本单独变化即零写入() async throws {
        for enabled in [false, true] {
            let transport = ScheduledTaskFlowTransport(), repo = try repository(transport)
            if enabled { await transport.setEnabled(false) }
            let (task, original) = try await original(repo); await transport.changeScript()
            let change: NasScheduledTaskChange = enabled ? .setEnabled(task: task, original: original, enabled: true) : .run(task: task, original: original)
            let result = try await repo.changeScheduledTaskResult(change) { _ in XCTFail() }
            XCTAssertEqual(result.status, .confirmedFailure); XCTAssertFalse(result.submitted); XCTAssertEqual(result.errorCategory, .conflict)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test手动运行不要求重新解释原有星期安排() async throws {
        let transport = ScheduledTaskFlowTransport(), repo = try repository(transport); await transport.setWeekdays("")
        let (task, original) = try await original(repo)
        let result = try await repo.changeScheduledTaskResult(.run(task: task, original: original)) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "run"); XCTAssertEqual(calls.last?["version"], "3")
        XCTAssertFalse(calls.contains { $0["api"] == DsmAPIName.coreEventScheduler })
    }
    func test未知原星期不改动时可保存其他字段但不能伪造新重复策略() async throws {
        let transport = ScheduledTaskFlowTransport(), repo = try repository(transport); await transport.setWeekdays("")
        let (task, original) = try await original(repo); var desired = original; desired.name = "Updated Task"
        let saved = try await repo.changeScheduledTaskResult(.save(task: task, original: original, desired: desired)) { _ in }
        XCTAssertEqual(saved.status, .confirmedSuccess)
        var invalid = original; invalid.schedule.repeatDate = 9999; invalid.name = "invalid"
        let rejected = try await repo.changeScheduledTaskResult(.save(task: task, original: original, desired: invalid)) { _ in XCTFail() }
        XCTAssertFalse(rejected.submitted); let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test只有v3也能停用而不读取脚本详情() async throws {
        let transport = ScheduledTaskFlowTransport(), repo = try repository(transport, maximum: 3)
        let tasks = try await repo.loadScheduledTasks(); let task = try XCTUnwrap(tasks.first)
        let result = try await repo.changeScheduledTaskResult(.setEnabled(task: task, original: nil, enabled: false)) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.calls; XCTAssertFalse(calls.contains { $0["method"] == "get" }); XCTAssertTrue(calls.allSatisfy { $0["version"] == "3" })
        XCTAssertEqual(calls.filter { $0["method"] == "set_enable" }.count, 1)
    }
    func test运行丢失回执不读取历史记录也不重发() async throws {
        let transport = ScheduledTaskFlowTransport(), repo = try repository(transport)
        let (task, original) = try await original(repo); await transport.setMode("nas-tasks-run-unknown")
        let result = try await repo.changeScheduledTaskResult(.run(task: task, original: original)) { _ in }
        XCTAssertEqual(result.status, .submittedButUnverified)
        let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "run"); let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test创建丢失回执不能凭唯一同名完整内容成功() async throws {
        let transport = ScheduledTaskFlowTransport(), repo = try repository(transport); await transport.setMode("nas-tasks-lost-ack")
        let original = try await repo.loadScheduledTaskDraft(id: nil, realOwner: nil); var desired = original; desired.name = "New Task"; desired.script = "echo created"
        let result = try await repo.changeScheduledTaskResult(.save(task: nil, original: original, desired: desired)) { _ in }
        XCTAssertEqual(result.status, .submittedButUnverified); let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test创建接受回执也不能认领已有数字身份() async throws {
        let transport = ScheduledTaskFlowTransport(), repo = try repository(transport); await transport.setMode("nas-tasks-reuse-id")
        let original = try await repo.loadScheduledTaskDraft(id: nil, realOwner: nil); var desired = original; desired.name = "New Task"; desired.script = "echo created"
        let result = try await repo.changeScheduledTaskResult(.save(task: nil, original: original, desired: desired)) { _ in }
        XCTAssertEqual(result.status, .submittedButUnverified); let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test编辑丢失回执可通过全部保存字段恢复且只发送一次() async throws {
        let transport = ScheduledTaskFlowTransport(), repo = try repository(transport)
        let (task, original) = try await original(repo); var desired = original; desired.script = "echo updated"
        await transport.setMode("nas-tasks-lost-ack")
        let result = try await repo.changeScheduledTaskResult(.save(task: task, original: original, desired: desired)) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess); let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test明确拒绝不再读取或用旧字段覆盖失败() async throws {
        let transport = ScheduledTaskFlowTransport(), repo = try repository(transport)
        let (task, original) = try await original(repo); await transport.setMode("nas-tasks-denied")
        let result = try await repo.changeScheduledTaskResult(.run(task: task, original: original)) { _ in }
        XCTAssertEqual(result.status, .permissionDenied); let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "run")
    }
    func test删除只有原数字身份消失才成功() async throws {
        for reuse in [false, true] {
            let transport = ScheduledTaskFlowTransport(), repo = try repository(transport)
            let tasks = try await repo.loadScheduledTasks(); let task = try XCTUnwrap(tasks.first)
            if reuse { await transport.setMode("nas-tasks-reuse-id") }
            let result = try await repo.changeScheduledTaskResult(.delete(task: task)) { _ in }
            XCTAssertEqual(result.status, reuse ? .submittedButUnverified : .confirmedSuccess)
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["version"], "3")
        }
    }
    func test写前权限或记录失败零请求而回执记录失败不继续读() async throws {
        for accepted in [false, true] {
            let transport = ScheduledTaskFlowTransport(), repo = try repository(transport)
            let tasks = try await repo.loadScheduledTasks(); let task = try XCTUnwrap(tasks.first)
            do {
                _ = try await repo.changeScheduledTaskResult(.delete(task: task)) { stage in
                    if accepted ? stage == .accepted : stage != .accepted { throw TaskJournalFailure.failed }
                }; XCTFail()
            } catch { XCTAssertTrue(error is TaskJournalFailure) }
            let writes = await transport.writes; XCTAssertEqual(writes.count, accepted ? 1 : 0)
            if accepted { let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "delete") }
        }
    }
    func test新旧入口共享同目标互斥() async throws {
        let transport = ScheduledTaskFlowTransport(), repo = try repository(transport)
        let (task, original) = try await original(repo)
        let result = try await repo.changeScheduledTaskResult(.run(task: task, original: original)) { stage in
            if case .willSubmit = stage {
                do { try await repo.runScheduledTask(id: 12, realOwner: "operator"); XCTFail() }
                catch { XCTAssertEqual((error as? AppError)?.category, .conflict) }
            }
        }
        XCTAssertEqual(result.status, .confirmedSuccess); let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test未知启用状态保持未知而非伪造已停用() async throws {
        let transport = ScheduledTaskFlowTransport(mode: "nas-tasks-unknown-enabled"), repo = try repository(transport)
        let tasks = try await repo.loadScheduledTasks(); let task = try XCTUnwrap(tasks.first)
        XCTAssertFalse(task.isEnabledKnown); XCTAssertFalse(task.canEdit)
        let result = try await repo.changeScheduledTaskResult(.delete(task: task)) { _ in XCTFail() }
        XCTAssertFalse(result.submitted)
    }
    func test非脚本任务仅按运行许可提交并不读取脚本() async throws {
        let transport = ScheduledTaskFlowTransport(mode: "nas-tasks-non-script"), repo = try repository(transport, maximum: 3)
        let tasks = try await repo.loadScheduledTasks(); let task = try XCTUnwrap(tasks.first)
        let result = try await repo.changeScheduledTaskResult(.run(task: task, original: nil)) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess); let calls = await transport.calls; XCTAssertFalse(calls.contains { $0["method"] == "get" })
    }
    func test同名任务不能混读运行记录() async throws {
        let transport = ScheduledTaskFlowTransport(), repo = try repository(transport)
        let tasks = try await repo.loadScheduledTasks(); let task = try XCTUnwrap(tasks.first); await transport.addDuplicateName()
        do { _ = try await repo.scheduledTaskResults(for: task); XCTFail() } catch { XCTAssertEqual((error as? AppError)?.category, .conflict) }
        let calls = await transport.calls; XCTAssertFalse(calls.contains { $0["method"] == "result_list" })
    }
    func test读取输出绑定当前任务与实际运行记录() async throws {
        let transport = ScheduledTaskFlowTransport(), repo = try repository(transport)
        let tasks = try await repo.loadScheduledTasks(); let task = try XCTUnwrap(tasks.first)
        do { _ = try await repo.scheduledTaskOutput(for: task, resultID: "missing"); XCTFail() } catch { XCTAssertEqual((error as? AppError)?.category, .conflict) }
        let before = await transport.calls; XCTAssertFalse(before.contains { $0["method"] == "result_get_file" })
        let output = try await repo.scheduledTaskOutput(for: task, resultID: "result-1")
        XCTAssertEqual(output.command, "echo synthetic output"); XCTAssertTrue(output.output?.hasSuffix("SYNTHETIC OUTPUT END") == true)
        let calls = await transport.calls; XCTAssertTrue(calls.filter { $0["api"] == DsmAPIName.coreEventScheduler }.allSatisfy { $0["version"] == "1" })
    }
    func test连接身份异常在预检和提交时原样传播且不继续读取() async throws {
        for writing in [false, true] {
            let transport = ScheduledTaskFlowTransport(), repo = try repository(transport)
            let (task, original) = try await original(repo); await transport.setMode(writing ? "nas-tasks-trust-write" : "nas-tasks-trust")
            do { _ = try await repo.changeScheduledTaskResult(.run(task: task, original: original)) { _ in }; XCTFail() }
            catch { XCTAssertEqual((error as? AppError)?.category, .tlsUntrusted) }
            let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], writing ? "run" : "list")
            let writes = await transport.writes; XCTAssertEqual(writes.count, writing ? 1 : 0)
        }
    }
    func test脚本运行缺少预览和创建缺少v4均零提交() async throws {
        let transport = ScheduledTaskFlowTransport(), repo = try repository(transport, maximum: 3)
        let tasks = try await repo.loadScheduledTasks(), task = try XCTUnwrap(tasks.first)
        let run = try await repo.changeScheduledTaskResult(.run(task: task, original: nil)) { _ in XCTFail() }
        XCTAssertFalse(run.submitted)
        let original = NasScheduledTaskDraft(owner: "operator"); var desired = original; desired.name = "New Task"; desired.script = "echo created"
        let create = try await repo.changeScheduledTaskResult(.save(task: nil, original: original, desired: desired)) { _ in XCTFail() }
        XCTAssertEqual(create.status, .unsupported); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    private func original(_ repo: DsmNasAdministrationRepository) async throws -> (NasScheduledTask, NasScheduledTaskDraft) {
        let tasks = try await repo.loadScheduledTasks(), task = try XCTUnwrap(tasks.first)
        let draft = try await repo.inspectScheduledTask(task); return (task, try XCTUnwrap(draft))
    }
    private func repository(_ transport: ScheduledTaskFlowTransport, maximum: Int = 4) throws -> DsmNasAdministrationRepository {
        let capabilities = CapabilitySet([DsmAPIName.coreTaskScheduler: .init(name: DsmAPIName.coreTaskScheduler, path: "entry.cgi", minVersion: 1, maxVersion: maximum, requestFormat: .form, selectedVersion: maximum),
            DsmAPIName.coreEventScheduler: .init(name: DsmAPIName.coreEventScheduler, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form, selectedVersion: 1)])
        return try .init(profile: .init(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "operator"), capabilities: capabilities,
            session: .init(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
}
private enum TaskJournalFailure: Error { case failed }
private actor TaskCheckpointLog { private(set) var values: [NasScheduledTaskCheckpoint] = []; func append(_ value: NasScheduledTaskCheckpoint) { values.append(value) } }

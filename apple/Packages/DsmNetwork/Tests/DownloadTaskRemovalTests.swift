import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class DownloadTaskRemovalTests: XCTestCase {
    func test两种明确意图均固定公开一版且只确认任务消失() async throws {
        for force in [false, true] {
            let transport = MockHTTPTransport(responses: [page(), response(#"[{"id":"task","error":0}]"#), empty()])
            let result = try await repository(transport).removeDownloadTask(removal(force)) {
                let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
                XCTAssertEqual(Self.field("method", calls[0]), "list")
            }
            XCTAssertEqual(result, .removed)
            let calls = await transport.recordedRequests()
            XCTAssertEqual(calls.map { Self.field("method", $0) }, ["list", "delete", "list"])
            XCTAssertEqual(Self.field("version", calls[1]), "1")
            XCTAssertEqual(Self.field("force_complete", calls[1]), force ? "true" : "false")
            XCTAssertEqual(Self.field("id", calls[1]), "task"); XCTAssertEqual(calls[1].httpMethod, "POST")
            XCTAssertTrue(calls.allSatisfy { Self.field("api", $0) == DsmAPIName.downloadStationTask })
        }
    }
    func test原身份或位置改变以及缺失均不得写入() async throws {
        for data in [page(title: "changed"), page(size: 2), page(destination: "elsewhere"), empty()] {
            let transport = MockHTTPTransport(responses: [data])
            let result = try await repository(transport).removeDownloadTask(removal(), willSubmit: { XCTFail("目标改变不得保存发送") })
            XCTAssertEqual(result, .changed)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
        }
    }
    func test无公开一版能力和非法编号发送前拒绝() async throws {
        let transport = MockHTTPTransport(responses: []), repo = try repository(transport, minVersion: 2)
        XCTAssertFalse(repo.supportsDownloadTaskRemoval)
        do { _ = try await repo.removeDownloadTask(removal(), willSubmit: {}); XCTFail("无公开能力") } catch {}
        for id in ["", "task,other", " task", "task\n"] {
            let value = DownloadTaskRemoval(task: .init(id: id, title: "synthetic", status: "finished"), forceComplete: false)
            XCTAssertFalse(value.isValid)
            do { _ = try await repository(transport).removeDownloadTask(value, willSubmit: {}); XCTFail("非法编号") } catch {}
        }
        let calls = await transport.recordedRequests(); XCTAssertTrue(calls.isEmpty)
    }
    func test写前存储失败与回调期间取消均零写() async throws {
        let transport = MockHTTPTransport(responses: [page(), page()]), repo = try repository(transport)
        do { _ = try await repo.removeDownloadTask(removal()) { throw CocoaError(.fileWriteNoPermission) }; XCTFail("保存失败") } catch {}
        let gate = RemovalTestGate(), value = removal()
        let operation = Task { try await repo.removeDownloadTask(value) { await gate.wait() } }
        await gate.started(); operation.cancel(); await gate.release()
        let result = try await operation.value; XCTAssertEqual(result, .cancelledBeforeSubmission)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.map { Self.field("method", $0) }, ["list", "list"])
    }
    func test逐项与顶层明确拒绝不误报成功() async throws {
        for code in [105, 402, 404, 405, 407, 100] {
            for top in [false, true] {
                let denial = top ? DsmHTTPResponse(data: Data("{\"success\":false,\"error\":{\"code\":\(code)}}".utf8), statusCode: 200)
                    : response("[{\"id\":\"task\",\"error\":\(code)}]")
                let transport = MockHTTPTransport(responses: [page(), denial])
                let result = try await repository(transport).removeDownloadTask(removal(), willSubmit: {})
                let expected: DownloadTaskRemovalOutcome = [105, 402].contains(code) ? .denied : code == 404 ? .changed : code == 100 ? .pending : .rejected
                XCTAssertEqual(result, expected)
                let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
            }
        }
    }
    func test无效回执保留未知且阻止编辑控制重复删除包括旧入口() async throws {
        for data in ["{}", "[]", #"[{"id":"other","error":0}]"#, #"[{"id":"task","error":true}]"#,
                     #"[{"id":"task","error":"0"}]"#, #"[{"id":"task","error":0},{"id":"task","error":0}]"#] {
            let transport = MockHTTPTransport(responses: [page(), response(data)]), repo = try repository(transport)
            let result = try await repo.removeDownloadTask(removal(), willSubmit: {}); XCTAssertEqual(result, .pending)
            do { _ = try await repo.removeDownloadTask(removal(true), willSubmit: {}); XCTFail("重复删除") } catch {}
            do { _ = try await repo.changeDownloadTaskDestination(.init(task: task(), destination: "new"), willSubmit: {}); XCTFail("编辑") } catch {}
            do { _ = try await repo.controlDownloadTaskResult(.init(task: task(), action: .pause)); XCTFail("控制") } catch {}
            do { _ = try await repo.deleteDownloadTasksResult(ids: ["task"], removeData: false); XCTFail("旧删除") } catch {}
            do { try await repo.controlDownloadTasks(ids: ["task"], action: .pause); XCTFail("旧控制") } catch {}
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
        }
    }
    func test成功回执后的读取失败不当作消失() async throws {
        let transport = MockHTTPTransport(steps: [.response(page()), .response(response(#"[{"id":"task","error":0}]"#)), .urlError(.notConnectedToInternet)])
        let result = try await repository(transport).removeDownloadTask(removal(), willSubmit: {})
        XCTAssertEqual(result, .pending)
    }
    func test未知恢复只读原任务仍在不解除保护消失后完成() async throws {
        let transport = MockHTTPTransport(steps: [.response(page()), .urlError(.timedOut), .response(page()), .response(empty())])
        let repo = try repository(transport)
        let initial = try await repo.removeDownloadTask(removal(), willSubmit: {}); XCTAssertEqual(initial, .pending)
        let existing = try await repo.reviewDownloadTaskRemoval(removal()); XCTAssertEqual(existing, .pending)
        let gone = try await repo.reviewDownloadTaskRemoval(removal()); XCTAssertEqual(gone, .removed)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.filter { Self.field("method", $0) == "delete" }.count, 1)
    }
    func test重启发现编号复用不会认作删除成功或重发() async throws {
        let transport = MockHTTPTransport(responses: [page(title: "replacement")])
        let result = try await repository(transport).reviewDownloadTaskRemoval(removal())
        XCTAssertEqual(result, .changed)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.map { Self.field("method", $0) }, ["list"])
    }
    func test后续分页错误不当作目标不存在() async throws {
        let first = response(#"{"tasks":[{"id":"other","title":"other","status":"finished"}],"offset":0,"total":2}"#)
        let transport = MockHTTPTransport(steps: [.response(first), .urlError(.timedOut)])
        do { _ = try await repository(transport).reviewDownloadTaskRemoval(removal()); XCTFail("分页不全") } catch {}
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Self.field("offset", calls[1]), "1")
    }
    func test在途移除阻止同目标并发但不发送虚构完成做种方法() async throws {
        let transport = MockHTTPTransport(responses: [page(), response(#"[{"id":"task","error":0}]"#), empty()])
        let repo = try repository(transport), gate = RemovalTestGate(), value = removal()
        let operation = Task { try await repo.removeDownloadTask(value) { await gate.wait() } }
        await gate.started()
        do { _ = try await repo.removeDownloadTask(value, willSubmit: {}); XCTFail("重复") } catch {}
        do { _ = try await repo.controlDownloadTaskResult(.init(task: task(), action: .pause)); XCTFail("在途控制") } catch {}
        do { try await repo.controlDownloadTasks(ids: ["task"], action: .finish); XCTFail("无 finish 方法") } catch {}
        await gate.release(); let result = try await operation.value; XCTAssertEqual(result, .removed)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 3)
    }
    private func repository(_ transport: MockHTTPTransport, minVersion: Int = 1) throws -> DsmServiceManagementRepository {
        try DsmServiceManagementRepository(profile: NasProfile(displayName: "Synthetic", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet([DsmAPIName.downloadStationTask: .init(name: DsmAPIName.downloadStationTask, path: "entry.cgi", minVersion: minVersion, maxVersion: 3, requestFormat: .form, selectedVersion: 3)]),
            session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func task() -> DownloadStationTask { .init(id: "task", title: "synthetic", status: "downloading", sizeBytes: 4096, destination: "folder") }
    private func removal(_ force: Bool = false) -> DownloadTaskRemoval { .init(task: task(), forceComplete: force) }
    private func page(title: String = "synthetic", size: Int = 4096, destination: String = "folder") -> DsmHTTPResponse {
        response("{\"tasks\":[{\"id\":\"task\",\"title\":\"\(title)\",\"status\":\"downloading\",\"size\":\(size),\"additional\":{\"detail\":{\"destination\":\"\(destination)\"}}}],\"offset\":0,\"total\":1}")
    }
    private func empty() -> DsmHTTPResponse { response(#"{"tasks":[],"offset":0,"total":0}"#) }
    private func response(_ data: String) -> DsmHTTPResponse { .init(data: Data("{\"success\":true,\"data\":\(data)}".utf8), statusCode: 200) }
    private static func field(_ name: String, _ request: URLRequest) -> String? {
        URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems?.first { $0.name == name }?.value
    }
}
private actor RemovalTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { didStart = true; waiters.forEach { $0.resume() }; waiters = []; await withCheckedContinuation { continuation = $0 } }
    func started() async { if !didStart { await withCheckedContinuation { waiters.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}

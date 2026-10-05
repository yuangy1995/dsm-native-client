import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class DownloadTaskDestinationTests: XCTestCase {
    func test固定二版差量请求与原身份原位置写前回调() async throws {
        let transport = MockHTTPTransport(responses: [page(), response(#"[{"id":"<synthetic-download-task>","error":0}]"#), page(destination: "<synthetic-directory>")])
        let result = try await repository(transport).changeDownloadTaskDestination(change()) {
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(Self.field("method", calls[0]), "list")
        }
        XCTAssertEqual(result, .complete(task(destination: "<synthetic-directory>")))
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { Self.field("method", $0) }, ["list", "edit", "list"])
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(
            "contracts/request-fixtures/download-station/edit-destination/synthetic-task-v2/request.json"))) as? [String: Any])
        let parameters = try XCTUnwrap(fixture["parameters"] as? [[String: Any]])
        for parameter in parameters { XCTAssertEqual(Self.field(try XCTUnwrap(parameter["name"] as? String), requests[1]), parameter["encodedValue"] as? String) }
        let fields = URLComponents(string: "https://example.invalid/?" + String(data: requests[1].httpBody!, encoding: .utf8)!)!.queryItems!
        XCTAssertEqual(Set(fields.map(\.name)).subtracting(["api", "version", "method", "_sid", "SynoToken"]), ["id", "destination"])
        XCTAssertEqual(Self.field("version", requests[1]), "2"); XCTAssertEqual(requests[1].httpMethod, "POST")
    }
    func test一版能力与非法目录编号全部在读取之前拒绝() async throws {
        let transport = MockHTTPTransport(responses: []), old = try repository(transport, version: 1)
        XCTAssertFalse(old.supportsDownloadDestinationEditing)
        do { _ = try await old.changeDownloadTaskDestination(change(), willSubmit: {}); XCTFail("一版不支持编辑") } catch {}
        let current = try repository(transport)
        for path in ["", "/folder", "folder/", "folder//child", "folder/../child", "folder/./child", "folder\nchild"] {
            let change = DownloadTaskDestinationChange(task: task(), destination: path)
            XCTAssertFalse(change.isValid)
            do { _ = try await current.changeDownloadTaskDestination(change, willSubmit: {}); XCTFail("非法目录不提交") } catch {}
        }
        for id in ["one,two", " one", "one\ntwo"] {
            let change = DownloadTaskDestinationChange(task: .init(id: id, title: "合成任务", status: "downloading", destination: "old"), destination: "new")
            XCTAssertFalse(change.isValid)
        }
        let calls = await transport.recordedRequests(); XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(DownloadTaskDestinationChange.validDestination("folder with spaces /child "))
    }
    func test原身份或原目录变化与缺失任务不发送编辑() async throws {
        for value in [page(title: "另一合成任务"), page(size: 8), page(destination: "changed"), response(#"{"tasks":[],"total":0,"offset":0}"#)] {
            let transport = MockHTTPTransport(responses: [value])
            let result = try await repository(transport).changeDownloadTaskDestination(change(), willSubmit: { XCTFail("不得保存待发送记录") })
            XCTAssertEqual(result, .changed)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
        }
    }
    func test写前存储失败零写且取消回调后也零写() async throws {
        let transport = MockHTTPTransport(responses: [page(), page()]), repo = try repository(transport)
        do { _ = try await repo.changeDownloadTaskDestination(change(), willSubmit: { throw CocoaError(.fileWriteNoPermission) }); XCTFail("存储失败") } catch {}
        let gate = DestinationTestGate(), value = change()
        let operation = Task { try await repo.changeDownloadTaskDestination(value) { await gate.wait() } }
        await gate.waitUntilStarted(); operation.cancel(); await gate.release()
        let outcome = try await operation.value; XCTAssertEqual(outcome, .cancelledBeforeSubmission)
        let calls = await transport.recordedRequests(); XCTAssertTrue(calls.allSatisfy { Self.field("method", $0) == "list" })
    }
    func test每项明确错误与顶层错误按官方语义分类() async throws {
        for code in [105, 402, 403, 404, 405, 407, 100] {
            for topLevel in [false, true] {
                let rejection = topLevel ? DsmHTTPResponse(data: Data("{\"success\":false,\"error\":{\"code\":\(code)}}".utf8), statusCode: 200)
                    : response("[{\"id\":\"<synthetic-download-task>\",\"error\":\(code)}]")
                let transport = MockHTTPTransport(responses: [page(), rejection])
                let outcome = try await repository(transport).changeDownloadTaskDestination(change(), willSubmit: {})
                let expected: DownloadTaskDestinationOutcome = [105, 402].contains(code) ? .denied : code == 404 ? .changed : code == 100 ? .pending : .rejected
                XCTAssertEqual(outcome, expected)
                let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
            }
        }
    }
    func test缺少重复错位和非法返回值保留未知不允许重放控制或删除() async throws {
        for data in ["{}", "[]", #"[{"id":"other","error":0}]"#,
                     #"[{"id":"<synthetic-download-task>","error":true}]"#,
                     #"[{"id":"<synthetic-download-task>","error":"0"}]"#,
                     #"[{"id":"<synthetic-download-task>","error":0},{"id":"<synthetic-download-task>","error":0}]"#] {
            let transport = MockHTTPTransport(responses: [page(), response(data)]), repo = try repository(transport)
            let first = try await repo.changeDownloadTaskDestination(change(), willSubmit: {}); XCTAssertEqual(first, .pending)
            do { _ = try await repo.changeDownloadTaskDestination(change(), willSubmit: {}); XCTFail("不得重发") } catch {}
            do { _ = try await repo.controlDownloadTaskResult(.init(task: task(), action: .pause)); XCTFail("不得控制") } catch {}
            do { _ = try await repo.deleteDownloadTasksResult(ids: [task().id], removeData: false); XCTFail("不得删除") } catch {}
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
        }
    }
    func test未知回读原值保持保护读取目标值后可完成且只有一次写() async throws {
        let transport = MockHTTPTransport(steps: [.response(page()), .urlError(.timedOut), .response(page()), .response(page(destination: "<synthetic-directory>"))])
        let repo = try repository(transport), value = change()
        let first = try await repo.changeDownloadTaskDestination(value, willSubmit: {}); XCTAssertEqual(first, .pending)
        let unchanged = try await repo.reviewDownloadTaskDestination(value); XCTAssertEqual(unchanged, .pending)
        let complete = try await repo.reviewDownloadTaskDestination(value); XCTAssertEqual(complete, .complete(task(destination: value.desired)))
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.filter { Self.field("method", $0) == "edit" }.count, 1)
    }
    func test成功回执但回读失败或第三方位置不误报成功() async throws {
        for last in [MockHTTPTransport.Step.urlError(.notConnectedToInternet), .response(page(destination: "someone-else"))] {
            let transport = MockHTTPTransport(steps: [.response(page()), .response(response(#"[{"id":"<synthetic-download-task>","error":0}]"#)), last])
            let outcome = try await repository(transport).changeDownloadTaskDestination(change(), willSubmit: {})
            XCTAssertEqual(outcome, .pending)
        }
    }
    func test重启回读不重发且编号复用不凭相同目录成功() async throws {
        let transport = MockHTTPTransport(responses: [page(destination: "<synthetic-directory>", title: "新任务")])
        let outcome = try await repository(transport).reviewDownloadTaskDestination(change())
        XCTAssertEqual(outcome, .changed)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.map { Self.field("method", $0) }, ["list"])
    }
    func test在途编辑阻止同任务重复编辑与控制() async throws {
        let transport = MockHTTPTransport(responses: [page(), response(#"[{"id":"<synthetic-download-task>","error":0}]"#), page(destination: "<synthetic-directory>")])
        let repo = try repository(transport), gate = DestinationTestGate(), value = change()
        let operation = Task { try await repo.changeDownloadTaskDestination(value) { await gate.wait() } }
        await gate.waitUntilStarted()
        do { _ = try await repo.changeDownloadTaskDestination(value, willSubmit: {}); XCTFail("重复编辑") } catch {}
        do { _ = try await repo.controlDownloadTaskResult(.init(task: task(), action: .pause)); XCTFail("在途控制") } catch {}
        await gate.release(); let outcome = try await operation.value
        XCTAssertEqual(outcome, .complete(task(destination: value.desired)))
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 3)
    }
    private func repository(_ transport: MockHTTPTransport, version: Int = 3) throws -> DsmServiceManagementRepository {
        try DsmServiceManagementRepository(profile: NasProfile(displayName: "合成设备", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet([DsmAPIName.downloadStationTask: .init(name: DsmAPIName.downloadStationTask, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version)]),
            session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func task(destination: String = "old", title: String = "合成任务", size: Int64 = 4096) -> DownloadStationTask {
        .init(id: "<synthetic-download-task>", title: title, status: "downloading", sizeBytes: size, destination: destination)
    }
    private func change() -> DownloadTaskDestinationChange { .init(task: task(), destination: "<synthetic-directory>") }
    private func page(destination: String = "old", title: String = "合成任务", size: Int64 = 4096) -> DsmHTTPResponse {
        response("{\"tasks\":[{\"id\":\"<synthetic-download-task>\",\"title\":\"\(title)\",\"status\":\"downloading\",\"size\":\"\(size)\",\"additional\":{\"detail\":{\"destination\":\"\(destination)\"}}}],\"offset\":0,\"total\":1}")
    }
    private func response(_ data: String) -> DsmHTTPResponse { .init(data: Data("{\"success\":true,\"data\":\(data)}".utf8), statusCode: 200) }
    private static func field(_ name: String, _ request: URLRequest) -> String? {
        URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems?.first { $0.name == name }?.value
    }
}
private actor DestinationTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { started = true; waiters.forEach { $0.resume() }; waiters = []; await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { waiters.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}

import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class DownloadStationControlRecoveryTests: XCTestCase {
    func test写前回调收到最新任务且回调完成前没有控制请求() async throws {
        let transport = MockHTTPTransport(responses: [page("downloading"), response(#"{}"#), page("paused")])
        let repository = try repository(transport), original = task("downloading")
        let outcome = try await repository.controlDownloadTaskResult(.init(task: original, action: .pause)) { latest in
            XCTAssertEqual(latest, original)
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(Self.field("method", requests[0]), "list")
        }
        XCTAssertEqual(outcome.result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { Self.field("method", $0) }, ["list", "pause", "list"])
        XCTAssertEqual(Self.field("id", requests[1]), "synthetic-1")
    }

    func test保存回调失败和身份冲突均零控制请求() async throws {
        for conflict in [false, true] {
            let transport = MockHTTPTransport(responses: [page("downloading")]), repository = try repository(transport)
            do {
                _ = try await repository.controlDownloadTaskResult(.init(task: task("downloading"), action: .pause)) { _ in
                    if conflict { throw AppError(category: .conflict, isRetryable: false, safeUserMessage: "合成冲突") }
                    throw CocoaError(.fileWriteNoPermission)
                }
                XCTFail("回调失败不得继续发送")
            } catch {}
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.map { Self.field("method", $0) }, ["list"])
        }
    }

    func test取消写前回调后仍不发送控制请求() async throws {
        let transport = MockHTTPTransport(responses: [page("downloading")]), repository = try repository(transport), gate = DownloadControlSaveGate()
        let original = task("downloading")
        let operation = Task {
            try await repository.controlDownloadTaskResult(.init(task: original, action: .pause)) { _ in await gate.wait() }
        }
        await gate.waitUntilStarted(); operation.cancel(); await gate.release()
        let result = try await operation.value
        XCTAssertEqual(result.result.status, .cancelledBeforeSubmission)
        XCTAssertFalse(result.result.submitted)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { Self.field("method", $0) }, ["list"])
    }

    func test重启读取无论状态是否符合都只读且缺任务保持缺失() async throws {
        for status in ["downloading", "paused"] {
            let transport = MockHTTPTransport(responses: [page(status)]), repository = try repository(transport)
            let task = try await repository.loadDownloadTaskControlState(id: "synthetic-1")
            XCTAssertEqual(task?.status, status)
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.map { Self.field("method", $0) }, ["list"])
        }
        let transport = MockHTTPTransport(responses: [response(#"{"tasks":[],"total":0}"#)])
        let missing = try await repository(transport).loadDownloadTaskControlState(id: "synthetic-1")
        XCTAssertNil(missing)
    }

    func test逗号和控制字符不能扩张单任务控制或恢复范围() async throws {
        for id in ["one,two", "one\ntwo", " one "] {
            let transport = MockHTTPTransport(responses: []), repository = try repository(transport)
            let result = try await repository.controlDownloadTaskResult(.init(task: .init(id: id, title: "合成任务", status: "downloading"), action: .pause))
            XCTAssertEqual(result.result.status, .confirmedFailure)
            XCTAssertFalse(result.result.submitted)
            do { _ = try await repository.loadDownloadTaskControlState(id: id); XCTFail("非法身份不能查询") } catch {}
            let requests = await transport.recordedRequests(); XCTAssertTrue(requests.isEmpty)
        }
    }

    func test原协议调用仍使用具体结果实现() async throws {
        let transport = MockHTTPTransport(responses: [page("paused"), response(#"{}"#), page("downloading")])
        let repository: any ServiceManagementRepository = try repository(transport)
        let outcome = try await repository.controlDownloadTaskResult(.init(task: task("paused"), action: .resume))
        XCTAssertEqual(outcome.result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { Self.field("method", $0) }, ["list", "resume", "list"])
    }

    func test持久终态结束旧回读保护后可再次执行相同动作() async throws {
        let transport = MockHTTPTransport(responses: [page("downloading"), response(#"{}"#), page("downloading"),
            page("paused"), page("downloading"), response(#"{}"#), page("paused")])
        let repository = try repository(transport), request = DownloadTaskControlRequest(task: task("downloading"), action: .pause)
        let unknown = try await repository.controlDownloadTaskResult(request)
        XCTAssertEqual(unknown.result.status, .submittedButUnverified)
        let recovered = try await repository.loadDownloadTaskControlState(id: "synthetic-1")
        XCTAssertEqual(recovered?.status, "paused")
        await repository.acknowledgeDownloadTaskControlResult(id: "synthetic-1", action: .pause)
        let next = try await repository.controlDownloadTaskResult(request)
        XCTAssertEqual(next.result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { Self.field("method", $0) == "pause" }.count, 2)
    }

    private func repository(_ transport: MockHTTPTransport) throws -> DsmServiceManagementRepository {
        try DsmServiceManagementRepository(
            profile: NasProfile(displayName: "合成设备", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet([DsmAPIName.downloadStationTask: ApiCapability(name: DsmAPIName.downloadStationTask,
                path: "entry.cgi", minVersion: 1, maxVersion: 3, requestFormat: .form, selectedVersion: 1)]),
            session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func task(_ status: String) -> DownloadStationTask { .init(id: "synthetic-1", title: "合成任务", status: status) }
    private func page(_ status: String) -> DsmHTTPResponse {
        response(#"{"tasks":[{"id":"synthetic-1","title":"合成任务","status":"\#(status)"}],"total":1,"offset":0}"#)
    }
    private func response(_ data: String) -> DsmHTTPResponse {
        .init(data: Data(#"{"success":true,"data":\#(data)}"#.utf8), statusCode: 200)
    }
    private static func field(_ key: String, _ request: URLRequest) -> String? {
        URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?
            .queryItems?.first { $0.name == key }?.value
    }
}

private actor DownloadControlSaveGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        started = true; waiters.forEach { $0.resume() }; waiters = []
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { waiters.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}

import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class ContainerDeletionFlowTests: XCTestCase {
    func test删除固定原目标与安全参数并依次记录边界() async throws {
        let transport = MockHTTPTransport(responses: [list(), success, list(ids: [])]), probe = ContainerDeletionProbe()
        try await repository(transport).deleteContainer(target()) { await probe.capture($0) }
        let points = await probe.points; XCTAssertEqual(points, [.willSubmit, .accepted, .verified])
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 3)
        let values = fields(calls[1]); XCTAssertEqual(values["version"], "1")
        XCTAssertEqual(values["name"], "sample-a"); XCTAssertEqual(values["force"], "false")
        XCTAssertEqual(values["preserve_profile"], "false"); XCTAssertNil(values["id"])
        XCTAssertNil(values["delete_volume"]); XCTAssertNil(values["delete_data"])
    }
    func test确认后的身份名称或原生状态变化均不提交() async throws {
        let cases = [list(ids: ["replacement"]), list(name: "renamed"), list(running: true),
                     list(paused: true), list(restarting: true), list(managed: true), list(missing: true)]
        for response in cases {
            let transport = MockHTTPTransport(responses: [response])
            do { try await repository(transport).deleteContainer(target()) { _ in XCTFail("不应进入提交边界") }; XCTFail("必须拒绝变化") }
            catch { XCTAssertEqual((error as? AppError)?.category, .conflict) }
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
        }
    }
    func test无法删除运行暂停未知或托管确认快照() async throws {
        let cases: [ContainerControlState] = [target(running: true), target(paused: true), target(restarting: true), target(managed: true), target(managed: nil)]
        let transport = MockHTTPTransport(responses: []), adapter = try repository(transport)
        for value in cases {
            XCTAssertFalse(value.canDelete)
            do { try await adapter.deleteContainer(value) { _ in XCTFail("零写入") }; XCTFail("不能删除") } catch { }
        }
        let calls = await transport.recordedRequests(); XCTAssertTrue(calls.isEmpty)
    }
    func test保存三个边界失败原样抛出且不继续请求() async throws {
        for boundary in [ContainerControlStage.willSubmit, .accepted, .verified] {
            let transport = MockHTTPTransport(responses: [list(), success, list(ids: [])])
            do {
                try await repository(transport).deleteContainer(target()) { if $0 == boundary { throw ContainerDeletionStorageError() } }
                XCTFail("应保留存储失败")
            } catch { XCTAssertTrue(error is ContainerDeletionStorageError) }
            let calls = await transport.recordedRequests()
            XCTAssertEqual(calls.count, boundary == .willSubmit ? 1 : boundary == .accepted ? 2 : 3)
        }
    }
    func test明确拒绝记录后直接抛出且不认领外部删除() async throws {
        let transport = MockHTTPTransport(responses: [list(), denied, list(ids: [])]), probe = ContainerDeletionProbe()
        let adapter = try repository(transport)
        do { try await adapter.deleteContainer(target()) { await probe.capture($0) }; XCTFail("必须拒绝") }
        catch { XCTAssertEqual((error as? AppError)?.category, .permissionDenied) }
        let points = await probe.points; XCTAssertEqual(points, [.willSubmit, .rejected])
        let before = await transport.recordedRequests(); XCTAssertEqual(before.count, 2)
        let values = try await adapter.loadContainerControlStates(); XCTAssertTrue(values.isEmpty)
        let after = await probe.points; XCTAssertEqual(after, points)
    }
    func test拒绝回执存储失败不能吞掉本地错误() async throws {
        let transport = MockHTTPTransport(responses: [list(), denied])
        do {
            try await repository(transport).deleteContainer(target()) { if $0 == .rejected { throw ContainerDeletionStorageError() } }
            XCTFail("应保留存储失败")
        } catch { XCTAssertTrue(error is ContainerDeletionStorageError) }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
    }
    func test未知删除禁止重新删除与启停并由只读清单解除() async throws {
        let transport = MockHTTPTransport(steps: [.response(list()), .urlError(.networkConnectionLost), .response(list(ids: []))])
        let adapter = try repository(transport), original = target()
        do { try await adapter.deleteContainer(original) { _ in }; XCTFail("应保留未知") } catch { }
        do { try await adapter.deleteContainer(original) { _ in XCTFail("不能重发") }; XCTFail("不能重复删除") } catch { }
        do { try await adapter.controlContainer(original, action: .start) { _ in XCTFail("不能控制") }; XCTFail("不能绕过旧删除") } catch { }
        let values = try await adapter.loadContainerControlStates(); XCTAssertTrue(values.isEmpty)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.filter { fields($0)["method"] == "delete" }.count, 1)
    }
    func test启停未知不能绕过为删除() async throws {
        let transport = MockHTTPTransport(steps: [.response(list()), .urlError(.networkConnectionLost)])
        let adapter = try repository(transport)
        do { try await adapter.controlContainer(target(), action: .start) { _ in }; XCTFail("应保留未知") } catch { }
        do { try await adapter.deleteContainer(target()) { _ in XCTFail("不能绕过") }; XCTFail("不能删除") } catch { }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
    }
    func test回读保留原ID或目录不完整不报成功() async throws {
        let incomplete = reply(#"{"success":true,"data":{"containers":[],"total":1}}"#)
        for result in [list(), incomplete] {
            let transport = MockHTTPTransport(responses: [list(), success, result]), probe = ContainerDeletionProbe()
            do { try await repository(transport).deleteContainer(target()) { await probe.capture($0) }; XCTFail("不能报成功") } catch { }
            let points = await probe.points; XCTAssertEqual(points, [.willSubmit, .accepted])
        }
    }
    func test读取拒绝缺页及错误类型的完整清单标记() async throws {
        for metadata in [#""total":1"#, #""total":true"#, #""total":"0""#, #""total":0.5"#, #""offset":1"#, #""offset":null"#] {
            let transport = MockHTTPTransport(responses: [reply("{\"success\":true,\"data\":{\"containers\":[],\(metadata)}}")])
            do { _ = try await repository(transport).loadContainerControlStates(); XCTFail("不完整目录不能解除保护") }
            catch { XCTAssertEqual((error as? AppError)?.category, .invalidResponse) }
        }
    }
    func test同名替换仅确认原ID消失不会继续删除新容器() async throws {
        let transport = MockHTTPTransport(responses: [list(), success, list(ids: ["replacement"], name: "sample-a")])
        try await repository(transport).deleteContainer(target()) { _ in }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.filter { fields($0)["method"] == "delete" }.count, 1)
    }
    func test证书失败停止预检提交与回读包括旧入口() async throws {
        for legacy in [false, true] {
            for step in 0...2 {
                let before: [MockHTTPTransport.Step] = [.response(list()), .response(success)]
                let transport = MockHTTPTransport(steps: Array(before.prefix(step)) + [.urlError(.serverCertificateUntrusted)])
                do {
                    let adapter = try repository(transport)
                    if legacy { _ = try await adapter.deleteContainersResult(ids: ["a"]) }
                    else { try await adapter.deleteContainer(target()) { _ in } }
                    XCTFail("应保留证书错误")
                } catch { XCTAssertEqual((error as? AppError)?.category, .tlsUntrusted) }
                let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, step + 1)
            }
        }
    }
    func test旧批量第二项变化区分前项未知与后项未提交() async throws {
        let transport = MockHTTPTransport(responses: [list(ids: ["a", "b"]), success, list(ids: ["replacement"])])
        let result = try await repository(transport).deleteContainersResult(ids: ["a", "b"])
        XCTAssertTrue(result.submitted); XCTAssertEqual(result.counts.unknown, 1); XCTAssertEqual(result.counts.failed, 1)
        XCTAssertNotEqual(result.status, .confirmedSuccess)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.filter { fields($0)["method"] == "delete" }.count, 1)
    }
    func test旧批量第二项拒绝不能把前项计为失败或认领后项() async throws {
        let transport = MockHTTPTransport(responses: [list(ids: ["a", "b"]), success, list(ids: ["b"]), denied])
        let result = try await repository(transport).deleteContainersResult(ids: ["a", "b"])
        XCTAssertEqual(result.status, .permissionDenied); XCTAssertEqual(result.counts.unknown, 1)
        XCTAssertEqual(result.counts.failed, 1); XCTAssertEqual(result.counts.succeeded, 0)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 4)
    }
    private var success: DsmHTTPResponse { reply(#"{"success":true}"#) }
    private var denied: DsmHTTPResponse { reply(#"{"success":false,"error":{"code":105}}"#) }
    private func reply(_ json: String) -> DsmHTTPResponse { .init(data: Data(json.utf8), statusCode: 200) }
    private func target(running: Bool? = false, paused: Bool? = false, restarting: Bool? = false, managed: Bool? = false) -> ContainerControlState {
        .init(id: "a", name: "sample-a", running: running, paused: paused, restarting: restarting,
              startedAt: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"), managedByPackage: managed)
    }
    private func list(ids: [String] = ["a"], name: String? = nil, running: Bool = false, paused: Bool = false,
                      restarting: Bool = false, managed: Bool = false, missing: Bool = false) -> DsmHTTPResponse {
        let values: [[String: Any]] = ids.map { id in
            var state: [String: Any] = ["Running": running, "Paused": paused, "Restarting": restarting, "StartedAt": "2026-01-01T00:00:00Z"]
            if missing { state["Running"] = nil }
            return ["id": id, "name": name ?? "sample-\(id)", "image": "sample:latest", "status": "stopped",
                    "is_package": managed, "State": state, "Labels": [:]]
        }
        return .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": ["containers": values]]), statusCode: 200)
    }
    private func fields(_ request: URLRequest) -> [String: String] {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    private func repository(_ transport: any DsmHTTPTransport) throws -> DsmServiceManagementRepository {
        let name = DsmAPIName.dockerContainer
        return try .init(profile: .init(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001),
            capabilities: .init([name: .init(name: name, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .form, selectedVersion: 2)]),
            session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
}

private struct ContainerDeletionStorageError: Error { }
private actor ContainerDeletionProbe {
    var points: [ContainerControlStage] = []
    func capture(_ point: ContainerControlStage) { points.append(point) }
}

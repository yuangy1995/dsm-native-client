import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class ContainerNetworkManagementTests: XCTestCase {
    func test创建只按固定v1参数且记录四个结果边界() async throws {
        let transport = MockHTTPTransport(responses: [list(empty: true), reply(#"{"success":true}"#), list()])
        let probe = NetworkCheckpointProbe()
        try await repository(transport).createContainerNetwork(.init(name: "sample-network")) { await probe.record($0) }
        let stages = await probe.stages; XCTAssertEqual(stages, ["willSubmit", "accepted", "verified"])
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.map { fields($0)["method"] }, ["list", "create", "list"])
        XCTAssertEqual(fields(calls[1])["version"], "1"); XCTAssertNil(fields(calls[1])["driver"])
    }
    func test创建无回执同名仅报告存在不冒充创建完成且不重写() async throws {
        let transport = MockHTTPTransport(steps: [.response(list(empty: true)), .urlError(.networkConnectionLost), .response(list())])
        let adapter = try repository(transport), value = ContainerNetworkCreation(name: "sample-network")
        do { try await adapter.createContainerNetwork(value); XCTFail("应保留未知") } catch { }
        let outcome = try await adapter.reviewContainerNetworkCreation(.init(value), accepted: false)
        XCTAssertEqual(outcome, .existing)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.filter { fields($0)["method"] == "create" }.count, 1)
    }
    func test创建接受后配置不同保留未知且只读() async throws {
        let transport = MockHTTPTransport(responses: [list()])
        var configuration = ContainerNetworkCreation(name: "sample-network"); configuration.isIPv6Enabled = true
        configuration.ipv6Subnet = "2001:db8::/64"; configuration.ipv6Gateway = "2001:db8::1"
        let result = try await repository(transport).reviewContainerNetworkCreation(.init(configuration), accepted: true)
        XCTAssertEqual(result, .pending)
    }
    func test删除绑定原快照单目标数组与记录边界() async throws {
        let transport = MockHTTPTransport(responses: [list(), reply(#"{"success":true,"data":{"failed":[]}}"#), list(empty: true)])
        let probe = NetworkCheckpointProbe()
        try await repository(transport).deleteContainerNetwork(target()) { await probe.record($0) }
        let stages = await probe.stages; XCTAssertEqual(stages, ["willSubmit", "accepted", "verified"])
        let calls = await transport.recordedRequests(), payload = fields(calls[1])
        XCTAssertEqual(payload["version"], "1"); XCTAssertEqual(payload["method"], "remove"); XCTAssertNil(payload["id"])
        let objects = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(payload["networks"]).utf8)) as? [[String: Any]])
        XCTAssertEqual(objects.count, 1); XCTAssertEqual(objects[0]["id"] as? String, "network-a")
        XCTAssertEqual(objects[0]["_key"] as? String, "network-a"); XCTAssertEqual(objects[0]["containers"] as? [String], [])
    }
    func test单项删除非空失败数组保留拒绝不读取外部结果() async throws {
        let transport = MockHTTPTransport(responses: [list(), reply(#"{"success":true,"data":{"failed":["sample-network"]}}"#), list(empty: true)])
        let probe = NetworkCheckpointProbe()
        do { try await repository(transport).deleteContainerNetwork(target()) { await probe.record($0) }; XCTFail("不能成功") } catch { }
        let stages = await probe.stages; XCTAssertEqual(stages, ["willSubmit", "rejected"])
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
    }
    func test读前及读后不完整清单都不能认领缺失() async throws {
        for body in [#"{"network":[],"total":1}"#, #"{"network":[],"offset":1}"#, #"{"network":[],"total":false}"#,
                     #"{"network":[{"id":"a","containers":[]}]}"#] {
            let transport = MockHTTPTransport(responses: [reply("{\"success\":true,\"data\":\(body)}")])
            do { _ = try await repository(transport).reviewContainerNetworkDeletion(.init(target())); XCTFail("错误清单不能证明已删除") }
            catch { XCTAssertEqual((error as? AppError)?.category, .invalidResponse) }
        }
    }
    func test每个记录边界失败均停止后续请求() async throws {
        for point in ["willSubmit", "accepted", "verified", "rejected"] {
            let transport = MockHTTPTransport(responses: [list(), point == "rejected" ? denied : reply(#"{"success":true,"data":{"failed":[]}}"#), list(empty: true)])
            do {
                try await repository(transport).deleteContainerNetwork(target()) { if String(describing: $0) == point { throw NetworkStorageFailure() } }
                XCTFail("必须保留存储错误")
            } catch { XCTAssertTrue(error is NetworkStorageFailure) }
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, point == "willSubmit" ? 1 : point == "verified" ? 3 : 2)
        }
    }
    func test证书错误在每个边界原样停止不重试() async throws {
        for index in 0...2 {
            let steps: [MockHTTPTransport.Step] = [.response(list()), .response(reply(#"{"success":true,"data":{"failed":[]}}"#))]
            let transport = MockHTTPTransport(steps: Array(steps.prefix(index)) + [.urlError(.serverCertificateUntrusted)])
            do { try await repository(transport).deleteContainerNetwork(target()) { _ in }; XCTFail("必须保留证书错误") }
            catch { XCTAssertEqual((error as? AppError)?.category, .tlsUntrusted) }
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, index + 1)
        }
    }
    func test未知删除禁止重放及同名创建() async throws {
        let transport = MockHTTPTransport(steps: [.response(list()), .urlError(.networkConnectionLost)])
        let adapter = try repository(transport)
        do { try await adapter.deleteContainerNetwork(target()) { _ in }; XCTFail("应保留未知") } catch { }
        do { try await adapter.deleteContainerNetwork(target()) { _ in XCTFail("不能发送") }; XCTFail("不能重放") } catch { }
        do { try await adapter.createContainerNetwork(.init(name: "sample-network")); XCTFail("不能绕过删除") } catch { }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
    }
    func test创建明确拒绝后不能认领外部同名网络() async throws {
        let transport = MockHTTPTransport(responses: [list(empty: true), denied, list()])
        let adapter = try repository(transport), configuration = ContainerNetworkCreation(name: "sample-network")
        do { try await adapter.createContainerNetwork(configuration); XCTFail("应保留拒绝") } catch { }
        do { try await adapter.createContainerNetwork(configuration); XCTFail("同名外部网络不能判作原创建成功") } catch { }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 3)
    }
    func test删除明确拒绝不能被外部消失覆盖() async throws {
        let transport = MockHTTPTransport(responses: [list(), list(), denied, list(empty: true)])
        let result = try await repository(transport).deleteContainerNetworksResult(ids: ["network-a"])
        XCTAssertNotEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.counts.succeeded, 0)
    }
    func test删除预检使用中不能被外部消失当作已提交() async throws {
        let transport = MockHTTPTransport(responses: [list(), list(inUse: true), list(empty: true)])
        let result = try await repository(transport).deleteContainerNetworksResult(ids: ["network-a"])
        XCTAssertNotEqual(result.status, .confirmedSuccess)
        XCTAssertFalse(result.submitted)
        let calls = await transport.recordedRequests()
        XCTAssertTrue(calls.allSatisfy { fields($0)["method"] == "list" })
    }
    func test旧批量入口丢失删除回执后原身份消失仍不认领本次成功() async throws {
        let transport = MockHTTPTransport(steps: [.response(list()), .response(list()), .urlError(.networkConnectionLost),
            .response(list(empty: true)), .response(list(empty: true))])
        let adapter = try repository(transport)
        let original = try await adapter.deleteContainerNetworksResult(ids: ["network-a"])
        XCTAssertEqual(original.status, .submittedButUnverified)
        let recovered = try await adapter.deleteContainerNetworksResult(ids: ["network-a"])
        XCTAssertEqual(recovered.status, .submittedButUnverified); XCTAssertEqual(recovered.counts.succeeded, 0)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.filter { fields($0)["method"] == "remove" }.count, 1)
    }
    func test旧批量入口保留接受回执后可只读恢复完成() async throws {
        let transport = MockHTTPTransport(steps: [.response(list()), .response(list()),
            .response(reply(#"{"success":true,"data":{"failed":[]}}"#)), .urlError(.networkConnectionLost),
            .response(list(empty: true)), .response(list(empty: true))])
        let adapter = try repository(transport)
        let original = try await adapter.deleteContainerNetworksResult(ids: ["network-a"])
        XCTAssertEqual(original.status, .submittedButUnverified)
        let recovered = try await adapter.deleteContainerNetworksResult(ids: ["network-a"])
        XCTAssertEqual(recovered.status, .confirmedSuccess); XCTAssertEqual(recovered.counts.succeeded, 1)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.filter { fields($0)["method"] == "remove" }.count, 1)
    }
    private var denied: DsmHTTPResponse { reply(#"{"success":false,"error":{"code":105}}"#) }
    private func target() -> ContainerNetwork {
        .init(id: "network-a", name: "sample-network", driver: "bridge", isIPv6Enabled: false, connectedContainerNames: [])
    }
    private func reply(_ value: String) -> DsmHTTPResponse { .init(data: Data(value.utf8), statusCode: 200) }
    private func list(empty: Bool = false, inUse: Bool = false) -> DsmHTTPResponse {
        let rows: [[String: Any]] = empty ? [] : [["id": "network-a", "name": "sample-network", "driver": "bridge",
            "containers": inUse ? ["sample-container"] : [], "enable_ipv6": false]]
        return .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": ["network": rows]]), statusCode: 200)
    }
    private func fields(_ request: URLRequest) -> [String: String] {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    private func repository(_ transport: any DsmHTTPTransport) throws -> DsmServiceManagementRepository {
        let name = DsmAPIName.dockerNetwork
        return try .init(profile: .init(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001),
            capabilities: .init([name: .init(name: name, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form, selectedVersion: 1)]),
            session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport,
            containerNetworkCreationEnabled: true)
    }
}

private struct NetworkStorageFailure: Error { }
private actor NetworkCheckpointProbe {
    var stages: [String] = []
    func record(_ stage: ContainerNetworkMutationStage) { stages.append(String(describing: stage)) }
}

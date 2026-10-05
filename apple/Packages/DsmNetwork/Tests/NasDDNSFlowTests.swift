import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class NasDDNSFlowTests: XCTestCase {
    func test四动作检查点分别位于唯一请求前和成功回执后() async throws {
        let record = record(), edited = draft(original: "Example", hostname: "updated.example.invalid")
        let changes: [(NasDDNSChange, String, String)] = [
            (.test(original: record, draft: edited), "test", records()),
            (.save(original: record, draft: edited), "set", records(hostname: "updated.example.invalid")),
            (.delete(record), "delete", empty),
            (.updateAddress(providerIDs: ["Example"]), "update_ip_address", records())
        ]
        for (change, method, after) in changes {
            var responses = [response(providers), response(records()), response(#"{"success":true}"#)]
            if method != "test" { responses += [response(providers), response(after)] }
            let transport = MockHTTPTransport(responses: responses), journal = DDNSCheckpoints()
            let repository = try repository(transport)
            let result = try await repository.changeDDNSResult(change) { stage in
                let count = await transport.recordedRequests().count
                await journal.append(stage, count: count)
            }
            XCTAssertEqual(result.status, .confirmedSuccess)
            let checkpoints = await journal.values
            XCTAssertEqual(checkpoints, ["before:2", "accepted:3"])
            let calls = await transport.recordedRequests()
            XCTAssertEqual(calls.filter { field("method", $0) != "list" }.map { field("method", $0) }, [method])
        }
    }

    func test新建保存没有隐式连接测试或地址更新() async throws {
        let transport = MockHTTPTransport(responses: [response(providers), response(empty), response(#"{"success":true}"#), response(providers), response(records())])
        let result = try await repository(transport).changeDDNSResult(.save(original: nil, draft: draft())) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.recordedRequests()
        XCTAssertEqual(calls.map { field("method", $0) }, ["list", "list", "create", "list", "list"])
    }

    func test写前记录失败零提交() async throws {
        let transport = MockHTTPTransport(responses: [response(providers), response(records())])
        do {
            _ = try await repository(transport).changeDDNSResult(.delete(record())) { _ in throw DDNSJournalError.unavailable }
            XCTFail("记录失败必须终止提交")
        } catch { XCTAssertTrue(error is DDNSJournalError) }
        let calls = await transport.recordedRequests()
        XCTAssertEqual(calls.count, 2)
    }

    func test确认后的记录变化或全局目标变化零写() async throws {
        for change in [NasDDNSChange.delete(record()), .save(original: record(), draft: draft(original: "Example")),
                       .test(original: record(), draft: draft(original: "Example")), .updateAddress(providerIDs: ["Example", "Other"])] {
            let transport = MockHTTPTransport(responses: [response(providers), response(records(hostname: "changed.example.invalid"))])
            let result = try await repository(transport).changeDDNSResult(change) { _ in XCTFail("快照冲突不能进入提交边界") }
            XCTAssertEqual(result.status, .confirmedFailure); XCTAssertFalse(result.submitted)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
        }
    }

    func test管理读取缺少字段和畸形记录不能解释为空或关闭() async throws {
        for value in [#"{}"#, #"{"records":{}}"#, #"{"records":[null]}"#,
                      #"{"records":[{"provider":"Example","hostname":"nas.example.invalid","enable":true,"heartbeat":false}]}"#,
                      #"{"records":[{"provider":"Example","hostname":"nas.example.invalid","username":"synthetic-user","enable":"unexpected","heartbeat":false}]}"#] {
            let transport = MockHTTPTransport(responses: [response(providers), response("{\"success\":true,\"data\":\(value)}")])
            do { _ = try await repository(transport).loadDDNSForManagement(); XCTFail("不完整列表必须失败") }
            catch { XCTAssertEqual((error as? AppError)?.category, .invalidResponse) }
        }
    }

    func test缺少任一能力时管理读取零请求() async throws {
        for names in [[DsmAPIName.coreDDNSProvider], [DsmAPIName.coreDDNSRecord], []] {
            let transport = MockHTTPTransport(responses: [])
            do { _ = try await repository(transport, names: names).loadDDNSForManagement(); XCTFail("能力不足必须拒绝") }
            catch { XCTAssertEqual((error as? AppError)?.category, .apiUnavailable) }
            let calls = await transport.recordedRequests(); XCTAssertTrue(calls.isEmpty)
        }
    }

    func test删除回执丢失后畸形列表不能冒报删除成功() async throws {
        let transport = MockHTTPTransport(steps: [.response(response(providers)), .response(response(records())), .urlError(.networkConnectionLost),
            .response(response(providers)), .response(response(#"{"success":true,"data":{}}"#))])
        let result = try await repository(transport).changeDDNSResult(.delete(record())) { _ in }
        XCTAssertEqual(result.status, .submittedButUnverified)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.filter { field("method", $0) == "delete" }.count, 1)
    }

    func test编辑不补造缺失的网络配置也不提交空密码() async throws {
        let transport = MockHTTPTransport(responses: [response(providers), response(records()), response(#"{"success":true}"#),
            response(providers), response(records(hostname: "updated.example.invalid"))])
        let change = NasDDNSChange.save(original: record(), draft: draft(original: "Example", hostname: "updated.example.invalid", password: ""))
        let result = try await repository(transport).changeDDNSResult(change) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.recordedRequests(), write = calls[2]
        for key in ["net", "ip", "ipv6", "interface_v4", "interface_v6", "passwd"] { XCTAssertNil(field(key, write), key) }
        XCTAssertEqual(field("id", write), "Example")
    }

    func test编辑期间公网地址变化不冲突且不回写旧地址() async throws {
        let before = records().replacingOccurrences(of: "\"heartbeat\":false", with: "\"heartbeat\":false,\"ip\":\"192.0.2.20\"")
        let transport = MockHTTPTransport(responses: [response(providers), response(before), response(#"{"success":true}"#),
            response(providers), response(records(hostname: "updated.example.invalid"))])
        let original = record(ipv4: "192.0.2.10")
        let change = NasDDNSChange.save(original: original, draft: draft(original: "Example", hostname: "updated.example.invalid", password: ""))
        let result = try await repository(transport).changeDDNSResult(change) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.recordedRequests()
        XCTAssertEqual(field("ip", calls[2]), "192.0.2.20")
    }

    func test仅换凭据回执丢失不产生接受检查点() async throws {
        let transport = MockHTTPTransport(steps: [.response(response(providers)), .response(response(records())), .urlError(.timedOut)])
        let journal = DDNSCheckpoints()
        let result = try await repository(transport).changeDDNSResult(.save(original: record(), draft: draft(original: "Example"))) { stage in
            await journal.append(stage, count: transport.recordedRequests().count)
        }
        XCTAssertEqual(result.status, .submittedButUnverified)
        let checkpoints = await journal.values; XCTAssertEqual(checkpoints, ["before:2"])
    }

    private var providers: String { #"{"success":true,"data":{"providers":[{"id":"Example","display":"Synthetic provider"}]}}"# }
    private var empty: String { #"{"success":true,"data":{"records":[]}}"# }
    private func records(hostname: String = "nas.example.invalid") -> String {
        "{\"success\":true,\"data\":{\"records\":[{\"provider\":\"Example\",\"hostname\":\"\(hostname)\",\"username\":\"synthetic-user\",\"enable\":true,\"heartbeat\":false}]}}"
    }
    private func record(ipv4: String? = nil) -> NasDDNSRecord {
        .init(id: "Example", providerID: "Example", providerName: "Synthetic provider", hostname: "nas.example.invalid", address: nil,
              status: nil, lastUpdated: nil, isEnabled: true, username: "synthetic-user", networkType: nil, ipv4: ipv4, ipv6: nil,
              interfaceV4: nil, interfaceV6: nil, heartbeat: false)
    }
    private func draft(original: String? = nil, hostname: String = "nas.example.invalid", password: String = "synthetic-only") -> NasDDNSDraft {
        .init(originalProviderID: original, providerID: "Example", hostname: hostname, username: "synthetic-user", password: password)
    }
    private func response(_ text: String) -> DsmHTTPResponse { .init(data: Data(text.utf8), statusCode: 200) }
    private func repository(_ transport: MockHTTPTransport, names: [String] = [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord]) throws -> DsmNasAdministrationRepository {
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: names.map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form, selectedVersion: 1)) }))
        return try DsmNasAdministrationRepository(profile: NasProfile(displayName: "Synthetic", host: "nas.example.invalid", port: 5001), capabilities: capabilities,
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func field(_ key: String, _ request: URLRequest) -> String? {
        URLComponents(string: "https://fixture.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems?.first { $0.name == key }?.value
    }
}
private actor DDNSCheckpoints {
    private(set) var values: [String] = []
    func append(_ stage: NasDDNSCheckpoint, count: Int) { values.append("\(stage == .willSubmit ? "before" : "accepted"):\(count)") }
}
private enum DDNSJournalError: Error { case unavailable }

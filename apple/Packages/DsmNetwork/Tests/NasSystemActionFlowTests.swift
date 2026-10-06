import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class NasSystemActionFlowTests: XCTestCase {
    private let service: [String: Any] = ["pid": 201, "who": "sample-user", "from": "client.example.invalid", "type": "SMB", "protocol": "SMB3", "descr": "Synthetic", "can_be_kicked": true, "is_current_connected": false]
    func test服务连接使用刚读目标和v1且完整消失才成功() async throws {
        let page = list([service]), transport = SystemFlowTransport([.value(page), .value(page), .value([:]), .value(list([]))])
        let repo = try repository(transport), log = SystemCheckpointLog()
        let before = try await repo.loadConnectionsForManagement(), target = try XCTUnwrap(before.connections.first)
        let result = try await repo.performSystemActionResult(.disconnect(target)) { await log.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.calls, checkpoints = await log.values
        XCTAssertEqual(calls.map { $0["method"] }, ["list", "list", "kick_connection", "list"])
        XCTAssertTrue(calls.allSatisfy { $0["version"] == "1" }); XCTAssertEqual(checkpoints, [.willSubmit, .accepted])
        let objects = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(calls[2]["service_conn"]).utf8)) as? [[String: String]]
        XCTAssertEqual(objects, [["pid":"201", "type":"SMB", "who":"sample-user", "from":"client.example.invalid"]])
        XCTAssertEqual(calls[2]["http_conn"], "[]"); XCTAssertNil(calls[2]["id"])
    }
    func test网页连接绑定原设备标识并单独编码() async throws {
        var row = service; row.removeValue(forKey: "pid"); row["did"] = "synthetic-device"; row["type"] = "HTTP/HTTPS"; row["is_current_connected"] = true
        let page = list([row]), transport = SystemFlowTransport([.value(page), .value(page), .value([:]), .value(list([]))]), repo = try repository(transport)
        let values = try await repo.loadConnectionsForManagement(), target = try XCTUnwrap(values.connections.first)
        XCTAssertTrue(target.isCurrentConnection)
        let result = try await repo.performSystemActionResult(.disconnect(target)) { _ in }; XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.calls, objects = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(calls[2]["http_conn"]).utf8)) as? [[String: String]]
        XCTAssertEqual(objects, [["did":"synthetic-device", "descr":"Synthetic", "who":"sample-user", "from":"client.example.invalid"]]); XCTAssertEqual(calls[2]["service_conn"], "[]")
    }
    func test目标变化和部分目录均零写入() async throws {
        for incomplete in [false, true] {
            var changed = service; changed["who"] = "another-user"
            let transport = SystemFlowTransport([.value(list([service])), .value(incomplete ? ["items":[service], "total":500] : list([changed]))]), repo = try repository(transport)
            let page = try await repo.loadConnectionsForManagement(), target = try XCTUnwrap(page.connections.first)
            let result = try await repo.performSystemActionResult(.disconnect(target)) { _ in XCTFail() }
            XCTAssertFalse(result.submitted); let calls = await transport.calls; XCTAssertEqual(calls.count, 2)
        }
    }
    func test缺少原始标识不能由账号拼接请求() async throws {
        var row = service; row.removeValue(forKey: "pid")
        let transport = SystemFlowTransport([.value(list([row]))]), repo = try repository(transport)
        let page = try await repo.loadConnectionsForManagement(), target = try XCTUnwrap(page.connections.first)
        XCTAssertFalse(target.canDisconnect); XCTAssertFalse(target.hasDisconnectIdentity)
        let result = try await repo.performSystemActionResult(.disconnect(target)) { _ in XCTFail() }
        XCTAssertFalse(result.submitted); let calls = await transport.calls; XCTAssertEqual(calls.count, 1)
    }
    func test无回执但完整目录目标消失可确认且没有重发() async throws {
        let page = list([service]), transport = SystemFlowTransport([.value(page), .value(page), .error(.timeout), .value(list([]))]), repo = try repository(transport), log = SystemCheckpointLog()
        let values = try await repo.loadConnectionsForManagement(), target = try XCTUnwrap(values.connections.first)
        let result = try await repo.performSystemActionResult(.disconnect(target)) { await log.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess); let calls = await transport.calls, stages = await log.values
        XCTAssertEqual(calls.filter { $0["method"] == "kick_connection" }.count, 1); XCTAssertEqual(stages, [.willSubmit])
    }
    func test原始标识仍在或相似条目缺标识均保持未知() async throws {
        for missing in [false, true] {
            var row = service
            if missing { row.removeValue(forKey: "pid") } else { row["type"] = "AFP" }
            let page = list([service]), after = list([row])
            let transport = SystemFlowTransport([.value(page), .value(page), .value([:])] + Array(repeating: .value(after), count: 4)), repo = try repository(transport)
            let values = try await repo.loadConnectionsForManagement(), target = try XCTUnwrap(values.connections.first)
            let result = try await repo.performSystemActionResult(.disconnect(target)) { _ in }
            XCTAssertEqual(result.status, .submittedButUnverified); let calls = await transport.calls
            XCTAssertEqual(calls.filter { $0["method"] == "kick_connection" }.count, 1); XCTAssertEqual(calls.filter { $0["method"] == "list" }.count, 6)
        }
    }
    func test明确拒绝后不继续读回冒充成功() async throws {
        let page = list([service]), transport = SystemFlowTransport([.value(page), .value(page), .error(.permissionDenied)]), repo = try repository(transport)
        let values = try await repo.loadConnectionsForManagement(), target = try XCTUnwrap(values.connections.first)
        let result = try await repo.performSystemActionResult(.disconnect(target)) { _ in }
        XCTAssertEqual(result.status, .permissionDenied); let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "kick_connection")
    }
    func test缺标识相似条目时间变化仍保持未知() async throws {
        var original = service; original["time"] = "2026-10-06 08:15:00"
        var later = original; later.removeValue(forKey: "pid"); later["time"] = "2026-10-06 01:15:00"
        let page = list([original]), transport = SystemFlowTransport([.value(page), .value(page), .error(.timeout), .value(list([later]))])
        let repo = try repository(transport), values = try await repo.loadConnectionsForManagement()
        let result = try await repo.performSystemActionResult(.disconnect(try XCTUnwrap(values.connections.first))) { _ in }
        XCTAssertEqual(result.status, .submittedButUnverified)
        let calls = await transport.calls; XCTAssertEqual(calls.filter { $0["method"] == "kick_connection" }.count, 1)
    }
    func test写前或回执持久化失败均停止后续请求() async throws {
        for receipt in [false, true] {
            let page = list([service]), transport = SystemFlowTransport([.value(page), .value(page), .value([:])]), repo = try repository(transport)
            let values = try await repo.loadConnectionsForManagement(), target = try XCTUnwrap(values.connections.first)
            do {
                _ = try await repo.performSystemActionResult(.disconnect(target)) { phase in
                    if phase == (receipt ? .accepted : .willSubmit) { throw SystemJournalError.failed }
                }; XCTFail()
            } catch { XCTAssertTrue(error is SystemJournalError) }
            let calls = await transport.calls; XCTAssertEqual(calls.count, receipt ? 3 : 2)
        }
    }
    func test新旧断开入口共享同目标互斥() async throws {
        let page = list([service]), transport = SystemFlowTransport([.value(page), .value(page), .value([:]), .value(list([]))]), repo = try repository(transport)
        let values = try await repo.loadConnectionsForManagement(), target = try XCTUnwrap(values.connections.first)
        let result = try await repo.performSystemActionResult(.disconnect(target)) { stage in
            if stage == .willSubmit {
                do { try await repo.disconnectConnection(target); XCTFail() } catch { XCTAssertEqual((error as? AppError)?.category, .conflict) }
            }
        }
        XCTAssertEqual(result.status, .confirmedSuccess); let calls = await transport.calls; XCTAssertEqual(calls.count, 4)
    }
    func test电源固定v3独立预检回执且不回读最终状态() async throws {
        for action in [NasPowerAction.shutdown, .reboot] {
            let transport = SystemFlowTransport([.value([:]), .value([:])]), repo = try repository(transport), log = SystemCheckpointLog()
            let result = try await repo.performSystemActionResult(.power(action)) { await log.append($0) }
            XCTAssertEqual(result.status, .confirmedSuccess); let calls = await transport.calls, stages = await log.values
            XCTAssertEqual(calls.map { $0["method"] }, ["info", action.rawValue]); XCTAssertTrue(calls.allSatisfy { $0["version"] == "3" })
            XCTAssertEqual(stages, [.willSubmit, .accepted])
        }
    }
    func test电源预检拒绝与不支持版本均零写入() async throws {
        let denied = SystemFlowTransport([.error(.permissionDenied)]), first = try repository(denied)
        let result = try await first.performSystemActionResult(.power(.shutdown)) { _ in XCTFail() }; XCTAssertEqual(result.status, .permissionDenied); XCTAssertFalse(result.submitted)
        let unavailable = SystemFlowTransport([]), second = try repository(unavailable, maximum: 2)
        let unsupported = try await second.performSystemActionResult(.power(.reboot)) { _ in XCTFail() }; XCTAssertEqual(unsupported.status, .unsupported)
        let calls = await unavailable.calls; XCTAssertTrue(calls.isEmpty)
    }
    func test电源模糊提交和提交阶段取消不回读不重发() async throws {
        for error in [AppErrorCategory.timeout, .cancelled] {
            let transport = SystemFlowTransport([.value([:]), .error(error)]), repo = try repository(transport), log = SystemCheckpointLog()
            let result = try await repo.performSystemActionResult(.power(.shutdown)) { await log.append($0) }
            XCTAssertEqual(result.status, error == .cancelled ? .cancellationRequestedAfterSubmission : .submittedButUnverified)
            let calls = await transport.calls, stages = await log.values; XCTAssertEqual(calls.count, 2); XCTAssertEqual(stages, [.willSubmit])
        }
    }
    func test电源写前取消与记录失败均零提交() async throws {
        for cancel in [false, true] {
            let transport = SystemFlowTransport([.value([:])]), repo = try repository(transport)
            let task = Task {
                try await repo.performSystemActionResult(.power(.shutdown)) { _ in
                    if cancel { withUnsafeCurrentTask { $0?.cancel() } } else { throw SystemJournalError.failed }
                }
            }
            if cancel { let value = try await task.value; XCTAssertEqual(value.status, .cancelledBeforeSubmission) }
            else { do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is SystemJournalError) } }
            let calls = await transport.calls; XCTAssertEqual(calls.count, 1)
        }
    }
    func test新旧电源动作共用互斥且恢复仅info() async throws {
        let transport = SystemFlowTransport([.value([:]), .value([:]), .value([:])]), repo = try repository(transport)
        let value = try await repo.performSystemActionResult(.power(.shutdown)) { stage in
            if stage == .willSubmit {
                let duplicate = try await repo.performPowerActionResult(.reboot)
                XCTAssertFalse(duplicate.submitted); XCTAssertEqual(duplicate.errorCategory, .conflict)
            }
        }
        XCTAssertEqual(value.status, .confirmedSuccess); try await repo.verifyPowerConnection()
        let calls = await transport.calls; XCTAssertEqual(calls.map { $0["method"] }, ["info", "shutdown", "info"])
    }
    func test电源身份异常原样传播且不继续读取() async throws {
        for writing in [false, true] {
            let transport = SystemFlowTransport(writing ? [.value([:]), .error(.tlsCertificateChanged)] : [.error(.tlsUntrusted)]), repo = try repository(transport)
            do { _ = try await repo.performSystemActionResult(.power(.reboot)) { _ in }; XCTFail() }
            catch {
                if writing { guard case .changed? = error as? DsmCertificateTrustError else { return XCTFail() } }
                else { XCTAssertEqual((error as? AppError)?.category, .tlsUntrusted) }
            }
            let calls = await transport.calls; XCTAssertEqual(calls.count, writing ? 2 : 1)
        }
    }
    private func list(_ rows: [[String: Any]]) -> [String: Any] { ["items":rows, "total":rows.count] }
    private func repository(_ transport: SystemFlowTransport, maximum: Int = 5) throws -> DsmNasAdministrationRepository {
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: [DsmAPIName.coreCurrentConnection, DsmAPIName.coreSystem].map {
            ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: maximum, requestFormat: .form, selectedVersion: maximum))
        }))
        return try .init(profile: .init(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "operator"), capabilities: capabilities,
                         session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
}
private enum SystemJournalError: Error { case failed }
private actor SystemCheckpointLog { private(set) var values: [NasSystemActionCheckpoint] = []; func append(_ value: NasSystemActionCheckpoint) { values.append(value) } }
private actor SystemFlowTransport: DsmHTTPTransport {
    enum Reply: @unchecked Sendable { case value([String: Any]), error(AppErrorCategory) }
    private var replies: [Reply]
    private(set) var calls: [[String: String]] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        calls.append(Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }))
        guard !replies.isEmpty else { throw AppError(category: .invalidResponse, isRetryable: false, safeUserMessage: "") }
        switch replies.removeFirst() {
        case .value(let value): return .init(data: try JSONSerialization.data(withJSONObject: ["success":true, "data":value]), statusCode: 200)
        case .error(let category):
            switch category {
            case .permissionDenied: return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200)
            case .cancelled: throw CancellationError()
            case .timeout: throw URLError(.timedOut)
            case .tlsUntrusted: throw URLError(.serverCertificateUntrusted)
            case .tlsCertificateChanged: throw DsmCertificateTrustError.changed(.init(host: "fixture.example.invalid", subjectSummary: "Synthetic", sha256Fingerprint: String(repeating: "0", count: 64), canBePinned: true))
            default: throw URLError(.notConnectedToInternet)
            }
        }
    }
}

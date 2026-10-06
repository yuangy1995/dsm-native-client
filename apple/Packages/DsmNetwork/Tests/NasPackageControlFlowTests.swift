import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class NasPackageControlFlowTests: XCTestCase {
    func test三种控制绑定原安装固定版本与检查点() async throws {
        for action in [NasPackageAction.start, .stop, .uninstall] {
            let before = package(action), after: [String: Any] = action == .uninstall ? ["packages": [], "total": 0] : list(row(action == .start ? "running" : "stopped"))
            let transport = MockHTTPTransport(responses: [response(list(row(before.status!))), response([:]), response([:]), response(after)])
            let repo = try repository(transport), log = PackageControlStages()
            let result = try await repo.controlPackageResult(before, action: action) { await log.append($0) }
            XCTAssertEqual(result.status, .confirmedSuccess)
            let calls = await transport.recordedRequests(), stages = await log.values
            XCTAssertEqual(calls.map { field("method", $0) }, ["list", "feasibility_check", action.rawValue, "list"])
            XCTAssertEqual(calls.map { field("version", $0) }, ["2", "1", "1", "2"])
            XCTAssertEqual(field("id", calls[2]), "Synthetic")
            XCTAssertEqual(field("dsm_apps", calls[2]), action == .stop ? nil : #"["Synthetic.App"]"#)
            XCTAssertEqual(stages, [.willSubmit, .accepted])
        }
    }

    func test原安装版本时间类型状态和桌面应用漂移均零写入() async throws {
        for key in ["version", "timestamp", "install_type", "status", "dsm_apps", "startable", "ctl_uninstall"] {
            var changed = row("stopped")
            if key == "version" { changed[key] = "2.0" }
            else if key == "timestamp" { changed[key] = 1_700_000_001 }
            else {
                var info = try XCTUnwrap(changed["additional"] as? [String: Any])
                switch key {
                case "install_type": info[key] = "system"
                case "status": info[key] = "running"
                case "dsm_apps": info[key] = ["Other.App"]
                default: info[key] = false
                }
                changed["additional"] = info
            }
            let transport = MockHTTPTransport(responses: [response(list(changed))]), repo = try repository(transport)
            let result = try await repo.controlPackageResult(package(.start), action: .start) { _ in XCTFail("漂移后不应到达写前边界") }
            XCTAssertFalse(result.submitted, key); XCTAssertEqual(result.status, .confirmedFailure, key)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1, key)
        }
    }

    func test卸载每次重读原对象并拒绝系统套件与缺失权限() async throws {
        for key in ["missing", "system", "permission", "apps", "truncated"] {
            var item = row("running"), info = try XCTUnwrap(row("running")["additional"] as? [String: Any])
            if key == "system" { info["install_type"] = "system_hidden" }
            if key == "permission" { info.removeValue(forKey: "ctl_uninstall") }
            if key == "apps" { info.removeValue(forKey: "dsm_apps") }
            item["additional"] = info
            var snapshot = key == "missing" ? ["packages": [], "total": 0] : list(item)
            if key == "truncated" { snapshot["total"] = 2 }
            let transport = MockHTTPTransport(responses: [response(snapshot)]), repo = try repository(transport)
            let result = try await repo.uninstallPackageResult(id: "Synthetic")
            XCTAssertFalse(result.submitted, key); XCTAssertEqual(result.status, .confirmedFailure, key)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
        }
    }

    func test缺少或畸形桌面应用不能猜空而停止无需该字段() async throws {
        for apps: Any? in [nil, 3, ["Synthetic.App", 1]] {
            var item = row("stopped"), info = try XCTUnwrap(item["additional"] as? [String: Any]); info["dsm_apps"] = apps; item["additional"] = info
            let transport = MockHTTPTransport(responses: [response(list(item))]), repo = try repository(transport)
            let result = try await repo.controlPackageResult(id: "Synthetic", action: .start)
            XCTAssertFalse(result.submitted)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
        }
        var before = row("running"), info = try XCTUnwrap(before["additional"] as? [String: Any]); info.removeValue(forKey: "dsm_apps"); before["additional"] = info
        let transport = MockHTTPTransport(responses: [response(list(before)), response([:]), response([:]), response(list(row("stopped")))]), repo = try repository(transport)
        let result = try await repo.controlPackageResult(id: "Synthetic", action: .stop); XCTAssertEqual(result.status, .confirmedSuccess)
    }

    func test明确拒绝不能被外部同状态覆盖或继续读取() async throws {
        for action in [NasPackageAction.start, .stop, .uninstall] {
            let transport = MockHTTPTransport(responses: [response(list(row(package(action).status!))), response([:]), denied(), response(["packages": [], "total": 0])]), repo = try repository(transport), log = PackageControlStages()
            let result = try await repo.controlPackageResult(package(action), action: action) { await log.append($0) }
            XCTAssertEqual(result.status, .permissionDenied); XCTAssertTrue(result.submitted); XCTAssertFalse(result.requiresRefresh)
            let calls = await transport.recordedRequests(), stages = await log.values
            XCTAssertEqual(calls.count, 3); XCTAssertEqual(stages, [.willSubmit])
        }
    }

    func test写前持久化和接受后持久化失败不混作NAS拒绝() async throws {
        for action in [NasPackageAction.start, .stop, .uninstall] {
            for accepted in [false, true] {
                let transport = MockHTTPTransport(responses: [response(list(row(package(action).status!))), response([:]), response([:])]), repo = try repository(transport)
                do {
                    _ = try await repo.controlPackageResult(package(action), action: action) { stage in
                        if stage == (accepted ? .accepted : .willSubmit) { throw PackageControlStorageFailure() }
                    }
                    XCTFail("记录失败必须停止后续处理")
                } catch { XCTAssertTrue(error is PackageControlStorageFailure) }
                let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, accepted ? 3 : 2)
            }
        }
    }
    func test明确输入拒绝不作为响应损坏继续认领状态() async throws {
        for action in [NasPackageAction.start, .stop, .uninstall] {
            let rejection = DsmHTTPResponse(data: Data(#"{"success":false,"error":{"code":1301}}"#.utf8), statusCode: 200)
            let transport = MockHTTPTransport(responses: [response(list(row(package(action).status!))), response([:]), rejection,
                response(action == .uninstall ? ["packages": [], "total": 0] : list(row(action == .start ? "running" : "stopped")))])
            let repo = try repository(transport), stages = PackageControlStages()
            let result = try await repo.controlPackageResult(package(action), action: action) { await stages.append($0) }
            XCTAssertEqual(result.status, .confirmedFailure); XCTAssertTrue(result.submitted)
            XCTAssertEqual(result.errorCategory, .validation); XCTAssertFalse(result.requiresRefresh)
            let calls = await transport.recordedRequests(), values = await stages.values
            XCTAssertEqual(calls.count, 3); XCTAssertEqual(values, [.willSubmit])
        }
    }

    func test回读发现重装不能认领相同状态且权限失败停止轮询() async throws {
        var replacement = row("running"); replacement["timestamp"] = 1_700_000_001
        let transport = MockHTTPTransport(steps: [.response(response(list(row("stopped")))), .response(response([:])), .urlError(.timedOut), .response(response(list(replacement))), .response(denied())]), repo = try repository(transport)
        let result = try await repo.controlPackageResult(package(.start), action: .start) { _ in }
        XCTAssertEqual(result.status, .submittedButUnverified); XCTAssertEqual(result.errorCategory, .permission)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 5); XCTAssertEqual(calls.filter { field("method", $0) == "start" }.count, 1)
    }

    func test卸载空列表若总数不匹配不能表示成功() async throws {
        let transport = MockHTTPTransport(responses: [response(list(row("running"))), response([:]), response([:]), response(["packages": [], "total": 1])]), repo = try repository(transport)
        let result = try await repo.controlPackageResult(package(.uninstall), action: .uninstall) { _ in }
        XCTAssertEqual(result.status, .submittedButUnverified); XCTAssertEqual(result.counts.succeeded, 0)
    }

    func test写入与回读证书失败立即停止() async throws {
        for action in [NasPackageAction.start, .uninstall] {
            for readback in [false, true] {
                var steps: [MockHTTPTransport.Step] = [.response(response(list(row(package(action).status!)))), .response(response([:]))]
                if readback { steps.append(.response(response([:]))) }; steps.append(.urlError(.serverCertificateUntrusted))
                let transport = MockHTTPTransport(steps: steps), repo = try repository(transport)
                do { _ = try await repo.controlPackageResult(package(action), action: action) { _ in }; XCTFail() }
                catch { XCTAssertEqual((error as? AppError)?.category, .tlsUntrusted) }
                let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, readback ? 4 : 3)
            }
        }
    }

    func test缺少固定版本零请求且不降级() async throws {
        for range in [1...1, 2...5] {
            let transport = MockHTTPTransport(responses: []), repo = try repository(transport, packageRange: range)
            for action in [NasPackageAction.start, .stop, .uninstall] {
                let result = try await repo.controlPackageResult(package(action), action: action) { _ in XCTFail() }
                XCTAssertEqual(result.status, .unsupported); XCTAssertFalse(result.submitted)
            }
            let calls = await transport.recordedRequests(); XCTAssertTrue(calls.isEmpty)
        }
    }

    func test写前取消并阻止套件设置安装与同目标并发() async throws {
        let transport = MockHTTPTransport(responses: [response(list(row("running"))), response([:])]), repo = try repository(transport), before = package(.stop)
        let result = try await Task {
            try await repo.controlPackageResult(before, action: .stop) { stage in
                guard stage == .willSubmit else { XCTFail(); return }
                let duplicate = try await repo.controlPackageResult(id: before.id, action: .uninstall)
                XCTAssertFalse(duplicate.submitted); XCTAssertEqual(duplicate.errorCategory, .conflict)
                do { _ = try await repo.savePackageSource(.init(name: "Synthetic", url: "https://example.invalid/feed"), replacing: nil); XCTFail() } catch { }
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }.value
        XCTAssertEqual(result.status, .cancelledBeforeSubmission)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
    }

    private func package(_ action: NasPackageAction) -> NasPackage {
        .init(id: "Synthetic", name: "Synthetic", version: "1.0", status: action == .start ? "stopped" : "running", statusDescription: nil,
            packageDescription: nil, installType: "user", installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            canStart: action == .start, canStop: action != .start, canUninstall: true, dsmApps: ["Synthetic.App"])
    }
    private func row(_ status: String) -> [String: Any] {
        ["id": "Synthetic", "name": "Synthetic", "version": "1.0", "timestamp": 1_700_000_000,
         "additional": ["status": status, "install_type": "user", "startable": true, "ctl_uninstall": true, "dsm_apps": ["Synthetic.App"], "available_operation": [String: String]()]]
    }
    private func list(_ item: [String: Any]) -> [String: Any] { ["packages": [item], "total": 1] }
    private func response(_ data: [String: Any]) -> DsmHTTPResponse { .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200) }
    private func denied() -> DsmHTTPResponse { .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
    private func repository(_ transport: MockHTTPTransport, packageRange: ClosedRange<Int> = 1...5) throws -> DsmNasAdministrationRepository {
        try .init(profile: .init(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "operator"),
            capabilities: .init(Dictionary(uniqueKeysWithValues: [DsmAPIName.corePackage, DsmAPIName.corePackageControl, DsmAPIName.corePackageUninstallation, DsmAPIName.corePackageFeed].map { name in
                let range = name == DsmAPIName.corePackage ? packageRange : 1...3
                return (name, .init(name: name, path: "entry.cgi", minVersion: range.lowerBound, maxVersion: range.upperBound, requestFormat: .form, selectedVersion: range.upperBound))
            })), session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func field(_ key: String, _ request: URLRequest) -> String? {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        return parts.queryItems?.first { $0.name == key }?.value
    }
}
private struct PackageControlStorageFailure: Error { }
private actor PackageControlStages { private(set) var values: [NasPackageControlCheckpoint] = []; func append(_ value: NasPackageControlCheckpoint) { values.append(value) } }

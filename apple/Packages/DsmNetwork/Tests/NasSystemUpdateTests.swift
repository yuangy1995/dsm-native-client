import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class NasSystemUpdateTests: XCTestCase {
    private let target = "DSM 7.2.1-69057 Update 13"
    private var ready: String { #"{"allow_upgrade":true,"status":"ready_upgrade","target":"update","patch_info":{"buildnumber":69057,"smallfixnumber":13,"upgradetype":"smallupdate","reboot":"now"}}"# }
    private var preflight: [DsmHTTPResponse] {
        [ok(#"{"firmware_ver":"DSM 7.2.1-69057 Update 12"}"#), ok(#"{"update":{"version":"DSM 7.2.1-69057 Update 13"}}"#),
         ok(ready), ok(#"{"allow_upgrade":true}"#), ok("false")]
    }

    func test安装确认绑定补丁再次预检且只提交一次() async throws {
        for format in [DsmRequestFormat.form, .json] {
            let transport = MockHTTPTransport(responses: preflight + preflight + [ok("{}")])
            let repository = try make(transport, format: format)
            let plan = try await repository.prepareSystemUpdate(expectedVersion: target)
            let result = try await repository.installSystemUpdate(plan: plan)
            XCTAssertEqual(result, .accepted)
            do { _ = try await repository.installSystemUpdate(plan: plan); XCTFail("安装不能重发") } catch {}
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 11)
            XCTAssertEqual(value("method", requests[4]), "check_having_upgradeable_drives")
            let targetData = Data(try XCTUnwrap(value("upgrade_to", requests[4])).utf8)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: targetData) as? [String: Int], ["base": 69057, "nano": 13])
            XCTAssertEqual(value("method", requests[10]), "start")
            XCTAssertEqual(value("type", requests[10]), format == .json ? #""server""# : "server")
            XCTAssertEqual(value("force", requests[10]), "true")
        }
    }

    func test断线保留提交未知且不重放() async throws {
        let steps = (preflight + preflight).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)]
        let transport = MockHTTPTransport(steps: steps), repository = try make(transport)
        let plan = try await repository.prepareSystemUpdate(expectedVersion: target)
        let result = try await repository.installSystemUpdate(plan: plan)
        XCTAssertEqual(result, .uncertain)
        do { _ = try await repository.installSystemUpdate(plan: plan); XCTFail("未知提交不能重放") } catch {}
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 11)
    }

    func test额外警告和大版本不开放安装() async throws {
        for warning in ["hard", "soft", "unknown"] {
            let transport = MockHTTPTransport(responses: Array(preflight.prefix(3)) + [ok("{\"allow_upgrade\":true,\"check_type\":\"\(warning)\"}")])
            let repository = try make(transport)
            do { _ = try await repository.prepareSystemUpdate(expectedVersion: target); XCTFail("警告不能跳过") } catch {}
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
        }
        let transport = MockHTTPTransport(responses: Array(preflight.prefix(2)) + [ok(ready.replacingOccurrences(of: "smallupdate", with: "dsm"))])
        do { _ = try await make(transport).prepareSystemUpdate(expectedVersion: target); XCTFail("大版本需要独立预检") } catch {}
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 3)
    }

    func test权限或缺失许可不能写入且计划不能跨连接使用() async throws {
        for status in [ready.replacingOccurrences(of: "\"allow_upgrade\":true", with: "\"allow_upgrade\":false"), ready.replacingOccurrences(of: "\"allow_upgrade\":true,", with: "")] {
            let transport = MockHTTPTransport(responses: Array(preflight.prefix(2)) + [ok(status)])
            do { _ = try await make(transport).prepareSystemUpdate(expectedVersion: target); XCTFail("必须明确允许") } catch {}
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 3)
        }
        let transport = MockHTTPTransport(responses: [])
        do { _ = try await make(transport).installSystemUpdate(plan: .init(version: target, build: 69057, update: 13)); XCTFail("伪造计划") } catch {}
        let requests = await transport.recordedRequests(); XCTAssertTrue(requests.isEmpty)
    }

    func test补丁变化和预检失败不能用旧确认提交() async throws {
        let changed = ready.replacingOccurrences(of: "\"smallfixnumber\":13", with: "\"smallfixnumber\":14")
        let transport = MockHTTPTransport(responses: preflight + Array(preflight.prefix(2)) + [ok(changed), ok(#"{"allow_upgrade":true}"#), ok("false")])
        let repository = try make(transport), plan = try await repository.prepareSystemUpdate(expectedVersion: target)
        do { _ = try await repository.installSystemUpdate(plan: plan); XCTFail("补丁变化必须重新确认") } catch {}
        let requests = await transport.recordedRequests(); XCTAssertFalse(requests.contains { value("method", $0) == "start" })
    }

    func test下载补丁必须与用户看到的目标版本一致() async throws {
        let oldPatch = ready.replacingOccurrences(of: "\"smallfixnumber\":13", with: "\"smallfixnumber\":12")
        let transport = MockHTTPTransport(responses: Array(preflight.prefix(2)) + [ok(oldPatch)])
        do { _ = try await make(transport).prepareSystemUpdate(expectedVersion: target); XCTFail("不能把旧补丁标为新版本") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 3)
    }

    func test明确拒绝安装后可重新检查() async throws {
        let denied = DsmHTTPResponse(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200)
        let transport = MockHTTPTransport(responses: preflight + preflight + [denied] + preflight)
        let repository = try make(transport), plan = try await repository.prepareSystemUpdate(expectedVersion: target)
        do { _ = try await repository.installSystemUpdate(plan: plan); XCTFail("权限拒绝") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        _ = try await repository.prepareSystemUpdate(expectedVersion: target)
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.filter { value("method", $0) == "start" }.count, 1)
    }

    func test网关错误不能释放安装与电源保护() async throws {
        for code in [502, 504] {
            let transport = MockHTTPTransport(responses: preflight + preflight + [.init(data: Data(), statusCode: code)])
            let repository = try make(transport), plan = try await repository.prepareSystemUpdate(expectedVersion: target)
            let result = try await repository.installSystemUpdate(plan: plan)
            XCTAssertEqual(result, .uncertain)
            let power = try await repository.performPowerActionResult(.reboot)
            XCTAssertEqual(power.status, .confirmedFailure); XCTAssertFalse(power.submitted)
            do { _ = try await repository.installSystemUpdate(plan: plan); XCTFail("网关错误不能重放") } catch {}
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 11)
        }
    }

    func test版本先变化不会提前确认重启完成() async throws {
        let transport = MockHTTPTransport(responses: preflight + preflight + [ok("{}"), ok(#"{"status":"none"}"#),
            ok(#"{"firmware_ver":"DSM 7.2.1-69057 Update 13","up_time":"7200"}"#),
            ok(#"{"status":"none"}"#), ok(#"{"firmware_ver":"DSM 7.2.1-69057 Update 13","up_time":"30"}"#)])
        let repository = try make(transport), plan = try await repository.prepareSystemUpdate(expectedVersion: target)
        _ = try await repository.installSystemUpdate(plan: plan)
        await repository.setSystemUpdateSubmissionTimeForTest(Date().addingTimeInterval(-300))
        let beforeRestart = try await repository.loadSystemUpdateStatus(); XCTAssertEqual(beforeRestart.phase, .idle)
        let power = try await repository.performPowerActionResult(.shutdown); XCTAssertFalse(power.submitted)
        let afterRestart = try await repository.loadSystemUpdateStatus()
        XCTAssertEqual(afterRestart.phase, .completed); XCTAssertEqual(afterRestart.installedVersion, target)
    }

    func test下载目标和后台安装只读恢复() async throws {
        let transport = MockHTTPTransport(responses: [ok(#"{"status":"downloading","target":"promotion"}"#),
                                                     ok(#"{"status":"upgrading"}"#), ok(#"{"percent":23}"#)])
        let repository = try make(transport)
        let other = try await repository.loadSystemUpdateStatus(); XCTAssertEqual(other.phase, .unknown)
        let installing = try await repository.loadSystemUpdateStatus()
        XCTAssertEqual(installing.phase, .installing); XCTAssertEqual(installing.percent, 23)
        let requests = await transport.recordedRequests(); XCTAssertFalse(requests.contains { value("method", $0) == "start" })
    }

    func test下载状态使用服务端进度不夹造百分比() async throws {
        let transport = MockHTTPTransport(responses: [ok(#"{"status":"downloading","allow_upgrade":false,"target":"update"}"#), ok(#"{"percent":54,"status":"downloading","target":"update"}"#), ok(#"{"percent":100,"type":"smallupdate"}"#), ok(#"{"percent":101}"#)])
        let repository = try make(transport)
        let downloading = try await repository.loadSystemUpdateStatus()
        XCTAssertEqual(downloading.phase, .downloading); XCTAssertEqual(downloading.percent, 54)
        let progress = try await repository.loadSystemUpdateProgress()
        XCTAssertEqual(progress.phase, .installing); XCTAssertEqual(progress.percent, 100)
        let malformed = try await repository.loadSystemUpdateProgress(); XCTAssertNil(malformed.percent)
    }

    private func make(_ transport: MockHTTPTransport, format: DsmRequestFormat = .form) throws -> DsmNasAdministrationRepository {
        let names = [DsmAPIName.coreSystem, DsmAPIName.coreUpgradeServer, DsmAPIName.coreUpgrade, DsmAPIName.coreUpgradeDownload]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: names.map {
            ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 3, requestFormat: format, selectedVersion: $0 == DsmAPIName.coreSystem ? 3 : 1))
        }))
        return try .init(profile: .init(displayName: "Synthetic NAS", host: "nas.example.invalid", port: 5001), capabilities: capabilities,
                         session: .init(sid: "REDACTED", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func ok(_ data: String) -> DsmHTTPResponse { .init(data: Data("{\"success\":true,\"data\":\(data)}".utf8), statusCode: 200) }
    private func value(_ key: String, _ request: URLRequest) -> String? {
        URLComponents(string: "?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self))?.queryItems?.first { $0.name == key }?.value
    }
}

private extension DsmNasAdministrationRepository {
    func setSystemUpdateSubmissionTimeForTest(_ date: Date) { systemUpdateSubmittedAt = date }
}

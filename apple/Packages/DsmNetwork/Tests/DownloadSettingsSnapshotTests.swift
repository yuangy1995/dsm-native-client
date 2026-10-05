import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class DownloadSettingsSnapshotTests: XCTestCase {
    func test字段缺失和非法类型不补零且保留合法关闭与零值() async throws {
        let transport = MockHTTPTransport(responses: snapshot(#"{"bt_max_download":0,"bt_max_upload":false,"emule_enabled":false,"unzip_service_enabled":"unknown","default_destination":"folder with spaces"}"#,
            manager: #"{"is_manager":"true"}"#, schedule: #"{"enabled":false,"emule_enabled":1}"#))
        let value = try await repository(transport).loadDownloadSettingsSnapshot()
        XCTAssertNil(value.isManager); XCTAssertEqual(value.values[.btDownload], .number(0))
        XCTAssertEqual(value.values[.emule], .flag(false)); XCTAssertEqual(value.values[.schedule], .flag(false))
        XCTAssertEqual(value.values[.destination], .text("folder with spaces"))
        XCTAssertNil(value.values[.btUpload]); XCTAssertNil(value.values[.autoExtract]); XCTAssertNil(value.values[.emuleSchedule])
    }
    func test只有Info一版时不把返回的目录当可写字段且计划独立降级() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"is_manager":true}"#), response(#"{"default_destination":"synthetic","bt_max_download":0}"#)])
        let value = try await repository(transport, infoVersion: 1, schedule: false).loadDownloadSettingsSnapshot()
        XCTAssertNil(value.values[.destination]); XCTAssertNil(value.values[.schedule]); XCTAssertEqual(value.values[.btDownload], .number(0))
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { Self.field("version", $0) == "1" })
    }
    func test常规设置只提交变更字段写前回调位于最新权限和原值之后() async throws {
        let change = change(), transport = MockHTTPTransport(responses: snapshot(#"{"bt_max_download":0,"unzip_service_enabled":true}"#)
            + [response("{}")]
            + snapshot(#"{"bt_max_download":12,"unzip_service_enabled":true}"#))
        let repository = try repository(transport)
        let result = try await repository.changeDownloadSettings(change) {
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.map { Self.field("method", $0) }, ["getinfo", "getconfig", "getconfig"])
        }
        XCTAssertEqual(result, .complete)
        let requests = await transport.recordedRequests(), write = requests[3]
        try assertDeltaFixture(write, operation: "save-settings")
        XCTAssertEqual(Self.field("version", write), "2"); XCTAssertEqual(Self.field("bt_max_download", write), "12")
        XCTAssertNil(Self.field("default_destination", write)); XCTAssertNil(Self.field("unzip_service_enabled", write))
        XCTAssertEqual(requests.filter { Self.field("method", $0) == "setserverconfig" }.count, 1)
    }
    func test计划只写单个变更开关且固定使用一版() async throws {
        let change = DownloadSettingsChange(group: .schedule, original: [.schedule: .flag(false)], desired: [.schedule: .flag(true)])
        let transport = MockHTTPTransport(responses: snapshot("{}", schedule: #"{"enabled":false,"emule_enabled":false}"#)
            + [response("{}")] + snapshot("{}", schedule: #"{"enabled":true,"emule_enabled":false}"#))
        let result = try await repository(transport).changeDownloadSettings(change, willSubmit: {})
        XCTAssertEqual(result, .complete)
        let requests = await transport.recordedRequests(), write = requests[3]
        try assertDeltaFixture(write, operation: "save-schedule")
        XCTAssertEqual(Self.field("api", write), DsmAPIName.downloadStationSchedule)
        XCTAssertEqual(Self.field("version", write), "1"); XCTAssertEqual(Self.field("enabled", write), "true")
        XCTAssertNil(Self.field("emule_enabled", write))
    }
    func test权限缺失或撤销与原值冲突均零写入() async throws {
        for (manager, rate, expected) in [("{}", 0, AppErrorCategory.invalidResponse), (#"{"is_manager":false}"#, 0, .permissionDenied),
                                          (#"{"is_manager":true}"#, 20, .conflict)] {
            let transport = MockHTTPTransport(responses: snapshot("{\"bt_max_download\":\(rate)}", manager: manager))
            do { _ = try await repository(transport).changeDownloadSettings(change(), willSubmit: { XCTFail("不能进入保存回调") }); XCTFail("应拒绝") }
            catch let error as AppError { XCTAssertEqual(error.category, expected) }
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 3)
            XCTAssertFalse(requests.contains { Self.field("method", $0)?.hasPrefix("set") == true })
        }
    }
    func test存储失败不发送设置() async throws {
        let transport = MockHTTPTransport(responses: snapshot(#"{"bt_max_download":0}"#))
        do { _ = try await repository(transport).changeDownloadSettings(change(), willSubmit: { throw CocoaError(.fileWriteNoPermission) }); XCTFail("应抛错") } catch {}
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 3)
    }
    func test未知写禁止同分区再次发送恢复只能查询且成功后可再改() async throws {
        let transport = MockHTTPTransport(steps: snapshot(#"{"bt_max_download":0}"#).map(MockHTTPTransport.Step.response)
            + [.urlError(.timedOut)]
            + snapshot(#"{"bt_max_download":0}"#).map(MockHTTPTransport.Step.response)
            + snapshot(#"{"bt_max_download":12}"#).map(MockHTTPTransport.Step.response))
        let repository = try repository(transport), change = change()
        let first = try await repository.changeDownloadSettings(change, willSubmit: {})
        XCTAssertEqual(first, .pending)
        do { _ = try await repository.changeDownloadSettings(change, willSubmit: { XCTFail("禁止重发") }); XCTFail("应被限制") } catch {}
        let pending = try await repository.reviewDownloadSettings(change); XCTAssertFalse(pending)
        let complete = try await repository.reviewDownloadSettings(change); XCTAssertTrue(complete)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { Self.field("method", $0) == "setserverconfig" }.count, 1)
        XCTAssertEqual(requests.count, 10)
    }
    func test官方明确拒绝与成功空响应后不同值均不误报保存() async throws {
        for code in [105, 101] {
            let transport = MockHTTPTransport(responses: snapshot(#"{"bt_max_download":0}"#)
                + [.init(data: Data("{\"success\":false,\"error\":{\"code\":\(code)}}".utf8), statusCode: 200)])
            let outcome = try await repository(transport).changeDownloadSettings(change(), willSubmit: {})
            XCTAssertEqual(outcome, code == 105 ? .denied : .rejected)
        }
        let transport = MockHTTPTransport(responses: snapshot(#"{"bt_max_download":0}"#) + [response("{}")]
            + snapshot(#"{"bt_max_download":5}"#))
        let outcome = try await repository(transport).changeDownloadSettings(change(), willSubmit: {})
        XCTAssertEqual(outcome, .pending)
    }
    func testHTTP与FTP必须成对且原值一致无变化与非法值不允许写入() async throws {
        let values: [DownloadSettingsChange] = [
            .init(group: .general, original: [.httpDownload: .number(0)], desired: [.httpDownload: .number(12)]),
            .init(group: .general, original: [.httpDownload: .number(0), .ftpDownload: .number(1)], desired: [.httpDownload: .number(12), .ftpDownload: .number(12)]),
            .init(group: .general, original: [.btDownload: .number(0)], desired: [.btDownload: .number(-1)]),
            .init(group: .general, original: [.btDownload: .number(0)], desired: [.btDownload: .number(0)]),
            .init(group: .schedule, original: [.btDownload: .number(0)], desired: [.btDownload: .number(12)])]
        for change in values {
            XCTAssertFalse(change.isValid)
            let transport = MockHTTPTransport(responses: [])
            do { _ = try await repository(transport).changeDownloadSettings(change, willSubmit: {}); XCTFail("不应发送") } catch {}
            let requests = await transport.recordedRequests(); XCTAssertTrue(requests.isEmpty)
        }
    }
    func test取消发生在保存回调后仍零写入() async throws {
        let gate = DownloadSettingsTestGate(), transport = MockHTTPTransport(responses: snapshot(#"{"bt_max_download":0}"#)), repository = try repository(transport)
        let change = change(), operation = Task { try await repository.changeDownloadSettings(change) { await gate.wait() } }
        await gate.waitUntilStarted(); operation.cancel(); await gate.release()
        let outcome = try await operation.value; XCTAssertEqual(outcome, .cancelledBeforeSubmission)
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 3)
    }
    private func assertDeltaFixture(_ request: URLRequest, operation: String) throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(
            "contracts/request-fixtures/download-station/\(operation)/synthetic-delta/request.json"))) as? [String: Any])
        let api = try XCTUnwrap(json["api"] as? [String: Any]), parameters = try XCTUnwrap(json["parameters"] as? [[String: Any]])
        let expected = try Dictionary(uniqueKeysWithValues: parameters.map { (try XCTUnwrap($0["name"] as? String), try XCTUnwrap($0["encodedValue"] as? String)) })
        let fields = URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)!.queryItems!
        let actual = Dictionary(uniqueKeysWithValues: fields.filter { !["api", "method", "version", "_sid", "SynoToken"].contains($0.name) }.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Self.field("api", request), api["name"] as? String)
        XCTAssertEqual(Self.field("method", request), api["method"] as? String)
        XCTAssertEqual(Self.field("version", request), (api["resolvedVersion"] as? Int).map(String.init))
        XCTAssertEqual(request.httpMethod, "POST")
    }
    private func repository(_ transport: MockHTTPTransport, infoVersion: Int = 2, schedule: Bool = true) throws -> DsmServiceManagementRepository {
        var capabilities = [DsmAPIName.downloadStationInfo: ApiCapability(name: DsmAPIName.downloadStationInfo, path: "entry.cgi", minVersion: 1, maxVersion: infoVersion, requestFormat: .form, selectedVersion: infoVersion)]
        if schedule { capabilities[DsmAPIName.downloadStationSchedule] = ApiCapability(name: DsmAPIName.downloadStationSchedule, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form, selectedVersion: 1) }
        return try DsmServiceManagementRepository(profile: NasProfile(displayName: "合成设备", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet(capabilities), session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func change() -> DownloadSettingsChange { .init(group: .general, original: [.btDownload: .number(0)], desired: [.btDownload: .number(12)]) }
    private func snapshot(_ config: String, manager: String = #"{"is_manager":true}"#, schedule: String = #"{"enabled":false}"#) -> [DsmHTTPResponse] {
        [response(manager), response(config), response(schedule)]
    }
    private func response(_ data: String) -> DsmHTTPResponse { .init(data: Data(#"{"success":true,"data":\#(data)}"#.utf8), statusCode: 200) }
    private static func field(_ key: String, _ request: URLRequest) -> String? {
        URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems?.first { $0.name == key }?.value
    }
}
private actor DownloadSettingsTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { started = true; waiters.forEach { $0.resume() }; waiters = []; await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { waiters.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}

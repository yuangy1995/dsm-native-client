import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class NasRegionFlowTests: XCTestCase {
    func test区域保存明确拒绝不能用其他来源写入的同值配置覆盖() async throws {
        let zones = #"{"success":true,"data":{"zonedata":[{"value":"UTC","display":"UTC"}]}}"#
        let original = #"{"success":true,"data":{"date_format":"Y/m/d","time_format":"H:i","timezone":"UTC","enable_ntp":"ntp","server":"time.example.invalid","date":"2026/10/5","hour":8,"minute":0,"second":0}}"#
        let matching = original.replacingOccurrences(of: "Y/m/d", with: "Y-m-d")
        let transport = MockHTTPTransport(responses: [response(original), response(zones),
            response(#"{"success":false,"error":{"code":105}}"#), response(matching), response(zones)])
        let capability = ApiCapability(name: DsmAPIName.coreRegionNTP, path: "entry.cgi", minVersion: 1, maxVersion: 3, requestFormat: .form, selectedVersion: 3)
        let repository = try DsmNasAdministrationRepository(profile: NasProfile(displayName: "Synthetic", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet([DsmAPIName.coreRegionNTP: capability]),
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        let desired = NasRegionSettings(dateFormat: "Y-m-d", timeFormat: "H:i", timeZone: "UTC", isNetworkTimeEnabled: true,
            timeServers: ["time.example.invalid"], manualDate: nil, timeZones: [.init(id: "UTC", displayName: "UTC")])
        let result = try await repository.saveRegionSettingsResult(desired)
        XCTAssertEqual(result.status, .permissionDenied)
        let calls = await transport.recordedRequests()
        XCTAssertEqual(calls.count, 3)
        let methods = calls.map { request in
            URLComponents(string: "https://fixture.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems?.first { $0.name == "method" }?.value
        }
        XCTAssertEqual(methods, ["get", "listzone", "set"])
    }
    func test保存与校时分别在写前和回执后记录且完整回读() async throws {
        let original = settings(), desired = settings(server: "new.example.invalid")
        let transport = MockHTTPTransport(responses: [snapshot(original), zones, response(#"{"success":true}"#), snapshot(desired), zones,
            response(#"{"success":true}"#), snapshot(desired), zones])
        let stages = RegionStages(), repository = try repository(transport)
        let result = try await repository.changeRegionResult(.save(original: original, desired: desired, editsManualTime: false)) { await stages.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let recorded = await stages.values
        XCTAssertEqual(recorded, [.willSave, .saved, .configurationVerified, .willSynchronize, .synchronized])
        let calls = await transport.recordedRequests()
        XCTAssertEqual(calls.map { field("method", $0) }, ["get", "listzone", "set", "get", "listzone", "sync", "get", "listzone"])
        XCTAssertEqual(field("version", calls[2]), "3"); XCTAssertEqual(field("version", calls[5]), "2")
    }

    func test确认后的原配置或时区列表变化不提交() async throws {
        var changed = settings(); changed.timeZone = "Asia/Shanghai"
        for current in [changed, settings()] {
            let actualZones = current.timeZone == "UTC" ? response(#"{"success":true,"data":{"zonedata":[{"value":"UTC","display":"UTC"}]}}"#) : zones
            let transport = MockHTTPTransport(responses: [snapshot(current), actualZones])
            let desired = settings(zone: "Asia/Shanghai")
            let result = try await repository(transport).changeRegionResult(.save(original: settings(), desired: desired, editsManualTime: false)) { _ in XCTFail("预检失败不能落盘提交") }
            XCTAssertEqual(result.status, .confirmedFailure); XCTAssertFalse(result.submitted)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
        }
    }

    func test写前保存记录失败不修改时间() async throws {
        let transport = MockHTTPTransport(responses: [snapshot(settings()), zones])
        do {
            _ = try await repository(transport).changeRegionResult(.save(original: settings(), desired: settings(format: "h:i a"), editsManualTime: false)) { _ in throw URLError(.cannotWriteToFile) }
            XCTFail("写前失败必须返回")
        } catch { }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
    }

    func test配置回读检查点保存失败不继续校时() async throws {
        let original = settings(), desired = settings(server: "new.example.invalid")
        let transport = MockHTTPTransport(responses: [snapshot(original), zones, response(#"{"success":true}"#), snapshot(desired), zones])
        do {
            _ = try await repository(transport).changeRegionResult(.save(original: original, desired: desired, editsManualTime: false)) {
                if $0 == .configurationVerified { throw URLError(.cannotWriteToFile) }
            }
            XCTFail("持久保存失败不得开始第二个副作用")
        } catch { }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.map { field("method", $0) }, ["get", "listzone", "set", "get", "listzone"])
    }

    func test单独重试校时不重写配置且确认完整原设置() async throws {
        let current = settings(), stages = RegionStages()
        let transport = MockHTTPTransport(responses: [snapshot(current), zones, response(#"{"success":true}"#), snapshot(current), zones])
        let result = try await repository(transport).changeRegionResult(.synchronize(expected: current)) { await stages.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let recorded = await stages.values; XCTAssertEqual(recorded, [.willSynchronize, .synchronized])
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.map { field("method", $0) }, ["get", "listzone", "sync", "get", "listzone"])
    }

    func test未编辑手动时间使用最新NAS时间不回写旧时刻() async throws {
        let original = settings(network: false, hour: 8), current = settings(network: false, hour: 18)
        var desired = original; desired.timeFormat = "h:i a"
        var verified = current; verified.timeFormat = "h:i a"
        let transport = MockHTTPTransport(responses: [snapshot(current), zones, response(#"{"success":true}"#), snapshot(verified), zones])
        let result = try await repository(transport).changeRegionResult(.save(original: original, desired: desired, editsManualTime: false)) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.recordedRequests()
        XCTAssertEqual(field("hour", calls[2]), "18"); XCTAssertFalse(calls.contains { field("method", $0) == "sync" })
    }

    func test用户明确调整一分钟也会提交而不被误判无变化() async throws {
        let original = settings(network: false), desired = settings(network: false, minute: 16)
        let transport = MockHTTPTransport(responses: [snapshot(original), zones, response(#"{"success":true}"#), snapshot(desired), zones])
        let result = try await repository(transport).changeRegionResult(.save(original: original, desired: desired, editsManualTime: true)) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.recordedRequests(); XCTAssertEqual(field("minute", calls[2]), "16")
    }

    func test回读未编辑字段意外变化不能报告全部保存成功() async throws {
        let original = settings(), desired = settings(format: "h:i a")
        let unexpected = settings(format: "h:i a", zone: "Asia/Shanghai")
        let transport = MockHTTPTransport(responses: [snapshot(original), zones, response(#"{"success":true}"#), snapshot(unexpected), zones])
        let result = try await repository(transport).changeRegionResult(.save(original: original, desired: desired, editsManualTime: false)) { _ in }
        XCTAssertEqual(result.status, .partialSuccess)
    }

    func test版本不足读取零请求且未知校时不重放() async throws {
        let unavailable = MockHTTPTransport(responses: [])
        do { _ = try await repository(unavailable, version: 2).loadRegionForManagement(); XCTFail("需要读取 v3") } catch { }
        let unavailableCalls = await unavailable.recordedRequests(); XCTAssertTrue(unavailableCalls.isEmpty)
        let transport = MockHTTPTransport(steps: [.response(snapshot(settings())), .response(zones), .urlError(.timedOut)])
        let result = try await repository(transport).changeRegionResult(.synchronize(expected: settings())) { _ in }
        XCTAssertEqual(result.status, .submittedButUnverified)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.filter { field("method", $0) == "sync" }.count, 1)
    }

    func test手动改时回执丢失不能用相近旧时钟冒认成功() async throws {
        let original = settings(network: false), desired = settings(network: false, minute: 16)
        let transport = MockHTTPTransport(steps: [.response(snapshot(original)), .response(zones), .urlError(.timedOut),
            .response(snapshot(original)), .response(zones)])
        let stages = RegionStages()
        let result = try await repository(transport).changeRegionResult(.save(original: original, desired: desired, editsManualTime: true)) { await stages.append($0) }
        XCTAssertEqual(result.status, .submittedButUnverified)
        let recorded = await stages.values; XCTAssertEqual(recorded, [.willSave])
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 3)
    }

    func test单独校时权限拒绝不能算作部分配置已保存() async throws {
        let transport = MockHTTPTransport(responses: [snapshot(settings()), zones, response(#"{"success":false,"error":{"code":105}}"#)])
        let result = try await repository(transport).changeRegionResult(.synchronize(expected: settings())) { _ in }
        XCTAssertEqual(result.status, .permissionDenied)
        XCTAssertEqual(result.counts.succeeded, 0)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.map { field("method", $0) }, ["get", "listzone", "sync"])
    }

    func test校时前取消保留是否已经保存配置而且零校时请求() async throws {
        for saved in [false, true] {
            let original = settings(), desired = settings(server: "new.example.invalid")
            let responses = saved ? [snapshot(original), zones, response(#"{"success":true}"#), snapshot(desired), zones] : [snapshot(original), zones]
            let transport = MockHTTPTransport(responses: responses)
            let change: NasRegionChange = saved ? .save(original: original, desired: desired, editsManualTime: false) : .synchronize(expected: original)
            let result = try await repository(transport).changeRegionResult(change) { if $0 == .willSynchronize { throw CancellationError() } }
            XCTAssertEqual(result.status, saved ? .cancellationRequestedAfterSubmission : .cancelledBeforeSubmission)
            XCTAssertEqual(result.submitted, saved)
            let calls = await transport.recordedRequests(); XCTAssertFalse(calls.contains { field("method", $0) == "sync" })
        }
    }

    private var zones: DsmHTTPResponse { response(#"{"success":true,"data":{"zonedata":[{"value":"UTC","display":"UTC"},{"value":"Asia/Shanghai","display":"Asia/Shanghai"}]}}"#) }
    private func settings(format: String = "H:i", server: String = "time.example.invalid", zone: String = "UTC", network: Bool = true, hour: Int = 8, minute: Int = 15) -> NasRegionSettings {
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 5, hour: hour, minute: minute, second: 0))!
        return .init(dateFormat: "Y-m-d", timeFormat: format, timeZone: zone, isNetworkTimeEnabled: network,
            timeServers: [server], manualDate: date, timeZones: [.init(id: "UTC", displayName: "UTC"), .init(id: "Asia/Shanghai", displayName: "Asia/Shanghai")])
    }
    private func snapshot(_ value: NasRegionSettings) -> DsmHTTPResponse {
        let parts = Calendar(identifier: .gregorian).dateComponents([.hour, .minute, .second], from: value.manualDate!)
        let data: [String: Any] = ["date_format": value.dateFormat, "time_format": value.timeFormat, "timezone": value.timeZone,
            "enable_ntp": value.isNetworkTimeEnabled ? "ntp" : "manual", "server": value.timeServers.joined(separator: ","),
            "date": "2026/10/5", "hour": parts.hour!, "minute": parts.minute!, "second": parts.second!]
        return .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
    private func repository(_ transport: MockHTTPTransport, version: Int = 3) throws -> DsmNasAdministrationRepository {
        let capability = ApiCapability(name: DsmAPIName.coreRegionNTP, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version)
        return try DsmNasAdministrationRepository(profile: NasProfile(displayName: "Synthetic", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet([DsmAPIName.coreRegionNTP: capability]),
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func field(_ name: String, _ request: URLRequest) -> String? {
        URLComponents(string: "https://fixture.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems?.first { $0.name == name }?.value
    }
    private func response(_ text: String) -> DsmHTTPResponse { .init(data: Data(text.utf8), statusCode: 200) }
}

private actor RegionStages {
    var values: [NasRegionCheckpoint] = []
    func append(_ value: NasRegionCheckpoint) { values.append(value) }
}

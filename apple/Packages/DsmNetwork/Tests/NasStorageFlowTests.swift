import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class NasStorageFlowTests: XCTestCase {
    func test检测保存回调在预检后且在唯一写入前执行() async throws {
        let transport = MockHTTPTransport(responses: [response(storage), response(status(false)), response(#"{"success":true}"#), response(status(true, type: "quick"))])
        let repository = try repository(transport)
        let checkpoint = Checkpoint()
        let result = try await repository.changeDiskTestResult(change(.quick)) {
            await checkpoint.record(await transport.recordedRequests().count)
        }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let count = await checkpoint.requestCount
        XCTAssertEqual(count, 2)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { field("method", $0) }, ["load_info", "get_smart_test_log", "do_smart_test", "get_smart_test_log"])
        XCTAssertEqual(field("device", requests[2]), "synthetic-device")
        XCTAssertEqual(field("type", requests[2]), "quick")
    }

    func test保存回调失败保持零写入并向调用方保留错误() async throws {
        let transport = MockHTTPTransport(responses: [response(storage), response(status(false))])
        let repository = try repository(transport)
        do {
            _ = try await repository.changeDiskTestResult(change(.quick)) { throw CheckpointFailure.unavailable }
            XCTFail("记录保存失败不能启动检测")
        } catch { XCTAssertTrue(error is CheckpointFailure) }
        let requests = await transport.recordedRequests()
        XCTAssertFalse(requests.contains { field("method", $0) == "do_smart_test" })
    }

    func test确认后硬盘身份改变时不保存提交记录也不写入() async throws {
        let transport = MockHTTPTransport(responses: [response(storage.replacingOccurrences(of: "synthetic-device", with: "replacement-device")), response(status(false).replacingOccurrences(of: "synthetic-device", with: "replacement-device"))])
        let checkpoint = Checkpoint()
        let repository = try repository(transport)
        let result = try await repository.changeDiskTestResult(change(.quick)) { await checkpoint.record(99) }
        XCTAssertEqual(result.status, .confirmedFailure)
        XCTAssertEqual(result.errorCategory, .conflict)
        XCTAssertFalse(result.submitted)
        let count = await checkpoint.requestCount
        XCTAssertNil(count)
        let requests = await transport.recordedRequests()
        XCTAssertFalse(requests.contains { field("method", $0) == "do_smart_test" })
    }

    func test停止确认后的运行类型变化拒绝停止另一项检测() async throws {
        let transport = MockHTTPTransport(responses: [response(storage), response(status(true, type: "extend"))])
        let repository = try repository(transport)
        let request = NasDiskTestChange(disk: disk, baseline: .init(diskID: disk.id, isRunning: true, runningType: .quick), action: .stop)
        let checkpoint = Checkpoint()
        let result = try await repository.changeDiskTestResult(request) { await checkpoint.record(99) }
        XCTAssertEqual(result.status, .confirmedFailure)
        XCTAssertFalse(result.submitted)
        let count = await checkpoint.requestCount
        XCTAssertNil(count)
    }

    func test启动回读了另一种检测时不冒报成功() async throws {
        let transport = MockHTTPTransport(responses: [response(storage), response(status(false)), response(#"{"success":true}"#)] + Array(repeating: response(status(true, type: "extend")), count: 6))
        let repository = try repository(transport)
        let result = try await repository.startDiskTestResult(diskID: disk.id, type: .quick)
        XCTAssertEqual(result.status, .submittedButUnverified)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { field("method", $0) == "do_smart_test" }.count, 1)
    }

    func test旧状态返回签名也等待精确检测类型() async throws {
        let transport = MockHTTPTransport(responses: [response(storage), response(status(false)), response(#"{"success":true}"#), response(status(true, type: "extend")), response(status(true, type: "quick"))])
        let repository = try repository(transport)
        let result = try await repository.startDiskTest(diskID: disk.id, type: .quick)
        XCTAssertEqual(result.runningType, .quick)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { field("method", $0) == "get_smart_test_log" }.count, 3)
    }

    func test丢失回执后另一种检测运行仍保持未知() async throws {
        let transport = MockHTTPTransport(steps: [.response(response(storage)), .response(response(status(false))), .urlError(.networkConnectionLost), .response(response(status(true, type: "extend")))])
        let repository = try repository(transport)
        let result = try await repository.startDiskTestResult(diskID: disk.id, type: .quick)
        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.submitted)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { field("method", $0) == "do_smart_test" }.count, 1)
    }

    func test存储布尔状态区分明确否和缺失且旧调用保持() async throws {
        let payload = #"{"success":true,"data":{"disks":[],"storagePools":[{"id":"known","is_writable":false,"data_scrubbing":false},{"id":"unknown"}],"volumes":[{"id":"known","is_encrypted":false,"is_writable":false},{"id":"unknown"}]}}"#
        let repository = try repository(MockHTTPTransport(responses: [response(payload)]))
        let snapshot = try await repository.loadStorage()
        XCTAssertEqual(snapshot.pools[0].reportedWritable, false)
        XCTAssertEqual(snapshot.pools[0].reportedScrubbing, false)
        XCTAssertNil(snapshot.pools[1].reportedWritable)
        XCTAssertNil(snapshot.pools[1].reportedScrubbing)
        XCTAssertEqual(snapshot.volumes[0].reportedEncrypted, false)
        XCTAssertEqual(snapshot.volumes[0].reportedWritable, false)
        XCTAssertNil(snapshot.volumes[1].reportedEncrypted)
        XCTAssertNil(snapshot.volumes[1].reportedWritable)
        XCTAssertFalse(snapshot.volumes[1].isWritable)
        XCTAssertFalse(snapshot.volumes[1].isEncrypted)
    }

    func test日志分页保留完整正文和账号且仅读取() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"items":[{"time":"2026-10-05 08:00:00","level":"warn","logtype":"synthetic","who":"synthetic-user","descr":"First line\nSecond line"}],"total":51,"infoCount":40,"warnCount":10,"errorCount":1}}"#)])
        let repository = try repository(transport)
        let page = try await repository.loadLogs(offset: 50, limit: 50)
        XCTAssertEqual(page.entries.first?.message, "First line\nSecond line")
        XCTAssertEqual(page.entries.first?.account, "synthetic-user")
        XCTAssertEqual(page.total, 51)
        XCTAssertTrue(page.isTotalKnown)
        XCTAssertEqual(page.warningCount, 10)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(field("offset", requests[0]), "50")
        XCTAssertEqual(field("limit", requests[0]), "50")
        XCTAssertEqual(field("api", requests[0]), DsmAPIName.coreSystemLog)
    }

    func test日志缺少总数不编造完整数量() async throws {
        let repository = try repository(MockHTTPTransport(responses: [response(#"{"success":true,"data":{"items":[{"descr":"Synthetic"}]}}"#)]))
        let page = try await repository.loadLogs(offset: 50, limit: 50)
        XCTAssertFalse(page.isTotalKnown)
        XCTAssertEqual(page.total, 51)
        XCTAssertNil(page.infoCount)
        XCTAssertNil(page.warningCount)
        XCTAssertNil(page.errorCount)
    }

    func test日志缺失或畸形列表不能显示为空() async throws {
        for json in [
            #"{"success":true,"data":{}}"#,
            #"{"success":true,"data":{"items":{}}}"#,
            #"{"success":true,"data":{"items":[null]}}"#,
            #"{"success":true,"data":{"items":[{"level":"warn"}]}}"#,
            #"{"success":true,"data":{"items":[],"total":-1}}"#
        ] {
            let repository = try repository(MockHTTPTransport(responses: [response(json)]))
            do { _ = try await repository.loadLogs(offset: 0, limit: 50); XCTFail("畸形列表必须失败") }
            catch { XCTAssertEqual((error as? AppError)?.category, .invalidResponse) }
        }
    }

    private var disk: NasDisk { .init(id: "synthetic-disk", deviceID: "synthetic-device", name: "Synthetic Disk", model: nil, type: nil, totalBytes: nil, status: nil, smartStatus: "normal", temperatureCelsius: nil, isSSD: false, usedBy: nil, supportsSmartTest: true) }
    private func change(_ action: NasDiskTestAction) -> NasDiskTestChange { .init(disk: disk, baseline: .init(diskID: disk.id, isRunning: false), action: action) }
    private var storage: String { #"{"success":true,"data":{"disks":[{"id":"synthetic-disk","device":"synthetic-device","longName":"Synthetic Disk","smart_status":"normal","smart_test_support":true}],"storagePools":[],"volumes":[]}}"# }
    private func status(_ running: Bool, type: String? = nil) -> String {
        let typeField = type.map { ",\"test_type\":\"\($0)\"" } ?? ""
        return "{\"success\":true,\"data\":{\"testInfo\":[{\"device\":\"synthetic-device\",\"testing\":\(running),\"ihm_testing\":false,\"perf_testing\":false\(typeField)}]}}"
    }
    private func repository(_ transport: MockHTTPTransport) throws -> DsmNasAdministrationRepository {
        let names = [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk, DsmAPIName.coreSystemLog]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: names.map { name in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form, selectedVersion: 1))
        }))
        return try DsmNasAdministrationRepository(profile: NasProfile(displayName: "Synthetic", host: "nas.example.invalid", port: 5001), capabilities: capabilities,
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func response(_ text: String) -> DsmHTTPResponse { .init(data: Data(text.utf8), statusCode: 200) }
    private func field(_ name: String, _ request: URLRequest) -> String? {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        return URLComponents(string: "https://synthetic.invalid/?" + body)?.queryItems?.first { $0.name == name }?.value
    }
}

private actor Checkpoint {
    private(set) var requestCount: Int?
    func record(_ count: Int) { requestCount = count }
}
private enum CheckpointFailure: Error { case unavailable }

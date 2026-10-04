import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class DownloadStationInventoryTests: XCTestCase {
    func test完整目录超过旧上限仍读取最后任务() async throws {
        var responses = stride(from: 0, to: 5_500, by: 500).map {
            page(start: $0, count: 500, total: 5_501)
        }
        responses.append(page(start: 5_500, count: 1, total: 5_501))
        let transport = MockHTTPTransport(responses: responses)
        let snapshot = try await repository(transport).loadDownloadStationInventory()
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertEqual(snapshot.tasks.count, 5_501)
        XCTAssertEqual(snapshot.tasks.last?.id, "task-5500")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 12)
        XCTAssertEqual(field("offset", requests.last!), "5500")
        XCTAssertTrue(requests.allSatisfy { field("additional", $0) == "detail,transfer" })
        XCTAssertTrue(requests.allSatisfy { field("limit", $0) == "500" && field("version", $0) == "1" })
    }

    func test已知总量的短页继续读取直到结束() async throws {
        let transport = MockHTTPTransport(responses: [
            page(start: 0, count: 1, total: 2), page(start: 1, count: 1, total: 2)
        ])
        let snapshot = try await repository(transport).loadDownloadStationInventory()
        XCTAssertEqual(snapshot.tasks.map(\.id), ["task-0", "task-1"])
        XCTAssertTrue(snapshot.isComplete)
    }

    func test已知总量中途空页不能伪装为完整清单() async throws {
        let transport = MockHTTPTransport(responses: [
            page(start: 0, count: 1, total: 2), page(start: 1, count: 0, total: 2)
        ])
        await expectInvalid(transport)
    }

    func test畸形清单不能变成空目录() async throws {
        for data in [#"{}"#, #"{"tasks":{}}"#, #"{"tasks":[null]}"#,
                     #"{"tasks":[{"id":"one","status":"paused"}]}"#,
                     #"{"tasks":[],"total":true}"#, #"{"tasks":[],"offset":-1}"#,
                     #"{"tasks":[],"total":"9223372036854775808"}"#] {
            await expectInvalid(MockHTTPTransport(responses: [response(data)]))
        }
    }

    func test重复身份与总量漂移拒绝完整性结论() async throws {
        await expectInvalid(MockHTTPTransport(responses: [
            page(start: 0, count: 1, total: 2),
            response(#"{"tasks":[{"id":"task-0","title":"合成任务","status":"paused"}],"offset":1,"total":2}"#)
        ]))
        await expectInvalid(MockHTTPTransport(responses: [
            page(start: 0, count: 1, total: 2), page(start: 1, count: 1, total: 3)
        ]))
    }

    func test缺少总量时短页明确结束且空列表合法() async throws {
        let snapshot = try await repository(MockHTTPTransport(responses: [response(#"{"tasks":[]}"#)]))
            .loadDownloadStationInventory()
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertTrue(snapshot.tasks.isEmpty)
        XCTAssertNil(snapshot.statistics?.downloadBytesPerSecond)
    }

    func test摘要保持原有限定范围不宣称完整() async throws {
        let transport = MockHTTPTransport(responses: [page(start: 0, count: 1, total: 2)])
        let snapshot = try await repository(transport).loadDownloadStation()
        XCTAssertFalse(snapshot.isComplete)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(field("limit", requests[0]), "1000")
    }

    func test统计缺字段与负数保留未知真实零保持零() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"tasks":[]}"#),
            response(#"{"speed_download":0,"emule_speed_download":-1,"emule_speed_upload":true}"#)
        ])
        let snapshot = try await repository(transport, statistic: true).loadDownloadStationInventory()
        XCTAssertTrue(snapshot.hasActivitySummary)
        XCTAssertEqual(snapshot.statistics?.downloadBytesPerSecond, 0)
        XCTAssertNil(snapshot.statistics?.uploadBytesPerSecond)
        XCTAssertNil(snapshot.statistics?.emuleDownloadBytesPerSecond)
        XCTAssertNil(snapshot.statistics?.emuleUploadBytesPerSecond)
    }

    func test详情解析官方附属字段并剔除Tracker凭据() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"tasks":[{"id":"task-1","title":"合成任务","status":"downloading","size":"1000","type":"bt","username":"synthetic-user","additional":{"detail":{"destination":"synthetic-downloads","create_time":"1000","priority":"high","connected_seeders":3,"connected_leechers":2,"total_peers":9},"transfer":{"size_downloaded":"400","size_uploaded":"200","speed_download":20,"speed_upload":0},"file":[{"filename":"synthetic.txt","size":"1000","size_downloaded":"400","priority":"normal"}],"tracker":[{"url":"https://synthetic:credential@tracker.example.invalid:443/private-passkey/announce?key=synthetic-secret#private","status":"working","seeds":4,"peers":5,"update_timer":30}],"peer":[{"address":"192.0.2.1","agent":"Synthetic Client","progress":0.5,"speed_download":3,"speed_upload":0}]}}]}"#)])
        let detail = try await repository(transport).loadDownloadTaskDetails(id: "task-1")
        XCTAssertEqual(detail.task.remainingSeconds, 30)
        XCTAssertEqual(detail.task.shareRatio, 0.5)
        XCTAssertEqual(detail.task.destination, "synthetic-downloads")
        XCTAssertEqual(detail.kind, "bt")
        XCTAssertEqual(detail.owner, "synthetic-user")
        XCTAssertEqual(detail.createdAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(detail.connectedSeeders, 3)
        XCTAssertEqual(detail.files?.first?.downloadedBytes, 400)
        XCTAssertEqual(detail.trackers?.first?.displayAddress, "https://tracker.example.invalid:443")
        XCTAssertEqual(detail.peers?.first?.progress, 0.5)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(field("method", requests[0]), "getinfo")
        XCTAssertEqual(field("version", requests[0]), "1")
        XCTAssertEqual(field("id", requests[0]), "task-1")
        XCTAssertEqual(field("additional", requests[0]), "detail,transfer,file,tracker,peer")
    }

    func test详情缺失分区与明确空数组区分() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"tasks":[{"id":"task-1","title":"合成","status":"paused","additional":{"file":[],"peer":null}}]}"#)])
        let detail = try await repository(transport).loadDownloadTaskDetails(id: "task-1")
        XCTAssertEqual(detail.files, [])
        XCTAssertNil(detail.trackers)
        XCTAssertNil(detail.peers)
        XCTAssertNil(detail.task.downloadBytesPerSecond)
        XCTAssertNil(detail.task.remainingSeconds)
        XCTAssertNil(detail.task.shareRatio)
    }

    func test详情必须匹配唯一任务且拒绝畸形附属数组() async throws {
        for data in [#"{"tasks":[]}"#,
                     #"{"tasks":[{"id":"another","title":"合成","status":"paused"}]}"#,
                     #"{"tasks":[{"id":"task-1","title":"合成","status":"paused","additional":{"file":[null]}}]}"#] {
            do {
                _ = try await repository(MockHTTPTransport(responses: [response(data)]))
                    .loadDownloadTaskDetails(id: "task-1")
                XCTFail("不应接受身份不符或不完整的详情")
            } catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test详情拒绝多个身份与版本缺失且不发送请求() async throws {
        let transport = MockHTTPTransport(responses: [])
        for id in ["task-1,task-2", " task-1", "task-1\n"] {
            do {
                _ = try await repository(transport).loadDownloadTaskDetails(id: id)
                XCTFail("非法单项身份不得发送")
            } catch {}
        }
        do {
            _ = try await repository(transport, minimum: 2).loadDownloadTaskDetails(id: "task-1")
            XCTFail("未支持公开 v1 时不得猜测更高版本")
        } catch {}
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test剩余时间和分享率不由缺失值或负数推算() {
        let zeroSpeed = DownloadStationTask(id: "one", title: "合成", status: "downloading",
            sizeBytes: 100, downloadedBytes: 10, uploadedBytes: 0, downloadBytesPerSecond: 0)
        XCTAssertNil(zeroSpeed.remainingSeconds)
        XCTAssertEqual(zeroSpeed.shareRatio, 0)
        let invalid = DownloadStationTask(id: "one", title: "合成", status: "downloading",
            sizeBytes: 100, downloadedBytes: -1, uploadedBytes: -1, downloadBytesPerSecond: 3)
        XCTAssertNil(invalid.remainingSeconds)
        XCTAssertNil(invalid.shareRatio)
        XCTAssertNil(invalid.progress)
    }

    func test移除结果读取千项之后仍存在的任务不得误报成功() async throws {
        let pages = [page(start: 0, count: 500, total: 1002), page(start: 500, count: 500, total: 1002),
                     page(start: 1000, count: 2, total: 1002)]
        let transport = MockHTTPTransport(responses: pages + [response(#"{}"#)] + pages)
        let result = try await repository(transport).deleteDownloadTasksResult(ids: ["task-1001"], removeData: false)
        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertEqual(result.counts.unknown, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { field("method", $0) == "delete" }.count, 1)
        XCTAssertEqual(requests.filter { field("offset", $0) == "1000" }.count, 2)
    }

    func test移除后目录不完整时保留未知结果() async throws {
        let transport = MockHTTPTransport(responses: [page(start: 0, count: 1, total: 1), response(#"{}"#),
            response(#"{"tasks":[],"offset":0,"total":1}"#)])
        let result = try await repository(transport).deleteDownloadTasksResult(ids: ["task-0"], removeData: false)
        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertEqual(result.counts.unknown, 1)
    }

    private func expectInvalid(_ transport: MockHTTPTransport) async {
        do {
            _ = try await repository(transport).loadDownloadStationInventory()
            XCTFail("不完整响应不得返回完整目录")
        } catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        catch { XCTFail("意外错误类别：\(type(of: error))") }
    }

    private func repository(_ transport: MockHTTPTransport, statistic: Bool = false, minimum: Int = 1) throws -> DsmServiceManagementRepository {
        let names = [DsmAPIName.downloadStationTask] + (statistic ? [DsmAPIName.downloadStationStatistic] : [])
        let capabilities = names.map { name in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: minimum,
                maxVersion: 3, requestFormat: .form, selectedVersion: minimum))
        }
        return try DsmServiceManagementRepository(
            profile: NasProfile(displayName: "合成设备", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet(Dictionary(uniqueKeysWithValues: capabilities)),
            session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false),
            transport: transport)
    }

    private func page(start: Int, count: Int, total: Int) -> DsmHTTPResponse {
        let tasks = (start..<(start + count)).map {
            #"{"id":"task-\#($0)","title":"合成任务","status":"paused"}"#
        }.joined(separator: ",")
        return response(#"{"tasks":[\#(tasks)],"offset":\#(start),"total":\#(total)}"#)
    }

    private func response(_ data: String) -> DsmHTTPResponse {
        DsmHTTPResponse(data: Data(#"{"success":true,"data":\#(data)}"#.utf8), statusCode: 200)
    }

    private func field(_ name: String, _ request: URLRequest) -> String? {
        URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?
            .queryItems?.first { $0.name == name }?.value
    }
}

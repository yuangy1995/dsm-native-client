import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class DownloadStationRSSTests: XCTestCase {
    func test官方两种站点容器及数字字段并隐藏来源身份() async throws {
        for key in ["sites", "site"] {
            let transport = MockHTTPTransport(responses: [sites(key: key)])
            let result = try await repository(transport).loadDownloadRSSSites()
            XCTAssertEqual(result.count, 1); XCTAssertEqual(result.first?.id, 7)
            XCTAssertEqual(result.first?.lastUpdate, 1000); XCTAssertEqual(result.first?.isUpdating, false)
            XCTAssertEqual(result.first?.identityDigest.count, 64)
            XCTAssertFalse(String(describing: result).contains("secret")); XCTAssertFalse(String(describing: result).contains("synthetic-owner"))
            let requests = await transport.recordedRequests()
            XCTAssertEqual(field("version", requests[0]), "1"); XCTAssertEqual(field("limit", requests[0]), "500")
        }
    }

    func test条目指定站点并按字节字符串解析重复项不影响分页偏移() async throws {
        let feed = #"{"title":"合成条目","size":"792230407","time":1000,"download_uri":"https://example.invalid/file.torrent","external_link":"https://example.invalid/page"}"#
        let transport = MockHTTPTransport(responses: [response(#"{"feeds":[\#(feed),\#(feed)],"total":3,"offset":0}"#),
            response(#"{"feeds":[\#(feed)],"total":3,"offset":2}"#)])
        let result = try await repository(transport).loadDownloadRSSFeeds(siteID: 7)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result.first?.sizeBytes, 792230407)
        XCTAssertEqual(result.first?.id.count, 64); XCTAssertEqual(result.first?.downloadURI, "https://example.invalid/file.torrent")
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.allSatisfy { field("id", $0) == "7" && field("version", $0) == "1" })
        XCTAssertEqual(field("offset", requests[1]), "2")
    }

    func test分页总量漂移中途空页重复站点与畸形响应均不能变成空清单() async throws {
        let bad = [#"{}"#, #"{"sites":[],"site":[],"total":0,"offset":0}"#,
            #"{"sites":[],"total":true,"offset":0}"#, #"{"sites":[],"total":"0","offset":0}"#,
            #"{"sites":[],"total":0,"offset":1}"#, #"{"sites":[],"total":1,"offset":0}"#,
            #"{"sites":[null],"total":1,"offset":0}"#]
        for value in bad { await expectInvalid(MockHTTPTransport(responses: [response(value)])) }
        await expectInvalid(MockHTTPTransport(responses: [sites(total: 2), sites(offset: 1, total: 3)]))
        await expectInvalid(MockHTTPTransport(responses: [sites(total: 2), sites(offset: 1, total: 2)]))
        for (field, value) in [("id", "true"), ("id", "\"7\""), ("last_update", "-1"), ("is_updating", "1")] {
            let data = siteObject.replacingOccurrences(of: "\"\(field)\":" + (field == "id" ? "7" : field == "last_update" ? "1000" : "false"),
                with: "\"\(field)\":\(value)")
            await expectInvalid(MockHTTPTransport(responses: [response(#"{"sites":[\#(data)],"total":1,"offset":0}"#)]))
        }
    }

    func test条目尺寸不能套用BT数值类型或溢出负数布尔() async throws {
        for size in ["1000", "true", "\"-1\"", "\"9223372036854775808\"", "\"\""] {
            let transport = MockHTTPTransport(responses: [response(#"{"feeds":[{"title":"合成","size":\#(size),"time":1,"download_uri":"","external_link":""}],"total":1,"offset":0}"#)])
            do { _ = try await repository(transport).loadDownloadRSSFeeds(siteID: 7); XCTFail("畸形尺寸不能被默认为零") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test更新接受无Data成功回执仍需另外读取当前订阅() async throws {
        let transport = MockHTTPTransport(responses: [sites(), sites(), .init(data: Data(#"{"success":true}"#.utf8), statusCode: 200), sites()])
        let repository = try repository(transport), original = try await repository.loadDownloadRSSSites()[0]
        let receipt = try await repository.refreshDownloadRSSSite(original) {}
        XCTAssertEqual(receipt, .accepted)
        let current = try await repository.loadDownloadRSSSites()
        XCTAssertEqual(current[0].lastUpdate, original.lastUpdate)
        let requests = await transport.recordedRequests(), writes = requests.filter { field("method", $0) == "refresh" }
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(field("id", writes[0]), "7"); XCTAssertEqual(field("version", writes[0]), "1")
        XCTAssertEqual(writes[0].httpMethod, "POST")
    }

    func test未知回执和已接受未更新都不重复提交且日期前进后解除限制() async throws {
        for unknown in [false, true] {
            let step: MockHTTPTransport.Step = unknown ? .urlError(.timedOut) : .response(.init(data: Data(#"{"success":true}"#.utf8), statusCode: 200))
            let transport = MockHTTPTransport(steps: [.response(sites()), .response(sites()), step, .response(sites()),
                .response(sites(time: 1001)), .response(sites(time: 1001)), .response(.init(data: Data(#"{"success":true}"#.utf8), statusCode: 200))])
            let repository = try repository(transport), original = try await repository.loadDownloadRSSSites()[0]
            let receipt = try await repository.refreshDownloadRSSSite(original) {}
            XCTAssertEqual(receipt, unknown ? .unknown : .accepted)
            do { _ = try await repository.refreshDownloadRSSSite(original) {}; XCTFail("未结束更新不得重放") }
            catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
            let current = try await repository.loadDownloadRSSSites()[0]
            let next = try await repository.refreshDownloadRSSSite(current) {}; XCTAssertEqual(next, .accepted)
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.filter { field("method", $0) == "refresh" }.count, 2)
        }
    }

    func test写前保存失败或取消不发送以及站点替换不得更新() async throws {
        for cancel in [false, true] {
            let transport = MockHTTPTransport(responses: [sites(), sites()])
            let repository = try repository(transport), original = try await repository.loadDownloadRSSSites()[0]
            do {
                _ = try await repository.refreshDownloadRSSSite(original) {
                    if cancel { throw CancellationError() }; throw CocoaError(.fileWriteOutOfSpace)
                }
                XCTFail("必须保留写前门禁")
            } catch {}
            let requests = await transport.recordedRequests(); XCTAssertFalse(requests.contains { field("method", $0) == "refresh" })
        }
        let transport = MockHTTPTransport(responses: [sites(), sites(url: "https://example.invalid/replaced")])
        let repository = try repository(transport), original = try await repository.loadDownloadRSSSites()[0]
        do { _ = try await repository.refreshDownloadRSSSite(original) {}; XCTFail("不能更新同编号的另一个订阅") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
    }

    func test站点已在更新或已更新时不发送旧意图() async throws {
        for current in [sites(updating: true), sites(time: 1001)] {
            let transport = MockHTTPTransport(responses: [sites(), current])
            let repository = try repository(transport), original = try await repository.loadDownloadRSSSites()[0]
            do { _ = try await repository.refreshDownloadRSSSite(original) {}; XCTFail("旧意图不能重放") }
            catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        }
    }

    func test实际权限拒绝与未知错误严格区分() async throws {
        for (code, expected) in [(105, DownloadRSSRefreshReceipt.denied), (104, .rejected), (9999, .unknown)] {
            let transport = MockHTTPTransport(responses: [sites(), sites(), .init(data: Data("{\"success\":false,\"error\":{\"code\":\(code)}}".utf8), statusCode: 200)])
            let repository = try repository(transport), original = try await repository.loadDownloadRSSSites()[0]
            let receipt = try await repository.refreshDownloadRSSSite(original) {}; XCTAssertEqual(receipt, expected)
        }
    }

    func test公开版本缺失与非法站点不会发送请求() async throws {
        let transport = MockHTTPTransport(responses: []), repository = try repository(transport, minimum: 2)
        let supported = await repository.supportsDownloadRSS; XCTAssertFalse(supported)
        do { _ = try await repository.loadDownloadRSSSites(); XCTFail("v1 缺失必须拒绝") } catch {}
        do { _ = try await repository.loadDownloadRSSFeeds(siteID: -1); XCTFail("非法编号必须拒绝") } catch {}
        let requests = await transport.recordedRequests(); XCTAssertTrue(requests.isEmpty)
    }

    private var siteObject: String {
        #"{"id":7,"is_updating":false,"last_update":1000,"title":"合成订阅","url":"https://example.invalid/?secret=synthetic","username":"synthetic-owner"}"#
    }
    private func sites(key: String = "sites", offset: Int = 0, total: Int = 1, time: Int = 1000, updating: Bool = false, url: String? = nil) -> DsmHTTPResponse {
        var object = siteObject.replacingOccurrences(of: "\"last_update\":1000", with: "\"last_update\":\(time)")
            .replacingOccurrences(of: "\"is_updating\":false", with: "\"is_updating\":\(updating)")
        if let url { object = object.replacingOccurrences(of: "https://example.invalid/?secret=synthetic", with: url) }
        return response(#"{"\#(key)":[\#(object)],"offset":\#(offset),"total":\#(total)}"#)
    }
    private func response(_ data: String) -> DsmHTTPResponse { .init(data: Data(#"{"success":true,"data":\#(data)}"#.utf8), statusCode: 200) }
    private func field(_ name: String, _ request: URLRequest) -> String? {
        URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems?.first { $0.name == name }?.value
    }
    private func repository(_ transport: MockHTTPTransport, minimum: Int = 1) throws -> DsmServiceManagementRepository {
        let names = [DsmAPIName.downloadStationRSSSite, DsmAPIName.downloadStationRSSFeed]
        return try DsmServiceManagementRepository(profile: NasProfile(displayName: "合成设备", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet(Dictionary(uniqueKeysWithValues: names.map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: minimum, maxVersion: 3, requestFormat: .form, selectedVersion: 3)) })),
            session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func expectInvalid(_ transport: MockHTTPTransport) async {
        do { _ = try await repository(transport).loadDownloadRSSSites(); XCTFail("不完整读取不得报告空订阅") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        catch { XCTFail("错误类别不符：\(type(of: error))") }
    }
}

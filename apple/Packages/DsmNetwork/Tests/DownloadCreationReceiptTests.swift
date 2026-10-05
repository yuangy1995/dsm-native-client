import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class DownloadCreationReceiptTests: XCTestCase {
    private let uri = "https://files.example.invalid/synthetic.torrent"
    func testMac旧Void创建签名使用三版并接受官方空回执() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true}"#)])
        try await repository(transport).createDownloadTask(uri: uri, destination: "synthetic-downloads")
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(Self.field("method", calls[0]), "create"); XCTAssertEqual(Self.field("version", calls[0]), "3")
        XCTAssertEqual(Self.field("uri", calls[0]), uri); XCTAssertEqual(Self.field("destination", calls[0]), "synthetic-downloads")
    }
    func test官方三版空成功回执无需任务编号且严格符合请求样本() async throws {
        for reply in [#"{"success":true}"#, #"{"success":true,"data":{}}"#, #"{"success":true,"data":null}"#] {
            let transport = MockHTTPTransport(responses: [page(), response(reply)])
            let recorder = CreationReceiptRecorder()
            let result = try await repository(transport).createDownloadTaskResult(.init(uri: uri, destination: "synthetic-downloads"), willSubmit: { identity in
                let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
                XCTAssertEqual(Self.field("method", calls[0]), "list"); XCTAssertTrue(identity.isValid)
                await recorder.save(identity)
            }, didAccept: { await recorder.accept() })
            XCTAssertTrue(result.requestAccepted); XCTAssertEqual(result.result.status, .confirmedSuccess)
            XCTAssertNil(result.task); XCTAssertNil(result.taskID)
            let accepted = await recorder.accepted; XCTAssertEqual(accepted, 1)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
            var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }
            let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(
                "contracts/request-fixtures/download-station/create/synthetic-link-v3/request.json"))) as? [String: Any])
            for field in try XCTUnwrap(fixture["parameters"] as? [[String: Any]]) {
                let expected = (field["encodedValue"] as? String)?.replacingOccurrences(of: "<synthetic-download-uri>", with: uri)
                    .replacingOccurrences(of: "<synthetic-download-directory>", with: "synthetic-downloads")
                XCTAssertEqual(Self.field(try XCTUnwrap(field["name"] as? String), calls[1]), expected)
            }
            XCTAssertEqual(Self.field("version", calls[1]), "3")
            XCTAssertFalse(calls[1].url!.absoluteString.contains("REDACTED"))
        }
    }
    func test低版本链接零读取零创建而文件按目录选择版本() async throws {
        let none = MockHTTPTransport(responses: [])
        let result = try await repository(none, maximum: 2).createDownloadTaskResult(.init(uri: uri, destination: nil),
            willSubmit: { _ in XCTFail("版本不足不能保留已提交记录") }, didAccept: { XCTFail("版本不足") })
        XCTAssertEqual(result.result.status, .unsupported); let calls = await none.recordedRequests(); XCTAssertTrue(calls.isEmpty)
        let file = try input("AAAA"); defer { try? FileManager.default.removeItem(at: file) }
        for destination in [nil, "synthetic-downloads"] as [String?] {
            let transport = MockHTTPTransport(responses: [page(), response(#"{"success":true}"#)])
            let value = try await repository(transport, maximum: destination == nil ? 1 : 2).createDownloadTaskFileResult(
                .init(fileURL: file, destination: destination), willSubmit: { _ in }, didAccept: {})
            XCTAssertTrue(value.requestAccepted)
            let calls = await transport.recordedRequests(); XCTAssertEqual(Self.field("version", calls[1]), destination == nil ? "1" : "2")
        }
    }
    func test写前保存失败只读取而成功回执保存失败后同请求不能重发() async throws {
        let transport = MockHTTPTransport(responses: [page(), page(), response(#"{"success":true}"#)])
        let repo = try repository(transport), request = DownloadTaskCreateRequest(uri: uri, destination: nil)
        do { _ = try await repo.createDownloadTaskResult(request, willSubmit: { _ in throw CocoaError(.fileWriteOutOfSpace) }, didAccept: {}); XCTFail("预写失败必须返回") } catch {}
        var calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
        do { _ = try await repo.createDownloadTaskResult(request, willSubmit: { _ in }, didAccept: { throw CocoaError(.fileWriteOutOfSpace) }); XCTFail("回执存储失败") } catch {}
        let replay = try await repo.createDownloadTaskResult(request, willSubmit: { _ in XCTFail("旧未知不能再次预写") }, didAccept: {})
        XCTAssertFalse(replay.requestAccepted); XCTAssertEqual(replay.result.status, .submittedButUnverified)
        calls = await transport.recordedRequests(); XCTAssertEqual(calls.filter { Self.field("method", $0) == "create" }.count, 1)
    }
    func test来源摘要按文件内容区分且不受改名目录密码影响() async throws {
        let first = try input("AAAA"), second = try input("BBBB"), renamed = try input("AAAA")
        defer { for url in [first, second, renamed] { try? FileManager.default.removeItem(at: url) } }
        let identities = CreationReceiptRecorder()
        for (index, file) in [first, second, renamed].enumerated() {
            let transport = MockHTTPTransport(responses: [page(), response(#"{"success":true}"#)])
            _ = try await repository(transport).createDownloadTaskFileResult(.init(fileURL: file,
                destination: index == 2 ? "other" : "synthetic-downloads", unzipPassword: index == 2 ? "synthetic-secret" : nil),
                willSubmit: { await identities.save($0) }, didAccept: {})
        }
        let values = await identities.identities
        XCTAssertEqual(values.count, 3); XCTAssertNotEqual(values[0].sourceDigest, values[1].sourceDigest)
        XCTAssertEqual(values[0].sourceDigest, values[2].sourceDigest); XCTAssertNotEqual(values[0].requestDigest, values[2].requestDigest)
        let encoded = String(data: try JSONEncoder().encode(values), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("synthetic-secret")); XCTAssertFalse(encoded.contains("AAAA"))
    }
    func test链接来源摘要不含账号内容且换目录仍为同一来源() async throws {
        let identities = CreationReceiptRecorder()
        for destination in [nil, "synthetic-downloads"] as [String?] {
            let transport = MockHTTPTransport(responses: [page(), response(#"{"success":true}"#)])
            _ = try await repository(transport).createDownloadTaskResult(.init(uri: "https://synthetic:secret@files.example.invalid/a?key=private", destination: destination),
                willSubmit: { await identities.save($0) }, didAccept: {})
        }
        let values = await identities.identities
        XCTAssertEqual(values[0].sourceDigest, values[1].sourceDigest); XCTAssertNotEqual(values[0].requestDigest, values[1].requestDigest)
        XCTAssertFalse(String(data: try JSONEncoder().encode(values), encoding: .utf8)!.contains("secret"))
    }
    func test明确拒绝与未知错误分别保留真实结果() async throws {
        for code in [105, 402, 403, 405, 408, 100] {
            let transport = MockHTTPTransport(responses: [page(), response("{\"success\":false,\"error\":{\"code\":\(code)}}")])
            let result = try await repository(transport).createDownloadTaskResult(.init(uri: uri, destination: nil),
                willSubmit: { _ in }, didAccept: { XCTFail("错误不能保存接受回执") })
            XCTAssertFalse(result.requestAccepted)
            XCTAssertEqual(result.result.status, [105, 402].contains(code) ? .permissionDenied : code == 100 ? .submittedButUnverified : .confirmedFailure)
        }
    }
    func test发送后断网或取消只允许查询而不重新创建() async throws {
        for cancel in [false, true] {
            let transport = MockHTTPTransport(steps: [.response(page()), cancel ? .waitUntilCancelled : .urlError(.timedOut)])
            let repo = try repository(transport), request = DownloadTaskCreateRequest(uri: uri, destination: nil)
            let operation = Task { try await repo.createDownloadTaskResult(request, willSubmit: { _ in }, didAccept: { XCTFail("没有回执") }) }
            if cancel { while await transport.recordedRequests().count < 2 { await Task.yield() }; operation.cancel() }
            let result = try await operation.value; XCTAssertFalse(result.requestAccepted)
            XCTAssertEqual(result.result.status, cancel ? .cancellationRequestedAfterSubmission : .submittedButUnverified)
            _ = try await repo.createDownloadTaskResult(request, willSubmit: { _ in XCTFail("未知不能重发") }, didAccept: {})
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
        }
    }
    func test取消写前回调后不发送且不是未知结果() async throws {
        let transport = MockHTTPTransport(responses: [page()])
        let repo = try repository(transport), request = DownloadTaskCreateRequest(uri: uri, destination: nil)
        let operation = Task {
            try await repo.createDownloadTaskResult(request, willSubmit: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }, didAccept: { XCTFail("未发送") })
        }
        let result = try await operation.value; XCTAssertEqual(result.result.status, .cancelledBeforeSubmission)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
    }
    func test未提供创建空值约定的读取仍拒绝空成功() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true}"#)])
        do { _ = try await repository(transport).loadDownloadStationInventory(); XCTFail("列表不能用空回执冒充空列表") } catch {}
    }
    func test文件成功字段必须是布尔值而缺少上传能力不得保存已提交记录() async throws {
        let file = try input("synthetic"); defer { try? FileManager.default.removeItem(at: file) }
        for value in [#"{"success":"true"}"#, #"{"success":1}"#, #"{"data":{}}"#] {
            let transport = MockHTTPTransport(responses: [page(), response(value)])
            let result = try await repository(transport).createDownloadTaskFileResult(.init(fileURL: file, destination: nil),
                willSubmit: { _ in }, didAccept: { XCTFail("字段类型错误不能保存接受回执") })
            XCTAssertFalse(result.requestAccepted); XCTAssertEqual(result.result.status, .submittedButUnverified)
        }
        let transport = CreationNoUploadTransport()
        let result = try await repository(transport).createDownloadTaskFileResult(.init(fileURL: file, destination: nil),
            willSubmit: { _ in XCTFail("缺少上传传输能力") }, didAccept: { XCTFail("未发送") })
        XCTAssertEqual(result.result.status, .unsupported)
        let count = await transport.calls; XCTAssertEqual(count, 0)
    }
    private func input(_ value: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("creation-\(UUID()).torrent")
        try Data(value.utf8).write(to: url); return url
    }
    private func repository(_ transport: any DsmHTTPTransport, maximum: Int = 3) throws -> DsmServiceManagementRepository {
        try .init(profile: .init(displayName: "合成", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet([DsmAPIName.downloadStationTask: .init(name: DsmAPIName.downloadStationTask, path: "entry.cgi", minVersion: 1, maxVersion: maximum, requestFormat: .form, selectedVersion: 1)]),
            session: .init(sid: "REDACTED_SESSION", synoToken: "REDACTED_TOKEN", did: nil, isPortalPort: false), transport: transport)
    }
    private func response(_ value: String) -> DsmHTTPResponse { .init(data: Data(value.utf8), statusCode: 200) }
    private func page() -> DsmHTTPResponse { response(#"{"success":true,"data":{"tasks":[],"total":0,"offset":0}}"#) }
    private static func field(_ name: String, _ request: URLRequest) -> String? {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let form = URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems ?? []
        return (query + form).first { $0.name == name }?.value
    }
}

private actor CreationNoUploadTransport: DsmHTTPTransport {
    private(set) var calls = 0
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse { calls += 1; throw URLError(.unsupportedURL) }
}

private actor CreationReceiptRecorder {
    private(set) var identities: [DownloadTaskCreationIdentity] = []
    private(set) var accepted = 0
    func save(_ value: DownloadTaskCreationIdentity) { identities.append(value) }
    func accept() { accepted += 1 }
}

import DsmCore
import Foundation
import XCTest
@testable import DsmFileFeature

@MainActor
final class MobileVFSCloudAuthorizationTests: XCTestCase {
    func test系统浏览器回调只接受本次路径与回调名且完成后关闭端口() async throws {
        let request = context()
        var received: [FileVFSCloudAuthorization] = []
        var failures: [String] = []
        let server = FileVFSCloudAuthorizationSession(request: request, onAuthorization: { received.append($0) }, onFailure: { failures.append($0) })
        defer { server.stop() }
        var opened: URL?
        try server.start { opened = $0 }
        for _ in 0..<100 where opened == nil { try await Task.sleep(for: .milliseconds(20)) }
        let login = try XCTUnwrap(opened)
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(url: login, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let callback = try XCTUnwrap(fields["callback"])
        let origin = try XCTUnwrap(server.callbackBaseURL)
        XCTAssertEqual(origin.host, "127.0.0.1"); XCTAssertEqual(origin.scheme, "http")
        XCTAssertEqual(fields["host"], origin.absoluteString)
        XCTAssertEqual(login.host, "synooauth.synology.com")
        XCTAssertFalse(login.absoluteString.contains("nas.invalid"))
        XCTAssertGreaterThan(origin.path.count, 30)
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func send(_ url: URL, callbackName: String) async throws -> (Data, HTTPURLResponse) {
            var query = URLComponents()
            query.queryItems = [.init(name: "callback", value: callbackName), .init(name: "account", value: "synthetic-cloud-account"),
                .init(name: "access_token", value: "synthetic+access"), .init(name: "refresh_token", value: "synthetic-refresh"),
                .init(name: "expires_in", value: "3600")]
            var call = URLRequest(url: url); call.httpMethod = "POST"; call.timeoutInterval = 2
            call.httpBody = Data(query.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B").utf8)
            call.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await client.data(for: call)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }
        let wrongPath = origin.deletingLastPathComponent().appendingPathComponent("different-attempt")
        let (_, rejectedPath) = try await send(wrongPath, callbackName: callback)
        XCTAssertEqual(rejectedPath.statusCode, 404); XCTAssertTrue(received.isEmpty)
        let (_, rejectedName) = try await send(origin, callbackName: "wrong-callback")
        XCTAssertEqual(rejectedName.statusCode, 400); XCTAssertTrue(received.isEmpty); XCTAssertTrue(server.isRunning)
        let (body, accepted) = try await send(origin.appendingPathComponent("synthetic-relay"), callbackName: callback)
        for _ in 0..<100 where received.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(accepted.statusCode, 200); XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.requestID, request.id); XCTAssertEqual(received.first?.accessToken, "synthetic+access")
        XCTAssertEqual(received.first?.account, "synthetic-cloud-account")
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("synthetic+access"))
        XCTAssertEqual(accepted.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(server.isRunning); XCTAssertNil(server.loginURL); XCTAssertTrue(failures.isEmpty)
        do { _ = try await send(origin, callbackName: callback); XCTFail("完成后不能接受第二次授权") } catch {}
    }

    func test取消授权立即关闭监听且不产生连接写入() async throws {
        var received = false
        let server = FileVFSCloudAuthorizationSession(request: context(), onAuthorization: { _ in received = true }, onFailure: { _ in })
        try server.start { _ in }
        for _ in 0..<100 where server.callbackBaseURL == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(server.callbackBaseURL)
        server.stop()
        XCTAssertFalse(server.isRunning); XCTAssertNil(server.callbackBaseURL); XCTAssertFalse(received)
        XCTAssertThrowsError(try server.start { _ in })
    }

    func test回调解析拒绝重复长度越界与额外请求并支持分段正文() throws {
        let text = "callback=expected&account=synthetic&access_token=synthetic&expires_in=3600"
        let header = "POST /once/relay HTTP/1.1\r\nHost: 127.0.0.1:49152\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: \(text.utf8.count)\r\n\r\n"
        XCTAssertNil(try FileVFSCloudCallbackHTTP.decode(Data((header + String(text.prefix(10))).utf8)))
        let request = try XCTUnwrap(FileVFSCloudCallbackHTTP.decode(Data((header + text).utf8)))
        let payload = try request.authorizationPayload(callbackName: "expected")
        XCTAssertFalse(payload.isEmpty)
        XCTAssertThrowsError(try request.authorizationPayload(callbackName: "another"))
        XCTAssertThrowsError(try FileVFSCloudCallbackHTTP.decode(Data((header + text + "GET / HTTP/1.1").utf8)))
        XCTAssertThrowsError(try FileVFSCloudCallbackHTTP.decode(Data(header.replacingOccurrences(of: "Content-Length:", with: "Content-Length: 0\r\nContent-Length:").utf8)))
        XCTAssertThrowsError(try FileVFSCloudCallbackHTTP.decode(Data("POST / HTTP/1.1\r\nHost: 127.0.0.1:49152\r\nContent-Length: 200000\r\n\r\n".utf8)))
        XCTAssertThrowsError(try FileVFSCloudCallbackHTTP.decode(Data("GET https://external.invalid HTTP/1.1\r\nHost: external.invalid\r\n\r\n".utf8)))
    }

    func test包装回调保持字段白名单并拒绝冲突与布尔过期时间() throws {
        let json = #"{"callback":"expected","account":"synthetic","access_token":"synthetic","expires_in":3600,"password":"never-forward"}"#
        var encoded = URLComponents(); encoded.queryItems = [.init(name: "data", value: json)]
        let request = FileVFSCloudCallbackHTTP.Request(host: "127.0.0.1:49152", path: "/once", query: encoded.percentEncodedQuery, contentType: nil, body: Data())
        let data = try request.authorizationPayload(callbackName: "expected")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(fields["password"])
        let conflicting = FileVFSCloudCallbackHTTP.Request(host: request.host, path: request.path,
            query: "callback=another", contentType: "application/json", body: Data(json.utf8))
        XCTAssertThrowsError(try conflicting.authorizationPayload(callbackName: "expected"))
        let boolean = FileVFSCloudCallbackHTTP.Request(host: request.host, path: request.path, query: nil,
            contentType: "application/json", body: Data(json.replacingOccurrences(of: "3600", with: "true").utf8))
        XCTAssertThrowsError(try boolean.authorizationPayload(callbackName: "expected"))
    }

    private func context() -> FileVFSCloudAuthorizationRequest {
        .init(profileID: UUID(), protocolID: "google",
            loginURL: URL(string: "https://synooauth.synology.com/FileStation/Cloud/login.php?major=7&minor=2&type=google")!,
            callbackName: "_webfmOAuthCallback")
    }
}

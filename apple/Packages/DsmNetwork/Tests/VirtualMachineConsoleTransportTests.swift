import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class VirtualMachineConsoleTransportTests: XCTestCase, @unchecked Sendable {
    private func setup(http: ConsoleAssetTransport = ConsoleAssetTransport(), socket: ConsoleTestSocket = ConsoleTestSocket()) throws -> (VirtualMachineConsolePolicy, DsmVirtualMachineConsoleTransport) {
        let policy = try VirtualMachineConsolePolicy(baseURL: XCTUnwrap(URL(string: "https://nas.example.invalid:5001")), machineID: "vm-1", name: "Synthetic", keyboardLayout: "en-us")
        let transport = try DsmVirtualMachineConsoleTransport(policy: policy, cookie: "SYNTHETIC_COOKIE", http: http) { request in
            XCTAssertEqual(request.url, policy.socketURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=SYNTHETIC_COOKIE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://nas.example.invalid:5001")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "binary")
            XCTAssertFalse(request.url?.absoluteString.contains("SYNTHETIC_COOKIE") == true)
            return socket
        }
        return (policy, transport)
    }
    func test静态请求仅向固定资源发送Cookie且关闭后零请求() async throws {
        let http = ConsoleAssetTransport(), (policy, transport) = try setup(http: http)
        let resource = try await transport.resource(policy.documentURL)
        XCTAssertEqual(resource.mediaType, "text/html")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Cookie"), "id=SYNTHETIC_COOKIE")
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
        await transport.close()
        do { _ = try await transport.resource(policy.documentURL); XCTFail("关闭后不能读取") } catch { XCTAssertEqual(error as? VirtualMachineConsoleError, .closed) }
        let count = await http.requests.count
        XCTAssertEqual(count, 1)
    }
    func test重定向错误类型超限与登录页面不能当资源() async throws {
        for mode in [ConsoleAssetTransport.Mode.redirect, .wrongType, .oversized, .unauthorized] {
            let (policy, transport) = try setup(http: .init(mode: mode))
            do { _ = try await transport.resource(policy.documentURL); XCTFail("不安全资源不能加载：\(mode)") }
            catch {
                if mode == .unauthorized { XCTAssertEqual((error as? AppError)?.category, .authenticationRequired) }
                else if mode == .redirect { XCTAssertEqual((error as? AppError)?.category, .invalidResponse) }
                else { XCTAssertEqual(error as? VirtualMachineConsoleError, .invalidResponse) }
            }
            await transport.close()
        }
    }
    func test网络越界请求在发出前拒绝() async throws {
        let http = ConsoleAssetTransport(), (_, transport) = try setup(http: http)
        for text in ["https://other.invalid/app.js", "https://nas.example.invalid:5001/webapi/entry.cgi", "https://nas.example.invalid:5001/webman/3rdparty/Virtualization/noVNC/app.js?_sid=synthetic"] {
            do { _ = try await transport.resource(XCTUnwrap(URL(string: text))); XCTFail("不应向越界地址发请求") }
            catch { XCTAssertEqual(error as? VirtualMachineConsoleError, .forbiddenResource) }
        }
        let count = await http.requests.count
        XCTAssertEqual(count, 0)
        await transport.close()
    }
    func test画面连接只开启一次且关闭后不再发送() async throws {
        let socket = ConsoleTestSocket(), (_, transport) = try setup(socket: socket)
        try await transport.connect(); try await transport.send(Data([1, 2]))
        let data = try await transport.receive()
        XCTAssertEqual(data, Data([7, 8]))
        do { try await transport.connect(); XCTFail("不能自动重连") } catch {}
        await transport.close()
        do { try await transport.send(Data([3])); XCTFail("关闭后不能发送") } catch {}
        let opens = await socket.opens, inputs = await socket.inputs, closed = await socket.closed
        XCTAssertEqual(opens, 1); XCTAssertEqual(inputs, [Data([1, 2])]); XCTAssertTrue(closed)
    }
    func test握手失败不开放输入且不自动重试() async throws {
        let socket = ConsoleTestSocket(fails: true), (_, transport) = try setup(socket: socket)
        do { try await transport.connect(); XCTFail("失败不能报连接成功") } catch {}
        do { try await transport.send(Data([1])); XCTFail("失败后不能发送") } catch {}
        do { try await transport.connect(); XCTFail("失败后不能重复握手") } catch {}
        let opens = await socket.opens, inputs = await socket.inputs
        XCTAssertEqual(opens, 1); XCTAssertTrue(inputs.isEmpty)
    }
    func test无效Cookie不能进入网络请求() throws {
        let policy = try setup().0
        for cookie in ["", "x;y", "x\ny", "a,b", "x\\y", "中文"] {
            XCTAssertThrowsError(try DsmVirtualMachineConsoleTransport(policy: policy, cookie: cookie, http: ConsoleAssetTransport()) { _ in ConsoleTestSocket() })
        }
    }
    func test控制台传输单独禁止同源重定向且不改变其他调用默认策略() throws {
        let session = URLSession(configuration: .ephemeral)
        let original = try XCTUnwrap(URL(string: "https://example.invalid/from"))
        let destination = URLRequest(url: try XCTUnwrap(URL(string: "https://example.invalid/to")))
        let task = session.dataTask(with: original)
        let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
        let consoleDelegate = DsmTLSDelegate(expectedHost: "example.invalid", pinnedFingerprint: nil, allowsRedirects: false)
        consoleDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: destination) { XCTAssertNil($0) }
        let ordinary = DsmTLSDelegate(expectedHost: "example.invalid", pinnedFingerprint: nil)
        ordinary.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: destination) { XCTAssertEqual($0?.url, destination.url) }
        session.invalidateAndCancel()
    }
}

private actor ConsoleTestSocket: DsmConsoleSocket {
    let fails: Bool
    var opens = 0
    var inputs: [Data] = []
    var closed = false
    init(fails: Bool = false) { self.fails = fails }
    func connect() async throws { opens += 1; if fails { throw VirtualMachineConsoleError.unavailable } }
    func receive() async throws -> Data { Data([7, 8]) }
    func send(_ data: Data) async throws { inputs.append(data) }
    func close() async { closed = true }
}

private actor ConsoleAssetTransport: DsmHTTPTransport {
    enum Mode { case normal, redirect, wrongType, oversized, unauthorized }
    let mode: Mode
    var requests: [URLRequest] = []
    init(mode: Mode = .normal) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        requests.append(request)
        return .init(data: mode == .oversized ? Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1) : Data("<html></html>".utf8),
                     statusCode: mode == .redirect ? 302 : mode == .unauthorized ? 401 : 200,
                     headers: ["Content-Type": mode == .wrongType ? "application/json" : "text/html", "Location": "https://other.invalid/"])
    }
}

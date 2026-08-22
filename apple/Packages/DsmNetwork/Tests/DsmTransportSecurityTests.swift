import Foundation
import XCTest
@testable import DsmNetwork

final class DsmTransportSecurityTests: XCTestCase {
    override func tearDown() {
        SyntheticTransportURLProtocol.handler = nil
        super.tearDown()
    }

    func testTLS失败按任务标识隔离消费() {
        let failures = TaskScopedTLSFailureStore()
        let firstReview = review(fingerprint: "AA")
        let secondReview = review(fingerprint: "BB")
        failures.store(.untrusted(firstReview), taskIdentifier: 11)
        failures.store(.changed(secondReview), taskIdentifier: 22)

        guard case .changed(let consumedSecond)? = failures.consume(taskIdentifier: 22)
        else {
            return XCTFail("第二个任务应只取得自己的证书失败。")
        }
        XCTAssertEqual(consumedSecond, secondReview)
        XCTAssertNil(failures.consume(taskIdentifier: 22))

        guard case .untrusted(let consumedFirst)? = failures.consume(taskIdentifier: 11)
        else {
            return XCTFail("第一个任务的证书失败不应被其他任务消费。")
        }
        XCTAssertEqual(consumedFirst, firstReview)
    }

    func test会话级TLS失败按host归属且取消不消费其他任务错误() throws {
        let failures = SessionScopedTLSFailureStore()
        let firstScope = try XCTUnwrap(
            SessionTLSFailureScope(
                host: "nas-a.example.invalid",
                port: 5_001,
                scheme: "https",
                expectedHost: "configured.example.invalid"
            )
        )
        let secondScope = try XCTUnwrap(
            SessionTLSFailureScope(
                host: "nas-b.example.invalid",
                port: 5_001,
                scheme: "https",
                expectedHost: "configured.example.invalid"
            )
        )
        XCTAssertNotEqual(firstScope, secondScope)
        let firstReview = review(fingerprint: "AA")
        let secondReview = DsmCertificateReview(
            host: "nas-b.example.invalid",
            subjectSummary: "Synthetic NAS B",
            sha256Fingerprint: "BB",
            canBePinned: true
        )
        failures.register(taskIdentifier: 11, scope: firstScope)
        failures.register(taskIdentifier: 22, scope: firstScope)
        failures.register(taskIdentifier: 33, scope: secondScope)

        // 这里模拟 URLSessionDelegate 的无 taskIdentifier 服务器信任挑战。
        failures.store(.untrusted(firstReview), scope: firstScope)
        failures.store(.changed(secondReview), scope: secondScope)
        failures.remove(taskIdentifier: 11)
        failures.register(taskIdentifier: 44, scope: firstScope)

        XCTAssertNil(failures.consume(taskIdentifier: 11))
        XCTAssertNil(failures.consume(taskIdentifier: 44))
        guard case .untrusted(let consumedFirst)? = failures.consume(taskIdentifier: 22)
        else {
            return XCTFail("同 host 的未取消任务应获得结构化 TLS 错误。")
        }
        XCTAssertEqual(consumedFirst, firstReview)
        guard case .changed(let consumedSecond)? = failures.consume(taskIdentifier: 33)
        else {
            return XCTFail("不同 host 的失败必须保持隔离。")
        }
        XCTAssertEqual(consumedSecond, secondReview)
    }

    func test会话级TLS失败不会泄漏给挑战后才注册的任务() throws {
        let failures = SessionScopedTLSFailureStore()
        let scope = try XCTUnwrap(
            SessionTLSFailureScope(
                host: "nas.example.invalid",
                port: 443,
                scheme: "https",
                expectedHost: nil
            )
        )
        let review = review(fingerprint: "CC")
        failures.register(taskIdentifier: 1, scope: scope)
        failures.store(.untrusted(review), scope: scope)
        failures.register(taskIdentifier: 2, scope: scope)

        XCTAssertNil(failures.consume(taskIdentifier: 2))
        guard case .untrusted(let consumed)? = failures.consume(taskIdentifier: 1)
        else {
            return XCTFail("挑战发生时已经在途的任务应保留其 TLS 错误。")
        }
        XCTAssertEqual(consumed, review)
    }

    func test同源HTTPS重定向保留请求头但收敛查询凭据() throws {
        var proposed = URLRequest(
            url: try XCTUnwrap(
                URL(string: "https://nas.example.invalid:5001/next?keep=1&_sid=synthetic-session&SynoToken=synthetic-token")
            )
        )
        proposed.setValue("id=synthetic-session", forHTTPHeaderField: "Cookie")

        let redirected = DsmRedirectPolicy.redirectedRequest(
            from: try XCTUnwrap(URL(string: "https://nas.example.invalid:5001/start")),
            proposedRequest: proposed
        )
        let url = try XCTUnwrap(redirected?.url)
        let query = Dictionary(
            uniqueKeysWithValues: (
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            ).map { ($0.name, $0.value ?? "") }
        )

        XCTAssertEqual(query["keep"], "1")
        XCTAssertNil(query["_sid"])
        XCTAssertNil(query["SynoToken"])
        XCTAssertEqual(redirected?.value(forHTTPHeaderField: "Cookie"), "id=synthetic-session")
    }

    func test跨源或非HTTPS重定向被取消() throws {
        let source = try XCTUnwrap(URL(string: "https://nas.example.invalid:5001/start"))
        let destinations = [
            "https://other.example.invalid:5001/next",
            "https://nas.example.invalid:5002/next",
            "http://nas.example.invalid:5001/next",
        ]

        for destination in destinations {
            let request = URLRequest(url: try XCTUnwrap(URL(string: destination)))
            XCTAssertNil(
                DsmRedirectPolicy.redirectedRequest(
                    from: source,
                    proposedRequest: request
                ),
                "不应允许重定向到 \(destination)"
            )
        }
    }

    func test诊断脱敏移除查询凭据并覆盖敏感请求头() throws {
        let source = try XCTUnwrap(
            URL(string: "https://nas.example.invalid/entry.cgi?api=SYNO.Test&_sid=synthetic-session&SynoToken=synthetic-token")
        )
        let url = DsmSensitiveRequestRedactor.redactedURL(source)
        let headers = DsmSensitiveRequestRedactor.redactedHeaders([
            "Cookie": "id=synthetic-session",
            "X-SYNO-TOKEN": "synthetic-token",
            "Authorization": "Bearer synthetic-value",
            "Location": "/entry.cgi?next=1&_sid=synthetic-session&SynoToken=synthetic-token",
            "Accept": "application/json",
        ])

        XCTAssertFalse(url.absoluteString.contains("synthetic-session"))
        XCTAssertFalse(url.absoluteString.contains("synthetic-token"))
        XCTAssertEqual(headers["Cookie"], "<redacted>")
        XCTAssertEqual(headers["X-SYNO-TOKEN"], "<redacted>")
        XCTAssertEqual(headers["Authorization"], "<redacted>")
        XCTAssertEqual(headers["Location"], "/entry.cgi?next=1")
        XCTAssertEqual(headers["Accept"], "application/json")
    }

    func test声明响应长度超限会立即取消并报告统一错误() throws {
        let box = BoundedResponseDataBox(maximumBytes: 8)
        let response = URLResponse(
            url: try XCTUnwrap(URL(string: "https://nas.example.invalid/entry.cgi")),
            mimeType: "application/json",
            expectedContentLength: 9,
            textEncodingName: nil
        )

        XCTAssertEqual(box.accept(response), .cancel)
        XCTAssertThrowsError(try box.value()) { error in
            XCTAssertEqual(error as? DsmTransportError, .responseTooLarge)
        }
    }

    func test分块响应超过上限不会继续累积() throws {
        let box = BoundedResponseDataBox(maximumBytes: 8)
        XCTAssertTrue(box.append(Data(repeating: 0x01, count: 5)))
        XCTAssertFalse(box.append(Data(repeating: 0x02, count: 4)))
        XCTAssertThrowsError(try box.value()) { error in
            XCTAssertEqual(error as? DsmTransportError, .responseTooLarge)
        }
    }

    func testURLSession传输在超限响应前不返回完整数据() async throws {
        SyntheticTransportURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "9"]
                )
            )
            return (response, Data(repeating: 0x01, count: 9))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticTransportURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: configuration,
            maximumResponseBytes: 8
        )

        do {
            _ = try await transport.send(
                URLRequest(
                    url: try XCTUnwrap(URL(string: "https://nas.example.invalid/entry.cgi"))
                )
            )
            XCTFail("超限响应不应返回给上层。")
        } catch let error as DsmTransportError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testURLSession响应头统一脱敏() async throws {
        SyntheticTransportURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "Set-Cookie": "id=synthetic-session",
                        "X-SYNO-TOKEN": "synthetic-token",
                        "Location": "/entry.cgi?next=1&_sid=synthetic-session",
                    ]
                )
            )
            return (response, Data(#"{}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticTransportURLProtocol.self]
        let transport = URLSessionTransport(configuration: configuration)

        let response = try await transport.send(
            URLRequest(
                url: try XCTUnwrap(
                    URL(string: "https://nas.example.invalid/entry.cgi")
                )
            )
        )

        XCTAssertEqual(response.headers["content-type"], "application/json")
        XCTAssertEqual(response.headers["set-cookie"], "<redacted>")
        XCTAssertEqual(response.headers["x-syno-token"], "<redacted>")
        XCTAssertEqual(response.headers["location"], "/entry.cgi?next=1")
    }

    private func review(fingerprint: String) -> DsmCertificateReview {
        DsmCertificateReview(
            host: "nas.example.invalid",
            subjectSummary: "Synthetic NAS",
            sha256Fingerprint: fingerprint,
            canBePinned: true
        )
    }
}

private final class SyntheticTransportURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

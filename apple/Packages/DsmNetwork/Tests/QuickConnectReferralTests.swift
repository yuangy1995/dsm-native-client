import CryptoKit
import Foundation
import XCTest
@testable import DsmNetwork

final class QuickConnectReferralTests: XCTestCase {
    private let globals = ["global.quickconnect.to", "global.quickconnect.cn"]
    private let online = """
    [{"errno":0,"server":{"ds_state":"CONNECTED"},"service":{"port":5001},
      "smartdns":{"host":"sample.direct.quickconnect.to"}}]
    """

    override func tearDown() {
        ReferralURLProtocol.handler = nil
        super.tearDown()
    }

    func test全球入口转介可跨区域并继续多级查询() async throws {
        var hosts: [String] = []
        let resolver = makeResolver { request in
            let host = try XCTUnwrap(request.url?.host)
            hosts.append(host)
            try self.checkControlRequest(request)
            switch host {
            case "region.quickconnect.to":
                return self.referral(["region.quickconnect.cn"])
            case "region.quickconnect.cn":
                return self.online
            default:
                return self.referral(["REGION.QUICKCONNECT.TO", "region.quickconnect.to"])
            }
        }

        let endpoints = try await resolver.resolve(id: "sample")

        XCTAssertEqual(endpoints.map(\.host), ["sample.direct.quickconnect.to"])
        XCTAssertEqual(hosts, globals + ["region.quickconnect.to", "region.quickconnect.cn"])
    }

    func test拒绝非官方主机和不合法DNS标签且不发出对应请求() async throws {
        let invalidSites = [
            "attacker.invalid", "global.quickconnect.to.attacker.invalid",
            "https://region.quickconnect.to", "region.quickconnect.to/path",
            "user@region.quickconnect.to", "region.quickconnect.to:443",
            "region.quickconnect.to?query=1", "region.quickconnect.to#fragment",
            ".quickconnect.to", "region..quickconnect.to", "region.quickconnect.to.",
            "-region.quickconnect.to", "region-.quickconnect.to", "bad_label.quickconnect.cn",
            String(repeating: "a", count: 64) + ".quickconnect.to"
        ]
        for site in invalidSites {
            var hosts: [String] = []
            let resolver = makeResolver { request in
                hosts.append(try XCTUnwrap(request.url?.host))
                return self.referral([site])
            }

            await expectError(.invalidResponse, resolver: resolver)
            XCTAssertEqual(hosts, globals, site)
        }
    }

    func test转介元素不是字符串时拒绝() async {
        for site in ["null", "42", "{}"] {
            var count = 0
            let resolver = makeResolver { _ in
                count += 1
                return "[{\"errno\":4,\"sites\":[\(site)]}]"
            }
            await expectError(.invalidResponse, resolver: resolver)
            XCTAssertEqual(count, 2)
        }
    }

    func test循环和重复转介不会超过八个唯一入口() async {
        var hosts: [String] = []
        let sites = globals + (0..<30).map { "region-\($0).quickconnect.to" }
        let resolver = makeResolver { request in
            hosts.append(try XCTUnwrap(request.url?.host))
            return self.referral(sites + sites)
        }

        await expectError(.notFound, resolver: resolver)

        XCTAssertEqual(hosts, globals + (0..<6).map { "region-\($0).quickconnect.to" })
        XCTAssertEqual(Set(hosts).count, 8)
    }

    func test转介回全球入口不会再次查询() async {
        var hosts: [String] = []
        let resolver = makeResolver { request in
            hosts.append(try XCTUnwrap(request.url?.host))
            return self.referral(self.globals + self.globals.map { $0.uppercased() })
        }

        await expectError(.notFound, resolver: resolver)

        XCTAssertEqual(hosts, globals)
    }

    func test没有转介字段时保留未找到错误() async {
        var count = 0
        let resolver = makeResolver { _ in count += 1; return "[{\"errno\":4}]" }
        await expectError(.notFound, resolver: resolver)
        XCTAssertEqual(count, 2)
    }

    func test首个在线但无直连响应不会被其他入口错误覆盖() async {
        var count = 0
        let resolver = makeResolver { _ in
            count += 1
            return count == 1
                ? "[{\"errno\":0,\"server\":{\"ds_state\":\"CONNECTED\"}}]"
                : "[{\"errno\":4}]"
        }

        await expectError(.noDirectRoute, resolver: resolver)

        XCTAssertEqual(count, 1)
    }

    func test首个入口网络失败后仍可经另一个入口转介() async throws {
        var hosts: [String] = []
        let resolver = makeResolver { request in
            let host = try XCTUnwrap(request.url?.host)
            hosts.append(host)
            if host == self.globals[0] { throw URLError(.timedOut) }
            return host == "region.quickconnect.cn"
                ? self.online : self.referral(["region.quickconnect.cn"])
        }

        let endpoints = try await resolver.resolve(id: "sample")

        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(hosts, globals + ["region.quickconnect.cn"])
    }

    func test中继发现沿用区域转介并完成身份核对() async throws {
        var hosts: [String] = []
        let resolver = makeRelayResolver(hosts: { hosts.append($0) }, matchesIdentity: true)

        let endpoint = try await resolver.requestRelay(id: "sample")

        XCTAssertEqual(endpoint, QuickConnectEndpoint(host: "sample.r1.quickconnect.cn", port: 443, kind: .relay))
        XCTAssertEqual(hosts, globals + ["region.quickconnect.cn", "region.quickconnect.cn", "sample.r1.quickconnect.cn"])
    }

    func test区域转介后的中继身份不匹配仍停止且不重试() async {
        var hosts: [String] = []
        let resolver = makeRelayResolver(hosts: { hosts.append($0) }, matchesIdentity: false)

        do {
            _ = try await resolver.requestRelay(id: "sample")
            XCTFail("身份不匹配不得返回中继。")
        } catch {
            XCTAssertEqual(error as? QuickConnectResolutionError, .relayIdentityMismatch)
        }
        XCTAssertEqual(hosts.count, 5)
    }

    func test开始前取消不查询任何入口() async throws {
        let resolver = makeResolver { _ in
            XCTFail("已取消任务不应发出请求。")
            return self.online
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await resolver.resolve(id: "sample")
        }
        do {
            _ = try await task.value
            XCTFail("应传播取消。")
        } catch is CancellationError {} catch { XCTFail("取消不应变成连接失败：\(error)") }
    }

    func test请求期间取消不继续查询其他入口() async throws {
        let started = expectation(description: "首个请求已开始")
        var count = 0
        let resolver = makeResolver { _ in
            count += 1
            started.fulfill()
            return nil
        }
        let task = Task { try await resolver.resolve(id: "sample") }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("应传播取消。")
        } catch is CancellationError {} catch { XCTFail("取消不应变成连接失败：\(error)") }
        XCTAssertEqual(count, 1)
    }

    private func makeRelayResolver(hosts: @escaping (String) -> Void, matchesIdentity: Bool) -> DsmQuickConnectResolver {
        makeResolver { request in
            let host = try XCTUnwrap(request.url?.host)
            hosts(host)
            if request.httpMethod == "GET" {
                XCTAssertEqual(host, "sample.r1.quickconnect.cn")
                let identity = Insecure.MD5.hash(data: Data("synthetic-server".utf8))
                    .map { String(format: "%02x", $0) }.joined()
                return "{\"ezid\":\"\(matchesIdentity ? identity : "mismatch")\"}"
            }
            try self.checkControlRequest(request)
            if self.globals.contains(host) { return self.referral(["region.quickconnect.cn"]) }
            XCTAssertEqual(host, "region.quickconnect.cn")
            // 同一受控响应同时支持发现和隧道申请；不会提供直连地址。
            return """
            [{"errno":0,"server":{"ds_state":"CONNECTED","serverID":"synthetic-server"},
              "service":{"relay_ip":"203.0.113.10","relay_port":12345},
              "env":{"control_host":"region.quickconnect.cn","relay_region":"r1"}}]
            """
        }
    }

    private func makeResolver(_ response: @escaping (URLRequest) throws -> String?) -> DsmQuickConnectResolver {
        ReferralURLProtocol.handler = response
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReferralURLProtocol.self]
        return DsmQuickConnectResolver(
            session: URLSession(configuration: configuration),
            controlURLs: globals.map { URL(string: "https://\($0)/Serv.php")! }
        )
    }

    private func referral(_ hosts: [String]) -> String {
        let value = try! JSONSerialization.data(withJSONObject: [["errno": 4, "suberrno": 0, "sites": hosts]])
        return String(decoding: value, as: UTF8.self)
    }

    private func checkControlRequest(_ request: URLRequest) throws {
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.path, "/Serv.php")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-SYNO-TOKEN"))
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let commands = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(Set(command.keys), ["version", "command", "stop_when_error", "stop_when_success", "id", "serverID", "is_gofile", "path"])
        XCTAssertEqual(command["serverID"] as? String, "sample")
        XCTAssertEqual(command["id"] as? String, "mainapp_https")
    }

    private func expectError(_ expected: QuickConnectResolutionError, resolver: DsmQuickConnectResolver) async {
        do {
            _ = try await resolver.resolve(id: "sample")
            XCTFail("应返回 \(expected)。")
        } catch { XCTAssertEqual(error as? QuickConnectResolutionError, expected) }
    }
}

private final class ReferralURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> String?)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let body = try Self.handler?(request) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}

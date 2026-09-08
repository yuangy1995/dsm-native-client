import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class DsmAuthenticationServiceTests: XCTestCase {
    func test两台NAS登录后首个文件请求分别携带自己的认证且不进入URL() async throws {
        for format in [DsmRequestFormat.form, .json] {
            var clients: [(NasProfile, DsmFileRepository, MockHTTPTransport, String, String)] = []
            for alias in ["first", "second"] {
                let sid = "synthetic-session-\(alias)"
                let token = "synthetic-token-\(alias)"
                let response = try JSONSerialization.data(withJSONObject: ["success": true, "data": ["sid": sid, "synotoken": token]])
                let transport = MockHTTPTransport(responses: [
                    DsmHTTPResponse(data: response, statusCode: 200),
                    DsmHTTPResponse(data: Data(#"{"success":true,"data":{"offset":0,"total":0,"shares":[]}}"#.utf8), statusCode: 200)
                ])
                let profile = try NasProfile(displayName: "Synthetic NAS", host: "\(alias).example.invalid", port: alias == "first" ? 5001 : 6443)
                let auth = DsmAuthenticationService(client: DsmAPIClient(baseURL: try DsmEndpoint.baseURL(for: profile), transport: transport))
                let session = try await auth.login(capability: authenticationCapability, account: "synthetic-user", password: "synthetic-password", otpCode: nil)
                let files = try DsmFileRepository(profile: profile, capabilities: CapabilitySet([
                    DsmAPIName.fileStationList: ApiCapability(name: DsmAPIName.fileStationList, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: format, selectedVersion: 2)
                ]), session: session, transport: transport)
                clients.append((profile, files, transport, sid, token))
            }
            // 第二台登录完成后再读取第一台，覆盖会话串用回归。
            for (profile, files, transport, sid, token) in clients.reversed() {
                _ = try await files.listShares(offset: 0, limit: 1)
                let requests = await transport.recordedRequests()
                XCTAssertEqual(requests.count, 2)
                let loginFields = try decodeForm(requests[0].httpBody)
                XCTAssertEqual(loginFields["enable_syno_token"], "yes")
                let request = requests[1]
                let fields = try decodeForm(request.httpBody)
                XCTAssertEqual(request.url?.host, profile.host)
                XCTAssertEqual(request.url?.port, profile.port)
                XCTAssertNil(request.url?.query)
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(fields["_sid"], sid)
                XCTAssertEqual(fields["SynoToken"], token)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=\(sid)")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-SYNO-TOKEN"), token)
            }
        }
    }

    func test登录解析会话且请求使用POST正文() async throws {
        let response = DsmHTTPResponse(
            data: Data(
                #"{"success":true,"data":{"sid":"<REDACTED_SESSION>","synotoken":"<REDACTED_SESSION>","did":"<REDACTED_DEVICE>","is_portal_port":false}}"#.utf8
            ),
            statusCode: 200
        )
        let transport = MockHTTPTransport(responses: [response])
        let service = DsmAuthenticationService(
            client: DsmAPIClient(
                baseURL: try XCTUnwrap(URL(string: "https://nas.example.invalid:5001")),
                transport: transport
            )
        )

        let session = try await service.login(
            capability: authenticationCapability,
            account: "<REDACTED_CREDENTIAL>",
            password: "<REDACTED_CREDENTIAL>",
            otpCode: nil
        )

        XCTAssertEqual(session.sid, "<REDACTED_SESSION>")
        XCTAssertEqual(session.did, "<REDACTED_DEVICE>")
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.url?.query)
        let fields = try decodeForm(request.httpBody)
        XCTAssertEqual(fields["format"], "sid")
    }

    func test需要OTP时映射统一错误() async throws {
        let response = DsmHTTPResponse(
            data: Data(#"{"success":false,"error":{"code":403}}"#.utf8),
            statusCode: 200
        )
        let transport = MockHTTPTransport(responses: [response])
        let service = DsmAuthenticationService(
            client: DsmAPIClient(
                baseURL: try XCTUnwrap(URL(string: "https://nas.example.invalid:5001")),
                transport: transport
            )
        )

        do {
            _ = try await service.login(
                capability: authenticationCapability,
                account: "<REDACTED_CREDENTIAL>",
                password: "<REDACTED_CREDENTIAL>",
                otpCode: nil
            )
            XCTFail("预期登录进入 OTP 流程")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .otpRequired)
            XCTAssertEqual(error.dsmCode, 403)
        }
    }

    private var authenticationCapability: ApiCapability {
        ApiCapability(
            name: DsmAPIName.authentication,
            path: "entry.cgi",
            minVersion: 3,
            maxVersion: 7,
            requestFormat: .form,
            selectedVersion: 6
        )
    }

    private func decodeForm(_ data: Data?) throws -> [String: String] {
        let body = try XCTUnwrap(data.flatMap { String(data: $0, encoding: .utf8) })
        var components = URLComponents()
        components.percentEncodedQuery = body
        return Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
    }
}

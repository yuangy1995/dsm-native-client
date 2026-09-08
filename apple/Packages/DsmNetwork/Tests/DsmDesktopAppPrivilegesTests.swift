import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class DsmDesktopAppPrivilegesTests: XCTestCase {
    private let session = AuthSession(sid: "synthetic-session", synoToken: "synthetic-token", did: nil, isPortalPort: false)
    private var capabilities: CapabilitySet {
        CapabilitySet([DsmAPIName.desktopInitData: ApiCapability(name: DsmAPIName.desktopInitData, path: "entry.cgi",
            minVersion: 1, maxVersion: 1, requestFormat: .json, selectedVersion: 1)])
    }

    func test只发送一条已观察的GET且认证不进入URL() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"AppPrivilege":{"SYNO.SDS.App.FileStation3.Instance":true},"Session":{"is_admin":false,"user":"ignored-private-user"},"UserSettings":{"secret":"ignored"}}"#)])
        let result = try await service(transport).read(capabilities: capabilities, session: session)
        XCTAssertEqual(result.applications, [.files: true])
        XCTAssertFalse(result.isAdministrator)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.url?.path, "/webapi/entry.cgi")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fields, ["api": DsmAPIName.desktopInitData, "method": "get_user_service", "version": "1", "launch_app": "null"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=synthetic-session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SYNO-TOKEN"), "synthetic-token")
        XCTAssertFalse(try XCTUnwrap(request.url).absoluteString.contains("synthetic-session"))
        XCTAssertFalse(try XCTUnwrap(request.url).absoluteString.contains("synthetic-token"))
    }

    func test未知第三方应用完全忽略且不会保留私密字段() throws {
        let payload = #"{"AppPrivilege":{"SYNO.SDS.Chat.Application":true,"SYNO.SDS.DownloadStation.Application":false,"thirdparty.application":{"private":"ignored"}},"Session":{"is_admin":true,"sid":"private-session"},"UserSettings":{"secret":"private"}}"#
        let result = try JSONDecoder().decode(DsmDesktopAppPrivileges.self, from: Data(payload.utf8))
        XCTAssertEqual(result.applications, [.chat: true, .downloads: false])
        XCTAssertTrue(result.isAdministrator)
        XCTAssertEqual(Mirror(reflecting: result).children.compactMap(\.label).sorted(), ["applications", "isAdministrator"])
    }

    func test完整空权限表有效但整表缺失或已知授权类型错误拒绝() throws {
        let empty = try JSONDecoder().decode(DsmDesktopAppPrivileges.self, from: Data(#"{"AppPrivilege":{}}"#.utf8))
        XCTAssertTrue(empty.applications.isEmpty)
        XCTAssertFalse(empty.isAdministrator)
        for payload in [#"{"Session":{"is_admin":true}}"#,
                        #"{"AppPrivilege":null}"#,
                        #"{"AppPrivilege":{"SYNO.SDS.Chat.Application":"true"}}"#,
                        #"{"AppPrivilege":{},"Session":{"is_admin":"true"}}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(DsmDesktopAppPrivileges.self, from: Data(payload.utf8)))
        }
    }

    func test能力缺失零请求且不猜测路径或版本() async throws {
        let transport = MockHTTPTransport(responses: [])
        do {
            _ = try await service(transport).read(capabilities: CapabilitySet([:]), session: session)
            XCTFail("缺少能力时必须停止")
        } catch let error as AppError { XCTAssertEqual(error.category, .apiUnavailable) }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test119保留原值不重试不改写权限() async throws {
        let transport = MockHTTPTransport(responses: [DsmHTTPResponse(data: Data(#"{"success":false,"error":{"code":119}}"#.utf8), statusCode: 200)])
        do {
            _ = try await service(transport).read(capabilities: capabilities, session: session)
            XCTFail("失败不能伪造空权限表")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .authenticationRequired)
            XCTAssertEqual(error.dsmCode, 119)
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func test权限能力包含在发现中并固定协商V1() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"SYNO.Core.Desktop.Initdata":{"path":"entry.cgi","minVersion":1,"maxVersion":3,"requestFormat":"JSON"}}"#)])
        let client = DsmAPIClient(baseURL: URL(string: "https://example.invalid:5001")!, transport: transport)
        let result = try await DsmCapabilityDiscovery(client: client).discover()
        XCTAssertEqual(result[DsmAPIName.desktopInitData]?.selectedVersion, 1)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(String(decoding: try XCTUnwrap(requests.first?.httpBody), as: UTF8.self).contains("SYNO.Core.Desktop.Initdata"))
    }

    private func service(_ transport: MockHTTPTransport) -> DsmDesktopAppPrivilegesService {
        DsmDesktopAppPrivilegesService(client: DsmAPIClient(baseURL: URL(string: "https://example.invalid:5001")!, transport: transport))
    }
    private func response(_ data: String) -> DsmHTTPResponse {
        DsmHTTPResponse(data: Data("{\"success\":true,\"data\":\(data)}".utf8), statusCode: 200)
    }
}

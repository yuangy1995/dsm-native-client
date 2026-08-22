import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class DsmRequestTests: XCTestCase {
    func test表单编码特殊字符且凭据不进入URL() throws {
        let request = try DsmRequestBuilder.build(
            baseURL: try XCTUnwrap(URL(string: "https://nas.example.invalid:5001")),
            path: "entry.cgi",
            api: "SYNO.API.Auth",
            version: 6,
            method: "login",
            requestFormat: .form,
            parameters: ["account": .string("中文 #+&=\"😀")],
            credential: DsmSessionCredential(
                sid: "REDACTED_SESSION",
                synoToken: "REDACTED_TOKEN"
            )
        )

        XCTAssertNil(request.url?.query)
        let fields = try decodeForm(request.httpBody)
        XCTAssertEqual(fields["account"], "中文 #+&=\"😀")
        XCTAssertEqual(fields["_sid"], "REDACTED_SESSION")
        XCTAssertEqual(fields["SynoToken"], "REDACTED_TOKEN")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=REDACTED_SESSION")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SYNO-TOKEN"), "REDACTED_TOKEN")
    }

    func testJSON请求格式编码字符串和布尔值() throws {
        let request = try DsmRequestBuilder.build(
            baseURL: try XCTUnwrap(URL(string: "https://nas.example.invalid:5001")),
            path: "entry.cgi",
            api: "SYNO.Example",
            version: 1,
            method: "get",
            requestFormat: .json,
            parameters: [
                "path": .string("/测试目录"),
                "overwrite": .boolean(false)
            ]
        )

        let fields = try decodeForm(request.httpBody)
        let encodedPath = try XCTUnwrap(fields["path"]?.data(using: .utf8))
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: encodedPath), "/测试目录")
        XCTAssertEqual(fields["overwrite"], "false")
    }

    func testGET请求格式编码参数且凭据不进入URL() throws {
        let request = try DsmRequestBuilder.build(
            baseURL: try XCTUnwrap(URL(string: "https://nas.example.invalid:5001")),
            path: "entry.cgi",
            api: "SYNO.FileStation.Download",
            version: 2,
            method: "download",
            requestFormat: .form,
            parameters: [
                "path": .string("/video/movie.mp4"),
                "mode": .string("download")
            ],
            credential: DsmSessionCredential(
                sid: "REDACTED_SESSION",
                synoToken: "REDACTED_TOKEN"
            ),
            httpMethod: "GET"
        )

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        let queryDict = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(queryDict["api"], "SYNO.FileStation.Download")
        XCTAssertEqual(queryDict["version"], "2")
        XCTAssertEqual(queryDict["method"], "download")
        XCTAssertEqual(queryDict["path"], "/video/movie.mp4")
        XCTAssertEqual(queryDict["mode"], "download")
        XCTAssertNil(queryDict["_sid"])
        XCTAssertNil(queryDict["SynoToken"])
        XCTAssertFalse(request.url?.absoluteString.contains("REDACTED_SESSION") == true)
        XCTAssertFalse(request.url?.absoluteString.contains("REDACTED_TOKEN") == true)
        
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=REDACTED_SESSION")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SYNO-TOKEN"), "REDACTED_TOKEN")
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

import Foundation
import XCTest
@testable import DsmMacExecutable

final class MediaStreamRedirectPolicyTests: XCTestCase {
    func test同源HTTPS重定向保留原认证头并剥离查询凭据() throws {
        var source = URLRequest(
            url: try XCTUnwrap(URL(string: "https://nas.example.invalid:5001/start"))
        )
        source.setValue("id=synthetic-session", forHTTPHeaderField: "Cookie")
        source.setValue("synthetic-token", forHTTPHeaderField: "X-SYNO-TOKEN")
        var proposed = URLRequest(
            url: try XCTUnwrap(
                URL(string: "https://nas.example.invalid:5001/next?keep=1&_sid=synthetic-session&SynoToken=synthetic-token")
            )
        )
        proposed.setValue("wrong-value", forHTTPHeaderField: "Cookie")

        let result = MediaStreamRedirectPolicy.redirectedRequest(
            from: source,
            proposedRequest: proposed
        )
        let url = try XCTUnwrap(result?.url)
        let query = Dictionary(
            uniqueKeysWithValues: (
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            ).map { ($0.name, $0.value ?? "") }
        )

        XCTAssertEqual(query["keep"], "1")
        XCTAssertNil(query["_sid"])
        XCTAssertNil(query["SynoToken"])
        XCTAssertEqual(result?.value(forHTTPHeaderField: "Cookie"), "id=synthetic-session")
        XCTAssertEqual(result?.value(forHTTPHeaderField: "X-SYNO-TOKEN"), "synthetic-token")
    }

    func test不同主机端口或协议的重定向会被取消() throws {
        let source = URLRequest(
            url: try XCTUnwrap(URL(string: "https://nas.example.invalid:5001/start"))
        )
        for destination in [
            "https://other.example.invalid:5001/next",
            "https://nas.example.invalid:5002/next",
            "http://nas.example.invalid:5001/next",
        ] {
            XCTAssertNil(
                MediaStreamRedirectPolicy.redirectedRequest(
                    from: source,
                    proposedRequest: URLRequest(
                        url: try XCTUnwrap(URL(string: destination))
                    )
                )
            )
        }
    }
}

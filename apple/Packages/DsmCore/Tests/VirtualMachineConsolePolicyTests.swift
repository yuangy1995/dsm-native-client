import Foundation
import XCTest
@testable import DsmCore

final class VirtualMachineConsolePolicyTests: XCTestCase {
    private func policy(_ origin: String = "https://example.invalid:5001") throws -> VirtualMachineConsolePolicy {
        try .init(baseURL: XCTUnwrap(URL(string: origin)), machineID: "vm-1", name: "Synthetic", keyboardLayout: "en-us")
    }
    func test原VM单窗口及别名控制台相互绑定() throws {
        let value = try policy("https://example.invalid:5001/virtual")
        XCTAssertEqual(value.documentURL.path, "/virtual/webman/3rdparty/Virtualization/noVNC/vnc.html")
        XCTAssertEqual(value.socketURL.path, "/virtual/synovirtualization/ws/vm-1")
        XCTAssertTrue(value.socketURL.absoluteString.contains(value.id.uuidString.lowercased()))
        XCTAssertEqual(try value.remoteResource(for: value.localDocumentURL), value.documentURL)
        XCTAssertEqual(value.localDocumentURL.host, value.id.uuidString.lowercased() + ".invalid")
        XCTAssertFalse(value.localDocumentURL.absoluteString.contains("example.invalid"))
    }
    func test原生网络只接受固定目录与已记录图标() throws {
        let value = try policy()
        for path in ["app.js?v=2.6.5-12202", "app/locale/zh.json", "app/sounds/bell.oga", "core/rfb.js"] {
            let url = try XCTUnwrap(URL(string: path, relativeTo: value.documentURL)?.absoluteURL)
            XCTAssertNotNil(value.mediaType(for: url), path)
        }
        let icon = try XCTUnwrap(URL(string: "../images/VirtualManagement_32.png", relativeTo: value.documentURL)?.absoluteURL)
        XCTAssertEqual(value.mediaType(for: icon), "image/png")
        for path in ["/webapi/entry.cgi", "/webman/3rdparty/Virtualization/noVNC/vnc.html?x=1", "/webman/3rdparty/Virtualization/noVNC/app.js?api=delete", "/webman/3rdparty/Virtualization/noVNC/%2e%2e/private.js", "/webman/3rdparty/Virtualization/images/VirtualManagement_128.png"] {
            XCTAssertNil(value.mediaType(for: try XCTUnwrap(URL(string: "https://example.invalid:5001" + path))), path)
        }
    }
    func test跨源凭据片段与外部页面不能进入资源或导航() throws {
        let value = try policy()
        for text in ["https://other.invalid/app.js", "http://example.invalid:5001/app.js", "https://user@example.invalid:5001/app.js", "file:///tmp/app.js", "javascript:alert(1)"] {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertNil(value.mediaType(for: url)); XCTAssertFalse(value.allowsNavigation(url))
            XCTAssertThrowsError(try value.remoteResource(for: url))
        }
        XCTAssertFalse(value.allowsNavigation(try XCTUnwrap(URL(string: value.localDocumentURL.absoluteString + "#other"))))
    }
    func test画面地址不能换VM窗口别名或增加凭据() throws {
        let value = try policy(), other = try policy()
        var socket = URLComponents(url: value.socketURL, resolvingAgainstBaseURL: false)!
        socket.host = value.localDocumentURL.host; socket.port = nil
        XCTAssertTrue(value.allowsSocket(try XCTUnwrap(socket.url)))
        socket.queryItems?.append(.init(name: "_sid", value: "synthetic"))
        XCTAssertFalse(value.allowsSocket(try XCTUnwrap(socket.url)))
        socket.queryItems = [.init(name: "app_id", value: other.id.uuidString.lowercased())]
        XCTAssertFalse(value.allowsSocket(try XCTUnwrap(socket.url)))
        socket.queryItems = [.init(name: "app_id", value: value.id.uuidString.lowercased())]
        socket.path = "/synovirtualization/ws/other"
        XCTAssertFalse(value.allowsSocket(try XCTUnwrap(socket.url)))
    }
    func test非法目标键盘与不安全源不能准备() throws {
        for origin in ["http://example.invalid", "https://user@example.invalid", "https://example.invalid/?sid=synthetic", "https://example.invalid/a/b", "https://example.invalid/#x"] {
            XCTAssertThrowsError(try policy(origin))
        }
        for id in ["../vm", "a/b", "a%2fb", "", "a?sid=synthetic"] {
            XCTAssertThrowsError(try VirtualMachineConsolePolicy(baseURL: XCTUnwrap(URL(string: "https://example.invalid")), machineID: id, name: "Synthetic", keyboardLayout: "en-us"))
        }
        XCTAssertThrowsError(try VirtualMachineConsolePolicy(baseURL: XCTUnwrap(URL(string: "https://example.invalid")), machineID: "vm-1", name: "Synthetic", keyboardLayout: "Default"))
    }
}

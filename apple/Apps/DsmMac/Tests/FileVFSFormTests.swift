import DsmCore
import DsmLocalization
import XCTest
@testable import DsmFileFeature

final class FileVFSFormTests: XCTestCase {
    private let protocols: [FileVFSProtocol] = [
        .init(id: "dav", name: "WebDAV", defaultPort: 80, hasConnections: false),
        .init(id: "davs", name: "WebDAV HTTPS", defaultPort: 443, hasConnections: false),
        .init(id: "ftp", name: "FTP", defaultPort: 21, hasConnections: false),
        .init(id: "sftp", name: "SFTP", defaultPort: 22, hasConnections: false)
    ]
    private func draft(_ address: String) -> FileVFSConfiguration {
        .init(protocolID: "dav", hostname: address, port: 80, alias: "Sample", account: "sample")
    }
    func test地址预填不依赖其他尚未填写的字段() throws {
        var raw = draft("https://example.invalid/webdav"); raw.alias = ""
        let value = try FileVFSForm.resolveAddress(raw, protocols: protocols)
        XCTAssertEqual(value.hostname, "example.invalid"); XCTAssertEqual(value.folder, "webdav")
        XCTAssertEqual(value.protocolID, "davs"); XCTAssertEqual(value.port, 443)
        XCTAssertThrowsError(try FileVFSForm.configuration(value, protocols: protocols))
    }
    func test完整HTTPS地址识别加密端口和文件夹() throws {
        let value = try FileVFSForm.configuration(draft("https://example.invalid/webdav"), protocols: protocols)
        XCTAssertEqual(value.protocolID, "davs")
        XCTAssertEqual(value.hostname, "example.invalid")
        XCTAssertEqual(value.port, 443)
        XCTAssertEqual(value.folder, "webdav")
        XCTAssertFalse(FileVFSForm.usesCleartext(value))
    }
    func test完整地址显式端口优先并解码文件夹() throws {
        let value = try FileVFSForm.configuration(draft("https://example.invalid:5006/Photo%20Archive/"), protocols: protocols)
        XCTAssertEqual(value.port, 5006)
        XCTAssertEqual(value.folder, "Photo Archive")
    }
    func test主机名输入保留自定义端口和单独文件夹() throws {
        var raw = draft(" example.invalid "); raw.port = 5005; raw.folder = "archive"
        let value = try FileVFSForm.configuration(raw, protocols: protocols)
        XCTAssertEqual(value.hostname, "example.invalid")
        XCTAssertEqual(value.protocolID, "dav")
        XCTAssertEqual(value.port, 5005)
        XCTAssertEqual(value.folder, "archive")
    }
    func test完整地址未写端口时保留手动非默认端口() throws {
        var raw = draft("https://example.invalid"); raw.port = 5006
        XCTAssertEqual(try FileVFSForm.configuration(raw, protocols: protocols).port, 5006)
    }
    func test明文提示跟随实际网址而不是下拉框() {
        XCTAssertFalse(FileVFSForm.usesCleartext(draft(" HTTPS://example.invalid/webdav ")))
        var raw = draft("http://example.invalid"); raw.protocolID = "davs"
        XCTAssertTrue(FileVFSForm.usesCleartext(raw))
        XCTAssertTrue(FileVFSForm.usesCleartext(draft("example.invalid")))
    }
    func test不接受网址中的账号密码参数或片段() {
        for address in ["https://user:sample@example.invalid/webdav", "https://example.invalid/?key=sample", "https://example.invalid/#folder"] {
            XCTAssertThrowsError(try FileVFSForm.configuration(draft(address), protocols: protocols)) { error in
                XCTAssertEqual((error as? FileVFSForm.ValidationError)?.resourceKey, "files.vfs.invalidAddress")
            }
        }
    }
    func test冲突的文件夹必须由用户修正() {
        var raw = draft("https://example.invalid/one"); raw.folder = "two"
        XCTAssertThrowsError(try FileVFSForm.configuration(raw, protocols: protocols)) { error in
            XCTAssertEqual((error as? FileVFSForm.ValidationError)?.resourceKey, "files.vfs.folderMismatch")
        }
    }
    func test同一文件夹可以同时来自网址和单独字段() throws {
        var raw = draft("https://example.invalid/one/"); raw.folder = "/one"
        XCTAssertEqual(try FileVFSForm.configuration(raw, protocols: protocols).folder, "one")
    }
    func test不悄悄修改已有连接类型或使用不支持的类型() {
        XCTAssertThrowsError(try FileVFSForm.configuration(draft("https://example.invalid"), protocols: protocols, editingProtocol: "dav"))
        XCTAssertThrowsError(try FileVFSForm.configuration(draft("ftp://example.invalid"), protocols: protocols))
        XCTAssertThrowsError(try FileVFSForm.configuration(draft("https://example.invalid"), protocols: [protocols[0]]))
    }
    func test输入错误有具体提示且修正后可再次校验() throws {
        var raw = draft("example.invalid"); raw.port = 0
        XCTAssertThrowsError(try FileVFSForm.configuration(raw, protocols: protocols)) { error in
            XCTAssertEqual((error as? FileVFSForm.ValidationError)?.resourceKey, "files.vfs.invalidPort")
        }
        raw.port = 80
        XCTAssertEqual(try FileVFSForm.configuration(raw, protocols: protocols).port, 80)
        raw.alias = " "
        XCTAssertThrowsError(try FileVFSForm.configuration(raw, protocols: protocols)) { error in
            XCTAssertEqual((error as? FileVFSForm.ValidationError)?.resourceKey, "files.vfs.invalidAlias")
        }
    }
    func testSFTP完整地址不改变连接语义() throws {
        var raw = draft("sftp://example.invalid:2222"); raw.protocolID = "sftp"; raw.port = 22
        let value = try FileVFSForm.configuration(raw, protocols: protocols)
        XCTAssertEqual(value.protocolID, "sftp"); XCTAssertEqual(value.port, 2222)
        XCTAssertFalse(FileVFSForm.usesCleartext(value))
    }
}

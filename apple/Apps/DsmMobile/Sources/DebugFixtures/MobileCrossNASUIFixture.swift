#if DEBUG
import CryptoKit
import DsmCore
import DsmNetwork
import Foundation

/// 两台内存 NAS 使用不同 Repository 和传输实例；所有请求均留在测试进程内。
actor MobileCrossNASUITransport: DsmBinaryHTTPTransport {
    private var items: [String: Bool]
    private var contents: [String: Data]
    private var lostReceipt: Bool
    private let readOnly: Bool
    private var md5Path = ""
    private let expectedSID: String?

    init(target: Bool, state: String, expectedSID: String? = nil) {
        self.expectedSID = expectedSID
        items = target ? ["/output": true] : ["/fixture": true, "/fixture/Inbox": true,
            "/fixture/Inbox/Empty": true, "/fixture/Inbox/Nested.txt": false, "/fixture/Sample document.txt": false]
        contents = target ? [:] : ["/fixture/Inbox/Nested.txt": Data("0123456789".utf8),
            "/fixture/Sample document.txt": Data("0123456789".utf8)]
        lostReceipt = target && state == "cross-unknown"
        readOnly = target && state == "cross-readonly"
        if target && state == "cross-conflict" {
            items["/output/Sample document.txt"] = false
            contents["/output/Sample document.txt"] = Data("keep original".utf8)
        }
    }

    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        throw URLError(.unsupportedURL)
    }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        throw URLError(.unsupportedURL)
    }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        if let expectedSID, request.value(forHTTPHeaderField: "Cookie") != "id=" + expectedSID {
            throw URLError(.userAuthenticationRequired)
        }
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []
        func field(_ name: String) -> String { fields.first { $0.name == name }?.value ?? "" }
        let api = field("api"), method = field("method")
        func row(_ path: String) -> [String: Any] {
            ["name": path == "/fixture" && method == "list_share" ? "Sample folder" : (path as NSString).lastPathComponent,
             "path": path, "isdir": items[path] ?? false, "additional": ["size": contents[path]?.count ?? 0,
                "perm": ["adv_right": ["read": true, "write": !readOnly, "delete": true]], "time": ["mtime": 1000]]]
        }
        let result: [String: Any]
        switch (api, method) {
        case (DsmAPIName.fileStationList, "list_share"):
            let shares = items.keys.filter { ($0 as NSString).deletingLastPathComponent == "/" }.sorted()
            result = ["shares": shares.map(row), "offset": 0, "total": shares.count]
        case (DsmAPIName.fileStationList, "list"):
            let children = items.keys.filter { ($0 as NSString).deletingLastPathComponent == field("folder_path") }.sorted()
            let offset = Int(field("offset")) ?? 0, limit = Int(field("limit")) ?? 200
            result = ["files": children.dropFirst(offset).prefix(limit).map(row), "offset": offset, "total": children.count]
        case (DsmAPIName.fileStationList, "getinfo"):
            let paths = try JSONDecoder().decode([String].self, from: Data(field("path").utf8))
            result = ["files": paths.filter { items[$0] != nil }.map(row)]
        case (DsmAPIName.fileStationMD5, "start"):
            md5Path = field("file_path"); result = ["taskid": "fixture-md5"]
        case (DsmAPIName.fileStationMD5, "status"):
            guard let data = contents[md5Path] else { throw URLError(.fileDoesNotExist) }
            result = ["finished": true, "md5": Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        case (DsmAPIName.fileStationDownload, "download"):
            let paths = try JSONDecoder().decode([String].self, from: Data(field("path").utf8))
            guard let path = paths.first, let data = contents[path] else { throw URLError(.fileDoesNotExist) }
            return .init(data: data, statusCode: 206, headers: ["Content-Type": "application/octet-stream",
                "Content-Length": String(data.count), "Content-Range": "bytes 0-\(data.count - 1)/\(data.count)", "ETag": "\"fixture-v1\""])
        case (DsmAPIName.fileStationUpload, "upload"):
            guard !readOnly, let stream = request.httpBodyStream else { throw URLError(.noPermissionsToReadFile) }
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.networkConnectionLost) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            guard let multipart = String(data: data, encoding: .utf8),
                  let pathStart = multipart.range(of: "name=\"path\"\r\n\r\n"),
                  let pathEnd = multipart.range(of: "\r\n", range: pathStart.upperBound..<multipart.endIndex),
                  let nameStart = multipart.range(of: "filename=\""),
                  let nameEnd = multipart.range(of: "\"", range: nameStart.upperBound..<multipart.endIndex),
                  let contentStart = multipart.range(of: "\r\n\r\n", range: nameEnd.upperBound..<multipart.endIndex),
                  let contentEnd = multipart.range(of: "\r\n--", range: contentStart.upperBound..<multipart.endIndex),
                  multipart.contains("name=\"overwrite\"\r\n\r\nfalse") else { throw URLError(.cannotParseResponse) }
            let path = String(multipart[pathStart.upperBound..<pathEnd.lowerBound]) + "/" + String(multipart[nameStart.upperBound..<nameEnd.lowerBound])
            guard items[path] == nil else { throw URLError(.cannotCreateFile) }
            items[path] = false; contents[path] = Data(multipart[contentStart.upperBound..<contentEnd.lowerBound].utf8)
            if lostReceipt { lostReceipt = false; throw URLError(.networkConnectionLost) }
            result = [:]
        case (DsmAPIName.fileStationCreateFolder, "create"):
            let path = field("folder_path") + "/" + field("name")
            guard !readOnly, items[path] == nil else { throw URLError(.cannotCreateFile) }
            items[path] = true; result = [:]
        case (DsmAPIName.fileStationCheckPermission, "write"):
            guard !readOnly else { throw URLError(.noPermissionsToReadFile) }; result = [:]
        case (DsmAPIName.fileStationDelete, "start"):
            let paths = try JSONDecoder().decode([String].self, from: Data(field("path").utf8))
            guard field("recursive") == "false", !items.keys.contains(where: { path in paths.contains { path.hasPrefix($0 + "/") } }) else {
                throw URLError(.noPermissionsToReadFile)
            }
            for path in paths { items[path] = nil; contents[path] = nil }
            result = ["taskid": "fixture-delete"]
        case (DsmAPIName.fileStationDelete, "status"): result = ["finished": true]
        case (DsmAPIName.fileStationBackgroundTask, "list"): result = ["tasks": [], "offset": 0, "total": 0]
        case (DsmAPIName.fileStationInfo, "get"): result = ["hostname": "Sample", "is_manager": true, "support_sharing": true]
        default: throw URLError(.unsupportedURL)
        }
        return .init(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": result]), statusCode: 200)
    }
}
#endif

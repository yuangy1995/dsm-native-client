#if DEBUG
import CryptoKit
import DsmCore
import DsmNetwork
import Foundation

/// 完全合成的最小 Word 包与内存 NAS，用于实际 Repository、系统预览及 UI 流程。
actor MobileOfficeUITransport: DsmBinaryHTTPTransport, MobileSecureRangeReading {
    static let document = Data(base64Encoded: "UEsDBBQAAAAIAKJLRF33S4B1wgAAAHYBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbH2QuQ7CMAyGX6XKiqgRAwOiLMAKDLyAlbptRC7FLsfbk3INCBjt//gsLw7XSFxcnPVcqU4kzgFYd+SQyxDJZ6UJyaHkMbUQUR+xJZhOJjPQwQt5GcvQoZaLNTXYWyk2l7xmE3ylEllWxephHFiVwhit0ShZh5OvPyjjJ6HMybuHOxN5lA0KvhIG5TfgmdudKCVTU7HHJFt02QXnkGqog+5dTpb/a77cGZrGaHrnh7aYgiZm41tny7fi0PjX/XB/9/IGUEsDBBQAAAAIAKJLRF1hey9DiQAAAPIAAAALAAAAX3JlbHMvLnJlbHONzzsOAiEQBuCrEA6ws1pYGKCy2dZ4AQLDIy6PDBj19lJYrMbCcuaffH9GnHHVPZbcQqyNPdKam+Sh93oEaCZg0m0qFfNIXKGk+xjJQ9Xmqj3Cfp4PQFuDK7E12WIlp8XuOLs8K/5jF+eiwVMxt4S5/6j4uhiyJo9d8nshC/a9ngbLQQn4eFG9AFBLAwQUAAAACACiS0RdM5LbHH4AAACnAAAAEQAAAHdvcmQvZG9jdW1lbnQueG1sRc7BDcMgDAXQVVAGqKMeekApK3QGCiZBwmAZWtLtG9JDL+/L+vqSl659cS/C3NROKVfd79PWGmuA6jYkWy+FMR9dKEK2Haes0It4luKw1phXSnCd5xuQjXkyS9fP4j8jeSCDZh4hRIeKBd8Ru6qWOOECoxrKKZ/+5vB/zXwBUEsBAhQDFAAAAAgAoktEXfdLgHXCAAAAdgEAABMAAAAAAAAAAAAAAIABAAAAAFtDb250ZW50X1R5cGVzXS54bWxQSwECFAMUAAAACACiS0RdYXsvQ4kAAADyAAAACwAAAAAAAAAAAAAAgAHzAAAAX3JlbHMvLnJlbHNQSwECFAMUAAAACACiS0RdM5LbHH4AAACnAAAAEQAAAAAAAAAAAAAAgAGlAQAAd29yZC9kb2N1bWVudC54bWxQSwUGAAAAAAMAAwC5AAAAUgIAAAAA")!
    private var content = document
    private let state: String
    private var revision = 1000
    private var failReadOnce = false
    init(state: String) { self.state = state }
    func activateScenario() { if state == "office-conflict" { content.append(Data("remote edit".utf8)) } }
    func read(source: MediaStreamSource, offset: Int64, maximumLength: Int, ifMatch: String?, requiresStrongETag: Bool) async throws -> MobileSecureRangePayload {
        let bytes = Data(content.dropFirst(Int(offset)).prefix(maximumLength))
        return .init(data: bytes, contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                     totalLength: Int64(content.count), strongETag: "\"office-v1\"")
    }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        try content.write(to: destinationURL); progress(Int64(content.count), Int64(content.count))
        return .init(data: Data(), statusCode: 200, headers: ["Content-Type": "application/octet-stream", "Content-Length": String(content.count)])
    }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        guard state != "office-readonly" else { throw URLError(.noPermissionsToReadFile) }
        let body = try Data(contentsOf: bodyFileURL)
        let header = Data("filename=\"Document.docx\"".utf8)
        guard let name = body.range(of: header), let start = body.range(of: Data("\r\n\r\n".utf8), in: name.upperBound..<body.endIndex),
              let end = body.range(of: Data("\r\n--".utf8), in: start.upperBound..<body.endIndex),
              body.range(of: Data("name=\"overwrite\"\r\n\r\ntrue".utf8)) != nil,
              body.range(of: Data("name=\"path\"\r\n\r\n/fixture".utf8)) != nil else { throw URLError(.cannotParseResponse) }
        content = body.subdata(in: start.upperBound..<end.lowerBound); revision += 1
        if state == "office-unknown" { failReadOnce = true; throw URLError(.networkConnectionLost) }
        return try response([:])
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []
        func field(_ key: String) -> String { fields.first { $0.name == key }?.value ?? "" }
        let api = field("api"), method = field("method")
        func row(_ directory: Bool) -> [String: Any] {
            ["name": directory ? "Sample folder" : "Document.docx", "path": directory ? "/fixture" : "/fixture/Document.docx",
             "isdir": directory, "additional": ["size": directory ? 0 : content.count, "time": ["mtime": revision],
               "perm": ["adv_right": ["read": true, "write": state != "office-readonly", "delete": true]]]]
        }
        let value: [String: Any]
        switch (api, method) {
        case (DsmAPIName.fileStationList, "list_share"): value = ["shares": [row(true)], "offset": 0, "total": 1]
        case (DsmAPIName.fileStationList, "list"): value = ["files": [row(false)], "offset": 0, "total": 1]
        case (DsmAPIName.fileStationList, "getinfo"):
            if failReadOnce { failReadOnce = false; throw URLError(.networkConnectionLost) }
            let paths = try JSONDecoder().decode([String].self, from: Data(field("path").utf8))
            value = ["files": paths.compactMap { path -> [String: Any]? in
                if path == "/fixture" { return row(true) }
                return path == "/fixture/Document.docx" ? row(false) : nil
            }]
        case (DsmAPIName.fileStationMD5, "start"): value = ["taskid": "office-md5"]
        case (DsmAPIName.fileStationMD5, "status"):
            value = ["finished": true, "md5": Insecure.MD5.hash(data: content).map { String(format: "%02x", $0) }.joined()]
        case (DsmAPIName.fileStationCheckPermission, "write"):
            guard state != "office-readonly" else { throw URLError(.noPermissionsToReadFile) }; value = [:]
        case (DsmAPIName.fileStationInfo, "get"): value = ["hostname": "Sample", "is_manager": true]
        case (DsmAPIName.fileStationBackgroundTask, "list"): value = ["tasks": [], "offset": 0, "total": 0]
        default: throw URLError(.unsupportedURL)
        }
        return try response(value)
    }
    private func response(_ value: [String: Any]) throws -> DsmHTTPResponse {
        .init(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": value]), statusCode: 200)
    }
}
#endif

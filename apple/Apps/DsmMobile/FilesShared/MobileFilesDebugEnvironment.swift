#if DEBUG
import CryptoKit
import Darwin
import DsmCore
import DsmNetwork
import Foundation

/// 正式构建不包含该入口；只读取有时限、独立编号且使用保留域名的合成环境。
struct MobileFilesDebugEnvironment: Codable, Sendable {
    let id: UUID
    let mode: String
    let createdAt: Date

    static func active() -> Self? {
        guard let base = try? MobileExtensionStorage.rootURL(),
              let data = try? Data(contentsOf: base.appendingPathComponent("ui-files-fixture.json")),
              let fixture = try? JSONDecoder().decode(Self.self, from: data),
              (0..<3_600).contains(Date().timeIntervalSince(fixture.createdAt)) else { return nil }
        return fixture
    }

    func rootURL() throws -> URL {
        try MobileExtensionStorage.rootURL().appendingPathComponent("UITestFiles", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    var locations: MobileFilesLocationStore { get throws { try .init(rootURL: rootURL().appendingPathComponent("Locations")) } }
    var accounts: MobileExtensionAccountStore { get throws { try .init(rootURL: rootURL()) } }

    static var capabilities: CapabilitySet {
        let names = [DsmAPIName.fileStationList, DsmAPIName.fileStationDownload, DsmAPIName.fileStationUpload,
            DsmAPIName.fileStationCheckPermission, DsmAPIName.fileStationCreateFolder, DsmAPIName.fileStationRename,
            DsmAPIName.fileStationCopyMove, DsmAPIName.fileStationDelete, DsmAPIName.fileStationMD5]
        return CapabilitySet(Dictionary(uniqueKeysWithValues: names.map {
            ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .form, selectedVersion: 2))
        }))
    }
}

/// 同一合成 NAS 的状态通过文件锁跨进程共享，供真实系统 Files 扩展测试读取。
actor MobileFilesSyntheticTransport: DsmBinaryHTTPTransport {
    struct Node: Codable, Equatable {
        var path: String
        var content: Data?
        var modified: Int = 1_800_000_000
        var directory: Bool { content == nil }
    }
    struct State: Codable {
        var nodes: [Node] = [.init(path: "/Shared", content: nil), .init(path: "/Shared/Sample.txt", content: Data("Initial sample\n".utf8))]
        var downloads = 0
        var uploads = 0
        var deletions = 0
        var creations = 0
        var renames = 0
        var reads = 0
        var hashTasks: [String: String] = [:]
    }
    let root: URL
    let mode: String
    init(root: URL, mode: String = "success") { self.root = root; self.mode = mode }

    func snapshot() throws -> State { try transaction { $0 } }
    func changeRemoteFile(_ path: String, content: Data) throws {
        try transaction { state in
            guard let index = state.nodes.firstIndex(where: { $0.path == path }) else { throw CocoaError(.fileNoSuchFile) }
            state.nodes[index].content = content; state.nodes[index].modified += 10
        }
    }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        guard request.url?.host == "files-ui.invalid" else { throw URLError(.unsupportedURL) }
        let fields = parameters(request)
        if mode == "read-error" { throw URLError(.notConnectedToInternet) }
        return try transaction { state in
            state.reads += 1
            let method = fields["method"], api = fields["api"]
            if api == DsmAPIName.fileStationMD5 {
                if method == "start" {
                    let task = UUID().uuidString
                    guard let content = state.nodes.first(where: { $0.path == fields["file_path"] })?.content else { throw CocoaError(.fileNoSuchFile) }
                    state.hashTasks[task] = Insecure.MD5.hash(data: content).map { String(format: "%02x", $0) }.joined()
                    return try response(["taskid": task])
                }
                if method == "status", let hash = state.hashTasks[fields["taskid"] ?? ""] { return try response(["finished": true, "md5": hash]) }
            }
            if api == DsmAPIName.fileStationDelete {
                if method == "start" {
                    let paths = try paths(fields["path"])
                    state.nodes.removeAll { node in paths.contains { node.path == $0 || node.path.hasPrefix($0 + "/") } }
                    state.deletions += 1
                    return try response(["taskid": "synthetic-delete"])
                }
                if method == "status" { return try response(["finished": true, "progress": 1.0, "processed_size": 1, "total": 1]) }
            }
            if api == DsmAPIName.fileStationCreateFolder, method == "create" {
                let path = (fields["folder_path"] ?? "") + "/" + (fields["name"] ?? "")
                guard !state.nodes.contains(where: { $0.path == path }) else { throw CocoaError(.fileWriteFileExists) }
                state.nodes.append(.init(path: path, content: nil)); state.creations += 1
                return try response([:])
            }
            if api == DsmAPIName.fileStationRename, method == "rename" {
                let source = try paths(fields["path"]).first ?? ""
                let name = try paths(fields["name"]).first ?? ""
                guard !source.isEmpty, !name.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                let destination = (source as NSString).deletingLastPathComponent + "/" + name
                for index in state.nodes.indices where state.nodes[index].path == source || state.nodes[index].path.hasPrefix(source + "/") {
                    state.nodes[index].path = destination + state.nodes[index].path.dropFirst(source.count)
                }
                state.renames += 1
                return try response([:])
            }
            if method == "write" { return try response([:]) }
            if method == "list_share" { return try page(state.nodes.filter { $0.path.split(separator: "/").count == 1 }, fields, shares: true) }
            if method == "getinfo" {
                let selected = try paths(fields["path"])
                return try response(["files": state.nodes.filter { selected.contains($0.path) }.map(item)])
            }
            if method == "list" {
                return try page(state.nodes.filter { ($0.path as NSString).deletingLastPathComponent == fields["folder_path"] }, fields)
            }
            throw URLError(.unsupportedURL)
        }
    }

    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        guard request.url?.host == "files-ui.invalid" else { throw URLError(.unsupportedURL) }
        let path = try paths(parameters(request)["path"]).first
        let content: Data = try transaction { state in
            guard let content = state.nodes.first(where: { $0.path == path })?.content else { throw CocoaError(.fileNoSuchFile) }
            state.downloads += 1
            return content
        }
        if mode == "slow" { try await Task.sleep(for: .seconds(3)) }
        try content.write(to: destinationURL, options: [.atomic, .completeFileProtection])
        progress(Int64(content.count), Int64(content.count))
        return .init(data: Data(), statusCode: 200, headers: ["content-type": "text/plain", "content-length": String(content.count)])
    }

    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        guard request.url?.host == "files-ui.invalid" else { throw URLError(.unsupportedURL) }
        let body = try String(contentsOf: bodyFileURL, encoding: .utf8)
        guard let filenameStart = body.range(of: "filename=\"")?.upperBound,
              let filenameEnd = body[filenameStart...].firstIndex(of: "\""),
              let folderStart = body.range(of: "name=\"path\"\r\n\r\n")?.upperBound,
              let folderEnd = body[folderStart...].range(of: "\r\n")?.lowerBound,
              let contentStart = body[filenameEnd...].range(of: "\r\n\r\n")?.upperBound,
              let contentEnd = body.range(of: "\r\n--", options: .backwards)?.lowerBound else { throw CocoaError(.fileReadCorruptFile) }
        let path = String(body[folderStart..<folderEnd]) + "/" + String(body[filenameStart..<filenameEnd])
        let content = Data(body[contentStart..<contentEnd].utf8)
        try transaction { state in
            let modified = (state.nodes.first { $0.path == path }?.modified ?? 1_800_000_000) + 1
            state.nodes.removeAll { $0.path == path }
            state.nodes.append(.init(path: path, content: content, modified: modified)); state.uploads += 1
        }
        progress(Int64(content.count), Int64(content.count))
        if mode == "unknown" { throw URLError(.timedOut) }
        return try response([:])
    }

    private func parameters(_ request: URLRequest) -> [String: String] {
        let raw = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            + (URLComponents(string: "?" + raw.replacingOccurrences(of: "+", with: "%20"))?.queryItems ?? [])
        return Dictionary(fields.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
    }
    private func paths(_ raw: String?) throws -> [String] {
        guard let raw else { return [] }
        if raw.hasPrefix("[") { return try JSONDecoder().decode([String].self, from: Data(raw.utf8)) }
        return [raw]
    }
    private func page(_ nodes: [Node], _ fields: [String: String], shares: Bool = false) throws -> DsmHTTPResponse {
        let offset = Int(fields["offset"] ?? "") ?? 0, limit = Int(fields["limit"] ?? "") ?? 500
        let items = nodes.sorted { $0.path < $1.path }.dropFirst(max(0, offset)).prefix(max(0, limit)).map(item)
        return try response(["offset": offset, "total": nodes.count, shares ? "shares" : "files": items])
    }
    private func item(_ node: Node) -> [String: Any] {
        ["name": (node.path as NSString).lastPathComponent, "path": node.path, "isdir": node.directory,
         "additional": ["size": node.content?.count ?? 0, "time": ["mtime": node.modified],
            "perm": ["adv_right": ["read": true, "write": true, "delete": true]]]]
    }
    private func response(_ data: [String: Any]) throws -> DsmHTTPResponse {
        .init(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
    private func transaction<Value>(_ body: (inout State) throws -> Value) throws -> Value {
        try MobileExtensionStorage.prepareDirectory(root)
        let descriptor = open(root.appendingPathComponent("synthetic.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        let url = root.appendingPathComponent("synthetic-server.json")
        var state = FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) : State()
        let result = try body(&state)
        try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtection])
        return result
    }
}
#endif

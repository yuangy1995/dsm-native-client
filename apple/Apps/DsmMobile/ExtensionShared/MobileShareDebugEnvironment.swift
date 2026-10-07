#if DEBUG
import DsmCore
import DsmNetwork
import Foundation
import SwiftUI

/// 只在显式 UI 测试写入标记后启用；独立目录与 .invalid 身份不接触真实连接。
struct MobileShareDebugEnvironment: Codable, Sendable {
    let id: UUID
    let mode: String
    let createdAt: Date
    var usesLargestDarkText = false

    static func active() -> Self? {
        guard let base = try? MobileExtensionStorage.rootURL(),
              let data = try? Data(contentsOf: base.appendingPathComponent("ui-share-fixture.json")),
              let fixture = try? JSONDecoder().decode(Self.self, from: data),
              Date().timeIntervalSince(fixture.createdAt) < 3_600 else { return nil }
        return fixture
    }

    func rootURL() throws -> URL {
        try MobileExtensionStorage.rootURL().appendingPathComponent("UITestShares", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static var capabilities: CapabilitySet {
        let names = [DsmAPIName.fileStationList, DsmAPIName.fileStationUpload, DsmAPIName.fileStationCheckPermission,
                     DsmAPIName.fileStationCreateFolder, DsmAPIName.fileStationMD5]
        return CapabilitySet(Dictionary(uniqueKeysWithValues: names.map {
            ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .form, selectedVersion: 2))
        }))
    }

    func repository(account: MobileExtensionAccount, accounts: MobileExtensionAccountStore,
                    sessions: any SessionSecureStoring) async throws -> DsmFileRepository {
        guard account.profile.id == id, account.profile.host == "share-ui.invalid" else { throw CocoaError(.fileReadNoPermission) }
        try accounts.requireCurrent(account)
        guard let session = try await sessions.load(for: account.id) else { throw MobileExtensionAccountError.signedOut }
        let network = MobileShareSyntheticTransport(root: try rootURL(), mode: mode)
        return try DsmFileRepository(profile: account.connection.profile, capabilities: Self.capabilities, session: session,
            transport: MobileExtensionTransport(account: account, accounts: accounts, sessions: sessions, transport: network))
    }
}

struct MobileShareDebugAppearance: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.dynamicTypeSize(.accessibility5).preferredColorScheme(.dark) }
        else { content }
    }
}

actor MobileShareSyntheticTransport: DsmBinaryHTTPTransport {
    struct State: Codable {
        var files: Set<String> = []
        var uploads = 0
    }
    let root: URL
    let mode: String
    init(root: URL, mode: String = "success") { self.root = root; self.mode = mode }
    private var stateURL: URL { root.appendingPathComponent("synthetic-server.json") }

    func snapshot() throws -> State {
        if FileManager.default.fileExists(atPath: stateURL.path) { return try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL)) }
        return State(files: mode == "conflict" ? ["/Shared/Sample.txt"] : [])
    }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let raw = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = URLComponents(string: "?" + raw.replacingOccurrences(of: "+", with: "%20"))?.queryItems ?? []
        let parameters = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
        let method = parameters["method"]
        if mode == "folder-error", ["list_share", "list"].contains(method) { throw URLError(.notConnectedToInternet) }
        if parameters["api"] == DsmAPIName.fileStationMD5 {
            if method == "start" { return try response(["taskid": "synthetic-md5"]) }
            if method == "status" { return try response(["finished": true, "md5": "d41d8cd98f00b204e9800998ecf8427e"]) }
        }
        if method == "write" { return try response([:]) }
        if method == "list_share" {
            return try response(["offset": 0, "total": 1, "shares": [item("/Shared", directory: true)]])
        }
        if method == "getinfo" {
            let paths = try JSONDecoder().decode([String].self, from: Data((parameters["path"] ?? "[]").utf8))
            let state = try snapshot()
            return try response(["files": paths.compactMap { path -> [String: Any]? in
                if path == "/Shared" || path == "/Shared/Subfolder" { return item(path, directory: true) }
                return state.files.contains(path) ? item(path, directory: false) : nil
            }])
        }
        if method == "list" {
            let path = parameters["folder_path"] ?? ""
            let children = try snapshot().files.filter { ($0 as NSString).deletingLastPathComponent == path }.sorted()
            var files = children.map { item($0, directory: false) }
            if path == "/Shared" { files.insert(item("/Shared/Subfolder", directory: true), at: 0) }
            return try response(["offset": 0, "total": files.count, "files": files])
        }
        throw URLError(.unsupportedURL)
    }

    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        var state = try snapshot(); state.uploads += 1; try save(state)
        for step in 0..<(mode == "slow" ? 60 : 2) {
            try await Task.sleep(for: .milliseconds(250))
            progress(Int64(step), mode == "slow" ? 60 : 2)
        }
        let body = try String(contentsOf: bodyFileURL, encoding: .utf8)
        guard let fileStart = body.range(of: "filename=\"")?.upperBound,
              let fileEnd = body[fileStart...].firstIndex(of: "\""),
              let pathStart = body.range(of: "name=\"path\"\r\n\r\n")?.upperBound,
              let pathEnd = body[pathStart...].range(of: "\r\n")?.lowerBound else { throw URLError(.badServerResponse) }
        state = try snapshot()
        state.files.insert(String(body[pathStart..<pathEnd]) + "/" + String(body[fileStart..<fileEnd]))
        try save(state)
        if mode == "unknown" { throw URLError(.timedOut) }
        return try response([:])
    }

    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { throw URLError(.unsupportedURL) }
    private func save(_ state: State) throws {
        try MobileExtensionStorage.prepareDirectory(root)
        try JSONEncoder().encode(state).write(to: stateURL, options: [.atomic, .completeFileProtection])
    }
    private func item(_ path: String, directory: Bool) -> [String: Any] {
        ["name": (path as NSString).lastPathComponent, "path": path, "isdir": directory,
         "additional": ["size": 0, "perm": ["adv_right": ["write": true, "read": true]]]]
    }
    private func response(_ data: [String: Any]) throws -> DsmHTTPResponse {
        .init(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
}
#endif

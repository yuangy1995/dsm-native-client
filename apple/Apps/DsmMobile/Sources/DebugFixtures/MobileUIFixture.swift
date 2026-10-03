#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 仅 Debug 的显式 UI 测试入口；所有请求都由内存替身处理，不读取真实配置或访问网络。
@MainActor
enum MobileUIFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-fixture") }

    static func makeModel() -> MobileAppModel {
        do {
            let defaults = UserDefaults(suiteName: "LanStash.Mobile.UITests.Fixture")!
            defaults.removePersistentDomain(forName: "LanStash.Mobile.UITests.Fixture")
            let uploadFixture = ProcessInfo.processInfo.environment["LANSTASH_UI_STATE"] == "upload"
            let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("LanStashUITestTransfers")
            if uploadFixture && !ProcessInfo.processInfo.arguments.contains("--ui-preserve-transfer-fixture") {
                try? FileManager.default.removeItem(at: fixtureRoot)
            }
            let model = MobileAppModel(defaults: defaults, sessionStore: FixtureSessionStore(), passwordStore: FixturePasswordStore(),
                transferRecoveryStore: uploadFixture ? MobileTransferRecoveryStore(rootURL: fixtureRoot) : nil)
            let profile = try NasProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!,
                                         displayName: "Sample NAS", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
            let versions = [DsmAPIName.fileStationList: 2, DsmAPIName.fileStationInfo: 2, DsmAPIName.fileStationSearch: 2,
                            DsmAPIName.fileStationUpload: 3, DsmAPIName.fileStationCreateFolder: 2, DsmAPIName.fileStationCheckPermission: 3,
                            DsmAPIName.downloadStationTask: 3, DsmAPIName.downloadStationStatistic: 1,
                            DsmAPIName.coreSystem: 3, DsmAPIName.dockerContainer: 1, DsmAPIName.virtualizationAPIGuest: 1]
            let fixtureCapabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in
                (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version,
                                     requestFormat: .form, selectedVersion: version, verified: false))
            }))
            let session = AuthSession(sid: "ui-fixture-session", synoToken: nil, did: nil, isPortalPort: false)
            let transport = FixtureTransport()
            model.profiles = [profile]
            model.capabilities = fixtureCapabilities
            model.session = session
            model.fileRepository = try DsmFileRepository(profile: profile, capabilities: fixtureCapabilities, session: session, transport: transport)
            model.serviceRepository = try DsmServiceManagementRepository(profile: profile, capabilities: fixtureCapabilities, session: session, transport: transport)
            model.nasRepository = try DsmNasAdministrationRepository(profile: profile, capabilities: fixtureCapabilities, session: session, transport: transport)
            model.chatRepository = try DsmChatRepository(profile: profile, capabilities: fixtureCapabilities, session: session, transport: transport)
            model.activeProfile = profile
            model.activeConnectionProfile = profile
            model.isConnected = true
            return model
        } catch {
            preconditionFailure("UI fixture configuration failed")
        }
    }
    static func prepareUploadSelection(_ model: MobileAppModel) async {
        guard ProcessInfo.processInfo.environment["LANSTASH_UI_STATE"] == "upload",
              !ProcessInfo.processInfo.arguments.contains("--ui-preserve-transfer-fixture") else { return }
        while model.fileUploadQueue.isConfiguring {
            try? await Task.sleep(for: .milliseconds(20))
            if Task.isCancelled { return }
        }
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("LanStashUITestSelection")
            try? FileManager.default.removeItem(at: root)
            let folder = root.appendingPathComponent("Sample upload")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Empty folder"), withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("Sample upload.txt"))
            await model.fileUploadQueue.prepare([folder], destination: "/fixture")
        } catch { preconditionFailure("UI upload fixture could not be prepared") }
    }

}

private actor FixtureSessionStore: SessionSecureStoring {
    func save(_ session: AuthSession, for profileID: UUID) async throws {}
    func load(for profileID: UUID) async throws -> AuthSession? { nil }
    func remove(for profileID: UUID) async throws {}
}

private actor FixturePasswordStore: PasswordSecureStoring {
    func save(_ password: String, for profileID: UUID) async throws {}
    func load(for profileID: UUID) async throws -> String? { nil }
    func remove(for profileID: UUID) async throws {}
}

private actor FixtureTransport: DsmBinaryHTTPTransport {
    private let pageState = ProcessInfo.processInfo.environment["LANSTASH_UI_STATE"] ?? "content"
    private var uploaded: [String: Bool] = [:]

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        if pageState == "loading" { try await Task.sleep(for: .seconds(60)) }
        if pageState == "error" { throw URLError(.notConnectedToInternet) }
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []
        let api = fields.first { $0.name == "api" }?.value ?? ""
        let method = fields.first { $0.name == "method" }?.value ?? ""
        let result: [String: Any]
        switch (api, method) {
        case (DsmAPIName.fileStationList, "list_share"):
            let shares: [[String: Any]] = pageState == "empty" ? [] : [["name": "Sample folder", "path": "/fixture", "isdir": true]]
            result = ["shares": shares, "offset": 0, "total": shares.count]
        case (DsmAPIName.fileStationCheckPermission, "write"):
            result = [:]
        case (DsmAPIName.fileStationCreateFolder, "create"):
            let path = fields.first { $0.name == "folder_path" }?.value ?? ""
            let name = fields.first { $0.name == "name" }?.value ?? ""
            guard path == "/fixture" || path.hasPrefix("/fixture/") else { throw URLError(.unsupportedURL) }
            uploaded[path + "/" + name] = true
            result = [:]
        case (DsmAPIName.fileStationList, "getinfo"):
            let value = fields.first { $0.name == "path" }?.value ?? "[]"
            let paths = try JSONDecoder().decode([String].self, from: Data(value.utf8))
            result = ["files": paths.compactMap { path -> [String: Any]? in
                guard path == "/fixture" || uploaded[path] != nil else { return nil }
                return fixtureItem(path, directory: uploaded[path] ?? true)
            }]
        case (DsmAPIName.fileStationList, "list") where pageState == "upload":
            let path = fields.first { $0.name == "folder_path" }?.value ?? ""
            let children = uploaded.filter { ($0.key as NSString).deletingLastPathComponent == path }
            result = ["files": children.map { fixtureItem($0.key, directory: $0.value) }, "offset": 0, "total": children.count]
        case (DsmAPIName.fileStationList, "list"):
            result = ["files": [["name": "Sample document.txt", "path": "/fixture/Sample document.txt", "isdir": false,
                                  "additional": ["size": 1024, "time": ["mtime": 1_700_000_000]]]], "offset": 0, "total": 1]
        case (DsmAPIName.fileStationSearch, "start"):
            result = ["taskid": "fixture-search", "has_not_index_share": pageState == "advanced"]
        case (DsmAPIName.fileStationSearch, "list"):
            if pageState == "advanced" {
                result = ["files": [["name": "Filtered result.txt", "path": "/fixture/Filtered result.txt", "isdir": false]], "offset": 0, "total": 1, "finished": true]
            } else {
                result = ["files": [], "offset": 0, "total": 0, "finished": true]
            }
        case (DsmAPIName.fileStationSearch, "stop"), (DsmAPIName.fileStationSearch, "clean"):
            result = [:]
        case (DsmAPIName.fileStationInfo, "get"):
            result = ["is_manager": false, "hostname": "Sample NAS", "support_sharing": false]
        case (DsmAPIName.downloadStationTask, "list"):
            result = ["tasks": [["id": "fixture-download", "title": "Sample archive.zip", "status": "downloading", "type": "http", "size": 4096,
                                  "additional": ["detail": ["destination": "fixture"], "transfer": ["size_downloaded": 2048, "speed_download": 0, "speed_upload": 0]]]], "total": 1, "offset": 0]
        case (DsmAPIName.downloadStationStatistic, "getinfo"):
            result = ["speed_download": 0, "speed_upload": 0]
        default:
            return .init(data: try JSONSerialization.data(withJSONObject: ["success": false, "error": ["code": 102]]), statusCode: 200)
        }
        return .init(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": result]), statusCode: 200)
    }

    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        throw URLError(.unsupportedURL)
    }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        guard pageState == "upload" else { throw URLError(.unsupportedURL) }
        let body = try String(contentsOf: bodyFileURL, encoding: .utf8)
        guard let nameStart = body.range(of: "filename=\"")?.upperBound,
              let nameEnd = body[nameStart...].firstIndex(of: "\""),
              let pathStart = body.range(of: "name=\"path\"\r\n\r\n")?.upperBound,
              let pathEnd = body[pathStart...].range(of: "\r\n")?.lowerBound else { throw URLError(.badServerResponse) }
        let path = String(body[pathStart..<pathEnd])
        guard path == "/fixture" || path.hasPrefix("/fixture/") else { throw URLError(.unsupportedURL) }
        uploaded[path + "/" + String(body[nameStart..<nameEnd])] = false
        progress(1, 1)
        return .init(data: Data("{\"success\":true,\"data\":{}}".utf8), statusCode: 200)
    }

    private func fixtureItem(_ path: String, directory: Bool) -> [String: Any] {
        ["name": (path as NSString).lastPathComponent, "path": path, "isdir": directory,
         "additional": ["size": 0, "perm": ["adv_right": ["write": true, "read": true]]]]
    }
}
#endif

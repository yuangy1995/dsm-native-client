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
            let uploadFixture = ["upload", "archive", "sharing", "permissions-acl", "permissions-posix"].contains(ProcessInfo.processInfo.environment["LANSTASH_UI_STATE"] ?? "")
            let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("LanStashUITestTransfers")
            if uploadFixture && !ProcessInfo.processInfo.arguments.contains("--ui-preserve-transfer-fixture") {
                try? FileManager.default.removeItem(at: fixtureRoot)
            }
            let model = MobileAppModel(defaults: defaults, sessionStore: FixtureSessionStore(), passwordStore: FixturePasswordStore(),
                transferRecoveryStore: uploadFixture ? MobileTransferRecoveryStore(rootURL: fixtureRoot) : nil)
            let profile = try NasProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!,
                                         displayName: "Sample NAS", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
            let versions = [DsmAPIName.coreACL: 1, DsmAPIName.fileStationACLOwner: 1, DsmAPIName.fileStationProperty: 1,
                            DsmAPIName.fileStationSharing: 3, DsmAPIName.desktopInitData: 1, DsmAPIName.fileStationUserGroup: 1, DsmAPIName.fileStationList: 2, DsmAPIName.fileStationInfo: 2, DsmAPIName.fileStationSearch: 2,
                            DsmAPIName.fileStationBackgroundTask: 3, DsmAPIName.fileStationCompress: 3, DsmAPIName.fileStationExtract: 2,
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
    private var stopped = false
    private var cleared = false
    private var permissionMode = 755
    private var permissionOwner = "Sample member"
    private var permissionGroup = "Sample group"
    private var permissionRules: [[String: Any]] = [FixtureTransport.rule("Sample member", kind: "user", level: 0),
                                                    FixtureTransport.rule("Sample group", kind: "group", level: 1)]
    private var isPermissionFixture: Bool { pageState.hasPrefix("permissions-") }
    private static func rule(_ name: String, kind: String, level: Int) -> [String: Any] {
        ["owner_type": kind, "owner_name": name, "permission_type": "allow", "level": level,
         "permission": Dictionary(uniqueKeysWithValues: FileACLRight.allCases.map { ($0.rawValue, $0 == .readData) }),
         "inherit": Dictionary(uniqueKeysWithValues: FileACLInheritance.allCases.map { ($0.rawValue, $0 == .thisFolder) })]
    }
    private var sharing: [[String: Any]] = [FixtureTransport.share("fixture-existing", path: "/fixture/Sample document.txt"),
                                           FixtureTransport.share("fixture-folder", path: "/fixture/Inbox")]
    private static func share(_ id: String, path: String) -> [String: Any] {
        ["id": id, "name": (path as NSString).lastPathComponent, "path": path, "url": "https://share.example.invalid/" + id,
         "has_password": false, "date_available": "0", "date_expired": "0", "status": "valid", "protect_type": "none",
         "protect_users": [String](), "protect_groups": [String](), "expire_times": 0, "enable_upload": false,
         "project_name": "SYNO.SDS.App.FileStation3.Instance", "request_name": "", "request_info": ""]
    }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        if pageState == "loading" { try await Task.sleep(for: .seconds(60)) }
        if pageState == "error" { throw URLError(.notConnectedToInternet) }
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []
        let api = fields.first { $0.name == "api" }?.value ?? ""
        let method = fields.first { $0.name == "method" }?.value ?? ""
        let result: [String: Any]
        switch (api, method) {
        case (DsmAPIName.coreACL, "get") where isPermissionFixture:
            result = ["is_acl": true, "change_permission": true, "is_inherited": true, "acl": permissionRules]
        case (DsmAPIName.fileStationACLOwner, "get") where isPermissionFixture:
            result = ["name": permissionOwner, "type": "user", "value": "user:" + permissionOwner, "hasPrivilege": true]
        case (DsmAPIName.coreACL, "check_self_denied") where isPermissionFixture:
            result = ["is_denied": false]
        case (DsmAPIName.coreACL, "set") where isPermissionFixture:
            if fields.contains(where: { $0.name == "change_acl" && $0.value == "true" }),
               let data = fields.first(where: { $0.name == "rules" })?.value?.data(using: .utf8),
               let rules = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                permissionRules = rules.map { $0.merging(["level": 0]) { _, new in new } }
                    + permissionRules.filter { $0["level"] as? Int == 1 }
            }
            if let owner = fields.first(where: { $0.name == "acl_owner" })?.value { permissionOwner = owner }
            result = ["task_id": "fixture-permission-task"]
        case (DsmAPIName.coreACL, "status") where isPermissionFixture,
             (DsmAPIName.fileStationProperty, "status") where isPermissionFixture:
            result = ["finished": true]
        case (DsmAPIName.fileStationProperty, "set") where isPermissionFixture:
            if let mode = fields.first(where: { $0.name == "mode" })?.value, mode != "-1" { permissionMode = Int(mode) ?? permissionMode }
            if let owner = fields.first(where: { $0.name == "owner" })?.value { permissionOwner = owner }
            if let group = fields.first(where: { $0.name == "group" })?.value { permissionGroup = group }
            result = ["taskid": "fixture-permission-task"]
        case (DsmAPIName.desktopInitData, "get_user_service"):
            result = ["AppPrivilege": ["SYNO.SDS.App.FileStation3.Instance": pageState == "sharing" || isPermissionFixture], "Session": ["is_admin": isPermissionFixture]]
        case (DsmAPIName.fileStationUserGroup, "list_all"):
            result = ["owners": [["name": "Sample member", "type": "user"], ["name": "Sample group", "type": "group"]], "total": 2]
        case (DsmAPIName.fileStationSharing, "list") where pageState == "sharing":
            result = ["links": sharing, "offset": 0, "total": sharing.count]
        case (DsmAPIName.fileStationSharing, "create") where pageState == "sharing":
            let value = fields.first { $0.name == "path" }?.value ?? "[]"
            guard let path = try JSONDecoder().decode([String].self, from: Data(value.utf8)).first else { throw URLError(.badURL) }
            let id = "fixture-created-" + String(sharing.count)
            var link = Self.share(id, path: path)
            for key in ["date_available", "date_expired"] {
                if let value = fields.first(where: { $0.name == key })?.value { link[key] = value }
            }
            if fields.contains(where: { $0.name == "password" && $0.value?.isEmpty == false }) { link["has_password"] = true; link["protect_type"] = "password" }
            if fields.contains(where: { $0.name == "file_request" && $0.value == "true" }) {
                link["enable_upload"] = true; link["project_name"] = "SYNO.SDS.App.SharingUpload.Application"
                link["request_name"] = fields.first { $0.name == "request_name" }?.value ?? ""
                link["request_info"] = fields.first { $0.name == "request_info" }?.value ?? ""
            }
            sharing.append(link); result = ["links": [["id": id, "path": path, "error": 0]]]
        case (DsmAPIName.fileStationSharing, "edit") where pageState == "sharing",
             (DsmAPIName.fileStationSharing, "delete") where pageState == "sharing":
            let value = fields.first { $0.name == "id" }?.value ?? "[]"
            let ids = try JSONDecoder().decode([String].self, from: Data(value.utf8))
            if method == "delete" { sharing.removeAll { ids.contains($0["id"] as? String ?? "") } }
            else {
                for index in sharing.indices where ids.contains(sharing[index]["id"] as? String ?? "") {
                    for key in ["date_available", "date_expired", "protect_type", "request_name", "request_info"] {
                        if let value = fields.first(where: { $0.name == key })?.value { sharing[index][key] = value }
                    }
                    if let password = fields.first(where: { $0.name == "password" })?.value {
                        sharing[index]["has_password"] = !password.isEmpty; sharing[index]["protect_type"] = password.isEmpty ? "none" : "password"
                    }
                    if fields.contains(where: { $0.name == "protect_type" }) { sharing[index]["has_password"] = false }
                    for key in ["protect_users", "protect_groups"] {
                        if let value = fields.first(where: { $0.name == key })?.value { sharing[index][key] = try JSONDecoder().decode([String].self, from: Data(value.utf8)) }
                    }
                    if let value = fields.first(where: { $0.name == "expire_times" })?.value { sharing[index]["expire_times"] = Int(value) }
                }
            }
            result = [:]
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
                guard path == "/fixture" || uploaded[path] != nil || pageState == "archive" && path == "/fixture/Sample archive.zip"
                    || (pageState == "sharing" || isPermissionFixture) && ["/fixture/Sample document.txt", "/fixture/Inbox"].contains(path) else { return nil }
                return fixtureItem(path, directory: uploaded[path] ?? (path == "/fixture" || path == "/fixture/Inbox"))
            }]
        case (DsmAPIName.fileStationList, "list") where pageState == "sharing" || isPermissionFixture:
            result = ["files": [fixtureItem("/fixture/Sample document.txt", directory: false), fixtureItem("/fixture/Inbox", directory: true)], "offset": 0, "total": 2]
        case (DsmAPIName.fileStationList, "list") where pageState == "upload":
            let path = fields.first { $0.name == "folder_path" }?.value ?? ""
            let children = uploaded.filter { ($0.key as NSString).deletingLastPathComponent == path }
            result = ["files": children.map { fixtureItem($0.key, directory: $0.value) }, "offset": 0, "total": children.count]
        case (DsmAPIName.fileStationList, "list") where pageState == "archive":
            let path = fields.first { $0.name == "folder_path" }?.value ?? ""
            var children = uploaded.filter { ($0.key as NSString).deletingLastPathComponent == path }
            if path == "/fixture" { children["/fixture/Sample archive.zip"] = false }
            result = ["files": children.map { fixtureItem($0.key, directory: $0.value) }, "offset": 0, "total": children.count]
        case (DsmAPIName.fileStationExtract, "list"):
            result = ["items": [["itemid": 1, "name": "Extracted document.txt", "path": "Extracted document.txt", "is_dir": false, "size": 0]], "total": 1]
        case (DsmAPIName.fileStationCompress, "start"):
            guard let destination = fields.first(where: { $0.name == "dest_file_path" })?.value, destination.hasPrefix("/fixture/") else { throw URLError(.unsupportedURL) }
            uploaded[destination] = false; result = ["taskid": "fixture-compression"]
        case (DsmAPIName.fileStationExtract, "start"):
            uploaded["/fixture/Sample archive"] = true
            uploaded["/fixture/Sample archive/Extracted document.txt"] = false
            result = ["taskid": "fixture-extraction"]
        case (DsmAPIName.fileStationCompress, "status"), (DsmAPIName.fileStationExtract, "status"):
            result = ["finished": true, "progress": 100, "total": 100]
        case (DsmAPIName.fileStationCompress, "stop"):
            stopped = true; result = [:]
        case (DsmAPIName.fileStationBackgroundTask, "clear_finished"):
            cleared = true; result = [:]
        case (DsmAPIName.fileStationBackgroundTask, "list"):
            let tasks: [[String: Any]] = pageState == "archive" && !cleared ? [["taskid": "fixture-background", "api": DsmAPIName.fileStationCompress,
                "version": 3, "method": "start", "finished": stopped, "progress": 0.5, "crtime": 1_700_000_000]] : []
            result = ["tasks": tasks, "offset": 0, "total": tasks.count]
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
        var additional: [String: Any] = ["size": 0, "perm": ["adv_right": ["write": true, "read": true]]]
        if isPermissionFixture {
            additional["real_path"] = "/volume-fixture" + path; additional["mount_point_type"] = "normal"
            additional["owner"] = ["user": permissionOwner, "group": permissionGroup]
            additional["perm"] = ["is_acl_mode": pageState == "permissions-acl", "posix": permissionMode,
                                  "adv_right": ["read": true, "write": true]]
        }
        return ["name": (path as NSString).lastPathComponent, "path": path, "isdir": directory, "additional": additional]
    }
}
#endif

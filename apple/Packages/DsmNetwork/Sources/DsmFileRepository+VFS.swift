import DsmCore
import Foundation

struct PendingFileVFSChange: Sendable {
    let change: FileVFSChange
    let originalIDs: Set<String>
    var connectionAcknowledged = false
    var profileAcknowledged = false
}

extension DsmFileRepository {
    public func listFileVFSProtocols() async throws -> [FileVFSProtocol] {
        let data: VFSProtocolsPayload = try await advancedFileCall(DsmAPIName.fileStationVFSProtocol, method: "list")
        guard Set(data.protocols.map(\.protocol)).count == data.protocols.count else { throw Self.advancedFileError() }
        return data.protocols.map { .init(id: $0.protocol, name: $0.name, defaultPort: $0.default_port, hasConnections: $0.has_server) }
    }

    public func prepareFileVFSCloudAuthorization(protocolID: String) async throws -> FileVFSCloudAuthorizationRequest {
        try requireSecureVFSSetup()
        try await requireAdvancedFileWrite()
        guard try await listFileVFSProtocols().contains(where: { $0.id == protocolID && $0.supportsCloudAuthorization }) else {
            throw Self.advancedFileError(.apiUnavailable, "files.advanced.unavailable")
        }
        struct SystemInfo: Decodable, Sendable { let firmware_ver: String }
        let info: SystemInfo = try await advancedFileCall(DsmAPIName.coreSystem, method: "info")
        let pattern = try NSRegularExpression(pattern: #"(?:^|[^0-9])([0-9]+)\.([0-9]+)(?:[^0-9]|$)"#)
        let text = info.firmware_ver as NSString
        guard let match = pattern.firstMatch(in: info.firmware_ver, range: NSRange(location: 0, length: text.length)),
              let major = Int(text.substring(with: match.range(at: 1))), let minor = Int(text.substring(with: match.range(at: 2))),
              major > 0, minor >= 0 else { throw Self.advancedFileError() }
        let callbackName = "_webfmOAuthCallback"
        var login = URLComponents(string: "https://synooauth.synology.com/FileStation/Cloud/login.php")!
        // 已以公开合成参数验证：major/minor 足以进入正式授权页，不发送设备标识或 NAS 会话。
        login.queryItems = [URLQueryItem(name: "major", value: String(major)), URLQueryItem(name: "minor", value: String(minor)),
            URLQueryItem(name: "type", value: protocolID)]
        let request = FileVFSCloudAuthorizationRequest(profileID: profileID, protocolID: protocolID, loginURL: login.url!,
            callbackName: callbackName)
        fileVFSCloudAuthorizationRequest = request
        return request
    }

    private func validateCloudAuthorization(_ value: FileVFSCloudAuthorization?, identity: FileVFSCloudIdentity) async throws {
        guard let value, value.profileID == profileID, value.protocolID == identity.protocolID, value.account == identity.account,
              !value.accessToken.isEmpty, !identity.account.isEmpty, !identity.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              identity.alias.count <= 255, value.expiresIn.map({ $0 >= 0 }) ?? true,
              try await listFileVFSProtocols().contains(where: { $0.id == identity.protocolID && $0.supportsCloudAuthorization }) else {
            throw Self.advancedFileError(.conflict, "files.vfs.authorizationMismatch")
        }
    }

    private static func cloudVFSParameters(_ value: FileVFSCloudAuthorization) -> [String: DsmParameterValue] {
        var fields: [String: DsmParameterValue] = ["account": .string(value.account), "access_token": .string(value.accessToken)]
        if let clientID = value.clientID { fields["client_id"] = .string(clientID) }
        if let token = value.refreshToken { fields["refresh_token"] = .string(token) }
        if let expires = value.expiresIn { fields["expires_in"] = .integer(expires) }
        return fields
    }

    public func listFileVFSProfiles() async throws -> [FileVFSProfile] {
        let data: VFSProfilesPayload = try await advancedFileCall(DsmAPIName.fileStationVFSProfile, method: "list")
        guard data.total == nil || data.total == data.profiles.count, Set(data.profiles.map(\.id)).count == data.profiles.count else {
            throw Self.advancedFileError()
        }
        return try data.profiles.map { row in
            guard !row.id.isEmpty, !row.protocol.isEmpty else { throw Self.advancedFileError() }
            return .init(profileID: profileID, id: row.id, protocolID: row.protocol, protocolName: row.protocol_name, uri: row.uri,
                hostname: row.hostname, port: row.port, alias: row.alias, account: row.account, codepage: row.codepage,
                state: row.connect_status == 1 ? .connected : row.connect_status == 0 ? .disconnected : .unknown)
        }
    }

    public func listFileVFSFolder(_ profile: FileVFSProfile, path: String, offset: Int, limit: Int) async throws -> FilePage {
        guard profile.profileID == profileID, profile.state == .connected,
              offset >= 0, (1...500).contains(limit), Self.vfsPath(path, belongsTo: profile),
              try await listFileVFSProfiles().contains(profile) else { throw Self.advancedFileError(.conflict, "files.vfs.changed") }
        // 官方树和表格都使用 List.list + 原始远程 URI，不将 URI 转成本机文件路径。
        let page = try await listFolder(path: path, offset: offset, limit: limit)
        guard page.offset == offset, page.items.count <= limit, !page.hasMore || !page.items.isEmpty,
              Set(page.items.map(\.id)).count == page.items.count,
              page.items.allSatisfy({ Self.vfsPath($0.path, belongsTo: profile) && $0.path != path }) else { throw Self.advancedFileError() }
        return page
    }

    private static func vfsPath(_ path: String, belongsTo profile: FileVFSProfile) -> Bool {
        let root = profile.uri.hasSuffix("/") ? String(profile.uri.dropLast()) : profile.uri
        guard !root.isEmpty, root.hasPrefix(profile.protocolID + "://"),
              !path.contains(where: { $0.isNewline }), !path.contains("\0"),
              path == root || path.hasPrefix(root + "/") else { return false }
        return !path.dropFirst(root.count).split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    public func loadFileVFSDetail(_ profile: FileVFSProfile) async throws -> FileVFSDetail {
        guard profile.profileID == profileID, try await listFileVFSProfiles().contains(profile),
              ["ftp", "sftp", "dav", "davs"].contains(profile.protocolID) else { throw Self.advancedFileError(.conflict, "files.vfs.changed") }
        // get 可能包含密码；解码白名单中不声明该字段，表单只允许显式输入替换密码。
        let data: VFSDetailPayload = try await advancedFileCall(DsmAPIName.fileStationVFSProfile, method: "get", parameters: ["id": .string(profile.id)])
        guard data.hostname == profile.hostname, data.port == profile.port, data.alias == profile.alias,
              data.account == profile.account, data.codepage == profile.codepage, [0, 1].contains(data.max_connection) else { throw Self.advancedFileError(.conflict, "files.vfs.changed") }
        let configuration = FileVFSConfiguration(protocolID: profile.protocolID, hostname: data.hostname, port: data.port,
            alias: data.alias, account: data.account, codepage: data.codepage, folder: data.uri_path, usesOneConnection: data.max_connection == 1)
        return .init(profile: profile, configuration: Self.normalizedVFS(configuration))
    }

    public func changeFileVFS(_ change: FileVFSChange, password: String?, confirmed: Bool) async throws -> MutationResult {
        try await performFileVFSChange(change, password: password, authorization: nil, confirmed: confirmed)
    }

    public func authorizeFileVFS(_ change: FileVFSChange, authorization: FileVFSCloudAuthorization, confirmed: Bool) async throws -> MutationResult {
        switch change {
        case .createCloud, .reauthorize: break
        default: throw Self.advancedFileError(.conflict, "files.vfs.authorizationMismatch")
        }
        guard let request = fileVFSCloudAuthorizationRequest, request.id == authorization.requestID,
              request.profileID == authorization.profileID, request.protocolID == authorization.protocolID else {
            throw Self.advancedFileError(.conflict, "files.vfs.authorizationExpired")
        }
        fileVFSCloudAuthorizationRequest = nil
        return try await performFileVFSChange(change, password: nil, authorization: authorization, confirmed: confirmed)
    }

    private func performFileVFSChange(_ change: FileVFSChange, password: String?, authorization: FileVFSCloudAuthorization?, confirmed: Bool) async throws -> MutationResult {
        let key = Self.vfsChangeKey(change)
        guard confirmed, !activeAdvancedFileChanges.contains("vfs"), pendingFileVFS[key] == nil else {
            throw Self.advancedFileError(.conflict, "files.advanced.pendingChange")
        }
        activeAdvancedFileChanges.insert("vfs")
        defer { activeAdvancedFileChanges.remove("vfs") }
        try await requireAdvancedFileWrite()
        let before = try await listFileVFSProfiles()
        let connectionAPI = DsmAPIName.fileStationVFSConnection, profileAPI = DsmAPIName.fileStationVFSProfile
        for api in [connectionAPI, profileAPI] {
            guard capabilities[api]?.selectedVersion == 1 else { throw Self.advancedFileError(.apiUnavailable, "files.advanced.unavailable") }
        }
        let method: String, parameters: [String: DsmParameterValue], writesProfile: Bool
        switch change {
        case .createCloud(let identity):
            try requireSecureVFSSetup()
            try await validateCloudAuthorization(authorization, identity: identity)
            guard !before.contains(where: { $0.alias == identity.alias || ($0.protocolID == identity.protocolID && $0.account == identity.account) }) else {
                throw Self.advancedFileError(.conflict, "files.vfs.alreadyExists")
            }
            var fields = Self.cloudVFSParameters(authorization!)
            fields["protocol"] = .string(identity.protocolID); fields["alias"] = .string(identity.alias)
            fields["hostname"] = .string("")
            method = "create"; parameters = fields; writesProfile = true
        case .reauthorize(let baseline):
            try requireSecureVFSSetup()
            guard baseline.profileID == profileID, before.contains(baseline), let account = baseline.account else {
                throw Self.advancedFileError(.conflict, "files.vfs.changed")
            }
            try await validateCloudAuthorization(authorization, identity: .init(protocolID: baseline.protocolID, alias: baseline.alias, account: account))
            var fields = Self.cloudVFSParameters(authorization!)
            fields["id"] = .string(baseline.id)
            method = "set"; parameters = fields; writesProfile = true
        case .create(let raw):
            try requireSecureVFSSetup()
            let configuration = Self.normalizedVFS(raw)
            try await validateVFSConfiguration(configuration)
            guard !before.contains(where: { $0.alias == configuration.alias || Self.vfsProfileMatches($0, configuration) }) else {
                throw Self.advancedFileError(.conflict, "files.vfs.alreadyExists")
            }
            method = "create"; parameters = Self.vfsParameters(configuration, password: password ?? ""); writesProfile = true
        case .update(let baseline, let raw):
            try requireSecureVFSSetup()
            guard baseline.profile.profileID == profileID, before.contains(baseline.profile),
                  baseline.profile.state != .unknown, raw.protocolID == baseline.profile.protocolID,
                  try await loadFileVFSDetail(baseline.profile) == baseline else { throw Self.advancedFileError(.conflict, "files.vfs.changed") }
            let configuration = Self.normalizedVFS(raw)
            guard configuration != baseline.configuration || password != nil else { throw Self.advancedFileError(.conflict, "files.vfs.noChanges") }
            try await validateVFSConfiguration(configuration)
            guard !before.contains(where: { $0.id != baseline.profile.id && $0.alias == configuration.alias }) else {
                throw Self.advancedFileError(.conflict, "files.vfs.alreadyExists")
            }
            var fields = Self.vfsParameters(configuration, password: password)
            fields.removeValue(forKey: "protocol"); fields["id"] = .string(baseline.profile.id)
            method = "set"; parameters = fields; writesProfile = true
        case .connect(let profile):
            guard profile.profileID == profileID, before.contains(profile), profile.state == .disconnected else {
                throw Self.advancedFileError(.conflict, "files.vfs.changed")
            }
            method = "create"; parameters = ["profile_id": .string(profile.id)]; writesProfile = false
        case .disconnect(let profile):
            guard profile.profileID == profileID, before.contains(profile), profile.state == .connected else {
                throw Self.advancedFileError(.conflict, "files.vfs.changed")
            }
            method = "delete"; parameters = ["id": .string(profile.id)]; writesProfile = false
        case .removeSavedProfile(let profile):
            guard profile.profileID == profileID, before.contains(profile), profile.state == .disconnected else {
                throw Self.advancedFileError(.conflict, "files.vfs.disconnectFirst")
            }
            method = "delete"; parameters = ["id": .string(profile.id)]; writesProfile = false
        }
        // 协议和详情检查之后再次核对清单，不能误用已经被他人改动的连接。
        guard try await listFileVFSProfiles() == before else { throw Self.advancedFileError(.conflict, "files.vfs.changed") }
        try Task.checkCancellation()
        var pending = PendingFileVFSChange(change: change, originalIDs: Set(before.map(\.id)))
        pendingFileVFS[key] = pending
        do {
            if case .removeSavedProfile = change {
                try await writeVFS(profileAPI, method: method, parameters: parameters)
                pending.profileAcknowledged = true
            } else {
                var connectionParameters = parameters
                if method != "delete" { connectionParameters["force"] = .boolean(false) }
                try await writeVFS(connectionAPI, method: method, parameters: connectionParameters)
                pending.connectionAcknowledged = true; pendingFileVFS[key] = pending
                if writesProfile {
                    try Task.checkCancellation()
                    try await writeVFS(profileAPI, method: method, parameters: parameters)
                    pending.profileAcknowledged = true
                }
            }
            pendingFileVFS[key] = pending
        } catch let error as DsmNetworkError {
            if case .api(let code, _) = error, !pending.connectionAcknowledged && !pending.profileAcknowledged {
                pendingFileVFS.removeValue(forKey: key)
                let message = [2107, 2112, 2115].contains(code) ? "files.vfs.identity-check" : "files.vfs.connection-failed"
                return try Self.vfsResult(.confirmedFailure, message: message)
            }
            if case .invalidRequest = error, !pending.connectionAcknowledged && !pending.profileAcknowledged {
                pendingFileVFS.removeValue(forKey: key); throw DsmErrorMapper.map(error)
            }
        } catch { /* 凭据不留在 pending 中；连接或配置结果未知时只回查。 */ }
        return try await reviewFileVFSCore(change)
    }

    public func reviewFileVFS(_ change: FileVFSChange) async throws -> MutationResult {
        guard !activeAdvancedFileChanges.contains("vfs") else { throw Self.advancedFileError(.conflict, "files.advanced.pendingChange") }
        activeAdvancedFileChanges.insert("vfs")
        defer { activeAdvancedFileChanges.remove("vfs") }
        return try await reviewFileVFSCore(change)
    }

    private func reviewFileVFSCore(_ change: FileVFSChange) async throws -> MutationResult {
        let key = Self.vfsChangeKey(change)
        guard let pending = pendingFileVFS[key], pending.change == change else { throw Self.advancedFileError(.conflict, "files.vfs.changed") }
        do {
            let profiles = try await listFileVFSProfiles()
            let verified: Bool
            switch change {
            case .createCloud(let identity):
                let matches = profiles.filter { !pending.originalIDs.contains($0.id) && $0.protocolID == identity.protocolID
                    && $0.account == identity.account && $0.alias == identity.alias && $0.state == .connected }
                verified = matches.count == 1 && pending.connectionAcknowledged && pending.profileAcknowledged
            case .reauthorize(let baseline):
                verified = pending.connectionAcknowledged && pending.profileAcknowledged
                    && profiles.contains { Self.sameVFSIdentity($0, baseline) && $0.state == .connected }
            case .create(let raw):
                let desired = Self.normalizedVFS(raw)
                let matches = profiles.filter { !pending.originalIDs.contains($0.id) && Self.vfsProfileMatches($0, desired) && $0.state == .connected }
                if matches.count == 1, pending.connectionAcknowledged, pending.profileAcknowledged,
                   let profile = matches.first {
                    verified = try await loadFileVFSDetail(profile).configuration == desired
                } else { verified = false }
            case .update(let baseline, let raw):
                let desired = Self.normalizedVFS(raw)
                if let profile = profiles.first(where: { $0.id == baseline.profile.id }), Self.vfsProfileMatches(profile, desired),
                   profile.state == .connected, pending.connectionAcknowledged, pending.profileAcknowledged {
                    verified = try await loadFileVFSDetail(profile).configuration == desired
                } else { verified = false }
            case .connect(let baseline):
                verified = profiles.contains { Self.sameVFSIdentity($0, baseline) && $0.state == .connected }
            case .disconnect(let baseline):
                verified = profiles.contains { Self.sameVFSIdentity($0, baseline) && $0.state == .disconnected }
            case .removeSavedProfile(let baseline):
                verified = !profiles.contains { $0.id == baseline.id }
            }
            if verified { pendingFileVFS.removeValue(forKey: key) }
            return try Self.vfsResult(verified ? .confirmedSuccess : .submittedButUnverified,
                message: !verified && pending.connectionAcknowledged && !pending.profileAcknowledged ? "files.vfs.partial" : nil)
        } catch { return try Self.vfsResult(.submittedButUnverified) }
    }

    private func writeVFS(_ api: String, method: String, parameters: [String: DsmParameterValue]) async throws {
        guard let capability = capabilities[api], capability.selectedVersion == 1 else { throw Self.advancedFileError(.apiUnavailable) }
        try await client.callVoid(path: capability.path, api: api, version: 1, method: method,
            requestFormat: capability.requestFormat, parameters: parameters, credential: credential)
    }
    private func validateVFSConfiguration(_ configuration: FileVFSConfiguration) async throws {
        let protocols = try await listFileVFSProtocols()
        guard protocols.contains(where: { $0.id == configuration.protocolID && $0.supportsServerSetup }),
              (1...65_535).contains(configuration.port), !configuration.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.hostname.contains(where: { $0.isWhitespace || "/@?#".contains($0) }),
              !configuration.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, configuration.alias.count <= 255,
              !configuration.codepage.isEmpty else { throw Self.advancedFileError(.invalidResponse, "files.vfs.invalidConfiguration") }
    }
    private static func normalizedVFS(_ value: FileVFSConfiguration) -> FileVFSConfiguration {
        var result = value; result.hostname = value.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.protocolID == "dav" || value.protocolID == "davs" { result.folder = String(value.folder.drop(while: { $0 == "/" })) }
        return result
    }
    private static func vfsParameters(_ value: FileVFSConfiguration, password: String?) -> [String: DsmParameterValue] {
        var fields: [String: DsmParameterValue] = ["protocol": .string(value.protocolID), "hostname": .string(value.hostname),
            "port": .integer(value.port), "alias": .string(value.alias), "account": .string(value.account),
            "codepage": .string(value.codepage), "uri_path": .string(value.folder), "max_connection": .integer(value.usesOneConnection ? 1 : 0)]
        if let password { fields["password"] = .string(password) }
        return fields
    }
    private static func vfsProfileMatches(_ profile: FileVFSProfile, _ configuration: FileVFSConfiguration) -> Bool {
        profile.protocolID == configuration.protocolID && profile.hostname == configuration.hostname && profile.port == configuration.port
            && profile.alias == configuration.alias && profile.account == configuration.account && profile.codepage == configuration.codepage
    }
    private static func sameVFSIdentity(_ left: FileVFSProfile, _ right: FileVFSProfile) -> Bool {
        left.profileID == right.profileID && left.id == right.id && left.protocolID == right.protocolID && left.uri == right.uri
            && left.hostname == right.hostname && left.port == right.port && left.alias == right.alias && left.account == right.account && left.codepage == right.codepage
    }
    private static func vfsChangeKey(_ change: FileVFSChange) -> String {
        switch change {
        case .createCloud(let identity): return "vfs:cloud:" + identity.protocolID + ":" + identity.account
        case .reauthorize(let profile): return "vfs:" + profile.id
        case .create(let configuration):
            let value = normalizedVFS(configuration)
            return "vfs:new:" + value.protocolID + ":" + value.hostname + ":" + String(value.port) + ":" + value.account + ":" + value.folder
        case .update(let baseline, _): return "vfs:" + baseline.profile.id
        case .connect(let profile), .disconnect(let profile), .removeSavedProfile(let profile): return "vfs:" + profile.id
        }
    }
    private static func vfsResult(_ status: MutationResultStatus, message: String? = nil) throws -> MutationResult {
        let success = status == .confirmedSuccess, unknown = status == .submittedButUnverified
        return try MutationResult(status: status, operation: "fileStationRemoteConnection", submitted: true, requiresRefresh: unknown,
            counts: .init(succeeded: success ? 1 : 0, failed: success || unknown ? 0 : 1, unknown: unknown ? 1 : 0),
            localizationKey: message, diagnosticTag: "file-station.vfs")
    }
}

private struct VFSProtocolsPayload: Decodable, Sendable {
    struct Row: Decodable, Sendable { let `protocol`: String; let name: String; let default_port: Int?; let has_server: Bool }
    let protocols: [Row]
}
private struct VFSProfilesPayload: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        let id: String; let `protocol`: String; let protocol_name: String; let uri: String
        let hostname: String?; let port: Int?; let alias: String; let account: String?; let codepage: String?; let connect_status: Int
    }
    let profiles: [Row]; let total: Int?
}
private struct VFSDetailPayload: Decodable, Sendable {
    let hostname: String; let port: Int; let alias: String; let account: String; let codepage: String; let uri_path: String; let max_connection: Int
}

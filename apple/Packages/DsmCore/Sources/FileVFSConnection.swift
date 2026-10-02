import Foundation

public struct FileVFSProtocol: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let defaultPort: Int?
    public let hasConnections: Bool
    public var supportsServerSetup: Bool { ["ftp", "sftp", "dav", "davs"].contains(id) }
    public var supportsCloudAuthorization: Bool { Self.cloudProtocolIDs.contains(id) }
    public static let cloudProtocolIDs: Set<String> = ["google", "dropbox", "baidu", "onedrive", "box"]
    public init(id: String, name: String, defaultPort: Int?, hasConnections: Bool) {
        self.id = id; self.name = name; self.defaultPort = defaultPort; self.hasConnections = hasConnections
    }
}

public struct FileVFSProfile: Identifiable, Equatable, Sendable {
    public enum State: Sendable { case connected, disconnected, unknown }
    public let profileID: UUID
    public let id: String
    public let protocolID: String
    public let protocolName: String
    public let uri: String
    public let hostname: String?
    public let port: Int?
    public let alias: String
    public let account: String?
    public let codepage: String?
    public let state: State
    public init(profileID: UUID, id: String, protocolID: String, protocolName: String, uri: String, hostname: String?, port: Int?,
                alias: String, account: String?, codepage: String?, state: State) {
        self.profileID = profileID; self.id = id; self.protocolID = protocolID; self.protocolName = protocolName; self.uri = uri
        self.hostname = hostname; self.port = port; self.alias = alias; self.account = account; self.codepage = codepage; self.state = state
    }
}

/// 不含密码或授权令牌，只描述 NAS 管理的远程连接。
public struct FileVFSConfiguration: Equatable, Sendable {
    public var protocolID: String
    public var hostname: String
    public var port: Int
    public var alias: String
    public var account: String
    public var codepage: String
    public var folder: String
    public var usesOneConnection: Bool
    public init(protocolID: String, hostname: String, port: Int, alias: String, account: String, codepage: String = "UTF-8",
                folder: String = "", usesOneConnection: Bool = false) {
        self.protocolID = protocolID; self.hostname = hostname; self.port = port; self.alias = alias
        self.account = account; self.codepage = codepage; self.folder = folder; self.usesOneConnection = usesOneConnection
    }
}

public struct FileVFSDetail: Equatable, Sendable {
    public let profile: FileVFSProfile
    public let configuration: FileVFSConfiguration
    public init(profile: FileVFSProfile, configuration: FileVFSConfiguration) { self.profile = profile; self.configuration = configuration }
}

public enum FileVFSChange: Equatable, Sendable {
    case create(FileVFSConfiguration)
    case update(baseline: FileVFSDetail, configuration: FileVFSConfiguration)
    case createCloud(FileVFSCloudIdentity)
    case reauthorize(FileVFSProfile)
    case connect(FileVFSProfile)
    case disconnect(FileVFSProfile)
    case removeSavedProfile(FileVFSProfile)
}

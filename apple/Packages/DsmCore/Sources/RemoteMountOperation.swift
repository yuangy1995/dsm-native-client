import Foundation

/// 操作恢复只持有非密码配置，不可编码为凭据或持久化记录。
public struct RemoteMountSetup: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let protocolType: RemoteMountProtocol
    public let server: String
    public let remotePath: String
    public let mountPoint: String
    public let username: String
    public let domain: String
    public let readOnly: Bool
    public let nfsVersion: RemoteMountNFSVersion
    public let nfsTransport: RemoteMountNFSTransport
    public init(_ configuration: RemoteMountConfiguration) {
        protocolType = configuration.protocolType; server = configuration.server; remotePath = configuration.remotePath
        mountPoint = configuration.mountPoint; username = configuration.username; domain = configuration.domain; readOnly = configuration.readOnly
        nfsVersion = configuration.nfsVersion; nfsTransport = configuration.nfsTransport
    }
    public func configuration(password: String = "") -> RemoteMountConfiguration {
        RemoteMountConfiguration(protocolType: protocolType, server: server, remotePath: remotePath, mountPoint: mountPoint,
            username: username, password: protocolType == .smb ? password : "", domain: domain, readOnly: readOnly,
            nfsVersion: nfsVersion, nfsTransport: nfsTransport)
    }
    public var description: String { "RemoteMountSetup" }
    public var debugDescription: String { description }
}

public enum RemoteMountOperationAction: Equatable, Sendable { case create, update, disconnect }
public enum RemoteMountOperationStage: Equatable, Sendable {
    case verifyingConnection, verifyingDisconnection, readyToConnect, readyToDisconnectPrevious, completed, failed, cancelled
    public var requiresReview: Bool { self == .verifyingConnection || self == .verifyingDisconnection }
    public var canContinue: Bool { self == .readyToConnect || self == .readyToDisconnectPrevious }
    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

public struct RemoteMountOperation: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let profileID: UUID
    public let action: RemoteMountOperationAction
    public let baseline: RemoteMountConnection?
    public let setup: RemoteMountSetup?
    public let stage: RemoteMountOperationStage
    public var mountPoint: String { setup?.mountPoint ?? baseline?.mountPoint ?? "" }
    public var affectedPaths: Set<String> { Set([baseline?.mountPoint, setup?.mountPoint].compactMap { $0 }) }
    public init(id: UUID, profileID: UUID, action: RemoteMountOperationAction, baseline: RemoteMountConnection?, setup: RemoteMountSetup?, stage: RemoteMountOperationStage) {
        self.id = id; self.profileID = profileID; self.action = action; self.baseline = baseline; self.setup = setup; self.stage = stage
    }
    public func replacingStage(_ stage: RemoteMountOperationStage) -> RemoteMountOperation {
        RemoteMountOperation(id: id, profileID: profileID, action: action, baseline: baseline, setup: setup, stage: stage)
    }
    public var description: String { "RemoteMountOperation" }
    public var debugDescription: String { description }
}

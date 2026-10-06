import Foundation

/// 内部 Container.list 的稳定身份与原生运行字段。缺失字段不能补成 false。
public struct ContainerControlState: Equatable, Sendable {
    public let id: String
    public let name: String
    public let running: Bool?
    public let paused: Bool?
    public let restarting: Bool?
    public let startedAt: Date?
    public let managedByPackage: Bool?

    public init(id: String, name: String, running: Bool?, paused: Bool?, restarting: Bool?,
                startedAt: Date?, managedByPackage: Bool?) {
        self.id = id; self.name = name; self.running = running; self.paused = paused
        self.restarting = restarting; self.startedAt = startedAt; self.managedByPackage = managedByPackage
    }

    public var canDelete: Bool {
        managedByPackage == false && running == false && paused == false && restarting == false
    }

    public func supports(_ action: ContainerAction) -> Bool {
        guard managedByPackage == false, paused == false, let running, let restarting else { return false }
        switch action {
        case .start: return !running && !restarting
        case .stop: return running || restarting
        case .restart: return (running || restarting) && startedAt != nil
        }
    }

    public func verifies(_ action: ContainerAction, previousStartedAt: Date?) -> Bool {
        guard managedByPackage == false, paused == false, restarting == false else { return false }
        switch action {
        case .start: return running == true
        case .stop: return running == false
        case .restart:
            guard running == true, let previousStartedAt, let startedAt else { return false }
            return startedAt > previousStartedAt
        }
    }
}

public enum ContainerControlStage: String, Codable, Sendable {
    case willSubmit, accepted, rejected, verified
}

public typealias ContainerControlObserver = @Sendable (ContainerControlStage) async throws -> Void

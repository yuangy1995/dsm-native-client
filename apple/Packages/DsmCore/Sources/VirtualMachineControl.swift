import Foundation

/// 写入只使用原始身份与状态；展示默认值不能作为电源或删除依据。
public struct VirtualMachineControlState: Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let availableActions: Set<VirtualMachinePowerAction>
    public let allowsDeletion: Bool

    public init(id: String, name: String, status: String,
                availableActions: Set<VirtualMachinePowerAction>, allowsDeletion: Bool) {
        self.id = id; self.name = name; self.status = status
        self.availableActions = availableActions; self.allowsDeletion = allowsDeletion
    }

    public var canDelete: Bool { allowsDeletion && status == "shutdown" }

    public func supports(_ action: VirtualMachinePowerAction) -> Bool {
        availableActions.contains(action) && status == (action == .powerOn ? "shutdown" : "running")
    }

    public func verifies(_ action: VirtualMachinePowerAction) -> Bool {
        switch action {
        case .powerOn: status == "running"
        case .shutdown, .powerOff: status == "shutdown"
        // 官方只记录了请求，尚无可关联本次重启的可靠终态；不能把仍运行当作完成。
        case .restart: false
        }
    }
}

public enum VirtualMachineControlStage: String, Codable, Sendable {
    case willSubmit, accepted, rejected, verified
}

public typealias VirtualMachineControlObserver = @Sendable (VirtualMachineControlStage) async throws -> Void

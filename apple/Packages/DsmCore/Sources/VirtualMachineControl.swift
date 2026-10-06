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

/// 内部设置的原始快照；缺失字段保持未知，不使用展示默认值作为保存依据。
public struct VirtualMachineSettingsState: Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let description: String?
    public let cpuCount: Int?
    public let memoryMiB: Int?
    public let cpuWeight: Int?
    public let startupBehavior: VirtualMachineStartupBehavior?

    public init(id: String, name: String, status: String, description: String? = nil,
                cpuCount: Int? = nil, memoryMiB: Int? = nil, cpuWeight: Int? = nil,
                startupBehavior: VirtualMachineStartupBehavior? = nil) {
        self.id = id; self.name = name; self.status = status; self.description = description
        self.cpuCount = cpuCount; self.memoryMiB = memoryMiB; self.cpuWeight = cpuWeight
        self.startupBehavior = startupBehavior
    }

    public var canEdit: Bool { status == "shutdown" || status == "running" }
    public var canEditHardware: Bool { status == "shutdown" }
}

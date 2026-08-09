import Foundation

/// 移动端清单允许跨层传递的虚拟机字段白名单。
public struct VirtualMachineInventoryItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let cpuCount: Int?
    public let memoryBytes: Int64?
    public let storageBytes: Int64?
    public let autoStart: Bool

    public init(
        id: String,
        name: String,
        status: String,
        cpuCount: Int? = nil,
        memoryBytes: Int64? = nil,
        storageBytes: Int64? = nil,
        autoStart: Bool = false
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.storageBytes = storageBytes
        self.autoStart = autoStart
    }
}

/// 移动端虚拟机清单只读契约的结果；不包含附属资源、日志或管理能力。
public struct VirtualMachineInventorySnapshot: Equatable, Sendable {
    public let source: ServiceContractSource
    public let machines: [VirtualMachineInventoryItem]

    public init(source: ServiceContractSource, machines: [VirtualMachineInventoryItem]) {
        self.source = source
        self.machines = machines
    }
}

/// 只暴露虚拟机公开清单读取，避免移动端持有完整服务管理写契约。
public protocol VirtualMachineInventoryReading: Sendable {
    func loadVirtualMachineInventory() async throws -> VirtualMachineInventorySnapshot
}

/// 移动端清单允许跨层传递的容器字段白名单。
public struct ContainerInventoryItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let image: String?

    public init(id: String, name: String, status: String, image: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.image = image
    }
}

/// 移动端容器实例清单只读契约的结果；不包含附属资源、日志或管理能力。
public struct ContainerInventorySnapshot: Equatable, Sendable {
    public let source: ServiceContractSource
    public let containers: [ContainerInventoryItem]

    public init(source: ServiceContractSource, containers: [ContainerInventoryItem]) {
        self.source = source
        self.containers = containers
    }
}

/// 只暴露容器实例清单读取，避免移动端持有完整服务管理写契约。
public protocol ContainerInventoryReading: Sendable {
    func loadContainerInventory() async throws -> ContainerInventorySnapshot
}

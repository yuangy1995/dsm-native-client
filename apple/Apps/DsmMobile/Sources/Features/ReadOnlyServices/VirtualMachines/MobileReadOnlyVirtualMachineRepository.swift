import DsmCore
import Foundation

protocol MobileVirtualMachineInventoryReading: Sendable {
    var profileID: UUID { get }
    func loadInventory() async throws -> VirtualMachineManagerSnapshot
}

/// 移动端只持有一次完整只读快照能力，不暴露服务管理写方法。
struct MobileReadOnlyVirtualMachineRepository: MobileVirtualMachineInventoryReading, Sendable {
    let profileID: UUID
    private let loader: @Sendable () async throws -> VirtualMachineManagerSnapshot

    init(profileID: UUID, base: any ServiceManagementRepository) {
        self.profileID = profileID
        loader = { try await base.loadVirtualMachineManager() }
    }

    init(
        profileID: UUID,
        loader: @escaping @Sendable () async throws -> VirtualMachineManagerSnapshot
    ) {
        self.profileID = profileID
        self.loader = loader
    }

    func loadInventory() async throws -> VirtualMachineManagerSnapshot {
        try await loader()
    }
}

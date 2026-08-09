import DsmCore
import Foundation

protocol MobileVirtualMachineInventoryReading: Sendable {
    var profileID: UUID { get }
    func loadInventory() async throws -> VirtualMachineInventorySnapshot
}

/// 移动端只持有公开虚拟机清单读取能力，不暴露服务管理写方法。
struct MobileReadOnlyVirtualMachineRepository: MobileVirtualMachineInventoryReading, Sendable {
    let profileID: UUID
    private let base: any VirtualMachineInventoryReading

    init(profileID: UUID, base: any VirtualMachineInventoryReading) {
        self.profileID = profileID
        self.base = base
    }

    func loadInventory() async throws -> VirtualMachineInventorySnapshot {
        try await base.loadVirtualMachineInventory()
    }
}

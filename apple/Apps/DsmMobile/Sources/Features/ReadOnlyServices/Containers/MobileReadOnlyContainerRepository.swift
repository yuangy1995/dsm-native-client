import DsmCore
import Foundation

protocol MobileContainerInventoryReading: Sendable {
    var profileID: UUID { get }
    func loadInventory() async throws -> ContainerInventorySnapshot
}

/// 移动端只持有容器实例清单读取能力，不暴露完整服务管理写方法。
struct MobileReadOnlyContainerRepository: MobileContainerInventoryReading, Sendable {
    let profileID: UUID
    private let base: any ContainerInventoryReading

    init(profileID: UUID, base: any ContainerInventoryReading) {
        self.profileID = profileID
        self.base = base
    }

    func loadInventory() async throws -> ContainerInventorySnapshot {
        try await base.loadContainerInventory()
    }
}

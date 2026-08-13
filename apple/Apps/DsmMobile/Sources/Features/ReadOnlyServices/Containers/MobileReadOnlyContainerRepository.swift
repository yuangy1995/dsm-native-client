import DsmCore
import Foundation

protocol MobileContainerInventoryReading: Sendable {
    var profileID: UUID { get }
    func loadInventory() async throws -> ContainerManagerSnapshot
}

/// 移动端只持有一次完整只读快照能力，不暴露服务管理写方法。
struct MobileReadOnlyContainerRepository: MobileContainerInventoryReading, Sendable {
    let profileID: UUID
    private let loader: @Sendable () async throws -> ContainerManagerSnapshot

    init(profileID: UUID, base: any ServiceManagementRepository) {
        self.profileID = profileID
        loader = { try await base.loadContainerManager() }
    }

    init(
        profileID: UUID,
        loader: @escaping @Sendable () async throws -> ContainerManagerSnapshot
    ) {
        self.profileID = profileID
        self.loader = loader
    }

    func loadInventory() async throws -> ContainerManagerSnapshot {
        try await loader()
    }
}

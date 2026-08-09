import DsmCore
import Foundation

protocol MobileNasHealthReading: Sendable {
    var profileID: UUID { get }

    func loadSystemOverview() async throws -> NasSystemOverview
    func loadPerformanceSnapshot() async throws -> NasPerformanceSnapshot
    func loadStorage() async throws -> NasStorageSnapshot
    func checkSystemUpdate() async throws -> NasSystemUpdateInfo
}

/// 移动端健康页只暴露四项只读查询，不向界面层泄漏管理写操作。
struct MobileReadOnlyNasHealthRepository: MobileNasHealthReading, Sendable {
    let profileID: UUID
    private let base: any NasSettingsRepository

    init(profileID: UUID, base: any NasSettingsRepository) {
        self.profileID = profileID
        self.base = base
    }

    func loadSystemOverview() async throws -> NasSystemOverview {
        try await base.loadSystemOverview()
    }

    func loadPerformanceSnapshot() async throws -> NasPerformanceSnapshot {
        try await base.loadPerformanceSnapshot()
    }

    func loadStorage() async throws -> NasStorageSnapshot {
        try await base.loadStorage()
    }

    func checkSystemUpdate() async throws -> NasSystemUpdateInfo {
        try await base.checkSystemUpdate()
    }
}

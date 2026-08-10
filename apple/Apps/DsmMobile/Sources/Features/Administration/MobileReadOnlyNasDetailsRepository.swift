import DsmCore
import Foundation

protocol MobileNasDetailsReading: Sendable {
    var profileID: UUID { get }

    func loadPackages() async throws -> MobileNasBoundedPage<MobileNasPackageDetail>
    func loadScheduledTasks() async throws -> MobileNasBoundedPage<MobileNasScheduledTaskDetail>
    func loadLogs() async throws -> MobileNasBoundedPage<MobileNasLogDetail>
    func loadConnections() async throws -> MobileNasBoundedPage<MobileNasConnectionDetail>
}

/// 只读适配器在 Repository 边界立即移除账号、地址、日志正文与管理能力字段。
struct MobileReadOnlyNasDetailsRepository: MobileNasDetailsReading, Sendable {
    static let packageLimit = 100
    static let scheduledTaskLimit = 100
    static let pageLimit = 50

    let profileID: UUID
    private let base: any NasSettingsRepository

    init(profileID: UUID, base: any NasSettingsRepository) {
        self.profileID = profileID
        self.base = base
    }

    func loadPackages() async throws -> MobileNasBoundedPage<MobileNasPackageDetail> {
        let values = try await base.loadPackages()
        try Task.checkCancellation()
        let items = values.prefix(Self.packageLimit).enumerated().map { index, value in
            MobileNasPackageDetail(
                id: index,
                name: value.name,
                version: value.version,
                status: MobileNasPackageStatus(value.status)
            )
        }
        return MobileNasBoundedPage(
            items: items,
            total: values.count,
            isTruncated: values.count > items.count
        )
    }

    func loadScheduledTasks() async throws -> MobileNasBoundedPage<MobileNasScheduledTaskDetail> {
        let values = try await base.loadScheduledTasks()
        try Task.checkCancellation()
        let items = values.prefix(Self.scheduledTaskLimit).enumerated().map { index, value in
            MobileNasScheduledTaskDetail(
                id: index,
                name: value.name,
                isEnabled: value.isEnabled,
                nextTriggerDescription: value.nextTriggerDescription
            )
        }
        return MobileNasBoundedPage(
            items: items,
            total: values.count,
            isTruncated: values.count > items.count
        )
    }

    func loadLogs() async throws -> MobileNasBoundedPage<MobileNasLogDetail> {
        let page = try await base.loadLogs(offset: 0, limit: Self.pageLimit)
        try Task.checkCancellation()
        let values = Array(page.entries.prefix(Self.pageLimit))
        let items = values.enumerated().map { index, value in
            MobileNasLogDetail(
                id: index,
                date: value.date,
                source: value.source,
                level: MobileNasLogLevel(value.level)
            )
        }
        let total = max(page.total, page.entries.count)
        return MobileNasBoundedPage(
            items: items,
            total: total,
            isTruncated: total > items.count || page.entries.count > items.count
        )
    }

    func loadConnections() async throws -> MobileNasBoundedPage<MobileNasConnectionDetail> {
        let page = try await base.loadConnections(offset: 0, limit: Self.pageLimit)
        try Task.checkCancellation()
        let values = Array(page.connections.prefix(Self.pageLimit))
        let items = values.enumerated().map { index, value in
            MobileNasConnectionDetail(
                id: index,
                protocolName: value.protocolName,
                type: value.type,
                connectedAt: value.connectedAt,
                isCurrentConnection: value.isCurrentConnection
            )
        }
        let total = max(page.total, page.connections.count)
        return MobileNasBoundedPage(
            items: items,
            total: total,
            isTruncated: total > items.count || page.connections.count > items.count
        )
    }
}

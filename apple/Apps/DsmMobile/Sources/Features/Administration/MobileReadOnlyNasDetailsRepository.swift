import DsmCore
import DsmLocalization
import Foundation

protocol MobileNasDetailsReading: Sendable {
    var profileID: UUID { get }

    func loadPackages() async throws -> MobileNasBoundedPage<MobileNasPackageDetail>
    func loadScheduledTasks() async throws -> MobileNasBoundedPage<MobileNasScheduledTaskDetail>
    func loadLogs(offset: Int, limit: Int) async throws -> MobileNasLogPage
    func loadConnections() async throws -> MobileNasBoundedPage<MobileNasConnectionDetail>
    func loadExternalStorage() async throws -> NasExternalStorageDirectory
    func loadProcesses() async throws -> NasProcessDirectory
    func loadShareAccess() async throws -> NasShareAccessDirectory
    func loadZRAM() async throws -> NasZRAMSnapshot
    func loadPowerSchedule() async throws -> NasPowerScheduleSnapshot
}

/// 只暴露已记录的读取能力；旧摘要保留投影，新增页面复用共享层的字段白名单。
struct MobileReadOnlyNasDetailsRepository: MobileNasDetailsReading, Sendable {
    static let packageLimit = 100
    static let scheduledTaskLimit = 100
    static let pageLimit = 50

    let profileID: UUID
    private let base: any NasSettingsRepository
    private let shareAccess: (any NasShareAccessRepository)?

    init(profileID: UUID, base: any NasSettingsRepository, fileRepository: (any FileRepository)? = nil) {
        self.profileID = profileID
        self.base = base
        self.shareAccess = fileRepository.map { FileStationShareAccessRepository(repository: $0) }
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

    func loadLogs(offset: Int, limit: Int) async throws -> MobileNasLogPage {
        let offset = max(0, offset), limit = min(200, max(1, limit))
        let page = try await base.loadLogs(offset: offset, limit: limit)
        try Task.checkCancellation()
        let items = page.entries.map { value in
            MobileNasLogDetail(id: value.id, date: value.date, source: value.source,
                level: MobileNasLogLevel(value.level), account: value.account, message: value.message)
        }
        return MobileNasLogPage(items: items, offset: offset, limit: limit, total: page.isTotalKnown ? page.total : nil)
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

    func loadExternalStorage() async throws -> NasExternalStorageDirectory {
        try await base.loadExternalStorage()
    }

    func loadProcesses() async throws -> NasProcessDirectory {
        try await base.loadSystemProcesses(start: 0, limit: 500)
    }

    func loadShareAccess() async throws -> NasShareAccessDirectory {
        guard let shareAccess else {
            throw AppError(category: .apiUnavailable, isRetryable: false,
                           safeUserMessage: L10n.string("share-access.unavailable"))
        }
        return try await shareAccess.loadShareAccess()
    }

    func loadZRAM() async throws -> NasZRAMSnapshot {
        try await base.loadZRAM()
    }

    func loadPowerSchedule() async throws -> NasPowerScheduleSnapshot {
        try await base.loadPowerSchedule()
    }
}

import DsmCore
import DsmFileFeature
import Foundation
import Observation
import DsmLocalization

enum NasSettingsPage: String, CaseIterable, Identifiable {
    case overview
    case storage
    case externalStorage
    case zram
    case fileServices
    case terminal
    case network
    case interfaces
    case hardware
    case powerSchedule
    case remoteAccess
    case security
    case region
    case ddns
    case packages
    case tasks
    case accounts
    case shareAccess
    case processes
    case logs
    case connections

    var id: Self { self }
}

struct StorageUsagePoint: Identifiable, Equatable, Sendable {
    let id = UUID()
    let recordedAt: Date
    let volumeID: String
    let volumeName: String
    let usedBytes: Int64
}

actor UnavailableNasAdministrationRepository: NasSettingsRepository {
    private func unavailable() -> AppError {
        AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("ui.45f2d65c5f20a7b9")
        )
    }

    func loadSystemOverview() async throws -> NasSystemOverview { throw unavailable() }
    func loadPerformanceSnapshot() async throws -> NasPerformanceSnapshot { throw unavailable() }
    func loadStorage() async throws -> NasStorageSnapshot { throw unavailable() }
    func loadPackages() async throws -> [NasPackage] { throw unavailable() }
    func loadScheduledTasks() async throws -> [NasScheduledTask] { throw unavailable() }
    func loadAccountsAndGroups() async throws -> NasAccountDirectory { throw unavailable() }
    func loadSystemProcesses(start: Int, limit: Int) async throws -> NasProcessDirectory {
        throw unavailable()
    }
    func loadLogs(offset: Int, limit: Int) async throws -> NasLogPage { throw unavailable() }
    func loadConnections(offset: Int, limit: Int) async throws -> NasConnectionPage { throw unavailable() }
}

@MainActor
@Observable
final class NasSettingsModel {
    var selectedPage: NasSettingsPage = .overview
    var isLiveUpdatesPaused = false

    var logCurrentPage: Int = 1
    var logPageSize: Int = 50

    private(set) var overview: NasSystemOverview?
    private(set) var performanceHistory: [NasPerformanceSnapshot] = []
    private(set) var storage: NasStorageSnapshot?
    private(set) var externalStorage: NasExternalStorageDirectory?
    private(set) var zram: NasZRAMSnapshot?
    private(set) var storageUsageHistory: [StorageUsagePoint] = []
    private(set) var storageAnalysis: StorageAnalysisSnapshot?
    private(set) var storageAnalysisProgress: StorageAnalysisProgress?
    private(set) var storageAnalysisError: String?
    private(set) var isAnalyzingStorage = false
    private(set) var fileServices: NasFileServiceSettings?
    private(set) var terminal: NasTerminalSettings?
    private(set) var proxy: NasProxySettings?
    private(set) var ethernetInterfaces: [NasEthernetInterface] = []
    private(set) var hardware: NasHardwareSettings?
    private(set) var powerSchedule: NasPowerScheduleSnapshot?
    private(set) var remoteAccess: NasRemoteAccessSettings?
    private(set) var security: NasSecuritySettings?
    private(set) var region: NasRegionSettings?
    private(set) var ddns: NasDDNSDirectory?
    private(set) var diskTestStatuses: [String: NasDiskTestStatus] = [:]
    private(set) var packages: [NasPackage] = []
    private(set) var packageCatalog: NasPackageCatalog?
    private(set) var packageCatalogError: String?
    private(set) var isLoadingPackageCatalog = false
    private(set) var isPreparingPackageInstallation = false
    private(set) var isAdvancingPackageInstallation = false
    private(set) var packageInstallPlan: NasPackageInstallPlan?
    private(set) var packageInstallProgress: NasPackageInstallProgress?
    private(set) var packageInstallationError: String?
    @ObservationIgnored private var packageInstallationTask: Task<Void, Never>?
    @ObservationIgnored private var packagePreparationTask: Task<NasPackageInstallPlan, Error>?
    @ObservationIgnored private var packagePreparationGeneration = 0
    @ObservationIgnored private var packageCatalogGeneration = 0

    private(set) var tasks: [NasScheduledTask] = []
    private(set) var accounts: NasAccountDirectory?
    private(set) var shareAccess: NasShareAccessDirectory?
    private(set) var processDirectory: NasProcessDirectory?
    private(set) var logs: NasLogPage?
    private(set) var connections: NasConnectionPage?
    private(set) var packageOperationIDs: Set<String> = []
    private(set) var taskOperationIDs: Set<String> = []
    private(set) var connectionOperationIDs: Set<String> = []
    private(set) var accountOperationIDs: Set<String> = []
    private(set) var diskOperationIDs: Set<String> = []
    private(set) var ddnsOperationIDs: Set<String> = []
    private(set) var networkOperationIDs: Set<String> = []
    private(set) var performanceIsLoading = false
    private(set) var isSavingServiceSettings = false
    private(set) var settingsNeedingRefresh: Set<NasSettingsPage> = []
    private(set) var isPerformingPowerAction = false
    private(set) var isModuleEnabled = false
    private var loadingPages: Set<NasSettingsPage> = []
    private var loadedPages: Set<NasSettingsPage> = []
    private var errors: [NasSettingsPage: String] = [:]

    @ObservationIgnored private let repository: any NasSettingsRepository
    @ObservationIgnored private let storageAnalysisEngine: StorageAnalysisEngine?
    @ObservationIgnored private let shareAccessRepository: (any NasShareAccessRepository)?
    @ObservationIgnored private var storageAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private var requestGenerations: [NasSettingsPage: Int] = [:]
    @ObservationIgnored private var performanceGeneration = 0
    @ObservationIgnored private var diskStatusGenerations: [String: Int] = [:]

    init(
        repository: any NasSettingsRepository = UnavailableNasAdministrationRepository(),
        fileRepository: (any FileRepository)? = nil,
        shareAccessRepository: (any NasShareAccessRepository)? = nil
    ) {
        self.repository = repository
        self.storageAnalysisEngine = fileRepository.map(StorageAnalysisEngine.init(repository:))
        if let shareAccessRepository {
            self.shareAccessRepository = shareAccessRepository
        } else if let fileRepository {
            self.shareAccessRepository = FileStationShareAccessRepository(repository: fileRepository)
        } else {
            self.shareAccessRepository = nil
        }
    }

    func setModuleEnabled(_ enabled: Bool) {
        isModuleEnabled = enabled
        guard !enabled else { return }
        cancelPackageInstallationPreparation()
        packageInstallationTask?.cancel()
        packageInstallationTask = nil
        packageCatalogGeneration += 1
        isLoadingPackageCatalog = false
        performanceGeneration += 1
        for page in NasSettingsPage.allCases {
            requestGenerations[page, default: 0] += 1
        }
        loadingPages.removeAll()
        packageOperationIDs.removeAll()
        taskOperationIDs.removeAll()
        connectionOperationIDs.removeAll()
        accountOperationIDs.removeAll()
        // 已发出的硬盘操作仍持有锁，直到原调用结束，不能通过关开模块重复提交。
        ddnsOperationIDs.removeAll()
        networkOperationIDs.removeAll()
        diskTestStatuses.removeAll()
        storageAnalysisTask?.cancel()
        storageAnalysisTask = nil
        isAnalyzingStorage = false
        storageAnalysisProgress = nil
        storageAnalysisError = nil
        isSavingServiceSettings = false
        isPerformingPowerAction = false
        performanceIsLoading = false
        errors.removeAll()
    }

    func isLoading(_ page: NasSettingsPage) -> Bool {
        loadingPages.contains(page)
    }

    func hasLoaded(_ page: NasSettingsPage) -> Bool {
        loadedPages.contains(page)
    }

    func errorMessage(for page: NasSettingsPage) -> String? {
        errors[page]
    }

    func activate(_ page: NasSettingsPage? = nil, force: Bool = false) async {
        guard isModuleEnabled else { return }
        if let page { selectedPage = page }
        let target = selectedPage
        if !force, loadedPages.contains(target) {
            if target == .overview {
                if performanceHistory.isEmpty {
                    await refreshPerformance()
                }
                if connections == nil {
                    await fetchConnectionsForOverview()
                }
            }
            return
        }

        switch target {
        case .overview:
            await loadOverview(force: force)
            await refreshPerformance(force: force)
            await fetchConnectionsForOverview()
        case .storage:
            await loadPage(.storage, operation: { [repository] in
                try await repository.loadStorage()
            }, apply: { applyStorage($0) })
        case .externalStorage:
            await loadPage(.externalStorage, operation: { [repository] in
                try await repository.loadExternalStorage()
            }, apply: { externalStorage = $0 })
        case .zram:
            await loadPage(.zram, operation: { [repository] in
                try await repository.loadZRAM()
            }, apply: { zram = $0; settingsNeedingRefresh.remove(.zram) })
        case .fileServices:
            await loadPage(.fileServices, operation: { [repository] in
                try await repository.loadFileServiceSettings()
            }, apply: { fileServices = $0 })
        case .terminal:
            await loadPage(.terminal, operation: { [repository] in
                try await repository.loadTerminalSettings()
            }, apply: { terminal = $0 })
        case .network:
            await loadPage(.network, operation: { [repository] in
                try await repository.loadProxySettings()
            }, apply: { proxy = $0 })
        case .interfaces:
            await loadPage(.interfaces, operation: { [repository] in
                try await repository.loadEthernetInterfaces()
            }, apply: { ethernetInterfaces = $0 })
        case .hardware:
            await loadPage(.hardware, operation: { [repository] in
                try await repository.loadHardwareSettings()
            }, apply: { hardware = $0 })
        case .powerSchedule:
            await loadPage(.powerSchedule, operation: { [repository] in
                try await repository.loadPowerSchedule()
            }, apply: { powerSchedule = $0; settingsNeedingRefresh.remove(.powerSchedule) })
        case .remoteAccess:
            await loadPage(.remoteAccess, operation: { [repository] in
                try await repository.loadRemoteAccessSettings()
            }, apply: { remoteAccess = $0 })
        case .security:
            await loadPage(.security, operation: { [repository] in
                try await repository.loadSecuritySettings()
            }, apply: { security = $0 })
        case .region:
            await loadPage(.region, operation: { [repository] in
                try await repository.loadRegionSettings()
            }, apply: { region = $0 })
        case .ddns:
            await loadPage(.ddns, operation: { [repository] in
                try await repository.loadDDNS()
            }, apply: { ddns = $0 })
        case .packages:
            await loadPage(.packages, operation: { [repository] in
                try await repository.loadPackages()
            }, apply: { packages = $0 })
        case .tasks:
            await loadPage(.tasks, operation: { [repository] in
                try await repository.loadScheduledTasks()
            }, apply: { tasks = $0 })
        case .accounts:
            await loadPage(.accounts, operation: { [repository] in
                try await repository.loadAccountsAndGroups()
            }, apply: { accounts = $0 })
        case .shareAccess:
            await loadPage(.shareAccess, operation: { [shareAccessRepository] in
                guard let shareAccessRepository else {
                    throw AppError(
                        category: .apiUnavailable,
                        isRetryable: false,
                        safeUserMessage: L10n.string("share-access.unavailable")
                    )
                }
                return try await shareAccessRepository.loadShareAccess()
            }, apply: { shareAccess = $0 })
        case .processes:
            await loadPage(.processes, operation: { [repository] in
                try await repository.loadSystemProcesses(start: 0, limit: 500)
            }, apply: { processDirectory = $0 })
        case .logs:
            await fetchLogs(page: logCurrentPage, pageSize: logPageSize)
        case .connections:
            await loadPage(.connections, operation: { [repository] in
                try await repository.loadConnections(offset: 0, limit: 300)
            }, apply: { connections = $0 })
        }
    }

    func beginStorageAnalysis() {
        guard isModuleEnabled, !isAnalyzingStorage else { return }
        guard let storageAnalysisEngine else {
            storageAnalysisError = L10n.string("ui.53cce0f955826240")
            return
        }
        storageAnalysisError = nil
        isAnalyzingStorage = true
        storageAnalysisProgress = StorageAnalysisProgress(
            title: L10n.string("ui.9e316eddfe3b16cd"),
            completed: 0,
            total: 0
        )
        storageAnalysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await storageAnalysisEngine.analyze { [weak self] progress in
                    self?.storageAnalysisProgress = progress
                }
                guard !Task.isCancelled else { return }
                storageAnalysis = snapshot
            } catch is CancellationError {
                storageAnalysisError = nil
            } catch let error as AppError {
                switch error.category {
                case .unknown, .invalidResponse:
                    storageAnalysisError = L10n.string("ui.ebf27fffde487252")
                default:
                    storageAnalysisError = error.safeUserMessage
                }
            } catch {
                storageAnalysisError = L10n.string("ui.ebf27fffde487252")
            }
            isAnalyzingStorage = false
            storageAnalysisProgress = nil
            storageAnalysisTask = nil
        }
    }

    func cancelStorageAnalysis() {
        storageAnalysisTask?.cancel()
        storageAnalysisTask = nil
        isAnalyzingStorage = false
        storageAnalysisProgress = nil
    }

    private func applyStorage(_ snapshot: NasStorageSnapshot) {
        let previousDisks = storage?.disks ?? []
        diskTestStatuses = diskTestStatuses.filter { id, _ in
            guard let previous = previousDisks.first(where: { $0.id == id }),
                  let current = snapshot.disks.first(where: { $0.id == id }) else { return false }
            return sameDiskTarget(previous, current)
        }
        storage = snapshot
        let now = Date()
        let points = snapshot.volumes.compactMap { volume -> StorageUsagePoint? in
            guard let used = volume.usedBytes else { return nil }
            return StorageUsagePoint(
                recordedAt: now,
                volumeID: volume.id,
                volumeName: volume.name,
                usedBytes: used
            )
        }
        storageUsageHistory.append(contentsOf: points)
        if storageUsageHistory.count > 120 {
            storageUsageHistory.removeFirst(storageUsageHistory.count - 120)
        }
    }

    func fetchLogs(page: Int? = nil, pageSize: Int? = nil) async {
        if let page { logCurrentPage = max(1, page) }
        if let pageSize { logPageSize = max(10, pageSize) }
        let targetPage = logCurrentPage
        let targetSize = logPageSize
        let offset = (targetPage - 1) * targetSize
        await loadPage(.logs, operation: { [repository] in
            try await repository.loadLogs(offset: offset, limit: targetSize)
        }, apply: { logs = $0 })
    }

    private func fetchConnectionsForOverview() async {
        guard isModuleEnabled else { return }
        if let page = try? await repository.loadConnections(offset: 0, limit: 100) {
            self.connections = page
        }
    }

    func refreshPerformance(force: Bool = false) async {
        guard isModuleEnabled, force || !isLiveUpdatesPaused else { return }
        performanceGeneration += 1
        let generation = performanceGeneration
        performanceIsLoading = performanceHistory.isEmpty
        do {
            let snapshot = try await repository.loadPerformanceSnapshot()
            guard isModuleEnabled, generation == performanceGeneration else { return }
            if performanceHistory.last?.recordedAt != snapshot.recordedAt {
                performanceHistory.append(snapshot)
                if performanceHistory.count > 120 {
                    performanceHistory.removeFirst(performanceHistory.count - 120)
                }
            }
            performanceIsLoading = false
            if overview != nil {
                loadedPages.insert(.overview)
                errors[.overview] = nil
            }
        } catch is CancellationError {
            guard generation == performanceGeneration else { return }
            performanceIsLoading = false
        } catch {
            guard isModuleEnabled, generation == performanceGeneration else { return }
            performanceIsLoading = false
            if overview == nil {
                errors[.overview] = userMessage(for: error, fallback: L10n.string("ui.243c3342118e97c5"))
            }
        }
    }

    private func loadOverview(force: Bool) async {
        if !force, overview != nil { return }
        await loadPage(.overview, operation: { [repository] in
            try await repository.loadSystemOverview()
        }, apply: { overview = $0 })
    }

    private func loadPage<Value: Sendable>(
        _ page: NasSettingsPage,
        operation: @escaping @Sendable () async throws -> Value,
        apply: (Value) -> Void
    ) async {
        requestGenerations[page, default: 0] += 1
        let generation = requestGenerations[page, default: 0]
        loadingPages.insert(page)
        errors[page] = nil
        do {
            let value = try await operation()
            guard isCurrent(page, generation) else { return }
            apply(value)
            loadedPages.insert(page)
            loadingPages.remove(page)
        } catch is CancellationError {
            guard isCurrent(page, generation) else { return }
            loadingPages.remove(page)
        } catch {
            guard isCurrent(page, generation) else { return }
            loadingPages.remove(page)
            if page == .storage { diskTestStatuses.removeAll() }
            errors[page] = userMessage(for: error, fallback: L10n.string("ui.f1217f463299df23"))
        }
    }

    private func isCurrent(_ page: NasSettingsPage, _ generation: Int) -> Bool {
        isModuleEnabled && requestGenerations[page] == generation
    }

    @discardableResult
    func loadDiskTestStatus(diskID: String) async throws -> NasDiskTestStatus {
        guard isModuleEnabled, !isLoading(.storage), errors[.storage] == nil,
              let disk = storage?.disks.first(where: { $0.id == diskID }) else { throw CancellationError() }
        let storageGeneration = requestGenerations[.storage, default: 0]
        diskStatusGenerations[diskID, default: 0] += 1
        let generation = diskStatusGenerations[diskID, default: 0]
        do {
            let status = try await repository.loadDiskTestStatus(diskID: diskID)
            try Task.checkCancellation()
            guard diskContextIsCurrent(disk, storageGeneration: storageGeneration),
                  diskStatusGenerations[diskID] == generation else { throw CancellationError() }
            guard status.diskID == diskID else {
                throw AppError(category: .invalidResponse, isRetryable: false, safeUserMessage: L10n.string("ui.75f623dd62397b99"))
            }
            diskTestStatuses[diskID] = status
            return status
        } catch {
            if diskContextIsCurrent(disk, storageGeneration: storageGeneration), diskStatusGenerations[diskID] == generation {
                diskTestStatuses[diskID] = nil
            }
            throw error
        }
    }

    private func sameDiskTarget(_ left: NasDisk, _ right: NasDisk) -> Bool {
        left.id == right.id && left.deviceID == right.deviceID && left.supportsSmartTest == right.supportsSmartTest
    }

    private func diskContextIsCurrent(_ disk: NasDisk, storageGeneration: Int) -> Bool {
        guard isCurrent(.storage, storageGeneration), errors[.storage] == nil,
              let current = storage?.disks.first(where: { $0.id == disk.id }) else { return false }
        return sameDiskTarget(disk, current)
    }

    func startDiskTest(diskID: String, type: NasDiskTestType) async throws {
        guard isModuleEnabled, !isLoading(.storage), errors[.storage] == nil else { throw CancellationError() }
        guard diskOperationIDs.insert(diskID).inserted else {
            throw AppError(
                category: .serverBusy,
                isRetryable: true,
                safeUserMessage: L10n.string("ui.15311c0dd9419f7e")
            )
        }
        defer { diskOperationIDs.remove(diskID) }
        guard let disk = storage?.disks.first(where: { $0.id == diskID }) else {
            throw AppError(
                category: .notFound,
                isRetryable: true,
                safeUserMessage: L10n.string("ui.75f623dd62397b99")
            )
        }
        guard disk.supportsSmartTest else {
            throw AppError(
                category: .apiUnavailable,
                isRetryable: false,
                safeUserMessage: L10n.string("ui.edb18b7e9cd3b114")
            )
        }

        let storageGeneration = requestGenerations[.storage, default: 0]
        diskStatusGenerations[diskID, default: 0] += 1
        diskTestStatuses[diskID] = nil
        let result = try await repository.startDiskTestResult(
            diskID: diskID,
            type: type
        )
        guard diskContextIsCurrent(disk, storageGeneration: storageGeneration) else { throw CancellationError() }
        if result.requiresRefresh || result.status == .confirmedSuccess {
            _ = try? await loadDiskTestStatus(diskID: diskID)
        }
        guard diskContextIsCurrent(disk, storageGeneration: storageGeneration) else { throw CancellationError() }
        if result.status == .confirmedSuccess || result.status == .cancelledBeforeSubmission { return }
        guard result.status != .cancelledBeforeSubmission else { return }
        throw diskTestError(for: result.status, isStarting: true)
    }

    func stopDiskTest(diskID: String) async throws {
        guard isModuleEnabled, !isLoading(.storage), errors[.storage] == nil,
              let disk = storage?.disks.first(where: { $0.id == diskID }) else { throw CancellationError() }
        guard diskOperationIDs.insert(diskID).inserted else {
            throw AppError(
                category: .serverBusy,
                isRetryable: true,
                safeUserMessage: L10n.string("ui.15311c0dd9419f7e")
            )
        }
        defer { diskOperationIDs.remove(diskID) }
        guard diskTestStatuses[diskID]?.isRunning == true else {
            throw AppError(
                category: .conflict,
                isRetryable: true,
                safeUserMessage: L10n.string("ui.1022d6b5423a7d10")
            )
        }
        let storageGeneration = requestGenerations[.storage, default: 0]
        diskStatusGenerations[diskID, default: 0] += 1
        diskTestStatuses[diskID] = nil
        let result = try await repository.stopDiskTestResult(diskID: diskID)
        guard diskContextIsCurrent(disk, storageGeneration: storageGeneration) else { throw CancellationError() }
        if result.requiresRefresh || result.status == .confirmedSuccess {
            _ = try? await loadDiskTestStatus(diskID: diskID)
        }
        guard diskContextIsCurrent(disk, storageGeneration: storageGeneration) else { throw CancellationError() }
        if result.status == .confirmedSuccess { return }
        guard result.status != .cancelledBeforeSubmission else { return }
        throw diskTestError(for: result.status, isStarting: false)
    }

    struct DiskTestFeedback: Equatable {
        let resourceKey: String
        let category: AppErrorCategory
    }

    static func diskTestFeedback(
        for status: MutationResultStatus,
        isStarting: Bool
    ) -> DiskTestFeedback {
        let prefix = isStarting
            ? "storage.disk-test.start"
            : "storage.disk-test.stop"
        return switch status {
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            DiskTestFeedback(
                resourceKey: "\(prefix).unverified",
                category: .unknown
            )
        case .partialSuccess:
            DiskTestFeedback(
                resourceKey: "\(prefix).unverified",
                category: .partialFailure
            )
        case .permissionDenied:
            DiskTestFeedback(
                resourceKey: "\(prefix).permission-denied",
                category: .permissionDenied
            )
        case .unsupported:
            DiskTestFeedback(
                resourceKey: "\(prefix).unsupported",
                category: .apiUnavailable
            )
        case .confirmedFailure:
            DiskTestFeedback(
                resourceKey: "\(prefix).failed",
                category: .conflict
            )
        case .confirmedSuccess:
            DiskTestFeedback(
                resourceKey: "\(prefix).completed",
                category: .unknown
            )
        case .cancelledBeforeSubmission:
            DiskTestFeedback(
                resourceKey: "\(prefix).cancelled",
                category: .cancelled
            )
        }
    }

    private func diskTestError(
        for status: MutationResultStatus,
        isStarting: Bool
    ) -> AppError {
        let feedback = Self.diskTestFeedback(for: status, isStarting: isStarting)
        return AppError(
            category: feedback.category,
            isRetryable: false,
            safeUserMessage: L10n.string(feedback.resourceKey)
        )
    }

    func loadPackageCenterSettings() async throws -> NasPackageCenterSettings {
        guard isModuleEnabled else { throw packageInstallBusyError() }
        return try await repository.loadPackageCenterSettings()
    }
    func savePackageCenterSettings(_ settings: NasPackageCenterSettings, replacing baseline: NasPackageCenterSettings) async throws -> NasPackageCenterSettings {
        guard isModuleEnabled, !packageInstallationIsBusy, packageOperationIDs.isEmpty else { throw packageInstallBusyError() }
        isPreparingPackageInstallation = true
        defer { isPreparingPackageInstallation = false }
        let result = try await repository.savePackageCenterSettings(settings, replacing: baseline)
        await loadPackageCatalog(force: true)
        return result
    }
    func loadPackageSources() async throws -> [NasPackageSource] {
        guard isModuleEnabled else { throw packageInstallBusyError() }
        return try await repository.loadPackageSources()
    }
    func savePackageSource(_ source: NasPackageSource, replacing baseline: NasPackageSource?) async throws -> [NasPackageSource] {
        guard isModuleEnabled, !packageInstallationIsBusy, packageOperationIDs.isEmpty else { throw packageInstallBusyError() }
        isPreparingPackageInstallation = true
        defer { isPreparingPackageInstallation = false }
        let result = try await repository.savePackageSource(source, replacing: baseline)
        await loadPackageCatalog(force: true)
        return result
    }
    func deletePackageSource(_ source: NasPackageSource) async throws -> [NasPackageSource] {
        guard isModuleEnabled, !packageInstallationIsBusy, packageOperationIDs.isEmpty else { throw packageInstallBusyError() }
        isPreparingPackageInstallation = true
        defer { isPreparingPackageInstallation = false }
        let result = try await repository.deletePackageSource(source)
        await loadPackageCatalog(force: true)
        return result
    }

    var packageInstallationIsBusy: Bool {
        isPreparingPackageInstallation || isAdvancingPackageInstallation
            || packageInstallProgress.map { [.downloading, .installing, .needsOptions, .unverified].contains($0.phase) } == true
    }

    func loadPackageCatalog(force: Bool = false) async {
        guard isModuleEnabled, !isLoadingPackageCatalog, force || packageCatalog == nil else { return }
        packageCatalogGeneration += 1
        let generation = packageCatalogGeneration
        isLoadingPackageCatalog = true
        defer { if generation == packageCatalogGeneration { isLoadingPackageCatalog = false } }
        do {
            let catalog = try await repository.loadPackageCatalog()
            guard isModuleEnabled, generation == packageCatalogGeneration else { return }
            packageCatalog = catalog; packageCatalogError = nil
        } catch {
            guard isModuleEnabled, generation == packageCatalogGeneration else { return }
            packageCatalogError = (error as? AppError)?.safeUserMessage ?? L10n.string("package.center.catalog-failed")
        }
    }

    func preparePackageInstallation(_ ids: [String]) async throws {
        guard isModuleEnabled, !packageInstallationIsBusy, packageOperationIDs.isEmpty else { throw packageInstallBusyError() }
        packagePreparationGeneration += 1
        let generation = packagePreparationGeneration
        isPreparingPackageInstallation = true
        packageInstallPlan = nil
        packageInstallationError = nil
        let task = Task { [repository] in try await repository.preparePackageInstallation(catalogIDs: ids) }
        packagePreparationTask = task
        defer {
            if generation == packagePreparationGeneration {
                packagePreparationTask = nil
                isPreparingPackageInstallation = false
            }
        }
        do {
            let plan = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard generation == packagePreparationGeneration, isModuleEnabled, !Task.isCancelled else { throw CancellationError() }
            packageInstallPlan = plan
        } catch {
            guard generation == packagePreparationGeneration, isModuleEnabled, !Task.isCancelled else { throw CancellationError() }
            throw error
        }
    }

    var canCancelPackagePreparation: Bool { isPreparingPackageInstallation && packagePreparationTask != nil }

    /// 这里只取消只读的安装计划准备；已提交的安装由进度流程继续核对。
    func cancelPackageInstallationPreparation() {
        guard let task = packagePreparationTask else { return }
        packagePreparationGeneration += 1
        task.cancel()
        packagePreparationTask = nil
        packageInstallPlan = nil
        isPreparingPackageInstallation = false
    }

    func discardPackageInstallPlan() { packageInstallPlan = nil }

    func startPackageInstallation(volumes: [String: String], startAfterInstall: Bool) async throws {
        guard isModuleEnabled, !packageInstallationIsBusy, packageOperationIDs.isEmpty, let plan = packageInstallPlan else {
            throw packageInstallBusyError()
        }
        isPreparingPackageInstallation = true
        defer { isPreparingPackageInstallation = false }
        packageInstallationError = nil
        let progress = try await repository.startPackageInstallation(planID: plan.id, volumes: volumes, startAfterInstall: startAfterInstall)
        packageInstallPlan = nil; packageInstallProgress = progress
        monitorPackageInstallation()
    }

    func uploadPackageForInstallation(_ fileURL: URL) async throws {
        guard isModuleEnabled, !packageInstallationIsBusy, packageOperationIDs.isEmpty else { throw packageInstallBusyError() }
        isPreparingPackageInstallation = true
        defer { isPreparingPackageInstallation = false }
        packageInstallationError = nil
        packageInstallProgress = try await repository.uploadPackageForInstallation(fileURL: fileURL)
    }

    func configurePackageInstallation(volumeID: String, startAfterInstall: Bool, licenseAccepted: Bool,
                                      values: [String: NasPackageOptionValue]) async throws {
        guard isModuleEnabled, !isAdvancingPackageInstallation, let progress = packageInstallProgress,
              progress.phase == .needsOptions else { throw packageInstallBusyError() }
        isAdvancingPackageInstallation = true
        defer { isAdvancingPackageInstallation = false }
        packageInstallationError = nil
        packageInstallProgress = try await repository.configurePackageInstallation(id: progress.id, volumeID: volumeID,
            startAfterInstall: startAfterInstall, licenseAccepted: licenseAccepted, values: values)
        monitorPackageInstallation()
    }

    func cancelPackageInstallation() async throws {
        guard isModuleEnabled, !isAdvancingPackageInstallation, let progress = packageInstallProgress else { throw packageInstallBusyError() }
        isAdvancingPackageInstallation = true
        defer { isAdvancingPackageInstallation = false }
        packageInstallProgress = try await repository.cancelPackageInstallation(id: progress.id)
        monitorPackageInstallation()
    }

    func refreshPackageInstallation() async {
        guard isModuleEnabled, !isAdvancingPackageInstallation, let progress = packageInstallProgress else { return }
        isAdvancingPackageInstallation = true
        defer { isAdvancingPackageInstallation = false }
        do {
            packageInstallProgress = try await repository.advancePackageInstallation(id: progress.id)
            packageInstallationError = nil
            if packageInstallProgress?.phase == .completed {
                await loadPage(.packages, operation: { [repository] in
                    try await repository.loadPackages()
                }, apply: { packages = $0 })
                await loadPackageCatalog(force: true)
            }
        } catch {
            packageInstallationError = (error as? AppError)?.safeUserMessage ?? L10n.string("package.center.unverified")
            packageInstallProgress = NasPackageInstallProgress(id: progress.id, packageName: progress.packageName,
                completedCount: progress.completedCount, totalCount: progress.totalCount, phase: .unverified,
                messageKey: "package.center.unverified", canCancel: progress.canCancel)
        }
    }

    func resumePackageInstallationMonitoring() async {
        await refreshPackageInstallation()
        monitorPackageInstallation()
    }

    private func monitorPackageInstallation() {
        packageInstallationTask?.cancel()
        guard packageInstallProgress?.phase.isActive == true else { return }
        packageInstallationTask = Task { [weak self] in
            for _ in 0..<900 {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.isModuleEnabled, self.packageInstallProgress?.phase.isActive == true else { return }
                await self.refreshPackageInstallation()
            }
            guard let self, let progress = self.packageInstallProgress, progress.phase.isActive else { return }
            self.packageInstallProgress = NasPackageInstallProgress(id: progress.id, packageName: progress.packageName,
                completedCount: progress.completedCount, totalCount: progress.totalCount, phase: .unverified,
                messageKey: "package.center.unverified")
        }
    }

    private func packageInstallBusyError() -> AppError {
        AppError(category: .serverBusy, isRetryable: false, safeUserMessage: L10n.string("package.center.busy"))
    }

    func controlPackage(
        id: String,
        action: NasPackageAction
    ) async throws -> MutationResult {
        guard !packageInstallationIsBusy else { throw packageInstallBusyError() }
        guard packageOperationIDs.insert(id).inserted else {
            throw AppError(
                category: .serverBusy,
                isRetryable: true,
                safeUserMessage: L10n.string("ui.313fb64bd1a8f846")
            )
        }
        defer { packageOperationIDs.remove(id) }

        guard let package = packages.first(where: { $0.id == id }) else {
            throw AppError(
                category: .notFound,
                isRetryable: true,
                safeUserMessage: L10n.string("ui.86d86e549eb9d8ba")
            )
        }
        switch action {
        case .start where !package.canStart:
            throw unavailablePackageAction(L10n.string("ui.8763bd51641c4851"))
        case .stop where !package.canStop:
            throw unavailablePackageAction(L10n.string("ui.377e24aef22f6f7c"))
        case .uninstall where !package.canUninstall:
            throw unavailablePackageAction(L10n.string("ui.8e3cf87f70acf631"))
        case .upgrade where !package.canUpgrade:
            throw AppError(
                category: .apiUnavailable,
                isRetryable: false,
                safeUserMessage: L10n.string("ui.40a27587a6302b95")
            )
        default:
            break
        }

        if action == .uninstall {
            let result = try await repository.uninstallPackageResult(id: id)
            if result.requiresRefresh || result.status == .confirmedSuccess {
                await activate(.packages, force: true)
            }
            if packageActionIsVerified(id: id, action: action)
                || result.status == .confirmedSuccess
                || result.status == .cancelledBeforeSubmission {
                return result
            }
            let feedback = Self.packageUninstallFeedback(for: result.status)
            throw AppError(
                category: feedback.category,
                isRetryable: false,
                safeUserMessage: L10n.string(feedback.resourceKey)
            )
        }

        let result = try await repository.controlPackageResult(
            id: id,
            action: action
        )
        if result.requiresRefresh || result.status == .confirmedSuccess {
            await activate(.packages, force: true)
        }
        if result.status == .confirmedSuccess
            || result.status == .cancelledBeforeSubmission {
            return result
        }
        if packageActionIsVerified(id: id, action: action) {
            let prefix = action == .start ? "package.start" : "package.stop"
            return try MutationResult(
                status: .confirmedSuccess,
                operation: action == .start ? "packageStart" : "packageStop",
                submitted: true,
                requiresRefresh: false,
                counts: MutationResultCounts(
                    succeeded: 1,
                    failed: 0,
                    unknown: 0
                ),
                localizationKey: "\(prefix).completed",
                diagnosticTag: "\(prefix).confirmed-after-model-refresh"
            )
        }
        let feedback = Self.packageControlFeedback(
            for: result.status,
            action: action
        )
        throw AppError(
            category: feedback.category,
            isRetryable: false,
            safeUserMessage: L10n.string(feedback.resourceKey)
        )
    }

    struct PackageControlFeedback: Equatable {
        let resourceKey: String
        let category: AppErrorCategory
    }

    static func packageControlFeedback(
        for status: MutationResultStatus,
        action: NasPackageAction
    ) -> PackageControlFeedback {
        let prefix = action == .start ? "package.start" : "package.stop"
        return switch status {
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            PackageControlFeedback(
                resourceKey: "\(prefix).unverified",
                category: .unknown
            )
        case .permissionDenied:
            PackageControlFeedback(
                resourceKey: "package.control.permission-denied",
                category: .permissionDenied
            )
        case .unsupported:
            PackageControlFeedback(
                resourceKey: "package.control.unsupported",
                category: .apiUnavailable
            )
        case .partialSuccess:
            PackageControlFeedback(
                resourceKey: "\(prefix).unverified",
                category: .partialFailure
            )
        case .confirmedFailure:
            PackageControlFeedback(
                resourceKey: "package.control.failed",
                category: .conflict
            )
        case .confirmedSuccess:
            PackageControlFeedback(
                resourceKey: "\(prefix).completed",
                category: .unknown
            )
        case .cancelledBeforeSubmission:
            PackageControlFeedback(
                resourceKey: "package.control.cancelled",
                category: .cancelled
            )
        }
    }

    struct PackageUninstallFeedback: Equatable {
        let resourceKey: String
        let category: AppErrorCategory
    }

    static func packageUninstallFeedback(
        for status: MutationResultStatus
    ) -> PackageUninstallFeedback {
        switch status {
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            PackageUninstallFeedback(
                resourceKey: "package.uninstall.unverified",
                category: .unknown
            )
        case .permissionDenied:
            PackageUninstallFeedback(
                resourceKey: "package.uninstall.permission-denied",
                category: .permissionDenied
            )
        case .unsupported:
            PackageUninstallFeedback(
                resourceKey: "package.uninstall.unsupported",
                category: .apiUnavailable
            )
        case .partialSuccess:
            PackageUninstallFeedback(
                resourceKey: "package.uninstall.unverified",
                category: .partialFailure
            )
        case .confirmedFailure:
            PackageUninstallFeedback(
                resourceKey: "package.uninstall.failed",
                category: .conflict
            )
        case .confirmedSuccess:
            PackageUninstallFeedback(
                resourceKey: "package.uninstall.completed",
                category: .unknown
            )
        case .cancelledBeforeSubmission:
            PackageUninstallFeedback(
                resourceKey: "package.uninstall.cancelled",
                category: .cancelled
            )
        }
    }

    func performPowerAction(
        _ action: NasPowerAction
    ) async throws -> MutationResult {
        guard !isPerformingPowerAction else { throw settingsBusyError() }
        isPerformingPowerAction = true
        defer { isPerformingPowerAction = false }
        return try await repository.performPowerActionResult(action)
    }

    func disconnectConnection(_ connection: NasConnection) async throws {
        guard connectionOperationIDs.insert(connection.id).inserted else {
            throw AppError(
                category: .serverBusy,
                isRetryable: true,
                safeUserMessage: L10n.string("ui.8f73f45bdcbee2b3")
            )
        }
        defer { connectionOperationIDs.remove(connection.id) }

        do { try await repository.disconnectConnection(connection) }
        catch let error as AppError {
            switch error.category {
            case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown, .cancelled:
                throw connectionVerificationError()
            default: throw error
            }
        } catch { throw connectionVerificationError() }
        for attempt in 0..<4 {
            var verified: NasConnectionPage?
            await loadPage(.connections, operation: { [repository] in
                try await repository.loadConnections(offset: 0, limit: 500)
            }, apply: { page in connections = page; verified = page })
            if let verified, verified.connections.count < 500, verified.total <= verified.connections.count,
               !verified.connections.contains(where: { Self.connectionMayRemain($0, target: connection) }) {
                return
            }
            if attempt < 3 {
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { throw connectionVerificationError() }
            }
        }
        throw connectionVerificationError()
    }

    private static func connectionMayRemain(_ current: NasConnection, target: NasConnection) -> Bool {
        let web = target.type?.uppercased() == "HTTP/HTTPS"
        let raw = web ? current.deviceID : current.processID
        let expected = web ? target.deviceID : target.processID
        if expected == nil || raw == expected { return true }
        if raw?.isEmpty == false { return false }
        // 标识缺失的相似条目无法排除，不因派生行 ID 改变就报告已断开。
        return current.account == target.account
            && (current.source == nil || target.source == nil || current.source == target.source)
            && (current.description == nil || target.description == nil || current.description == target.description)
            && (current.connectedAt == nil || target.connectedAt == nil || current.connectedAt == target.connectedAt)
    }

    private func connectionVerificationError() -> AppError {
        AppError(
            category: .invalidResponse,
            isRetryable: false,
            safeUserMessage: L10n.string("ui.f0b77bcbb861e723")
        )
    }

    func loadTaskDraft(_ task: NasScheduledTask?) async throws -> NasScheduledTaskDraft {
        let id = task.flatMap { Int($0.id) }
        if task != nil, id == nil {
            throw AppError(
                category: .invalidResponse,
                isRetryable: true,
                safeUserMessage: L10n.string("ui.06669846e8a043c1")
            )
        }
        return try await repository.loadScheduledTaskDraft(
            id: id,
            realOwner: task?.realOwner
        )
    }

    func loadTaskResults(_ task: NasScheduledTask) async throws -> [NasScheduledTaskResult] {
        try await repository.loadScheduledTaskResults(taskName: task.name)
    }

    func loadTaskResultOutput(
        task: NasScheduledTask,
        resultID: String
    ) async throws -> NasScheduledTaskResultOutput {
        try await repository.loadScheduledTaskResultOutput(
            taskName: task.name,
            resultID: resultID
        )
    }

    func saveTask(_ draft: NasScheduledTaskDraft, baseline: NasScheduledTaskDraft) async throws {
        let operationID = draft.id.map(String.init) ?? "new"
        try beginTaskOperation(operationID)
        defer { taskOperationIDs.remove(operationID) }
        guard draft.id == baseline.id, draft.realOwner == baseline.realOwner,
              !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !draft.script.isEmpty,
              (0...23).contains(draft.schedule.hour), (0...59).contains(draft.schedule.minute) else {
            throw taskVerificationError(submitted: false)
        }
        let currentList = try await repository.loadScheduledTasks()
        if let id = draft.id {
            guard let current = currentList.first(where: { $0.id == String(id) }), current.canEdit, current.type == "script",
                  current.name == baseline.name, current.owner == baseline.owner else { throw taskVerificationError(submitted: false) }
        } else if currentList.contains(where: { $0.name == draft.name.trimmingCharacters(in: .whitespacesAndNewlines) && $0.owner == draft.owner.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            throw taskVerificationError(submitted: false)
        }
        let currentDetail = try await repository.loadScheduledTaskDraft(id: baseline.id, realOwner: baseline.realOwner)
        guard currentDetail == baseline else { throw taskVerificationError(submitted: false) }
        try await executeTaskCommand { try await self.repository.saveScheduledTask(draft) }
        let verified = try await readTaskCommandResult()
        let matches = verified.filter {
            if let id = draft.id { return $0.id == String(id) }
            return $0.name == draft.name.trimmingCharacters(in: .whitespacesAndNewlines) && $0.owner == draft.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard matches.count == 1, let target = matches.first, let id = Int(target.id), target.type == "script" else { throw taskVerificationError() }
        let saved: NasScheduledTaskDraft
        do { saved = try await repository.loadScheduledTaskDraft(id: id, realOwner: target.realOwner) }
        catch { throw taskVerificationError() }
        guard saved.name == draft.name.trimmingCharacters(in: .whitespacesAndNewlines), saved.owner == draft.owner.trimmingCharacters(in: .whitespacesAndNewlines),
              saved.isEnabled == draft.isEnabled, saved.script == draft.script, saved.notifyOnError == draft.notifyOnError,
              saved.notificationEmails == draft.notificationEmails, saved.schedule == draft.schedule else {
            throw taskVerificationError()
        }
    }

    func setTaskEnabled(_ task: NasScheduledTask, enabled: Bool) async throws {
        let id = try taskNumericID(task)
        try beginTaskOperation(task.id)
        defer { taskOperationIDs.remove(task.id) }
        try await prepareTaskCommand(task, running: false)
        guard task.isEnabled != enabled else { throw taskVerificationError(submitted: false) }
        try await executeTaskCommand {
            try await self.repository.setScheduledTaskEnabled(id: id, realOwner: task.realOwner, enabled: enabled)
        }
        let verified = try await readTaskCommandResult()
        guard verified.first(where: { $0.id == task.id && $0.realOwner == task.realOwner })?.isEnabled == enabled else {
            throw taskVerificationError()
        }
    }

    func runTask(_ task: NasScheduledTask) async throws {
        let id = try taskNumericID(task)
        try beginTaskOperation(task.id)
        defer { taskOperationIDs.remove(task.id) }
        try await prepareTaskCommand(task, running: true)
        // 此调用只表示运行请求被接受，脚本是否成功必须另看运行记录。
        try await executeTaskCommand { try await self.repository.runScheduledTask(id: id, realOwner: task.realOwner) }
    }

    func deleteTask(_ task: NasScheduledTask) async throws {
        let id = try taskNumericID(task)
        try beginTaskOperation(task.id)
        defer { taskOperationIDs.remove(task.id) }
        try await prepareTaskCommand(task, running: false)
        try await executeTaskCommand { try await self.repository.deleteScheduledTask(id: id, realOwner: task.realOwner) }
        let verified = try await readTaskCommandResult()
        guard !verified.contains(where: { $0.id == task.id }) else {
            throw taskVerificationError()
        }
    }

    func saveAccount(_ draft: NasAccountDraft) async throws {
        let name = draft.originalName ?? draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseline = draft.originalName.flatMap { original in accounts?.users.first { $0.name == original } }
        let operationID = Self.accountOperationKey(kind: .user, name: name)
        guard accountOperationIDs.insert(operationID).inserted else {
            throw busyAccountError()
        }
        defer { accountOperationIDs.remove(operationID) }
        guard !name.isEmpty, draft.originalName == nil || (draft.name == name && baseline?.canEdit == true),
              draft.originalName != nil || !draft.password.isEmpty,
              (draft.password.isEmpty ? draft.passwordConfirmation.isEmpty : draft.password == draft.passwordConfirmation) else {
            throw accountVerificationError(submitted: false)
        }
        let current = try await prepareDirectoryChange(kind: .user, name: name, baseline: baseline)
        if let groups = draft.groups {
            guard baseline == nil || baseline?.groups != nil, Set(groups).count == groups.count,
                  groups.allSatisfy({ name in current.groups.contains { $0.name == name } }) else {
                throw accountVerificationError(submitted: false)
            }
        }
        if let baseline, draft.password.isEmpty, accountSavedFieldsMatch(baseline, draft, name: name) {
            throw accountVerificationError(submitted: false)
        }
        let verified = try await saveAndReloadDirectory { try await self.repository.saveAccount(draft) }
        guard let saved = verified.users.first(where: { $0.name == name }),
              baseline == nil || saved.numericID == baseline?.numericID,
              accountSavedFieldsMatch(saved, draft, name: name) else {
            throw accountVerificationError()
        }
    }

    func deleteAccount(_ account: NasAccount) async throws {
        guard account.kind == .user, account.canDelete else {
            throw AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("ui.917cb22bc73cc211")
            )
        }
        let operationID = Self.accountOperationKey(kind: .user, name: account.name)
        guard accountOperationIDs.insert(operationID).inserted else {
            throw busyAccountError()
        }
        defer { accountOperationIDs.remove(operationID) }
        let result = try await repository.deleteAccountResult(name: account.name)
        if result.requiresRefresh || result.status == .confirmedSuccess {
            await activate(.accounts, force: true)
        }
        // 目录可能已被其他操作改变，不能覆盖适配器的拒绝或未知结果。
        if result.status == .confirmedSuccess
            || result.status == .cancelledBeforeSubmission {
            return
        }
        throw directoryDeletionError(for: result.status, kind: .user)
    }

    func saveGroup(_ draft: NasGroupDraft) async throws {
        let name = draft.originalName ?? draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseline = draft.originalName.flatMap { original in accounts?.groups.first { $0.name == original } }
        let operationID = Self.accountOperationKey(kind: .group, name: name)
        guard accountOperationIDs.insert(operationID).inserted else {
            throw busyAccountError()
        }
        defer { accountOperationIDs.remove(operationID) }
        guard !name.isEmpty, draft.originalName == nil || (draft.name == name && baseline?.canEdit == true),
              baseline == nil || baseline?.description != draft.description else {
            throw accountVerificationError(submitted: false)
        }
        _ = try await prepareDirectoryChange(kind: .group, name: name, baseline: baseline)
        let verified = try await saveAndReloadDirectory { try await self.repository.saveGroup(draft) }
        guard let saved = verified.groups.first(where: { $0.name == name }),
              baseline == nil || saved.numericID == baseline?.numericID,
              saved.description == draft.description else {
            throw accountVerificationError()
        }
    }

    func deleteGroup(_ group: NasAccount) async throws {
        guard group.kind == .group, group.canDelete else {
            throw AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("ui.966bbfaa2a0d098a")
            )
        }
        let operationID = Self.accountOperationKey(kind: .group, name: group.name)
        guard accountOperationIDs.insert(operationID).inserted else {
            throw busyAccountError()
        }
        defer { accountOperationIDs.remove(operationID) }
        let result = try await repository.deleteGroupResult(name: group.name)
        if result.requiresRefresh || result.status == .confirmedSuccess {
            await activate(.accounts, force: true)
        }
        if result.status == .confirmedSuccess
            || result.status == .cancelledBeforeSubmission {
            return
        }
        throw directoryDeletionError(for: result.status, kind: .group)
    }

    struct DirectoryDeletionFeedback: Equatable {
        let resourceKey: String
        let category: AppErrorCategory
    }

    static func directoryDeletionFeedback(
        for status: MutationResultStatus,
        kind: NasAccount.Kind
    ) -> DirectoryDeletionFeedback {
        let prefix = kind == .group ? "group.delete" : "account.delete"
        return switch status {
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            DirectoryDeletionFeedback(
                resourceKey: "\(prefix).unverified",
                category: .unknown
            )
        case .permissionDenied:
            DirectoryDeletionFeedback(
                resourceKey: "\(prefix).permission-denied",
                category: .permissionDenied
            )
        case .unsupported:
            DirectoryDeletionFeedback(
                resourceKey: "\(prefix).unsupported",
                category: .apiUnavailable
            )
        case .partialSuccess:
            DirectoryDeletionFeedback(
                resourceKey: "\(prefix).unverified",
                category: .partialFailure
            )
        case .confirmedFailure:
            DirectoryDeletionFeedback(
                resourceKey: "\(prefix).failed",
                category: .conflict
            )
        case .confirmedSuccess:
            DirectoryDeletionFeedback(
                resourceKey: "\(prefix).completed",
                category: .unknown
            )
        case .cancelledBeforeSubmission:
            DirectoryDeletionFeedback(
                resourceKey: "\(prefix).cancelled",
                category: .cancelled
            )
        }
    }

    private func directoryDeletionError(
        for status: MutationResultStatus,
        kind: NasAccount.Kind
    ) -> AppError {
        let feedback = Self.directoryDeletionFeedback(for: status, kind: kind)
        return AppError(
            category: feedback.category,
            isRetryable: false,
            safeUserMessage: L10n.string(feedback.resourceKey)
        )
    }

    private func busyAccountError() -> AppError {
        AppError(
            category: .serverBusy,
            isRetryable: true,
            safeUserMessage: L10n.string("ui.588822329fcd7bbd")
        )
    }

    nonisolated static func accountOperationKey(kind: NasAccount.Kind, name: String) -> String {
        "\(kind.rawValue):\(name.lowercased())"
    }

    private func prepareDirectoryChange(kind: NasAccount.Kind, name: String, baseline: NasAccount?) async throws -> NasAccountDirectory {
        let current = try await repository.loadAccountsAndGroups()
        let existing = (kind == .user ? current.users : current.groups).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if let baseline {
            guard let existing, accountSnapshotMatches(existing, baseline) else { throw accountVerificationError(submitted: false) }
        } else if existing != nil { throw accountVerificationError(submitted: false) }
        return current
    }

    private func saveAndReloadDirectory(_ operation: () async throws -> Void) async throws -> NasAccountDirectory {
        do { try await operation() }
        catch let error as AppError {
            switch error.category {
            case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown, .cancelled:
                await activate(.accounts, force: true)
                throw accountVerificationError()
            default: throw error
            }
        } catch {
            await activate(.accounts, force: true)
            throw accountVerificationError()
        }
        var verified: NasAccountDirectory?
        await loadPage(.accounts, operation: { [repository] in
            try await repository.loadAccountsAndGroups()
        }, apply: { directory in
            accounts = directory
            verified = directory
        })
        // 失败或过期的加载不会调用 apply，不能用页面保留的旧列表确认保存。
        guard let verified else { throw accountVerificationError() }
        return verified
    }

    private func accountSnapshotMatches(_ current: NasAccount, _ baseline: NasAccount) -> Bool {
        current.id == baseline.id && current.name == baseline.name && current.kind == baseline.kind
            && current.numericID == baseline.numericID && current.description == baseline.description
            && current.email == baseline.email && current.isExpired == baseline.isExpired
            && current.canEdit == baseline.canEdit && current.canDelete == baseline.canDelete
            && current.groups?.sorted() == baseline.groups?.sorted()
    }

    private func accountSavedFieldsMatch(_ current: NasAccount, _ draft: NasAccountDraft, name: String) -> Bool {
        // 旧领域的停用值不可空；解析器仅在必需字段完整且许可明确时保留可编辑状态。
        current.canEdit && current.name == name && current.description == draft.description && current.email == draft.email
            && current.isExpired == draft.isExpired
            && (draft.groups == nil || current.groups?.sorted() == draft.groups?.sorted())
    }

    private func accountVerificationError(submitted: Bool = true) -> AppError {
        AppError(
            category: submitted ? .unknown : .invalidResponse,
            isRetryable: false,
            safeUserMessage: L10n.string(submitted ? "account.save.unverified" : "account.save.conflict")
        )
    }

    private func beginTaskOperation(_ id: String) throws {
        guard taskOperationIDs.insert(id).inserted else {
            throw AppError(
                category: .serverBusy,
                isRetryable: true,
                safeUserMessage: L10n.string("ui.7fc7c12d022f5692")
            )
        }
    }

    private func taskNumericID(_ task: NasScheduledTask) throws -> Int {
        guard let id = Int(task.id), id >= 0 else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("ui.06669846e8a043c1")
            )
        }
        return id
    }

    private func prepareTaskCommand(_ expected: NasScheduledTask, running: Bool) async throws {
        guard running ? expected.canRun : expected.canEdit else { throw taskVerificationError(submitted: false) }
        let current = try await repository.loadScheduledTasks()
        guard let task = current.first(where: { $0.id == expected.id && $0.realOwner == expected.realOwner }),
              task.name == expected.name, task.owner == expected.owner, task.type == expected.type,
              task.action == expected.action, task.isEnabled == expected.isEnabled, task.canRun == expected.canRun,
              task.canEdit == expected.canEdit else { throw taskVerificationError(submitted: false) }
    }

    private func executeTaskCommand(_ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch let error as AppError {
            switch error.category {
            case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown, .cancelled: throw taskVerificationError()
            default: throw error
            }
        } catch { throw taskVerificationError() }
    }

    private func readTaskCommandResult() async throws -> [NasScheduledTask] {
        var verified: [NasScheduledTask]?
        await loadPage(.tasks, operation: { [repository] in try await repository.loadScheduledTasks() },
            apply: { values in tasks = values; verified = values })
        guard let verified else { throw taskVerificationError() }
        return verified
    }

    private func taskVerificationError(submitted: Bool = true) -> AppError {
        AppError(
            category: submitted ? .unknown : .invalidResponse,
            isRetryable: false,
            safeUserMessage: L10n.string(submitted ? "task.command.unverified" : "task.command.changed")
        )
    }

    func checkSystemUpdate() async throws -> NasSystemUpdateInfo {
        try await repository.checkSystemUpdate()
    }

    func saveFileServices(_ settings: NasFileServiceSettings) async throws {
        guard !isSavingServiceSettings else { throw settingsBusyError() }
        isSavingServiceSettings = true
        defer { isSavingServiceSettings = false }
        let result = try await repository.saveFileServiceSettingsResult(settings)
        if result.requiresRefresh || result.status == .confirmedSuccess {
            await activate(.fileServices, force: true)
        }
        // 页面缓存或偶合的回读不能覆盖适配器的明确拒绝、部分完成及未知结果。
        if result.status == .confirmedSuccess
            || result.status == .cancelledBeforeSubmission {
            return
        }
        let feedback = Self.fileServiceSettingsFeedback(for: result.status)
        throw AppError(
            category: feedback.category,
            isRetryable: false,
            safeUserMessage: L10n.string(
                result.localizationKey ?? feedback.resourceKey
            )
        )
    }

    struct FileServiceSettingsFeedback: Equatable {
        let resourceKey: String
        let category: AppErrorCategory
    }

    static func fileServiceSettingsFeedback(
        for status: MutationResultStatus
    ) -> FileServiceSettingsFeedback {
        switch status {
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            FileServiceSettingsFeedback(
                resourceKey: "file-services.settings.unverified",
                category: .unknown
            )
        case .partialSuccess:
            FileServiceSettingsFeedback(
                resourceKey: "file-services.settings.partial",
                category: .partialFailure
            )
        case .permissionDenied:
            FileServiceSettingsFeedback(
                resourceKey: "file-services.settings.permission-denied",
                category: .permissionDenied
            )
        case .unsupported:
            FileServiceSettingsFeedback(
                resourceKey: "file-services.settings.unsupported",
                category: .apiUnavailable
            )
        case .confirmedFailure:
            FileServiceSettingsFeedback(
                resourceKey: "file-services.settings.failed",
                category: .conflict
            )
        case .confirmedSuccess:
            FileServiceSettingsFeedback(
                resourceKey: "file-services.settings.completed",
                category: .unknown
            )
        case .cancelledBeforeSubmission:
            FileServiceSettingsFeedback(
                resourceKey: "file-services.settings.cancelled",
                category: .cancelled
            )
        }
    }

    func saveTerminal(_ settings: NasTerminalSettings) async throws {
        guard !isSavingServiceSettings else { throw settingsBusyError() }
        isSavingServiceSettings = true
        defer { isSavingServiceSettings = false }
        let result = try await repository.saveTerminalSettingsResult(settings)
        if result.requiresRefresh || result.status == .confirmedSuccess {
            await activate(.terminal, force: true)
        }
        // 页面缓存或偶合的回读不能覆盖适配器的明确拒绝、部分完成及未知结果。
        if result.status == .confirmedSuccess
            || result.status == .cancelledBeforeSubmission {
            return
        }
        let feedback = Self.terminalSettingsFeedback(for: result.status)
        throw AppError(
            category: feedback.category,
            isRetryable: false,
            safeUserMessage: L10n.string(
                result.localizationKey ?? feedback.resourceKey
            )
        )
    }

    struct TerminalSettingsFeedback: Equatable {
        let resourceKey: String
        let category: AppErrorCategory
    }

    static func terminalSettingsFeedback(
        for status: MutationResultStatus
    ) -> TerminalSettingsFeedback {
        switch status {
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            TerminalSettingsFeedback(
                resourceKey: "terminal.settings.unverified",
                category: .unknown
            )
        case .partialSuccess:
            TerminalSettingsFeedback(
                resourceKey: "terminal.settings.partial",
                category: .partialFailure
            )
        case .permissionDenied:
            TerminalSettingsFeedback(
                resourceKey: "terminal.settings.permission-denied",
                category: .permissionDenied
            )
        case .unsupported:
            TerminalSettingsFeedback(
                resourceKey: "terminal.settings.unsupported",
                category: .apiUnavailable
            )
        case .confirmedFailure:
            TerminalSettingsFeedback(
                resourceKey: "terminal.settings.failed",
                category: .conflict
            )
        case .confirmedSuccess:
            TerminalSettingsFeedback(
                resourceKey: "terminal.settings.completed",
                category: .unknown
            )
        case .cancelledBeforeSubmission:
            TerminalSettingsFeedback(
                resourceKey: "terminal.settings.cancelled",
                category: .cancelled
            )
        }
    }

    func saveProxy(_ settings: NasProxySettings) async throws {
        guard !isSavingServiceSettings else { throw settingsBusyError() }
        isSavingServiceSettings = true
        defer { isSavingServiceSettings = false }
        let result = try await repository.saveProxySettingsResult(settings)
        if result.requiresRefresh || result.status == .confirmedSuccess {
            await activate(.network, force: true)
        }
        // 页面缓存或偶合的回读不能覆盖适配器的明确拒绝、部分完成及未知结果。
        if result.status == .confirmedSuccess
            || result.status == .cancelledBeforeSubmission {
            return
        }
        let feedback = Self.proxySettingsFeedback(for: result.status)
        throw AppError(
            category: feedback.category,
            isRetryable: false,
            safeUserMessage: L10n.string(
                result.localizationKey ?? feedback.resourceKey
            )
        )
    }

    struct ProxySettingsFeedback: Equatable {
        let resourceKey: String
        let category: AppErrorCategory
    }

    static func proxySettingsFeedback(
        for status: MutationResultStatus
    ) -> ProxySettingsFeedback {
        switch status {
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            ProxySettingsFeedback(
                resourceKey: "proxy.settings.unverified",
                category: .unknown
            )
        case .partialSuccess:
            ProxySettingsFeedback(
                resourceKey: "proxy.settings.partial",
                category: .partialFailure
            )
        case .permissionDenied:
            ProxySettingsFeedback(
                resourceKey: "proxy.settings.permission-denied",
                category: .permissionDenied
            )
        case .unsupported:
            ProxySettingsFeedback(
                resourceKey: "proxy.settings.unsupported",
                category: .apiUnavailable
            )
        case .confirmedFailure:
            ProxySettingsFeedback(
                resourceKey: "proxy.settings.failed",
                category: .conflict
            )
        case .confirmedSuccess:
            ProxySettingsFeedback(
                resourceKey: "proxy.settings.completed",
                category: .unknown
            )
        case .cancelledBeforeSubmission:
            ProxySettingsFeedback(
                resourceKey: "proxy.settings.cancelled",
                category: .cancelled
            )
        }
    }

    func saveEthernetInterface(_ interface: NasEthernetInterface) async throws {
        let operationID = "network:\(interface.id)"
        guard networkOperationIDs.insert(operationID).inserted else { throw settingsBusyError() }
        defer { networkOperationIDs.remove(operationID) }
        let result = try await repository.saveEthernetInterfaceResult(interface)
        if result.requiresRefresh || result.status == .confirmedSuccess {
            await activate(.interfaces, force: true)
        }
        if result.status == .confirmedSuccess || result.status == .cancelledBeforeSubmission {
            return
        }
        let feedback = Self.ethernetUpdateFeedback(for: result.status)
        throw AppError(
            category: feedback.category,
            isRetryable: false,
            safeUserMessage: L10n.string(feedback.resourceKey)
        )
    }

    struct EthernetUpdateFeedback: Equatable {
        let resourceKey: String
        let category: AppErrorCategory
    }

    static func ethernetUpdateFeedback(
        for status: MutationResultStatus
    ) -> EthernetUpdateFeedback {
        switch status {
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            EthernetUpdateFeedback(
                resourceKey: "network.ethernet.unverified",
                category: .unknown
            )
        case .permissionDenied:
            EthernetUpdateFeedback(
                resourceKey: "network.ethernet.permission-denied",
                category: .permissionDenied
            )
        case .unsupported:
            EthernetUpdateFeedback(
                resourceKey: "network.ethernet.unsupported",
                category: .apiUnavailable
            )
        case .partialSuccess:
            EthernetUpdateFeedback(
                resourceKey: "network.ethernet.unverified",
                category: .partialFailure
            )
        case .confirmedFailure:
            EthernetUpdateFeedback(
                resourceKey: "network.ethernet.failed",
                category: .conflict
            )
        case .confirmedSuccess:
            EthernetUpdateFeedback(
                resourceKey: "network.ethernet.completed",
                category: .unknown
            )
        case .cancelledBeforeSubmission:
            EthernetUpdateFeedback(
                resourceKey: "network.ethernet.cancelled",
                category: .cancelled
            )
        }
    }

    func saveZRAM(enabled: Bool, baseline: NasZRAMSnapshot) async throws {
        guard isModuleEnabled else { throw CancellationError() }
        guard !isSavingServiceSettings, !settingsNeedingRefresh.contains(.zram) else { throw settingsBusyError() }
        isSavingServiceSettings = true
        defer { isSavingServiceSettings = false }
        let result = try await repository.saveZRAMResult(enabled: enabled, replacing: baseline)
        try finishHardwareEdit(result, page: .zram)
        await activate(.zram, force: true)
    }

    func savePowerSchedule(_ entries: [NasPowerScheduleEntry], baseline: NasPowerScheduleSnapshot) async throws {
        guard isModuleEnabled else { throw CancellationError() }
        guard !isSavingServiceSettings, !settingsNeedingRefresh.contains(.powerSchedule) else { throw settingsBusyError() }
        isSavingServiceSettings = true
        defer { isSavingServiceSettings = false }
        let result = try await repository.savePowerScheduleResult(entries, replacing: baseline)
        try finishHardwareEdit(result, page: .powerSchedule)
        await activate(.powerSchedule, force: true)
    }

    private func finishHardwareEdit(_ result: MutationResult, page: NasSettingsPage) throws {
        if result.status == .confirmedSuccess { return }
        if result.submitted { settingsNeedingRefresh.insert(page) }
        throw AppError(category: result.status == .permissionDenied ? .permissionDenied : .unknown,
                       isRetryable: false, safeUserMessage: L10n.string(result.localizationKey ?? "nas.edit.unconfirmed"))
    }

    func saveHardware(_ settings: NasHardwareSettings) async throws {
        guard !isSavingServiceSettings else { throw settingsBusyError() }
        isSavingServiceSettings = true
        defer { isSavingServiceSettings = false }
        let result = try await repository.saveHardwareSettingsResult(settings)
        if result.requiresRefresh || result.status == .confirmedSuccess {
            await activate(.hardware, force: true)
        }
        if hardware == settings
            || result.status == .confirmedSuccess
            || result.status == .cancelledBeforeSubmission {
            return
        }
        let feedback = Self.hardwareSettingsFeedback(for: result.status)
        throw AppError(
            category: feedback.category,
            isRetryable: false,
            safeUserMessage: L10n.string(feedback.resourceKey)
        )
    }

    struct HardwareSettingsFeedback: Equatable {
        let resourceKey: String
        let category: AppErrorCategory
    }

    static func hardwareSettingsFeedback(
        for status: MutationResultStatus
    ) -> HardwareSettingsFeedback {
        switch status {
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            HardwareSettingsFeedback(
                resourceKey: "hardware.settings.unverified",
                category: .unknown
            )
        case .partialSuccess:
            HardwareSettingsFeedback(
                resourceKey: "hardware.settings.partial",
                category: .partialFailure
            )
        case .permissionDenied:
            HardwareSettingsFeedback(
                resourceKey: "hardware.settings.permission-denied",
                category: .permissionDenied
            )
        case .unsupported:
            HardwareSettingsFeedback(
                resourceKey: "hardware.settings.unsupported",
                category: .apiUnavailable
            )
        case .confirmedFailure:
            HardwareSettingsFeedback(
                resourceKey: "hardware.settings.failed",
                category: .conflict
            )
        case .confirmedSuccess:
            HardwareSettingsFeedback(
                resourceKey: "hardware.settings.completed",
                category: .unknown
            )
        case .cancelledBeforeSubmission:
            HardwareSettingsFeedback(
                resourceKey: "hardware.settings.cancelled",
                category: .cancelled
            )
        }
    }

    func saveRemoteAccess(_ settings: NasRemoteAccessSettings) async throws {
        guard isModuleEnabled else { throw CancellationError() }
        guard !isSavingServiceSettings else { throw settingsBusyError() }
        isSavingServiceSettings = true
        defer { isSavingServiceSettings = false }
        let generation = requestGenerations[.remoteAccess, default: 0]
        let result = try await repository.saveRemoteAccessSettingsResult(settings)
        guard isCurrent(.remoteAccess, generation) else { throw CancellationError() }
        if result.requiresRefresh || result.status == .confirmedSuccess {
            let refreshGeneration = requestGenerations[.remoteAccess, default: 0] + 1
            await activate(.remoteAccess, force: true)
            guard isCurrent(.remoteAccess, refreshGeneration) else { throw CancellationError() }
        }
        if result.status == .confirmedSuccess
            || result.status == .cancelledBeforeSubmission {
            return
        }
        let feedback = Self.remoteAccessSettingsFeedback(for: result.status)
        throw AppError(
            category: feedback.category,
            isRetryable: false,
            safeUserMessage: L10n.string(feedback.resourceKey)
        )
    }

    struct RemoteAccessSettingsFeedback: Equatable {
        let resourceKey: String
        let category: AppErrorCategory
    }

    static func remoteAccessSettingsFeedback(
        for status: MutationResultStatus
    ) -> RemoteAccessSettingsFeedback {
        switch status {
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            RemoteAccessSettingsFeedback(
                resourceKey: "remote-access.settings.unverified",
                category: .unknown
            )
        case .partialSuccess:
            RemoteAccessSettingsFeedback(
                resourceKey: "remote-access.settings.partial",
                category: .partialFailure
            )
        case .permissionDenied:
            RemoteAccessSettingsFeedback(
                resourceKey: "remote-access.settings.permission-denied",
                category: .permissionDenied
            )
        case .unsupported:
            RemoteAccessSettingsFeedback(
                resourceKey: "remote-access.settings.unsupported",
                category: .apiUnavailable
            )
        case .confirmedFailure:
            RemoteAccessSettingsFeedback(
                resourceKey: "remote-access.settings.failed",
                category: .conflict
            )
        case .confirmedSuccess:
            RemoteAccessSettingsFeedback(
                resourceKey: "remote-access.settings.completed",
                category: .unknown
            )
        case .cancelledBeforeSubmission:
            RemoteAccessSettingsFeedback(
                resourceKey: "remote-access.settings.cancelled",
                category: .cancelled
            )
        }
    }

    func saveSecurity(_ settings: NasSecuritySettings) async throws {
        guard !isSavingServiceSettings else { throw settingsBusyError() }
        isSavingServiceSettings = true
        defer { isSavingServiceSettings = false }
        let result = try await repository.saveSecuritySettingsResult(settings)
        if result.requiresRefresh || result.status == .confirmedSuccess {
            await activate(.security, force: true)
        }
        if result.status == .confirmedSuccess
            || result.status == .cancelledBeforeSubmission {
            return
        }
        let feedback = Self.securitySettingsFeedback(for: result.status)
        throw AppError(
            category: feedback.category,
            isRetryable: false,
            safeUserMessage: L10n.string(feedback.resourceKey)
        )
    }

    struct SecuritySettingsFeedback: Equatable {
        let resourceKey: String
        let category: AppErrorCategory
    }

    static func securitySettingsFeedback(
        for status: MutationResultStatus
    ) -> SecuritySettingsFeedback {
        switch status {
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            SecuritySettingsFeedback(
                resourceKey: "security.settings.unverified",
                category: .unknown
            )
        case .partialSuccess:
            SecuritySettingsFeedback(
                resourceKey: "security.settings.partial",
                category: .partialFailure
            )
        case .permissionDenied:
            SecuritySettingsFeedback(
                resourceKey: "security.settings.permission-denied",
                category: .permissionDenied
            )
        case .unsupported:
            SecuritySettingsFeedback(
                resourceKey: "security.settings.unsupported",
                category: .apiUnavailable
            )
        case .confirmedFailure:
            SecuritySettingsFeedback(
                resourceKey: "security.settings.failed",
                category: .conflict
            )
        case .confirmedSuccess:
            SecuritySettingsFeedback(
                resourceKey: "security.settings.completed",
                category: .unknown
            )
        case .cancelledBeforeSubmission:
            SecuritySettingsFeedback(
                resourceKey: "security.settings.cancelled",
                category: .cancelled
            )
        }
    }

    func saveRegion(_ settings: NasRegionSettings) async throws {
        guard !isSavingServiceSettings else { throw settingsBusyError() }
        isSavingServiceSettings = true
        defer { isSavingServiceSettings = false }
        let result = try await repository.saveRegionSettingsResult(settings)
        if result.requiresRefresh || result.status == .confirmedSuccess {
            await activate(.region, force: true)
        }
        // 配置匹配不能覆盖校时部分失败，也不能证明手动改时或被拒绝的保存成功。
        if result.status == .confirmedSuccess
            || result.status == .cancelledBeforeSubmission {
            return
        }
        let feedback = Self.regionSettingsFeedback(for: result.status)
        throw AppError(
            category: feedback.category,
            isRetryable: false,
            safeUserMessage: L10n.string(
                result.localizationKey ?? feedback.resourceKey
            )
        )
    }

    struct RegionSettingsFeedback: Equatable {
        let resourceKey: String
        let category: AppErrorCategory
    }

    static func regionSettingsFeedback(
        for status: MutationResultStatus
    ) -> RegionSettingsFeedback {
        switch status {
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            RegionSettingsFeedback(
                resourceKey: "region.settings.unverified",
                category: .unknown
            )
        case .partialSuccess:
            RegionSettingsFeedback(
                resourceKey: "region.settings.partial",
                category: .partialFailure
            )
        case .permissionDenied:
            RegionSettingsFeedback(
                resourceKey: "region.settings.permission-denied",
                category: .permissionDenied
            )
        case .unsupported:
            RegionSettingsFeedback(
                resourceKey: "region.settings.unsupported",
                category: .apiUnavailable
            )
        case .confirmedFailure:
            RegionSettingsFeedback(
                resourceKey: "region.settings.failed",
                category: .conflict
            )
        case .confirmedSuccess:
            RegionSettingsFeedback(
                resourceKey: "region.settings.completed",
                category: .unknown
            )
        case .cancelledBeforeSubmission:
            RegionSettingsFeedback(
                resourceKey: "region.settings.cancelled",
                category: .cancelled
            )
        }
    }

    func testDDNS(_ draft: NasDDNSDraft) async throws -> MutationResult {
        let operationID = draft.normalizedProviderID
        guard !ddnsOperationIDs.contains("refresh"),
              ddnsOperationIDs.insert(operationID).inserted else {
            throw settingsBusyError()
        }
        defer { ddnsOperationIDs.remove(operationID) }
        let result = try await repository.testDDNSResult(draft)
        guard result.status == .confirmedSuccess
                || result.status == .cancelledBeforeSubmission else {
            throw Self.ddnsOperationError(
                result,
                fallbackKey: "ddns.test.failed"
            )
        }
        return result
    }

    func saveDDNS(_ draft: NasDDNSDraft) async throws {
        let operationID = draft.normalizedProviderID
        guard !ddnsOperationIDs.contains("refresh"),
              ddnsOperationIDs.insert(operationID).inserted else {
            throw settingsBusyError()
        }
        defer { ddnsOperationIDs.remove(operationID) }
        let result = try await repository.saveDDNSResult(draft)
        if result.requiresRefresh || result.status == .confirmedSuccess {
            await activate(.ddns, force: true)
        }
        // 列表匹配可能只是旧配置，不能覆盖适配器的拒绝或凭据未确认结果。
        if result.status == .confirmedSuccess
            || result.status == .cancelledBeforeSubmission {
            return
        }
        throw Self.ddnsOperationError(
            result,
            fallbackKey: "ddns.save.failed"
        )
    }

    func deleteDDNS(_ record: NasDDNSRecord) async throws {
        guard !ddnsOperationIDs.contains("refresh"),
              ddnsOperationIDs.insert(record.providerID).inserted else {
            throw settingsBusyError()
        }
        defer { ddnsOperationIDs.remove(record.providerID) }
        let result = try await repository.deleteDDNSResult(
            providerID: record.providerID
        )
        if result.requiresRefresh || result.status == .confirmedSuccess {
            await activate(.ddns, force: true)
        }
        // 记录消失可能来自其他操作，只接受适配器已核对的结果。
        if result.status == .confirmedSuccess
            || result.status == .cancelledBeforeSubmission {
            return
        }
        throw Self.ddnsOperationError(
            result,
            fallbackKey: "ddns.delete.failed"
        )
    }

    func refreshDDNS() async throws {
        guard ddnsOperationIDs.isEmpty else { throw settingsBusyError() }
        ddnsOperationIDs.insert("refresh")
        defer { ddnsOperationIDs.remove("refresh") }
        let result = try await repository.refreshDDNSResult()
        if result.requiresRefresh || result.status == .confirmedSuccess {
            await activate(.ddns, force: true)
        }
        guard result.status == .confirmedSuccess
                || result.status == .cancelledBeforeSubmission else {
            throw Self.ddnsOperationError(
                result,
                fallbackKey: "ddns.refresh.failed"
            )
        }
    }

    private static func ddnsOperationError(
        _ result: MutationResult,
        fallbackKey: String
    ) -> AppError {
        let category: AppErrorCategory = switch result.status {
        case .permissionDenied:
            .permissionDenied
        case .unsupported:
            .apiUnavailable
        case .partialSuccess:
            .partialFailure
        case .cancelledBeforeSubmission, .cancellationRequestedAfterSubmission:
            .cancelled
        case .confirmedSuccess, .confirmedFailure, .submittedButUnverified:
            .unknown
        }
        return AppError(
            category: category,
            isRetryable: false,
            safeUserMessage: L10n.string(
                result.localizationKey ?? fallbackKey
            )
        )
    }

    private func settingsBusyError() -> AppError {
        AppError(
            category: .serverBusy,
            isRetryable: true,
            safeUserMessage: L10n.string("ui.ba90314384daf833")
        )
    }

    private func settingsVerificationError() -> AppError {
        AppError(
            category: .invalidResponse,
            isRetryable: true,
            safeUserMessage: L10n.string("ui.981825780cae2565")
        )
    }

    private func packageActionIsVerified(id: String, action: NasPackageAction) -> Bool {
        guard let package = packages.first(where: { $0.id == id }) else {
            return action == .uninstall
        }
        let status = package.status?.lowercased() ?? ""
        switch action {
        case .start:
            return status == "running" || status == "active"
        case .stop:
            return status != "running" && status != "active"
        case .uninstall:
            return false
        case .upgrade:
            return true
        }
    }

    private func unavailablePackageAction(_ message: String) -> AppError {
        AppError(
            category: .permissionDenied,
            isRetryable: false,
            safeUserMessage: message
        )
    }
}

@MainActor
func userMessage(for error: Error, fallback: String) -> String {
    (error as? AppError)?.safeUserMessage ?? fallback
}

import CryptoKit
import DsmCore
import DsmNetwork
import FileProvider
import Foundation

protocol ProviderRuntimeConfigurationStoring: Sendable {
    func configuration(
        mappingID: UUID
    ) async throws -> DesktopDriveProviderConfiguration?
    func runtime(mappingID: UUID) async throws -> DesktopDriveMappingRuntime
    func registerItemPaths(
        mappingID: UUID,
        remotePaths: [String]
    ) async throws
    func remotePath(
        mappingID: UUID,
        itemIdentifier: String
    ) async throws -> String?
    func changeJournalRevision(
        mappingID: UUID,
        containerIdentifier: String
    ) async throws -> DesktopDriveChangeJournalRevision?
    func refreshChangeJournal(
        mappingID: UUID,
        containerIdentifier: String,
        currentItems: [String: FileItem],
        maximumEntryCount: Int,
        expectedRevision: DesktopDriveChangeJournalRevision?
    ) async throws -> DesktopDriveChangeJournal
    func recordCacheEntry(
        _ entry: DesktopDriveCacheEntry,
        mappingID: UUID
    ) async throws
    func removeCacheEntries(
        remotePaths: [String],
        mappingID: UUID
    ) async throws
    func isProviderAvailable() async throws -> Bool
}

extension DesktopDriveConfigurationStore: ProviderRuntimeConfigurationStoring {}

protocol ProviderRuntimeRepository: Sendable {
    func listShares(offset: Int, limit: Int) async throws -> FilePage
    func listFolder(path: String, offset: Int, limit: Int) async throws -> FilePage
    func getInfo(paths: [String]) async throws -> [FileItem]
    func download(
        remotePath: String,
        to localURL: URL,
        expectedSize: Int64?,
        progress: @escaping FileTransferProgress
    ) async throws
    func removePartialDownload(to localURL: URL) async
}

extension DsmFileRepository: ProviderRuntimeRepository {}

struct ProviderRuntimeDependencies: Sendable {
    var configurationStore: any ProviderRuntimeConfigurationStoring
    var makeRepository: @Sendable (
        DesktopDriveProviderConfiguration
    ) async throws -> any ProviderRuntimeRepository
    var temporaryDirectory: @Sendable (DesktopDriveMapping) throws -> URL
    var ensureCacheSpace: @Sendable (Int64?, URL) throws -> Void
    var evictItem: @Sendable (
        NSFileProviderItemIdentifier,
        DesktopDriveMapping
    ) async throws -> Void
    var removeItem: @Sendable (URL) -> Void
    var capacityRecheckIntervalBytes: Int64
    var changeJournalMaximumEntries: Int

    static func live() -> Self {
        let configurationStore = DesktopDriveConfigurationStore()
        let sessionStore = SharedKeychainSessionStore()
        return .init(
            configurationStore: configurationStore,
            makeRepository: { configuration in
                guard let session: AuthSession = try await sessionStore.load(
                    for: configuration.mapping.profileID
                ) else {
                    throw NSFileProviderError(.notAuthenticated)
                }
                return try DsmFileRepository(
                    profile: configuration.connection.profile,
                    capabilities: configuration.connection.capabilitySet,
                    session: session
                )
            },
            temporaryDirectory: { mapping in
                let domain = ProviderRuntime.domain(for: mapping)
                guard let manager = NSFileProviderManager(for: domain) else {
                    throw NSFileProviderError(.providerNotFound)
                }
                return try manager.temporaryDirectoryURL()
            },
            ensureCacheSpace: ProviderRuntime.ensureCacheSpace,
            evictItem: { identifier, mapping in
                let domain = ProviderRuntime.domain(for: mapping)
                guard let manager = NSFileProviderManager(for: domain) else {
                    throw NSFileProviderError(.providerNotFound)
                }
                try await ProviderRuntime.evictItem(
                    identifier: identifier,
                    manager: manager
                )
            },
            removeItem: { try? FileManager.default.removeItem(at: $0) },
            capacityRecheckIntervalBytes: 8 * 1_024 * 1_024,
            // 仅保留有限增量；更旧锚点交给系统完整重新枚举，避免无限增长。
            changeJournalMaximumEntries: 2_048
        )
    }
}

struct ProviderRequestedVersion: Equatable, Sendable {
    let content: Data
    let metadata: Data
}

struct ProviderChangePage: Sendable {
    let updatedItems: [ProviderItem]
    let deletedItemIdentifiers: [NSFileProviderItemIdentifier]
    let nextAnchor: Data
    let moreComing: Bool
}

private struct ProviderChangeAnchor: Equatable, Sendable {
    private static let prefix = "lanstash-change-v1"

    let containerFingerprint: String
    let generation: UUID
    let revision: Int64

    init?(_ data: Data) {
        guard let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        let components = raw.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0] == Self.prefix,
              !components[1].isEmpty,
              let generation = UUID(uuidString: String(components[2])),
              let revision = Int64(components[3]),
              revision >= 0 else {
            return nil
        }
        containerFingerprint = String(components[1])
        self.generation = generation
        self.revision = revision
    }

    init(
        mappingID: UUID,
        containerIdentifier: String,
        generation: UUID,
        revision: Int64
    ) {
        containerFingerprint = Self.fingerprint(
            mappingID: mappingID,
            containerIdentifier: containerIdentifier
        )
        self.generation = generation
        self.revision = revision
    }

    var rawValue: Data {
        Data(
            "\(Self.prefix)|\(containerFingerprint)|\(generation.uuidString.lowercased())|\(revision)".utf8
        )
    }

    private static func fingerprint(
        mappingID: UUID,
        containerIdentifier: String
    ) -> String {
        var input = Data(mappingID.uuidString.lowercased().utf8)
        input.append(0)
        input.append(contentsOf: containerIdentifier.utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}

actor ProviderRuntime {
    private struct TemporaryReservation {
        let remotePath: String
        let bytes: Int64
    }

    private let mappingID: UUID?
    private let dependencies: ProviderRuntimeDependencies
    private let metadata = DesktopDriveMetadataCoordinator()
    private var temporaryReservations: [UUID: TemporaryReservation] = [:]
    private var temporaryAdmissionIsLocked = false
    private var temporaryAdmissionWaiters: [CheckedContinuation<Void, Never>] = []

    init(mappingIdentifier: String) {
        self.init(
            mappingIdentifier: mappingIdentifier,
            dependencies: .live()
        )
    }

    init(
        mappingIdentifier: String,
        dependencies: ProviderRuntimeDependencies
    ) {
        mappingID = UUID(uuidString: mappingIdentifier)
        self.dependencies = dependencies
    }

    private var configurationStore: any ProviderRuntimeConfigurationStoring {
        dependencies.configurationStore
    }

    func invalidate() async {
        await metadata.invalidate(cancelInFlight: true)
    }

    func item(
        for identifier: NSFileProviderItemIdentifier
    ) async throws -> ProviderItem {
        let context = try await makeContext()
        let runtime = try await configurationStore.runtime(
            mappingID: context.configuration.mapping.id
        )
        if identifier == .rootContainer {
            let rootPath = Self.rootPath(
                for: context.configuration.mapping
            )
            return ProviderItem.root(
                configuration: context.configuration,
                keptOffline: runtime.keepsOffline(rootPath)
            )
        }
        let path = try await remotePath(for: identifier)
        guard let item = try await metadata.item(path: path, loader: {
            try await context.repository.getInfo(paths: [path]).first
        }) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return ProviderItem(
            fileItem: item,
            mapping: context.configuration.mapping,
            keptOffline: runtime.keepsOffline(path)
        )
    }

    func enumerate(
        containerIdentifier: NSFileProviderItemIdentifier,
        offset: Int,
        limit: Int
    ) async throws -> (items: [ProviderItem], nextOffset: Int?) {
        let context = try await makeContext()
        let runtime = try await configurationStore.runtime(
            mappingID: context.configuration.mapping.id
        )
        if containerIdentifier == .workingSet {
            return try await enumerateWorkingSet(
                context: context,
                runtime: runtime,
                offset: offset,
                limit: limit
            )
        }
        let folderPath = Self.isRootContainer(containerIdentifier)
            ? nil
            : try await remotePath(for: containerIdentifier)
        let pageKey = DesktopDriveMetadataCoordinator.PageKey(
            containerIdentifier: containerIdentifier.rawValue,
            offset: offset,
            limit: limit
        )
        let page = try await metadata.page(key: pageKey) {
            if let folderPath {
                return try await context.repository.listFolder(
                    path: folderPath,
                    offset: offset,
                    limit: limit
                )
            }
            switch context.configuration.mapping.scope {
            case .allShares:
                return try await context.repository.listShares(
                    offset: offset,
                    limit: limit
                )
            case .folder(let path):
                return try await context.repository.listFolder(
                    path: path,
                    offset: offset,
                    limit: limit
                )
            }
        }
        try await configurationStore.registerItemPaths(
            mappingID: context.configuration.mapping.id,
            remotePaths: page.items.map(\.path)
        )
        let items = page.items.map {
            ProviderItem(
                fileItem: $0,
                mapping: context.configuration.mapping,
                keptOffline: runtime.keepsOffline($0.path)
            )
        }
        return (
            items,
            page.hasMore ? page.offset + page.items.count : nil
        )
    }

    /// 获取当前目录的持久化增量锚点，并在首次使用时建立完整基线。
    func currentChangeAnchor(
        for containerIdentifier: NSFileProviderItemIdentifier
    ) async throws -> Data {
        let context = try await makeContext()
        let result = try await latestChangeJournal(
            for: containerIdentifier,
            context: context
        )
        return ProviderChangeAnchor(
            mappingID: context.configuration.mapping.id,
            containerIdentifier: result.containerIdentifier,
            generation: result.journal.generation,
            revision: result.journal.currentRevision
        ).rawValue
    }

    /// 从指定锚点开始返回有限批次的目录更新与删除，旧 generation 或被裁剪的锚点
    /// 一律交给 File Provider 执行完整重新枚举。
    func enumerateChanges(
        for containerIdentifier: NSFileProviderItemIdentifier,
        from anchorData: Data,
        limit: Int
    ) async throws -> ProviderChangePage {
        let context = try await makeContext()
        let result = try await latestChangeJournal(
            for: containerIdentifier,
            context: context
        )
        guard let anchor = ProviderChangeAnchor(anchorData),
              anchor == ProviderChangeAnchor(
                mappingID: context.configuration.mapping.id,
                containerIdentifier: result.containerIdentifier,
                generation: result.journal.generation,
                revision: anchor.revision
              ),
              anchor.revision >= result.journal.minimumAnchorRevision,
              anchor.revision <= result.journal.currentRevision else {
            throw NSFileProviderError(.syncAnchorExpired)
        }

        let maximumCount = max(limit, 1)
        let pending = result.journal.entries.filter {
            $0.revision > anchor.revision
        }
        let entries = Array(pending.prefix(maximumCount))
        let runtime = try await configurationStore.runtime(
            mappingID: context.configuration.mapping.id
        )
        var updatedItems: [ProviderItem] = []
        var deletedItemIdentifiers: [NSFileProviderItemIdentifier] = []
        for entry in entries {
            switch entry.kind {
            case .updated:
                guard let item = entry.item else {
                    throw NSFileProviderError(.syncAnchorExpired)
                }
                updatedItems.append(
                    ProviderItem(
                        fileItem: item,
                        mapping: context.configuration.mapping,
                        keptOffline: runtime.keepsOffline(item.path)
                    )
                )
            case .deleted:
                deletedItemIdentifiers.append(
                    NSFileProviderItemIdentifier(entry.itemIdentifier)
                )
            }
        }
        let nextRevision = entries.last?.revision ?? result.journal.currentRevision
        let nextAnchor = ProviderChangeAnchor(
            mappingID: context.configuration.mapping.id,
            containerIdentifier: result.containerIdentifier,
            generation: result.journal.generation,
            revision: nextRevision
        ).rawValue
        return ProviderChangePage(
            updatedItems: updatedItems,
            deletedItemIdentifiers: deletedItemIdentifiers,
            nextAnchor: nextAnchor,
            moreComing: pending.count > entries.count
        )
    }

    func fetchContents(
        for identifier: NSFileProviderItemIdentifier,
        requestedVersion: ProviderRequestedVersion?,
        progress: @escaping FileTransferProgress
    ) async throws -> (URL, ProviderItem) {
        let context = try await makeContext()
        let path = try await remotePath(for: identifier)
        guard let remoteItem = try await metadata.item(path: path, ttl: 0, loader: {
            try await context.repository.getInfo(paths: [path]).first
        }),
              !remoteItem.isDirectory else {
            throw NSFileProviderError(.noSuchItem)
        }
        let providerItem = ProviderItem(
            fileItem: remoteItem,
            mapping: context.configuration.mapping,
            keptOffline: false
        )
        let currentVersion = ProviderRequestedVersion(
            content: providerItem.itemVersion.contentVersion,
            metadata: providerItem.itemVersion.metadataVersion
        )
        if let requestedVersion, requestedVersion != currentVersion {
            throw NSFileProviderError(.versionNoLongerAvailable)
        }
        guard let fileName = DesktopDriveStagingIdentity.contentFileName(
            mappingID: context.configuration.mapping.id,
            remotePath: path,
            sizeBytes: remoteItem.sizeBytes,
            modifiedAt: remoteItem.times?.modifiedAt
        ) else {
            throw NSFileProviderError(.noSuchItem)
        }
        let stagingDirectory = try dependencies.temporaryDirectory(
            context.configuration.mapping
        )
            .appendingPathComponent("LanStashStaging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        let temporaryURL = stagingDirectory
            .appendingPathComponent(fileName, isDirectory: false)
        progress(0, remoteItem.sizeBytes)
        do {
            if try isCompleteFile(
                at: temporaryURL,
                expectedSize: remoteItem.sizeBytes
            ) {
                let temporaryReservation = try await admitTemporaryDownload(
                    mapping: context.configuration.mapping,
                    remotePath: path,
                    incomingBytes: remoteItem.sizeBytes
                )
                defer {
                    if let temporaryReservation {
                        temporaryReservations[temporaryReservation] = nil
                    }
                }
                let result = try await recordMaterializedFile(
                    at: temporaryURL,
                    remoteItem: remoteItem,
                    remotePath: path,
                    configuration: context.configuration
                )
                progress(result.sizeBytes, remoteItem.sizeBytes)
                return (temporaryURL, result.item)
            }
            let temporaryReservation: UUID?
            do {
                try dependencies.ensureCacheSpace(
                    remoteItem.sizeBytes,
                    temporaryURL.deletingLastPathComponent()
                )
                temporaryReservation = try await admitTemporaryDownload(
                    mapping: context.configuration.mapping,
                    remotePath: path,
                    incomingBytes: remoteItem.sizeBytes
                )
            } catch {
                await context.repository.removePartialDownload(to: temporaryURL)
                dependencies.removeItem(temporaryURL)
                throw error
            }
            defer {
                if let temporaryReservation {
                    temporaryReservations[temporaryReservation] = nil
                }
            }
            let monitor = ProviderDownloadCapacityMonitor(
                expectedSize: remoteItem.sizeBytes,
                directory: temporaryURL.deletingLastPathComponent(),
                intervalBytes: dependencies.capacityRecheckIntervalBytes,
                ensureCacheSpace: dependencies.ensureCacheSpace
            )
            let downloadTask = Task {
                try await context.repository.download(
                    remotePath: path,
                    to: temporaryURL,
                    expectedSize: remoteItem.sizeBytes
                ) { completedBytes, totalBytes in
                    monitor.observe(completedBytes: completedBytes)
                    progress(completedBytes, totalBytes)
                }
            }
            monitor.attachCancellation {
                downloadTask.cancel()
            }
            do {
                try await downloadTask.value
                try monitor.throwIfCapacityCheckFailed()
            } catch {
                if let capacityError = monitor.capacityCheckFailure() {
                    await context.repository.removePartialDownload(to: temporaryURL)
                    dependencies.removeItem(temporaryURL)
                    throw capacityError
                }
                throw error
            }
            let result = try await recordMaterializedFile(
                at: temporaryURL,
                remoteItem: remoteItem,
                remotePath: path,
                configuration: context.configuration
            )
            scheduleTemporaryCacheMaintenance(
                mapping: context.configuration.mapping
            )
            return (temporaryURL, result.item)
        } catch {
            if !(error is CancellationError),
               (error as? AppError)?.category != .cancelled {
                dependencies.removeItem(temporaryURL)
            }
            throw error
        }
    }

    private func isCompleteFile(
        at url: URL,
        expectedSize: Int64?
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        guard let expectedSize else {
            return false
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? -1) == expectedSize
    }

    private func recordMaterializedFile(
        at url: URL,
        remoteItem: FileItem,
        remotePath: String,
        configuration: DesktopDriveProviderConfiguration
    ) async throws -> (item: ProviderItem, sizeBytes: Int64) {
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .fileAllocatedSizeKey]
        )
        let actualSize = Int64(values.fileSize ?? 0)
        if let expectedSize = remoteItem.sizeBytes,
           actualSize != expectedSize {
            throw CocoaError(.fileReadCorruptFile)
        }
        let runtime = try await configurationStore.runtime(
            mappingID: configuration.mapping.id
        )
        let entry = DesktopDriveCacheEntry(
            remotePath: remotePath,
            kind: runtime.keepsOffline(remotePath) ? .keptOffline : .temporary,
            logicalSizeBytes: actualSize,
            allocatedSizeBytes: Int64(
                values.fileAllocatedSize ?? values.fileSize ?? 0
            )
        )
        try await configurationStore.recordCacheEntry(
            entry,
            mappingID: configuration.mapping.id
        )
        return (
            ProviderItem(
                fileItem: remoteItem,
                mapping: configuration.mapping,
                keptOffline: runtime.keepsOffline(remotePath)
            ),
            actualSize
        )
    }

    private func scheduleTemporaryCacheMaintenance(
        mapping: DesktopDriveMapping
    ) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.enforceTemporaryCacheLimit(mapping: mapping)
        }
    }

    /// 临时内容只有在驱逐成功且配置记录同步后才允许开始接收。
    private func admitTemporaryDownload(
        mapping: DesktopDriveMapping,
        remotePath: String,
        incomingBytes: Int64?
    ) async throws -> UUID? {
        await acquireTemporaryAdmissionLock()
        defer { releaseTemporaryAdmissionLock() }
        try Task.checkCancellation()

        var runtime = try await configurationStore.runtime(mappingID: mapping.id)
        guard !runtime.keepsOffline(remotePath) else { return nil }
        guard let incomingBytes, incomingBytes >= 0,
              incomingBytes <= mapping.cachePolicy.temporaryLimitBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let reservedBytes = reservedTemporaryBytes()
        let excludedPaths = Set(
            temporaryReservations.values.map(\.remotePath) + [remotePath]
        )
        guard !fitsTemporaryLimit(
            runtime: runtime,
            excludingPaths: excludedPaths,
            reservedBytes: reservedBytes,
            incomingBytes: incomingBytes,
            limitBytes: mapping.cachePolicy.temporaryLimitBytes
        ) else {
            return reserveTemporaryBytes(
                incomingBytes,
                remotePath: remotePath
            )
        }

        let limitWithoutIncoming = mapping.cachePolicy.temporaryLimitBytes
            - incomingBytes
        guard reservedBytes <= limitWithoutIncoming else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let remainingLimit = limitWithoutIncoming - reservedBytes
        let paths = DesktopDriveCacheEvictionPlanner.temporaryPathsToEvict(
            entries: runtime.cacheEntries.values.filter {
                !excludedPaths.contains($0.remotePath)
            },
            limitBytes: remainingLimit
        )
        for path in paths {
            guard let identifier = DesktopDriveItemIdentity.identifier(
                mappingID: mapping.id,
                remotePath: path
            ) else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try await dependencies.evictItem(
                NSFileProviderItemIdentifier(identifier),
                mapping
            )
            // 驱逐与记录删除逐项提交；任一步失败都保守拒绝新下载。
            try await configurationStore.removeCacheEntries(
                remotePaths: [path],
                mappingID: mapping.id
            )
        }

        runtime = try await configurationStore.runtime(mappingID: mapping.id)
        guard !runtime.keepsOffline(remotePath),
              fitsTemporaryLimit(
                runtime: runtime,
                excludingPaths: excludedPaths,
                reservedBytes: reservedBytes,
                incomingBytes: incomingBytes,
                limitBytes: mapping.cachePolicy.temporaryLimitBytes
              ) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        return reserveTemporaryBytes(incomingBytes, remotePath: remotePath)
    }

    private func temporaryBytes(
        in runtime: DesktopDriveMappingRuntime,
        excludingPaths: Set<String> = []
    ) -> Int64 {
        runtime.cacheEntries.values.reduce(Int64(0)) { total, entry in
            guard entry.kind == .temporary,
                  !excludingPaths.contains(entry.remotePath) else {
                return total
            }
            let result = total.addingReportingOverflow(entry.allocatedSizeBytes)
            return result.overflow ? .max : result.partialValue
        }
    }

    private func fitsTemporaryLimit(
        runtime: DesktopDriveMappingRuntime,
        excludingPaths: Set<String>,
        reservedBytes: Int64,
        incomingBytes: Int64,
        limitBytes: Int64
    ) -> Bool {
        let withReservations = temporaryBytes(
            in: runtime,
            excludingPaths: excludingPaths
        )
            .addingReportingOverflow(reservedBytes)
        guard !withReservations.overflow else { return false }
        let withIncoming = withReservations.partialValue
            .addingReportingOverflow(incomingBytes)
        return !withIncoming.overflow && withIncoming.partialValue <= limitBytes
    }

    private func reservedTemporaryBytes() -> Int64 {
        temporaryReservations.values.reduce(Int64(0)) { total, reservation in
            let result = total.addingReportingOverflow(reservation.bytes)
            return result.overflow ? .max : result.partialValue
        }
    }

    private func reserveTemporaryBytes(
        _ bytes: Int64,
        remotePath: String
    ) -> UUID {
        let identifier = UUID()
        temporaryReservations[identifier] = .init(
            remotePath: remotePath,
            bytes: bytes
        )
        return identifier
    }

    /// Actor 在 await 期间可重入，因此驱逐与准入决策需要显式串行化。
    private func acquireTemporaryAdmissionLock() async {
        if !temporaryAdmissionIsLocked {
            temporaryAdmissionIsLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            temporaryAdmissionWaiters.append(continuation)
        }
    }

    private func releaseTemporaryAdmissionLock() {
        guard !temporaryAdmissionWaiters.isEmpty else {
            temporaryAdmissionIsLocked = false
            return
        }
        temporaryAdmissionWaiters.removeFirst().resume()
    }

    private func enforceTemporaryCacheLimit(
        mapping: DesktopDriveMapping
    ) async {
        guard let runtime = try? await configurationStore.runtime(
            mappingID: mapping.id
        ) else {
            return
        }
        let paths = DesktopDriveCacheEvictionPlanner.temporaryPathsToEvict(
            entries: Array(runtime.cacheEntries.values),
            limitBytes: mapping.cachePolicy.temporaryLimitBytes
        )
        guard !paths.isEmpty else { return }
        for path in paths {
            guard let identifier = DesktopDriveItemIdentity.identifier(
                mappingID: mapping.id,
                remotePath: path
            ) else {
                continue
            }
            do {
                try await dependencies.evictItem(
                    NSFileProviderItemIdentifier(identifier),
                    mapping
                )
                try await configurationStore.removeCacheEntries(
                    remotePaths: [path],
                    mappingID: mapping.id
                )
            } catch {
                // 文件可能仍被前台程序占用，保留记录供下一轮维护重试。
            }
        }
    }

    fileprivate static func evictItem(
        identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            manager.evictItem(identifier: identifier) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    fileprivate static func ensureCacheSpace(
        expectedSize: Int64?,
        at directory: URL
    ) throws {
        let values = try directory.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let totalCapacity = values.volumeTotalCapacity,
              let availableCapacity = values.volumeAvailableCapacityForImportantUsage else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let decision = DesktopDriveCacheSpaceCalculator.evaluate(
            candidates: [.init(sizeBytes: expectedSize)],
            volumeCapacityBytes: Int64(totalCapacity),
            availableCapacityBytes: availableCapacity
        )
        guard case .allowed = decision else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    private func latestChangeJournal(
        for containerIdentifier: NSFileProviderItemIdentifier,
        context: (
            configuration: DesktopDriveProviderConfiguration,
            repository: any ProviderRuntimeRepository
        )
    ) async throws -> (
        journal: DesktopDriveChangeJournal,
        containerIdentifier: String
    ) {
        let journalContainerIdentifier = Self.journalContainerIdentifier(
            for: containerIdentifier
        )
        // 最多重扫一次：慢扫描提交时发现较新 revision 后直接丢弃旧快照，重新从
        // 最新基线扫描；连续竞争时安全失败，不能写出倒退的更新或删除事件。
        for attempt in 0...1 {
            let expectedRevision = try await configurationStore.changeJournalRevision(
                mappingID: context.configuration.mapping.id,
                containerIdentifier: journalContainerIdentifier
            )
            let scan: (items: [FileItem], invalidationPaths: [String])
            if containerIdentifier == .workingSet {
                let runtime = try await configurationStore.runtime(
                    mappingID: context.configuration.mapping.id
                )
                let items = try await workingSetItems(
                    context: context,
                    runtime: runtime,
                    persistTrackedItems: false
                )
                scan = (items, items.map(\.path))
            } else {
                let folderPath = try await folderPath(
                    for: containerIdentifier
                )
                let items = try await allItems(
                    in: folderPath,
                    context: context
                )
                scan = (
                    items,
                    [folderPath ?? Self.rootPath(for: context.configuration.mapping)]
                )
            }
            let snapshot = try Self.makeChangeSnapshot(
                from: scan.items,
                mappingID: context.configuration.mapping.id
            )
            do {
                let journal = try await configurationStore.refreshChangeJournal(
                    mappingID: context.configuration.mapping.id,
                    containerIdentifier: journalContainerIdentifier,
                    currentItems: snapshot,
                    maximumEntryCount: dependencies.changeJournalMaximumEntries,
                    expectedRevision: expectedRevision
                )
                if containerIdentifier == .workingSet {
                    try await configurationStore.registerItemPaths(
                        mappingID: context.configuration.mapping.id,
                        remotePaths: scan.items.map(\.path)
                    )
                    await metadata.remember(scan.items)
                }
                // 增量扫描直接读取远端，结果优先于短期元数据缓存。
                if !scan.invalidationPaths.isEmpty {
                    await metadata.invalidate(paths: scan.invalidationPaths)
                }
                return (journal, journalContainerIdentifier)
            } catch let error as DesktopDriveConfigurationStoreError
                where error == .staleChangeJournal && attempt == 0 {
                continue
            }
        }
        throw DesktopDriveConfigurationStoreError.staleChangeJournal
    }

    private func enumerateWorkingSet(
        context: (
            configuration: DesktopDriveProviderConfiguration,
            repository: any ProviderRuntimeRepository
        ),
        runtime: DesktopDriveMappingRuntime,
        offset: Int,
        limit: Int
    ) async throws -> (items: [ProviderItem], nextOffset: Int?) {
        let paths = Self.workingSetPaths(
            runtime: runtime,
            mapping: context.configuration.mapping
        )
        let safeOffset = min(max(offset, 0), paths.count)
        let safeLimit = max(limit, 1)
        let end = min(safeOffset + safeLimit, paths.count)
        let requestedPaths = Array(paths[safeOffset..<end])
        let resolvedItems = try await workingSetItems(
            context: context,
            paths: requestedPaths
        )
        return (
            resolvedItems.map {
                ProviderItem(
                    fileItem: $0,
                    mapping: context.configuration.mapping,
                    keptOffline: runtime.keepsOffline($0.path)
                )
            },
            end < paths.count ? end : nil
        )
    }

    private func workingSetItems(
        context: (
            configuration: DesktopDriveProviderConfiguration,
            repository: any ProviderRuntimeRepository
        ),
        runtime: DesktopDriveMappingRuntime,
        persistTrackedItems: Bool = true
    ) async throws -> [FileItem] {
        try await workingSetItems(
            context: context,
            paths: Self.workingSetPaths(
                runtime: runtime,
                mapping: context.configuration.mapping
            ),
            persistTrackedItems: persistTrackedItems
        )
    }

    private func workingSetItems(
        context: (
            configuration: DesktopDriveProviderConfiguration,
            repository: any ProviderRuntimeRepository
        ),
        paths: [String],
        persistTrackedItems: Bool = true
    ) async throws -> [FileItem] {
        guard !paths.isEmpty else { return [] }
        let requested = Set(paths)
        let returnedItems = try await context.repository.getInfo(paths: paths)
        var resolvedByPath: [String: FileItem] = [:]
        for item in returnedItems {
            guard let normalized = DesktopDrivePath.normalized(item.path),
                  requested.contains(normalized) else {
                continue
            }
            if let previous = resolvedByPath[normalized], previous != item {
                throw NSFileProviderError(.cannotSynchronize)
            }
            resolvedByPath[normalized] = item
        }
        let items = paths.compactMap { resolvedByPath[$0] }
        if persistTrackedItems {
            try await configurationStore.registerItemPaths(
                mappingID: context.configuration.mapping.id,
                remotePaths: items.map(\.path)
            )
            await metadata.remember(items)
        }
        return items
    }

    private func allItems(
        in folderPath: String?,
        context: (
            configuration: DesktopDriveProviderConfiguration,
            repository: any ProviderRuntimeRepository
        )
    ) async throws -> [FileItem] {
        var offset = 0
        var pageCount = 0
        var items: [FileItem] = []
        while true {
            try Task.checkCancellation()
            guard pageCount < 1_000 else {
                throw NSFileProviderError(.cannotSynchronize)
            }
            let page: FilePage
            if let folderPath {
                page = try await context.repository.listFolder(
                    path: folderPath,
                    offset: offset,
                    limit: 500
                )
            } else {
                switch context.configuration.mapping.scope {
                case .allShares:
                    page = try await context.repository.listShares(
                        offset: offset,
                        limit: 500
                    )
                case .folder(let path):
                    page = try await context.repository.listFolder(
                        path: path,
                        offset: offset,
                        limit: 500
                    )
                }
            }
            guard page.offset == offset else {
                throw NSFileProviderError(.cannotSynchronize)
            }
            items.append(contentsOf: page.items)
            guard page.hasMore else { return items }
            let nextOffset = page.offset.addingReportingOverflow(page.items.count)
            guard !nextOffset.overflow, nextOffset.partialValue > offset else {
                throw NSFileProviderError(.cannotSynchronize)
            }
            offset = nextOffset.partialValue
            pageCount += 1
        }
    }

    private func folderPath(
        for containerIdentifier: NSFileProviderItemIdentifier
    ) async throws -> String? {
        guard !Self.isRootContainer(containerIdentifier) else {
            return nil
        }
        return try await remotePath(for: containerIdentifier)
    }

    private static func makeChangeSnapshot(
        from items: [FileItem],
        mappingID: UUID
    ) throws -> [String: FileItem] {
        var snapshot: [String: FileItem] = [:]
        for item in items {
            guard DesktopDrivePath.normalized(item.path) != nil,
                  let identifier = DesktopDriveItemIdentity.identifier(
                    mappingID: mappingID,
                    remotePath: item.path
                  ) else {
                throw NSFileProviderError(.cannotSynchronize)
            }
            if let previous = snapshot[identifier], previous != item {
                throw NSFileProviderError(.cannotSynchronize)
            }
            snapshot[identifier] = item
        }
        return snapshot
    }

    private func makeContext() async throws -> (
        configuration: DesktopDriveProviderConfiguration,
        repository: any ProviderRuntimeRepository
    ) {
        guard let mappingID,
              let configuration = try await configurationStore.configuration(
            mappingID: mappingID
        ) else {
            throw NSFileProviderError(.noSuchItem)
        }
        guard try await configurationStore.isProviderAvailable() else {
            throw NSFileProviderError(.serverUnreachable)
        }
        let runtime = try await configurationStore.runtime(mappingID: mappingID)
        guard !runtime.isManuallyPaused else {
            throw NSFileProviderError(.serverUnreachable)
        }
        let repository = try await dependencies.makeRepository(configuration)
        return (configuration, repository)
    }

    private func remotePath(
        for identifier: NSFileProviderItemIdentifier
    ) async throws -> String {
        guard let mappingID else {
            throw NSFileProviderError(.noSuchItem)
        }
        if let path = try await configurationStore.remotePath(
            mappingID: mappingID,
            itemIdentifier: identifier.rawValue
        ) {
            return path
        }
        // 仅用于迁移开发阶段已经物化的旧标识；新标识始终是不透明摘要。
        let legacyPrefix = "path:"
        guard identifier.rawValue.hasPrefix(legacyPrefix),
              let path = DesktopDrivePath.normalized(
                String(identifier.rawValue.dropFirst(legacyPrefix.count))
              ) else {
            throw NSFileProviderError(.noSuchItem)
        }
        try await configurationStore.registerItemPaths(
            mappingID: mappingID,
            remotePaths: [path]
        )
        return path
    }

    private static func rootPath(
        for mapping: DesktopDriveMapping
    ) -> String {
        switch mapping.scope {
        case .allShares:
            return "/"
        case .folder(let path):
            return DesktopDrivePath.normalized(path) ?? "/"
        }
    }

    /// working set 只返回目前可证明已被系统跟踪的项目：已固定路径和已有本地
    /// 缓存记录。它不触发根目录列表或递归扫描，并且保持有界，防止大 NAS 的
    /// 全量目录被错误当成工作集。
    private static func workingSetPaths(
        runtime: DesktopDriveMappingRuntime,
        mapping: DesktopDriveMapping
    ) -> [String] {
        let pinned = runtime.pinnedPaths.compactMap(DesktopDrivePath.normalized)
            .filter { isWorkingSetPath($0, in: mapping) }
            .sorted()
        let cached = runtime.cacheEntries.values.compactMap {
            entry -> (path: String, lastAccessedAt: Date)? in
            guard let path = DesktopDrivePath.normalized(entry.remotePath),
                  isWorkingSetPath(path, in: mapping) else {
                return nil
            }
            return (path, entry.lastAccessedAt)
        }.sorted {
            if $0.lastAccessedAt == $1.lastAccessedAt {
                return $0.path < $1.path
            }
            return $0.lastAccessedAt > $1.lastAccessedAt
        }.map(\.path)

        var seen = Set<String>()
        var result: [String] = []
        for path in pinned + cached where seen.insert(path).inserted {
            result.append(path)
            if result.count == 500 {
                break
            }
        }
        return result
    }

    private static func isWorkingSetPath(
        _ path: String,
        in mapping: DesktopDriveMapping
    ) -> Bool {
        switch mapping.scope {
        case .allShares:
            return path != "/"
        case .folder(let rootPath):
            guard let root = DesktopDrivePath.normalized(rootPath) else {
                return false
            }
            return path != root && DesktopDrivePath.isAncestorOrSame(root, of: path)
        }
    }

    private static func isRootContainer(
        _ identifier: NSFileProviderItemIdentifier
    ) -> Bool {
        identifier == .rootContainer
    }

    private static func journalContainerIdentifier(
        for identifier: NSFileProviderItemIdentifier
    ) -> String {
        if identifier == .workingSet {
            return NSFileProviderItemIdentifier.workingSet.rawValue
        }
        return isRootContainer(identifier)
            ? NSFileProviderItemIdentifier.rootContainer.rawValue
            : identifier.rawValue
    }

    fileprivate static func domain(
        for mapping: DesktopDriveMapping
    ) -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(
                mapping.providerDomainIdentifier ?? mapping.id.uuidString
            ),
            displayName: mapping.displayName
        )
    }
}

/// 进度回调本身不可抛错，因此记录容量错误并取消实际下载 Task，等待下载返回后再清理。
private final class ProviderDownloadCapacityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedSize: Int64?
    private let directory: URL
    private let intervalBytes: Int64
    private let ensureCacheSpace: @Sendable (Int64?, URL) throws -> Void
    private var nextCheckBytes: Int64
    private var failure: Error?
    private var cancelDownload: (@Sendable () -> Void)?

    init(
        expectedSize: Int64?,
        directory: URL,
        intervalBytes: Int64,
        ensureCacheSpace: @escaping @Sendable (Int64?, URL) throws -> Void
    ) {
        self.expectedSize = expectedSize
        self.directory = directory
        self.intervalBytes = max(intervalBytes, 1)
        self.ensureCacheSpace = ensureCacheSpace
        nextCheckBytes = max(intervalBytes, 1)
    }

    func attachCancellation(_ action: @escaping @Sendable () -> Void) {
        let shouldCancel = lock.withLock {
            cancelDownload = action
            return failure != nil
        }
        if shouldCancel {
            action()
        }
    }

    func observe(completedBytes: Int64) {
        let shouldCheck = lock.withLock { () -> Bool in
            guard failure == nil, completedBytes >= nextCheckBytes else {
                return false
            }
            let completedIntervals = completedBytes / intervalBytes
            nextCheckBytes = (completedIntervals + 1) * intervalBytes
            return true
        }
        guard shouldCheck else { return }

        do {
            let remainingBytes = expectedSize.map {
                max($0 - max(completedBytes, 0), 0)
            }
            try ensureCacheSpace(remainingBytes, directory)
        } catch {
            let cancellation = lock.withLock {
                if failure == nil {
                    failure = error
                }
                return cancelDownload
            }
            cancellation?()
        }
    }

    func capacityCheckFailure() -> Error? {
        lock.withLock { failure }
    }

    func throwIfCapacityCheckFailed() throws {
        if let failure = capacityCheckFailure() {
            throw failure
        }
    }
}

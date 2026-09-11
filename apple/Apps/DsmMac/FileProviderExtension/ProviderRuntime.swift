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
    func validateWritebackState(mappingID: UUID) async throws
    func relocateItemPaths(mappingID: UUID, source: String, destination: String) async throws
    func removeDeletedItemPaths(mappingID: UUID, remotePath: String, maximumEntryCount: Int) async throws
}

extension ProviderRuntimeConfigurationStoring {
    func validateWritebackState(mappingID: UUID) async throws {
        throw DesktopDriveWritebackError.disabled
    }
    func relocateItemPaths(mappingID: UUID, source: String, destination: String) async throws {
        throw DesktopDriveWritebackError.disabled
    }
    func removeDeletedItemPaths(mappingID: UUID, remotePath: String, maximumEntryCount: Int) async throws {
        throw DesktopDriveWritebackError.disabled
    }
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

protocol ProviderWritebackRepository: ProviderRuntimeRepository {
    func upload(localURL: URL, to folderPath: String, overwrite: Bool, progress: @escaping FileTransferProgress) async throws
    func createFolderResult(parentPath: String, name: String) async throws -> FileItemMutationOutcome
    func renameResult(path: String, newName: String) async throws -> FileItemMutationOutcome
    func copyMoveResult(_ request: FileCopyMoveRequest, progress: @escaping FileTransferProgress) async throws -> FileCopyMoveOutcome
    func deleteResult(paths: [String], recursive: Bool, progress: @escaping FileTransferProgress) async throws -> MutationResult
}

extension DsmFileRepository: ProviderWritebackRepository {}

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
    var writebackStore: DesktopDriveWritebackStore = .init()
    var writebackAvailable: Bool = DesktopDriveWritebackAvailability.isEnabled
    var waitForChildren: @Sendable (NSFileProviderItemIdentifier, DesktopDriveMapping) async throws -> Void = { _, _ in }
    var signalDeletion: @Sendable (DesktopDriveMapping) async throws -> Void = { _ in }

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
            changeJournalMaximumEntries: 2_048,
            waitForChildren: { identifier, mapping in
                guard let manager = NSFileProviderManager(for: ProviderRuntime.domain(for: mapping)) else {
                    throw NSFileProviderError(.providerNotFound)
                }
                try await manager.waitForChanges(below: identifier)
            },
            signalDeletion: { mapping in
                guard let manager = NSFileProviderManager(for: ProviderRuntime.domain(for: mapping)) else {
                    throw NSFileProviderError(.providerNotFound)
                }
                try await manager.signalEnumerator(for: .workingSet)
                try await manager.signalEnumerator(for: .rootContainer)
            }
        )
    }
}

struct ProviderRequestedVersion: Equatable, Sendable {
    let content: Data
    let metadata: Data
}

struct ProviderImportedItemTemplate: Sendable {
    let identifier: NSFileProviderItemIdentifier
    let parentIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let isDirectory: Bool

    init(item: NSFileProviderItem) {
        identifier = item.itemIdentifier
        parentIdentifier = item.parentItemIdentifier
        filename = item.filename
        isDirectory = item.contentType == .folder
    }

    init(identifier: NSFileProviderItemIdentifier, parentIdentifier: NSFileProviderItemIdentifier,
         filename: String, isDirectory: Bool) {
        self.identifier = identifier
        self.parentIdentifier = parentIdentifier
        self.filename = filename
        self.isDirectory = isDirectory
    }
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
        // 系统注册/恢复挂载时先索取根项目。根项目仅来自本地配置，不能依赖
        // 登录会话或网络就绪；真实目录与文件仍通过 makeContext 检查访问条件。
        if identifier == .rootContainer {
            return try await rootItem()
        }
        let context = try await makeContext()
        let runtime = try await configurationStore.runtime(
            mappingID: context.configuration.mapping.id
        )
        let path = try await remotePath(for: identifier)
        guard let item = try await metadata.item(path: path, loader: {
            try await context.repository.getInfo(paths: [path]).first
        }) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return ProviderItem(
            fileItem: item,
            mapping: context.configuration.mapping,
            keptOffline: runtime.keepsOffline(path),
            identifiersByPath: context.configuration.itemIdentifiersByPath,
            writable: isWritebackEnabled(context.configuration),
            deletable: isDeletionEnabled(context.configuration)
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
        let currentIdentifiers = try await configuration().itemIdentifiersByPath
        let items = page.items.map {
            ProviderItem(
                fileItem: $0,
                mapping: context.configuration.mapping,
                keptOffline: runtime.keepsOffline($0.path),
                identifiersByPath: currentIdentifiers,
                writable: isWritebackEnabled(context.configuration),
                deletable: isDeletionEnabled(context.configuration)
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
        let currentIdentifiers = try await configuration().itemIdentifiersByPath
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
                        keptOffline: runtime.keepsOffline(item.path),
                        identifiersByPath: currentIdentifiers,
                        writable: isWritebackEnabled(context.configuration),
                        deletable: isDeletionEnabled(context.configuration)
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

    func itemForImportedSystemItem(
        _ template: ProviderImportedItemTemplate
    ) async throws -> ProviderItem? {
        if template.identifier == .trashContainer {
            return ProviderItem.trashContainer()
        }
        guard template.identifier == .rootContainer else {
            return nil
        }
        return try await rootItem()
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
            keptOffline: false,
            identifiersByPath: context.configuration.itemIdentifiersByPath,
            writable: isWritebackEnabled(context.configuration),
            deletable: isDeletionEnabled(context.configuration)
        )
        let currentVersion = ProviderRequestedVersion(
            content: providerItem.itemVersion.contentVersion,
            metadata: providerItem.itemVersion.metadataVersion
        )
        if let requestedVersion, requestedVersion.content != currentVersion.content {
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
                keptOffline: runtime.keepsOffline(remotePath),
                identifiersByPath: configuration.itemIdentifiersByPath,
                writable: isWritebackEnabled(configuration),
                deletable: isDeletionEnabled(configuration)
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
            try await configurationStore.registerItemPaths(mappingID: context.configuration.mapping.id, remotePaths: scan.items.map(\.path))
            let snapshot = try Self.makeChangeSnapshot(
                from: scan.items,
                mappingID: context.configuration.mapping.id,
                identifiersByPath: try await configuration().itemIdentifiersByPath
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
        let currentIdentifiers = try await configuration().itemIdentifiersByPath
        return (
            resolvedItems.map {
                ProviderItem(
                    fileItem: $0,
                    mapping: context.configuration.mapping,
                    keptOffline: runtime.keepsOffline($0.path),
                    identifiersByPath: currentIdentifiers,
                    writable: isWritebackEnabled(context.configuration),
                    deletable: isDeletionEnabled(context.configuration)
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
        mappingID: UUID,
        identifiersByPath: [String: String] = [:]
    ) throws -> [String: FileItem] {
        var snapshot: [String: FileItem] = [:]
        for item in items {
            guard DesktopDrivePath.normalized(item.path) != nil,
                  let identifier = identifiersByPath[item.path] ?? DesktopDriveItemIdentity.identifier(
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

    private func isWritebackEnabled(_ configuration: DesktopDriveProviderConfiguration) -> Bool {
        guard dependencies.writebackAvailable else { return false }
        return (try? dependencies.writebackStore.isEnabled(mappingID: configuration.mapping.id)) == true
    }

    private func isDeletionEnabled(_ configuration: DesktopDriveProviderConfiguration) -> Bool {
        dependencies.writebackAvailable &&
            (try? dependencies.writebackStore.isDeletionEnabled(mappingID: configuration.mapping.id)) == true
    }

    /// 主 App 不参与上传；系统重复回调复用同一收据，提交结果不明时只回读，不重放。
    func writeItem(_ template: ProviderImportedItemTemplate, baseVersion: ProviderRequestedVersion?,
                   contents: URL?, creating: Bool, progress: @escaping FileTransferProgress) async throws -> ProviderItem {
        guard let mappingID, dependencies.writebackAvailable else { throw DesktopDriveWritebackError.disabled }
        if !creating && template.isDirectory {
            try await dependencies.waitForChildren(template.identifier, configuration().mapping)
        }
        let journal = dependencies.writebackStore
        let lease = try journal.lock(mappingID: mappingID)
        defer { withExtendedLifetime(lease) {} }
        try await configurationStore.validateWritebackState(mappingID: mappingID)
        let context = try await makeContext()
        guard try journal.isEnabled(mappingID: mappingID),
              let repository = context.repository as? any ProviderWritebackRepository else {
            throw DesktopDriveWritebackError.disabled
        }
        let root = Self.rootPath(for: context.configuration.mapping)
        let runtime = try await configurationStore.runtime(mappingID: mappingID)
        guard ![.removing, .recoveryRequired, .failed].contains(runtime.state) else { throw DesktopDriveWritebackError.disabled }
        guard template.identifier != .rootContainer, template.identifier != .trashContainer,
              DesktopDriveWritebackStore.validFilename(template.filename), template.filename != "#recycle" else {
            throw DesktopDriveWritebackError.invalidItem
        }
        let parent = template.parentIdentifier == .rootContainer ? root : try await remotePath(for: template.parentIdentifier)
        let destination = (parent as NSString).appendingPathComponent(template.filename)
        let source = creating ? nil : try await remotePath(for: template.identifier)
        for path in [source, destination].compactMap({ $0 }) {
            guard DesktopDrivePath.normalized(path) == path, path != root,
                  path.split(separator: "/").count > 1,
                  DesktopDrivePath.isAncestorOrSame(root, of: path), !path.split(separator: "/").contains("#recycle") else {
                throw DesktopDriveWritebackError.invalidItem
            }
        }
        if let source, source.split(separator: "/").first != destination.split(separator: "/").first {
            throw DesktopDriveWritebackError.invalidItem
        }
        if let source, template.isDirectory, DesktopDrivePath.isAncestorOrSame(source, of: parent) {
            throw DesktopDriveWritebackError.invalidItem
        }
        let hash = try contents.map(DesktopDriveWritebackStore.hash(of:)) ??
            (creating && !template.isDirectory ? SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined() : nil)
        let size = try contents.map { Int64(try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) } ??
            (hash != nil ? 0 : nil)
        let comparableBase = baseVersion.flatMap {
            $0.metadata.starts(with: Data("metadata:".utf8)) ? $0.content : nil
        }
        let previous = try journal.records(mappingID: mappingID).last {
            !$0.isDeletion && $0.itemIdentifier == template.identifier.rawValue && $0.destinationPath == destination &&
                $0.contentHash == hash && ($0.baseContentVersion == comparableBase || $0.phase != .verified)
        }
        var record = try previous ?? journal.prepare(.init(mappingID: mappingID, itemIdentifier: template.identifier.rawValue,
                                              sourcePath: source, destinationPath: destination,
                                              isDirectory: template.isDirectory, contentHash: hash, contentSize: size,
                                              baseContentVersion: comparableBase), contents: contents)
        if record.phase == .verified, let item = record.verifiedItem { return try await writebackItem(item) }
        if record.phase == .keptLocally { throw DesktopDriveWritebackError.keptLocally }
        if record.phase == .conflict { throw DesktopDriveWritebackError.conflict }
        let userApprovedOverwrite = record.allowOverwrite

        func info(_ path: String) async throws -> FileItem? {
            try await repository.getInfo(paths: [path]).first(where: { $0.path == path })
        }
        guard let parentItem = try await info(parent), parentItem.isDirectory,
              parentItem.permissions?.canWrite != false, parentItem.mountPointType == nil else {
            throw CocoaError(.fileWriteNoPermission)
        }

        if let source = record.sourcePath, record.step == 0, record.phase == .prepared {
            guard let current = try await info(source), current.isDirectory == template.isDirectory,
                  current.kind == .file || current.kind == .directory, current.mountPointType == nil else {
                throw DesktopDriveWritebackError.invalidItem
            }
            guard current.permissions?.canWrite != false else { throw CocoaError(.fileWriteNoPermission) }
            // 既有 File Station 的内容版本是时间/大小快照，不冒充 Drive 的历史版本号。
            if !userApprovedOverwrite, let base = record.baseContentVersion {
                guard current.times?.modifiedAt != nil, current.sizeBytes != nil else {
                    throw DesktopDriveWritebackError.outcomeUnknown
                }
                let currentItem = ProviderItem(fileItem: current, mapping: context.configuration.mapping, keptOffline: false)
                if base != currentItem.itemVersion.contentVersion {
                    record.phase = .conflict
                    try journal.save(record)
                    throw DesktopDriveWritebackError.conflict
                }
            }
        }

        var paths: [(from: String, to: String, move: Bool)] = []
        if let source = record.sourcePath, source != destination {
            let oldParent = (source as NSString).deletingLastPathComponent
            let oldName = (source as NSString).lastPathComponent
            let intermediate = (parent as NSString).appendingPathComponent(oldName)
            if oldParent != parent { paths.append((source, intermediate, true)) }
            if intermediate != destination { paths.append((oldParent == parent ? source : intermediate, destination, false)) }
        }
        for (step, change) in paths.enumerated() where record.step <= step {
            if record.phase == .submitted {
                // 用户明确核对后，仅接受“源已消失且目标存在”的已完成移动；不覆盖同名目标。
                if userApprovedOverwrite, try await info(change.from) == nil,
                   let moved = try await info(change.to), moved.isDirectory == record.isDirectory {
                    try await configurationStore.relocateItemPaths(mappingID: mappingID, source: change.from, destination: change.to)
                    record.step = step + 1
                    record.phase = .prepared
                    try journal.save(record)
                    continue
                }
                if userApprovedOverwrite, try await info(change.from) != nil, try await info(change.to) == nil {
                    record.phase = .prepared
                } else { throw DesktopDriveWritebackError.outcomeUnknown }
            }
            guard let item = try await info(change.from), try await info(change.to) == nil else {
                record.phase = .conflict
                try journal.save(record)
                throw DesktopDriveWritebackError.conflict
            }
            record.phase = .submitted
            record.allowOverwrite = false
            try journal.save(record)
            let result: MutationResult
            if change.move {
                result = try await repository.copyMoveResult(.init(profileID: item.profileID, operation: .move,
                    source: item, destinationFolderPath: (change.to as NSString).deletingLastPathComponent,
                    overwrite: false), progress: progress).result
            } else {
                result = try await repository.renameResult(path: change.from, newName: (change.to as NSString).lastPathComponent).result
            }
            guard result.status == .confirmedSuccess else {
                if !result.submitted { record.phase = .prepared; try journal.save(record) }
                throw DesktopDriveWritebackError.outcomeUnknown
            }
            try await configurationStore.registerItemPaths(mappingID: mappingID, remotePaths: [change.from])
            try await configurationStore.relocateItemPaths(mappingID: mappingID, source: change.from, destination: change.to)
            record.step = step + 1
            record.phase = .prepared
            try journal.save(record)
        }

        if creating && template.isDirectory {
            let existing = try await info(destination)
            if record.phase == .submitted && !userApprovedOverwrite { throw DesktopDriveWritebackError.outcomeUnknown }
            if userApprovedOverwrite, existing?.isDirectory == true {
                // 用户已检查，接纳此次创建留下的目录，不重复创建。
            } else {
                guard existing == nil else { throw DesktopDriveWritebackError.conflict }
                record.phase = .submitted
                record.allowOverwrite = false
                try journal.save(record)
                let result = try await repository.createFolderResult(parentPath: parent, name: template.filename).result
                guard result.status == .confirmedSuccess else {
                    if !result.submitted { record.phase = .prepared; try journal.save(record) }
                    throw DesktopDriveWritebackError.outcomeUnknown
                }
            }
        } else if hash != nil {
            var verified = false
            if record.phase == .submitted {
                verified = try await verifyUploadedContent(record, repository: repository)
                if !verified && !userApprovedOverwrite { throw DesktopDriveWritebackError.outcomeUnknown }
            }
            if !verified {
                if creating && !userApprovedOverwrite, try await info(destination) != nil {
                    record.phase = .conflict
                    try journal.save(record)
                    throw DesktopDriveWritebackError.conflict
                }
                try Task.checkCancellation()
                record.phase = .submitted
                record.allowOverwrite = false
                try journal.save(record)
                try await repository.upload(localURL: journal.contentURL(for: record), to: parent,
                                            overwrite: !creating || userApprovedOverwrite, progress: progress)
                // 不覆盖上传可能被 NAS 当成“跳过”；完整内容核对也用于提交响应丢失后的恢复。
                guard try await verifyUploadedContent(record, repository: repository) else { throw DesktopDriveWritebackError.outcomeUnknown }
            }
        }
        guard let saved = try await info(destination), saved.isDirectory == template.isDirectory else {
            throw DesktopDriveWritebackError.outcomeUnknown
        }
        try await configurationStore.registerItemPaths(mappingID: mappingID, remotePaths: [destination])
        await metadata.invalidate(cancelInFlight: true)
        let item = try await writebackItem(saved)
        try journal.complete(record, item: saved)
        return item
    }

    /// 先保存删除意图，再提交。未知结果只回读；用户检查并确认后才允许再次提交。
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion: ProviderRequestedVersion,
                    recursive: Bool, progress: @escaping FileTransferProgress) async throws {
        guard let mappingID, dependencies.writebackAvailable else { throw DesktopDriveWritebackError.disabled }
        guard identifier != .rootContainer, identifier != .trashContainer, identifier != .workingSet else {
            throw DesktopDriveWritebackError.invalidItem
        }
        if recursive { try await dependencies.waitForChildren(identifier, configuration().mapping) }
        let journal = dependencies.writebackStore
        let lease = try journal.lock(mappingID: mappingID)
        defer { withExtendedLifetime(lease) {} }
        try await configurationStore.validateWritebackState(mappingID: mappingID)
        let context = try await makeContext()
        guard let repository = context.repository as? any ProviderWritebackRepository else {
            throw DesktopDriveWritebackError.disabled
        }
        let previous = try journal.records(mappingID: mappingID).last {
            $0.isDeletion && $0.itemIdentifier == identifier.rawValue
        }
        if previous?.phase == .verified {
            try await dependencies.signalDeletion(context.configuration.mapping)
            return
        }
        guard try journal.isDeletionEnabled(mappingID: mappingID) || previous?.phase == .keptLocally else {
            throw DesktopDriveWritebackError.disabled
        }
        let path: String
        if let previous { path = previous.destinationPath }
        else {
            do { path = try await remotePath(for: identifier) }
            catch let error as NSFileProviderError where error.code == .noSuchItem {
                // 未完成创建的项目仍有本机内容，不能把它当作可静默丢弃的未知项目。
                guard try !journal.pendingRecords(mappingID: mappingID).contains(where: {
                    $0.itemIdentifier == identifier.rawValue
                }) else { throw DesktopDriveWritebackError.pendingChanges }
                return
            }
        }
        let root = Self.rootPath(for: context.configuration.mapping)
        guard DesktopDrivePath.normalized(path) == path, path != root,
              path.split(separator: "/").count > 1, DesktopDrivePath.isAncestorOrSame(root, of: path),
              !path.split(separator: "/").contains("#recycle") else {
            throw DesktopDriveWritebackError.invalidItem
        }
        let parts = path.split(separator: "/")
        let ancestorPaths = (1..<parts.count).map { "/" + parts.prefix($0).joined(separator: "/") }
        let ancestors = try await repository.getInfo(paths: ancestorPaths)
        for ancestorPath in ancestorPaths {
            guard let ancestor = ancestors.first(where: { $0.path == ancestorPath }), ancestor.isDirectory else {
                throw CocoaError(.fileReadNoPermission)
            }
            guard ancestor.mountPointType == nil else { throw DesktopDriveWritebackError.invalidItem }
        }
        guard let parentItem = ancestors.first(where: { $0.path == ancestorPaths.last }),
              parentItem.permissions?.canRead != false else {
            throw CocoaError(.fileReadNoPermission)
        }
        let current = try await deletionInfo(path, repository: repository)
        if previous?.phase == .keptLocally {
            if let current {
                if var stopped = previous {
                    if stopped.restorationRequested == true {
                        // 无法区分新的用户删除与系统重试，重新出现时要求一次明确确认。
                        stopped.phase = .conflict
                        stopped.allowOverwrite = false
                        try journal.save(stopped)
                        throw DesktopDriveWritebackError.conflict
                    }
                    stopped.restorationRequested = true
                    try journal.save(stopped)
                }
                throw NSError.fileProviderErrorForRejectedDeletion(of: ProviderItem(fileItem: current,
                    mapping: context.configuration.mapping, keptOffline: false,
                    identifiersByPath: context.configuration.itemIdentifiersByPath))
            }
            try await finishDeletion(path: path, mapping: context.configuration.mapping, record: previous)
            return
        }
        guard let current else {
            try await finishDeletion(path: path, mapping: context.configuration.mapping, record: previous)
            return
        }
        guard current.kind == .file || current.kind == .directory, !current.isRecyclePath,
              current.mountPointType == nil else { throw DesktopDriveWritebackError.invalidItem }
        guard current.permissions?.canDelete == true, parentItem.permissions?.canWrite != false else {
            throw NSError.fileProviderErrorForRejectedDeletion(of: ProviderItem(fileItem: current,
                mapping: context.configuration.mapping, keptOffline: false,
                identifiersByPath: context.configuration.itemIdentifiersByPath))
        }
        if let currentIdentifier = context.configuration.itemIdentifiersByPath[path],
           currentIdentifier != identifier.rawValue, !identifier.rawValue.hasPrefix("path:") {
            throw DesktopDriveWritebackError.conflict
        }
        if current.isDirectory && previous == nil {
            try await checkDeletionChildren(path, recursive: recursive, repository: repository)
        }
        let hasKnownBase = baseVersion.metadata.starts(with: Data("metadata:".utf8)) ||
            (current.isDirectory && current.times?.modifiedAt != nil)
        var record = try previous ?? journal.prepare(.init(mappingID: mappingID,
            itemIdentifier: identifier.rawValue, sourcePath: path, destinationPath: path,
            isDirectory: current.isDirectory, contentHash: nil, contentSize: nil,
            baseContentVersion: hasKnownBase ? baseVersion.content : nil, operation: .delete, recursive: recursive), contents: nil)
        if record.phase == .conflict { throw DesktopDriveWritebackError.conflict }
        if record.phase == .submitted && !record.allowOverwrite { throw DesktopDriveWritebackError.outcomeUnknown }
        guard record.isDirectory == current.isDirectory else { throw DesktopDriveWritebackError.conflict }
        if !record.allowOverwrite, let base = record.baseContentVersion {
            if current.times?.modifiedAt == nil || (!current.isDirectory && current.sizeBytes == nil) {
                throw DesktopDriveWritebackError.outcomeUnknown
            }
            let item = ProviderItem(fileItem: current, mapping: context.configuration.mapping, keptOffline: false)
            if base != item.itemVersion.contentVersion {
                record.phase = .conflict
                try journal.save(record)
                throw DesktopDriveWritebackError.conflict
            }
        }
        if current.isDirectory && previous != nil {
            try await checkDeletionChildren(path, recursive: record.recursive == true, repository: repository)
        }
        try Task.checkCancellation()
        record.phase = .submitted
        record.allowOverwrite = false
        try journal.save(record)
        let result = try await repository.deleteResult(paths: [path], recursive: record.recursive == true, progress: progress)
        if !result.submitted {
            record.phase = .conflict
            try journal.save(record)
            throw DesktopDriveWritebackError.conflict
        }
        guard try await deletionInfo(path, repository: repository) == nil else {
            throw DesktopDriveWritebackError.outcomeUnknown
        }
        try await finishDeletion(path: path, mapping: context.configuration.mapping, record: record)
    }

    private func deletionInfo(_ path: String, repository: any ProviderWritebackRepository) async throws -> FileItem? {
        do { return try await repository.getInfo(paths: [path]).first(where: { $0.path == path }) }
        catch let error as AppError where error.category == .notFound { return nil }
    }

    private func checkDeletionChildren(_ path: String, recursive: Bool,
                                       repository: any ProviderWritebackRepository) async throws {
        var folders = [path]
        while let folder = folders.popLast() {
            var offset = 0
            while true {
                try Task.checkCancellation()
                let page = try await repository.listFolder(path: folder, offset: offset, limit: 200)
                if !recursive && (!page.items.isEmpty || page.hasMore) { throw NSFileProviderError(.directoryNotEmpty) }
                for child in page.items {
                    guard DesktopDrivePath.normalized(child.path) == child.path,
                          (child.path as NSString).deletingLastPathComponent == folder,
                          child.permissions?.canDelete == true, !child.isRecyclePath, child.mountPointType == nil,
                          child.kind == .file || child.kind == .directory else {
                        throw NSFileProviderError(.directoryNotEmpty)
                    }
                    if child.isDirectory { folders.append(child.path) }
                }
                if !page.hasMore { break }
                guard !page.items.isEmpty else { throw DesktopDriveWritebackError.outcomeUnknown }
                offset += page.items.count
            }
        }
    }

    private func finishDeletion(path: String, mapping: DesktopDriveMapping, record: DesktopDriveWritebackRecord?) async throws {
        try await configurationStore.removeDeletedItemPaths(mappingID: mapping.id, remotePath: path,
            maximumEntryCount: dependencies.changeJournalMaximumEntries)
        await metadata.invalidate(cancelInFlight: true)
        if let record { try dependencies.writebackStore.completeDeletion(record) }
        // 刷新通知失败也不能丢失已确认的删除收据；重试仅补发通知。
        try await dependencies.signalDeletion(mapping)
    }

    private func verifyUploadedContent(_ record: DesktopDriveWritebackRecord,
                                       repository: any ProviderWritebackRepository) async throws -> Bool {
        guard let expectedHash = record.contentHash,
              let item = try await repository.getInfo(paths: [record.destinationPath]).first(where: { $0.path == record.destinationPath }),
              !item.isDirectory, item.sizeBytes == record.contentSize else { return false }
        let scratch = try dependencies.writebackStore.contentURL(for: record).deletingLastPathComponent()
            .appendingPathComponent("verify-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try await repository.download(remotePath: record.destinationPath, to: scratch, expectedSize: record.contentSize, progress: { _, _ in })
        } catch {
            await repository.removePartialDownload(to: scratch)
            throw error
        }
        return try DesktopDriveWritebackStore.hash(of: scratch) == expectedHash
    }

    private func writebackItem(_ item: FileItem) async throws -> ProviderItem {
        let configuration = try await configuration()
        let runtime = try await configurationStore.runtime(mappingID: configuration.mapping.id)
        return ProviderItem(fileItem: item, mapping: configuration.mapping, keptOffline: runtime.keepsOffline(item.path),
                            identifiersByPath: configuration.itemIdentifiersByPath, writable: isWritebackEnabled(configuration),
                            deletable: isDeletionEnabled(configuration))
    }

    private func configuration()
        async throws -> DesktopDriveProviderConfiguration {
        guard let mappingID,
              let configuration = try await configurationStore.configuration(
            mappingID: mappingID
        ) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return configuration
    }

    private func rootItem() async throws -> ProviderItem {
        let configuration = try await configuration()
        let runtime = try await configurationStore.runtime(
            mappingID: configuration.mapping.id
        )
        return ProviderItem.root(
            configuration: configuration,
            keptOffline: runtime.keepsOffline(
                Self.rootPath(for: configuration.mapping)
            ),
            writable: isWritebackEnabled(configuration)
        )
    }

    private func makeContext() async throws -> (
        configuration: DesktopDriveProviderConfiguration,
        repository: any ProviderRuntimeRepository
    ) {
        let configuration = try await configuration()
        guard try await configurationStore.isProviderAvailable() else {
            throw NSFileProviderError(.serverUnreachable)
        }
        let runtime = try await configurationStore.runtime(
            mappingID: configuration.mapping.id
        )
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
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(
                mapping.providerDomainIdentifier ?? mapping.id.uuidString
            ),
            displayName: mapping.displayName
        )
        domain.supportsSyncingTrash = false
        return domain
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

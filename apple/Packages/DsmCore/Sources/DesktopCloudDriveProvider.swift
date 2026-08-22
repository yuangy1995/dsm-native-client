import Darwin
import Foundation

public enum DesktopDriveSharedContainer {
    public static let appGroupIdentifier =
        "group.io.github.qwertyuiop1995.dsmnativeclient"
}

public struct DesktopDriveProviderConnection: Codable, Equatable, Sendable {
    public let profile: NasProfile
    public let capabilities: [ApiCapability]

    public init(profile: NasProfile, capabilities: CapabilitySet) {
        self.profile = profile
        self.capabilities = capabilities.all
    }

    public var capabilitySet: CapabilitySet {
        CapabilitySet(Dictionary(uniqueKeysWithValues: capabilities.map { ($0.name, $0) }))
    }
}

public struct DesktopDriveProviderConfiguration: Codable, Equatable, Sendable {
    public let mapping: DesktopDriveMapping
    public let connection: DesktopDriveProviderConnection

    public init(
        mapping: DesktopDriveMapping,
        connection: DesktopDriveProviderConnection
    ) {
        self.mapping = mapping
        self.connection = connection
    }
}

public enum DesktopDriveConfigurationStoreError: Error, Equatable, Sendable {
    case sharedContainerUnavailable
    case connectionUnavailable
    case invalidStateTransition
}

public actor DesktopDriveConfigurationStore {
    private struct Snapshot: Codable {
        var version = 2
        var connections: [UUID: DesktopDriveProviderConnection] = [:]
        var mappings: [UUID: DesktopDriveMapping] = [:]
        var itemPaths: [UUID: [String: String]]?
        var changeJournals: [UUID: [String: DesktopDriveChangeJournal]]?
        var runtimes: [UUID: DesktopDriveMappingRuntime]?
        var runtimeRecoveryMappingIDs: Set<UUID>?
        var pendingSessionRemovalProfileIDs: Set<UUID>?
        var providerAvailable: Bool?

        private enum CodingKeys: String, CodingKey {
            case version
            case connections
            case mappings
            case itemPaths
            case changeJournals
            case runtimes
            case runtimeRecoveryMappingIDs
            case pendingSessionRemovalProfileIDs
            case providerAvailable
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 2
            connections = try container.decode(
                [UUID: DesktopDriveProviderConnection].self,
                forKey: .connections
            )
            mappings = try container.decode(
                [UUID: DesktopDriveMapping].self,
                forKey: .mappings
            )
            itemPaths = try container.decodeIfPresent(
                [UUID: [String: String]].self,
                forKey: .itemPaths
            )
            // 日志损坏时不能让整个映射配置不可读；丢弃该可重建缓存并让旧锚点过期。
            do {
                changeJournals = try container.decodeIfPresent(
                    [UUID: [String: DesktopDriveChangeJournal]].self,
                    forKey: .changeJournals
                )
            } catch {
                changeJournals = nil
            }
            providerAvailable = try container.decodeIfPresent(
                Bool.self,
                forKey: .providerAvailable
            )
            let persistedRecoveryIDs: Set<UUID>
            do {
                persistedRecoveryIDs = Set(
                    try container.decodeIfPresent(
                        [UUID].self,
                        forKey: .runtimeRecoveryMappingIDs
                    ) ?? []
                )
            } catch {
                persistedRecoveryIDs = Set(mappings.keys)
            }
            runtimeRecoveryMappingIDs = persistedRecoveryIDs
            pendingSessionRemovalProfileIDs = Set(
                try container.decodeIfPresent(
                    [UUID].self,
                    forKey: .pendingSessionRemovalProfileIDs
                ) ?? []
            )

            guard container.contains(.runtimes) else {
                runtimes = nil
                runtimeRecoveryMappingIDs = persistedRecoveryIDs.intersection(
                    mappings.keys
                )
                return
            }
            do {
                let recovered = try container.decodeIfPresent(
                    RecoverableRuntimeDictionary.self,
                    forKey: .runtimes
                )
                runtimes = recovered?.values
                runtimeRecoveryMappingIDs = persistedRecoveryIDs.union(
                    recovered?.corruptIdentifiers ?? []
                )
            } catch {
                runtimes = Dictionary(uniqueKeysWithValues: mappings.keys.map {
                    ($0, DesktopDriveMappingRuntime(state: .failed))
                })
                runtimeRecoveryMappingIDs = persistedRecoveryIDs.union(
                    mappings.keys
                )
            }
            runtimeRecoveryMappingIDs = runtimeRecoveryMappingIDs?
                .intersection(mappings.keys)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(connections, forKey: .connections)
            try container.encode(mappings, forKey: .mappings)
            try container.encodeIfPresent(itemPaths, forKey: .itemPaths)
            try container.encodeIfPresent(changeJournals, forKey: .changeJournals)
            try container.encodeIfPresent(
                runtimes.map(RecoverableRuntimeDictionary.init(values:)),
                forKey: .runtimes
            )
            try container.encodeIfPresent(
                runtimeRecoveryMappingIDs?.sorted {
                    $0.uuidString < $1.uuidString
                },
                forKey: .runtimeRecoveryMappingIDs
            )
            try container.encodeIfPresent(
                pendingSessionRemovalProfileIDs?.sorted {
                    $0.uuidString < $1.uuidString
                },
                forKey: .pendingSessionRemovalProfileIDs
            )
            try container.encodeIfPresent(
                providerAvailable,
                forKey: .providerAvailable
            )
        }
    }

    /// 单条运行时记录损坏时保留其映射，并将该记录降级为需要本机恢复。
    private struct RecoverableRuntimeDictionary: Codable {
        var values: [UUID: DesktopDriveMappingRuntime]
        var corruptIdentifiers: Set<UUID> = []

        init(values: [UUID: DesktopDriveMappingRuntime]) {
            self.values = values
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var decoded: [UUID: DesktopDriveMappingRuntime] = [:]
            while !container.isAtEnd {
                let rawIdentifier = try container.decode(String.self)
                guard !container.isAtEnd else {
                    if let identifier = UUID(uuidString: rawIdentifier) {
                        decoded[identifier] = .init(state: .failed)
                        corruptIdentifiers.insert(identifier)
                    }
                    break
                }
                let valueDecoder = try container.superDecoder()
                guard let identifier = UUID(uuidString: rawIdentifier) else {
                    continue
                }
                do {
                    decoded[identifier] = try DesktopDriveMappingRuntime(
                        from: valueDecoder
                    )
                } catch {
                    decoded[identifier] = .init(state: .failed)
                    corruptIdentifiers.insert(identifier)
                }
            }
            values = decoded
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            for identifier in values.keys.sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                guard var runtime = values[identifier] else { continue }
                try container.encode(identifier.uuidString)
                if runtime.state == .recoveryRequired {
                    runtime.state = .failed
                }
                try container.encode(runtime)
            }
        }
    }

    private let directoryURL: URL?
    private let fileManager: FileManager
    private let writeOptions: Data.WritingOptions
    /// 只用于读取降级；任何写入仍必须先成功解码当前磁盘快照。
    private var lastSuccessfullyDecodedSnapshot: Snapshot?

    public init(
        appGroupIdentifier: String = DesktopDriveSharedContainer.appGroupIdentifier,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        writeOptions = [.atomic, .completeFileProtection]
        directoryURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        writeOptions = [.atomic]
    }

    public func saveConnection(
        profile: NasProfile,
        capabilities: CapabilitySet
    ) throws {
        try updateSnapshot { snapshot in
            snapshot.connections[profile.id] = DesktopDriveProviderConnection(
                profile: profile,
                capabilities: capabilities
            )
        }
    }

    public func saveMapping(_ mapping: DesktopDriveMapping) throws {
        try updateSnapshot { snapshot in
            guard snapshot.connections[mapping.profileID] != nil else {
                throw DesktopDriveConfigurationStoreError.connectionUnavailable
            }
            snapshot.mappings[mapping.id] = mapping
        }
    }

    public func configuration(
        mappingID: UUID
    ) throws -> DesktopDriveProviderConfiguration? {
        try readSnapshot { snapshot in
            guard let mapping = snapshot.mappings[mappingID],
                  let connection = snapshot.connections[mapping.profileID] else {
                return nil
            }
            return DesktopDriveProviderConfiguration(
                mapping: mapping,
                connection: connection
            )
        }
    }

    public func mappings(profileID: UUID? = nil) throws -> [DesktopDriveMapping] {
        try readSnapshot { snapshot in
            snapshot.mappings.values
                .filter { profileID == nil || $0.profileID == profileID }
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    public func removeMapping(id: UUID) throws {
        try updateSnapshot { snapshot in
            snapshot.mappings.removeValue(forKey: id)
            snapshot.itemPaths?[id] = nil
            snapshot.changeJournals?[id] = nil
            snapshot.runtimes?[id] = nil
            snapshot.runtimeRecoveryMappingIDs?.remove(id)
        }
    }

    public func removeConnection(profileID: UUID) throws {
        try updateSnapshot { snapshot in
            snapshot.connections.removeValue(forKey: profileID)
            let removedIDs = snapshot.mappings.values
                .filter { $0.profileID == profileID }
                .map(\.id)
            snapshot.mappings = snapshot.mappings.filter {
                $0.value.profileID != profileID
            }
            for mappingID in removedIDs {
                snapshot.itemPaths?[mappingID] = nil
                snapshot.changeJournals?[mappingID] = nil
                snapshot.runtimes?[mappingID] = nil
                snapshot.runtimeRecoveryMappingIDs?.remove(mappingID)
            }
        }
    }

    /// 返回会话删除尚未得到确认的 profile，供启动恢复继续处理。
    public func pendingSessionRemovalProfileIDs() throws -> Set<UUID> {
        try readSnapshot { snapshot in
            snapshot.pendingSessionRemovalProfileIDs ?? []
        }
    }

    /// 标记或清除 profile 级会话删除任务；只有外部确认删除成功后才应清除。
    public func setSessionRemovalPending(
        _ isPending: Bool,
        profileID: UUID
    ) throws {
        try updateSnapshot { snapshot in
            if snapshot.pendingSessionRemovalProfileIDs == nil {
                snapshot.pendingSessionRemovalProfileIDs = []
            }
            if isPending {
                snapshot.pendingSessionRemovalProfileIDs?.insert(profileID)
            } else {
                snapshot.pendingSessionRemovalProfileIDs?.remove(profileID)
            }
        }
    }

    public func registerItemPaths(
        mappingID: UUID,
        remotePaths: [String]
    ) throws {
        try updateSnapshot { snapshot in
            guard snapshot.mappings[mappingID] != nil else {
                return
            }
            var index = snapshot.itemPaths?[mappingID] ?? [:]
            for rawPath in remotePaths {
                guard let path = DesktopDrivePath.normalized(rawPath),
                      let identifier = DesktopDriveItemIdentity.identifier(
                        mappingID: mappingID,
                        remotePath: path
                      ) else {
                    continue
                }
                index[identifier] = path
            }
            if snapshot.itemPaths == nil {
                snapshot.itemPaths = [:]
            }
            snapshot.itemPaths?[mappingID] = index
        }
    }

    public func remotePath(
        mappingID: UUID,
        itemIdentifier: String
    ) throws -> String? {
        try readSnapshot {
            $0.itemPaths?[mappingID]?[itemIdentifier]
        }
    }

    /// 基于一份完整目录快照原子地更新持久化变化日志。
    ///
    /// 目录扫描发生在锁外，但与磁盘上最新日志的比较、修订号递增和写回在同一文件锁内
    /// 完成，因此 Extension 重启或并发实例不会丢弃已记录的变化。
    public func refreshChangeJournal(
        mappingID: UUID,
        containerIdentifier: String,
        currentItems: [String: FileItem],
        maximumEntryCount: Int
    ) throws -> DesktopDriveChangeJournal {
        var result: DesktopDriveChangeJournal?
        try updateSnapshot { snapshot in
            guard snapshot.mappings[mappingID] != nil else {
                throw CocoaError(.fileNoSuchFile)
            }

            let existing = snapshot.changeJournals?[mappingID]?[containerIdentifier]
            let previousIdentifiers: Set<String>
            if let existing, existing.isValid {
                previousIdentifiers = Set(existing.snapshot.keys)
            } else {
                previousIdentifiers = []
            }
            var journal: DesktopDriveChangeJournal
            if let existing, existing.isValid {
                journal = existing
                journal.apply(
                    snapshot: currentItems,
                    maximumEntryCount: maximumEntryCount
                )
                if !journal.isValid {
                    journal = DesktopDriveChangeJournal(snapshot: currentItems)
                }
            } else {
                // 缺失、损坏或旧 schema 的日志都建立全新 generation，旧锚点会安全失效。
                journal = DesktopDriveChangeJournal(snapshot: currentItems)
            }

            if snapshot.changeJournals == nil {
                snapshot.changeJournals = [:]
            }
            if snapshot.changeJournals?[mappingID] == nil {
                snapshot.changeJournals?[mappingID] = [:]
            }
            snapshot.changeJournals?[mappingID]?[containerIdentifier] = journal

            var pathIndex = snapshot.itemPaths?[mappingID] ?? [:]
            for identifier in journal.snapshot.keys {
                guard let item = journal.snapshot[identifier],
                      DesktopDrivePath.normalized(item.path) != nil else {
                    continue
                }
                pathIndex[identifier] = item.path
            }
            for identifier in previousIdentifiers where journal.snapshot[identifier] == nil {
                pathIndex[identifier] = nil
            }
            if snapshot.itemPaths == nil {
                snapshot.itemPaths = [:]
            }
            snapshot.itemPaths?[mappingID] = pathIndex
            result = journal
        }
        guard let result else {
            throw CocoaError(.fileWriteUnknown)
        }
        return result
    }

    /// 读取测试、诊断和恢复决策所需的日志副本；调用方不得原地修改共享状态。
    public func changeJournal(
        mappingID: UUID,
        containerIdentifier: String
    ) throws -> DesktopDriveChangeJournal? {
        try readSnapshot {
            $0.changeJournals?[mappingID]?[containerIdentifier]
        }
    }

    public func runtime(
        mappingID: UUID
    ) throws -> DesktopDriveMappingRuntime {
        try readSnapshot { snapshot in
            var runtime = snapshot.runtimes?[mappingID] ?? .init()
            if snapshot.runtimeRecoveryMappingIDs?.contains(mappingID) == true {
                runtime.state = .recoveryRequired
            }
            return runtime
        }
    }

    public func saveRuntime(
        _ runtime: DesktopDriveMappingRuntime,
        mappingID: UUID
    ) throws {
        try updateSnapshot { snapshot in
            guard snapshot.mappings[mappingID] != nil else {
                return
            }
            if snapshot.runtimes == nil {
                snapshot.runtimes = [:]
            }
            let currentState = effectiveState(
                in: snapshot,
                mappingID: mappingID
            )
            guard currentState != .recoveryRequired,
                  isAllowedStoreTransition(
                    from: currentState,
                    to: runtime.state
                  ) else {
                throw DesktopDriveConfigurationStoreError.invalidStateTransition
            }
            var storedRuntime = runtime
            if runtime.state == .recoveryRequired {
                storedRuntime.state = .failed
                if snapshot.runtimeRecoveryMappingIDs == nil {
                    snapshot.runtimeRecoveryMappingIDs = []
                }
                snapshot.runtimeRecoveryMappingIDs?.insert(mappingID)
            }
            snapshot.runtimes?[mappingID] = storedRuntime
        }
    }

    public func setMappingState(
        _ state: DesktopDriveMappingState,
        mappingID: UUID,
        successfulCheckAt: Date? = nil
    ) throws {
        try updateSnapshot { snapshot in
            guard snapshot.mappings[mappingID] != nil else {
                return
            }
            let currentState = effectiveState(
                in: snapshot,
                mappingID: mappingID
            )
            guard isAllowedStoreTransition(from: currentState, to: state) else {
                throw DesktopDriveConfigurationStoreError.invalidStateTransition
            }
            var runtime = snapshot.runtimes?[mappingID] ?? .init()
            runtime.state = state == .recoveryRequired ? .failed : state
            if let successfulCheckAt {
                runtime.lastSuccessfulCheckAt = successfulCheckAt
            }
            if snapshot.runtimes == nil {
                snapshot.runtimes = [:]
            }
            if state == .recoveryRequired {
                if snapshot.runtimeRecoveryMappingIDs == nil {
                    snapshot.runtimeRecoveryMappingIDs = []
                }
                snapshot.runtimeRecoveryMappingIDs?.insert(mappingID)
            } else if state == .removing {
                snapshot.runtimeRecoveryMappingIDs?.remove(mappingID)
            }
            snapshot.runtimes?[mappingID] = runtime
        }
    }

    /// 只有显式恢复完成后才同时清除恢复标记并提交可用状态。
    public func completeRuntimeRecovery(
        mappingID: UUID,
        successfulCheckAt: Date
    ) throws {
        try updateSnapshot { snapshot in
            guard snapshot.mappings[mappingID] != nil else { return }
            guard effectiveState(in: snapshot, mappingID: mappingID)
                    == .recoveryRequired else {
                throw DesktopDriveConfigurationStoreError.invalidStateTransition
            }
            var runtime = snapshot.runtimes?[mappingID] ?? .init()
            runtime.state = .available
            runtime.isManuallyPaused = false
            runtime.lastSuccessfulCheckAt = successfulCheckAt
            if snapshot.runtimes == nil {
                snapshot.runtimes = [:]
            }
            snapshot.runtimes?[mappingID] = runtime
            snapshot.runtimeRecoveryMappingIDs?.remove(mappingID)
        }
    }

    public func setMappingPaused(
        _ isPaused: Bool,
        mappingID: UUID
    ) throws {
        try updateSnapshot { snapshot in
            guard snapshot.mappings[mappingID] != nil else {
                return
            }
            let targetState: DesktopDriveMappingState = isPaused ? .paused : .checking
            let currentState = effectiveState(
                in: snapshot,
                mappingID: mappingID
            )
            guard isAllowedStoreTransition(
                from: currentState,
                to: targetState
            ) else {
                throw DesktopDriveConfigurationStoreError.invalidStateTransition
            }
            var runtime = snapshot.runtimes?[mappingID] ?? .init()
            runtime.isManuallyPaused = isPaused
            runtime.state = targetState
            if snapshot.runtimes == nil {
                snapshot.runtimes = [:]
            }
            snapshot.runtimes?[mappingID] = runtime
        }
    }

    public func setPinnedPaths(
        _ remotePaths: [String],
        mappingID: UUID
    ) throws {
        try updateSnapshot { snapshot in
            guard snapshot.mappings[mappingID] != nil else {
                return
            }
            var runtime = snapshot.runtimes?[mappingID] ?? .init()
            runtime.pinnedPaths = Array(
                Set(remotePaths.compactMap(DesktopDrivePath.normalized))
            ).sorted()
            if snapshot.runtimes == nil {
                snapshot.runtimes = [:]
            }
            snapshot.runtimes?[mappingID] = runtime
        }
    }

    public func recordCacheEntry(
        _ entry: DesktopDriveCacheEntry,
        mappingID: UUID
    ) throws {
        try updateSnapshot { snapshot in
            guard snapshot.mappings[mappingID] != nil else {
                return
            }
            var runtime = snapshot.runtimes?[mappingID] ?? .init()
            runtime.cacheEntries[entry.remotePath] = entry
            if snapshot.runtimes == nil {
                snapshot.runtimes = [:]
            }
            snapshot.runtimes?[mappingID] = runtime
        }
    }

    public func removeCacheEntries(
        remotePaths: [String],
        mappingID: UUID
    ) throws {
        try updateSnapshot { snapshot in
            guard snapshot.mappings[mappingID] != nil else {
                return
            }
            var runtime = snapshot.runtimes?[mappingID] ?? .init()
            for path in remotePaths {
                runtime.cacheEntries.removeValue(forKey: path)
            }
            if snapshot.runtimes == nil {
                snapshot.runtimes = [:]
            }
            snapshot.runtimes?[mappingID] = runtime
        }
    }

    public func setProviderAvailable(_ isAvailable: Bool) throws {
        try updateSnapshot { snapshot in
            snapshot.providerAvailable = isAvailable
        }
    }

    public func isProviderAvailable() throws -> Bool {
        try readSnapshot {
            $0.providerAvailable ?? true
        }
    }

    private func readSnapshot<T>(
        _ body: (Snapshot) throws -> T
    ) throws -> T {
        let snapshot = try withFileLock(exclusive: false) {
            try loadSnapshotUnlocked(allowCachedFallback: true)
        }
        return try body(snapshot)
    }

    private func updateSnapshot(
        _ body: (inout Snapshot) throws -> Void
    ) throws {
        try withFileLock(exclusive: true) {
            var snapshot = try loadSnapshotUnlocked(allowCachedFallback: false)
            try body(&snapshot)
            try saveSnapshotUnlocked(snapshot)
        }
    }

    private func loadSnapshotUnlocked(
        allowCachedFallback: Bool
    ) throws -> Snapshot {
        guard let fileURL else {
            throw DesktopDriveConfigurationStoreError.sharedContainerUnavailable
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            if let lastSuccessfullyDecodedSnapshot {
                if allowCachedFallback {
                    return lastSuccessfullyDecodedSnapshot
                }
                throw CocoaError(.fileNoSuchFile)
            }
            return Snapshot()
        }
        do {
            let snapshot = try JSONDecoder().decode(
                Snapshot.self,
                from: Data(contentsOf: fileURL)
            )
            lastSuccessfullyDecodedSnapshot = snapshot
            return snapshot
        } catch {
            if allowCachedFallback, let lastSuccessfullyDecodedSnapshot {
                return lastSuccessfullyDecodedSnapshot
            }
            throw error
        }
    }

    private func saveSnapshotUnlocked(_ snapshot: Snapshot) throws {
        guard let directoryURL, let fileURL else {
            throw DesktopDriveConfigurationStoreError.sharedContainerUnavailable
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: writeOptions)
        lastSuccessfullyDecodedSnapshot = snapshot
    }

    private func effectiveState(
        in snapshot: Snapshot,
        mappingID: UUID
    ) -> DesktopDriveMappingState {
        if snapshot.runtimeRecoveryMappingIDs?.contains(mappingID) == true {
            return .recoveryRequired
        }
        return snapshot.runtimes?[mappingID]?.state ?? .preparing
    }

    /// 启动恢复会在完成可读验证后直接恢复为可用，其余路径遵循领域状态机。
    private func isAllowedStoreTransition(
        from current: DesktopDriveMappingState,
        to target: DesktopDriveMappingState
    ) -> Bool {
        if current == .recoveryRequired {
            return target == .recoveryRequired || target == .removing
        }
        if [DesktopDriveMappingState.failed, .cacheVolumeUnavailable]
            .contains(current), target == .available {
            return true
        }
        return current.canTransition(to: target)
    }

    private func withFileLock<T>(
        exclusive: Bool,
        _ body: () throws -> T
    ) throws -> T {
        guard let directoryURL, let lockURL else {
            throw DesktopDriveConfigurationStoreError.sharedContainerUnavailable
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private var fileURL: URL? {
        directoryURL?.appendingPathComponent(
            "desktop-drive-config-v1.json",
            isDirectory: false
        )
    }

    private var lockURL: URL? {
        directoryURL?.appendingPathComponent(
            "desktop-drive-config-v1.lock",
            isDirectory: false
        )
    }
}

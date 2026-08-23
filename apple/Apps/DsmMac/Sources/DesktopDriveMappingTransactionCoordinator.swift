import DsmCore
import FileProvider
import Foundation

protocol DesktopDriveSessionBridging: Sendable {
    func publish() async throws
    func remove() async throws
}

protocol DesktopDriveConfigurationReading: Sendable {
    func mappings(profileID: UUID?) async throws -> [DesktopDriveMapping]
    func runtime(mappingID: UUID) async throws -> DesktopDriveMappingRuntime
}

protocol DesktopDriveConfigurationWriting: Sendable {
    func saveMapping(_ mapping: DesktopDriveMapping) async throws
    func setMappingState(
        _ state: DesktopDriveMappingState,
        mappingID: UUID,
        successfulCheckAt: Date?
    ) async throws
}

extension DesktopDriveConfigurationReading {
    func mappings() async throws -> [DesktopDriveMapping] {
        try await mappings(profileID: nil)
    }
}

extension DesktopDriveConfigurationWriting {
    func setMappingState(
        _ state: DesktopDriveMappingState,
        mappingID: UUID
    ) async throws {
        try await setMappingState(
            state,
            mappingID: mappingID,
            successfulCheckAt: nil
        )
    }
}

protocol DesktopDriveConfigurationTransactionStoring:
    DesktopDriveConfigurationReading,
    DesktopDriveConfigurationWriting {
    func removeMapping(id: UUID) async throws
    func pendingSessionRemovalProfileIDs() async throws -> Set<UUID>
    func setSessionRemovalPending(
        _ isPending: Bool,
        profileID: UUID
    ) async throws
}

protocol DesktopDriveManagerStoring:
    DesktopDriveConfigurationTransactionStoring {
    func setProviderAvailable(_ isAvailable: Bool) async throws
    func registerItemPaths(
        mappingID: UUID,
        remotePaths: [String]
    ) async throws
    func setPinnedPaths(_ paths: [String], mappingID: UUID) async throws
    func removeCacheEntries(
        remotePaths: [String],
        mappingID: UUID
    ) async throws
    func setMappingPaused(_ isPaused: Bool, mappingID: UUID) async throws
    func completeRuntimeRecovery(
        mappingID: UUID,
        successfulCheckAt: Date
    ) async throws
}

extension DesktopDriveConfigurationStore: DesktopDriveManagerStoring {}

@MainActor
protocol DesktopDriveDomainRegistrationControlling {
    func domain(for mapping: DesktopDriveMapping) -> NSFileProviderDomain
    func domainForCreation(
        _ mapping: DesktopDriveMapping
    ) throws -> NSFileProviderDomain
    func add(_ domain: NSFileProviderDomain) async throws
    func remove(_ domain: NSFileProviderDomain) async throws
    func registeredDomainIdentifiers() async throws -> Set<String>
    func removeRegisteredDomain(identifier: String) async throws
}

enum DesktopDriveMappingRecoveryResult: Equatable {
    case unchanged
    case activated
    case removed
    case needsCacheVolume
    case recoveryRequired
    case failed
}

enum DesktopDriveSessionRecoveryResult: Equatable {
    case ready
    case unused
    case cleanupPending
    case authenticationRequired
}

struct DesktopDriveOrphanCleanupResult: Equatable {
    let removedCount: Int
    let failureCount: Int
}

/// 将映射创建、移除和启动恢复集中为可测试事务，系统回调失败时保留可恢复状态。
@MainActor
struct DesktopDriveMappingTransactionCoordinator {
    private let store: any DesktopDriveConfigurationTransactionStoring
    private let sessionBridge: (any DesktopDriveSessionBridging)?
    private let domainController: any DesktopDriveDomainRegistrationControlling

    init(
        store: any DesktopDriveConfigurationTransactionStoring,
        sessionBridge: (any DesktopDriveSessionBridging)?,
        domainController: any DesktopDriveDomainRegistrationControlling
    ) {
        self.store = store
        self.sessionBridge = sessionBridge
        self.domainController = domainController
    }

    func create(
        _ initialMapping: DesktopDriveMapping,
        verifyReadable: (DesktopDriveMapping) async throws -> Void
    ) async throws -> DesktopDriveMapping {
        guard let sessionBridge else {
            throw DesktopDriveConfigurationStoreError.connectionUnavailable
        }

        var mapping = initialMapping
        var mappingSaved = false
        var domainAdded = false
        do {
            try await sessionBridge.publish()
            let domain = try domainController.domainForCreation(mapping)
            if domain.identifier.rawValue != mapping.id.uuidString {
                mapping = mapping.replacing(
                    providerDomainIdentifier: domain.identifier.rawValue
                )
            }
            try await store.saveMapping(mapping)
            mappingSaved = true
            try await store.setMappingState(
                .preparing,
                mappingID: mapping.id,
                successfulCheckAt: nil
            )
            try await domainController.add(domain)
            domainAdded = true
            try await verifyReadable(mapping)
            try await store.setMappingState(
                .available,
                mappingID: mapping.id,
                successfulCheckAt: Date()
            )
            return mapping
        } catch {
            if domainAdded {
                do {
                    try await domainController.remove(
                        domainController.domain(for: mapping)
                    )
                    if mappingSaved {
                        try await store.removeMapping(id: mapping.id)
                    }
                } catch {
                    try? await store.setMappingState(
                        .removing,
                        mappingID: mapping.id,
                        successfulCheckAt: nil
                    )
                }
            } else if mappingSaved {
                do {
                    try await store.removeMapping(id: mapping.id)
                } catch {
                    try? await store.setMappingState(
                        .removing,
                        mappingID: mapping.id,
                        successfulCheckAt: nil
                    )
                }
            }
            try await removeSessionIfUnused(profileID: mapping.profileID)
            throw error
        }
    }

    func remove(_ mapping: DesktopDriveMapping) async throws {
        try await store.setMappingState(
            .removing,
            mappingID: mapping.id,
            successfulCheckAt: nil
        )
        let shouldRemoveSharedSession =
            try await beginSharedSessionRemovalIfLastMapping(mapping)
        try await domainController.remove(domainController.domain(for: mapping))
        if shouldRemoveSharedSession {
            await completePendingSharedSessionRemovalBestEffort(
                profileID: mapping.profileID
            )
        }
        try await store.removeMapping(id: mapping.id)
    }

    func restoreSharedSession(
        for mappings: [DesktopDriveMapping],
        profileID: UUID
    ) async -> DesktopDriveSessionRecoveryResult {
        guard !mappings.isEmpty else {
            do {
                try await removeSharedSessionTransaction(profileID: profileID)
                return .unused
            } catch {
                return .cleanupPending
            }
        }
        var activeMappings: [DesktopDriveMapping] = []
        for mapping in mappings {
            let state = try? await store.runtime(mappingID: mapping.id).state
            if state != .removing {
                activeMappings.append(mapping)
            }
        }
        guard !activeMappings.isEmpty else {
            return .ready
        }
        guard let sessionBridge else {
            await markAuthenticationRequired(activeMappings)
            return .authenticationRequired
        }
        do {
            try await sessionBridge.publish()
        } catch {
            await markAuthenticationRequired(activeMappings)
            return .authenticationRequired
        }
        do {
            try await store.setSessionRemovalPending(
                false,
                profileID: profileID
            )
            return .ready
        } catch {
            return .cleanupPending
        }
    }

    func recover(
        _ mapping: DesktopDriveMapping,
        registeredDomainIdentifiers: Set<String>,
        verifyReadable: (DesktopDriveMapping) async throws -> Void
    ) async -> DesktopDriveMappingRecoveryResult {
        do {
            let runtime = try await store.runtime(mappingID: mapping.id)
            let identifier =
                mapping.providerDomainIdentifier ?? mapping.id.uuidString
            let isRegistered = registeredDomainIdentifiers.contains(identifier)

            if runtime.state == .removing {
                let shouldRemoveSharedSession =
                    try await beginSharedSessionRemovalIfLastMapping(mapping)
                if isRegistered {
                    try await domainController.remove(
                        domainController.domain(for: mapping)
                    )
                }
                if shouldRemoveSharedSession {
                    await completePendingSharedSessionRemovalBestEffort(
                        profileID: mapping.profileID
                    )
                }
                try await store.removeMapping(id: mapping.id)
                return .removed
            }

            if runtime.state == .recoveryRequired {
                return .recoveryRequired
            }

            if !isRegistered {
                switch mapping.cachePolicy.location {
                case .systemDefault:
                    try await domainController.add(
                        domainController.domain(for: mapping)
                    )
                case .eligibleVolume:
                    try await store.setMappingState(
                        .cacheVolumeUnavailable,
                        mappingID: mapping.id,
                        successfulCheckAt: nil
                    )
                    return .needsCacheVolume
                }
            } else if case .systemDefault = mapping.cachePolicy.location {
                try await domainController.add(
                    domainController.domain(for: mapping)
                )
            }

            guard [
                DesktopDriveMappingState.preparing,
                .cacheVolumeUnavailable,
                .failed,
            ].contains(runtime.state) || !isRegistered else {
                return .unchanged
            }
            try await verifyReadable(mapping)
            try await store.setMappingState(
                .available,
                mappingID: mapping.id,
                successfulCheckAt: Date()
            )
            return .activated
        } catch {
            let currentState =
                try? await store.runtime(mappingID: mapping.id).state
            if currentState != .removing {
                try? await store.setMappingState(
                    .failed,
                    mappingID: mapping.id,
                    successfulCheckAt: nil
                )
            }
            return .failed
        }
    }

    func registeredDomainIdentifiers() async throws -> Set<String> {
        try await domainController.registeredDomainIdentifiers()
    }

    func removeOrphanedDomains(
        allMappings: [DesktopDriveMapping]
    ) async throws -> DesktopDriveOrphanCleanupResult {
        let configuredIdentifiers = Set(allMappings.map {
            $0.providerDomainIdentifier ?? $0.id.uuidString
        })
        let orphanedIdentifiers =
            try await domainController.registeredDomainIdentifiers()
                .subtracting(configuredIdentifiers)
        var removedCount = 0
        var failureCount = 0
        for identifier in orphanedIdentifiers.sorted() {
            do {
                try await domainController.removeRegisteredDomain(
                    identifier: identifier
                )
                removedCount += 1
            } catch {
                failureCount += 1
            }
        }
        return .init(
            removedCount: removedCount,
            failureCount: failureCount
        )
    }

    private func removeSessionIfUnused(profileID: UUID) async throws {
        let mappings = try await store.mappings(profileID: profileID)
        guard mappings.isEmpty else {
            return
        }
        try await removeSharedSessionTransaction(profileID: profileID)
    }

    private func removeSessionBeforeRemovingLastMapping(
        _ mapping: DesktopDriveMapping
    ) async throws {
        guard try await mappingRemovalLeavesProfileUnused(mapping) else {
            return
        }
        try await removeSharedSessionTransaction(profileID: mapping.profileID)
    }

    private func beginSharedSessionRemovalIfLastMapping(
        _ mapping: DesktopDriveMapping
    ) async throws -> Bool {
        guard try await mappingRemovalLeavesProfileUnused(mapping) else {
            return false
        }
        try await store.setSessionRemovalPending(
            true,
            profileID: mapping.profileID
        )
        return true
    }

    private func mappingRemovalLeavesProfileUnused(
        _ mapping: DesktopDriveMapping
    ) async throws -> Bool {
        let remainingMappings = try await store.mappings(
            profileID: mapping.profileID
        ).filter { $0.id != mapping.id }
        return remainingMappings.isEmpty
    }

    /// 先持久化待清理标记，再执行可重复的 Keychain 删除；只有两步都成功才清标记。
    private func removeSharedSessionTransaction(profileID: UUID) async throws {
        try await store.setSessionRemovalPending(true, profileID: profileID)
        try await completePendingSharedSessionRemoval(profileID: profileID)
    }

    private func completePendingSharedSessionRemoval(
        profileID: UUID
    ) async throws {
        guard let sessionBridge else {
            throw DesktopDriveConfigurationStoreError.connectionUnavailable
        }
        try await sessionBridge.remove()
        try await store.setSessionRemovalPending(false, profileID: profileID)
    }

    private func completePendingSharedSessionRemovalBestEffort(
        profileID: UUID
    ) async {
        do {
            try await completePendingSharedSessionRemoval(profileID: profileID)
        } catch {
            // 待清理标记已经持久化，后续启动或重新登录时继续补清理。
        }
    }

    private func markAuthenticationRequired(
        _ mappings: [DesktopDriveMapping]
    ) async {
        for mapping in mappings {
            let state = try? await store.runtime(mappingID: mapping.id).state
            guard state != .removing, state != .recoveryRequired else {
                continue
            }
            if state?.canTransition(to: .authenticationRequired) == false {
                // Store 会强制状态机；先进入检查态，再记录重新认证要求。
                try? await store.setMappingState(
                    .checking,
                    mappingID: mapping.id,
                    successfulCheckAt: nil
                )
            }
            try? await store.setMappingState(
                .authenticationRequired,
                mappingID: mapping.id,
                successfulCheckAt: nil
            )
        }
    }
}

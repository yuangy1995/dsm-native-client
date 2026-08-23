import DsmCore
@preconcurrency import FileProvider
import Foundation

/// 集中封装文件提供器域的生命周期和系统回调，避免界面状态管理器承担平台适配细节。
@MainActor
struct DesktopDriveDomainController: DesktopDriveDomainRegistrationControlling {
    func domain(for mapping: DesktopDriveMapping) -> NSFileProviderDomain {
        Self.configureDomain(
            NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(
                    mapping.providerDomainIdentifier ?? mapping.id.uuidString
                ),
                displayName: mapping.displayName
            )
        )
    }

    func domainForCreation(
        _ mapping: DesktopDriveMapping
    ) throws -> NSFileProviderDomain {
        switch mapping.cachePolicy.location {
        case .systemDefault:
            return domain(for: mapping)
        case .eligibleVolume(let identifier):
            guard #available(macOS 15.0, *),
                  let volumeURL = Self.mountedVolumeURL(
                    identifier: identifier
                  ) else {
                throw CocoaError(.fileNoSuchFile)
            }
            guard case .eligible =
                    try NSFileProviderManager.checkDomainsCanBeStoredOnVolume(
                        at: volumeURL
                    ) else {
                throw CocoaError(.fileWriteUnsupportedScheme)
            }
            return Self.configureDomain(
                NSFileProviderDomain(
                    displayName: mapping.displayName,
                    userInfo: ["mappingID": mapping.id.uuidString],
                    volumeURL: volumeURL
                )
            )
        }
    }

    static func configureDomain(
        _ domain: NSFileProviderDomain
    ) -> NSFileProviderDomain {
        domain.supportsSyncingTrash = false
        return domain
    }

    func manager(
        for mapping: DesktopDriveMapping
    ) -> NSFileProviderManager? {
        NSFileProviderManager(for: domain(for: mapping))
    }

    @available(macOS 15.0, *)
    static func mountedVolumeURL(identifier: String) -> URL? {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey]
        return FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        )?.first {
            (try? $0.resourceValues(forKeys: keys).volumeUUIDString)
                == identifier
        }
    }

    nonisolated func add(_ domain: NSFileProviderDomain) async throws {
        try await DesktopDriveFileProviderCallbackBridge.add(domain)
    }

    nonisolated func remove(_ domain: NSFileProviderDomain) async throws {
        try await DesktopDriveFileProviderCallbackBridge.remove(domain)
    }

    nonisolated func registeredDomainIdentifiers() async throws -> Set<String> {
        try await DesktopDriveFileProviderCallbackBridge
            .registeredDomainIdentifiers()
    }

    nonisolated func removeRegisteredDomain(identifier: String) async throws {
        try await DesktopDriveFileProviderCallbackBridge
            .removeRegisteredDomain(identifier: identifier)
    }

    nonisolated func userVisibleURL(
        manager: NSFileProviderManager
    ) async throws -> URL {
        try await DesktopDriveFileProviderCallbackBridge
            .userVisibleURL(manager: manager)
    }

    nonisolated func evict(
        identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager
    ) async throws {
        try await DesktopDriveFileProviderCallbackBridge.evict(
            identifier: identifier,
            manager: manager
        )
    }

    nonisolated func requestDownload(
        identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager
    ) async throws {
        try await DesktopDriveFileProviderCallbackBridge.requestDownload(
            identifier: identifier,
            manager: manager
        )
    }

    nonisolated func signalRoot(
        _ manager: NSFileProviderManager
    ) async throws {
        try await DesktopDriveFileProviderCallbackBridge.signalRoot(manager)
    }

    nonisolated func disconnect(
        _ manager: NSFileProviderManager,
        reason: String
    ) async throws {
        try await DesktopDriveFileProviderCallbackBridge.disconnect(
            manager,
            reason: reason
        )
    }

    nonisolated func reconnect(_ manager: NSFileProviderManager) async throws {
        try await DesktopDriveFileProviderCallbackBridge.reconnect(manager)
    }
}

enum DesktopDriveFileProviderCallbackBridge {
    nonisolated static func add(_ domain: NSFileProviderDomain) async throws {
        try await DesktopDriveAsyncCallbackBridge.void { completion in
            NSFileProviderManager.add(domain) { error in
                completion(error)
            }
        }
    }

    nonisolated static func remove(
        _ domain: NSFileProviderDomain
    ) async throws {
        try await DesktopDriveAsyncCallbackBridge.void { completion in
            NSFileProviderManager.remove(
                domain,
                mode: .preserveDownloadedUserData
            ) { _, error in
                completion(error)
            }
        }
    }

    nonisolated static func registeredDomainIdentifiers()
        async throws -> Set<String> {
        try await DesktopDriveAsyncCallbackBridge.value { completion in
            NSFileProviderManager.getDomainsWithCompletionHandler {
                domains,
                error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(
                        .success(Set(domains.map(\.identifier.rawValue)))
                    )
                }
            }
        }
    }

    nonisolated static func removeRegisteredDomain(
        identifier: String
    ) async throws {
        try await DesktopDriveAsyncCallbackBridge.void { completion in
            NSFileProviderManager.getDomainsWithCompletionHandler {
                domains,
                error in
                if let error {
                    completion(error)
                    return
                }
                guard let domain = domains.first(where: {
                    $0.identifier.rawValue == identifier
                }) else {
                    completion(nil)
                    return
                }
                NSFileProviderManager.remove(
                    domain,
                    mode: .preserveDownloadedUserData
                ) { _, removeError in
                    completion(removeError)
                }
            }
        }
    }

    nonisolated static func userVisibleURL(
        manager: NSFileProviderManager
    ) async throws -> URL {
        try await DesktopDriveAsyncCallbackBridge.value { completion in
            manager.getUserVisibleURL(for: .rootContainer) { url, error in
                if let error {
                    completion(.failure(error))
                } else if let url {
                    completion(.success(url))
                } else {
                    completion(.failure(CocoaError(.fileNoSuchFile)))
                }
            }
        }
    }

    nonisolated static func evict(
        identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager
    ) async throws {
        try await DesktopDriveAsyncCallbackBridge.void { completion in
            manager.evictItem(identifier: identifier) { error in
                completion(error)
            }
        }
    }

    nonisolated static func requestDownload(
        identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager
    ) async throws {
        try await DesktopDriveAsyncCallbackBridge.void { completion in
            manager.requestDownloadForItem(
                withIdentifier: identifier,
                requestedRange: NSRange(location: NSNotFound, length: 0)
            ) { error in
                completion(error)
            }
        }
    }

    nonisolated static func signalRoot(
        _ manager: NSFileProviderManager
    ) async throws {
        try await DesktopDriveAsyncCallbackBridge.void { completion in
            manager.signalEnumerator(for: .rootContainer) { error in
                completion(error)
            }
        }
    }

    nonisolated static func disconnect(
        _ manager: NSFileProviderManager,
        reason: String
    ) async throws {
        try await DesktopDriveAsyncCallbackBridge.void { completion in
            manager.disconnect(
                reason: reason,
                options: [.temporary]
            ) { error in
                completion(error)
            }
        }
    }

    nonisolated static func reconnect(
        _ manager: NSFileProviderManager
    ) async throws {
        try await DesktopDriveAsyncCallbackBridge.void { completion in
            manager.reconnect { error in
                completion(error)
            }
        }
    }
}

enum DesktopDriveAsyncCallbackBridge {
    typealias VoidCompletion = @Sendable (Error?) -> Void

    nonisolated static func void(
        _ register: (@escaping VoidCompletion) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            register { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    nonisolated static func value<T: Sendable>(
        _ register: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<T, Error>) in
            register { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

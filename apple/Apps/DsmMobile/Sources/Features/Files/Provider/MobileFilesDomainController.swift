import FileProvider
import Foundation
import DsmCore

protocol MobileFilesDomainControlling: Sendable {
    func registrations() async throws -> [UUID: Bool]
    func add(_ location: MobileFilesLocation) async throws
    func signal(_ location: MobileFilesLocation) async throws
    func captureLocalChanges(_ location: MobileFilesLocation) async throws
    func recover(_ record: DesktopDriveWritebackRecord, location: MobileFilesLocation) async throws
    func settle(_ location: MobileFilesLocation) async throws
    func remove(_ location: MobileFilesLocation) async throws
}

struct MobileFilesDomainController: MobileFilesDomainControlling {
    func registrations() async throws -> [UUID: Bool] {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: Dictionary(domains.compactMap { domain in
                    UUID(uuidString: domain.identifier.rawValue).map { ($0, domain.userEnabled) }
                }, uniquingKeysWith: { _, latest in latest })) }
            }
        }
    }

    func add(_ location: MobileFilesLocation) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.add(location.domain) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func signal(_ location: MobileFilesLocation) async throws {
        let manager = try manager(location)
        try await manager.signalEnumerator(for: .rootContainer)
        try await manager.signalEnumerator(for: .workingSet)
    }

    func captureLocalChanges(_ location: MobileFilesLocation) async throws {
        try MobileFilesDependencies.localBridge(for: location).storage.capturePendingFiles()
    }

    func recover(_ record: DesktopDriveWritebackRecord, location: MobileFilesLocation) async throws {
        try await MobileFilesDependencies.localBridge(for: location).recover(record)
    }

    func settle(_ location: MobileFilesLocation) async throws {
        try MobileFilesDependencies.localBridge(for: location).storage.requireNoUnsavedChanges()
    }

    func remove(_ location: MobileFilesLocation) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.remove(location.domain) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func manager(_ location: MobileFilesLocation) throws -> NSFileProviderManager {
        guard let manager = NSFileProviderManager(for: location.domain) else { throw NSFileProviderError(.providerNotFound) }
        return manager
    }
}

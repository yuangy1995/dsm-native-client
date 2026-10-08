import Darwin
import DsmCore
import FileProvider
import Foundation

struct MobileFilesLocation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let profile: NasProfile
    let createdAt: Date

    var identity: MobileWorkspaceIdentity { MobileWorkspaceIdentity(profile) }
    var mapping: DesktopDriveMapping {
        .init(id: id, profileID: profile.id, displayName: profile.displayName, scope: .allShares,
            cachePolicy: .init(temporaryLimitBytes: 512 * 1_024 * 1_024), launchAtLogin: false,
            providerDomainIdentifier: id.uuidString, createdAt: createdAt)
    }

    var domain: NSFileProviderDomain {
        NSFileProviderDomain(identifier: .init(id.uuidString), displayName: profile.displayName,
                             pathRelativeToDocumentStorage: id.uuidString)
    }
}

/// 域编号与最初账号、地址和信任边界绑定；共享会话重新发布不会改变域身份。
struct MobileFilesLocationStore: Sendable {
    private struct Snapshot: Codable { var version = 1; var locations: [MobileFilesLocation] = [] }
    let rootURL: URL

    static func live() throws -> Self {
        try .init(rootURL: MobileExtensionStorage.rootURL().appendingPathComponent("Files", isDirectory: true))
    }

    func locations() throws -> [MobileFilesLocation] { try locked { try load().locations } }

    func location(id: UUID) throws -> MobileFilesLocation {
        guard let location = try locations().first(where: { $0.id == id }) else {
            throw NSFileProviderError(.providerNotFound)
        }
        return location
    }

    func reserve(account: MobileExtensionAccount) throws -> MobileFilesLocation {
        try locked {
            var snapshot = try load()
            if let existing = snapshot.locations.first(where: {
                $0.identity == account.identity && $0.profile.pinnedCertificateSHA256 == account.profile.pinnedCertificateSHA256
            }) { return existing }
            let location = MobileFilesLocation(id: UUID(), profile: account.profile, createdAt: Date())
            snapshot.locations.append(location)
            try save(snapshot)
            return location
        }
    }

    func requireCurrent(_ location: MobileFilesLocation, accounts: MobileExtensionAccountStore) throws -> MobileExtensionAccount {
        guard try self.location(id: location.id) == location,
              let account = try accounts.accounts().first(where: {
                  $0.identity == location.identity && $0.profile.pinnedCertificateSHA256 == location.profile.pinnedCertificateSHA256
              }) else { throw NSFileProviderError(.notAuthenticated) }
        try accounts.requireCurrent(account)
        return account
    }

    func remove(_ location: MobileFilesLocation) throws {
        try locked {
            var snapshot = try load()
            guard snapshot.locations.contains(location) else { throw NSFileProviderError(.providerNotFound) }
            snapshot.locations.removeAll { $0.id == location.id }
            try save(snapshot)
        }
    }

    func directory(id: UUID) throws -> URL {
        let directory = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try MobileExtensionStorage.prepareDirectory(directory)
        return directory
    }

    func configurationStore(id: UUID) throws -> DesktopDriveConfigurationStore {
        try .init(directoryURL: directory(id: id))
    }

    func writebackStore(id: UUID) throws -> DesktopDriveWritebackStore { try .init(directory: directory(id: id)) }

    private var recordsURL: URL { rootURL.appendingPathComponent("locations-v1.json") }

    private func load() throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: recordsURL.path) else { return Snapshot() }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: recordsURL))
        guard snapshot.version == 1, Set(snapshot.locations.map(\.id)).count == snapshot.locations.count else {
            throw MobileExtensionAccountError.invalidRecord
        }
        return snapshot
    }

    private func save(_ snapshot: Snapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: recordsURL, options: [.atomic, .completeFileProtection])
    }

    private func locked<Value>(_ body: () throws -> Value) throws -> Value {
        try MobileExtensionStorage.prepareDirectory(rootURL)
        let descriptor = open(rootURL.appendingPathComponent("locations.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

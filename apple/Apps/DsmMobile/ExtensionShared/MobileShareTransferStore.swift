import Darwin
import DsmCore
import Foundation

struct MobileShareTransfer: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let profileID: UUID
    let context: String
    let displayName: String
    let createdAt: Date
}

/// 每次分享有独立目录。系统关闭扩展后文件锁自动释放，主 App 才能接手该队列。
struct MobileShareTransferStore: Sendable {
    let rootURL: URL

    func create(profile: NasProfile) throws -> (MobileShareTransfer, MobileShareTransferLease) {
        let record = MobileShareTransfer(id: UUID(), profileID: profile.id,
            context: MobileWorkspaceIdentity(profile).storageIdentifier, displayName: profile.displayName, createdAt: Date())
        let directory = directory(record.id)
        try MobileExtensionStorage.prepareDirectory(directory)
        do {
            let lock = directory.appendingPathComponent("owner.lock")
            try Data().write(to: lock, options: [.atomic, .completeFileProtection])
            let lease = try MobileShareTransferLease(url: lock)
            try JSONEncoder().encode(record).write(to: manifest(record.id), options: [.atomic, .completeFileProtection])
            return (record, lease)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func records() throws -> [MobileShareTransfer] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            .compactMap { url -> MobileShareTransfer? in
                guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
                // create 在写完 manifest 前的目录尚不可交付，不属于恢复记录。
                guard FileManager.default.fileExists(atPath: manifest(id).path) else { return nil }
                let record = try JSONDecoder().decode(MobileShareTransfer.self, from: Data(contentsOf: manifest(id)))
                guard record.id == id, !record.context.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                return record
            }.sorted { $0.createdAt < $1.createdAt }
    }

    func claim(_ record: MobileShareTransfer) throws -> MobileShareTransferLease {
        let lease = try MobileShareTransferLease(url: directory(record.id).appendingPathComponent("owner.lock"))
        let persisted = try JSONDecoder().decode(MobileShareTransfer.self, from: Data(contentsOf: manifest(record.id)))
        guard persisted == record else { throw CocoaError(.fileReadCorruptFile) }
        return lease
    }

    func queueURL(_ id: UUID) -> URL { directory(id).appendingPathComponent("Queue", isDirectory: true) }
    func incomingURL(_ id: UUID) -> URL { directory(id).appendingPathComponent("Incoming", isDirectory: true) }

    func remove(_ record: MobileShareTransfer, lease: MobileShareTransferLease) throws {
        guard lease.url == directory(record.id).appendingPathComponent("owner.lock") else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: directory(record.id))
    }

    private func directory(_ id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func manifest(_ id: UUID) -> URL { directory(id).appendingPathComponent("share.json") }
}

final class MobileShareTransferLease: Sendable {
    enum LeaseError: Error { case alreadyOwned }
    let url: URL
    private let descriptor: Int32

    init(url: URL) throws {
        let descriptor = open(url.path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { throw LeaseError.alreadyOwned }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.url = url
        self.descriptor = descriptor
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

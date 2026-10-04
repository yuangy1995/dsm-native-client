import DsmCore
import Foundation

/// 一次明确确认的原件列表；未提交项暂停，已提交项只能查询，终态用于展示逐项数量。
public struct PhotoDeletionRecovery: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public let identity: String
    public var entries: [SynologyPhotoDeletionCheckpoint]
    public init(photos: [SynologyPhoto], identity: String) throws {
        version = 1; id = UUID(); self.identity = identity
        entries = try photos.map { try .init(photo: $0, operationID: UUID(), identity: identity) }
        try validate()
    }
    public var isFinished: Bool { entries.allSatisfy(\.isFinished) }
    public func count(_ state: SynologyPhotoDeletionCheckpoint.State) -> Int { entries.filter { $0.state == state }.count }
    public func validate() throws {
        guard version == 1, !entries.isEmpty, entries.count <= 100,
              Set(entries.map(\.operationID)).count == entries.count,
              Set(entries.map { $0.target.id }).count == entries.count,
              entries.allSatisfy({ $0.identity == identity }) else { throw CocoaError(.coderReadCorrupt) }
        for entry in entries { try entry.validate() }
    }
}

/// 与相册/上传回执分开的原子文件；旧会话不可覆盖新账号的记录。
public final class PhotoDeletionRecoveryStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var acceptsWrites = true
    public init(url: URL) { self.url = url }
    public func suspendWrites() { lock.withLock { acceptsWrites = false } }
    public func load() throws -> PhotoDeletionRecovery? { try lock.withLock { try read() } }
    public func save(_ value: PhotoDeletionRecovery) throws {
        try lock.withLock {
            if let previous = try read(), !previous.isFinished { throw CocoaError(.fileWriteNoPermission) }
            try write(value)
        }
    }
    public func update(_ checkpoint: SynologyPhotoDeletionCheckpoint, batchID: UUID) throws {
        try lock.withLock {
            guard var batch = try read(), batch.id == batchID,
                  let index = batch.entries.firstIndex(where: { $0.operationID == checkpoint.operationID }) else { throw CocoaError(.fileWriteNoPermission) }
            let previous = batch.entries[index]
            guard previous.identity == checkpoint.identity, previous.target == checkpoint.target,
                  previous.takenAtDigest == checkpoint.takenAtDigest,
                  previous.state == checkpoint.state ||
                    (previous.state == .prepared && [.submitted, .cancelled].contains(checkpoint.state)) ||
                    (previous.state == .submitted && [.confirmed, .rejected].contains(checkpoint.state)) else { throw CocoaError(.fileWriteNoPermission) }
            batch.entries[index] = checkpoint
            try write(batch)
        }
    }
    private func read() throws -> PhotoDeletionRecovery? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(PhotoDeletionRecovery.self, from: Data(contentsOf: url))
        try value.validate(); return value
    }
    private func write(_ value: PhotoDeletionRecovery) throws {
        guard acceptsWrites else { throw CocoaError(.fileWriteNoPermission) }
        try value.validate()
        let root = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
        var protected = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try JSONEncoder().encode(value).write(to: url, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

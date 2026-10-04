import DsmCore
import Foundation

/// 原子保存一个在途相册操作；只有明确终态才能移除，旧会话不能覆盖新记录。
public final class PhotoAlbumRecoveryStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var acceptsWrites = true

    public init(url: URL) { self.url = url }
    public func suspendWrites() { lock.withLock { acceptsWrites = false } }

    public func load() throws -> SynologyPhotosAlbumCheckpoint? {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let checkpoint = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: Data(contentsOf: url))
            _ = try checkpoint.reviewMutation()
            return checkpoint
        }
    }

    public func save(_ checkpoint: SynologyPhotosAlbumCheckpoint) throws {
        try lock.withLock {
            guard acceptsWrites else { throw CocoaError(.fileWriteNoPermission) }
            _ = try checkpoint.reviewMutation()
            let root = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
            var protected = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protected.setResourceValues(values)
            try JSONEncoder().encode(checkpoint).write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try JSONEncoder().encode(checkpoint).write(to: url, options: [.atomic])
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    public func clear(operationID: UUID) throws {
        try lock.withLock {
            guard acceptsWrites else { throw CocoaError(.fileWriteNoPermission) }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let checkpoint = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: Data(contentsOf: url))
            guard checkpoint.operationID == operationID else { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
    }
}

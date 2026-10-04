import DsmCore
import Foundation

/// 临时分享的后续阶段与操作回执分开保存；不包含链接、口令或访问凭据。
struct PhotoTemporarySharingRecovery: Codable, Sendable {
    enum Phase: String, Codable { case creating, configure, copy, stop, delete }
    struct Album: Codable, Sendable {
        let id: Int
        let name: String
        init(_ album: SynologyPhotoCollection) { id = album.id; name = album.name }
        var collection: SynologyPhotoCollection { .init(id: id, name: name) }
    }
    let version: Int
    let id: UUID
    let identity: String
    var phase: Phase
    var album: Album?
    var preservedCopy: Album?
    var cancelled = false

    init(id: UUID, identity: String, phase: Phase, album: SynologyPhotoCollection? = nil) {
        version = 1; self.id = id; self.identity = identity; self.phase = phase
        self.album = album.map(Album.init)
    }
    func validate() throws {
        guard version == 1, !identity.isEmpty, phase == .creating || album != nil,
              album.map({ $0.id > 0 && !$0.name.isEmpty }) ?? true,
              preservedCopy.map({ $0.id > 0 && $0.id != album?.id && !$0.name.isEmpty }) ?? true else { throw CocoaError(.coderReadCorrupt) }
    }
}

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
            try writeProtected(checkpoint, to: url)
        }
    }

    private var temporaryURL: URL { url.deletingLastPathComponent().appendingPathComponent("temporary-v1.json") }
    func loadTemporarySharing() throws -> PhotoTemporarySharingRecovery? {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: temporaryURL.path) else { return nil }
            let value = try JSONDecoder().decode(PhotoTemporarySharingRecovery.self, from: Data(contentsOf: temporaryURL))
            try value.validate(); return value
        }
    }
    func saveTemporarySharing(_ value: PhotoTemporarySharingRecovery) throws {
        try lock.withLock {
            guard acceptsWrites else { throw CocoaError(.fileWriteNoPermission) }
            try value.validate(); try writeProtected(value, to: temporaryURL)
        }
    }
    func clearTemporarySharing(id: UUID) throws {
        try lock.withLock {
            guard acceptsWrites else { throw CocoaError(.fileWriteNoPermission) }
            guard FileManager.default.fileExists(atPath: temporaryURL.path) else { return }
            let value = try JSONDecoder().decode(PhotoTemporarySharingRecovery.self, from: Data(contentsOf: temporaryURL))
            guard value.id == id else { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: temporaryURL)
        }
    }
    private func writeProtected<T: Encodable>(_ value: T, to destination: URL) throws {
        let root = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
        var protected = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        try JSONEncoder().encode(value).write(to: destination, options: [.atomic, .completeFileProtection])
        #else
        try JSONEncoder().encode(value).write(to: destination, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
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

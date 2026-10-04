import CryptoKit
import DsmCore
import Foundation

struct PhotoUploadCollectionSnapshot: Codable {
    let id: Int
    let name: String
    let parentID: Int?
    let space: SynologyPhotoSpace
    let conditional: Bool
    let frozen: Bool
    init(_ value: SynologyPhotoCollection) {
        id = value.id; name = value.name; parentID = value.parentID; space = value.space
        conditional = value.isConditional; frozen = value.isFrozen
    }
    var collection: SynologyPhotoCollection {
        .init(id: id, name: name, parentID: parentID, isConditional: conditional, isFrozen: frozen, space: space)
    }
}

struct PhotoUploadSavedEntry: Codable {
    let id: UUID
    let filename: String
    let size: Int64
    let modifiedAt: Date
    let bookmark: Data?
    let relativeComponents: [String]
    let directories: [String]
    let album: PhotoUploadCollectionSnapshot?
    let folder: PhotoUploadCollectionSnapshot?
    let space: SynologyPhotoSpace
    let directAlbumUpload: Bool
    let duplicate: String
    let ignoredDuplicate: Bool
    let state: PhotoUploadEntry.State
    let uploadedPhoto: SynologyPhotoUploadPhoto?
    let batchID: UUID

    init(_ entry: PhotoUploadEntry, previous: Self?, bookmarkAccess: any PhotoUploadBookmarkAccess) throws {
        id = entry.id; filename = entry.file.url.lastPathComponent
        size = entry.file.size; modifiedAt = entry.file.modifiedAt
        if let bookmark = entry.file.recoveryBookmark {
            self.bookmark = bookmark; relativeComponents = entry.file.recoveryRelativeComponents
        } else if let previous {
            bookmark = previous.bookmark; relativeComponents = previous.relativeComponents
        } else if [.completed, .skipped, .cancelled].contains(entry.state) {
            bookmark = nil; relativeComponents = []
        } else {
            let root = entry.file.sourceAccess?.url ?? entry.file.url
            let base = root.standardizedFileURL.pathComponents
            let path = entry.file.url.standardizedFileURL.pathComponents
            guard path.starts(with: base) else { throw CocoaError(.fileReadNoPermission) }
            relativeComponents = Array(path.dropFirst(base.count))
            bookmark = try bookmarkAccess.makeBookmark(for: root)
        }
        directories = entry.file.directoryComponents
        album = entry.album.map(PhotoUploadCollectionSnapshot.init); folder = entry.folder.map(PhotoUploadCollectionSnapshot.init)
        space = entry.space; directAlbumUpload = entry.directAlbumUpload; duplicate = entry.duplicate.rawValue
        ignoredDuplicate = entry.ignoredDuplicate; state = entry.state
        uploadedPhoto = entry.uploadedPhoto.map(SynologyPhotoUploadPhoto.init); batchID = entry.batchID
    }

    func restore(bookmarkAccess: any PhotoUploadBookmarkAccess) throws -> PhotoUploadEntry {
        guard let duplicate = SynologyPhotoDuplicateSettings.Upload(rawValue: duplicate),
              relativeComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else { throw CocoaError(.coderReadCorrupt) }
        var file = PhotoUploadFile(id: id, url: URL(fileURLWithPath: "/").appendingPathComponent(filename), size: size, modifiedAt: modifiedAt,
                                   directoryComponents: directories, requiresSourceSelection: true,
                                   recoveryBookmark: bookmark, recoveryRelativeComponents: relativeComponents)
        if let bookmark {
            if let resolved = try? bookmarkAccess.resolve(bookmark) {
                let root = resolved.url
                let stale = resolved.isStale
                let access = PhotoUploadSourceAccess(url: root)
                let source = relativeComponents.reduce(root) { $0.appendingPathComponent($1) }
                if !stale, let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                   values.isRegularFile == true, values.isSymbolicLink != true,
                   values.fileSize.map(Int64.init) == size, values.contentModificationDate == modifiedAt {
                    file = PhotoUploadFile(id: id, url: source, size: size, modifiedAt: modifiedAt, sourceAccess: access,
                                           directoryComponents: directories, recoveryBookmark: bookmark, recoveryRelativeComponents: relativeComponents)
                }
            }
        }
        let restoredState: PhotoUploadEntry.State = [.queued, .preparingFolders, .uploading, .addingToAlbum].contains(state) ? .cancelled : state
        return PhotoUploadEntry(file: file, album: album?.collection, folder: folder?.collection, space: space,
                                directAlbumUpload: directAlbumUpload, duplicate: duplicate, ignoredDuplicate: ignoredDuplicate,
                                state: restoredState, progress: uploadedPhoto == nil ? 0 : 1, uploadedPhoto: uploadedPhoto?.photo, batchID: batchID)
    }
}

struct PhotoUploadSavedDirectory: Codable {
    let key: PhotoUploadDirectoryKey
    let folder: PhotoUploadCollectionSnapshot
}

struct PhotoUploadRecoveryDocument: Codable {
    var version = 1
    let identity: String
    let entries: [PhotoUploadSavedEntry]
    let directories: [PhotoUploadSavedDirectory]
    let pendingEntryID: UUID?
    let pendingDirectory: PhotoUploadDirectoryKey?
    let pendingOperationID: UUID?
    var checkpoint: SynologyPhotosUploadCheckpoint?
}

/// 单个文件原子替换队列和回执；网络回调必须同步完成落盘后才可发送写请求。
public final class PhotoUploadRecoveryStore: @unchecked Sendable {
    private let lock = NSLock()
    public let url: URL
    private let bookmarkAccess: any PhotoUploadBookmarkAccess
    private var document: PhotoUploadRecoveryDocument?
    private var acceptsWrites = true

    public init(url: URL, bookmarkAccess: any PhotoUploadBookmarkAccess) {
        self.url = url; self.bookmarkAccess = bookmarkAccess
    }

    /// 替换会话前冻结旧写入者，迟到回执不能覆盖新会话恢复后的队列。
    public func suspendWrites() {
        lock.withLock { acceptsWrites = false }
    }

    func sourceBookmark(for url: URL) throws -> Data { try bookmarkAccess.makeBookmark(for: url) }

    func restoredEntries(from document: PhotoUploadRecoveryDocument) throws -> [PhotoUploadEntry] {
        try document.entries.map { try $0.restore(bookmarkAccess: bookmarkAccess) }
    }

    public static func forProfile(_ profile: NasProfile, bookmarkAccess: any PhotoUploadBookmarkAccess) -> PhotoUploadRecoveryStore {
        // 连接目标或账号变化后使用独立队列，磁盘文件名不暴露地址和账号。
        let identity = [profile.id.uuidString, profile.scheme.rawValue, profile.host.lowercased(), String(profile.port), profile.usernameHint ?? ""].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LanStash/PhotoUploadRecovery", isDirectory: true)
        return .init(url: root.appendingPathComponent(digest + ".json"), bookmarkAccess: bookmarkAccess)
    }

    func load() throws -> PhotoUploadRecoveryDocument? {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { document = nil; return nil }
            let value = try JSONDecoder().decode(PhotoUploadRecoveryDocument.self, from: Data(contentsOf: url))
            guard value.version == 1, Set(value.entries.map(\.id)).count == value.entries.count,
                  Set(value.directories.map(\.key)).count == value.directories.count,
                  value.checkpoint == nil || value.checkpoint?.operationID == value.pendingOperationID,
                  value.checkpoint == nil || value.entries.contains(where: { $0.id == value.pendingEntryID }) else { throw CocoaError(.coderReadCorrupt) }
            document = value
            return value
        }
    }

    func save(identity: String, entries: [PhotoUploadEntry], directories: [PhotoUploadSavedDirectory],
              pendingEntryID: UUID?, pendingDirectory: PhotoUploadDirectoryKey?, pendingOperationID: UUID?) throws {
        try lock.withLock {
            let saved = try entries.map { entry in try PhotoUploadSavedEntry(entry, previous: document?.entries.first { $0.id == entry.id }, bookmarkAccess: bookmarkAccess) }
            let checkpoint = pendingOperationID == document?.pendingOperationID ? document?.checkpoint : nil
            let value = PhotoUploadRecoveryDocument(identity: identity, entries: saved, directories: directories,
                pendingEntryID: pendingEntryID, pendingDirectory: pendingDirectory, pendingOperationID: pendingOperationID, checkpoint: checkpoint)
            try write(value)
        }
    }

    public func checkpoint(_ checkpoint: SynologyPhotosUploadCheckpoint) throws {
        try lock.withLock {
            guard var value = document, value.pendingOperationID == checkpoint.operationID,
                  value.identity == "\(checkpoint.profileID.uuidString):\(checkpoint.userID)", value.pendingEntryID != nil else { throw CocoaError(.coderInvalidValue) }
            value.checkpoint = checkpoint
            try write(value)
        }
    }

    private func write(_ value: PhotoUploadRecoveryDocument) throws {
        guard acceptsWrites else { throw CocoaError(.fileWriteNoPermission) }
        let manager = FileManager.default
        let root = url.deletingLastPathComponent()
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
        var protectedRoot = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedRoot.setResourceValues(values)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try JSONEncoder().encode(value).write(to: url, options: [.atomic])
        #endif
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        document = value
    }
}

@MainActor
extension SynologyPhotosModel {
    public convenience init(repository: (any SynologyPhotosServing)? = nil, uploadRecoveryStore: PhotoUploadRecoveryStore?,
                     deletionReviewDelay: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.init(repository: repository, deletionReviewDelay: deletionReviewDelay)
        configureUploadRecovery(uploadRecoveryStore)
    }
}

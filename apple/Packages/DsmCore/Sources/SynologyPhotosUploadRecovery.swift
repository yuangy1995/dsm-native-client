import Foundation

/// 上传恢复专用快照；只保存核对所需身份，不包含媒体、会话或分享口令。
public struct SynologyPhotoUploadPhoto: Codable, Sendable {
    public let profileID: UUID
    public let space: SynologyPhotoSpace
    public let unitID: Int
    public let filename: String
    public let size: Int64
    public let takenAt: Date
    public let indexedAt: Date
    public let folderID: Int
    public let mediaType: String
    public let albumID: Int?
    public let ownerID: Int?
    public let providerID: Int?
    public init(_ photo: SynologyPhoto) {
        profileID = photo.id.profileID; space = photo.id.space; unitID = photo.id.unitID
        filename = photo.filename; size = photo.sizeBytes; takenAt = photo.takenAt
        indexedAt = photo.indexedAt; folderID = photo.folderID; mediaType = photo.mediaType
        albumID = photo.albumContext?.albumID; ownerID = photo.albumContext?.ownerUserID
        providerID = photo.albumContext?.providerUserID
    }
    public var photo: SynologyPhoto {
        .init(id: .init(profileID: profileID, space: space, unitID: unitID), filename: filename,
              sizeBytes: size, takenAt: takenAt, indexedAt: indexedAt, folderID: folderID, mediaType: mediaType,
              albumContext: albumID.flatMap { album in ownerID.map { .init(albumID: album, ownerUserID: $0, providerUserID: providerID) } })
    }
}

/// 持久化的操作只能恢复为只读核对，不允许重发原写请求。
public struct SynologyPhotosUploadCheckpoint: Codable, Sendable {
    public enum Operation: Codable, Sendable {
        case upload(filename: String, size: Int64, modifiedAt: Date, folderID: Int?, space: SynologyPhotoSpace, duplicate: String)
        case uploadToAlbum(filename: String, size: Int64, modifiedAt: Date, albumID: Int, duplicate: String)
        case createFolder(parentID: Int, name: String, space: SynologyPhotoSpace)
        case addToAlbum(albumID: Int, photo: SynologyPhotoUploadPhoto)
    }
    public let version: Int
    public let profileID: UUID
    public let userID: Int
    public let operationID: UUID
    public let operation: Operation
    public var itemID: Int?
    public var folderID: Int?
    public var uploadAction: String?
    public var membershipHasFailures = false
    public var rejected = false

    public init(mutation: SynologyPhotosMutation, operationID: UUID, profileID: UUID, userID: Int) throws {
        version = 1; self.profileID = profileID; self.userID = userID; self.operationID = operationID
        switch mutation {
        case .upload(let file, let size, let modifiedAt, let folderID, let space, let duplicate):
            operation = .upload(filename: file.lastPathComponent, size: size, modifiedAt: modifiedAt, folderID: folderID, space: space, duplicate: duplicate.rawValue)
        case .uploadToAlbum(let file, let size, let modifiedAt, let albumID, let duplicate):
            operation = .uploadToAlbum(filename: file.lastPathComponent, size: size, modifiedAt: modifiedAt, albumID: albumID, duplicate: duplicate.rawValue)
        case .createFolder(let parentID, let name, let space): operation = .createFolder(parentID: parentID, name: name, space: space)
        case .addToAlbum(let albumID, let photos) where photos.count == 1:
            operation = .addToAlbum(albumID: albumID, photo: .init(photos[0]))
        default: throw CocoaError(.coderInvalidValue)
        }
    }

    /// 路径只用于比较文件名；恢复入口绝不读取本地媒体或执行上传。
    public func reviewMutation() throws -> SynologyPhotosMutation {
        guard version == 1, userID > 0 else { throw CocoaError(.coderReadCorrupt) }
        switch operation {
        case .upload(let filename, let size, let modified, let folder, let space, let duplicate):
            guard let policy = SynologyPhotoDuplicateSettings.Upload(rawValue: duplicate) else { throw CocoaError(.coderReadCorrupt) }
            return .upload(file: URL(fileURLWithPath: "/").appendingPathComponent(filename), size: size, modifiedAt: modified, folderID: folder, space: space, duplicate: policy)
        case .uploadToAlbum(let filename, let size, let modified, let album, let duplicate):
            guard let policy = SynologyPhotoDuplicateSettings.Upload(rawValue: duplicate) else { throw CocoaError(.coderReadCorrupt) }
            return .uploadToAlbum(file: URL(fileURLWithPath: "/").appendingPathComponent(filename), size: size, modifiedAt: modified, albumID: album, duplicate: policy)
        case .createFolder(let parent, let name, let space): return .createFolder(parentID: parent, name: name, space: space)
        case .addToAlbum(let album, let photo):
            guard photo.profileID == profileID else { throw CocoaError(.coderReadCorrupt) }
            return .addToAlbum(id: album, photos: [photo.photo])
        }
    }
}

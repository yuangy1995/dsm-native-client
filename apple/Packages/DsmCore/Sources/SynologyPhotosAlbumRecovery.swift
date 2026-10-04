import Foundation

/// 普通相册恢复只保留回读需要的身份，不包含媒体、认证资料或分享链接。
public struct SynologyPhotosAlbumCheckpoint: Codable, Sendable {
    public enum Operation: Codable, Sendable {
        case create(name: String, photos: [SynologyPhotoUploadPhoto])
        case rename(id: Int, name: String)
        case delete(id: Int)
        case add(id: Int, photos: [SynologyPhotoUploadPhoto])
        case remove(id: Int, photos: [SynologyPhotoUploadPhoto])
        case cover(id: Int, photo: SynologyPhotoUploadPhoto)
    }
    public let version: Int
    public let profileID: UUID
    public let userID: Int
    public let operationID: UUID
    public let operation: Operation
    public var createdAlbumID: Int?
    public var membershipHasFailures = false
    public var rejected = false

    public static func supports(_ mutation: SynologyPhotosMutation) -> Bool {
        switch mutation {
        case .createAlbum, .renameAlbum, .deleteAlbum, .addToAlbum, .removeFromAlbum, .setAlbumCover: true
        default: false
        }
    }

    public init(mutation: SynologyPhotosMutation, operationID: UUID, profileID: UUID, userID: Int) throws {
        version = 1; self.profileID = profileID; self.userID = userID; self.operationID = operationID
        switch mutation {
        case .createAlbum(let name, let photos): operation = .create(name: name, photos: photos.map(SynologyPhotoUploadPhoto.init))
        case .renameAlbum(let id, let name): operation = .rename(id: id, name: name)
        case .deleteAlbum(let id): operation = .delete(id: id)
        case .addToAlbum(let id, let photos): operation = .add(id: id, photos: photos.map(SynologyPhotoUploadPhoto.init))
        case .removeFromAlbum(let id, let photos): operation = .remove(id: id, photos: photos.map(SynologyPhotoUploadPhoto.init))
        case .setAlbumCover(let id, let photo): operation = .cover(id: id, photo: .init(photo))
        default: throw CocoaError(.coderInvalidValue)
        }
        _ = try reviewMutation()
    }

    /// 只交给 restoreAlbumMutation；恢复接口不执行原写请求。
    public func reviewMutation() throws -> SynologyPhotosMutation {
        guard version == 1, userID > 0, createdAlbumID.map({ $0 > 0 }) ?? true else { throw CocoaError(.coderReadCorrupt) }
        let command: SynologyPhotosMutation
        switch operation {
        case .create(let name, let photos): command = .createAlbum(name: name, photos: photos.map(\.photo))
        case .rename(let id, let name): command = .renameAlbum(id: id, name: name)
        case .delete(let id): command = .deleteAlbum(id: id)
        case .add(let id, let photos): command = .addToAlbum(id: id, photos: photos.map(\.photo))
        case .remove(let id, let photos): command = .removeFromAlbum(id: id, photos: photos.map(\.photo))
        case .cover(let id, let photo): command = .setAlbumCover(id: id, photo: photo.photo)
        }
        let photos = command.photos
        guard photos.count <= 100, Set(photos.map(\.id)).count == photos.count,
              photos.allSatisfy({ $0.id.profileID == profileID && $0.id.unitID > 0 && $0.folderID > 0 }) else { throw CocoaError(.coderReadCorrupt) }
        switch command {
        case .createAlbum(let name, _): guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.coderReadCorrupt) }
        case .renameAlbum(let id, let name): guard id > 0, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.coderReadCorrupt) }
        case .deleteAlbum(let id): guard id > 0 else { throw CocoaError(.coderReadCorrupt) }
        case .addToAlbum(let id, _), .removeFromAlbum(let id, _), .setAlbumCover(let id, _):
            guard id > 0, !photos.isEmpty else { throw CocoaError(.coderReadCorrupt) }
        default: throw CocoaError(.coderReadCorrupt)
        }
        return command
    }
}

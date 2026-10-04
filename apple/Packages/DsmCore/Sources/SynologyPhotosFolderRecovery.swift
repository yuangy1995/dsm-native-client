import Foundation

extension SynologyPhotosAlbumCheckpoint {
    /// 目录操作沿用原对象与任务回执；路径仅用于 NAS 对象回读，不能用于本机文件读写。
    public struct FolderOperation: Codable, Sendable {
        public struct Folder: Codable, Sendable {
            let id: Int
            let parentID: Int?
            let name: String
            let path: String?
            let space: SynologyPhotoSpace

            init(_ folder: SynologyPhotoCollection) {
                id = folder.id; parentID = folder.parentID; name = folder.name
                path = folder.path; space = folder.space
            }
            var collection: SynologyPhotoCollection {
                .init(id: id, name: name, parentID: parentID, path: path, space: space)
            }
        }
        public enum Intent: Codable, Sendable {
            case create(parentID: Int, name: String, space: SynologyPhotoSpace)
            case rename(Folder, name: String)
            case sort(Folder, field: String, direction: String)
            case cover(Folder, photo: SynologyPhotoUploadPhoto)
            case delete(photos: [SynologyPhotoUploadPhoto], folders: [Folder])
            case transfer(copying: Bool, photos: [SynologyPhotoUploadPhoto], folders: [Folder], targetID: Int, space: SynologyPhotoSpace, duplicate: String)
        }
        public let intent: Intent
        public var taskID: Int?
        public var createdFolderID: Int?
        public var transferTargetVerified = false
        public var transferTotal: Int?
        public var coverAcknowledged = false

        public init(mutation: SynologyPhotosMutation) throws {
            switch mutation {
            case .createFolder(let parent, let name, let space): intent = .create(parentID: parent, name: name, space: space)
            case .renameFolder(let folder, let name): intent = .rename(.init(folder), name: name)
            case .setFolderSort(let folder, let sort): intent = .sort(.init(folder), field: sort.field.rawValue, direction: sort.direction.rawValue)
            case .setFolderCover(let folder, let photo): intent = .cover(.init(folder), photo: .init(photo))
            case .deleteFolderItems(let photos, let folders): intent = .delete(photos: photos.map(SynologyPhotoUploadPhoto.init), folders: folders.map(Folder.init))
            case .move(let photos, let id, _, let folders, let duplicate), .copy(let photos, let id, _, let folders, let duplicate):
                let copying = if case .copy = mutation { true } else { false }
                intent = .transfer(copying: copying, photos: photos.map(SynologyPhotoUploadPhoto.init), folders: folders.map(Folder.init),
                    targetID: id, space: mutation.destinationSpace, duplicate: duplicate.rawValue)
            default: throw CocoaError(.coderInvalidValue)
            }
        }

        public func hasSameIntent(as mutation: SynologyPhotosMutation, profileID: UUID) -> Bool {
            guard let other = try? Self(mutation: mutation),
                  let expected = try? other.reviewMutation(profileID: profileID),
                  let current = try? reviewMutation(profileID: profileID) else { return false }
            return current == expected
        }

        func reviewMutation(profileID: UUID) throws -> SynologyPhotosMutation {
            let mutation: SynologyPhotosMutation
            var folders: [Folder] = []
            var photos: [SynologyPhotoUploadPhoto] = []
            var allowsTask = false, allowsCreated = false, allowsTransfer = false, allowsCover = false
            switch intent {
            case .create(let parent, let name, let space):
                guard parent > 0, SynologyPhotosMutation.isValidFolderName(name) else { throw CocoaError(.coderReadCorrupt) }
                mutation = .createFolder(parentID: parent, name: name, space: space); allowsCreated = true
            case .rename(let folder, let name):
                guard folder.path != "/", SynologyPhotosMutation.isValidFolderName(name) else { throw CocoaError(.coderReadCorrupt) }
                folders = [folder]; mutation = .renameFolder(folder: folder.collection, name: name)
            case .sort(let folder, let field, let direction):
                guard let field = SynologyPhotoSort.Field(rawValue: field), let direction = SynologyPhotoSort.Direction(rawValue: direction) else { throw CocoaError(.coderReadCorrupt) }
                folders = [folder]; mutation = .setFolderSort(folder: folder.collection, sort: .init(field: field, direction: direction))
            case .cover(let folder, let photo):
                guard folder.path != "/", folder.space == photo.space, photo.albumID == nil else { throw CocoaError(.coderReadCorrupt) }
                folders = [folder]; photos = [photo]; allowsCover = true
                mutation = .setFolderCover(folder: folder.collection, photo: photo.photo)
            case .delete(let values, let targets):
                guard !targets.isEmpty else { throw CocoaError(.coderReadCorrupt) }
                folders = targets; photos = values; allowsTask = true
                mutation = .deleteFolderItems(photos: values.map(\.photo), folders: targets.map(\.collection))
            case .transfer(let copying, let values, let targets, let id, let space, let duplicate):
                guard id > 0, !values.isEmpty || !targets.isEmpty,
                      let duplicate = SynologyPhotoDuplicateSettings.Transfer(rawValue: duplicate) else { throw CocoaError(.coderReadCorrupt) }
                folders = targets; photos = values; allowsTask = true; allowsTransfer = true
                mutation = copying ? .copy(values.map(\.photo), folderID: id, destinationSpace: space, folders: targets.map(\.collection), duplicate: duplicate)
                    : .move(values.map(\.photo), folderID: id, destinationSpace: space, folders: targets.map(\.collection), duplicate: duplicate)
            }
            guard photos.count + (allowsCover ? 0 : folders.count) <= 100,
                  Set(photos.map { $0.photo.id }).count == photos.count,
                  photos.allSatisfy({ $0.profileID == profileID && $0.unitID > 0 && $0.folderID > 0 && $0.size >= 0 && $0.space == mutation.space }),
                  Set(folders.map(\.id)).count == folders.count,
                  folders.allSatisfy({ folder in
                      guard folder.id > 0, folder.space == mutation.space, let path = folder.path, path.hasPrefix("/"),
                            folder.parentID.map({ $0 > 0 && $0 != folder.id }) ?? true else { return false }
                      return path == "/" || (!path.hasSuffix("/") && (path as NSString).lastPathComponent == folder.name)
                  }),
                  taskID.map({ allowsTask && $0 > 0 }) ?? true,
                  createdFolderID.map({ allowsCreated && $0 > 0 }) ?? true,
                  transferTotal.map({ allowsTransfer && $0 >= 0 }) ?? true,
                  !transferTargetVerified || (allowsTransfer && taskID != nil),
                  !coverAcknowledged || allowsCover else { throw CocoaError(.coderReadCorrupt) }
            if allowsTask, let first = folders.first {
                guard let parent = first.parentID, first.path != "/",
                      folders.allSatisfy({ $0.parentID == parent && $0.path != "/" && ($0.path! as NSString).deletingLastPathComponent == (first.path! as NSString).deletingLastPathComponent }),
                      photos.allSatisfy({ $0.folderID == parent && $0.albumID == nil }) else { throw CocoaError(.coderReadCorrupt) }
            }
            return mutation
        }
    }
}

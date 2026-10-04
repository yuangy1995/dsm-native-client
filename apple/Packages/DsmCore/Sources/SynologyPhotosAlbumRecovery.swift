import Foundation

/// 相册恢复只保留回读需要的身份，不包含媒体、认证资料或分享链接。
public struct SynologyPhotosAlbumCheckpoint: Codable, Sendable {
    public enum Operation: Codable, Sendable {
        case create(name: String, photos: [SynologyPhotoUploadPhoto])
        case rename(id: Int, name: String)
        case delete(id: Int)
        case add(id: Int, photos: [SynologyPhotoUploadPhoto])
        case remove(id: Int, photos: [SynologyPhotoUploadPhoto])
        case cover(id: Int, photo: SynologyPhotoUploadPhoto)
        case sharing(Sharing)
        case createTemporary(name: String, photos: [SynologyPhotoUploadPhoto])
        case copyTemporary(id: Int, name: String, revision: String)
        case deleteTemporary(id: Int, revision: String, preservedCopyID: Int?)
    }
    public let version: Int
    public let profileID: UUID
    public let userID: Int
    public let operationID: UUID
    public private(set) var operation: Operation
    public var createdAlbumID: Int?
    public var membershipHasFailures = false
    public var rejected = false
    public var temporaryMembers: [TemporaryMember]?

    public static func supports(_ mutation: SynologyPhotosMutation) -> Bool {
        switch mutation {
        case .createAlbum, .renameAlbum, .deleteAlbum, .addToAlbum, .removeFromAlbum, .setAlbumCover, .shareAlbum,
             .createTemporaryAlbum, .copyTemporaryAlbum, .deleteTemporaryAlbum: true
        default: false
        }
    }

    public init(mutation: SynologyPhotosMutation, operationID: UUID, profileID: UUID, userID: Int) throws {
        version = switch mutation {
        case .createTemporaryAlbum, .copyTemporaryAlbum, .deleteTemporaryAlbum: 3
        case .shareAlbum: 2
        default: 1
        }
        self.profileID = profileID; self.userID = userID; self.operationID = operationID
        switch mutation {
        case .createAlbum(let name, let photos): operation = .create(name: name, photos: photos.map(SynologyPhotoUploadPhoto.init))
        case .renameAlbum(let id, let name): operation = .rename(id: id, name: name)
        case .deleteAlbum(let id): operation = .delete(id: id)
        case .addToAlbum(let id, let photos): operation = .add(id: id, photos: photos.map(SynologyPhotoUploadPhoto.init))
        case .removeFromAlbum(let id, let photos): operation = .remove(id: id, photos: photos.map(SynologyPhotoUploadPhoto.init))
        case .setAlbumCover(let id, let photo): operation = .cover(id: id, photo: .init(photo))
        case .shareAlbum: operation = .sharing(try Sharing(mutation: mutation))
        case .createTemporaryAlbum(let name, let photos): operation = .createTemporary(name: name, photos: photos.map(SynologyPhotoUploadPhoto.init))
        case .copyTemporaryAlbum(let id, let name, let original): operation = .copyTemporary(id: id, name: name, revision: original.revision)
        case .deleteTemporaryAlbum(let id, let original, let copy): operation = .deleteTemporary(id: id, revision: original.revision, preservedCopyID: copy)
        default: throw CocoaError(.coderInvalidValue)
        }
        _ = try reviewMutation()
    }

    /// 只交给 restoreAlbumMutation；恢复接口不执行原写请求。
    public func reviewMutation() throws -> SynologyPhotosMutation {
        guard (1...3).contains(version), userID > 0, createdAlbumID.map({ $0 > 0 }) ?? true else { throw CocoaError(.coderReadCorrupt) }
        if let temporaryMembers {
            guard temporaryMembers.allSatisfy({ $0.profileID == profileID && $0.unitID > 0 && $0.folderID > 0 && $0.size >= 0 }),
                  Set(temporaryMembers.map(\.id)).count == temporaryMembers.count else { throw CocoaError(.coderReadCorrupt) }
        }
        let command: SynologyPhotosMutation
        switch operation {
        case .create(let name, let photos): command = .createAlbum(name: name, photos: photos.map(\.photo))
        case .rename(let id, let name): command = .renameAlbum(id: id, name: name)
        case .delete(let id): command = .deleteAlbum(id: id)
        case .add(let id, let photos): command = .addToAlbum(id: id, photos: photos.map(\.photo))
        case .remove(let id, let photos): command = .removeFromAlbum(id: id, photos: photos.map(\.photo))
        case .cover(let id, let photo): command = .setAlbumCover(id: id, photo: photo.photo)
        case .sharing(let value):
            guard version == 2 else { throw CocoaError(.coderReadCorrupt) }
            command = try value.reviewMutation()
        case .createTemporary(let name, let photos):
            guard version == 3, !photos.isEmpty else { throw CocoaError(.coderReadCorrupt) }
            command = .createTemporaryAlbum(name: name, photos: photos.map(\.photo))
        case .copyTemporary(let id, let name, let revision):
            guard version == 3, id > 0, !revision.isEmpty else { throw CocoaError(.coderReadCorrupt) }
            command = .copyTemporaryAlbum(id: id, name: name, original: .init(access: .disabled, revision: revision, isTemporary: true))
        case .deleteTemporary(let id, let revision, let copy):
            guard version == 3, id > 0, !revision.isEmpty, copy.map({ $0 > 0 && $0 != id }) ?? true else { throw CocoaError(.coderReadCorrupt) }
            command = .deleteTemporaryAlbum(id: id, original: .init(access: .disabled, revision: revision, isTemporary: true), preservedCopyID: copy)
        }
        let photos = command.photos
        guard photos.count <= 100, Set(photos.map(\.id)).count == photos.count,
              photos.allSatisfy({ $0.id.profileID == profileID && $0.id.unitID > 0 && $0.folderID > 0 }) else { throw CocoaError(.coderReadCorrupt) }
        switch command {
        case .createAlbum(let name, _), .createTemporaryAlbum(let name, _), .copyTemporaryAlbum(_, let name, _):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.coderReadCorrupt) }
        case .renameAlbum(let id, let name): guard id > 0, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.coderReadCorrupt) }
        case .deleteAlbum(let id): guard id > 0 else { throw CocoaError(.coderReadCorrupt) }
        case .addToAlbum(let id, _), .removeFromAlbum(let id, _), .setAlbumCover(let id, _):
            guard id > 0, !photos.isEmpty else { throw CocoaError(.coderReadCorrupt) }
        case .shareAlbum, .deleteTemporaryAlbum: break
        default: throw CocoaError(.coderReadCorrupt)
        }
        return command
    }

    public var sharingDetails: Sharing? {
        get { if case .sharing(let value) = operation { return value }; return nil }
        set { if case .sharing = operation, let newValue { operation = .sharing(newValue) } }
    }
}

extension SynologyPhotosAlbumCheckpoint {
    /// 临时相册副本必须核对完整成员，不保存缩略图引用或分享上下文。
    public struct TemporaryMember: Codable, Sendable {
        public let profileID: UUID
        public let space: SynologyPhotoSpace
        public let unitID: Int
        public let filename: String
        public let size: Int64
        public let folderID: Int
        public let indexedAt: Date
        public var id: SynologyPhotoID { .init(profileID: profileID, space: space, unitID: unitID) }
        public init(id: SynologyPhotoID, filename: String, size: Int64, folderID: Int, indexedAt: Date) {
            profileID = id.profileID; space = id.space; unitID = id.unitID
            self.filename = filename; self.size = size; self.folderID = folderID; self.indexedAt = indexedAt
        }
    }

    /// 密码只记录操作种类；成员只保留身份和角色，不保存名称、链接或分享口令。
    public struct Sharing: Codable, Equatable, Sendable {
        public enum Password: String, Codable, Sendable { case unchanged, set, remove }
        public enum Expiration: Codable, Equatable, Sendable {
            case missing, seconds(Int), unknown
            public init(_ value: SynologyPhotoConditionValue?) {
                switch value {
                case nil: self = .missing
                case .integer(let value) where value >= 0: self = .seconds(value)
                case .decimal(let value) where value >= 0:
                    self = Int(exactly: value).map(Self.seconds) ?? .unknown
                default: self = .unknown
                }
            }
            public func matches(_ value: SynologyPhotoConditionValue?) -> Bool {
                self != .unknown && self == Self(value)
            }
        }
        public struct Member: Codable, Equatable, Sendable {
            public let type: String
            public let id: SynologyPhotoConditionValue
            public let role: String
            public init(_ grant: SynologyPhotoShareGrant) { type = grant.id.type; id = grant.id.value; role = grant.role }
            public var grant: SynologyPhotoShareGrant { .init(recipient: .init(id: .init(type: type, value: id), name: ""), role: role) }
            var isValid: Bool {
                guard ["user", "group"].contains(type), !role.isEmpty else { return false }
                switch id {
                case .integer(let value): return value > 0
                case .string(let value): return !value.isEmpty
                default: return false
                }
            }
        }
        public let albumID: Int
        public let access: String
        public let members: [Member]?
        public let expiration: Int?
        public let password: Password
        public var previousMembers: [Member]?
        public var previousExpiration: Expiration = .unknown
        public var previousHasPassword: Bool?
        public var passwordAcknowledged = false
        public var enableAttempted = false
        public var isTemporary: Bool?

        public init(mutation: SynologyPhotosMutation) throws {
            guard case .shareAlbum(let id, let access, let original, let members, let expiration, let password) = mutation else { throw CocoaError(.coderInvalidValue) }
            albumID = id; self.access = access.rawValue; self.members = members?.map(Member.init)
            self.expiration = expiration; self.password = password.map { $0.isEmpty ? .remove : .set } ?? .unchanged
            isTemporary = original?.isTemporary
        }

        /// 恢复只构造查询上下文，不还原或重新提交密码。
        public func reviewMutation() throws -> SynologyPhotosMutation {
            guard albumID > 0, let access = SynologyPhotoLinkAccess(rawValue: access), expiration.map({ $0 >= 0 }) ?? true else { throw CocoaError(.coderReadCorrupt) }
            for values in [members, previousMembers].compactMap({ $0 }) {
                guard values.allSatisfy(\.isValid), Set(values.map { $0.grant.id }).count == values.count else { throw CocoaError(.coderReadCorrupt) }
            }
            if case .seconds(let value) = previousExpiration, value < 0 { throw CocoaError(.coderReadCorrupt) }
            return .shareAlbum(id: albumID, access: access,
                              original: isTemporary.map { .init(access: access, revision: "", isTemporary: $0) },
                              members: members?.map(\.grant), expiration: expiration)
        }

        public func hasSameIntent(as mutation: SynologyPhotosMutation) -> Bool {
            guard let other = try? Self(mutation: mutation) else { return false }
            return albumID == other.albumID && access == other.access && members == other.members && expiration == other.expiration && password == other.password
        }
    }
}

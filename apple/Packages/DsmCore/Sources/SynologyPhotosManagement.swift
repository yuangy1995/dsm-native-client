import Foundation

/// 管理功能按 NAS 实际接口能力显示，执行时独立核对目标与权限。
public enum SynologyPhotosManagementFeature: String, CaseIterable, Hashable, Sendable {
    case metadata, tags, tagCreation, albums, conditionAlbums, folders, fileTransfer, upload, sharing, peopleNames, peopleMerge
}

public enum SynologyPhotoMetadataEdit: Equatable, Sendable {
    case rating(Int)
    case description(String)
    case takenAt(Date)
}

public enum SynologyPhotoLinkAccess: String, CaseIterable, Sendable {
    case disabled, invited, view, download
}

/// 确认时保留完整身份快照，不从后续变化的界面选择重新读取目标。
public enum SynologyPhotosMutation: Equatable, Sendable {
    case edit([SynologyPhoto], SynologyPhotoMetadataEdit)
    case shiftDates([SynologyPhoto], seconds: Int)
    case createTag(name: String, photos: [SynologyPhoto])
    case addTags([SynologyPhoto], ids: [Int])
    case removeTags([SynologyPhoto], ids: [Int])
    case createAlbum(name: String, photos: [SynologyPhoto])
    case createConditionAlbum(name: String, condition: SynologyPhotoAlbumCondition)
    case setAlbumCondition(id: Int, original: SynologyPhotoAlbumCondition, condition: SynologyPhotoAlbumCondition)
    case renameAlbum(id: Int, name: String)
    case deleteAlbum(id: Int)
    case addToAlbum(id: Int, photos: [SynologyPhoto])
    case removeFromAlbum(id: Int, photos: [SynologyPhoto])
    case setAlbumCover(id: Int, photo: SynologyPhoto)
    case createFolder(parentID: Int, name: String)
    case move([SynologyPhoto], folderID: Int)
    case copy([SynologyPhoto], folderID: Int)
    case upload(file: URL, size: Int64, modifiedAt: Date, folderID: Int?)
    case renamePerson(SynologyPhotoCollection, name: String)
    case mergePeople(target: SynologyPhotoCollection, sources: [SynologyPhotoCollection], name: String)
    case shareAlbum(id: Int, access: SynologyPhotoLinkAccess, original: SynologyPhotoSharingState? = nil, members: [SynologyPhotoShareGrant]? = nil)

    public var feature: SynologyPhotosManagementFeature {
        switch self {
        case .edit, .shiftDates: .metadata
        case .createTag: .tagCreation
        case .addTags, .removeTags: .tags
        case .createAlbum, .renameAlbum, .deleteAlbum, .addToAlbum, .removeFromAlbum, .setAlbumCover: .albums
        case .createFolder: .folders
        case .createConditionAlbum, .setAlbumCondition: .conditionAlbums
        case .move, .copy: .fileTransfer
        case .upload: .upload
        case .shareAlbum: .sharing
        case .renamePerson: .peopleNames
        case .mergePeople: .peopleMerge
        }
    }

    public var photos: [SynologyPhoto] {
        switch self {
        case .edit(let photos, _), .shiftDates(let photos, _), .createTag(_, let photos), .addTags(let photos, _), .removeTags(let photos, _),
             .createAlbum(_, let photos), .addToAlbum(_, let photos), .removeFromAlbum(_, let photos),
             .move(let photos, _), .copy(let photos, _): photos
        case .setAlbumCover(_, let photo): [photo]
        default: []
        }
    }
}

public struct SynologyPhotosMutationResult: Equatable, Sendable {
    public enum State: Equatable, Sendable { case confirmed, pendingReview, partial, rejected }
    public let state: State
    public let photos: [SynologyPhoto]
    public let album: SynologyPhotoCollection?
    public let tag: SynologyPhotoFilterChoice?
    public let folder: SynologyPhotoCollection?
    public let person: SynologyPhotoCollection?
    public let removedPersonIDs: [Int]
    public let sharingURL: URL?
    public let completedCount: Int

    public init(state: State, photos: [SynologyPhoto] = [], album: SynologyPhotoCollection? = nil,
                sharingURL: URL? = nil, completedCount: Int = 0, tag: SynologyPhotoFilterChoice? = nil,
                folder: SynologyPhotoCollection? = nil, person: SynologyPhotoCollection? = nil, removedPersonIDs: [Int] = []) {
        self.state = state; self.photos = photos; self.album = album
        self.sharingURL = sharingURL; self.completedCount = completedCount; self.tag = tag
        self.folder = folder; self.person = person; self.removedPersonIDs = removedPersonIDs
    }
}

/// 条件值保留完整结构，编辑一项规则不得丢弃其他规则或失去名称的引用。
public indirect enum SynologyPhotoConditionValue: Codable, Hashable, Sendable {
    case integer(Int), decimal(Double), string(String), boolean(Bool), array([Self]), object([String: Self]), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let number = try? value.decode(Int.self) { self = .integer(number) }
        else if let bool = try? value.decode(Bool.self) { self = .boolean(bool) }
        else if let number = try? value.decode(Double.self) { self = .decimal(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else { self = .object(try value.decode([String: Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .integer(let item): try value.encode(item)
        case .decimal(let item): try value.encode(item)
        case .null: try value.encodeNil()
        case .string(let item): try value.encode(item)
        case .boolean(let item): try value.encode(item)
        case .array(let items): try value.encode(items)
        case .object(let items): try value.encode(items)
        }
    }
    public var integer: Int? { if case .integer(let value) = self { value } else { nil } }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var array: [Self]? { if case .array(let value) = self { value } else { nil } }
    public var object: [String: Self]? { if case .object(let value) = self { value } else { nil } }
}

public enum SynologyPhotoConditionField: String, CaseIterable, Sendable {
    case keyword, person, concept, general_tag, camera, lens, aperture, iso, geocoding
    case focal_length_group, exposure_time_group, flash
    public var supportsPolicy: Bool { [.keyword, .person, .concept, .general_tag].contains(self) }
}

public struct SynologyPhotoConditionOption: Identifiable, Hashable, Sendable {
    public var id: SynologyPhotoConditionValue { value }
    public let name: String
    public let value: SynologyPhotoConditionValue
    public init(name: String, value: SynologyPhotoConditionValue) { self.name = name; self.value = value }
}

public struct SynologyPhotoAlbumCondition: Equatable, Sendable {
    public var fields: [String: SynologyPhotoConditionValue]
    public var names: [String: [SynologyPhotoConditionOption]]
    public init(fields: [String: SynologyPhotoConditionValue] = ["item_type": .array([])],
                names: [String: [SynologyPhotoConditionOption]] = [:]) { self.fields = fields; self.names = names }
    public func values(_ key: String) -> [SynologyPhotoConditionValue] { fields[key]?.array ?? [] }
    public mutating func setValues(_ values: [SynologyPhotoConditionValue], for key: String) {
        fields[key] = values.isEmpty && key != "item_type" ? nil : .array(values)
        if values.isEmpty { fields[key + "_policy"] = nil }
    }
}


/// 界面读取的分享快照。修订摘要只用于冲突检查，不包含密码或认证信息。
public struct SynologyPhotoSharingState: Equatable, Sendable {
    public let access: SynologyPhotoLinkAccess
    public let url: URL?
    public let hasPassword: Bool?
    public let hasExpiration: Bool?
    public let revision: String
    public let members: [SynologyPhotoShareGrant]?
    public init(access: SynologyPhotoLinkAccess, url: URL? = nil, hasPassword: Bool? = nil,
                hasExpiration: Bool? = nil, revision: String, members: [SynologyPhotoShareGrant]? = nil) {
        self.access = access; self.url = url; self.hasPassword = hasPassword
        self.hasExpiration = hasExpiration; self.revision = revision; self.members = members
    }
}


/// 成员编号保留接口的数字或字符串类型，用户与群组即使编号相同也不合并。
public struct SynologyPhotoShareRecipient: Hashable, Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        public let type: String
        public let value: SynologyPhotoConditionValue
        public init(type: String, value: SynologyPhotoConditionValue) { self.type = type; self.value = value }
    }
    public let id: ID
    public let name: String
    public init(id: ID, name: String) { self.id = id; self.name = name }
}

public struct SynologyPhotoShareGrant: Equatable, Identifiable, Sendable {
    public var id: SynologyPhotoShareRecipient.ID { recipient.id }
    public let recipient: SynologyPhotoShareRecipient
    // 保留原有未知角色；只在明确更改时发送已知角色，不静默降级。
    public var role: String
    public init(recipient: SynologyPhotoShareRecipient, role: String) { self.recipient = recipient; self.role = role }
}

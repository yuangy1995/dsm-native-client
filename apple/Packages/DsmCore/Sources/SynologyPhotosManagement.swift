import Foundation

/// 管理功能按 NAS 实际接口能力显示，执行时独立核对目标与权限。
public enum SynologyPhotosManagementFeature: String, CaseIterable, Hashable, Sendable {
    case backgroundTasks, automaticPreview, automaticPreviewSettings, sharedSpaceSettings, sharedMembers, globalSettings, conversionCache, libraryMaintenance, codecPrompt
    case frozenAlbums, metadata, rotation, tags, tagCreation, albums, conditionAlbums, folders, folderDeletion, folderCover, folderSorting, folderSharing, fileTransfer, upload, sharing, peopleNames, peopleMerge, peopleFaces, peopleCover, peopleVisibility, conceptVisibility, conceptCover, conceptItems, manualFaces, photoRequests, previewRegeneration, similarGroups, recognitionSettings, displaySettings, duplicateSettings, albumSorting, albumListSorting, albumListDisplay
}

/// 新格式提示固定当前用户及生成范围；确认提交不等于后台生成已经结束。
public struct SynologyPhotoCodecPrompt: Equatable, Sendable {
    public let profileID: UUID
    public let userID: Int
    public let isAdministrator: Bool
    public let shouldShow: Bool
    public let personalSpaceEnabled: Bool
    public let generationAlreadySubmitted: Bool
    public init(profileID: UUID, userID: Int, isAdministrator: Bool, shouldShow: Bool, personalSpaceEnabled: Bool, generationAlreadySubmitted: Bool = false) {
        self.profileID = profileID; self.userID = userID; self.isAdministrator = isAdministrator
        self.shouldShow = shouldShow; self.personalSpaceEnabled = personalSpaceEnabled
        self.generationAlreadySubmitted = generationAlreadySubmitted
    }
    public var canGenerate: Bool { userID > 0 && shouldShow && !generationAlreadySubmitted && (isAdministrator || personalSpaceEnabled) }
}

/// 当前空间的整库维护快照，不包含其他用户或其他空间的索引任务。
public struct SynologyPhotoLibraryMaintenanceStatus: Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable { case reindex = "basic", previews = "thumbnail" }
    public let profileID: UUID
    public let userID: Int
    public let space: SynologyPhotoSpace
    public let indexingCount: Int
    public let previewCount: Int
    public let supportsPreviewGeneration: Bool

    public init(profileID: UUID, userID: Int, space: SynologyPhotoSpace, indexingCount: Int,
                previewCount: Int, supportsPreviewGeneration: Bool) {
        self.profileID = profileID; self.userID = userID; self.space = space
        self.indexingCount = indexingCount; self.previewCount = previewCount
        self.supportsPreviewGeneration = supportsPreviewGeneration
    }
    public func pendingCount(for action: Action) -> Int { action == .reindex ? indexingCount : previewCount }
    public func canStart(_ action: Action) -> Bool {
        userID > 0 && indexingCount >= 0 && previewCount >= 0 && pendingCount(for: action) == 0 &&
            (action == .reindex || supportsPreviewGeneration)
    }
}

public struct SynologyPhotoDuplicateSettings: Equatable, Sendable {
    public enum Upload: String, CaseIterable, Sendable { case ignore, rename }
    public enum Transfer: String, CaseIterable, Sendable { case skip, overwrite }
    public var upload: Upload
    public var transfer: Transfer
    public init(upload: Upload, transfer: Transfer) { self.upload = upload; self.transfer = transfer }
}

public enum SynologyPhotoMetadataEdit: Equatable, Sendable {
    case rating(Int)
    case description(String)
    case takenAt(Date)
}

public enum SynologyPhotoLinkAccess: String, CaseIterable, Sendable {
    case disabled, invited, view, download
}

/// 当前会话在单个相册中的实际权限；不包含分享口令或原空间写权限。
public struct SynologyPhotoAlbumAccess: Equatable, Sendable {
    public let albumID: Int
    public let currentUserID: Int
    public let isOwner: Bool
    public let canDownload: Bool
    public let canContribute: Bool
    public init(albumID: Int, currentUserID: Int, isOwner: Bool, canDownload: Bool, canContribute: Bool) {
        self.albumID = albumID; self.currentUserID = currentUserID; self.isOwner = isOwner
        self.canDownload = canDownload; self.canContribute = canContribute
    }
}

/// 撤销引用本会话已确认的分组操作，不能用新快照猜测原始成员。
public enum SynologyPhotoSimilarEdit: Equatable, Sendable {
    case topPick(Int)
    case ungroup
    case remove([Int])
    case undo(UUID)
}

/// 确认时保留完整身份快照，不从后续变化的界面选择重新读取目标。
public enum SynologyPhotosMutation: Equatable, Sendable {
    case cancelBackgroundTask(SynologyPhotoBackgroundTask)
    case clearBackgroundTasks([SynologyPhotoBackgroundTask])
    case respondToCodecPrompt(SynologyPhotoCodecPrompt, generate: Bool)
    case maintainLibrary(SynologyPhotoLibraryMaintenanceStatus, SynologyPhotoLibraryMaintenanceStatus.Action)
    case setSharedMembers(original: SynologyPhotoSharedMembers, members: [SynologyPhotoSharedMember], folderEdits: [SynologyPhotoMemberFolderEdit])
    case setGlobalSettings(original: SynologyPhotoGlobalSettings, enabled: Set<SynologyPhotoGlobalSettings.Kind>, excludedExtensions: Set<String>?)
    case clearConversionCache(SynologyPhotoConversionCache)
    case setSharedSpaceSettings(original: SynologyPhotoSharedSpaceSettings, enabled: Set<SynologyPhotoSharedSpaceSettings.Kind>)
    case setSharedSpaceEnabled(original: SynologyPhotoSharedSpaceSettings, enabled: Bool)
    case setAutomaticPreview(original: Bool, enabled: Bool)
    case generateAutomaticPreview(SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport)
    case setRecognitionSettings(original: SynologyPhotoRecognitionSettings, enabled: Set<SynologyPhotoRecognitionSettings.Kind>)
    case setDisplaySettings(original: SynologyPhotoDisplaySettings, updated: SynologyPhotoDisplaySettings)
    case setDuplicateSettings(original: SynologyPhotoDuplicateSettings, updated: SynologyPhotoDuplicateSettings)
    case editSimilarGroup(SynologyPhotoSimilarDetail, SynologyPhotoSimilarEdit)
    case edit([SynologyPhoto], SynologyPhotoMetadataEdit)
    case rotatePhoto(SynologyPhoto)
    case shiftDates([SynologyPhoto], seconds: Int)
    case createTag(name: String, photos: [SynologyPhoto], space: SynologyPhotoSpace = .personal)
    case addTags([SynologyPhoto], ids: [Int])
    case removeTags([SynologyPhoto], ids: [Int])
    case createAlbum(name: String, photos: [SynologyPhoto])
    case createTemporaryAlbum(name: String, photos: [SynologyPhoto])
    case copyTemporaryAlbum(id: Int, name: String, original: SynologyPhotoSharingState)
    case deleteTemporaryAlbum(id: Int, original: SynologyPhotoSharingState, preservedCopyID: Int? = nil)
    case unfreezeAlbum(SynologyPhotoFrozenAlbum)
    case rebuildFrozenAlbum(SynologyPhotoFrozenAlbum, name: String, condition: SynologyPhotoAlbumCondition)
    case createConditionAlbum(name: String, condition: SynologyPhotoAlbumCondition)
    case setAlbumCondition(id: Int, original: SynologyPhotoAlbumCondition, condition: SynologyPhotoAlbumCondition)
    case renameAlbum(id: Int, name: String)
    case deleteAlbum(id: Int)
    case addToAlbum(id: Int, photos: [SynologyPhoto])
    case removeFromAlbum(id: Int, photos: [SynologyPhoto])
    case setAlbumCover(id: Int, photo: SynologyPhoto)
    case setFolderCover(folder: SynologyPhotoCollection, photo: SynologyPhoto)
    case deleteFolderItems(photos: [SynologyPhoto], folders: [SynologyPhotoCollection])
    case renameFolder(folder: SynologyPhotoCollection, name: String)
    case setAlbumListSort(scope: SynologyPhotoAlbumListScope, original: SynologyPhotoAlbumListSort, sort: SynologyPhotoAlbumListSort)
    case setAlbumListDisplay(original: SynologyPhotoAlbumDisplay, display: SynologyPhotoAlbumDisplay)
    case setAlbumSort(id: Int, original: SynologyPhotoSort, sort: SynologyPhotoSort)
    case setFolderSort(folder: SynologyPhotoCollection, sort: SynologyPhotoSort)
    case setFolderSharing(original: SynologyPhotoFolderSharingState, access: SynologyPhotoFolderSharingState.Access, members: [SynologyPhotoShareGrant]?, password: String?, appliesToSubfolders: Bool)
    case createFolder(parentID: Int, name: String, space: SynologyPhotoSpace = .personal)
    case move([SynologyPhoto], folderID: Int, destinationSpace: SynologyPhotoSpace? = nil, folders: [SynologyPhotoCollection] = [], duplicate: SynologyPhotoDuplicateSettings.Transfer = .skip)
    case copy([SynologyPhoto], folderID: Int, destinationSpace: SynologyPhotoSpace? = nil, folders: [SynologyPhotoCollection] = [], duplicate: SynologyPhotoDuplicateSettings.Transfer = .skip)
    case upload(file: URL, size: Int64, modifiedAt: Date, folderID: Int?, space: SynologyPhotoSpace = .personal, duplicate: SynologyPhotoDuplicateSettings.Upload = .rename)
    case uploadToAlbum(file: URL, size: Int64, modifiedAt: Date, albumID: Int, duplicate: SynologyPhotoDuplicateSettings.Upload = .rename)
    case renamePerson(SynologyPhotoCollection, name: String)
    case mergePeople(target: SynologyPhotoCollection, sources: [SynologyPhotoCollection], name: String)
    case removePersonFaces(person: SynologyPhotoCollection, faces: [SynologyPhotoFace])
    case reassignPersonFaces(person: SynologyPhotoCollection, faces: [SynologyPhotoFace], target: SynologyPhotoCollection?, name: String)
    case editPhotoFaces(photo: SynologyPhoto, changes: [SynologyPhotoFaceChange])
    case regeneratePreviews([SynologyPhoto], resuming: Bool = false)
    case setConceptCover(concept: SynologyPhotoConceptVisibility, photo: SynologyPhoto)
    case removeConceptItems(concept: SynologyPhotoConceptVisibility, photos: [SynologyPhoto])
    case setConceptVisibility([SynologyPhotoConceptVisibility], visible: Bool)
    case setPeopleVisibility([SynologyPhotoPersonVisibility], visible: Bool)
    case setPersonCover(person: SynologyPhotoCollection, photo: SynologyPhoto)
    case createPhotoRequest(SynologyPhotoRequestSettings)
    case updatePhotoRequest(original: SynologyPhotoRequest, settings: SynologyPhotoRequestSettings)
    case deletePhotoRequest(SynologyPhotoRequest)
    case shareAlbum(id: Int, access: SynologyPhotoLinkAccess, original: SynologyPhotoSharingState? = nil, members: [SynologyPhotoShareGrant]? = nil, expiration: Int? = nil, password: String? = nil)

    /// 与 Photos 网页重命名表单保持一致；长度按 JavaScript 的 UTF-16 单元计数。
    public static func isValidFolderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf16.count <= 255 && !name.contains("\0") &&
        name.range(of: #"^\s*$|^\.|\.$|^@(?:database|eaDir|tmp|sharebin)$|^#(?:recycle|snapshot)$|[/\\:]"#, options: .regularExpression) == nil
    }

    /// 网页仅对这些操作拆分个人/共享来源；标签编号不能跨空间复用。
    public var supportsMixedPhotoSpaces: Bool {
        switch self {
        case .edit(_, .rating), .edit(_, .takenAt), .shiftDates, .regeneratePreviews: true
        default: false
        }
    }

    /// 默认沿用来源空间；显式目标随确认快照固定，不跟随界面切换。
    public var destinationSpace: SynologyPhotoSpace {
        switch self {
        case .move(_, _, let destination, _, _), .copy(_, _, let destination, _, _): destination ?? space
        default: space
        }
    }

    public var transferFolders: [SynologyPhotoCollection] {
        switch self {
        case .move(_, _, _, let folders, _), .copy(_, _, _, let folders, _): folders
        default: []
        }
    }

    /// 相同空间内不能选择原位置、来源目录自身或后代。
    public func acceptsTransferDestination(_ folder: SynologyPhotoCollection) -> Bool {
        guard folder.id > 0, folder.space == destinationSpace else { return false }
        guard folder.space == space else { return true }
        if photos.contains(where: { $0.folderID == folder.id }) { return false }
        return transferFolders.allSatisfy { source in
            guard let sourcePath = source.path, let targetPath = folder.path else { return false }
            return folder.id != source.id && folder.id != source.parentID &&
                targetPath != sourcePath && !targetPath.hasPrefix(sourcePath + "/")
        }
    }

    public var feature: SynologyPhotosManagementFeature {
        switch self {
        case .cancelBackgroundTask, .clearBackgroundTasks: .backgroundTasks
        case .respondToCodecPrompt: .codecPrompt
        case .maintainLibrary: .libraryMaintenance
        case .setSharedMembers: .sharedMembers
        case .setGlobalSettings: .globalSettings
        case .clearConversionCache: .conversionCache
        case .setSharedSpaceSettings, .setSharedSpaceEnabled: .sharedSpaceSettings
        case .setAutomaticPreview: .automaticPreviewSettings
        case .generateAutomaticPreview: .automaticPreview
        case .setRecognitionSettings: .recognitionSettings
        case .setDisplaySettings: .displaySettings
        case .setDuplicateSettings: .duplicateSettings
        case .editSimilarGroup: .similarGroups
        case .edit, .shiftDates: .metadata
        case .rotatePhoto: .rotation
        case .createTag: .tagCreation
        case .addTags, .removeTags: .tags
        case .createAlbum, .createTemporaryAlbum, .copyTemporaryAlbum, .deleteTemporaryAlbum, .renameAlbum, .deleteAlbum, .addToAlbum, .removeFromAlbum, .setAlbumCover: .albums
        case .deleteFolderItems: .folderDeletion
        case .createFolder, .renameFolder: .folders
        case .setFolderCover: .folderCover
        case .setAlbumListSort: .albumListSorting
        case .setAlbumListDisplay: .albumListDisplay
        case .setAlbumSort: .albumSorting
        case .setFolderSort: .folderSorting
        case .setFolderSharing: .folderSharing
        case .unfreezeAlbum, .rebuildFrozenAlbum: .frozenAlbums
        case .createConditionAlbum, .setAlbumCondition: .conditionAlbums
        case .move, .copy: .fileTransfer
        case .upload, .uploadToAlbum: .upload
        case .createPhotoRequest, .updatePhotoRequest, .deletePhotoRequest: .photoRequests
        case .shareAlbum: .sharing
        case .renamePerson: .peopleNames
        case .mergePeople: .peopleMerge
        case .removePersonFaces, .reassignPersonFaces: .peopleFaces
        case .setPersonCover: .peopleCover
        case .editPhotoFaces: .manualFaces
        case .regeneratePreviews: .previewRegeneration
        case .setConceptCover: .conceptCover
        case .removeConceptItems: .conceptItems
        case .setConceptVisibility: .conceptVisibility
        case .setPeopleVisibility: .peopleVisibility
        }
    }

    public var photos: [SynologyPhoto] {
        switch self {
        case .editSimilarGroup(let detail, _): detail.photos
        case .edit(let photos, _), .shiftDates(let photos, _), .createTag(_, let photos, _), .addTags(let photos, _), .removeTags(let photos, _),
             .createAlbum(_, let photos), .createTemporaryAlbum(_, let photos), .addToAlbum(_, let photos), .removeFromAlbum(_, let photos),
             .move(let photos, _, _, _, _), .copy(let photos, _, _, _, _): photos
        case .removeConceptItems(_, let photos): photos
        case .setConceptCover(_, let photo): [photo]
        case .deleteFolderItems(let photos, _): photos
        case .regeneratePreviews(let photos, _): photos
        case .editPhotoFaces(let photo, _), .rotatePhoto(let photo): [photo]
        case .setAlbumCover(_, let photo), .setPersonCover(_, let photo), .setFolderCover(_, let photo): [photo]
        case .removePersonFaces(_, let faces), .reassignPersonFaces(_, let faces, _, _):
            faces.reduce(into: [SynologyPhoto]()) { photos, face in
                if !photos.contains(where: { $0.id == face.photo.id }) { photos.append(face.photo) }
            }
        default: []
        }
    }

    /// 无照片目标的写操作也必须固定空间，不能在排队或重试时读取当前界面选择。
    public var space: SynologyPhotoSpace {
        switch self {
        case .maintainLibrary(let status, _): status.space
        case .generateAutomaticPreview(let task, _): task.space
        case .editSimilarGroup(let detail, _): detail.group.space
        case .renamePerson(let person, _), .removePersonFaces(let person, _), .reassignPersonFaces(let person, _, _, _), .setPersonCover(let person, _): person.space
        case .mergePeople(let target, _, _): target.space
        case .setConceptCover(let concept, _), .removeConceptItems(let concept, _): concept.concept.space
        case .setConceptVisibility(let concepts, _): concepts.first?.concept.space ?? .personal
        case .setPeopleVisibility(let people, _): people.first?.person.space ?? .personal
        case .editPhotoFaces(let photo, _), .rotatePhoto(let photo): photo.id.space
        case .createAlbum(_, let photos), .createTemporaryAlbum(_, let photos), .addToAlbum(_, let photos), .removeFromAlbum(_, let photos): photos.first?.id.space ?? .personal
        case .setAlbumCover(_, let photo): photo.id.space
        case .deleteFolderItems(_, let folders): folders.first?.space ?? .personal
        case .setFolderCover(let folder, _), .setFolderSort(let folder, _), .renameFolder(let folder, _): folder.space
        case .setFolderSharing(let original, _, _, _, _): original.folder.space
        case .rebuildFrozenAlbum(_, _, let condition): condition.sourceSpace
        case .createConditionAlbum(_, let condition), .setAlbumCondition(_, _, let condition): condition.sourceSpace
        case .regeneratePreviews(let photos, _): photos.first?.id.space ?? .personal
        case .createPhotoRequest(let settings), .updatePhotoRequest(_, let settings): settings.space
        case .deletePhotoRequest(let request): request.settings.space
        case .upload(_, _, _, _, let space, _), .createFolder(_, _, let space), .createTag(_, _, let space): space
        case .move(let photos, _, _, let folders, _), .copy(let photos, _, _, let folders, _): folders.first?.space ?? photos.first?.id.space ?? .personal
        case .edit(let photos, _), .shiftDates(let photos, _), .addTags(let photos, _), .removeTags(let photos, _): photos.first?.id.space ?? .personal
        default: .personal
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
    public let deletedFolders: [SynologyPhotoCollection]
    public let deletedPhotoIDs: [SynologyPhotoID]
    public let person: SynologyPhotoCollection?
    public let removedPersonIDs: [Int]
    public let removedFromConceptPhotoIDs: [SynologyPhotoID]
    public let conceptVisibility: [SynologyPhotoConceptVisibility]
    public let personVisibility: [SynologyPhotoPersonVisibility]
    public let removedFromPersonPhotoIDs: [SynologyPhotoID]
    public let sharingURL: URL?
    public let completedCount: Int
    public let skippedCount: Int
    public let photoRequest: SynologyPhotoRequest?
    public let similarGroup: SynologyPhotoSimilarGroup?
    public let globalSettings: SynologyPhotoGlobalSettings?
    public let automaticPreviewFailureRecorded: Bool
    public let conversionCache: SynologyPhotoConversionCache?
    public let sharedSpaceSettings: SynologyPhotoSharedSpaceSettings?
    public let sharedMembers: SynologyPhotoSharedMembers?

    public init(state: State, photos: [SynologyPhoto] = [], album: SynologyPhotoCollection? = nil,
                sharingURL: URL? = nil, completedCount: Int = 0, tag: SynologyPhotoFilterChoice? = nil,
                folder: SynologyPhotoCollection? = nil, deletedFolders: [SynologyPhotoCollection] = [], deletedPhotoIDs: [SynologyPhotoID] = [], person: SynologyPhotoCollection? = nil, removedPersonIDs: [Int] = [], removedFromPersonPhotoIDs: [SynologyPhotoID] = [], personVisibility: [SynologyPhotoPersonVisibility] = [], conceptVisibility: [SynologyPhotoConceptVisibility] = [], removedFromConceptPhotoIDs: [SynologyPhotoID] = [], photoRequest: SynologyPhotoRequest? = nil, similarGroup: SynologyPhotoSimilarGroup? = nil, skippedCount: Int = 0, sharedSpaceSettings: SynologyPhotoSharedSpaceSettings? = nil, globalSettings: SynologyPhotoGlobalSettings? = nil, conversionCache: SynologyPhotoConversionCache? = nil, sharedMembers: SynologyPhotoSharedMembers? = nil, automaticPreviewFailureRecorded: Bool = false) {
        self.deletedFolders = deletedFolders; self.deletedPhotoIDs = deletedPhotoIDs
        self.state = state; self.photos = photos; self.album = album; self.similarGroup = similarGroup
        self.sharingURL = sharingURL; self.completedCount = completedCount; self.tag = tag
        self.automaticPreviewFailureRecorded = automaticPreviewFailureRecorded
        self.globalSettings = globalSettings; self.conversionCache = conversionCache
        self.sharedSpaceSettings = sharedSpaceSettings
        self.sharedMembers = sharedMembers
        self.skippedCount = skippedCount
        self.removedFromConceptPhotoIDs = removedFromConceptPhotoIDs
        self.conceptVisibility = conceptVisibility
        self.personVisibility = personVisibility
        self.removedFromPersonPhotoIDs = removedFromPersonPhotoIDs
        self.folder = folder; self.person = person; self.removedPersonIDs = removedPersonIDs; self.photoRequest = photoRequest
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
    /// 官方条件规则以user_id=0标识共享来源；其他用户编号仍由Repository核对。
    public var sourceSpace: SynologyPhotoSpace { fields["user_id"]?.integer == 0 ? .shared : .personal }
    public var fields: [String: SynologyPhotoConditionValue]
    public var names: [String: [SynologyPhotoConditionOption]]
    public init(fields: [String: SynologyPhotoConditionValue] = ["item_type": .array([])],
                names: [String: [SynologyPhotoConditionOption]] = [:]) { self.fields = fields; self.names = names }
    public func values(_ key: String) -> [SynologyPhotoConditionValue] { fields[key]?.array ?? [] }
    public mutating func setValues(_ values: [SynologyPhotoConditionValue], for key: String) {
        fields[key] = values.isEmpty && key != "item_type" ? nil : .array(values)
        if values.isEmpty { fields[key + "_policy"] = nil }
    }

    /// 请求与恢复共用集合归一化；未知字段的空数组与顺序原样保留。
    public func canonicalFields(sourceUserID: Int) throws -> [String: SynologyPhotoConditionValue] {
        var result = fields
        result["user_id"] = .integer(sourceUserID)
        result["item_type"] = result["item_type"] ?? .array([])
        let setFields = Set(SynologyPhotoConditionField.allCases.map(\.rawValue) + ["folder_filter", "rating", "item_type", "time"])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for (key, value) in result where setFields.contains(key) {
            if let values = value.array {
                if values.isEmpty && key != "item_type" { result[key] = nil; continue }
                result[key] = .array(try values.sorted { try encoder.encode($0).lexicographicallyPrecedes(encoder.encode($1)) })
            }
        }
        return result
    }
}


/// 界面读取的分享快照。修订摘要只用于冲突检查，不包含密码或认证信息。
public struct SynologyPhotoSharingState: Equatable, Sendable {
    public let access: SynologyPhotoLinkAccess
    public let url: URL?
    public let hasPassword: Bool?
    public let hasExpiration: Bool?
    /// Unix秒；0为不限日期，nil表示未能读取。命令中nil表示保留现状。
    public let expiration: Int?
    /// nil表示响应没有明确说明，不能据此清理相册。
    public let isTemporary: Bool?
    public let revision: String
    public let members: [SynologyPhotoShareGrant]?
    public init(access: SynologyPhotoLinkAccess, url: URL? = nil, hasPassword: Bool? = nil,
                hasExpiration: Bool? = nil, revision: String, members: [SynologyPhotoShareGrant]? = nil, expiration: Int? = nil, isTemporary: Bool? = nil) {
        self.access = access; self.url = url; self.hasPassword = hasPassword
        self.hasExpiration = hasExpiration; self.revision = revision; self.members = members
        self.expiration = expiration; self.isTemporary = isTemporary
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


/// 收集设置只随本次确认持有，不持久保存收集链接或目标分享标识。
public struct SynologyPhotoRequestSettings: Equatable, Sendable {
    public var subject: String
    public var description: String
    public var space: SynologyPhotoSpace
    public var folderPath: String
    public var folderID: Int?
    public var albumID: Int?
    public var albumPassphrase: String?
    public var expiration: Int
    public var sizeLimit: Int64
    public init(subject: String = "", description: String = "", space: SynologyPhotoSpace = .personal,
                folderPath: String = "", folderID: Int? = nil, albumID: Int? = nil, albumPassphrase: String? = nil,
                expiration: Int = 0, sizeLimit: Int64 = 0) {
        self.subject = subject; self.description = description; self.space = space
        self.folderPath = folderPath; self.folderID = folderID; self.albumID = albumID
        self.albumPassphrase = albumPassphrase; self.expiration = expiration; self.sizeLimit = sizeLimit
    }
    public static func defaultFolderPath(subject: String) -> String {
        let name = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = name.replacingOccurrences(of: #"^\s*$|^\.|\.$|^@(?:database|eaDir|tmp|sharebin)$|^#(?:recycle|snapshot)$|[/\\:]"#, with: "_", options: .regularExpression)
        return name.isEmpty ? "/PhotoRequest" : "/PhotoRequest/" + safe
    }
}

public struct SynologyPhotoRequest: Identifiable, Equatable, Sendable {
    public let id: String
    public let profileID: UUID
    public let settings: SynologyPhotoRequestSettings
    public let albumName: String?
    public let isFolderValid: Bool
    public let url: URL?
    public init(id: String, profileID: UUID, settings: SynologyPhotoRequestSettings, albumName: String? = nil, isFolderValid: Bool, url: URL? = nil) {
        self.id = id; self.profileID = profileID; self.settings = settings
        self.albumName = albumName; self.isFolderValid = isFolderValid; self.url = url
    }
}

public struct SynologyPhotoRequestAlbum: Identifiable, Equatable, Sendable {
    public var id: String { passphrase.map { "shared:" + $0 } ?? "owned:\(albumID ?? 0)" }
    public let albumID: Int?
    public let passphrase: String?
    public let name: String
    public let shared: Bool
    public init(albumID: Int? = nil, passphrase: String? = nil, name: String, shared: Bool) {
        self.albumID = albumID; self.passphrase = passphrase; self.name = name; self.shared = shared
    }
}

/// 人脸身份由人物列表读取；照片身份不能替代人脸编号。
public struct SynologyPhotoFace: Identifiable, Hashable, Sendable {
    public let id: Int
    public let personID: Int
    public let photo: SynologyPhoto
    public let thumbnail: SynologyPhotoThumbnail?
    public init(id: Int, personID: Int, photo: SynologyPhoto, thumbnail: SynologyPhotoThumbnail? = nil) {
        self.id = id; self.personID = personID; self.photo = photo; self.thumbnail = thumbnail
    }
}

/// 人物显示设置的读取快照，隐藏人物不影响原照片。
/// 主题显示状态与人物识别独立；隐藏主题不删除其照片。
public struct SynologyPhotoConceptVisibility: Identifiable, Equatable, Sendable {
    public var id: Int { concept.id }
    public let concept: SynologyPhotoCollection
    public let isVisible: Bool
    public let displayThreshold: Int?
    public var appearsInList: Bool {
        guard isVisible else { return false }
        guard let threshold = displayThreshold, let count = concept.itemCount else { return true }
        return count >= threshold
    }
    public init(concept: SynologyPhotoCollection, isVisible: Bool, displayThreshold: Int? = nil) {
        self.concept = concept; self.isVisible = isVisible; self.displayThreshold = displayThreshold
    }
}

public struct SynologyPhotoPersonVisibility: Identifiable, Equatable, Sendable {
    public var id: Int { person.id }
    public let person: SynologyPhotoCollection
    public let isVisible: Bool
    public init(person: SynologyPhotoCollection, isVisible: Bool) {
        self.person = person; self.isVisible = isVisible
    }
}


/// 显示方向图片上的归一化人脸框；不依赖视口大小或缩放倍率。
public struct SynologyPhotoFaceBounds: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.000001 && y + height <= 1.000001
    }
}

public struct SynologyPhotoFaceRegion: Identifiable, Equatable, Sendable {
    public let id: Int
    public let personID: Int
    public let name: String
    public let bounds: SynologyPhotoFaceBounds
    public let thumbnail: SynologyPhotoThumbnail?
    public init(id: Int, personID: Int, name: String, bounds: SynologyPhotoFaceBounds, thumbnail: SynologyPhotoThumbnail? = nil) {
        self.id = id; self.personID = personID; self.name = name; self.bounds = bounds; self.thumbnail = thumbnail
    }
}

public struct SynologyPhotoNewFace: Equatable, Sendable {
    public let temporaryID: String
    public let bounds: SynologyPhotoFaceBounds
    public let person: SynologyPhotoCollection?
    public let name: String
    public let jpeg: Data
    public init(temporaryID: String, bounds: SynologyPhotoFaceBounds, person: SynologyPhotoCollection?, name: String, jpeg: Data) {
        self.temporaryID = temporaryID; self.bounds = bounds; self.person = person; self.name = name; self.jpeg = jpeg
    }
}

/// 一次保存的不可变改动集合；新增框仅按明确回执关联，不通过名字追认。
public enum SynologyPhotoFaceChange: Equatable, Sendable {
    case add(SynologyPhotoNewFace)
    case remove(SynologyPhotoFaceRegion)
    case reassign(SynologyPhotoFaceRegion, person: SynologyPhotoCollection?, name: String)
    public var id: String {
        switch self {
        case .add(let face): "new-" + face.temporaryID
        case .remove(let face), .reassign(let face, _, _): "face-" + String(face.id)
        }
    }
}


/// 共享目录独立于相册分享；原始成员角色与未知状态保留，不把缺失当作关闭。
public struct SynologyPhotoFolderSharingState: Equatable, Sendable {
    public enum Access: String, CaseIterable, Sendable {
        case management, invited = "private", view = "public-view", download = "public-download"
    }
    public let folder: SynologyPhotoCollection
    public let access: Access
    public let url: URL
    public let hasPassword: Bool?
    public let members: [SynologyPhotoShareGrant]?
    public let parentIsShared: Bool
    public let appliesToSubfolders: Bool
    public let revision: String
    public var depth: Int { folder.path?.split(separator: "/").count ?? 0 }
    public var inheritsManagementOnly: Bool { depth > 1 && !parentIsShared }
    public init(folder: SynologyPhotoCollection, access: Access, url: URL, hasPassword: Bool?,
                members: [SynologyPhotoShareGrant]?, parentIsShared: Bool, appliesToSubfolders: Bool, revision: String) {
        self.folder = folder; self.access = access; self.url = url; self.hasPassword = hasPassword
        self.members = members; self.parentIsShared = parentIsShared; self.appliesToSubfolders = appliesToSubfolders; self.revision = revision
    }
}


/// 照片显示偏好保存在NAS；与相册/目录各自排序及应用外观设置分开。
public struct SynologyPhotoDisplaySettings: Equatable, Sendable {
    public enum Grouping: String, CaseIterable, Sendable { case day, month }
    public enum Clock: String, CaseIterable, Sendable { case twelve = "12", twentyFour = "24" }
    public enum DateFormat: String, CaseIterable, Sendable {
        case yearDash = "yyyy-mm-dd", yearSlash = "yyyy/mm/dd", yearDot = "yyyy.mm.dd"
        case dayDash = "dd-mm-yyyy", daySlash = "dd/mm/yyyy", dayDot = "dd.mm.yyyy"
        case monthDash = "mm-dd-yyyy", monthSlash = "mm/dd/yyyy", monthDot = "mm.dd.yyyy"
        public var pattern: String { rawValue.replacingOccurrences(of: "mm", with: "MM") }
        public var monthPattern: String {
            pattern.replacingOccurrences(of: #"[-/.]dd|dd[-/.]"#, with: "", options: .regularExpression)
        }
    }
    public var grouping: Grouping
    public var dateFormat: DateFormat
    public var clock: Clock
    public var defaultSort: SynologyPhotoSort
    public var showsPreviewInfo: Bool
    public init(grouping: Grouping = .day, dateFormat: DateFormat = .yearDash, clock: Clock = .twentyFour,
                defaultSort: SynologyPhotoSort = .init(), showsPreviewInfo: Bool = false) {
        self.grouping = grouping; self.dateFormat = dateFormat; self.clock = clock
        self.defaultSort = defaultSort; self.showsPreviewInfo = showsPreviewInfo
    }
}


/// 个人识别开关与管理员提供的实际能力分开；缺字段不猜为关闭。
public struct SynologyPhotoRecognitionSettings: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case person = "enable_person", concept = "enable_concept", similar = "enable_similar"
        public var category: SynologyPhotoCategory {
            switch self { case .person: .person; case .concept: .concept; case .similar: .similar }
        }
    }
    public let values: [Kind: Bool]
    public let globallyEnabled: Set<Kind>
    public let personalSpaceEnabled: Bool
    public var enabled: Set<Kind> { Set(values.filter(\.value).map(\.key)) }
    public var editable: Set<Kind> { personalSpaceEnabled ? Set(values.keys).intersection(globallyEnabled) : [] }
    public init(values: [Kind: Bool], globallyEnabled: Set<Kind>, personalSpaceEnabled: Bool) {
        self.values = values; self.globallyEnabled = globallyEnabled; self.personalSpaceEnabled = personalSpaceEnabled
    }
    public func canSave(_ target: Set<Kind>) -> Bool {
        let changed = enabled.symmetricDifference(target)
        return !changed.isEmpty && target.isSubset(of: Set(values.keys)) && changed.isSubset(of: editable)
    }
}


/// 共享空间设置由 DSM 管理员维护，与照片目录的 management 角色分开。
public struct SynologyPhotoSharedSpaceSettings: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case person = "enable_person", concept = "enable_concept", similar = "enable_similar"
        case publicRoot = "allow_root_folder_public"
        public var category: SynologyPhotoCategory? {
            switch self { case .person: .person; case .concept: .concept; case .similar: .similar; case .publicRoot: nil }
        }
    }
    public enum Role: String, Sendable { case none, entry, management }
    public let profileID: UUID
    public let administratorID: Int
    public var isEnabled: Bool
    public let personalSpaceEnabled: Bool
    public let role: Role
    public let disabledBySharedFolder: Bool?
    public var values: [Kind: Bool]
    public let globallyEnabled: Set<Kind>
    public var enabled: Set<Kind> { Set(values.filter(\.value).map(\.key)) }
    public var editable: Set<Kind> { isEnabled ? Set(values.keys).intersection(globallyEnabled.union([.publicRoot])) : [] }
    public var canAccess: Bool { isEnabled && role != .none }
    public init(profileID: UUID, administratorID: Int, isEnabled: Bool, personalSpaceEnabled: Bool,
                role: Role, disabledBySharedFolder: Bool? = nil, values: [Kind: Bool], globallyEnabled: Set<Kind>) {
        self.profileID = profileID; self.administratorID = administratorID; self.isEnabled = isEnabled
        self.personalSpaceEnabled = personalSpaceEnabled; self.role = role; self.disabledBySharedFolder = disabledBySharedFolder
        self.values = values; self.globallyEnabled = globallyEnabled
    }
    public func canSave(_ target: Set<Kind>) -> Bool {
        let changed = enabled.symmetricDifference(target)
        return !changed.isEmpty && target.isSubset(of: Set(values.keys)) && changed.isSubset(of: editable)
    }
    public func canSetEnabled(_ target: Bool) -> Bool {
        target != isEnabled && (target || personalSpaceEnabled)
    }
}


/// 共享成员保留原始角色；新角色只提供网页已知的两种选择。
public struct SynologyPhotoSharedMember: Equatable, Identifiable, Sendable {
    public enum Role: String, CaseIterable, Sendable { case entry, management }
    public var id: SynologyPhotoShareRecipient.ID { recipient.id }
    public let recipient: SynologyPhotoShareRecipient
    public var role: String
    public var autoBackup: Bool
    public var isProtected: Bool { id.type == "group" && recipient.name == "administrators" }
    public var canEdit: Bool { !isProtected && Role(rawValue: role) != nil }
    public init(recipient: SynologyPhotoShareRecipient, role: String, autoBackup: Bool) {
        self.recipient = recipient; self.role = role; self.autoBackup = autoBackup
    }
    public init(recipient: SynologyPhotoShareRecipient, role: Role) {
        self.init(recipient: recipient, role: role.rawValue, autoBackup: role == .management)
    }
    /// 升级管理角色自动开启备份，降级保留已有备份选择；表单取消可丢弃整个草稿。
    public func changingRole(to target: Role) -> Self {
        guard canEdit else { return self }
        var value = self; value.role = target.rawValue
        if target == .management { value.autoBackup = true }
        return value
    }
}

public struct SynologyPhotoSharedMembers: Equatable, Sendable {
    public let profileID: UUID
    public let administratorID: Int
    public let isEnabled: Bool
    public let members: [SynologyPhotoSharedMember]
    public init(profileID: UUID, administratorID: Int, isEnabled: Bool, members: [SynologyPhotoSharedMember]) {
        self.profileID = profileID; self.administratorID = administratorID
        self.isEnabled = isEnabled; self.members = members
    }
    /// 顺序不属于权限变更；未知角色、受保护群组和成员身份不能被表单顺带改写。
    public func canSave(_ target: [SynologyPhotoSharedMember], candidates: [SynologyPhotoShareRecipient], allowsUnchanged: Bool = false) -> Bool {
        guard isEnabled, Set(members.map(\.id)).count == members.count,
              Set(target.map(\.id)).count == target.count, Set(candidates.map(\.id)).count == candidates.count else { return false }
        let before = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: target.map { ($0.id, $0) })
        guard allowsUnchanged || before != after else { return false }
        let available = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        for member in members where !member.canEdit {
            guard after[member.id] == member else { return false }
        }
        return target.allSatisfy { member in
            if let original = before[member.id] {
                guard member.recipient == original.recipient else { return false }
                if member == original { return true }
                guard original.canEdit else { return false }
            } else {
                guard available[member.id] == member.recipient, !member.isProtected else { return false }
            }
            return SynologyPhotoSharedMember.Role(rawValue: member.role) != nil &&
                (member.role != "management" || member.autoBackup)
        }
    }
}

/// 目录成员角色是逐级包含的权限；公开访问下限与直接成员授权分别保留。
public enum SynologyPhotoFolderMemberRole: String, CaseIterable, Sendable {
    case view, download, upload, manage
    public var level: Int {
        switch self { case .view: 0; case .download: 1; case .upload: 2; case .manage: 3 }
    }
}

public struct SynologyPhotoMemberFolder: Equatable, Identifiable, Sendable {
    public var id: Int { folder.id }
    public let profileID: UUID
    public let memberID: SynologyPhotoShareRecipient.ID
    public let rootID: Int
    public let folder: SynologyPhotoCollection
    /// 根下第一层为0，第二层为1；网页只编辑这两层。
    public let depth: Int
    public let privacy: String
    public let directRole: String?
    public let revision: String
    public var publicRole: SynologyPhotoFolderMemberRole? {
        switch privacy { case "public-view": .view; case "public-download": .download; default: nil }
    }
    public var hasKnownPermissions: Bool {
        ["private", "public-view", "public-download"].contains(privacy) &&
            (directRole == nil || directRole.flatMap(SynologyPhotoFolderMemberRole.init(rawValue:)) != nil)
    }
    public var effectiveRole: SynologyPhotoFolderMemberRole? {
        guard hasKnownPermissions else { return nil }
        let direct = directRole.flatMap(SynologyPhotoFolderMemberRole.init(rawValue:))
        return (direct?.level ?? -1) >= (publicRole?.level ?? -1) ? direct : publicRole
    }
    public var canExpand: Bool { depth == 0 }
    public init(profileID: UUID, memberID: SynologyPhotoShareRecipient.ID, rootID: Int,
                folder: SynologyPhotoCollection, depth: Int, privacy: String, directRole: String?, revision: String) {
        self.profileID = profileID; self.memberID = memberID; self.rootID = rootID; self.folder = folder
        self.depth = depth; self.privacy = privacy; self.directRole = directRole; self.revision = revision
    }
}

public struct SynologyPhotoMemberFolderPage: Equatable, Sendable {
    public let profileID: UUID
    public let administratorID: Int
    public let memberID: SynologyPhotoShareRecipient.ID
    public let parentID: Int
    public let parent: SynologyPhotoMemberFolder?
    public let folders: [SynologyPhotoMemberFolder]
    public let nextOffset: Int?
    public init(profileID: UUID, administratorID: Int, memberID: SynologyPhotoShareRecipient.ID,
                parentID: Int, parent: SynologyPhotoMemberFolder?, folders: [SynologyPhotoMemberFolder], nextOffset: Int?) {
        self.profileID = profileID; self.administratorID = administratorID; self.memberID = memberID
        self.parentID = parentID; self.parent = parent; self.folders = folders; self.nextOffset = nextOffset
    }
}

/// 一个成员的目录草稿与固定完整快照；确认前只在内存修改，不临时授权NAS。
public struct SynologyPhotoMemberFolderEdit: Equatable, Sendable {
    public struct Change: Equatable, Sendable {
        public let folderID: Int
        public let role: SynologyPhotoFolderMemberRole?
        public init(folderID: Int, role: SynologyPhotoFolderMemberRole?) { self.folderID = folderID; self.role = role }
    }
    public struct Batch: Equatable, Sendable {
        public enum Action: String, CaseIterable, Sendable { case checkAll = "check_all", uncheckAll = "uncheck_all" }
        public let action: Action
        public let role: SynologyPhotoFolderMemberRole
        public init(action: Action, role: SynologyPhotoFolderMemberRole) { self.action = action; self.role = role }
        public func applying(to value: String?) -> String? {
            let current = value.flatMap(SynologyPhotoFolderMemberRole.init(rawValue:))?.level ?? -1
            switch action {
            case .checkAll: return current <= role.level ? role.rawValue : value
            case .uncheckAll:
                guard current >= role.level - 1 else { return value }
                return SynologyPhotoFolderMemberRole.allCases.first(where: { $0.level == role.level - 1 })?.rawValue
            }
        }
    }
    public let memberID: SynologyPhotoShareRecipient.ID
    public let original: [SynologyPhotoMemberFolder]
    public var batch: Batch?
    public var changes: [Change]
    public init(memberID: SynologyPhotoShareRecipient.ID, original: [SynologyPhotoMemberFolder], batch: Batch? = nil, changes: [Change] = []) {
        self.memberID = memberID; self.original = original; self.batch = batch; self.changes = changes
    }
    public func expectedRole(for folder: SynologyPhotoMemberFolder, includingChanges: Bool = true) -> String? {
        func ownRole(_ item: SynologyPhotoMemberFolder) -> String? {
            if includingChanges, let change = changes.first(where: { $0.folderID == item.id }) { return change.role?.rawValue }
            if let batch { return batch.applying(to: item.directRole) }
            return item.directRole
        }
        if includingChanges, folder.depth == 1, let parent = original.first(where: { $0.id == folder.folder.parentID }),
           parent.privacy == "private", parent.directRole != nil, ownRole(parent) == nil { return nil }
        return ownRole(folder)
    }
    public var canSave: Bool {
        guard !original.isEmpty, Set(original.map(\.id)).count == original.count,
              Set(changes.map(\.folderID)).count == changes.count,
              original.allSatisfy({ $0.memberID == memberID }),
              (batch == nil || original.allSatisfy(\.hasKnownPermissions)),
              changes.allSatisfy({ change in original.contains { $0.id == change.folderID } }) else { return false }
        for change in changes {
            guard let folder = original.first(where: { $0.id == change.folderID }), folder.hasKnownPermissions else { return false }
            if folder.depth == 1 {
                guard let parent = original.first(where: { $0.id == folder.folder.parentID }),
                      parent.hasKnownPermissions,
                      parent.publicRole != nil || expectedRole(for: parent) != nil else { return false }
            }
        }
        return original.contains { folder in
            guard folder.hasKnownPermissions else { return false }
            let expected = max(expectedRole(for: folder).flatMap(SynologyPhotoFolderMemberRole.init(rawValue:))?.level ?? -1, folder.publicRole?.level ?? -1)
            return expected != (folder.effectiveRole?.level ?? -1)
        }
    }
}

/// 管理员设置的完整原快照；未知字段保留未知，不以缺失值推断关闭。
public struct SynologyPhotoGlobalSettings: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case person = "enable_person", concept = "enable_concept", similar = "enable_similar"
        case userSharing = "enable_user_sharing", guestInfo = "display_photo_info_to_guest"
        case originalJPEG = "enable_converted_original_jpeg"
    }
    public let profileID: UUID
    public let administratorID: Int
    public var values: [Kind: Bool]
    public var excludedExtensions: Set<String>?
    public let hasHEVC: Bool?
    public var personalRecognition: [SynologyPhotoRecognitionSettings.Kind: Bool]
    public var sharedRecognition: [SynologyPhotoRecognitionSettings.Kind: Bool]
    public let personalSpaceEnabled: Bool
    public let sharedSpaceEnabled: Bool
    public let sharedRole: SynologyPhotoSharedSpaceSettings.Role
    public init(profileID: UUID, administratorID: Int, values: [Kind: Bool], excludedExtensions: Set<String>?, hasHEVC: Bool?,
                personalRecognition: [SynologyPhotoRecognitionSettings.Kind: Bool], sharedRecognition: [SynologyPhotoRecognitionSettings.Kind: Bool],
                personalSpaceEnabled: Bool, sharedSpaceEnabled: Bool, sharedRole: SynologyPhotoSharedSpaceSettings.Role) {
        self.profileID = profileID; self.administratorID = administratorID; self.values = values
        self.excludedExtensions = excludedExtensions; self.hasHEVC = hasHEVC
        self.personalRecognition = personalRecognition; self.sharedRecognition = sharedRecognition
        self.personalSpaceEnabled = personalSpaceEnabled; self.sharedSpaceEnabled = sharedSpaceEnabled; self.sharedRole = sharedRole
    }
    public var enabled: Set<Kind> { Set(values.filter(\.value).map(\.key)) }
    public var editable: Set<Kind> { Set(values.keys).subtracting(hasHEVC == true ? [] : [.originalJPEG]) }
    public var supportsOriginalJPEG: Bool { values[.originalJPEG] == true && hasHEVC == true }
    /// 来自官方 Photos 设置页格式选项；既有未知格式仍显示并保留，允许用户移除。
    public static let supportedExtensions = Set("jpg jpeg jpe webp bmp png gif tif tiff heic heif hif arw srf sr2 dcr k25 kdc cr2 cr3 crw nef mrw ptx pef raf 3fr erf mef mos orf rw2 dng x3f raw mpg mpeg avi asf wmv mov flv f4v mp4 divx xvid m2ts m2t mts m4v 3gp 3g2 qt".uppercased().split(separator: " ").map(String.init))
    public func applying(enabled: Set<Kind>, excludedExtensions: Set<String>?) -> Self {
        var target = self
        for kind in values.keys { target.values[kind] = enabled.contains(kind) }
        target.excludedExtensions = excludedExtensions
        for kind in SynologyPhotoRecognitionSettings.Kind.allCases {
            guard let global = Kind(rawValue: kind.rawValue), target.values[global] == false else { continue }
            if target.personalRecognition[kind] != nil { target.personalRecognition[kind] = false }
            if target.sharedRecognition[kind] != nil { target.sharedRecognition[kind] = false }
        }
        return target
    }
    public func canSave(enabled: Set<Kind>, excludedExtensions: Set<String>?) -> Bool {
        guard enabled.isSubset(of: Set(values.keys)), enabled.symmetricDifference(self.enabled).isSubset(of: editable),
              (self.excludedExtensions == nil) == (excludedExtensions == nil) else { return false }
        if let excludedExtensions, !excludedExtensions.isSubset(of: Self.supportedExtensions.union(self.excludedExtensions ?? [])) { return false }
        return applying(enabled: enabled, excludedExtensions: excludedExtensions) != self
    }
    public func recognition(in space: SynologyPhotoSpace) -> SynologyPhotoRecognitionSettings {
        let current = space == .personal ? personalRecognition : sharedRecognition
        let global = Set(SynologyPhotoRecognitionSettings.Kind.allCases.filter { values[Kind(rawValue: $0.rawValue)!] != false })
        return .init(values: current, globallyEnabled: global, personalSpaceEnabled: space == .personal ? personalSpaceEnabled : sharedSpaceEnabled)
    }
}

/// 缓存只保留当前读取的大小和清理状态，不落盘保存，也不关联真实照片列表。
public struct SynologyPhotoConversionCache: Equatable, Sendable {
    public let profileID: UUID
    public let administratorID: Int
    public let sizeBytes: Int64
    public let isClearing: Bool
    public init(profileID: UUID, administratorID: Int, sizeBytes: Int64, isClearing: Bool) {
        self.profileID = profileID; self.administratorID = administratorID; self.sizeBytes = sizeBytes; self.isClearing = isClearing
    }
    public var canClear: Bool { sizeBytes > 0 && !isClearing }
}


/// NAS复制/移动任务快照；处理数量包含失败，不把done等同全部成功。
public struct SynologyPhotoBackgroundTask: Equatable, Identifiable, Sendable {
    public enum Status: String, Sendable { case waiting, processing, aborting, done, unknown }
    public let profileID: UUID
    public let userID: Int
    public let id: Int
    public let operation: String
    public let status: Status
    public let total: Int
    public let completion: Int
    public let errors: Int
    public let skipped: Int
    public let overwritten: Int
    public let createdAt: Double
    public let targetFolderID: Int?
    public let targetOwnerID: Int?
    public init(profileID: UUID, userID: Int, id: Int, operation: String, status: Status, total: Int,
                completion: Int, errors: Int, skipped: Int, overwritten: Int, createdAt: Double,
                targetFolderID: Int?, targetOwnerID: Int?) {
        self.profileID = profileID; self.userID = userID; self.id = id; self.operation = operation
        self.status = status; self.total = total; self.completion = completion; self.errors = errors
        self.skipped = skipped; self.overwritten = overwritten; self.createdAt = createdAt
        self.targetFolderID = targetFolderID; self.targetOwnerID = targetOwnerID
    }
    public var isTransfer: Bool { operation == "copy" || operation == "move" }
    public var canCancel: Bool { isTransfer && [.waiting, .processing].contains(status) }
    public var canClear: Bool { isTransfer && status == .done }
    public var isCancelled: Bool { status == .done && completion < total }
    public var successfulCount: Int { max(0, completion - errors) }
    public var targetSpace: SynologyPhotoSpace? {
        guard let owner = targetOwnerID else { return nil }
        if owner == 0 { return .shared }
        return owner == userID ? .personal : nil
    }
    /// 进度变化不改变任务身份；账号、创建时间、操作与目标不允许被同编号替换。
    public func hasSameIdentity(as other: Self) -> Bool {
        profileID == other.profileID && userID == other.userID && id == other.id &&
        operation == other.operation && createdAt == other.createdAt && total == other.total &&
        targetFolderID == other.targetFolderID && targetOwnerID == other.targetOwnerID
    }
}

public struct SynologyPhotoBackgroundTaskError: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case item, folder, unknown }
    public enum Reason: String, Sendable {
        case quota = "quota_full", space = "space_full", subfolder = "skipped", missing = "not_existed"
        case targetMissing = "target_not_existed", excluded = "excluded_extension", unknown
    }
    public var id: String { "\(kind.rawValue):\(itemID)" }
    public let kind: Kind
    public let itemID: Int
    public let reason: Reason
    public let name: String?
    public let folderPath: String?
    public init(kind: Kind, itemID: Int, reason: Reason, name: String? = nil, folderPath: String? = nil) {
        self.kind = kind; self.itemID = itemID; self.reason = reason; self.name = name; self.folderPath = folderPath
    }
}


/// 冻结相册确认快照。原始规则仅在内存比较，不持久化或写入新相册。
public struct SynologyPhotoFrozenAlbum: Equatable, Sendable {
    public let profileID: UUID
    public let userID: Int
    public let album: SynologyPhotoCollection
    public let rawCondition: [String: SynologyPhotoConditionValue]
    public let unsupportedConditions: [String: SynologyPhotoConditionValue]
    public let rebuildCondition: SynologyPhotoAlbumCondition?
    public let sharingRevision: String?
    public let isShared: Bool
    public init(profileID: UUID, userID: Int, album: SynologyPhotoCollection,
                rawCondition: [String: SynologyPhotoConditionValue], unsupportedConditions: [String: SynologyPhotoConditionValue],
                rebuildCondition: SynologyPhotoAlbumCondition?, sharingRevision: String?, isShared: Bool) {
        self.profileID = profileID; self.userID = userID; self.album = album
        self.rawCondition = rawCondition; self.unsupportedConditions = unsupportedConditions
        self.rebuildCondition = rebuildCondition; self.sharingRevision = sharingRevision; self.isShared = isShared
    }
    public var canRebuild: Bool {
        rebuildCondition != nil && !(rawCondition.count == 1 && rawCondition["user_id"]?.integer == 0)
    }
    /// 缩略图刷新和显示名称本地化不改变待恢复对象身份。
    public func hasSameState(as other: Self) -> Bool {
        profileID == other.profileID && userID == other.userID && album.id == other.album.id &&
        album.name == other.album.name && album.itemCount == other.album.itemCount &&
        album.isFrozen == other.album.isFrozen && album.isConditional == other.album.isConditional &&
        rawCondition == other.rawCondition && unsupportedConditions == other.unsupportedConditions &&
        sharingRevision == other.sharingRevision && isShared == other.isShared
    }
}

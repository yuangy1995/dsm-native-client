import Foundation

/// Photos 的空间和项目身份不依赖 File Station 路径。
public enum SynologyPhotoSpace: String, CaseIterable, Codable, Sendable {
    case personal
    case shared
}

/// 下载格式独立于原件；NAS无法提供压缩图时可能返回原格式。
public enum SynologyPhotoDownloadFormat: Equatable, Sendable {
    case original, optimizedJPEG, originalSizeJPEG
}

/// 整个集合的下载目标，不依赖当前页面已加载的成员。
public enum SynologyPhotoArchiveTarget: Equatable, Sendable {
    case album(id: Int)
    case folder(id: Int, space: SynologyPhotoSpace)
    /// 同一目录的选择快照；至少包含一个子目录，子目录包含全部后代。
    case selection(photos: [SynologyPhoto], folders: [SynologyPhotoCollection])
}

public struct SynologyPhotoID: Hashable, Sendable {
    public let profileID: UUID
    public let space: SynologyPhotoSpace
    public let unitID: Int

    public init(profileID: UUID, space: SynologyPhotoSpace, unitID: Int) {
        self.profileID = profileID
        self.space = space
        self.unitID = unitID
    }
}

public struct SynologyPhotoThumbnail: Hashable, Sendable {
    public let unitID: Int
    public let revision: String

    public init(unitID: Int, revision: String) {
        self.unitID = unitID
        self.revision = revision
    }
}

/// 官方自动队列按数字升序处理；后台候选不从文件名猜测编码。
public enum SynologyPhotoAutomaticPreviewPriority: Int, Hashable, Sendable {
    case standard = 1, hevcOrLiveVideo = 2, vc1 = 3, background = 4
}

/// 自动转换按预览单元读取，编号不得当作图库项目编号使用。
public struct SynologyPhotoAutomaticPreviewTask: Hashable, Sendable {
    public let profileID: UUID
    public let space: SynologyPhotoSpace
    public let unitID: Int
    public let filename: String
    /// 保留接口原值；官方列表将0映射照片，非0映射视频，不能从扩展名猜测。
    public let typeCode: Int
    public let needsThumbnail: Bool
    public let needsVideo: Bool
    /// 浏览触发的候选保留原照片快照；nil表示后台候选列表来源。
    public let sourcePhoto: SynologyPhoto?
    public let priority: SynologyPhotoAutomaticPreviewPriority

    public init(profileID: UUID, space: SynologyPhotoSpace, unitID: Int, filename: String,
                typeCode: Int, needsThumbnail: Bool, needsVideo: Bool, sourcePhoto: SynologyPhoto? = nil,
                priority: SynologyPhotoAutomaticPreviewPriority? = nil) {
        self.profileID = profileID; self.space = space; self.unitID = unitID; self.filename = filename
        self.typeCode = typeCode; self.needsThumbnail = needsThumbnail; self.needsVideo = needsVideo
        self.sourcePhoto = sourcePhoto
        self.priority = priority ?? (sourcePhoto == nil ? .background : .standard)
    }
}

/// 由实际转换后端提供能力，不代表当前设备已安装官方浏览器扩展。
public struct SynologyPhotoPreviewConversionSupport: Equatable, Sendable {
    public let hevc: Bool
    public let vc1: Bool
    public let video: Bool
    public init(hevc: Bool, vc1: Bool, video: Bool) { self.hevc = hevc; self.vc1 = vc1; self.video = video }
}

/// 相册内读取必须携带原相册，不能把相册访问权当成原件空间的写权限。
public struct SynologyPhotoAlbumContext: Hashable, Sendable {
    public let albumID: Int
    public let ownerUserID: Int
    public let providerUserID: Int?

    public init(albumID: Int, ownerUserID: Int, providerUserID: Int? = nil) {
        self.albumID = albumID
        self.ownerUserID = ownerUserID
        self.providerUserID = providerUserID
    }
}

public struct SynologyPhoto: Identifiable, Hashable, Sendable {
    public let id: SynologyPhotoID
    public let filename: String
    public let sizeBytes: Int64
    public let takenAt: Date
    public let indexedAt: Date
    public let folderID: Int
    /// 保留套件类型，未知格式不按扩展名猜测为照片或视频。
    public let mediaType: String
    public let thumbnail: SynologyPhotoThumbnail?
    public let width: Int?
    public let height: Int?
    public let orientation: Int?
    public let albumContext: SynologyPhotoAlbumContext?
    public var originalOrientation: Int? = nil
    public var description: String? = nil
    public var camera: String? = nil
    public var duration: Double? = nil
    public var lens: String? = nil
    public var aperture: String? = nil
    public var exposureTime: String? = nil
    public var focalLength: String? = nil
    public var iso: String? = nil
    public var rating: Int? = nil
    public var tags: [SynologyPhotoFilterChoice]? = nil
    public var addressComponents: [String] = []
    public var latitude: Double? = nil
    public var longitude: Double? = nil
    public var similarGroup: SynologyPhotoSimilarGroup? = nil

    /// 与官方预览菜单一致；方向值来自照片详情，不从文件名猜测。
    public var supportsRotation: Bool {
        ["photo", "live", "motion_photo", "burst"].contains(mediaType) &&
        !["gif", "webp"].contains((filename as NSString).pathExtension.lowercased()) &&
        counterClockwiseOrientation != nil
    }

    /// 官方方向转换保留镜像语义，不能仅对角度取模。
    public var counterClockwiseOrientation: Int? {
        guard let orientation, (1...8).contains(orientation) else { return nil }
        return [8, 5, 6, 7, 4, 1, 2, 3][orientation - 1]
    }

    public var canPlayMotion: Bool {
        mediaType == "live" && (originalOrientation == nil || originalOrientation == orientation)
    }

    /// 官方下载菜单限定的原尺寸转换格式，仍需核对NAS解码能力与下载权限。
    public var supportsOriginalSizeJPEG: Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["heic", "heif", "hif"].contains(ext) {
            return ["photo", "photo360", "burst", "motion_photo", "live"].contains(mediaType)
        }
        return ["tif", "tiff", "arw", "srf", "sr2", "dcr", "k25", "kdc", "cr2", "cr3", "crw", "nef", "mrw",
                "ptx", "pef", "raf", "3fr", "erf", "mef", "mos", "orf", "rw2", "dng", "x3f", "raw"].contains(ext)
    }

    public init(
        id: SynologyPhotoID, filename: String, sizeBytes: Int64,
        takenAt: Date, indexedAt: Date, folderID: Int, mediaType: String,
        thumbnail: SynologyPhotoThumbnail? = nil, width: Int? = nil,
        height: Int? = nil, orientation: Int? = nil,
        albumContext: SynologyPhotoAlbumContext? = nil
    ) {
        self.id = id
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.takenAt = takenAt
        self.indexedAt = indexedAt
        self.folderID = folderID
        self.mediaType = mediaType
        self.thumbnail = thumbnail
        self.width = width
        self.height = height
        self.orientation = orientation
        self.albumContext = albumContext
    }
}

public struct SynologyPhotoPage: Equatable, Sendable {
    public let items: [SynologyPhoto]
    public let offset: Int
    public let nextOffset: Int
    public let hasMore: Bool

    public init(items: [SynologyPhoto], offset: Int, nextOffset: Int, hasMore: Bool) {
        self.items = items
        self.offset = offset
        self.nextOffset = nextOffset
        self.hasMore = hasMore
    }
}

public struct SynologyPhotoDay: Hashable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let itemCount: Int

    public init(year: Int, month: Int, day: Int, itemCount: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.itemCount = itemCount
    }
}

public struct SynologyPhotosAccess: Equatable, Sendable {
    public let automaticPreviewEnabled: Bool?
    public let spaces: [SynologyPhotoSpace]
    public let packageVersion: String
    /// Photos共享空间管理权限，不从DSM管理员身份推断。
    public let canManageSharedSpace: Bool
    public let supportsOriginalSizeJPEG: Bool
    public let displaySettings: SynologyPhotoDisplaySettings?

    public init(spaces: [SynologyPhotoSpace], packageVersion: String, canManageSharedSpace: Bool = false, supportsOriginalSizeJPEG: Bool = false, displaySettings: SynologyPhotoDisplaySettings? = nil, automaticPreviewEnabled: Bool? = nil) {
        self.automaticPreviewEnabled = automaticPreviewEnabled
        self.spaces = spaces
        self.packageVersion = packageVersion
        self.canManageSharedSpace = canManageSharedSpace
        self.supportsOriginalSizeJPEG = supportsOriginalSizeJPEG
        self.displaySettings = displaySettings
    }
}

public enum SynologyPhotoDeletionResult: Equatable, Sendable { case confirmed, pendingReview }

/// 相册首页与两类分享列表各自保存浏览偏好，不改变相册内容或共享权限。
public enum SynologyPhotoAlbumListScope: String, CaseIterable, Sendable {
    case albums = "album_list", withMe = "shared_with_me", byMe = "shared_with_others"
    public var fields: [SynologyPhotoAlbumListSort.Field] {
        self == .albums ? [.name, .type, .startTime, .created, .sharing] : [.name, .type, .startTime, .shareModified]
    }
}
public enum SynologyPhotoAlbumDisplay: String, CaseIterable, Sendable {
    case all = "all_album", mine = "my_album"
}
public struct SynologyPhotoAlbumListSort: Equatable, Sendable {
    public enum Field: String, CaseIterable, Sendable {
        case name = "album_name", type = "album_type", startTime = "start_time", created = "create_time"
        case sharing = "share_status", shareModified = "share_modify_time"
    }
    public let field: Field
    public let direction: SynologyPhotoSort.Direction
    public init(field: Field, direction: SynologyPhotoSort.Direction) { self.field = field; self.direction = direction }
}

/// 目录照片按NAS统一排序分页，字段及方向不依赖界面语言。
public struct SynologyPhotoSort: Hashable, Sendable {
    public enum Field: String, CaseIterable, Sendable { case filename, filesize, itemType = "item_type", takenTime = "takentime" }
    public enum Direction: String, CaseIterable, Sendable { case ascending = "asc", descending = "desc" }
    public var field: Field
    public var direction: Direction
    public init(field: Field = .takenTime, direction: Direction = .ascending) { self.field = field; self.direction = direction }
}

public enum SynologyPhotoQuery: Hashable, Sendable {
    case timeline(startTime: Int, endTime: Int)
    case search(keyword: String, startTime: Int, endTime: Int)
    case folder(id: Int, sort: SynologyPhotoSort = .init())
    case album(id: Int, sort: SynologyPhotoSort = .init(direction: .descending))
    case recentlyAdded
    case similar(startTime: Int, endTime: Int)
    case filtered(SynologyPhotoFilter, startTime: Int, endTime: Int)
    case category(SynologyPhotoCategory, id: Int, startTime: Int, endTime: Int)
}

public enum SynologyPhotoCategory: String, CaseIterable, Hashable, Sendable {
    case recentlyAdded, person, concept, location, tags, videos, similar
}

/// 相似组是同一空间内的成员快照，不代表删除或修改原件的权限。
public struct SynologyPhotoSimilarGroup: Hashable, Sendable {
    public let profileID: UUID
    public let space: SynologyPhotoSpace
    public let id: Int
    public let photoIDs: [Int]
    public let topPickID: Int
    public init(profileID: UUID, space: SynologyPhotoSpace, id: Int, photoIDs: [Int], topPickID: Int) {
        self.profileID = profileID; self.space = space; self.id = id; self.photoIDs = photoIDs; self.topPickID = topPickID
    }
}

/// 相似识别处理状态；零待处理且迁移完成时不显示提示。
public struct SynologyPhotoSimilarStatus: Equatable, Sendable {
    public let waitingCount: Int
    public let stage: String
    public let migrationComplete: Bool
    public init(waitingCount: Int, stage: String, migrationComplete: Bool) {
        self.waitingCount = waitingCount; self.stage = stage; self.migrationComplete = migrationComplete
    }
    public var isVisible: Bool { waitingCount > 0 || !migrationComplete }
    public var isRunning: Bool { waitingCount > 0 && stage == "running" }
}

public struct SynologyPhotoSimilarDetail: Equatable, Sendable {
    public let group: SynologyPhotoSimilarGroup
    public let photos: [SynologyPhoto]
    public init(group: SynologyPhotoSimilarGroup, photos: [SynologyPhoto]) { self.group = group; self.photos = photos }
}

public struct SynologyPhotoFilter: Hashable, Sendable {
    public var mediaType: Int?
    public var startTime: Int?
    public var endTime: Int?
    public var personID: Int?
    public var locationID: Int?
    public var rating: Int?
    public var tagID: Int?
    public var cameraID: Int?
    public var lensID: Int?
    public var isoID: Int?
    public var apertureID: Int?
    public var focalRange: SynologyPhotoFocalRange?
    public var exposureRange: SynologyPhotoExposureRange?
    public init() {}
    public var isActive: Bool {
        mediaType != nil || startTime != nil || personID != nil || locationID != nil || rating != nil
            || tagID != nil || cameraID != nil || lensID != nil || isoID != nil || apertureID != nil
            || focalRange != nil || exposureRange != nil
    }
}

public struct SynologyPhotoFilterChoice: Decodable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public init(id: Int, name: String) { self.id = id; self.name = name }
}
public struct SynologyPhotoFocalRange: Decodable, Hashable, Sendable {
    public let start: Int
    public let end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}
public struct SynologyPhotoFraction: Decodable, Hashable, Sendable {
    public let num: Int
    public let den: Int
    public init(num: Int, den: Int) { self.num = num; self.den = den }
}
public struct SynologyPhotoExposureRange: Decodable, Hashable, Sendable {
    public let start: SynologyPhotoFraction
    public let end: SynologyPhotoFraction
    public init(start: SynologyPhotoFraction, end: SynologyPhotoFraction) { self.start = start; self.end = end }
}

public struct SynologyPhotoFilterOptions: Sendable {
    public let people: [SynologyPhotoCollection]
    public let locations: [SynologyPhotoLocation]
    public let tags: [SynologyPhotoFilterChoice]
    public let cameras: [SynologyPhotoFilterChoice]
    public let lenses: [SynologyPhotoFilterChoice]
    public let isoValues: [SynologyPhotoFilterChoice]
    public let apertures: [SynologyPhotoFilterChoice]
    public let focalRanges: [SynologyPhotoFocalRange]
    public let exposureRanges: [SynologyPhotoExposureRange]
    public init(people: [SynologyPhotoCollection], locations: [SynologyPhotoLocation],
                tags: [SynologyPhotoFilterChoice] = [], cameras: [SynologyPhotoFilterChoice] = [],
                lenses: [SynologyPhotoFilterChoice] = [], isoValues: [SynologyPhotoFilterChoice] = [],
                apertures: [SynologyPhotoFilterChoice] = [], focalRanges: [SynologyPhotoFocalRange] = [],
                exposureRanges: [SynologyPhotoExposureRange] = []) {
        self.people = people; self.locations = locations
        self.tags = tags; self.cameras = cameras; self.lenses = lenses; self.isoValues = isoValues
        self.apertures = apertures; self.focalRanges = focalRanges; self.exposureRanges = exposureRanges
    }
}

public struct SynologyPhotoLocation: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let level: Int
    public let children: [SynologyPhotoLocation]
    public init(id: Int, name: String, level: Int, children: [SynologyPhotoLocation] = []) {
        self.id = id; self.name = name; self.level = level; self.children = children
    }
}

public enum SynologyPhotoShareScope: String, CaseIterable, Sendable { case withMe, withOthers, requests }
public struct SynologyPhotoSharedEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let albumID: Int?
    public let url: URL?
    public init(id: String, title: String, albumID: Int? = nil, url: URL? = nil) {
        self.id = id; self.title = title; self.albumID = albumID; self.url = url
    }
}

/// 替换后的照片库只接受 Photos 身份，不提供扫描文件夹或 FileItem 转换入口。
public protocol SynologyPhotosServing: Sendable {
    func albumAccess(id: Int) async throws -> SynologyPhotoAlbumAccess
    func addableAlbums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection]
    func photoRequest(id: String) async throws -> SynologyPhotoRequest
    func photoRequestAlbums() async throws -> [SynologyPhotoRequestAlbum]
    func personFaces(personID: Int, photos: [SynologyPhoto]) async throws -> [SynologyPhotoFace]
    func thumbnail(for face: SynologyPhotoFace) async throws -> Data
    func managementPeople() async throws -> [SynologyPhotoCollection]
    func managementPeople(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoCollection]
    func conceptState(id: Int, in space: SynologyPhotoSpace) async throws -> SynologyPhotoConceptVisibility
    func conceptVisibility(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoConceptVisibility]
    func peopleVisibility(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoPersonVisibility]
    func peopleVisibility() async throws -> [SynologyPhotoPersonVisibility]
    func photoFaces(for photo: SynologyPhoto) async throws -> [SynologyPhotoFaceRegion]
    func albumSharing(id: Int) async throws -> SynologyPhotoSharingState
    func folderSharing(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoFolderSharingState
    func folderSharingRecipients() async throws -> [SynologyPhotoShareRecipient]
    func sharingRecipients() async throws -> [SynologyPhotoShareRecipient]
    func frozenAlbum(id: Int) async throws -> SynologyPhotoFrozenAlbum
    func albumCondition(id: Int) async throws -> SynologyPhotoAlbumCondition
    func conditionSuggestions(keyword: String) async throws -> [String: [SynologyPhotoConditionOption]]
    func conditionSuggestions(keyword: String, in space: SynologyPhotoSpace) async throws -> [String: [SynologyPhotoConditionOption]]
    func conditionItemCount(_ condition: SynologyPhotoAlbumCondition) async throws -> Int
    func pendingPreviewRegenerations(in space: SynologyPhotoSpace) async throws -> [SynologyPhoto]
    func automaticPreviewTasks(in space: SynologyPhotoSpace, support: SynologyPhotoPreviewConversionSupport) async throws -> [SynologyPhotoAutomaticPreviewTask]
    func automaticPreviewTasks(for photo: SynologyPhoto, support: SynologyPhotoPreviewConversionSupport) async throws -> [SynologyPhotoAutomaticPreviewTask]
    func codecPrompt() async throws -> SynologyPhotoCodecPrompt
    func libraryMaintenanceStatus(in space: SynologyPhotoSpace) async throws -> SynologyPhotoLibraryMaintenanceStatus
    func automaticPreviewEnabled() async throws -> Bool
    func downloadAutomaticPreviewSource(_ task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport, to destination: URL, progress: @escaping FileTransferProgress) async throws
    func managementFeatures() async -> Set<SynologyPhotosManagementFeature>
    func managementFeatures(in space: SynologyPhotoSpace) async -> Set<SynologyPhotosManagementFeature>
    func backgroundTasks() async throws -> [SynologyPhotoBackgroundTask]
    func backgroundTaskErrors(_ task: SynologyPhotoBackgroundTask) async throws -> [SynologyPhotoBackgroundTaskError]
    func prepareMutation(_ mutation: SynologyPhotosMutation) async throws
    func performMutation(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress) async throws -> SynologyPhotosMutationResult
    func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult
    func uploadRecoveryIdentity() async throws -> String
    func performRecoverableUpload(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress, checkpoint: @escaping @Sendable (SynologyPhotosUploadCheckpoint) throws -> Void) async throws -> SynologyPhotosMutationResult
    func restoreUploadMutation(_ checkpoint: SynologyPhotosUploadCheckpoint) async throws
    func forgetUploadMutation(operationID: UUID) async throws
    func prepareDeletion(_ photo: SynologyPhoto) async throws
    func deletePhoto(_ photo: SynologyPhoto, operationID: UUID) async throws -> SynologyPhotoDeletionResult
    func reviewDeletion(_ photo: SynologyPhoto) async throws -> SynologyPhotoDeletionResult
    func access() async throws -> SynologyPhotosAccess
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay]
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay]
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage
    func thumbnail(for photo: SynologyPhoto) async throws -> Data
    func thumbnail(for album: SynologyPhotoCollection) async throws -> Data
    func folderCoverImages(_ folder: SynologyPhotoCollection) async throws -> [Data]
    func albumSort(id: Int) async throws -> SynologyPhotoSort
    func albumListSort(_ scope: SynologyPhotoAlbumListScope) async throws -> SynologyPhotoAlbumListSort
    func albumListDisplay() async throws -> SynologyPhotoAlbumDisplay
    func albums(offset: Int, limit: Int, display: SynologyPhotoAlbumDisplay?, sort: SynologyPhotoAlbumListSort?) async throws -> [SynologyPhotoCollection]
    func sharedEntries(_ scope: SynologyPhotoShareScope, offset: Int, limit: Int, sort: SynologyPhotoAlbumListSort?) async throws -> [SynologyPhotoSharedEntry]
    func folderSort(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoSort
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int, direction: SynologyPhotoSort.Direction) async throws -> [SynologyPhotoCollection]
    func thumbnail(for collection: SynologyPhotoCollection, category: SynologyPhotoCategory) async throws -> Data
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection
    func folder(id: Int, in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection]
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection]
    func details(for photo: SynologyPhoto) async throws -> SynologyPhoto
    func previewImage(for photo: SynologyPhoto) async throws -> Data
    func videoSource(for photo: SynologyPhoto) async throws -> MediaStreamSource
    func downloadOriginal(_ photo: SynologyPhoto, to destination: URL, progress: @escaping FileTransferProgress) async throws
    func download(_ photo: SynologyPhoto, format: SynologyPhotoDownloadFormat, to destination: URL, progress: @escaping FileTransferProgress) async throws -> SynologyPhotoDownloadFormat
    func downloadArchive(_ target: SynologyPhotoArchiveTarget, format: SynologyPhotoDownloadFormat, to destination: URL, progress: @escaping FileTransferProgress) async throws
    func globalSettings() async throws -> SynologyPhotoGlobalSettings
    func conversionCache() async throws -> SynologyPhotoConversionCache
    func sharedSpaceSettings() async throws -> SynologyPhotoSharedSpaceSettings
    func sharedSpaceMembers() async throws -> SynologyPhotoSharedMembers
    func sharedSpaceMemberCandidates() async throws -> [SynologyPhotoShareRecipient]
    func sharedSpaceMemberFolderSnapshot(for member: SynologyPhotoShareRecipient.ID) async throws -> [SynologyPhotoMemberFolder]
    func sharedSpaceMemberFolders(for member: SynologyPhotoShareRecipient.ID, parent: SynologyPhotoMemberFolder?, offset: Int, limit: Int) async throws -> SynologyPhotoMemberFolderPage
    func recognitionSettings() async throws -> SynologyPhotoRecognitionSettings
    func displaySettings() async throws -> SynologyPhotoDisplaySettings
    func duplicateSettings() async throws -> SynologyPhotoDuplicateSettings
    func filteredTimeline(in space: SynologyPhotoSpace, filter: SynologyPhotoFilter) async throws -> [SynologyPhotoDay]
    func filterOptions(in space: SynologyPhotoSpace) async throws -> SynologyPhotoFilterOptions
    func categories() async throws -> Set<SynologyPhotoCategory>
    func categories(in space: SynologyPhotoSpace) async throws -> Set<SynologyPhotoCategory>
    func categoryPreviewImages(_ category: SynologyPhotoCategory, in space: SynologyPhotoSpace) async throws -> [Data]
    func similarTimeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay]
    func similarGroupDetails(_ group: SynologyPhotoSimilarGroup) async throws -> SynologyPhotoSimilarDetail?
    func similarStatus(in space: SynologyPhotoSpace) async throws -> SynologyPhotoSimilarStatus
    func similarPhotos(for photo: SynologyPhoto) async throws -> SynologyPhotoSimilarDetail
    func categoryTimeline(_ category: SynologyPhotoCategory, id: Int, in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay]
    func categoryItems(_ category: SynologyPhotoCategory, in space: SynologyPhotoSpace, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection]
    func categoryTimeline(_ category: SynologyPhotoCategory, id: Int) async throws -> [SynologyPhotoDay]
    func categoryItems(_ category: SynologyPhotoCategory, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection]
    func sharedEntries(_ scope: SynologyPhotoShareScope, offset: Int, limit: Int) async throws -> [SynologyPhotoSharedEntry]
}

public struct SynologyPhotoCollection: Identifiable, Equatable, Sendable {
    public let space: SynologyPhotoSpace
    public let id: Int
    public let name: String
    public let parentID: Int?
    public let path: String?
    public let itemCount: Int?
    public let thumbnail: SynologyPhotoThumbnail?
    public let isConditional: Bool
    public let isFrozen: Bool
    public var acceptsManualMembers: Bool { !isConditional && !isFrozen }
    public let sort: SynologyPhotoSort?

    public init(id: Int, name: String, parentID: Int? = nil, itemCount: Int? = nil, thumbnail: SynologyPhotoThumbnail? = nil, isConditional: Bool = false, isFrozen: Bool = false, path: String? = nil, space: SynologyPhotoSpace = .personal, sort: SynologyPhotoSort? = nil) {
        self.space = space
        self.sort = sort
        self.path = path; self.isConditional = isConditional; self.isFrozen = isFrozen
        self.thumbnail = thumbnail
        self.id = id; self.name = name; self.parentID = parentID; self.itemCount = itemCount
    }
}

// 新增读取能力采用显式不支持，既有合成 Repository 不伪造成功结果。
public extension SynologyPhotosServing {
    func forgetUploadMutation(operationID: UUID) async throws { throw CapabilitySelectionError.unsupported(apiName: "Photos.UploadRecovery") }
    func uploadRecoveryIdentity() async throws -> String { throw CapabilitySelectionError.unsupported(apiName: "Photos.UploadRecovery") }
    func performRecoverableUpload(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress, checkpoint: @escaping @Sendable (SynologyPhotosUploadCheckpoint) throws -> Void) async throws -> SynologyPhotosMutationResult { throw CapabilitySelectionError.unsupported(apiName: "Photos.UploadRecovery") }
    func restoreUploadMutation(_ checkpoint: SynologyPhotosUploadCheckpoint) async throws { throw CapabilitySelectionError.unsupported(apiName: "Photos.UploadRecovery") }
    func globalSettings() async throws -> SynologyPhotoGlobalSettings { throw CapabilitySelectionError.unsupported(apiName: "Photos.GlobalSettings") }
    func conversionCache() async throws -> SynologyPhotoConversionCache { throw CapabilitySelectionError.unsupported(apiName: "Photos.ConversionCache") }
    func sharedSpaceSettings() async throws -> SynologyPhotoSharedSpaceSettings { throw CapabilitySelectionError.unsupported(apiName: "Photos.SharedSpaceSettings") }
    func sharedSpaceMembers() async throws -> SynologyPhotoSharedMembers { throw CapabilitySelectionError.unsupported(apiName: "Photos.SharedMembers") }
    func sharedSpaceMemberCandidates() async throws -> [SynologyPhotoShareRecipient] { throw CapabilitySelectionError.unsupported(apiName: "Photos.SharedMembers") }
    func sharedSpaceMemberFolderSnapshot(for member: SynologyPhotoShareRecipient.ID) async throws -> [SynologyPhotoMemberFolder] { throw CapabilitySelectionError.unsupported(apiName: "Photos.MemberFolders") }
    func sharedSpaceMemberFolders(for member: SynologyPhotoShareRecipient.ID, parent: SynologyPhotoMemberFolder?, offset: Int, limit: Int) async throws -> SynologyPhotoMemberFolderPage { throw CapabilitySelectionError.unsupported(apiName: "Photos.MemberFolders") }
    func recognitionSettings() async throws -> SynologyPhotoRecognitionSettings { throw CapabilitySelectionError.unsupported(apiName: "Photos.RecognitionSettings") }
    func displaySettings() async throws -> SynologyPhotoDisplaySettings { throw CapabilitySelectionError.unsupported(apiName: "Photos.DisplaySettings") }
    func duplicateSettings() async throws -> SynologyPhotoDuplicateSettings { throw CapabilitySelectionError.unsupported(apiName: "Photos.DuplicateSettings") }
    func albumListSort(_ scope: SynologyPhotoAlbumListScope) async throws -> SynologyPhotoAlbumListSort { throw CapabilitySelectionError.unsupported(apiName: "Photos.AlbumListSort") }
    func albumListDisplay() async throws -> SynologyPhotoAlbumDisplay { throw CapabilitySelectionError.unsupported(apiName: "Photos.AlbumListDisplay") }
    func albums(offset: Int, limit: Int, display: SynologyPhotoAlbumDisplay?, sort: SynologyPhotoAlbumListSort?) async throws -> [SynologyPhotoCollection] {
        guard display == nil, sort == nil else { throw CapabilitySelectionError.unsupported(apiName: "Photos.AlbumListPreferences") }
        return try await albums(offset: offset, limit: limit)
    }
    func sharedEntries(_ scope: SynologyPhotoShareScope, offset: Int, limit: Int, sort: SynologyPhotoAlbumListSort?) async throws -> [SynologyPhotoSharedEntry] {
        guard sort == nil else { throw CapabilitySelectionError.unsupported(apiName: "Photos.AlbumListSort") }
        return try await sharedEntries(scope, offset: offset, limit: limit)
    }
    func albumSort(id: Int) async throws -> SynologyPhotoSort { throw CapabilitySelectionError.unsupported(apiName: "Photos.AlbumSort") }
    func folderSort(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoSort { throw CapabilitySelectionError.unsupported(apiName: "Photos.FolderSort") }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int, direction: SynologyPhotoSort.Direction) async throws -> [SynologyPhotoCollection] {
        guard direction == .ascending else { throw CapabilitySelectionError.unsupported(apiName: "Photos.FolderSort") }
        return try await folders(in: space, parentID: parentID, offset: offset, limit: limit)
    }

    func similarTimeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Similar") }
    func similarGroupDetails(_ group: SynologyPhotoSimilarGroup) async throws -> SynologyPhotoSimilarDetail? { throw CapabilitySelectionError.unsupported(apiName: "Photos.Similar") }
    func similarStatus(in space: SynologyPhotoSpace) async throws -> SynologyPhotoSimilarStatus { throw CapabilitySelectionError.unsupported(apiName: "Photos.Similar") }
    func similarPhotos(for photo: SynologyPhoto) async throws -> SynologyPhotoSimilarDetail { throw CapabilitySelectionError.unsupported(apiName: "Photos.Similar") }
    func categoryPreviewImages(_ category: SynologyPhotoCategory, in space: SynologyPhotoSpace) async throws -> [Data] {
        throw CapabilitySelectionError.unsupported(apiName: "Photos.CategoryPreview")
    }
    func managementPeople(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoCollection] {
        guard space == .personal else { throw CapabilitySelectionError.unsupported(apiName: "Photos.SharedPeople") }
        return try await managementPeople()
    }
    func conceptState(id: Int, in space: SynologyPhotoSpace) async throws -> SynologyPhotoConceptVisibility { throw CapabilitySelectionError.unsupported(apiName: "Photos.Concept") }
    func conceptVisibility(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoConceptVisibility] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Concept") }
    func peopleVisibility(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoPersonVisibility] {
        guard space == .personal else { throw CapabilitySelectionError.unsupported(apiName: "Photos.SharedPeople") }
        return try await peopleVisibility()
    }
    func photoRequest(id: String) async throws -> SynologyPhotoRequest { throw CapabilitySelectionError.unsupported(apiName: "Photos.PhotoRequest") }
    func photoRequestAlbums() async throws -> [SynologyPhotoRequestAlbum] { throw CapabilitySelectionError.unsupported(apiName: "Photos.PhotoRequestAlbum") }
    func thumbnail(for collection: SynologyPhotoCollection, category: SynologyPhotoCategory) async throws -> Data { throw CapabilitySelectionError.unsupported(apiName: "Photos.CategoryThumbnail") }
    func personFaces(personID: Int, photos: [SynologyPhoto]) async throws -> [SynologyPhotoFace] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Person") }
    func thumbnail(for face: SynologyPhotoFace) async throws -> Data { throw CapabilitySelectionError.unsupported(apiName: "Photos.Person") }
    func photoFaces(for photo: SynologyPhoto) async throws -> [SynologyPhotoFaceRegion] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Item.list_face") }
    func peopleVisibility() async throws -> [SynologyPhotoPersonVisibility] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Person") }
    func managementPeople() async throws -> [SynologyPhotoCollection] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Person") }
    func folderSharing(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoFolderSharingState { throw CapabilitySelectionError.unsupported(apiName: "Photos.FolderSharing") }
    func folderSharingRecipients() async throws -> [SynologyPhotoShareRecipient] { throw CapabilitySelectionError.unsupported(apiName: "Photos.FolderSharing.Members") }
    func albumSharing(id: Int) async throws -> SynologyPhotoSharingState { throw CapabilitySelectionError.unsupported(apiName: "Photos.Sharing") }
    func albumAccess(id: Int) async throws -> SynologyPhotoAlbumAccess { throw CapabilitySelectionError.unsupported(apiName: "Photos.AlbumAccess") }
    func addableAlbums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { try await albums(offset: offset, limit: limit) }
    func sharingRecipients() async throws -> [SynologyPhotoShareRecipient] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Sharing.Members") }
    func frozenAlbum(id: Int) async throws -> SynologyPhotoFrozenAlbum { throw CapabilitySelectionError.unsupported(apiName: "Photos.FrozenAlbum") }
    func albumCondition(id: Int) async throws -> SynologyPhotoAlbumCondition { throw CapabilitySelectionError.unsupported(apiName: "Photos.ConditionAlbum") }
    func conditionSuggestions(keyword: String, in space: SynologyPhotoSpace) async throws -> [String: [SynologyPhotoConditionOption]] {
        guard space == .personal else { throw CapabilitySelectionError.unsupported(apiName: "Photos.ConditionAlbum") }
        return try await conditionSuggestions(keyword: keyword)
    }
    func conditionSuggestions(keyword: String) async throws -> [String: [SynologyPhotoConditionOption]] { throw CapabilitySelectionError.unsupported(apiName: "Photos.ConditionAlbum") }
    func conditionItemCount(_ condition: SynologyPhotoAlbumCondition) async throws -> Int { throw CapabilitySelectionError.unsupported(apiName: "Photos.ConditionAlbum") }
    func folderCoverImages(_ folder: SynologyPhotoCollection) async throws -> [Data] { throw CapabilitySelectionError.unsupported(apiName: "Photos.FolderCover") }
    func thumbnail(for album: SynologyPhotoCollection) async throws -> Data { throw CapabilitySelectionError.unsupported(apiName: "Photos.AlbumThumbnail") }
    func pendingPreviewRegenerations(in space: SynologyPhotoSpace) async throws -> [SynologyPhoto] { throw CapabilitySelectionError.unsupported(apiName: "Photos.PreviewRecovery") }
    func automaticPreviewTasks(in space: SynologyPhotoSpace, support: SynologyPhotoPreviewConversionSupport) async throws -> [SynologyPhotoAutomaticPreviewTask] { throw CapabilitySelectionError.unsupported(apiName: "Photos.AutomaticPreview") }
    func automaticPreviewTasks(for photo: SynologyPhoto, support: SynologyPhotoPreviewConversionSupport) async throws -> [SynologyPhotoAutomaticPreviewTask] { [] }
    func codecPrompt() async throws -> SynologyPhotoCodecPrompt { throw CapabilitySelectionError.unsupported(apiName: "Photos.CodecPrompt") }
    func libraryMaintenanceStatus(in space: SynologyPhotoSpace) async throws -> SynologyPhotoLibraryMaintenanceStatus { throw CapabilitySelectionError.unsupported(apiName: "Photos.LibraryMaintenance") }
    func automaticPreviewEnabled() async throws -> Bool { throw CapabilitySelectionError.unsupported(apiName: "Photos.AutomaticPreview") }
    func downloadAutomaticPreviewSource(_ task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport, to destination: URL, progress: @escaping FileTransferProgress) async throws { throw CapabilitySelectionError.unsupported(apiName: "Photos.AutomaticPreview") }
    func managementFeatures() async -> Set<SynologyPhotosManagementFeature> { [] }
    func managementFeatures(in space: SynologyPhotoSpace) async -> Set<SynologyPhotosManagementFeature> {
        space == .personal ? await managementFeatures() : []
    }
    func backgroundTasks() async throws -> [SynologyPhotoBackgroundTask] { throw CapabilitySelectionError.unsupported(apiName: "Photos.BackgroundTasks") }
    func backgroundTaskErrors(_ task: SynologyPhotoBackgroundTask) async throws -> [SynologyPhotoBackgroundTaskError] { throw CapabilitySelectionError.unsupported(apiName: "Photos.BackgroundTasks") }
    func prepareMutation(_ mutation: SynologyPhotosMutation) async throws { throw CapabilitySelectionError.unsupported(apiName: "Photos.Management") }
    func performMutation(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress) async throws -> SynologyPhotosMutationResult { throw CapabilitySelectionError.unsupported(apiName: "Photos.Management") }
    func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult { throw CapabilitySelectionError.unsupported(apiName: "Photos.Management") }
    func prepareDeletion(_ photo: SynologyPhoto) async throws { throw CapabilitySelectionError.unsupported(apiName: "Photos.Delete") }
    func deletePhoto(_ photo: SynologyPhoto, operationID: UUID) async throws -> SynologyPhotoDeletionResult { throw CapabilitySelectionError.unsupported(apiName: "Photos.Delete") }
    func reviewDeletion(_ photo: SynologyPhoto) async throws -> SynologyPhotoDeletionResult { throw CapabilitySelectionError.unsupported(apiName: "Photos.Delete") }
    func filteredTimeline(in space: SynologyPhotoSpace, filter: SynologyPhotoFilter) async throws -> [SynologyPhotoDay] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Filter") }
    func filterOptions(in space: SynologyPhotoSpace) async throws -> SynologyPhotoFilterOptions { throw CapabilitySelectionError.unsupported(apiName: "Photos.Filter") }
    func categories(in space: SynologyPhotoSpace) async throws -> Set<SynologyPhotoCategory> {
        guard space == .personal else { throw CapabilitySelectionError.unsupported(apiName: "Photos.SharedCategory") }
        return try await categories()
    }
    func categoryTimeline(_ category: SynologyPhotoCategory, id: Int, in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] {
        guard space == .personal else { throw CapabilitySelectionError.unsupported(apiName: "Photos.SharedCategory") }
        return try await categoryTimeline(category, id: id)
    }
    func categoryItems(_ category: SynologyPhotoCategory, in space: SynologyPhotoSpace, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        guard space == .personal else { throw CapabilitySelectionError.unsupported(apiName: "Photos.SharedCategory") }
        return try await categoryItems(category, offset: offset, limit: limit)
    }
    func categories() async throws -> Set<SynologyPhotoCategory> { [] }
    func categoryTimeline(_ category: SynologyPhotoCategory, id: Int) async throws -> [SynologyPhotoDay] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Category") }
    func categoryItems(_ category: SynologyPhotoCategory, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Category") }
    func sharedEntries(_ scope: SynologyPhotoShareScope, offset: Int, limit: Int) async throws -> [SynologyPhotoSharedEntry] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Sharing") }
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { throw CapabilitySelectionError.unsupported(apiName: "Photos.Folder") }
    func folder(id: Int, in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { throw CapabilitySelectionError.unsupported(apiName: "Photos.Folder") }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Folder") }
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Album") }
    func details(for photo: SynologyPhoto) async throws -> SynologyPhoto { throw CapabilitySelectionError.unsupported(apiName: "Photos.Item") }
    func previewImage(for photo: SynologyPhoto) async throws -> Data { throw CapabilitySelectionError.unsupported(apiName: "Photos.Thumbnail") }
    func videoSource(for photo: SynologyPhoto) async throws -> MediaStreamSource { throw CapabilitySelectionError.unsupported(apiName: "Photos.Streaming") }
    func downloadOriginal(_ photo: SynologyPhoto, to destination: URL, progress: @escaping FileTransferProgress) async throws { throw CapabilitySelectionError.unsupported(apiName: "Photos.Download") }
    func downloadArchive(_ target: SynologyPhotoArchiveTarget, format: SynologyPhotoDownloadFormat, to destination: URL, progress: @escaping FileTransferProgress) async throws { throw CapabilitySelectionError.unsupported(apiName: "Photos.Download.Archive") }
    func download(_ photo: SynologyPhoto, format: SynologyPhotoDownloadFormat, to destination: URL, progress: @escaping FileTransferProgress) async throws -> SynologyPhotoDownloadFormat {
        guard format == .original else { throw CapabilitySelectionError.unsupported(apiName: "Photos.Download.JPEG") }
        try await downloadOriginal(photo, to: destination, progress: progress)
        return .original
    }
}

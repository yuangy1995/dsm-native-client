import Foundation

/// Photos 的空间和项目身份不依赖 File Station 路径。
public enum SynologyPhotoSpace: String, CaseIterable, Codable, Sendable {
    case personal
    case shared
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
    public var description: String? = nil
    public var camera: String? = nil
    public var duration: Double? = nil
    public var lens: String? = nil
    public var aperture: String? = nil
    public var exposureTime: String? = nil
    public var focalLength: String? = nil
    public var iso: String? = nil
    public var rating: Int? = nil
    public var addressComponents: [String] = []
    public var latitude: Double? = nil
    public var longitude: Double? = nil

    public init(
        id: SynologyPhotoID, filename: String, sizeBytes: Int64,
        takenAt: Date, indexedAt: Date, folderID: Int, mediaType: String,
        thumbnail: SynologyPhotoThumbnail? = nil, width: Int? = nil,
        height: Int? = nil, orientation: Int? = nil
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
    public let spaces: [SynologyPhotoSpace]
    public let packageVersion: String

    public init(spaces: [SynologyPhotoSpace], packageVersion: String) {
        self.spaces = spaces
        self.packageVersion = packageVersion
    }
}

public enum SynologyPhotoDeletionResult: Equatable, Sendable { case confirmed, pendingReview }

public enum SynologyPhotoQuery: Hashable, Sendable {
    case timeline(startTime: Int, endTime: Int)
    case search(keyword: String, startTime: Int, endTime: Int)
    case folder(id: Int)
    case album(id: Int)
    case recentlyAdded
    case filtered(SynologyPhotoFilter, startTime: Int, endTime: Int)
    case category(SynologyPhotoCategory, id: Int, startTime: Int, endTime: Int)
}

public enum SynologyPhotoCategory: String, CaseIterable, Hashable, Sendable {
    case recentlyAdded, person, concept, location, tags, videos
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
    func prepareDeletion(_ photo: SynologyPhoto) async throws
    func deletePhoto(_ photo: SynologyPhoto, operationID: UUID) async throws -> SynologyPhotoDeletionResult
    func reviewDeletion(_ photo: SynologyPhoto) async throws -> SynologyPhotoDeletionResult
    func access() async throws -> SynologyPhotosAccess
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay]
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay]
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage
    func thumbnail(for photo: SynologyPhoto) async throws -> Data
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection]
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection]
    func details(for photo: SynologyPhoto) async throws -> SynologyPhoto
    func previewImage(for photo: SynologyPhoto) async throws -> Data
    func videoSource(for photo: SynologyPhoto) async throws -> MediaStreamSource
    func downloadOriginal(_ photo: SynologyPhoto, to destination: URL, progress: @escaping FileTransferProgress) async throws
    func filteredTimeline(in space: SynologyPhotoSpace, filter: SynologyPhotoFilter) async throws -> [SynologyPhotoDay]
    func filterOptions(in space: SynologyPhotoSpace) async throws -> SynologyPhotoFilterOptions
    func categories() async throws -> Set<SynologyPhotoCategory>
    func categoryTimeline(_ category: SynologyPhotoCategory, id: Int) async throws -> [SynologyPhotoDay]
    func categoryItems(_ category: SynologyPhotoCategory, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection]
    func sharedEntries(_ scope: SynologyPhotoShareScope, offset: Int, limit: Int) async throws -> [SynologyPhotoSharedEntry]
}

public struct SynologyPhotoCollection: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let parentID: Int?
    public let itemCount: Int?

    public init(id: Int, name: String, parentID: Int? = nil, itemCount: Int? = nil) {
        self.id = id; self.name = name; self.parentID = parentID; self.itemCount = itemCount
    }
}

// 新增读取能力采用显式不支持，既有合成 Repository 不伪造成功结果。
public extension SynologyPhotosServing {
    func prepareDeletion(_ photo: SynologyPhoto) async throws { throw CapabilitySelectionError.unsupported(apiName: "Photos.Delete") }
    func deletePhoto(_ photo: SynologyPhoto, operationID: UUID) async throws -> SynologyPhotoDeletionResult { throw CapabilitySelectionError.unsupported(apiName: "Photos.Delete") }
    func reviewDeletion(_ photo: SynologyPhoto) async throws -> SynologyPhotoDeletionResult { throw CapabilitySelectionError.unsupported(apiName: "Photos.Delete") }
    func filteredTimeline(in space: SynologyPhotoSpace, filter: SynologyPhotoFilter) async throws -> [SynologyPhotoDay] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Filter") }
    func filterOptions(in space: SynologyPhotoSpace) async throws -> SynologyPhotoFilterOptions { throw CapabilitySelectionError.unsupported(apiName: "Photos.Filter") }
    func categories() async throws -> Set<SynologyPhotoCategory> { [] }
    func categoryTimeline(_ category: SynologyPhotoCategory, id: Int) async throws -> [SynologyPhotoDay] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Category") }
    func categoryItems(_ category: SynologyPhotoCategory, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Category") }
    func sharedEntries(_ scope: SynologyPhotoShareScope, offset: Int, limit: Int) async throws -> [SynologyPhotoSharedEntry] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Sharing") }
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { throw CapabilitySelectionError.unsupported(apiName: "Photos.Folder") }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Folder") }
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { throw CapabilitySelectionError.unsupported(apiName: "Photos.Album") }
    func details(for photo: SynologyPhoto) async throws -> SynologyPhoto { throw CapabilitySelectionError.unsupported(apiName: "Photos.Item") }
    func previewImage(for photo: SynologyPhoto) async throws -> Data { throw CapabilitySelectionError.unsupported(apiName: "Photos.Thumbnail") }
    func videoSource(for photo: SynologyPhoto) async throws -> MediaStreamSource { throw CapabilitySelectionError.unsupported(apiName: "Photos.Streaming") }
    func downloadOriginal(_ photo: SynologyPhoto, to destination: URL, progress: @escaping FileTransferProgress) async throws { throw CapabilitySelectionError.unsupported(apiName: "Photos.Download") }
}

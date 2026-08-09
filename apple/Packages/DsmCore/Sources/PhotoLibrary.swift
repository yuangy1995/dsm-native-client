import Foundation
import DsmLocalization

public enum PhotoSpaceKind: String, Codable, CaseIterable, Sendable {
    case personal
    case shared
}

public struct PhotoSpace: Identifiable, Codable, Hashable, Sendable {
    public var id: PhotoSpaceKind { kind }
    public let kind: PhotoSpaceKind
    public let rootPath: String

    public var title: String {
        switch kind {
        case .personal:
            L10n.string("shared.51fcaa8035fc61e2")
        case .shared:
            L10n.string("shared.17d2e16862f16829")
        }
    }

    public init(kind: PhotoSpaceKind, rootPath: String) {
        self.kind = kind
        self.rootPath = rootPath
    }

    public static let personal = PhotoSpace(
        kind: .personal,
        rootPath: "/home/Photos"
    )

    public static let shared = PhotoSpace(
        kind: .shared,
        rootPath: "/photo"
    )
}

public enum PhotoLibraryItemKind: String, Codable, Sendable {
    case folder
    case image
    case video
}

public enum PhotoBrowseMode: String, Codable, CaseIterable, Sendable {
    case timeline
    case albums
}

public enum PhotoMediaFilter: String, Codable, CaseIterable, Sendable {
    case all
    case images
    case videos
}

public struct PhotoLibraryItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let profileID: UUID
    public let name: String
    public let path: String
    public let kind: PhotoLibraryItemKind
    public let sizeBytes: Int64?
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let fileExtension: String?
    public let thumbnailAvailable: Bool?
    public var livePhotoVideoPath: String?

    public init?(_ file: FileItem, livePhotoVideoPath: String? = nil) {
        let itemKind: PhotoLibraryItemKind
        if file.isDirectory {
            itemKind = .folder
        } else {
            switch PreviewKind.classify(file) {
            case .image:
                itemKind = .image
            case .video:
                itemKind = .video
            default:
                return nil
            }
        }

        id = file.id
        profileID = file.profileID
        name = file.name
        path = file.path
        kind = itemKind
        sizeBytes = file.sizeBytes
        createdAt = file.times?.createdAt
        modifiedAt = file.times?.modifiedAt
        fileExtension = file.fileExtension
        thumbnailAvailable = file.thumbnailAvailable
        self.livePhotoVideoPath = livePhotoVideoPath
    }

    public init(
        id: String,
        profileID: UUID,
        name: String,
        path: String,
        kind: PhotoLibraryItemKind,
        sizeBytes: Int64?,
        createdAt: Date?,
        modifiedAt: Date?,
        fileExtension: String?,
        thumbnailAvailable: Bool?,
        livePhotoVideoPath: String? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.name = name
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.fileExtension = fileExtension
        self.thumbnailAvailable = thumbnailAvailable
        self.livePhotoVideoPath = livePhotoVideoPath
    }

    public var isFolder: Bool {
        kind == .folder
    }

    public var isLivePhoto: Bool {
        livePhotoVideoPath != nil
    }

    public var fileItem: FileItem {
        FileItem(
            profileID: profileID,
            name: name,
            path: path,
            kind: isFolder ? .directory : .file,
            sizeBytes: sizeBytes,
            fileExtension: fileExtension,
            times: FileTimes(modifiedAt: modifiedAt, createdAt: createdAt, accessedAt: nil),
            thumbnailAvailable: thumbnailAvailable
        )
    }

    /// 自动匹配同一目录下同名的图片 (.heic/.jpg) 与短视频 (.mov/.mp4) 为动态照片 Live Photo
    /// - Parameter isCancelled: 可选的取消检查闭包，用于大量数据在后台计算时尽早停止。
    public static func pairLivePhotos(
        _ items: [PhotoLibraryItem],
        isCancelled: (@Sendable () -> Bool)? = nil
    ) -> [PhotoLibraryItem] {
        var videosByStem: [String: PhotoLibraryItem] = [:]
        for item in items where item.kind == .video {
            if isCancelled?() == true { return [] }
            let directory = (item.path as NSString).deletingLastPathComponent
            let stem = ((item.name as NSString).deletingPathExtension).lowercased()
            let key = "\(directory)/\(stem)"
            videosByStem[key] = item
        }

        var pairedVideoPaths: Set<String> = []
        var result: [PhotoLibraryItem] = []

        for item in items {
            if isCancelled?() == true { return [] }
            if item.kind == .image {
                let directory = (item.path as NSString).deletingLastPathComponent
                let stem = ((item.name as NSString).deletingPathExtension).lowercased()
                let key = "\(directory)/\(stem)"
                if let videoItem = videosByStem[key] {
                    pairedVideoPaths.insert(videoItem.path)
                    var pairedItem = item
                    pairedItem.livePhotoVideoPath = videoItem.path
                    result.append(pairedItem)
                } else {
                    result.append(item)
                }
            } else if item.kind == .video {
                if !pairedVideoPaths.contains(item.path) {
                    result.append(item)
                }
            } else {
                result.append(item)
            }
        }

        return result.filter { item in
            if item.kind == .video && pairedVideoPaths.contains(item.path) {
                return false
            }
            return true
        }
    }
}

public struct PhotoLibraryPage: Codable, Equatable, Sendable {
    public let folderPath: String
    public let items: [PhotoLibraryItem]
    public let offset: Int
    public let nextOffset: Int
    public let sourceTotal: Int
    public let hasMore: Bool

    public init(
        folderPath: String,
        items: [PhotoLibraryItem],
        offset: Int,
        nextOffset: Int,
        sourceTotal: Int,
        hasMore: Bool
    ) {
        self.folderPath = folderPath
        self.items = items
        self.offset = offset
        self.nextOffset = nextOffset
        self.sourceTotal = sourceTotal
        self.hasMore = hasMore
    }
}

public struct PhotoTimelineScanUpdate: Sendable {
    public let items: [PhotoLibraryItem]
    public let removedPaths: [String]
    public let scannedFolderCount: Int
    public let skippedFolderPaths: [String]

    public init(
        items: [PhotoLibraryItem],
        removedPaths: [String] = [],
        scannedFolderCount: Int,
        skippedFolderPaths: [String] = []
    ) {
        self.items = items
        self.removedPaths = removedPaths
        self.scannedFolderCount = scannedFolderCount
        self.skippedFolderPaths = skippedFolderPaths
    }

    public var skippedFolderCount: Int {
        skippedFolderPaths.count
    }
}

/// 用户主动时间线扫描的硬上限。所有计数都按 File Station 返回的原始项目计算，
/// 避免只按可识别媒体计数而意外扫描完整照片空间。
public struct PhotoTimelineScanLimits: Equatable, Sendable {
    public let maximumFolderCount: Int
    public let maximumSourceItemCount: Int
    public let maximumMediaItemCount: Int
    public let pageSize: Int

    public init(
        maximumFolderCount: Int,
        maximumSourceItemCount: Int,
        maximumMediaItemCount: Int,
        pageSize: Int
    ) {
        self.maximumFolderCount = maximumFolderCount
        self.maximumSourceItemCount = maximumSourceItemCount
        self.maximumMediaItemCount = maximumMediaItemCount
        self.pageSize = pageSize
    }

    public static let mobileDefault = PhotoTimelineScanLimits(
        maximumFolderCount: 2_000,
        maximumSourceItemCount: 50_000,
        maximumMediaItemCount: 10_000,
        pageSize: 200
    )

    /// 旧版无返回值扫描的兼容策略；只保留原有 500 项分页，不引入新的截断语义。
    public static let legacyDefault = PhotoTimelineScanLimits(
        maximumFolderCount: .max,
        maximumSourceItemCount: .max,
        maximumMediaItemCount: .max,
        pageSize: 500
    )
}

public enum PhotoTimelineScanCompletion: String, Codable, Equatable, Sendable {
    case complete
    case truncated
}

public struct PhotoTimelineScanResult: Equatable, Sendable {
    public let items: [PhotoLibraryItem]
    public let scannedFolderCount: Int
    public let skippedFolderPaths: [String]
    public let sourceItemCount: Int
    public let completion: PhotoTimelineScanCompletion

    public init(
        items: [PhotoLibraryItem],
        scannedFolderCount: Int,
        skippedFolderPaths: [String],
        sourceItemCount: Int,
        completion: PhotoTimelineScanCompletion
    ) {
        self.items = items
        self.scannedFolderCount = scannedFolderCount
        self.skippedFolderPaths = skippedFolderPaths
        self.sourceItemCount = sourceItemCount
        self.completion = completion
    }
}

/// 照片基础能力所需的最小官方文件接口，便于与完整文件管理 Repository 解耦测试。
public protocol PhotoFileServing: Sendable {
    func listShares(offset: Int, limit: Int) async throws -> FilePage
    func listFolder(path: String, offset: Int, limit: Int) async throws -> FilePage
    func getThumbnail(path: String, size: ThumbnailSize) async throws -> Data
    func search(folderPath: String, query: String) async throws -> [FileItem]
}

public protocol PhotoLibraryRepository: Sendable {
    func discoverSpaces() async throws -> [PhotoSpace]
    func listFolder(
        in space: PhotoSpace,
        path: String,
        offset: Int,
        limit: Int
    ) async throws -> PhotoLibraryPage
    func getThumbnail(for item: PhotoLibraryItem, size: ThumbnailSize) async throws -> Data
    func scanTimeline(
        in space: PhotoSpace,
        startingAt folderPaths: [String],
        existingFolderItemPaths: [String: [String]],
        onUpdate: @escaping @Sendable (PhotoTimelineScanUpdate) async -> Void
    ) async throws
    func scanTimeline(
        in space: PhotoSpace,
        startingAt folderPaths: [String],
        existingFolderItemPaths: [String: [String]],
        limits: PhotoTimelineScanLimits,
        onUpdate: @escaping @Sendable (PhotoTimelineScanUpdate) async -> Void
    ) async throws -> PhotoTimelineScanResult
}

public extension PhotoLibraryRepository {
    func scanTimeline(
        in space: PhotoSpace,
        startingAt folderPaths: [String],
        existingFolderItemPaths: [String: [String]],
        limits: PhotoTimelineScanLimits,
        onUpdate: @escaping @Sendable (PhotoTimelineScanUpdate) async -> Void
    ) async throws -> PhotoTimelineScanResult {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.7dc6f291445bfb76")
        )
    }

    func scanTimeline(
        in space: PhotoSpace,
        startingAt folderPaths: [String],
        onUpdate: @escaping @Sendable (PhotoTimelineScanUpdate) async -> Void
    ) async throws {
        try await scanTimeline(
            in: space,
            startingAt: folderPaths,
            existingFolderItemPaths: [:],
            onUpdate: onUpdate
        )
    }

    func scanTimeline(
        in space: PhotoSpace,
        onUpdate: @escaping @Sendable (PhotoTimelineScanUpdate) async -> Void
    ) async throws {
        try await scanTimeline(
            in: space,
            startingAt: [space.rootPath],
            existingFolderItemPaths: [:],
            onUpdate: onUpdate
        )
    }

    func scanTimeline(
        in space: PhotoSpace,
        existingFolderItemPaths: [String: [String]],
        onUpdate: @escaping @Sendable (PhotoTimelineScanUpdate) async -> Void
    ) async throws {
        try await scanTimeline(
            in: space,
            startingAt: [space.rootPath],
            existingFolderItemPaths: existingFolderItemPaths,
            onUpdate: onUpdate
        )
    }
}

public struct PhotoTimelineSection: Identifiable, Sendable {
    public let date: Date
    public let items: [PhotoLibraryItem]
    public var id: Date { date }

    public var title: String {
        guard date != .distantPast else {
            return L10n.string("ui.0a680746ce36d7a8")
        }
        return date.formatted(
            Date.FormatStyle(date: .long, time: .omitted)
                .locale(L10n.locale)
        )
    }

    public init(date: Date, items: [PhotoLibraryItem]) {
        self.date = date
        self.items = items
    }
}

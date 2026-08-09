import Foundation
import DsmLocalization

public enum FileKind: String, Codable, Sendable {
    case file
    case directory
    case symlink
    case unknown
}

public struct FileTimes: Codable, Hashable, Sendable {
    public let modifiedAt: Date?
    public let createdAt: Date?
    public let accessedAt: Date?

    public init(modifiedAt: Date?, createdAt: Date?, accessedAt: Date?) {
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.accessedAt = accessedAt
    }
}

public struct FilePermissions: Codable, Hashable, Sendable {
    public let canRead: Bool
    public let canWrite: Bool
    public let canDelete: Bool
    public let posixMode: Int?

    public init(canRead: Bool, canWrite: Bool, canDelete: Bool, posixMode: Int?) {
        self.canRead = canRead
        self.canWrite = canWrite
        self.canDelete = canDelete
        self.posixMode = posixMode
    }
}

public struct FileItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let profileID: UUID
    public let name: String
    public let path: String
    public let kind: FileKind
    public let sizeBytes: Int64?
    public let mimeType: String?
    public let fileExtension: String?
    public let owner: String?
    public let group: String?
    public let times: FileTimes?
    public let permissions: FilePermissions?
    public let thumbnailAvailable: Bool?
    public let isRecyclePath: Bool
    public let rawType: String?
    public let mountPointType: String?

    public init(
        profileID: UUID,
        name: String,
        path: String,
        kind: FileKind,
        sizeBytes: Int64? = nil,
        mimeType: String? = nil,
        fileExtension: String? = nil,
        owner: String? = nil,
        group: String? = nil,
        times: FileTimes? = nil,
        permissions: FilePermissions? = nil,
        thumbnailAvailable: Bool? = nil,
        isRecyclePath: Bool? = nil,
        rawType: String? = nil,
        mountPointType: String? = nil
    ) {
        self.id = "\(profileID.uuidString):\(path)"
        self.profileID = profileID
        self.name = name
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.mimeType = mimeType
        self.fileExtension = fileExtension ?? URL(fileURLWithPath: name).pathExtension.lowercased()
        self.owner = owner
        self.group = group
        self.times = times
        self.permissions = permissions
        self.thumbnailAvailable = thumbnailAvailable
        self.isRecyclePath = isRecyclePath ?? path.split(separator: "/").contains("#recycle")
        self.rawType = rawType
        self.mountPointType = mountPointType
    }

    public var isDirectory: Bool {
        kind == .directory
    }
}

/// 新建或重命名单个文件项后的可审计结果。只有独立回读确认目标状态时才携带 `item`。
public struct FileItemMutationOutcome: Equatable, Sendable {
    public let result: MutationResult
    public let item: FileItem?

    public init(result: MutationResult, item: FileItem?) {
        self.result = result
        self.item = item
    }
}

/// 单个普通本地文件在同一 NAS 内复制或移动的操作类型。
public enum FileCopyMoveOperation: String, Codable, Sendable {
    case copy
    case move
}

/// 单个普通本地文件的有界复制或移动请求；首版明确不允许覆盖目标。
public struct FileCopyMoveRequest: Equatable, Sendable {
    public let profileID: UUID
    public let operation: FileCopyMoveOperation
    public let source: FileItem
    public let destinationFolderPath: String
    public let overwrite: Bool

    public init(
        profileID: UUID,
        operation: FileCopyMoveOperation,
        source: FileItem,
        destinationFolderPath: String,
        overwrite: Bool
    ) {
        self.profileID = profileID
        self.operation = operation
        self.source = source
        self.destinationFolderPath = destinationFolderPath
        self.overwrite = overwrite
    }
}

/// 复制或移动后的可审计结果。只有独立回读确认目标状态时才携带 `item`。
public struct FileCopyMoveOutcome: Equatable, Sendable {
    public let result: MutationResult
    public let sourcePath: String
    public let destinationPath: String
    public let item: FileItem?

    public init(
        result: MutationResult,
        sourcePath: String,
        destinationPath: String,
        item: FileItem?
    ) {
        self.result = result
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.item = item
    }
}

/// 将单个普通本地文件移入已发现回收站的请求；首版不接受目录、远程挂载或覆盖语义。
public struct FileMoveToRecycleRequest: Equatable, Sendable {
    public let profileID: UUID
    public let item: FileItem
    public let recycleLocation: FileRecycleLocation

    public init(
        profileID: UUID,
        item: FileItem,
        recycleLocation: FileRecycleLocation
    ) {
        self.profileID = profileID
        self.item = item
        self.recycleLocation = recycleLocation
    }
}

/// 从 `#recycle` 恢复单个普通文件的请求；目标路径由回收站路径严格反推。
public struct FileRestoreFromRecycleRequest: Equatable, Sendable {
    public let profileID: UUID
    public let item: FileItem

    public init(profileID: UUID, item: FileItem) {
        self.profileID = profileID
        self.item = item
    }
}

/// 回收站写操作的可审计结果。只有独立回读确认目标状态时才携带 `item`。
public struct FileRecycleMutationOutcome: Equatable, Sendable {
    public let result: MutationResult
    public let sourcePath: String
    public let destinationPath: String
    public let item: FileItem?

    public init(
        result: MutationResult,
        sourcePath: String,
        destinationPath: String,
        item: FileItem?
    ) {
        self.result = result
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.item = item
    }
}

/// File Station 官方虚拟文件夹接口支持的远程协议。
public enum FileVirtualProtocol: String, Codable, CaseIterable, Sendable {
    case cifs
    case nfs
    case iso

    /// ISO 映像由系统以只读方式挂载，不能使用远程连接管理接口修改或移除。
    public var supportsManagement: Bool {
        self != .iso
    }
}

/// 已识别协议的远程虚拟文件夹。
public struct FileVirtualFolder: Identifiable, Hashable, Sendable {
    public var id: String { "\(protocolType.rawValue):\(item.id)" }
    public let item: FileItem
    public let protocolType: FileVirtualProtocol

    public init(item: FileItem, protocolType: FileVirtualProtocol) {
        self.item = item
        self.protocolType = protocolType
    }
}

/// 远程虚拟文件夹分页结果；部分协议读取失败时仍返回其他可用协议。
public struct FileVirtualFolderPage: Equatable, Sendable {
    public let folders: [FileVirtualFolder]
    public let offset: Int
    public let total: Int
    public let hasMore: Bool
    public let isTruncated: Bool
    public let unavailableProtocols: [FileVirtualProtocol]

    public init(
        folders: [FileVirtualFolder],
        offset: Int,
        total: Int,
        hasMore: Bool,
        isTruncated: Bool = false,
        unavailableProtocols: [FileVirtualProtocol] = []
    ) {
        self.folders = folders
        self.offset = offset
        self.total = total
        self.hasMore = hasMore
        self.isTruncated = isTruncated
        self.unavailableProtocols = unavailableProtocols
    }
}

public struct FavoriteLocation: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// 收藏位置的有界规范化分页。`sourceTotal` 是服务端稳定报告的原始数量；
/// 服务端未报告总数时，它是本次实际消费的原始数量。`total` 是最多 5,000 条
/// 原始记录经路径规范化和去重后的可浏览数量。
public struct FileFavoritePage: Equatable, Sendable {
    public let locations: [FavoriteLocation]
    public let offset: Int
    public let nextOffset: Int
    public let total: Int
    public let sourceTotal: Int
    public let hasMore: Bool
    public let isTruncated: Bool

    public init(
        locations: [FavoriteLocation],
        offset: Int,
        nextOffset: Int,
        total: Int,
        sourceTotal: Int,
        hasMore: Bool,
        isTruncated: Bool
    ) {
        self.locations = locations
        self.offset = offset
        self.nextOffset = nextOffset
        self.total = total
        self.sourceTotal = sourceTotal
        self.hasMore = hasMore
        self.isTruncated = isTruncated
    }
}

/// 当前账号可见共享目录下的只读回收站入口。
public struct FileRecycleLocation: Equatable, Hashable, Sendable {
    public let shareName: String
    public let sharePath: String
    public let recyclePath: String

    public init(shareName: String, sharePath: String, recyclePath: String) {
        self.shareName = shareName
        self.sharePath = sharePath
        self.recyclePath = recyclePath
    }
}

/// 回收站发现结果只描述入口，不授予恢复、删除或清空能力。
public struct FileRecycleDiscoveryResult: Equatable, Sendable {
    public let profileID: UUID
    public let locations: [FileRecycleLocation]
    public let scannedShareCount: Int
    public let permissionDeniedShareCount: Int
    public let isTruncated: Bool

    public init(
        profileID: UUID,
        locations: [FileRecycleLocation],
        scannedShareCount: Int,
        permissionDeniedShareCount: Int,
        isTruncated: Bool
    ) {
        self.profileID = profileID
        self.locations = locations
        self.scannedShareCount = scannedShareCount
        self.permissionDeniedShareCount = permissionDeniedShareCount
        self.isTruncated = isTruncated
    }
}

public struct FileShareLink: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let url: String
    public let hasPassword: Bool
    public let expiresAt: String?

    public init(
        id: String,
        name: String,
        path: String,
        url: String,
        hasPassword: Bool = false,
        expiresAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.url = url
        self.hasPassword = hasPassword
        self.expiresAt = expiresAt
    }
}

public enum FileShareLinkAvailabilityStatus: String, Codable, Hashable, Sendable {
    case available
    case unsupported
}

public struct FileShareLinkAvailability: Codable, Hashable, Sendable {
    public let status: FileShareLinkAvailabilityStatus
    public let resolvedVersion: Int?

    public init(status: FileShareLinkAvailabilityStatus, resolvedVersion: Int?) {
        self.status = status
        self.resolvedVersion = resolvedVersion
    }

    public static let unsupported = FileShareLinkAvailability(
        status: .unsupported,
        resolvedVersion: nil
    )
}

public enum FileShareLinkContractError: Error, Equatable, Sendable {
    case invalidDate
    case invalidTarget
    case invalidPassword
    case invalidDateRange
}

/// 分享链接日期使用无时区的公历年月日，网络层只按 `yyyy-MM-dd` 发送。
public struct FileShareLinkCalendarDate: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else {
            throw FileShareLinkContractError.invalidDate
        }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else {
            throw FileShareLinkContractError.invalidDate
        }
        self.year = year
        self.month = month
        self.day = day
    }

    public init(iso8601 value: String) throws {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            throw FileShareLinkContractError.invalidDate
        }
        try self.init(year: year, month: month, day: day)
    }

    public var iso8601: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// 密码仅在当前创建请求内存中使用，因此该类型刻意不遵循 Codable。
public struct FileShareLinkCreateRequest: Sendable {
    public let target: FileItem
    public let password: String?
    public let availableOn: FileShareLinkCalendarDate?
    public let expiresOn: FileShareLinkCalendarDate?

    public init(
        target: FileItem,
        password: String? = nil,
        availableOn: FileShareLinkCalendarDate? = nil,
        expiresOn: FileShareLinkCalendarDate? = nil
    ) throws {
        let normalizedPassword = password?.isEmpty == false ? password : nil
        guard target.path.hasPrefix("/"), target.path != "/" else {
            throw FileShareLinkContractError.invalidTarget
        }
        guard normalizedPassword?.count ?? 0 <= 16 else {
            throw FileShareLinkContractError.invalidPassword
        }
        if let availableOn, let expiresOn, expiresOn < availableOn {
            throw FileShareLinkContractError.invalidDateRange
        }
        self.target = target
        self.password = normalizedPassword
        self.availableOn = availableOn
        self.expiresOn = expiresOn
    }
}

public struct FileShareLinkPage: Codable, Equatable, Sendable {
    public let links: [FileShareLink]
    public let offset: Int
    public let total: Int
    public let hasMore: Bool
    public let isTruncated: Bool

    public init(
        links: [FileShareLink],
        offset: Int,
        total: Int,
        hasMore: Bool,
        isTruncated: Bool = false
    ) {
        self.links = links
        self.offset = offset
        self.total = total
        self.hasMore = hasMore
        self.isTruncated = isTruncated
    }
}

public struct FileShareLinkCreateOutcome: Sendable, Equatable {
    public let result: MutationResult
    public let confirmedLink: FileShareLink?

    public init(result: MutationResult, confirmedLink: FileShareLink? = nil) {
        self.result = result
        self.confirmedLink = confirmedLink
    }
}

/// 当前账号通过 File Station 可见的存储空间汇总，不代表管理员看到的物理硬盘容量。
public struct StorageSpaceSummary: Codable, Hashable, Sendable {
    public let totalBytes: Int64
    public let remainingBytes: Int64
    public let volumeCount: Int

    public init(totalBytes: Int64, remainingBytes: Int64, volumeCount: Int) {
        self.totalBytes = max(totalBytes, 0)
        self.remainingBytes = min(max(remainingBytes, 0), max(totalBytes, 0))
        self.volumeCount = max(volumeCount, 0)
    }

    public var usedBytes: Int64 {
        max(totalBytes - remainingBytes, 0)
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }
}

public enum RemoteMountProtocol: String, Codable, CaseIterable, Sendable {
    case smb = "cifs"
    case nfs
}

/// 挂载密码只在当前请求内存中使用，不得编码、记录或持久化。
public struct RemoteMountConfiguration: Sendable, Equatable {
    public let protocolType: RemoteMountProtocol
    public let server: String
    public let remotePath: String
    public let mountPoint: String
    public let username: String
    public let password: String
    public let domain: String
    public let readOnly: Bool

    public init(
        protocolType: RemoteMountProtocol,
        server: String,
        remotePath: String,
        mountPoint: String,
        username: String = "",
        password: String = "",
        domain: String = "",
        readOnly: Bool = false
    ) {
        self.protocolType = protocolType
        self.server = server
        self.remotePath = remotePath
        self.mountPoint = mountPoint
        self.username = username
        self.password = password
        self.domain = domain
        self.readOnly = readOnly
    }
}

public struct FilePage: Codable, Equatable, Sendable {
    public let folderPath: String
    public let items: [FileItem]
    public let offset: Int
    public let total: Int
    public let hasMore: Bool
    public let loadedAt: Date

    public init(
        folderPath: String,
        items: [FileItem],
        offset: Int,
        total: Int,
        hasMore: Bool,
        loadedAt: Date = Date()
    ) {
        self.folderPath = folderPath
        self.items = items
        self.offset = offset
        self.total = total
        self.hasMore = hasMore
        self.loadedAt = loadedAt
    }
}

/// File Station 目录列表使用的稳定排序字段。
///
/// 展示文案与公开 API 参数由各平台和网络层分别映射，不能使用本地化字符串参与请求。
public enum FileListSortField: String, Codable, Hashable, Sendable {
    case name
    case size
    case modifiedTime
}

public enum FileListSortDirection: String, Codable, Hashable, Sendable {
    case ascending
    case descending
}

public enum FileListTypeFilter: String, Codable, Hashable, Sendable {
    case all
    case files
    case folders
}

/// 单次目录分页请求的排序与类型筛选；同一分页序列必须始终使用同一组选项。
public struct FileListOptions: Codable, Equatable, Hashable, Sendable {
    public let sortField: FileListSortField
    public let sortDirection: FileListSortDirection
    public let typeFilter: FileListTypeFilter

    public init(
        sortField: FileListSortField = .name,
        sortDirection: FileListSortDirection = .ascending,
        typeFilter: FileListTypeFilter = .all
    ) {
        self.sortField = sortField
        self.sortDirection = sortDirection
        self.typeFilter = typeFilter
    }

    public static let `default` = FileListOptions()
}

public enum ThumbnailSize: String, Codable, Sendable {
    case small
    case medium
    case large
}

public enum PreviewKind: String, Codable, Sendable {
    case image
    case pdf
    case text
    case video
    case audio
    case unsupported

    public static func classify(_ item: FileItem) -> PreviewKind {
        let ext = item.fileExtension?.lowercased() ?? ""
        if ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"].contains(ext) {
            return .image
        }
        if ext == "pdf" {
            return .pdf
        }
        if [
            "txt", "md", "markdown", "json", "xml", "yaml", "yml", "log", "csv", "tsv",
            "swift", "kt", "kts", "java", "cs", "js", "tsx", "jsx", "html", "css",
            "py", "rb", "go", "rs", "sh", "zsh", "ini", "conf", "toml"
        ].contains(ext) {
            return .text
        }
        if ext == "ts" {
            // `.ts` 同时可能是 TypeScript 或 MPEG 传输流；这里只采信服务端明确类型，
            // 未知时由预览流程读取文件头判断，不能用文件大小猜测。
            if item.mimeType?.lowercased().hasPrefix("video/") == true {
                return .video
            }
            return .text
        }
        if ["mp4", "mkv", "mov", "avi", "flv", "webm", "m4v", "3gp", "mts", "m2ts"].contains(ext) {
            return .video
        }
        if ["mp3", "wav", "m4a", "aac", "flac", "ogg", "wma"].contains(ext) {
            return .audio
        }
        return .unsupported
    }
}

public enum FileContentSniffer {
    /// 根据文件头区分 MPEG 传输流与文本。传输流包以 0x47 同步字节按固定间隔重复。
    public static func classifyTypeScriptOrTransportStream(_ data: Data) -> PreviewKind {
        guard !data.isEmpty else { return .text }
        let bytes = [UInt8](data)
        for packetSize in [188, 192, 204] {
            let maximumOffset = min(packetSize, 16)
            for offset in 0..<maximumOffset {
                var matches = 0
                var index = offset
                while index < bytes.count, matches < 4 {
                    guard bytes[index] == 0x47 else { break }
                    matches += 1
                    index += packetSize
                }
                if matches >= 3 { return .video }
            }
        }
        return .text
    }
}

public struct RecycleLocation: Equatable, Sendable {
    public let recycleRoot: String
    public let relativePath: String
    public let originalPath: String
    public let originalParentPath: String

    public init?(recyclePath: String) {
        let normalized = recyclePath.hasPrefix("/") ? recyclePath : "/\(recyclePath)"
        let components = normalized.split(separator: "/").map(String.init)
        guard let recycleIndex = components.firstIndex(of: "#recycle"),
              recycleIndex == 1,
              components.count > recycleIndex + 1 else {
            return nil
        }

        let share = components[0]
        let tail = components.dropFirst(recycleIndex + 1)
        recycleRoot = "/\(share)/#recycle"
        relativePath = "/" + tail.joined(separator: "/")
        originalPath = "/\(share)/" + tail.joined(separator: "/")
        originalParentPath = URL(fileURLWithPath: originalPath).deletingLastPathComponent().path
    }
}

public typealias FileTransferProgress = @Sendable (_ completedBytes: Int64, _ totalBytes: Int64?) -> Void

/// NAS 上由 File Station 执行的只读后台任务摘要。
///
/// 该模型刻意不包含任务参数、文件路径或当前处理路径，避免把服务端可能回显的敏感信息
/// 带入持久化、日志或用户界面。
public struct FileBackgroundTaskSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: FileBackgroundTaskKind
    public let state: FileBackgroundTaskState
    public let progress: Double?
    public let createdAt: Date?
    public let processedItemCount: Int?
    public let totalItemCount: Int?
    public let processedBytes: Int64?
    public let totalBytes: Int64?

    public init(
        id: String,
        kind: FileBackgroundTaskKind,
        state: FileBackgroundTaskState,
        progress: Double?,
        createdAt: Date?,
        processedItemCount: Int?,
        totalItemCount: Int?,
        processedBytes: Int64?,
        totalBytes: Int64?
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.progress = progress
        self.createdAt = createdAt
        self.processedItemCount = processedItemCount
        self.totalItemCount = totalItemCount
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
    }
}

public enum FileBackgroundTaskKind: Equatable, Sendable {
    case copyOrMove
    case delete
    case compress
    case extract
}

public enum FileBackgroundTaskState: Equatable, Sendable {
    case active
    /// 官方字段只表示任务已经结束，不代表任务成功。
    case finished
}

public struct FileBackgroundTaskPage: Equatable, Sendable {
    public let tasks: [FileBackgroundTaskSummary]
    public let offset: Int
    public let nextOffset: Int
    public let total: Int
    public let hasMore: Bool

    public init(
        tasks: [FileBackgroundTaskSummary],
        offset: Int,
        nextOffset: Int,
        total: Int,
        hasMore: Bool
    ) {
        self.tasks = tasks
        self.offset = offset
        self.nextOffset = nextOffset
        self.total = total
        self.hasMore = hasMore
    }
}

/// NAS 完成目录大小计算后返回的聚合结果。
///
/// 输入路径和服务端任务标识只在 Repository 内部短暂使用，不进入领域结果。
public struct FileDirectorySizeSummary: Equatable, Sendable {
    public let totalBytes: Int64
    public let fileCount: Int
    public let directoryCount: Int

    public init(totalBytes: Int64, fileCount: Int, directoryCount: Int) {
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
    }
}

/// 只在内存中交给媒体播放器使用。请求头可能包含短期会话信息，不得记录或持久化。
public struct MediaStreamSource: @unchecked Sendable {
    public let request: URLRequest
    public let fileExtension: String?
    public let expectedContentLength: Int64?
    public let expectedHost: String
    public let pinnedCertificateSHA256: String?

    public init(
        request: URLRequest,
        fileExtension: String?,
        expectedContentLength: Int64?,
        expectedHost: String,
        pinnedCertificateSHA256: String?
    ) {
        self.request = request
        self.fileExtension = fileExtension
        self.expectedContentLength = expectedContentLength
        self.expectedHost = expectedHost
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
    }
}

public protocol FileRepository: PhotoFileServing, Sendable {
    var profileID: UUID { get }
    var allowsVerifiedRestore: Bool { get }
    var allowsRemoteMountManagement: Bool { get }
    var fileShareLinkAvailability: FileShareLinkAvailability { get }

    func listShares(offset: Int, limit: Int) async throws -> FilePage
    func listBackgroundTasks(offset: Int, limit: Int) async throws -> FileBackgroundTaskPage
    func calculateDirectorySize(path: String) async throws -> FileDirectorySizeSummary
    func listVirtualFolders(offset: Int, limit: Int) async throws -> FileVirtualFolderPage
    func listRemoteMounts(offset: Int, limit: Int) async throws -> FilePage
    func listFolder(path: String, offset: Int, limit: Int) async throws -> FilePage
    func getInfo(paths: [String]) async throws -> [FileItem]
    func getThumbnail(path: String, size: ThumbnailSize) async throws -> Data
    func readPrefix(remotePath: String, maximumLength: Int) async throws -> Data
    func checkWritePermission(folderPath: String, filename: String, createOnly: Bool) async throws
    func mediaStreamSource(
        remotePath: String,
        fileExtension: String?,
        expectedContentLength: Int64?
    ) async throws -> MediaStreamSource
    func download(
        remotePath: String,
        to localURL: URL,
        expectedSize: Int64?,
        progress: @escaping FileTransferProgress
    ) async throws
    func downloadArchive(
        remotePaths: [String],
        to localURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws
    func removePartialDownload(to localURL: URL) async
    func upload(
        localURL: URL,
        to folderPath: String,
        overwrite: Bool,
        progress: @escaping FileTransferProgress
    ) async throws
    func delete(paths: [String], progress: @escaping FileTransferProgress) async throws
    func deleteResult(
        paths: [String],
        progress: @escaping FileTransferProgress
    ) async throws -> MutationResult
    func createFolder(parentPath: String, name: String) async throws
    func createFolderResult(parentPath: String, name: String) async throws -> FileItemMutationOutcome
    func rename(path: String, newName: String) async throws
    func renameResult(path: String, newName: String) async throws -> FileItemMutationOutcome
    func copy(
        paths: [String],
        to destinationFolder: String,
        overwrite: Bool,
        progress: @escaping FileTransferProgress
    ) async throws
    func move(
        paths: [String],
        to destinationFolder: String,
        overwrite: Bool,
        progress: @escaping FileTransferProgress
    ) async throws
    func copyMoveResult(
        _ request: FileCopyMoveRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileCopyMoveOutcome
    func moveToRecycleResult(
        _ request: FileMoveToRecycleRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileRecycleMutationOutcome
    func restoreFromRecycleResult(
        _ request: FileRestoreFromRecycleRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileRecycleMutationOutcome
    func compress(
        paths: [String],
        destinationFilePath: String,
        format: ArchiveFormat,
        level: ArchiveCompressionLevel,
        password: String?,
        progress: @escaping FileTransferProgress
    ) async throws
    func extract(
        filePath: String,
        destinationFolder: String,
        overwrite: Bool,
        keepDirectoryStructure: Bool,
        createSubfolder: Bool,
        codepage: String?,
        password: String?,
        progress: @escaping FileTransferProgress
    ) async throws
    func listArchiveItems(filePath: String, codepage: String?, password: String?) async throws -> [ArchiveItem]
    func search(folderPath: String, query: String) async throws -> [FileItem]
    /// 使用 File Station 官方接口计算远程文件校验值。该操作只读，但大文件可能耗时较长。
    func fileMD5(remotePath: String) async throws -> String
    func listFavorites() async throws -> [FavoriteLocation]
    func listFavoritesPage(offset: Int, limit: Int) async throws -> FileFavoritePage
    func discoverRecycleLocations() async throws -> FileRecycleDiscoveryResult
    func addFavorite(path: String, name: String) async throws
    func addFavoriteResult(path: String, name: String) async throws -> MutationResult
    func removeFavorite(path: String) async throws
    func listShareLinks() async throws -> [FileShareLink]
    func listShareLinksPage(offset: Int, limit: Int) async throws -> FileShareLinkPage
    func createShareLinkResult(
        _ request: FileShareLinkCreateRequest
    ) async throws -> FileShareLinkCreateOutcome
    func createShareLink(paths: [String], password: String?, expiresAt: String?) async throws -> FileShareLink
    func deleteShareLinks(ids: [String]) async throws
    func storageSpaceSummary() async throws -> StorageSpaceSummary?
    func createRemoteMount(_ configuration: RemoteMountConfiguration) async throws
    func updateRemoteMount(
        existingMountPoint: String,
        configuration: RemoteMountConfiguration
    ) async throws
    func removeRemoteMount(mountPoint: String) async throws
}

public extension FileRepository {
    var allowsRemoteMountManagement: Bool { false }
    var fileShareLinkAvailability: FileShareLinkAvailability { .unsupported }

    /// 兼容尚未实现严格分页的既有 Repository；生产网络 Repository 会覆盖此实现。
    func listFavoritesPage(offset: Int, limit: Int) async throws -> FileFavoritePage {
        let snapshotLimit = 5_000
        let requestedOffset = min(max(0, offset), snapshotLimit)
        let requestedLimit = min(max(1, limit), snapshotLimit - requestedOffset)
        let raw = try await listFavorites()
        var seenPaths = Set<String>()
        let all = raw.filter { seenPaths.insert($0.path).inserted }
        let bounded = Array(all.prefix(snapshotLimit))
        let start = min(requestedOffset, bounded.count)
        let end = min(start + requestedLimit, bounded.count)
        return FileFavoritePage(
            locations: Array(bounded[start..<end]),
            offset: start,
            nextOffset: end,
            total: bounded.count,
            sourceTotal: raw.count,
            hasMore: end < bounded.count,
            isTruncated: raw.count > snapshotLimit
        )
    }

    func discoverRecycleLocations() async throws -> FileRecycleDiscoveryResult {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.7dc6f291445bfb76")
        )
    }

    func listShareLinksPage(offset: Int, limit: Int) async throws -> FileShareLinkPage {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.7dc6f291445bfb76")
        )
    }

    func createShareLinkResult(
        _ request: FileShareLinkCreateRequest
    ) async throws -> FileShareLinkCreateOutcome {
        FileShareLinkCreateOutcome(
            result: try MutationResult(
                status: .unsupported,
                operation: "shareLinkCreate",
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                diagnosticTag: "file-station.share-link.unsupported"
            )
        )
    }

    func listVirtualFolders(offset: Int, limit: Int) async throws -> FileVirtualFolderPage {
        let page = try await listRemoteMounts(offset: offset, limit: limit)
        let folders = page.items.compactMap { item -> FileVirtualFolder? in
            guard let rawValue = item.mountPointType?.lowercased(),
                  let protocolType = FileVirtualProtocol(rawValue: rawValue) else {
                return nil
            }
            return FileVirtualFolder(item: item, protocolType: protocolType)
        }
        return FileVirtualFolderPage(
            folders: folders,
            offset: page.offset,
            total: folders.count,
            hasMore: page.hasMore
        )
    }

    func listRemoteMounts(offset: Int, limit: Int) async throws -> FilePage {
        FilePage(folderPath: "/", items: [], offset: offset, total: 0, hasMore: false)
    }

    func listBackgroundTasks(offset: Int, limit: Int) async throws -> FileBackgroundTaskPage {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.7dc6f291445bfb76")
        )
    }

    func calculateDirectorySize(path: String) async throws -> FileDirectorySizeSummary {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.7dc6f291445bfb76")
        )
    }

    func readPrefix(remotePath: String, maximumLength: Int) async throws -> Data {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.3350074ec48130fc")
        )
    }

    func fileMD5(remotePath: String) async throws -> String {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.f9672d024946937d")
        )
    }

    func rename(path: String, newName: String) async throws {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.fac438462e2f0a41")
        )
    }

    func createFolderResult(
        parentPath: String,
        name: String
    ) async throws -> FileItemMutationOutcome {
        FileItemMutationOutcome(
            result: try MutationResult(
                status: .unsupported,
                operation: "createFolder",
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                diagnosticTag: "file-station.create-folder.unsupported"
            ),
            item: nil
        )
    }

    func renameResult(
        path: String,
        newName: String
    ) async throws -> FileItemMutationOutcome {
        FileItemMutationOutcome(
            result: try MutationResult(
                status: .unsupported,
                operation: "rename",
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                diagnosticTag: "file-station.rename.unsupported"
            ),
            item: nil
        )
    }

    func copyMoveResult(
        _ request: FileCopyMoveRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileCopyMoveOutcome {
        let separator = request.destinationFolderPath == "/" ? "" : "/"
        return FileCopyMoveOutcome(
            result: try MutationResult(
                status: .unsupported,
                operation: request.operation.rawValue,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                diagnosticTag: "file-station.copy-move.unsupported"
            ),
            sourcePath: request.source.path,
            destinationPath: request.destinationFolderPath + separator + request.source.name,
            item: nil
        )
    }

    func moveToRecycleResult(
        _ request: FileMoveToRecycleRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileRecycleMutationOutcome {
        let destinationPath = request.recycleLocation.recyclePath + "/" + request.item.name
        return FileRecycleMutationOutcome(
            result: try MutationResult(
                status: .unsupported,
                operation: "moveToRecycle",
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                diagnosticTag: "file-station.recycle.move.unsupported"
            ),
            sourcePath: request.item.path,
            destinationPath: destinationPath,
            item: nil
        )
    }

    func restoreFromRecycleResult(
        _ request: FileRestoreFromRecycleRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileRecycleMutationOutcome {
        let destinationPath = RecycleLocation(recyclePath: request.item.path)?.originalPath
            ?? request.item.path
        return FileRecycleMutationOutcome(
            result: try MutationResult(
                status: .unsupported,
                operation: "restoreFromRecycle",
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                diagnosticTag: "file-station.recycle.restore.unsupported"
            ),
            sourcePath: request.item.path,
            destinationPath: destinationPath,
            item: nil
        )
    }

    func compress(
        paths: [String],
        destinationFilePath: String,
        format: ArchiveFormat,
        level: ArchiveCompressionLevel,
        password: String?,
        progress: @escaping FileTransferProgress
    ) async throws {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.ac6ef8446266ccf7")
        )
    }

    func extract(
        filePath: String,
        destinationFolder: String,
        overwrite: Bool,
        keepDirectoryStructure: Bool,
        createSubfolder: Bool,
        codepage: String?,
        password: String?,
        progress: @escaping FileTransferProgress
    ) async throws {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.f124b9115a6e0be4")
        )
    }

    func listArchiveItems(filePath: String, codepage: String?, password: String?) async throws -> [ArchiveItem] {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.a94bf064d8799444")
        )
    }

    func storageSpaceSummary() async throws -> StorageSpaceSummary? { nil }

    func createRemoteMount(_ configuration: RemoteMountConfiguration) async throws {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.cb48bca536580be8")
        )
    }

    func updateRemoteMount(
        existingMountPoint: String,
        configuration: RemoteMountConfiguration
    ) async throws {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.6745ef07c779b7e4")
        )
    }

    func removeRemoteMount(mountPoint: String) async throws {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.b43c378e71c2c62f")
        )
    }
}

public actor FileStationShareAccessRepository: NasShareAccessRepository {
    private let repository: any FileRepository

    public init(repository: any FileRepository) {
        self.repository = repository
    }

    public func loadShareAccess() async throws -> NasShareAccessDirectory {
        var entriesByID: [String: NasShareAccessEntry] = [:]
        var offset = 0

        repeat {
            let page = try await repository.listShares(offset: offset, limit: 200)
            for item in page.items where isLocalShare(item) {
                let accessLevel: NasShareAccessLevel
                if let permissions = item.permissions {
                    if permissions.canWrite {
                        accessLevel = .readWrite
                    } else if permissions.canRead {
                        accessLevel = .readOnly
                    } else {
                        // `list_share` 只证明条目对当前账号可见，不能把缺少权限位解释为拒绝访问。
                        accessLevel = .unknown
                    }
                } else {
                    accessLevel = .unknown
                }
                entriesByID[item.id] = NasShareAccessEntry(
                    id: item.id,
                    name: item.name,
                    accessLevel: accessLevel,
                    canDelete: item.permissions?.canDelete == true
                )
            }

            guard page.hasMore, !page.items.isEmpty else { break }
            offset = max(offset + page.items.count, page.offset + page.items.count)
        } while true

        let shares = entriesByID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return NasShareAccessDirectory(shares: shares)
    }

    private func isLocalShare(_ item: FileItem) -> Bool {
        guard !item.isRecyclePath else { return false }
        guard let mountType = item.mountPointType?.lowercased(), !mountType.isEmpty else {
            return true
        }
        return mountType == "normal"
    }
}

public struct ArchiveItem: Sendable, Equatable {
    public let id: Int
    public let name: String
    public let path: String
    public let isDirectory: Bool

    public init(id: Int, name: String, path: String, isDirectory: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }
}

public enum ArchiveFormat: String, Codable, CaseIterable, Sendable {
    case zip
    case sevenZip = "7z"
}

public enum ArchiveCompressionLevel: String, Codable, CaseIterable, Sendable {
    case moderate
    case store
    case fastest
    case best
}

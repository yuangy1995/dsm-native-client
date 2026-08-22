import DsmCore
import CryptoKit
import Foundation
import DsmLocalization

/// 可恢复下载只保存与当前远端内容版本绑定的最小元数据。远端路径和 profile
/// 不会以明文写入 sidecar，避免临时文件额外暴露用户的目录信息。
struct DownloadResumeMetadata: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let identityDigest: String
    let expectedSize: Int64
    let contentVersion: DownloadContentVersion

    init(
        identityDigest: String,
        expectedSize: Int64,
        contentVersion: DownloadContentVersion
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.identityDigest = identityDigest
        self.expectedSize = expectedSize
        self.contentVersion = contentVersion
    }

    func matches(identityDigest: String, expectedSize: Int64) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && self.identityDigest == identityDigest
            && self.expectedSize == expectedSize
    }
}

/// 用于 If-Range 的远端内容版本。ETag 必须是强校验器；没有强 ETag 时才使用
/// Last-Modified。每个 206 响应都必须返回完全一致的一组字段，避免拼接不同版本。
struct DownloadContentVersion: Codable, Equatable {
    let etag: String?
    let lastModified: String?

    init?(headers: [String: String]) {
        let etag = Self.strongETag(
            Self.headerValue(named: "etag", in: headers)
        )
        let lastModified = Self.httpLastModified(
            Self.headerValue(named: "last-modified", in: headers)
        )
        guard etag != nil || lastModified != nil else {
            return nil
        }
        self.etag = etag
        self.lastModified = lastModified
    }

    var ifRangeValue: String {
        // 构造器已确保至少有一个可用校验器。
        etag ?? lastModified!
    }

    private static func headerValue(
        named name: String,
        in headers: [String: String]
    ) -> String? {
        let normalizedName = name.lowercased()
        return headers.first {
            $0.key.lowercased() == normalizedName
        }?.value
    }

    private static func strongETag(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
            value.count >= 2,
            !value.lowercased().hasPrefix("w/"),
            value.first == "\"",
            value.last == "\"" else {
            return nil
        }
        return value
    }

    private static func httpLastModified(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else {
            return nil
        }
        // HTTP-date 的标准 IMF-fixdate 形态。无效日期不能作为 If-Range 条件，
        // 否则服务端可能静默忽略该条件并让旧分片继续拼接。
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        guard formatter.date(from: value) != nil else {
            return nil
        }
        return value
    }
}

private struct DownloadContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64

    init?(_ rawValue: String?) {
        guard let rawValue = rawValue?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) else {
            return nil
        }
        let components = rawValue.split(
            maxSplits: 1,
            whereSeparator: { $0.isWhitespace }
        )
        guard components.count == 2,
              components[0].lowercased() == "bytes" else {
            return nil
        }
        let rangeAndTotal = components[1].split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2,
              let total = Int64(rangeAndTotal[1]),
              total > 0 else {
            return nil
        }
        let bounds = rangeAndTotal[0].split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start else {
            return nil
        }
        self.start = start
        self.end = end
        self.total = total
    }
}

private enum DownloadResumeValidationError: Error {
    case invalidCheckpointOrRange
}

private struct FileListPayload: Decodable, Sendable {
    let offset: Int?
    let total: Int?
    let containsOffset: Bool
    let containsTotal: Bool
    let files: [FilePayload]?
    let shares: [FilePayload]?
    let folders: [FilePayload]?

    private enum CodingKeys: String, CodingKey {
        case offset, total, files, shares, folders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        containsOffset = container.contains(.offset)
        containsTotal = container.contains(.total)
        offset = Self.decodeInteger(from: container, key: .offset)
        total = Self.decodeInteger(from: container, key: .total)
        files = try container.decodeIfPresent([FilePayload].self, forKey: .files)
        shares = try container.decodeIfPresent([FilePayload].self, forKey: .shares)
        folders = try container.decodeIfPresent([FilePayload].self, forKey: .folders)
    }

    private static func decodeInteger(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let value = try? container.decode(String.self, forKey: key) { return Int(value) }
        return nil
    }

}

/// 只声明界面实际需要的白名单字段。官方响应中的 `params`、`path` 和
/// `processing_path` 可能包含路径或密码，必须在解码边界直接丢弃。
private struct BackgroundTaskListPayload: Decodable, Sendable {
    let offset: Int?
    let total: Int?
    let tasks: [BackgroundTaskPayload]?

    private enum CodingKeys: String, CodingKey {
        case offset, total, tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offset = Self.decodeInteger(from: container, key: .offset)
        total = Self.decodeInteger(from: container, key: .total)
        tasks = try? container.decodeIfPresent([BackgroundTaskPayload].self, forKey: .tasks)
    }

    private static func decodeInteger(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let value = try? container.decode(String.self, forKey: key) { return Int(value) }
        return nil
    }
}

private struct BackgroundTaskPayload: Decodable, Sendable {
    let api: String?
    let taskID: String?
    let finished: Bool?
    let progress: Double?
    let creationTime: Double?
    let processedItemCount: Int64?
    let processedBytes: Int64?
    let total: Int64?

    private enum CodingKeys: String, CodingKey {
        case api
        case taskID = "taskid"
        case finished
        case progress
        case creationTime = "crtime"
        case processedItemCount = "processed_num"
        case processedBytes = "processed_size"
        case total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        api = try? container.decodeIfPresent(String.self, forKey: .api)
        taskID = try? container.decodeIfPresent(String.self, forKey: .taskID)
        finished = Self.decodeBool(from: container, key: .finished)
        progress = Self.decodeDouble(from: container, key: .progress)
        creationTime = Self.decodeDouble(from: container, key: .creationTime)
        processedItemCount = Self.decodeInteger(from: container, key: .processedItemCount)
        processedBytes = Self.decodeInteger(from: container, key: .processedBytes)
        total = Self.decodeInteger(from: container, key: .total)
    }

    private static func decodeBool(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Bool? {
        if let value = try? container.decode(Bool.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key) { return value != 0 }
        if let value = try? container.decode(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func decodeDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let value = try? container.decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    private static func decodeInteger(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int64? {
        if let value = try? container.decode(Int64.self, forKey: key) { return value }
        if let value = try? container.decode(String.self, forKey: key) { return Int64(value) }
        return nil
    }
}

private struct FileInfoPayload: Decodable, Sendable {
    let files: [FilePayload]
}

private struct FileStationInfoPayload: Decodable, Sendable {
    let supportedVirtualProtocols: [String]

    private enum CodingKeys: String, CodingKey {
        case supportVirtualProtocol = "support_virtual_protocol"
        case supportVirtual = "support_virtual"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self.decodeValue(from: container, key: .supportVirtualProtocol)
            ?? Self.decodeValue(from: container, key: .supportVirtual)
            ?? ""
        supportedVirtualProtocols = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func decodeValue(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let values = try? container.decode([String].self, forKey: key) {
            return values.joined(separator: ",")
        }
        return nil
    }
}

private struct FilePayload: Decodable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let additional: FileAdditionalPayload?

    private enum CodingKeys: String, CodingKey {
        case name
        case path
        case isDirectory = "isdir"
        case additional
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        if let value = try? container.decode(Bool.self, forKey: .isDirectory) {
            isDirectory = value
        } else if let value = try? container.decode(Int.self, forKey: .isDirectory) {
            isDirectory = value != 0
        } else if let value = try? container.decode(String.self, forKey: .isDirectory) {
            isDirectory = value == "1" || value.lowercased() == "true"
        } else {
            isDirectory = false
        }
        additional = try? container.decodeIfPresent(FileAdditionalPayload.self, forKey: .additional)
    }
}

private struct FileAdditionalPayload: Decodable, Sendable {
    let size: Int64?
    let type: String?
    let time: FileTimePayload?
    let owner: FileOwnerPayload?
    let perm: FilePermissionPayload?
    let mountPointType: String?
    let realPath: String?
    let volumeStatus: VolumeStatusPayload?

    private enum CodingKeys: String, CodingKey {
        case size
        case type
        case time
        case owner
        case perm
        case mountPointType = "mount_point_type"
        case realPath = "real_path"
        case volumeStatus = "volume_status"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Int64.self, forKey: .size) {
            size = value
        } else if let value = try? container.decode(String.self, forKey: .size) {
            size = Int64(value)
        } else {
            size = nil
        }
        type = try container.decodeIfPresent(String.self, forKey: .type)
        time = try? container.decodeIfPresent(FileTimePayload.self, forKey: .time)
        owner = try? container.decodeIfPresent(FileOwnerPayload.self, forKey: .owner)
        perm = try? container.decodeIfPresent(FilePermissionPayload.self, forKey: .perm)
        mountPointType = try? container.decodeIfPresent(String.self, forKey: .mountPointType)
        realPath = try? container.decodeIfPresent(String.self, forKey: .realPath)
        volumeStatus = try? container.decodeIfPresent(VolumeStatusPayload.self, forKey: .volumeStatus)
    }
}

private struct VolumeStatusPayload: Decodable, Sendable {
    let totalBytes: Int64?
    let remainingBytes: Int64?

    private enum CodingKeys: String, CodingKey {
        case totalspace
        case totalSpace = "total_space"
        case total
        case freespace
        case freeSpace = "free_space"
        case free
        case available
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalBytes = Self.decodeInteger(
            from: container,
            keys: [.totalspace, .totalSpace, .total]
        )
        remainingBytes = Self.decodeInteger(
            from: container,
            keys: [.freespace, .freeSpace, .free, .available]
        )
    }

    private static func decodeInteger(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Int64? {
        for key in keys {
            if let value = try? container.decode(Int64.self, forKey: key) {
                return value
            }
            if let value = try? container.decode(String.self, forKey: key),
               let integer = Int64(value) {
                return integer
            }
        }
        return nil
    }
}

private struct SearchListPayload: Decodable, Sendable {
    let offset: Int?
    let total: Int?
    let finished: Bool?
    let files: [FilePayload]?
}

private struct FavoritePayload: Decodable, Sendable {
    let name: String?
    let path: String
}

private struct FavoritePagePayload: Decodable, Sendable {
    let favorites: [FavoritePayload]
    let offset: Int?
    let total: Int?

    private enum CodingKeys: String, CodingKey { case favorites, offset, total }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favorites = try container.decode([FavoritePayload].self, forKey: .favorites)
        let hasOffset = container.contains(.offset)
        let hasTotal = container.contains(.total)
        guard hasOffset == hasTotal else {
            throw DecodingError.dataCorruptedError(
                forKey: .favorites,
                in: container,
                debugDescription: "Favorite pagination metadata must be present together."
            )
        }
        if hasOffset {
            let decodedOffset = try container.decode(Int.self, forKey: .offset)
            let decodedTotal = try container.decode(Int.self, forKey: .total)
            guard decodedOffset >= 0, decodedTotal >= 0, decodedOffset <= decodedTotal,
                  favorites.count <= decodedTotal - decodedOffset else {
                throw DecodingError.dataCorruptedError(
                    forKey: .favorites,
                    in: container,
                    debugDescription: "Favorite page bounds are invalid."
                )
            }
            offset = decodedOffset
            total = decodedTotal
        } else {
            offset = nil
            total = nil
        }
    }
}

private struct StrictVirtualFolderPagePayload: Decodable, Sendable {
    let folders: [StrictVirtualFolderPayload]
    let offset: Int
    let total: Int

    private enum CodingKeys: String, CodingKey { case folders, offset, total }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folders = try container.decode([StrictVirtualFolderPayload].self, forKey: .folders)
        offset = try container.decode(Int.self, forKey: .offset)
        total = try container.decode(Int.self, forKey: .total)
        guard offset >= 0, total >= 0, offset <= total,
              folders.count <= total - offset else {
            throw DecodingError.dataCorruptedError(
                forKey: .folders,
                in: container,
                debugDescription: "Virtual folder page bounds are invalid."
            )
        }
    }
}

private struct StrictVirtualFolderPayload: Decodable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let additional: StrictVirtualFolderAdditionalPayload?

    private enum CodingKeys: String, CodingKey {
        case name, path, additional
        case isDirectory = "isdir"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        additional = try container.decodeIfPresent(
            StrictVirtualFolderAdditionalPayload.self,
            forKey: .additional
        )
    }
}

private struct StrictVirtualFolderAdditionalPayload: Decodable, Sendable {
    let mountPointType: String?
    let perm: FilePermissionPayload?

    private enum CodingKeys: String, CodingKey {
        case mountPointType = "mount_point_type"
        case perm
    }
}

private struct StrictRecycleSharePagePayload: Decodable, Sendable {
    let shares: [StrictRecycleSharePayload]
    let offset: Int
    let total: Int

    private enum CodingKeys: String, CodingKey { case shares, offset, total }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shares = try container.decode([StrictRecycleSharePayload].self, forKey: .shares)
        offset = try container.decode(Int.self, forKey: .offset)
        total = try container.decode(Int.self, forKey: .total)
        guard offset >= 0, total >= 0, offset <= total,
              shares.count <= total - offset else {
            throw DecodingError.dataCorruptedError(
                forKey: .shares,
                in: container,
                debugDescription: "Recycle share page bounds are invalid."
            )
        }
    }
}

private struct StrictRecycleSharePayload: Decodable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let additional: StrictRecycleShareAdditionalPayload?

    private enum CodingKeys: String, CodingKey {
        case name, path, additional
        case isDirectory = "isdir"
    }
}

private struct StrictRecycleShareAdditionalPayload: Decodable, Sendable {
    let mountPointType: String?

    private enum CodingKeys: String, CodingKey {
        case mountPointType = "mount_point_type"
    }
}

private struct StrictRecycleProbePayload: Decodable, Sendable {
    let files: [StrictRecycleProbeItemPayload]
    let offset: Int
    let total: Int

    private enum CodingKeys: String, CodingKey { case files, offset, total }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decode([StrictRecycleProbeItemPayload].self, forKey: .files)
        offset = try container.decode(Int.self, forKey: .offset)
        total = try container.decode(Int.self, forKey: .total)
        guard offset >= 0, total >= 0, offset <= total,
              files.count <= total - offset else {
            throw DecodingError.dataCorruptedError(
                forKey: .files,
                in: container,
                debugDescription: "Recycle probe bounds are invalid."
            )
        }
    }
}

private struct StrictRecycleProbeItemPayload: Decodable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool

    private enum CodingKeys: String, CodingKey {
        case name, path
        case isDirectory = "isdir"
    }
}

private struct ShareListItemPayload: Decodable, Sendable {
    let id: String
    let name: String?
    let path: String
    let url: String
    let hasPassword: Bool
    let expiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, path, url
        case hasPassword = "has_password"
        case expiresAt = "date_expired"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .id) {
            id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let value = try? container.decode(Int.self, forKey: .id) {
            id = String(value)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Share link ID is required."
            )
        }
        guard !id.isEmpty, id.utf8.count <= 512 else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Share link ID is invalid."
            )
        }
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        guard path.hasPrefix("/"), path.utf8.count <= 4_096 else {
            throw DecodingError.dataCorruptedError(
                forKey: .path,
                in: container,
                debugDescription: "Share link path is invalid."
            )
        }
        url = try container.decode(String.self, forKey: .url)
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "http" ||
                components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .url,
                in: container,
                debugDescription: "Share link URL is invalid."
            )
        }
        if let value = try? container.decode(Bool.self, forKey: .hasPassword) {
            hasPassword = value
        } else if let value = try? container.decode(Int.self, forKey: .hasPassword) {
            guard value == 0 || value == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .hasPassword,
                    in: container,
                    debugDescription: "Share password flag is invalid."
                )
            }
            hasPassword = value == 1
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .hasPassword,
                in: container,
                debugDescription: "Share password flag is required."
            )
        }
        if let value = try? container.decode(String.self, forKey: .expiresAt) {
            if value == "0" {
                expiresAt = nil
            } else {
                expiresAt = try FileShareLinkCalendarDate(iso8601: value).iso8601
            }
        } else if let value = try? container.decode(Int.self, forKey: .expiresAt) {
            guard value == 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .expiresAt,
                    in: container,
                    debugDescription: "Share expiration date is invalid."
                )
            }
            expiresAt = nil
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .expiresAt,
                in: container,
                debugDescription: "Share expiration date is required."
            )
        }
    }
}

private struct SharePagePayload: Decodable, Sendable {
    let links: [ShareListItemPayload]
    let offset: Int
    let total: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        links = try container.decode([ShareListItemPayload].self, forKey: .links)
        offset = try container.decode(Int.self, forKey: .offset)
        total = try container.decode(Int.self, forKey: .total)
        guard offset >= 0, total >= 0, offset <= total,
              links.count <= total - offset else {
            throw DecodingError.dataCorruptedError(
                forKey: .links,
                in: container,
                debugDescription: "Share link page bounds are invalid."
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case links, offset, total }
}

private struct ShareCreateItemPayload: Decodable, Sendable {
    let id: String?
    let path: String
    let error: Int

    private enum CodingKeys: String, CodingKey { case id, path, url, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .id) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            id = trimmed.isEmpty || trimmed.utf8.count > 512 ? nil : trimmed
        } else if let value = try? container.decode(Int.self, forKey: .id) {
            id = String(value)
        } else {
            id = nil
        }
        path = try container.decode(String.self, forKey: .path)
        guard path.hasPrefix("/"), path.utf8.count <= 4_096 else {
            throw DecodingError.dataCorruptedError(
                forKey: .path,
                in: container,
                debugDescription: "Created share path is invalid."
            )
        }
        error = try container.decode(Int.self, forKey: .error)
        guard error >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .error,
                in: container,
                debugDescription: "Created share item error is invalid."
            )
        }
        let value = try container.decode(String.self, forKey: .url)
        if let components = URLComponents(string: value),
           components.scheme?.lowercased() == "http" ||
            components.scheme?.lowercased() == "https",
           components.host?.isEmpty == false,
           components.user == nil,
           components.password == nil {
            // 创建响应中的 URL 只用于验证形态；最终 URL 始终来自列表回读。
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .url,
                in: container,
                debugDescription: "Created share URL is invalid."
            )
        }
    }
}

private struct ShareCreatePayload: Decodable, Sendable {
    let links: [ShareCreateItemPayload]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        links = try container.decode([ShareCreateItemPayload].self, forKey: .links)
        guard links.count == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .links,
                in: container,
                debugDescription: "A single share result is required."
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case links }
}

private enum ShareLinkReadbackError: Error, Sendable {
    case invalidPage
    case duplicateID
    case totalDrift
    case zeroProgress
    case truncated
}

private struct FileTimePayload: Decodable, Sendable {
    let mtime: Int64?
    let crtime: Int64?
    let atime: Int64?

    private enum CodingKeys: String, CodingKey {
        case mtime, crtime, atime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mtime = Self.integer(in: container, forKey: .mtime)
        crtime = Self.integer(in: container, forKey: .crtime)
        atime = Self.integer(in: container, forKey: .atime)
    }

    private static func integer(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int64? {
        if let value = try? container.decode(Int64.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }
}

private struct FileOwnerPayload: Decodable, Sendable {
    let user: String?
    let group: String?
}

private struct FilePermissionPayload: Decodable, Sendable {
    let posix: Int?
    let advRight: [String: Bool]?

    private enum CodingKeys: String, CodingKey {
        case posix
        case advRight = "adv_right"
    }
}

private struct TaskStartPayload: Decodable, Sendable {
    let taskid: String
}

private struct FileMD5StatusPayload: Decodable, Sendable {
    let finished: Bool
    let md5: String?
}

private struct DirectorySizeStatusPayload: Decodable, Sendable {
    let finished: Bool
    let totalBytes: Int64?
    let fileCount: Int64?
    let directoryCount: Int64?

    private enum CodingKeys: String, CodingKey {
        case finished
        case totalBytes = "total_size"
        case fileCount = "num_file"
        case directoryCount = "num_dir"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        finished = try container.decode(Bool.self, forKey: .finished)
        totalBytes = Self.decodeInteger(from: container, key: .totalBytes)
        fileCount = Self.decodeInteger(from: container, key: .fileCount)
        directoryCount = Self.decodeInteger(from: container, key: .directoryCount)
    }

    private static func decodeInteger(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int64? {
        if let value = try? container.decode(Int64.self, forKey: key) { return value }
        if let value = try? container.decode(String.self, forKey: key) { return Int64(value) }
        return nil
    }
}

private struct ArchiveListPayload: Decodable, Sendable {
    let items: [ArchiveItemPayload]?
}

private struct ArchiveItemPayload: Decodable, Sendable {
    let itemid: Int
    let name: String
    let path: String
    let isDirectory: Bool

    private enum CodingKeys: String, CodingKey {
        case itemid, name, path
        case isDirectory = "is_dir"
    }
}

private struct TaskStatusPayload: Decodable, Sendable {
    let finished: Bool
    let progress: Int64?
    let total: Int64?
    let processedSize: Int64?

    private enum CodingKeys: String, CodingKey {
        case finished
        case progress
        case total
        case processedSize = "processed_size"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        finished = try container.decode(Bool.self, forKey: .finished)
        total = try container.decodeIfPresent(Int64.self, forKey: .total)
        processedSize = try container.decodeIfPresent(Int64.self, forKey: .processedSize)
        if let integerProgress = try? container.decodeIfPresent(Int64.self, forKey: .progress) {
            progress = integerProgress
        } else if let fractionalProgress = try? container.decodeIfPresent(Double.self, forKey: .progress) {
            progress = Int64((fractionalProgress <= 1 ? fractionalProgress * 100 : fractionalProgress).rounded())
        } else {
            progress = nil
        }
    }
}

private struct BinaryEnvelope: Decodable, Sendable {
    struct ErrorPayload: Decodable, Sendable {
        let code: Int
    }

    let success: Bool
    let error: ErrorPayload?
}

private struct StreamingUploadPlan: @unchecked Sendable {
    var request: URLRequest
    let prefix: Data
    let suffix: Data
}

struct DirectorySizePollingPolicy: Sendable {
    let maxAttempts: Int
    let initialDelayNanoseconds: UInt64
    let maximumDelayNanoseconds: UInt64

    static let production = DirectorySizePollingPolicy(
        maxAttempts: 30,
        initialDelayNanoseconds: 250_000_000,
        maximumDelayNanoseconds: 2_000_000_000
    )
}

private enum FileItemMutationPreflight: Sendable {
    case allowed(expectedDirectory: Bool)
    case permission
    case conflict
}

private struct PendingFileItemMutationReview: Sendable {
    let paths: Set<String>
    let expectedDirectory: Bool
}

private enum FileItemMutationReadback: Sendable {
    case confirmed(FileItem)
    case mismatch
    case unavailable(AppError?)
}

public actor DsmFileRepository: FileRepository {
    public nonisolated let profileID: UUID
    public nonisolated let allowsVerifiedRestore: Bool
    public nonisolated let allowsRemoteMountManagement: Bool
    public nonisolated let fileShareLinkAvailability: FileShareLinkAvailability

    private let baseURL: URL
    private let expectedHost: String
    private let pinnedCertificateSHA256: String?
    private let capabilities: CapabilitySet
    private let credential: DsmSessionCredential
    private let transport: any DsmBinaryHTTPTransport
    private let client: DsmAPIClient
    private let directorySizePollingPolicy: DirectorySizePollingPolicy
    private var activeDeletionPaths: Set<String> = []
    private var activeDirectorySizePaths: Set<String> = []
    private var activeShareLinkPaths: Set<String> = []
    private var activeFileItemMutationPaths: Set<String> = []
    /// 提交状态未知的目标只能回读复核，不能再次发送写请求。
    private var pendingFileItemMutationReviews: [String: PendingFileItemMutationReview] = [:]

    public init(
        profile: NasProfile,
        capabilities: CapabilitySet,
        session: AuthSession,
        transport: (any DsmBinaryHTTPTransport)? = nil
    ) throws {
        try self.init(
            profile: profile,
            capabilities: capabilities,
            session: session,
            transport: transport,
            directorySizePollingPolicy: .production
        )
    }

    init(
        profile: NasProfile,
        capabilities: CapabilitySet,
        session: AuthSession,
        transport: (any DsmBinaryHTTPTransport)?,
        directorySizePollingPolicy: DirectorySizePollingPolicy
    ) throws {
        let resolvedTransport = transport ?? URLSessionTransport(
            expectedHost: profile.host,
            pinnedCertificateSHA256: profile.pinnedCertificateSHA256,
            requiresSystemCertificateTrust: DsmQuickConnectResolver.isTrustedRelayHost(
                profile.host
            )
        )
        let baseURL = try DsmEndpoint.baseURL(for: profile)
        profileID = profile.id
        allowsVerifiedRestore = capabilities[DsmAPIName.fileStationCopyMove]?.verified == true
        allowsRemoteMountManagement = capabilities[DsmAPIName.fileStationMount]?.selectedVersion == 1
        let sharingCapability = capabilities[DsmAPIName.fileStationSharing]
        let listCapability = capabilities[DsmAPIName.fileStationList]
        fileShareLinkAvailability = sharingCapability?.selectedVersion == 3 &&
            sharingCapability?.requestFormat.rawValue == DsmRequestFormat.form.rawValue &&
            (listCapability?.selectedVersion ?? 0) >= 2
            ? FileShareLinkAvailability(status: .available, resolvedVersion: 3)
            : .unsupported
        self.baseURL = baseURL
        self.expectedHost = profile.host
        self.pinnedCertificateSHA256 = profile.pinnedCertificateSHA256
        self.capabilities = capabilities
        self.credential = DsmSessionCredential(
            sid: session.sid,
            synoToken: session.synoToken
        )
        self.transport = resolvedTransport
        self.client = DsmAPIClient(baseURL: baseURL, transport: resolvedTransport)
        self.directorySizePollingPolicy = directorySizePollingPolicy
    }

    public func listShares(offset: Int = 0, limit: Int = 200) async throws -> FilePage {
        try await listShares(offset: offset, limit: limit, options: .default)
    }

    /// 共享根只使用排序选项；类型筛选由调用方在进入普通目录后启用。
    public func listShares(
        offset: Int,
        limit: Int,
        options: FileListOptions
    ) async throws -> FilePage {
        let capability = try requireCapability(DsmAPIName.fileStationList)
        let effectiveOptions = FileListOptions(
            sortField: .name,
            sortDirection: options.sortDirection,
            typeFilter: .all
        )
        do {
            let payload = try await client.call(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "list_share",
                requestFormat: capability.requestFormat,
                parameters: listParameters(
                    offset: offset,
                    limit: limit,
                    options: effectiveOptions,
                    includesTypeFilter: false
                ),
                credential: credential,
                as: FileListPayload.self
            )
            let items = (payload.shares ?? []).map(makeFileItem)
            let resolvedOffset = payload.offset ?? offset
            let total = payload.total ?? items.count
            return FilePage(
                folderPath: "/",
                items: items,
                offset: resolvedOffset,
                total: total,
                hasMore: resolvedOffset + items.count < total
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    public func listBackgroundTasks(
        offset: Int = 0,
        limit: Int = 100
    ) async throws -> FileBackgroundTaskPage {
        let capability = try requireCapability(DsmAPIName.fileStationBackgroundTask)
        let requestedOffset = max(0, offset)
        // 官方允许 limit=0 返回全部任务；客户端始终限制为有界分页。
        let requestedLimit = min(max(1, limit), 100)

        do {
            let payload = try await client.call(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "list",
                requestFormat: capability.requestFormat,
                parameters: [
                    "offset": .integer(requestedOffset),
                    "limit": .integer(requestedLimit),
                    "sort_by": .string("crtime"),
                    "sort_direction": .string("desc"),
                    "api_filter": .stringArray([
                        "SYNO.FileStation.CopyMove",
                        "SYNO.FileStation.Delete",
                        "SYNO.FileStation.Extract",
                        "SYNO.FileStation.Compress"
                    ])
                ],
                credential: credential,
                as: BackgroundTaskListPayload.self
            )

            let rawTasks = Array((payload.tasks ?? []).prefix(requestedLimit))
            var seenTaskIDs: Set<String> = []
            let tasks = rawTasks.compactMap { task -> FileBackgroundTaskSummary? in
                guard let summary = Self.makeBackgroundTaskSummary(task),
                      seenTaskIDs.insert(summary.id).inserted else {
                    return nil
                }
                return summary
            }
            let resolvedOffset = min(max(0, payload.offset ?? requestedOffset), 1_000_000)
            let nextOffset = min(resolvedOffset + rawTasks.count, 1_000_000)
            let reportedTotal = min(max(0, payload.total ?? nextOffset), 1_000_000)
            let total = max(nextOffset, reportedTotal)
            return FileBackgroundTaskPage(
                tasks: tasks,
                offset: resolvedOffset,
                nextOffset: nextOffset,
                total: total,
                hasMore: !rawTasks.isEmpty && nextOffset < total
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    public func listFolder(path: String, offset: Int = 0, limit: Int = 500) async throws -> FilePage {
        try await listFolder(path: path, offset: offset, limit: limit, options: .default)
    }

    public func listFolder(
        path: String,
        offset: Int,
        limit: Int,
        options: FileListOptions
    ) async throws -> FilePage {
        let capability = try requireCapability(DsmAPIName.fileStationList)
        do {
            var parameters = listParameters(
                offset: offset,
                limit: limit,
                options: options,
                includesTypeFilter: true
            )
            parameters["folder_path"] = .string(path)
            let payload = try await client.call(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "list",
                requestFormat: capability.requestFormat,
                parameters: parameters,
                credential: credential,
                as: FileListPayload.self
            )
            let items = (payload.files ?? []).map(makeFileItem)
            let resolvedOffset = payload.offset ?? offset
            let total = payload.total ?? items.count
            return FilePage(
                folderPath: path,
                items: items,
                offset: resolvedOffset,
                total: total,
                hasMore: resolvedOffset + items.count < total
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    public func getInfo(paths: [String]) async throws -> [FileItem] {
        guard !paths.isEmpty else {
            return []
        }
        let capability = try requireCapability(DsmAPIName.fileStationList)
        let version = try selectedVersion(capability, minimum: 2)
        var orderedPaths: [String] = []
        var seenPaths = Set<String>()
        for path in paths where seenPaths.insert(path).inserted {
            orderedPaths.append(path)
        }
        do {
            var itemsByPath: [String: FileItem] = [:]
            for chunkStart in stride(from: 0, to: orderedPaths.count, by: Self.getInfoChunkSize) {
                let chunkEnd = min(chunkStart + Self.getInfoChunkSize, orderedPaths.count)
                let chunk = Array(orderedPaths[chunkStart..<chunkEnd])
                let payload = try await client.call(
                    path: capability.path,
                    api: capability.name,
                    version: version,
                    method: "getinfo",
                    requestFormat: capability.requestFormat,
                    parameters: [
                        "path": .stringArray(chunk),
                        "additional": .stringArray(Self.getInfoAdditionalFields)
                    ],
                    credential: credential,
                    as: FileInfoPayload.self
                )
                let requestedPaths = Set(chunk)
                for payloadItem in payload.files where requestedPaths.contains(payloadItem.path) {
                    if itemsByPath[payloadItem.path] == nil {
                        itemsByPath[payloadItem.path] = makeFileItem(payloadItem)
                    }
                }
            }
            return orderedPaths.compactMap { itemsByPath[$0] }
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    public func listVirtualFolders(offset: Int, limit: Int) async throws -> FileVirtualFolderPage {
        let infoCapability = try requireCapability(DsmAPIName.fileStationInfo)
        let virtualFolderCapability = try requireCapability(DsmAPIName.fileStationVirtualFolder)
        guard infoCapability.minVersion <= 2, infoCapability.maxVersion >= 2,
              virtualFolderCapability.minVersion <= 2, virtualFolderCapability.maxVersion >= 2 else {
            throw AppError(
                category: .versionUnsupported,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.03e86493986f245a")
            )
        }
        let infoVersion = 2
        let virtualFolderVersion = 2
        let requestedOffset = min(max(0, offset), Self.virtualFolderSnapshotLimit)
        let remainingCapacity = Self.virtualFolderSnapshotLimit - requestedOffset
        let requestedLimit = remainingCapacity == 0
            ? 0
            : min(max(1, limit), remainingCapacity)

        let info: FileStationInfoPayload
        do {
            try Task.checkCancellation()
            info = try await client.call(
                path: infoCapability.path,
                api: infoCapability.name,
                version: infoVersion,
                method: "get",
                requestFormat: infoCapability.requestFormat,
                parameters: [:],
                credential: credential,
                as: FileStationInfoPayload.self
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DsmNetworkError {
            let mapped = DsmErrorMapper.map(error)
            if mapped.category == .cancelled { throw CancellationError() }
            throw mapped
        }

        let advertised = Set(info.supportedVirtualProtocols)
        let protocols = FileVirtualProtocol.allCases.filter { advertised.contains($0.rawValue) }
        guard !protocols.isEmpty else {
            return FileVirtualFolderPage(
                folders: [],
                offset: requestedOffset,
                total: 0,
                hasMore: false
            )
        }

        var folders: [FileVirtualFolder] = []
        var unavailableProtocols: [FileVirtualProtocol] = []
        var firstError: AppError?
        var sourceWasTruncated = false

        for protocolType in protocols {
            var protocolFolders: [FileVirtualFolder] = []
            var protocolOffset = 0
            var expectedTotal: Int?
            do {
                while protocolOffset < Self.virtualFolderSnapshotLimit {
                    try Task.checkCancellation()
                    let boundedRemaining = expectedTotal.map {
                        max(0, min($0, Self.virtualFolderSnapshotLimit) - protocolOffset)
                    } ?? (Self.virtualFolderSnapshotLimit - protocolOffset)
                    guard boundedRemaining > 0 else { break }
                    let requestLimit = min(Self.virtualFolderRequestLimit, boundedRemaining)
                    let payload = try await client.call(
                        path: virtualFolderCapability.path,
                        api: virtualFolderCapability.name,
                        version: virtualFolderVersion,
                        method: "list",
                        requestFormat: virtualFolderCapability.requestFormat,
                        parameters: [
                            "type": .string(protocolType.rawValue),
                            "offset": .integer(protocolOffset),
                            "limit": .integer(requestLimit),
                            "sort_by": .string("name"),
                            "sort_direction": .string("asc"),
                            "additional": .stringArray(Self.virtualFolderAdditionalFields)
                        ],
                        credential: credential,
                        as: StrictVirtualFolderPagePayload.self
                    )
                    try Task.checkCancellation()
                    guard payload.folders.count <= requestLimit else {
                        throw Self.invalidFileLocationResponse()
                    }
                    guard payload.offset == protocolOffset else {
                        throw Self.invalidFileLocationResponse()
                    }
                    if let expectedTotal {
                        guard payload.total == expectedTotal else {
                            throw Self.invalidFileLocationResponse()
                        }
                    } else {
                        expectedTotal = payload.total
                    }
                    let boundedTotal = min(payload.total, Self.virtualFolderSnapshotLimit)
                    if payload.folders.isEmpty, protocolOffset < boundedTotal {
                        throw Self.invalidFileLocationResponse()
                    }
                    for folder in payload.folders {
                        let canonicalPath = try Self.canonicalFileLocationPath(folder.path)
                        let normalizedName = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let advertisedType = folder.additional?.mountPointType?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        guard folder.isDirectory,
                              !normalizedName.isEmpty,
                              normalizedName.utf8.count <= 1_024,
                              advertisedType == nil || advertisedType == protocolType.rawValue else {
                            throw Self.invalidFileLocationResponse()
                        }
                        let rights = folder.additional?.perm?.advRight ?? [:]
                        let item = FileItem(
                            profileID: profileID,
                            name: normalizedName,
                            path: canonicalPath,
                            kind: .directory,
                            permissions: FilePermissions(
                                canRead: rights["read"] ?? rights["download"] ?? true,
                                canWrite: rights["write"] ?? rights["upload"] ?? false,
                                canDelete: rights["delete"] ?? false,
                                posixMode: folder.additional?.perm?.posix
                            ),
                            mountPointType: protocolType.rawValue
                        )
                        protocolFolders.append(
                            FileVirtualFolder(item: item, protocolType: protocolType)
                        )
                    }
                    let nextOffset = protocolOffset + payload.folders.count
                    guard nextOffset <= boundedTotal else {
                        throw Self.invalidFileLocationResponse()
                    }
                    guard nextOffset < boundedTotal else {
                        break
                    }
                    guard nextOffset > protocolOffset else {
                        throw Self.invalidFileLocationResponse()
                    }
                    protocolOffset = nextOffset
                }
                if let expectedTotal, expectedTotal > Self.virtualFolderSnapshotLimit {
                    sourceWasTruncated = true
                }
                folders.append(contentsOf: protocolFolders)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DsmNetworkError {
                let mapped = DsmErrorMapper.map(error)
                if mapped.category == .cancelled { throw CancellationError() }
                if mapped.category == .authenticationRequired || mapped.category == .otpRequired {
                    throw mapped
                }
                unavailableProtocols.append(protocolType)
                if firstError == nil {
                    firstError = mapped
                }
            } catch let error as AppError {
                if error.category == .cancelled { throw CancellationError() }
                if error.category == .authenticationRequired || error.category == .otpRequired {
                    throw error
                }
                unavailableProtocols.append(protocolType)
                if firstError == nil { firstError = error }
            }
        }

        if unavailableProtocols.count == protocols.count, let firstError {
            throw firstError
        }

        var uniqueFoldersByKey: [String: FileVirtualFolder] = [:]
        for folder in folders {
            let key = "\(folder.protocolType.rawValue)|\(folder.item.path)"
            if uniqueFoldersByKey[key] == nil {
                uniqueFoldersByKey[key] = folder
            }
        }
        let sortedFolders = uniqueFoldersByKey.values.sorted { left, right in
            let nameComparison = left.item.name.localizedCaseInsensitiveCompare(right.item.name)
            if nameComparison == .orderedSame {
                if left.item.path == right.item.path {
                    return left.protocolType.rawValue < right.protocolType.rawValue
                }
                return left.item.path < right.item.path
            }
            return nameComparison == .orderedAscending
        }
        let boundedFolders = Array(sortedFolders.prefix(Self.virtualFolderSnapshotLimit))
        let start = min(requestedOffset, boundedFolders.count)
        let end = min(start + requestedLimit, boundedFolders.count)
        let pageFolders = Array(boundedFolders[start..<end])
        let total = boundedFolders.count
        let isTruncated = sourceWasTruncated || sortedFolders.count > Self.virtualFolderSnapshotLimit
        return FileVirtualFolderPage(
            folders: pageFolders,
            offset: requestedOffset,
            total: total,
            hasMore: end < total,
            isTruncated: isTruncated,
            unavailableProtocols: unavailableProtocols
        )
    }

    public func listRemoteMounts(offset: Int, limit: Int) async throws -> FilePage {
        let page = try await listVirtualFolders(offset: offset, limit: limit)
        return FilePage(
            folderPath: "/",
            items: page.folders.map(\.item),
            offset: page.offset,
            total: page.total,
            hasMore: page.hasMore
        )
    }

    public func discoverRecycleLocations() async throws -> FileRecycleDiscoveryResult {
        let capability = try requireCapability(DsmAPIName.fileStationList)
        guard capability.minVersion <= 2, capability.maxVersion >= 2 else {
            throw AppError(
                category: .versionUnsupported,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.03e86493986f245a")
            )
        }

        var rawOffset = 0
        var expectedTotal: Int?
        var isTruncated = false
        var seenSharePaths = Set<String>()
        var localShares: [(name: String, path: String, recyclePath: String)] = []

        do {
            while rawOffset < Self.recycleShareLimit {
                try Task.checkCancellation()
                let boundedRemaining = expectedTotal.map {
                    max(0, min($0, Self.recycleShareLimit) - rawOffset)
                } ?? (Self.recycleShareLimit - rawOffset)
                guard boundedRemaining > 0 else { break }
                let requestLimit = min(Self.recycleSharePageLimit, boundedRemaining)
                let payload = try await client.call(
                    path: capability.path,
                    api: capability.name,
                    version: 2,
                    method: "list_share",
                    requestFormat: capability.requestFormat,
                    parameters: [
                        "offset": .integer(rawOffset),
                        "limit": .integer(requestLimit),
                        "sort_by": .string("name"),
                        "sort_direction": .string("asc"),
                        "additional": .stringArray(["mount_point_type"])
                    ],
                    credential: credential,
                    as: StrictRecycleSharePagePayload.self
                )
                try Task.checkCancellation()
                guard payload.shares.count <= requestLimit,
                      payload.offset == rawOffset else {
                    throw Self.invalidFileLocationResponse()
                }
                if let expectedTotal {
                    guard payload.total == expectedTotal else {
                        throw Self.invalidFileLocationResponse()
                    }
                } else {
                    expectedTotal = payload.total
                    isTruncated = payload.total > Self.recycleShareLimit
                }
                let boundedTotal = min(payload.total, Self.recycleShareLimit)
                if payload.shares.isEmpty, rawOffset < boundedTotal {
                    throw Self.invalidFileLocationResponse()
                }

                for share in payload.shares {
                    let canonicalPath = try Self.canonicalFileLocationPath(share.path)
                    let normalizedName = share.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard share.isDirectory,
                          !normalizedName.isEmpty,
                          normalizedName.utf8.count <= 1_024 else {
                        throw Self.invalidFileLocationResponse()
                    }
                    let mountType = share.additional?.mountPointType?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let isLocal = mountType == nil || mountType?.isEmpty == true ||
                        mountType == "normal" || mountType == "shared_folder"
                    guard isLocal, seenSharePaths.insert(canonicalPath).inserted else {
                        continue
                    }
                    localShares.append((
                        name: normalizedName,
                        path: canonicalPath,
                        recyclePath: try Self.canonicalFileLocationPath(
                            canonicalPath + "/#recycle"
                        )
                    ))
                }

                let nextOffset = rawOffset + payload.shares.count
                guard nextOffset <= boundedTotal else {
                    throw Self.invalidFileLocationResponse()
                }
                guard nextOffset < boundedTotal else { break }
                guard nextOffset > rawOffset else {
                    throw Self.invalidFileLocationResponse()
                }
                rawOffset = nextOffset
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DsmNetworkError {
            let mapped = DsmErrorMapper.map(error)
            if mapped.category == .cancelled { throw CancellationError() }
            throw mapped
        }

        var locations: [FileRecycleLocation] = []
        var scannedShareCount = 0
        var permissionDeniedShareCount = 0
        for share in localShares {
            try Task.checkCancellation()
            scannedShareCount += 1
            do {
                let payload = try await client.call(
                    path: capability.path,
                    api: capability.name,
                    version: 2,
                    method: "list",
                    requestFormat: capability.requestFormat,
                    parameters: [
                        "folder_path": .string(share.recyclePath),
                        "offset": .integer(0),
                        "limit": .integer(1),
                        "sort_by": .string("name"),
                        "sort_direction": .string("asc")
                    ],
                    credential: credential,
                    as: StrictRecycleProbePayload.self
                )
                try Task.checkCancellation()
                guard payload.offset == 0,
                      payload.files.count <= 1,
                      !(payload.files.isEmpty && payload.total > 0) else {
                    throw Self.invalidFileLocationResponse()
                }
                for item in payload.files {
                    let itemPath = try Self.canonicalFileLocationPath(item.path)
                    guard itemPath.hasPrefix(share.recyclePath + "/") else {
                        throw Self.invalidFileLocationResponse()
                    }
                }
                locations.append(FileRecycleLocation(
                    shareName: share.name,
                    sharePath: share.path,
                    recyclePath: share.recyclePath
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DsmNetworkError {
                let mapped = DsmErrorMapper.map(error)
                switch mapped.category {
                case .cancelled:
                    throw CancellationError()
                case .notFound:
                    continue
                case .permissionDenied:
                    permissionDeniedShareCount += 1
                    continue
                default:
                    throw mapped
                }
            } catch let error as AppError {
                switch error.category {
                case .cancelled:
                    throw CancellationError()
                case .notFound:
                    continue
                case .permissionDenied:
                    permissionDeniedShareCount += 1
                    continue
                default:
                    throw error
                }
            }
        }

        return FileRecycleDiscoveryResult(
            profileID: profileID,
            locations: locations,
            scannedShareCount: scannedShareCount,
            permissionDeniedShareCount: permissionDeniedShareCount,
            isTruncated: isTruncated
        )
    }

    public func getThumbnail(path: String, size: ThumbnailSize) async throws -> Data {
        let capability = try requireCapability(DsmAPIName.fileStationThumbnail)
        let request = try DsmRequestBuilder.build(
            baseURL: baseURL,
            path: capability.path,
            api: capability.name,
            version: try selectedVersion(capability),
            method: "get",
            requestFormat: capability.requestFormat,
            parameters: [
                "path": .string(path),
                "size": .string(size.rawValue),
                "rotate": .integer(0)
            ],
            credential: credential
        )
        do {
            let response = try await transport.send(request)
            try validateBinaryResponse(response, data: response.data)
            return response.data
        } catch {
            throw translate(error)
        }
    }

    public func readPrefix(remotePath: String, maximumLength: Int) async throws -> Data {
        guard maximumLength > 0 else { return Data() }
        let capability = try requireCapability(DsmAPIName.fileStationDownload)
        var request = try DsmRequestBuilder.build(
            baseURL: baseURL,
            path: capability.path,
            api: capability.name,
            version: try selectedVersion(capability),
            method: "download",
            requestFormat: capability.requestFormat,
            parameters: [
                "path": .stringArray([remotePath]),
                "mode": .string("download")
            ],
            credential: nil,
            httpMethod: "GET"
        )
        request.setValue("bytes=0-\(maximumLength - 1)", forHTTPHeaderField: "Range")
        if let cookie = credential.cookieHeaderValue {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let synoToken = credential.synoToken, !synoToken.isEmpty {
            request.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN")
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanStashFileProbe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do {
            let response = try await transport.download(request, to: temporaryURL) { _, _ in }
            let handle = try FileHandle(forReadingFrom: temporaryURL)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: maximumLength) ?? Data()
            try validateBinaryResponse(response, data: prefix)
            return prefix
        } catch {
            throw translate(error)
        }
    }

    public func checkWritePermission(
        folderPath: String,
        filename: String,
        createOnly: Bool
    ) async throws {
        let capability = try requireCapability(DsmAPIName.fileStationCheckPermission)
        do {
            try await client.callVoid(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "write",
                requestFormat: capability.requestFormat,
                parameters: [
                    "path": .string(folderPath),
                    "filename": .string(filename),
                    "create_only": .boolean(createOnly)
                ],
                credential: credential
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    public func mediaStreamSource(
        remotePath: String,
        fileExtension: String?,
        expectedContentLength: Int64?
    ) async throws -> MediaStreamSource {
        let capability = try requireCapability(DsmAPIName.fileStationDownload)
        var request = try DsmRequestBuilder.build(
            baseURL: baseURL,
            path: capability.path,
            api: capability.name,
            version: try selectedVersion(capability),
            method: "download",
            requestFormat: capability.requestFormat,
            parameters: [
                "path": .stringArray([remotePath]),
                "mode": .string("download")
            ],
            credential: nil,
            httpMethod: "GET"
        )
        if let cookie = credential.cookieHeaderValue {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let synoToken = credential.synoToken, !synoToken.isEmpty {
            request.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN")
        }
        return MediaStreamSource(
            request: request,
            fileExtension: fileExtension,
            expectedContentLength: expectedContentLength,
            expectedHost: expectedHost,
            pinnedCertificateSHA256: pinnedCertificateSHA256
        )
    }

    public func download(
        remotePath: String,
        to localURL: URL,
        expectedSize: Int64?,
        progress: @escaping FileTransferProgress
    ) async throws {
        try await performDownload(
            remotePaths: [remotePath],
            identity: remotePath,
            to: localURL,
            expectedSize: expectedSize,
            progress: progress
        )
    }

    public func downloadArchive(
        remotePaths: [String],
        to localURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws {
        guard !remotePaths.isEmpty else { return }
        try await performDownload(
            remotePaths: remotePaths,
            identity: remotePaths.joined(separator: "\u{1F}"),
            to: localURL,
            expectedSize: nil,
            progress: progress
        )
    }

    private func performDownload(
        remotePaths: [String],
        identity: String,
        to localURL: URL,
        expectedSize: Int64?,
        progress: @escaping FileTransferProgress
    ) async throws {
        let capability = try requireCapability(DsmAPIName.fileStationDownload)
        let baseRequest = try DsmRequestBuilder.build(
            baseURL: baseURL,
            path: capability.path,
            api: capability.name,
            version: try selectedVersion(capability),
            method: "download",
            requestFormat: capability.requestFormat,
            parameters: [
                "path": .stringArray(remotePaths),
                "mode": .string("download")
            ],
            credential: credential,
            httpMethod: "GET"
        )
        
        let partURL = partialDownloadURL(
            remotePath: identity,
            localURL: localURL,
            expectedSize: expectedSize
        )
        let metadataURL = Self.partialDownloadMetadataURL(for: partURL)
        
        do {
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw translate(error)
        }
        
        if let expectedSize, expectedSize > 0 {
            let savedChunkSize = UserDefaults.standard.integer(
                forKey: "LanStash_DownloadChunkSize"
            )
            let chunkSize: Int64 = (savedChunkSize >= 4 && savedChunkSize <= 64)
                ? Int64(savedChunkSize) * 1_024 * 1_024
                : 8 * 1_024 * 1_024
            let identityDigest = Self.partialDownloadIdentityDigest(
                profileID: profileID,
                remotePath: identity,
                expectedSize: expectedSize
            )
            let resumeState = try Self.loadPartialDownloadState(
                partURL: partURL,
                metadataURL: metadataURL,
                identityDigest: identityDigest,
                expectedSize: expectedSize
            )
            var completed = resumeState.completedBytes
            var contentVersion = resumeState.metadata?.contentVersion
            var remainingRestartCount = 1
            progress(completed, expectedSize)

            do {
                while completed < expectedSize {
                    try Task.checkCancellation()
                    let segmentURL = localURL.deletingLastPathComponent()
                        .appendingPathComponent(
                            ".\(localURL.lastPathComponent).\(UUID().uuidString).lanstash.segment"
                        )
                    defer { try? FileManager.default.removeItem(at: segmentURL) }

                    var request = baseRequest
                    let end = min(expectedSize - 1, completed + chunkSize - 1)
                    request.setValue(
                        "bytes=\(completed)-\(end)",
                        forHTTPHeaderField: "Range"
                    )
                    if completed > 0, let contentVersion {
                        request.setValue(
                            contentVersion.ifRangeValue,
                            forHTTPHeaderField: "If-Range"
                        )
                    }
                    let completedBeforeRequest = completed
                    let response = try await transport.download(request, to: segmentURL) { value, _ in
                        progress(completedBeforeRequest + value, expectedSize)
                    }
                    let inspectionData = try binaryInspectionData(
                        response: response,
                        fileURL: segmentURL
                    )
                    if response.statusCode == 416 {
                        try Self.discardPartialDownloadArtifacts(
                            partURL: partURL,
                            metadataURL: metadataURL
                        )
                        guard remainingRestartCount > 0 else {
                            throw Self.resumeIntegrityError()
                        }
                        remainingRestartCount -= 1
                        completed = 0
                        contentVersion = nil
                        progress(completed, expectedSize)
                        continue
                    }
                    try validateBinaryResponse(response, data: inspectionData)

                    if response.statusCode == 200 {
                        // If-Range 失效时服务端按规范返回完整 200。只要正文总长度
                        // 严格匹配，就从零开始采用这一个完整版本，绝不与旧 part 拼接。
                        guard Self.fileSize(at: segmentURL) == expectedSize else {
                            try Self.discardPartialDownloadArtifacts(
                                partURL: partURL,
                                metadataURL: metadataURL
                            )
                            guard remainingRestartCount > 0 else {
                                throw Self.resumeIntegrityError()
                            }
                            remainingRestartCount -= 1
                            completed = 0
                            contentVersion = nil
                            progress(completed, expectedSize)
                            continue
                        }
                        try Self.discardPartialDownloadArtifacts(
                            partURL: partURL,
                            metadataURL: metadataURL
                        )
                        try Self.safeReplaceFile(from: segmentURL, to: partURL)
                        completed = expectedSize
                        contentVersion = nil
                        progress(completed, expectedSize)
                        break
                    }

                    do {
                        let observedVersion = try Self.validateRangeResponse(
                            response: response,
                            actualSegmentLength: Self.fileSize(at: segmentURL),
                            expectedStart: completed,
                            expectedEnd: end,
                            expectedTotal: expectedSize,
                            expectedContentVersion: contentVersion
                        )
                        try Self.appendFile(at: segmentURL, to: partURL)
                        let metadata = DownloadResumeMetadata(
                            identityDigest: identityDigest,
                            expectedSize: expectedSize,
                            contentVersion: observedVersion
                        )
                        try Self.savePartialDownloadMetadata(
                            metadata,
                            to: metadataURL
                        )
                        completed = Self.fileSize(at: partURL)
                        contentVersion = observedVersion
                        progress(completed, expectedSize)
                    } catch is DownloadResumeValidationError {
                        try Self.discardPartialDownloadArtifacts(
                            partURL: partURL,
                            metadataURL: metadataURL
                        )
                        guard remainingRestartCount > 0 else {
                            throw Self.resumeIntegrityError()
                        }
                        remainingRestartCount -= 1
                        completed = 0
                        contentVersion = nil
                        progress(completed, expectedSize)
                    }
                }

                if completed != expectedSize {
                    throw AppError(
                        category: .partialFailure,
                        isRetryable: true,
                        safeUserMessage: L10n.string("shared.5e35450bf91845f5")
                    )
                }
                try Self.safeReplaceFile(from: partURL, to: localURL)
                try? FileManager.default.removeItem(at: partURL)
                try? FileManager.default.removeItem(at: metadataURL)
            } catch {
                throw translate(error)
            }
        } else {
            do {
                let response = try await transport.download(
                    baseRequest,
                    to: partURL,
                    progress: progress
                )
                let inspectionData = try binaryInspectionData(
                    response: response,
                    fileURL: partURL
                )
                try validateBinaryResponse(response, data: inspectionData)
                try Self.safeReplaceFile(from: partURL, to: localURL)
                try? FileManager.default.removeItem(at: partURL)
                try? FileManager.default.removeItem(at: metadataURL)
            } catch {
                try? FileManager.default.removeItem(at: partURL)
                try? FileManager.default.removeItem(at: metadataURL)
                throw translate(error)
            }
        }
    }

    public func removePartialDownload(to localURL: URL) async {
        let prefix = ".\(localURL.lastPathComponent)."
        let legacyName = ".\(localURL.lastPathComponent).lanstash.part"
        
        // 1. 清理临时目录下的分片（新逻辑）
        let tempDir = FileManager.default.temporaryDirectory
        let tempUrls = (try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in tempUrls where url.lastPathComponent.hasPrefix(prefix)
            && Self.isPartialDownloadArtifact(
                url.lastPathComponent,
                prefix: prefix
            ) {
            try? FileManager.default.removeItem(at: url)
        }
        
        // 2. 清理目标目录下的分片（测试和旧版本兼容）
        let targetDir = localURL.deletingLastPathComponent()
        let targetUrls = (try? FileManager.default.contentsOfDirectory(
            at: targetDir,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in targetUrls where url.lastPathComponent == legacyName
            || (url.lastPathComponent.hasPrefix(prefix)
                && Self.isPartialDownloadArtifact(
                    url.lastPathComponent,
                    prefix: prefix
                )) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func partialDownloadURL(
        remotePath: String,
        localURL: URL,
        expectedSize: Int64?
    ) -> URL {
        let digest = Self.partialDownloadIdentityDigest(
            profileID: profileID,
            remotePath: remotePath,
            expectedSize: expectedSize
        )
        let suffix = String(digest.prefix(16))
        return localURL.deletingLastPathComponent()
            .appendingPathComponent(".\(localURL.lastPathComponent).\(suffix).lanstash.part")
    }

    private static func partialDownloadIdentityDigest(
        profileID: UUID,
        remotePath: String,
        expectedSize: Int64?
    ) -> String {
        let identity = "\(profileID.uuidString)|\(remotePath)|\(expectedSize ?? -1)"
        return SHA256.hash(data: Data(identity.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func partialDownloadMetadataURL(for partURL: URL) -> URL {
        partURL.appendingPathExtension("metadata")
    }

    private static func isPartialDownloadArtifact(
        _ fileName: String,
        prefix: String
    ) -> Bool {
        fileName.hasPrefix(prefix)
            && (fileName.hasSuffix(".lanstash.part")
                || fileName.hasSuffix(".lanstash.part.metadata"))
    }

    private static func loadPartialDownloadState(
        partURL: URL,
        metadataURL: URL,
        identityDigest: String,
        expectedSize: Int64
    ) throws -> (completedBytes: Int64, metadata: DownloadResumeMetadata?) {
        let manager = FileManager.default
        let hasPart = manager.fileExists(atPath: partURL.path)
        let hasMetadata = manager.fileExists(atPath: metadataURL.path)
        guard hasPart, hasMetadata else {
            if hasPart || hasMetadata {
                try discardPartialDownloadArtifacts(
                    partURL: partURL,
                    metadataURL: metadataURL
                )
            }
            return (completedBytes: 0, metadata: nil)
        }
        guard let metadata = try? JSONDecoder().decode(
            DownloadResumeMetadata.self,
            from: Data(contentsOf: metadataURL)
        ), metadata.matches(
            identityDigest: identityDigest,
            expectedSize: expectedSize
        ) else {
            try discardPartialDownloadArtifacts(
                partURL: partURL,
                metadataURL: metadataURL
            )
            return (completedBytes: 0, metadata: nil)
        }
        let completed = fileSize(at: partURL)
        guard completed > 0, completed <= expectedSize else {
            try discardPartialDownloadArtifacts(
                partURL: partURL,
                metadataURL: metadataURL
            )
            return (completedBytes: 0, metadata: nil)
        }
        return (completed, metadata)
    }

    private static func savePartialDownloadMetadata(
        _ metadata: DownloadResumeMetadata,
        to metadataURL: URL
    ) throws {
        try JSONEncoder().encode(metadata).write(
            to: metadataURL,
            options: .atomic
        )
    }

    private static func discardPartialDownloadArtifacts(
        partURL: URL,
        metadataURL: URL
    ) throws {
        let manager = FileManager.default
        for url in [partURL, metadataURL] where manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        guard !manager.fileExists(atPath: partURL.path),
              !manager.fileExists(atPath: metadataURL.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func validateRangeResponse(
        response: DsmHTTPResponse,
        actualSegmentLength: Int64,
        expectedStart: Int64,
        expectedEnd: Int64,
        expectedTotal: Int64,
        expectedContentVersion: DownloadContentVersion?
    ) throws -> DownloadContentVersion {
        let span = expectedEnd.subtractingReportingOverflow(expectedStart)
        let expectedSegmentLength = span.partialValue.addingReportingOverflow(1)
        guard response.statusCode == 206,
              let contentRange = DownloadContentRange(
                response.headers.first {
                    $0.key.lowercased() == "content-range"
                }?.value
              ),
              contentRange.start == expectedStart,
              contentRange.end == expectedEnd,
              contentRange.total == expectedTotal,
              !span.overflow,
              !expectedSegmentLength.overflow,
              expectedSegmentLength.partialValue > 0,
              actualSegmentLength == expectedSegmentLength.partialValue,
              let contentVersion = DownloadContentVersion(headers: response.headers),
              expectedContentVersion == nil
                || expectedContentVersion == contentVersion else {
            throw DownloadResumeValidationError.invalidCheckpointOrRange
        }
        return contentVersion
    }

    private static func resumeIntegrityError() -> AppError {
        AppError(
            category: .partialFailure,
            isRetryable: true,
            safeUserMessage: L10n.string("shared.5e35450bf91845f5")
        )
    }

    private func binaryInspectionData(
        response: DsmHTTPResponse,
        fileURL: URL
    ) throws -> Data {
        let contentType = response.headers["content-type"]?.lowercased() ?? ""
        guard contentType.contains("application/json") || contentType.contains("text/html") else {
            return Data()
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        return try handle.read(upToCount: 1_048_576) ?? Data()
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func appendFile(at sourceURL: URL, to destinationURL: URL) throws {
        if !FileManager.default.fileExists(atPath: destinationURL.path) {
            guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let reader = try FileHandle(forReadingFrom: sourceURL)
        let writer = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? reader.close()
            try? writer.close()
        }
        try writer.seekToEnd()
        while let data = try reader.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            try writer.write(contentsOf: data)
        }
        try writer.synchronize()
    }

    private static func safeReplaceFile(from sourceURL: URL, to destinationURL: URL) throws {
        try AtomicFilePromotion.promote(
            from: sourceURL,
            to: destinationURL
        )
    }

    public func upload(
        localURL: URL,
        to folderPath: String,
        overwrite: Bool,
        progress: @escaping FileTransferProgress
    ) async throws {
        do {
            let capability = try requireCapability(DsmAPIName.fileStationUpload)
            // CheckPermission 的公开契约只保证检查“在目录中新建项目”的权限。
            // 覆盖上传时若直接拿已存在的文件名并传 create_only=false，部分 DSM
            // 会返回未公开错误码，导致真正的上传尚未开始便失败。使用一次性名称
            // 检查目标目录的写入权限，最终能否覆盖仍由 Upload API 决定。
            let permissionFilename = overwrite
                ? "LanStash-Write-Check-\(UUID().uuidString).tmp"
                : localURL.lastPathComponent
            try await checkWritePermission(
                folderPath: folderPath,
                filename: permissionFilename,
                createOnly: true
            )

            let boundary = "LanStash-\(UUID().uuidString)"
            let bodyURL = try createMultipartBody(
                localURL: localURL,
                boundary: boundary,
                fields: [
                    "api": capability.name,
                    "version": String(try selectedVersion(capability)),
                    "method": "upload",
                    "_sid": credential.sid,
                    "path": folderPath,
                    "create_parents": "false",
                    "overwrite": overwrite ? "true" : "false",
                    "SynoToken": credential.synoToken ?? "",
                    "synotoken": credential.synoToken ?? ""
                ]
            )
            defer { try? FileManager.default.removeItem(at: bodyURL) }

            var uploadURL = apiURL(path: capability.path)
            if var components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false) {
                var queryItems = components.queryItems ?? []
                queryItems.append(URLQueryItem(name: "api", value: capability.name))
                queryItems.append(URLQueryItem(name: "version", value: String(try selectedVersion(capability))))
                queryItems.append(URLQueryItem(name: "method", value: "upload"))
                components.queryItems = queryItems
                if let resolvedURL = components.url {
                    uploadURL = resolvedURL
                }
            }

            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let bodySize = try bodyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if let bodySize {
                request.setValue(String(bodySize), forHTTPHeaderField: "Content-Length")
            }
            if let cookie = credential.cookieHeaderValue {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            if let synoToken = credential.synoToken, !synoToken.isEmpty {
                request.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN")
            }

            let response = try await transport.upload(request, from: bodyURL, progress: progress)
            try validateUploadSuccess(response)
        } catch {
            throw translate(error)
        }
    }

    public func streamFileToNAS(
        remotePath: String,
        filename: String,
        expectedSize: Int64,
        target: DsmFileRepository,
        destinationFolder: String,
        overwrite: Bool,
        progress: @escaping FileTransferProgress
    ) async throws {
        guard expectedSize >= 0 else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.edd9dc456f2813da")
            )
        }
        let downloadCapability = try requireCapability(DsmAPIName.fileStationDownload)
        let baseRequest = try DsmRequestBuilder.build(
            baseURL: baseURL,
            path: downloadCapability.path,
            api: downloadCapability.name,
            version: try selectedVersion(downloadCapability),
            method: "download",
            requestFormat: downloadCapability.requestFormat,
            parameters: [
                "path": .stringArray([remotePath]),
                "mode": .string("download")
            ],
            credential: credential,
            httpMethod: "GET"
        )
        let uploadPlan = try await target.makeStreamingUploadPlan(
            filename: filename,
            fileSize: expectedSize,
            destinationFolder: destinationFolder,
            overwrite: overwrite
        )
        let progressState = CrossNASProgressState(fileSize: expectedSize, progress: progress)
        let pipe = BoundedMemoryPipe(
            capacity: 12 * 1_024 * 1_024,
            onFileBytesRead: { bytes in progressState.didUpload(bytes) }
        )

        let uploadTask = Task {
            do {
                try await target.performStreamingUpload(plan: uploadPlan, pipe: pipe)
            } catch {
                // 目标端提前拒绝上传时立即唤醒可能正在等待缓冲区空间的源端。
                pipe.cancel(with: error)
                throw error
            }
        }
        do {
            try pipe.write(uploadPlan.prefix, countsAsFileData: false)
            var offset: Int64 = 0
            var contentVersion: DownloadContentVersion?
            let chunkSize: Int64 = 4 * 1_024 * 1_024
            while offset < expectedSize {
                try Task.checkCancellation()
                let end = min(expectedSize - 1, offset + chunkSize - 1)
                var request = baseRequest
                request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                if offset > 0, let contentVersion {
                    request.setValue(
                        contentVersion.ifRangeValue,
                        forHTTPHeaderField: "If-Range"
                    )
                }
                let response = try await transport.send(request)
                try validateBinaryResponse(response, data: response.data)
                do {
                    contentVersion = try Self.validateRangeResponse(
                        response: response,
                        actualSegmentLength: Int64(response.data.count),
                        expectedStart: offset,
                        expectedEnd: end,
                        expectedTotal: expectedSize,
                        expectedContentVersion: contentVersion
                    )
                } catch is DownloadResumeValidationError {
                    // 跨 NAS 流式复制没有可验证的本地断点。校验器、范围或长度
                    // 任一不一致时立即取消整条上传，不能把不同远端版本写入目标端。
                    throw Self.resumeIntegrityError()
                }
                try pipe.write(response.data, countsAsFileData: true)
                progressState.didDownload(response.data.count)
                offset += Int64(response.data.count)
            }
            try pipe.write(uploadPlan.suffix, countsAsFileData: false)
            pipe.finish()
            try await uploadTask.value
        } catch {
            pipe.cancel(with: error)
            uploadTask.cancel()
            _ = try? await uploadTask.value
            throw translate(error)
        }
    }

    private func makeStreamingUploadPlan(
        filename: String,
        fileSize: Int64,
        destinationFolder: String,
        overwrite: Bool
    ) async throws -> StreamingUploadPlan {
        let capability = try requireCapability(DsmAPIName.fileStationUpload)
        try await checkWritePermission(
            folderPath: destinationFolder,
            filename: filename,
            createOnly: !overwrite
        )
        let boundary = "LanStash-\(UUID().uuidString)"
        let fields = [
            "api": capability.name,
            "version": String(try selectedVersion(capability)),
            "method": "upload",
            "_sid": credential.sid,
            "path": destinationFolder,
            "create_parents": "false",
            "overwrite": overwrite ? "true" : "false",
            "SynoToken": credential.synoToken ?? "",
            "synotoken": credential.synoToken ?? ""
        ]
        let safeFilename = filename
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\"", with: "'")
        var prefix = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
            prefix.append(Data("--\(boundary)\r\n".utf8))
            prefix.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            prefix.append(Data("\(value)\r\n".utf8))
        }
        prefix.append(Data("--\(boundary)\r\n".utf8))
        prefix.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n".utf8))
        prefix.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        let suffix = Data("\r\n--\(boundary)--\r\n".utf8)

        var uploadURL = apiURL(path: capability.path)
        if var components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false) {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "api", value: capability.name))
            queryItems.append(URLQueryItem(name: "version", value: String(try selectedVersion(capability))))
            queryItems.append(URLQueryItem(name: "method", value: "upload"))
            components.queryItems = queryItems
            uploadURL = components.url ?? uploadURL
        }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(Int64(prefix.count) + fileSize + Int64(suffix.count)), forHTTPHeaderField: "Content-Length")
        if let cookie = credential.cookieHeaderValue {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let synoToken = credential.synoToken, !synoToken.isEmpty {
            request.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN")
        }
        return StreamingUploadPlan(request: request, prefix: prefix, suffix: suffix)
    }

    private func performStreamingUpload(
        plan: StreamingUploadPlan,
        pipe: BoundedMemoryPipe
    ) async throws {
        var request = plan.request
        request.httpBodyStream = pipe.makeInputStream()
        let response = try await transport.send(request)
        try validateUploadSuccess(response)
    }

    public func delete(
        paths: [String],
        progress: @escaping FileTransferProgress
    ) async throws {
        guard !paths.isEmpty else {
            return
        }
        let capability = try requireCapability(DsmAPIName.fileStationDelete)
        do {
            let start = try await client.call(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "start",
                requestFormat: capability.requestFormat,
                parameters: [
                    "path": .stringArray(paths),
                    "recursive": .boolean(true),
                    "accurate_progress": .boolean(true)
                ],
                credential: credential,
                as: TaskStartPayload.self
            )
            try await pollTask(capability: capability, taskID: start.taskid, progress: progress)
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    /// 删除属于破坏性操作；统一结果会区分明确失败、部分完成和提交后无法确认。
    public func deleteResult(
        paths: [String],
        progress: @escaping FileTransferProgress
    ) async throws -> MutationResult {
        let operation = "fileDelete"
        if Task.isCancelled {
            return try makeMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "file-station.delete.cancelled-before-submission"
            )
        }

        let normalizedPaths = Array(Set(paths.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })).sorted()
        guard !normalizedPaths.isEmpty,
              normalizedPaths.allSatisfy(Self.isValidDeletionPath) else {
            return try makeMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: paths.count,
                unknown: 0,
                errorCategory: .validation,
                diagnosticTag: "file-station.delete.invalid-input"
            )
        }
        guard !activeDeletionPaths.contains(where: { activePath in
            normalizedPaths.contains {
                Self.deletionPathsOverlap(activePath, $0)
            }
        }) else {
            return try makeMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: normalizedPaths.count,
                unknown: 0,
                errorCategory: .conflict,
                diagnosticTag: "file-station.delete.duplicate-submission"
            )
        }
        guard let capability = capabilities[DsmAPIName.fileStationDelete],
              let version = capability.selectedVersion else {
            return try makeMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: normalizedPaths.count,
                unknown: 0,
                errorCategory: .unsupported,
                diagnosticTag: "file-station.delete.unsupported"
            )
        }

        activeDeletionPaths.formUnion(normalizedPaths)
        defer { activeDeletionPaths.subtract(normalizedPaths) }

        let taskID: String
        do {
            let start = try await client.call(
                path: capability.path,
                api: capability.name,
                version: version,
                method: "start",
                requestFormat: capability.requestFormat,
                parameters: [
                    "path": .stringArray(normalizedPaths),
                    "recursive": .boolean(true),
                    "accurate_progress": .boolean(true),
                ],
                credential: credential,
                as: TaskStartPayload.self
            )
            taskID = start.taskid
        } catch let error as DsmNetworkError {
            return try mutationResultForDeleteSubmissionError(
                error,
                operation: operation,
                itemCount: normalizedPaths.count
            )
        } catch {
            return try makeMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: normalizedPaths.count,
                errorCategory: .unknown,
                diagnosticTag: "file-station.delete.submission-unknown"
            )
        }

        do {
            try await pollTask(
                capability: capability,
                taskID: taskID,
                progress: progress
            )
        } catch let error as DsmNetworkError {
            let mapped = DsmErrorMapper.map(error)
            if mapped.category == .cancelled || Task.isCancelled {
                return try makeMutationResult(
                    status: .cancellationRequestedAfterSubmission,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: 0,
                    unknown: normalizedPaths.count,
                    errorCategory: mutationErrorCategory(for: mapped.category),
                    diagnosticTag: "file-station.delete.cancelled-after-submission"
                )
            }
            return try makeMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: normalizedPaths.count,
                errorCategory: mutationErrorCategory(for: mapped.category),
                diagnosticTag: "file-station.delete.task-unverified"
            )
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            return try makeMutationResult(
                status: cancelled
                    ? .cancellationRequestedAfterSubmission
                    : .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: normalizedPaths.count,
                errorCategory: cancelled ? nil : .unknown,
                diagnosticTag: cancelled
                    ? "file-station.delete.cancelled-after-submission"
                    : "file-station.delete.task-unknown"
            )
        }

        return try await verifyDeletedPaths(
            normalizedPaths,
            operation: operation
        )
    }

    public func createFolder(parentPath: String, name: String) async throws {
        let capability = try requireCapability(DsmAPIName.fileStationCreateFolder)
        do {
            try await client.callVoid(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "create",
                requestFormat: capability.requestFormat,
                parameters: [
                    "folder_path": .string(parentPath),
                    "name": .string(name),
                    "force_parent": .boolean(false)
                ],
                credential: credential
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    public func createFolderResult(
        parentPath: String,
        name: String
    ) async throws -> FileItemMutationOutcome {
        let operation = "createFolder"
        guard let parent = Self.normalizedMutationPath(parentPath),
              parent != "/",
              let normalizedName = Self.normalizedMutationName(name),
              let destination = Self.appendingMutationName(normalizedName, to: parent),
              !Self.isRecycleMutationPath(parent) else {
            return try fileItemMutationOutcome(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                failed: 1,
                errorCategory: .validation,
                diagnosticTag: "file-station.create-folder.invalid-input"
            )
        }
        let reviewKey = "create:\(destination)"
        return try await performFileItemMutation(
            operation: operation,
            sourcePath: nil,
            destinationPath: destination,
            reviewKey: reviewKey,
            expectedDirectory: true
        ) { capability in
            try await self.client.callVoid(
                path: capability.path,
                api: capability.name,
                version: 2,
                method: "create",
                requestFormat: .form,
                parameters: [
                    "folder_path": .string(parent),
                    "name": .string(normalizedName),
                    "force_parent": .boolean(false)
                ],
                credential: self.credential
            )
        } preflight: {
            guard let observedParent = try await self.getInfo(paths: [parent])
                .first(where: { $0.path == parent }),
                  observedParent.profileID == self.profileID,
                  Self.hasCanonicalMutationIdentity(observedParent),
                  observedParent.isDirectory,
                  !Self.isRemoteMutationItem(observedParent) else {
                return .conflict
            }
            if observedParent.permissions?.canWrite == false { return .permission }
            guard try await self.getInfo(paths: [destination]).isEmpty else {
                return .conflict
            }
            try await self.checkWritePermission(
                folderPath: parent,
                filename: normalizedName,
                createOnly: true
            )
            return .allowed(expectedDirectory: true)
        }
    }

    public func rename(path: String, newName: String) async throws {
        let capability = try requireCapability(DsmAPIName.fileStationRename)
        do {
            try await client.callVoid(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "rename",
                requestFormat: capability.requestFormat,
                parameters: [
                    "path": .stringArray([path]),
                    "name": .stringArray([newName])
                ],
                credential: credential
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    public func renameResult(
        path: String,
        newName: String
    ) async throws -> FileItemMutationOutcome {
        let operation = "rename"
        guard let source = Self.normalizedMutationPath(path),
              source.split(separator: "/").count >= 2,
              let normalizedName = Self.normalizedMutationName(newName),
              let parent = Self.mutationParentPath(source),
              let destination = Self.appendingMutationName(normalizedName, to: parent),
              source != destination,
              !Self.isRecycleMutationPath(source) else {
            return try fileItemMutationOutcome(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                failed: 1,
                errorCategory: .validation,
                diagnosticTag: "file-station.rename.invalid-input"
            )
        }
        let reviewKey = "rename:\(source)->\(destination)"
        return try await performFileItemMutation(
            operation: operation,
            sourcePath: source,
            destinationPath: destination,
            reviewKey: reviewKey,
            expectedDirectory: nil
        ) { capability in
            try await self.client.callVoid(
                path: capability.path,
                api: capability.name,
                version: 2,
                method: "rename",
                requestFormat: .form,
                parameters: [
                    "path": .stringArray([source]),
                    "name": .stringArray([normalizedName])
                ],
                credential: self.credential
            )
        } preflight: {
            guard let observedSource = try await self.getInfo(paths: [source])
                .first(where: { $0.path == source }),
                  observedSource.profileID == self.profileID,
                  Self.hasCanonicalMutationIdentity(observedSource),
                  !Self.isRemoteMutationItem(observedSource) else {
                return .conflict
            }
            if observedSource.permissions?.canWrite == false ||
                observedSource.permissions?.canDelete == false {
                return .permission
            }
            guard try await self.getInfo(paths: [destination]).isEmpty else {
                return .conflict
            }
            try await self.checkWritePermission(
                folderPath: parent,
                filename: normalizedName,
                createOnly: true
            )
            return .allowed(expectedDirectory: observedSource.isDirectory)
        }
    }

    public func move(
        paths: [String],
        to destinationFolder: String,
        overwrite: Bool,
        progress: @escaping FileTransferProgress
    ) async throws {
        try await copyMove(
            paths: paths,
            to: destinationFolder,
            overwrite: overwrite,
            removeSource: true,
            progress: progress
        )
    }

    public func copy(
        paths: [String],
        to destinationFolder: String,
        overwrite: Bool,
        progress: @escaping FileTransferProgress
    ) async throws {
        try await copyMove(
            paths: paths,
            to: destinationFolder,
            overwrite: overwrite,
            removeSource: false,
            progress: progress
        )
    }

    public func copyMoveResult(
        _ request: FileCopyMoveRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileCopyMoveOutcome {
        let operation = request.operation.rawValue
        guard request.profileID == profileID,
              request.source.profileID == profileID,
              Self.isSupportedCopyMoveSource(request.source),
              !request.overwrite,
              let sourcePath = Self.normalizedMutationPath(request.source.path),
              sourcePath == request.source.path,
              sourcePath.split(separator: "/").count >= 2,
              let destinationFolder = Self.normalizedMutationPath(request.destinationFolderPath),
              destinationFolder == request.destinationFolderPath,
              destinationFolder != "/",
              let destinationPath = Self.appendingMutationName(
                  request.source.name,
                  to: destinationFolder
              ),
              sourcePath != destinationPath,
              !destinationFolder.hasPrefix(sourcePath + "/"),
              !Self.isRecycleMutationPath(sourcePath),
              !Self.isRecycleMutationPath(destinationFolder),
              Self.hasCanonicalMutationIdentity(request.source),
              !Self.isRemoteMutationItem(request.source) else {
            return try FileCopyMoveOutcome(
                result: MutationResult(
                    status: .confirmedFailure,
                    operation: operation,
                    submitted: false,
                    requiresRefresh: false,
                    counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                    errorCategory: .validation,
                    diagnosticTag: "file-station.copy-move.invalid-input"
                ),
                sourcePath: request.source.path,
                destinationPath: request.destinationFolderPath,
                item: nil
            )
        }

        guard let capability = capabilities[DsmAPIName.fileStationCopyMove],
              capability.selectedVersion == 3,
              capability.requestFormat == .form,
              let listCapability = capabilities[DsmAPIName.fileStationList],
              (listCapability.selectedVersion ?? 0) >= 2,
              capabilities[DsmAPIName.fileStationCheckPermission]?.selectedVersion != nil else {
            return try FileCopyMoveOutcome(
                result: MutationResult(
                    status: .unsupported,
                    operation: operation,
                    submitted: false,
                    requiresRefresh: false,
                    counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                    errorCategory: .unsupported,
                    diagnosticTag: "file-station.copy-move.unsupported"
                ),
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                item: nil
            )
        }

        let prepared = FileCopyMovePreparedRequest(
            request: request,
            sourcePath: sourcePath,
            destinationFolderPath: destinationFolder,
            destinationPath: destinationPath,
            operationName: nil
        )
        return try await performPreparedCopyMoveResult(
            prepared,
            capability: capability,
            progress: progress
        )
    }

    public func moveToRecycleResult(
        _ request: FileMoveToRecycleRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileRecycleMutationOutcome {
        let operation = "moveToRecycle"
        let fallbackDestination = request.recycleLocation.recyclePath + "/" + request.item.name
        guard request.profileID == profileID,
              request.item.profileID == profileID,
              request.item.kind == .file,
              let sourceSize = request.item.sizeBytes,
              sourceSize >= 0,
              let sourcePath = Self.normalizedMutationPath(request.item.path),
              sourcePath == request.item.path,
              !Self.isRecycleMutationPath(sourcePath),
              let sharePath = Self.normalizedMutationPath(request.recycleLocation.sharePath),
              sharePath == request.recycleLocation.sharePath,
              let recycleRoot = Self.normalizedMutationPath(request.recycleLocation.recyclePath),
              recycleRoot == request.recycleLocation.recyclePath,
              Self.isRecycleMutationPath(recycleRoot),
              sourcePath.hasPrefix(sharePath + "/"),
              let destinationPath = Self.normalizedMutationPath(
                  recycleRoot + String(sourcePath.dropFirst(sharePath.count))
              ),
              destinationPath.hasPrefix(recycleRoot + "/"),
              Self.hasCanonicalMutationIdentity(request.item),
              !Self.isRemoteMutationItem(request.item) else {
            return try recycleMutationOutcome(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                sourcePath: request.item.path,
                destinationPath: fallbackDestination,
                failed: 1,
                errorCategory: .validation,
                diagnosticTag: "file-station.recycle.move.invalid-input"
            )
        }

        guard let capability = capabilities[DsmAPIName.fileStationDelete],
              capability.selectedVersion == 2,
              capability.requestFormat == .form,
              let listCapability = capabilities[DsmAPIName.fileStationList],
              (listCapability.selectedVersion ?? 0) >= 2 else {
            return try recycleMutationOutcome(
                status: .unsupported,
                operation: operation,
                submitted: false,
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                failed: 1,
                errorCategory: .unsupported,
                diagnosticTag: "file-station.recycle.move.unsupported"
            )
        }

        let prepared = FileRecyclePreparedRequest(
            profileID: request.profileID,
            operation: operation,
            source: request.item,
            sourcePath: sourcePath,
            destinationPath: destinationPath
        )
        return try await performPreparedMoveToRecycleResult(
            prepared,
            capability: capability,
            progress: progress
        )
    }

    public func restoreFromRecycleResult(
        _ request: FileRestoreFromRecycleRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileRecycleMutationOutcome {
        let operation = "restoreFromRecycle"
        guard request.profileID == profileID,
              request.item.profileID == profileID,
              request.item.kind == .file,
              let sourceSize = request.item.sizeBytes,
              sourceSize >= 0,
              let sourcePath = Self.normalizedMutationPath(request.item.path),
              sourcePath == request.item.path,
              Self.isRecycleMutationPath(sourcePath),
              let recycleLocation = RecycleLocation(recyclePath: sourcePath),
              let destinationFolder = Self.normalizedMutationPath(
                  recycleLocation.originalParentPath
              ),
              destinationFolder == recycleLocation.originalParentPath,
              destinationFolder != "/",
              let destinationPath = Self.normalizedMutationPath(recycleLocation.originalPath),
              destinationPath == recycleLocation.originalPath,
              !Self.isRecycleMutationPath(destinationFolder),
              !Self.isRecycleMutationPath(destinationPath),
              Self.hasCanonicalMutationIdentity(request.item),
              !Self.isRemoteMutationItem(request.item) else {
            return try recycleMutationOutcome(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                sourcePath: request.item.path,
                destinationPath: request.item.path,
                failed: 1,
                errorCategory: .validation,
                diagnosticTag: "file-station.recycle.restore.invalid-input"
            )
        }

        guard let capability = capabilities[DsmAPIName.fileStationCopyMove],
              capability.selectedVersion == 3,
              capability.requestFormat == .form,
              let listCapability = capabilities[DsmAPIName.fileStationList],
              (listCapability.selectedVersion ?? 0) >= 2,
              capabilities[DsmAPIName.fileStationCheckPermission]?.selectedVersion != nil else {
            return try recycleMutationOutcome(
                status: .unsupported,
                operation: operation,
                submitted: false,
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                failed: 1,
                errorCategory: .unsupported,
                diagnosticTag: "file-station.recycle.restore.unsupported"
            )
        }

        let copyMoveRequest = FileCopyMoveRequest(
            profileID: request.profileID,
            operation: .move,
            source: request.item,
            destinationFolderPath: destinationFolder,
            overwrite: false
        )
        let prepared = FileCopyMovePreparedRequest(
            request: copyMoveRequest,
            sourcePath: sourcePath,
            destinationFolderPath: destinationFolder,
            destinationPath: destinationPath,
            operationName: operation
        )
        let outcome = try await performPreparedCopyMoveResult(
            prepared,
            capability: capability,
            progress: progress
        )
        return FileRecycleMutationOutcome(
            result: outcome.result,
            sourcePath: outcome.sourcePath,
            destinationPath: outcome.destinationPath,
            item: outcome.item
        )
    }

    private func performPreparedMoveToRecycleResult(
        _ prepared: FileRecyclePreparedRequest,
        capability: ApiCapability,
        progress: @escaping FileTransferProgress
    ) async throws -> FileRecycleMutationOutcome {
        let paths = Set([prepared.sourcePath, prepared.destinationPath])
        if pendingFileItemMutationReviews.values.contains(where: {
            !$0.paths.isDisjoint(with: paths)
        }) || activeFileItemMutationPaths.contains(where: { active in
            paths.contains(where: { Self.deletionPathsOverlap(active, $0) })
        }) || activeDeletionPaths.contains(where: { active in
            paths.contains(where: { Self.deletionPathsOverlap(active, $0) })
        }) {
            return try recycleMutationOutcome(
                status: .confirmedFailure,
                operation: prepared.operation,
                submitted: false,
                sourcePath: prepared.sourcePath,
                destinationPath: prepared.destinationPath,
                failed: 1,
                errorCategory: .conflict,
                diagnosticTag: "file-station.recycle.move.target-busy"
            )
        }
        activeDeletionPaths.formUnion(paths)
        defer { activeDeletionPaths.subtract(paths) }

        let dependencies = FileRecycleMutationDependencies(
            submit: { [weak self] prepared, progress in
                guard let self else {
                    throw FileRecycleSubmissionFailure.cancelled(taskAccepted: false)
                }
                try await self.submitMoveToRecycle(
                    prepared,
                    capability: capability,
                    progress: progress
                )
            },
            readItems: { [weak self] paths in
                guard let self else { throw CancellationError() }
                return try await self.getInfo(paths: paths)
            }
        )
        return try await FileRecycleMutationCoordinator.shared.performMoveToRecycle(
            prepared,
            dependencies: dependencies,
            progress: progress
        )
    }

    private func recycleMutationOutcome(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool = false,
        sourcePath: String,
        destinationPath: String,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = nil,
        diagnosticTag: String,
        item: FileItem? = nil
    ) throws -> FileRecycleMutationOutcome {
        FileRecycleMutationOutcome(
            result: try MutationResult(
                status: status,
                operation: operation,
                submitted: submitted,
                requiresRefresh: requiresRefresh,
                counts: MutationResultCounts(
                    succeeded: succeeded,
                    failed: failed,
                    unknown: unknown
                ),
                errorCategory: errorCategory,
                diagnosticTag: diagnosticTag
            ),
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            item: item
        )
    }

    private func performPreparedCopyMoveResult(
        _ prepared: FileCopyMovePreparedRequest,
        capability: ApiCapability,
        progress: @escaping FileTransferProgress
    ) async throws -> FileCopyMoveOutcome {
        let paths = Set([
            prepared.sourcePath,
            prepared.destinationFolderPath,
            prepared.destinationPath,
        ])
        if pendingFileItemMutationReviews.values.contains(where: {
            !$0.paths.isDisjoint(with: paths)
        }) || activeFileItemMutationPaths.contains(where: { active in
            paths.contains(where: { Self.deletionPathsOverlap(active, $0) })
        }) || activeDeletionPaths.contains(where: { active in
            paths.contains(where: { Self.deletionPathsOverlap(active, $0) })
        }) {
            return try FileCopyMoveOutcome(
                result: MutationResult(
                    status: .confirmedFailure,
                    operation: prepared.operationName ?? prepared.request.operation.rawValue,
                    submitted: false,
                    requiresRefresh: false,
                    counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                    errorCategory: .conflict,
                    diagnosticTag: "file-station.copy-move.target-busy"
                ),
                sourcePath: prepared.sourcePath,
                destinationPath: prepared.destinationPath,
                item: nil
            )
        }
        activeFileItemMutationPaths.formUnion(paths)
        defer { activeFileItemMutationPaths.subtract(paths) }

        let dependencies = FileCopyMoveMutationDependencies(
            checkWritePermission: { [weak self] folderPath, filename in
                guard let self else { throw CancellationError() }
                try await self.checkWritePermission(
                    folderPath: folderPath,
                    filename: filename,
                    createOnly: true
                )
            },
            submit: { [weak self] prepared, progress in
                guard let self else {
                    throw FileCopyMoveSubmissionFailure.cancelled(taskAccepted: false)
                }
                try await self.submitCopyMove(
                    prepared,
                    capability: capability,
                    progress: progress
                )
            },
            readItems: { [weak self] paths in
                guard let self else { throw CancellationError() }
                return try await self.getInfo(paths: paths)
            }
        )
        return try await FileCopyMoveMutationCoordinator.shared.perform(
            prepared,
            dependencies: dependencies,
            progress: progress
        )
    }

    private func submitCopyMove(
        _ prepared: FileCopyMovePreparedRequest,
        capability: ApiCapability,
        progress: @escaping FileTransferProgress
    ) async throws {
        if Task.isCancelled {
            throw FileCopyMoveSubmissionFailure.cancelled(taskAccepted: false)
        }
        var taskAccepted = false
        do {
            let start = try await client.call(
                path: capability.path,
                api: capability.name,
                version: 3,
                method: "start",
                requestFormat: .form,
                parameters: [
                    "path": .stringArray([prepared.sourcePath]),
                    "dest_folder_path": .string(prepared.destinationFolderPath),
                    "remove_src": .boolean(prepared.request.operation == .move),
                    "overwrite": .boolean(false),
                    "accurate_progress": .boolean(true)
                ],
                credential: credential,
                as: TaskStartPayload.self
            )
            taskAccepted = true
            try await pollTask(
                capability: capability,
                taskID: start.taskid,
                progress: progress
            )
        } catch let error as DsmNetworkError {
            if case .cancelled = error {
                throw FileCopyMoveSubmissionFailure.cancelled(taskAccepted: true)
            }
            throw FileCopyMoveSubmissionFailure.network(error, taskAccepted: taskAccepted)
        } catch is CancellationError {
            throw FileCopyMoveSubmissionFailure.cancelled(taskAccepted: true)
        } catch {
            throw FileCopyMoveSubmissionFailure.unexpected(taskAccepted: true)
        }
    }

    private func submitMoveToRecycle(
        _ prepared: FileRecyclePreparedRequest,
        capability: ApiCapability,
        progress: @escaping FileTransferProgress
    ) async throws {
        if Task.isCancelled {
            throw FileRecycleSubmissionFailure.cancelled(taskAccepted: false)
        }
        var taskAccepted = false
        do {
            let start = try await client.call(
                path: capability.path,
                api: capability.name,
                version: 2,
                method: "start",
                requestFormat: .form,
                parameters: [
                    "path": .stringArray([prepared.sourcePath]),
                    "recursive": .boolean(true),
                    "accurate_progress": .boolean(true),
                ],
                credential: credential,
                as: TaskStartPayload.self
            )
            taskAccepted = true
            try await pollTask(
                capability: capability,
                taskID: start.taskid,
                progress: progress
            )
        } catch let error as DsmNetworkError {
            if case .cancelled = error {
                throw FileRecycleSubmissionFailure.cancelled(taskAccepted: true)
            }
            throw FileRecycleSubmissionFailure.network(error, taskAccepted: taskAccepted)
        } catch is CancellationError {
            throw FileRecycleSubmissionFailure.cancelled(taskAccepted: true)
        } catch {
            throw FileRecycleSubmissionFailure.unexpected(taskAccepted: true)
        }
    }

    private func copyMove(
        paths: [String],
        to destinationFolder: String,
        overwrite: Bool,
        removeSource: Bool,
        progress: @escaping FileTransferProgress
    ) async throws {
        guard !paths.isEmpty else {
            return
        }
        let capability = try requireCapability(DsmAPIName.fileStationCopyMove)
        do {
            let start = try await client.call(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "start",
                requestFormat: capability.requestFormat,
                parameters: [
                    "path": .stringArray(paths),
                    "dest_folder_path": .string(destinationFolder),
                    "remove_src": .boolean(removeSource),
                    "overwrite": .boolean(overwrite),
                    "accurate_progress": .boolean(true)
                ],
                credential: credential,
                as: TaskStartPayload.self
            )
            try await pollTask(capability: capability, taskID: start.taskid, progress: progress)
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    public func compress(
        paths: [String],
        destinationFilePath: String,
        format: ArchiveFormat,
        level: ArchiveCompressionLevel,
        password: String?,
        progress: @escaping FileTransferProgress
    ) async throws {
        guard !paths.isEmpty else { return }
        let capability = try requireCapability(DsmAPIName.fileStationCompress)
        guard try selectedVersion(capability) >= 3 else {
            throw AppError(
                category: .versionUnsupported,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.a6d04a723fffe229")
            )
        }
        do {
            var parameters: [String: DsmParameterValue] = [
                "path": .stringArray(paths),
                "dest_file_path": .string(destinationFilePath),
                "level": .string(level.rawValue),
                "mode": .string("add"),
                "format": .string(format.rawValue)
            ]
            if let password, !password.isEmpty {
                parameters["password"] = .string(password)
            }
            let start = try await client.call(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "start",
                requestFormat: capability.requestFormat,
                parameters: parameters,
                credential: credential,
                as: TaskStartPayload.self
            )
            try await pollTask(capability: capability, taskID: start.taskid, progress: progress)
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    public func extract(
        filePath: String,
        destinationFolder: String,
        overwrite: Bool,
        keepDirectoryStructure: Bool,
        createSubfolder: Bool,
        codepage: String?,
        password: String?,
        progress: @escaping FileTransferProgress
    ) async throws {
        let capability = try requireCapability(DsmAPIName.fileStationExtract)
        guard try selectedVersion(capability) >= 2 else {
            throw AppError(
                category: .versionUnsupported,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.dc01e0e93254c384")
            )
        }
        do {
            var parameters: [String: DsmParameterValue] = [
                "file_path": .string(filePath),
                "dest_folder_path": .string(destinationFolder),
                "overwrite": .boolean(overwrite),
                "keep_dir": .boolean(keepDirectoryStructure),
                "create_subfolder": .boolean(createSubfolder)
            ]
            if let codepage, !codepage.isEmpty {
                parameters["codepage"] = .string(codepage)
            }
            if let password, !password.isEmpty {
                parameters["password"] = .string(password)
            }
            let start = try await client.call(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "start",
                requestFormat: capability.requestFormat,
                parameters: parameters,
                credential: credential,
                as: TaskStartPayload.self
            )
            try await pollTask(capability: capability, taskID: start.taskid, progress: progress)
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    public func listArchiveItems(
        filePath: String,
        codepage: String?,
        password: String?
    ) async throws -> [ArchiveItem] {
        let capability = try requireCapability(DsmAPIName.fileStationExtract)
        guard try selectedVersion(capability) >= 2 else {
            throw AppError(
                category: .versionUnsupported,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.740aa171913b9fac")
            )
        }
        do {
            var parameters: [String: DsmParameterValue] = [
                "file_path": .string(filePath),
                "offset": .integer(0),
                "limit": .integer(200),
                "sort_by": .string("name"),
                "sort_direction": .string("asc"),
                "item_id": .integer(-1)
            ]
            if let codepage, !codepage.isEmpty {
                parameters["codepage"] = .string(codepage)
            }
            if let password, !password.isEmpty {
                parameters["password"] = .string(password)
            }
            let payload = try await client.call(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "list",
                requestFormat: capability.requestFormat,
                parameters: parameters,
                credential: credential,
                as: ArchiveListPayload.self
            )
            return (payload.items ?? []).map {
                ArchiveItem(id: $0.itemid, name: $0.name, path: $0.path, isDirectory: $0.isDirectory)
            }
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    private func pollTask(
        capability: ApiCapability,
        taskID: String,
        progress: @escaping FileTransferProgress
    ) async throws {
        var delay = 500_000_000
        do {
            while true {
                try Task.checkCancellation()
                let status = try await client.call(
                    path: capability.path,
                    api: capability.name,
                    version: try selectedVersion(capability),
                    method: "status",
                    requestFormat: capability.requestFormat,
                    parameters: ["taskid": .string(taskID)],
                    credential: credential,
                    as: TaskStatusPayload.self
                )
                let completed = status.processedSize ?? status.progress ?? 0
                progress(completed, status.total)
                if status.finished {
                    return
                }
                try await Task.sleep(nanoseconds: UInt64(delay))
                delay = min(delay * 2, 2_000_000_000)
            }
        } catch {
            if Task.isCancelled {
                let version = try selectedVersion(capability)
                let pollingClient = client
                let pollingCredential = credential
                let stopTask = Task.detached {
                    try? await pollingClient.callVoid(
                        path: capability.path,
                        api: capability.name,
                        version: version,
                        method: "stop",
                        requestFormat: capability.requestFormat,
                        parameters: ["taskid": .string(taskID)],
                        credential: pollingCredential
                    )
                }
                await stopTask.value
            }
            throw error
        }
    }

    private func listParameters(
        offset: Int,
        limit: Int,
        options: FileListOptions = .default,
        includesTypeFilter: Bool = false
    ) -> [String: DsmParameterValue] {
        var parameters: [String: DsmParameterValue] = [
            "offset": .integer(offset),
            "limit": .integer(limit),
            "sort_by": .string(Self.listSortField(options.sortField)),
            "sort_direction": .string(Self.listSortDirection(options.sortDirection)),
            "additional": .stringArray(Self.additionalFields)
        ]
        if includesTypeFilter {
            switch options.typeFilter {
            case .all:
                break
            case .files:
                parameters["filetype"] = .string("file")
            case .folders:
                parameters["filetype"] = .string("dir")
            }
        }
        return parameters
    }

    private static func listSortField(_ field: FileListSortField) -> String {
        switch field {
        case .name: "name"
        case .size: "size"
        case .modifiedTime: "mtime"
        }
    }

    private static func listSortDirection(_ direction: FileListSortDirection) -> String {
        switch direction {
        case .ascending: "asc"
        case .descending: "desc"
        }
    }

    private func makeFileItem(_ payload: FilePayload) -> FileItem {
        let rawType = payload.additional?.type
        let kind: FileKind
        if rawType?.lowercased().contains("link") == true {
            kind = .symlink
        } else {
            kind = payload.isDirectory ? .directory : .file
        }

        let rights = payload.additional?.perm?.advRight ?? [:]
        let permissions = FilePermissions(
            canRead: rights["read"] ?? rights["download"] ?? true,
            canWrite: rights["write"] ?? rights["upload"] ?? false,
            canDelete: rights["delete"] ?? false,
            posixMode: payload.additional?.perm?.posix
        )
        let time = payload.additional?.time
        let times = FileTimes(
            modifiedAt: time?.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            createdAt: time?.crtime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            accessedAt: time?.atime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
        let fileExtension = URL(fileURLWithPath: payload.name).pathExtension.lowercased()
        let thumbnail = [
            "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp",
            "mp4", "m4v", "mov", "avi", "mkv", "webm", "mpeg", "mpg"
        ]
            .contains(fileExtension)

        return FileItem(
            profileID: profileID,
            name: payload.name,
            path: payload.path,
            kind: kind,
            sizeBytes: payload.additional?.size,
            fileExtension: fileExtension,
            owner: payload.additional?.owner?.user,
            group: payload.additional?.owner?.group,
            times: times,
            permissions: permissions,
            thumbnailAvailable: thumbnail,
            rawType: rawType,
            mountPointType: payload.additional?.mountPointType
        )
    }

    public func search(folderPath: String, query: String) async throws -> [FileItem] {
        let capability = try requireCapability(DsmAPIName.fileStationSearch)
        let start = try await client.call(
            path: capability.path,
            api: capability.name,
            version: try selectedVersion(capability),
            method: "start",
            requestFormat: capability.requestFormat,
            parameters: [
                "folder_path": .string(folderPath),
                "pattern": .string(query),
                "recursive": .boolean(true),
                "search_content": .boolean(false)
            ],
            credential: credential,
            as: TaskStartPayload.self
        )
        do {
            var delay: UInt64 = 250_000_000
            while true {
                try Task.checkCancellation()
                let payload = try await client.call(
                    path: capability.path,
                    api: capability.name,
                    version: try selectedVersion(capability),
                    method: "list",
                    requestFormat: capability.requestFormat,
                    parameters: [
                        "taskid": .string(start.taskid),
                        "offset": .integer(0),
                        "limit": .integer(2_000),
                        "additional": .stringArray(Self.additionalFields)
                    ],
                    credential: credential,
                    as: SearchListPayload.self
                )
                if payload.finished == true {
                    var files = payload.files ?? []
                    let total = payload.total ?? files.count
                    var offset = files.count
                    while offset < total {
                        try Task.checkCancellation()
                        let nextPage = try await client.call(
                            path: capability.path,
                            api: capability.name,
                            version: try selectedVersion(capability),
                            method: "list",
                            requestFormat: capability.requestFormat,
                            parameters: [
                                "taskid": .string(start.taskid),
                                "offset": .integer(offset),
                                "limit": .integer(2_000),
                                "additional": .stringArray(Self.additionalFields)
                            ],
                            credential: credential,
                            as: SearchListPayload.self
                        )
                        let pageFiles = nextPage.files ?? []
                        guard !pageFiles.isEmpty else { break }
                        files.append(contentsOf: pageFiles)
                        offset += pageFiles.count
                    }
                    try? await cleanSearch(capability: capability, taskID: start.taskid)
                    return files.map(makeFileItem)
                }
                try await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 1_000_000_000)
            }
        } catch {
            try? await stopSearch(capability: capability, taskID: start.taskid)
            throw translate(error)
        }
    }

    public func calculateDirectorySize(path: String) async throws -> FileDirectorySizeSummary {
        try Task.checkCancellation()
        let capability = try requireCapability(DsmAPIName.fileStationDirSize)
        let normalizedPath = try Self.normalizedDirectorySizePath(path)
        guard activeDirectorySizePaths.insert(normalizedPath).inserted else {
            throw AppError(
                category: .conflict,
                isRetryable: true,
                safeUserMessage: L10n.string("dirsize.already-running")
            )
        }
        defer { activeDirectorySizePaths.remove(normalizedPath) }

        let start: TaskStartPayload
        do {
            start = try await client.call(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "start",
                requestFormat: capability.requestFormat,
                parameters: ["path": .stringArray([normalizedPath])],
                credential: credential,
                as: TaskStartPayload.self
            )
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            if let error = error as? DsmNetworkError {
                throw DsmErrorMapper.map(error)
            }
            throw translate(error)
        }

        guard Self.normalizedBackgroundTaskID(start.taskid) == start.taskid else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: true,
                safeUserMessage: L10n.string("dirsize.invalid-response")
            )
        }

        var taskFinished = false
        do {
            var delay = directorySizePollingPolicy.initialDelayNanoseconds
            for attempt in 0..<max(1, directorySizePollingPolicy.maxAttempts) {
                try Task.checkCancellation()
                let status = try await client.call(
                    path: capability.path,
                    api: capability.name,
                    version: try selectedVersion(capability),
                    method: "status",
                    requestFormat: capability.requestFormat,
                    parameters: ["taskid": .string(start.taskid)],
                    credential: credential,
                    as: DirectorySizeStatusPayload.self
                )
                if status.finished {
                    taskFinished = true
                    guard let totalBytes = status.totalBytes,
                          let fileCount = status.fileCount,
                          let directoryCount = status.directoryCount,
                          totalBytes >= 0,
                          fileCount >= 0,
                          directoryCount >= 0,
                          fileCount <= Int64(Int.max),
                          directoryCount <= Int64(Int.max) else {
                        throw AppError(
                            category: .invalidResponse,
                            isRetryable: true,
                            safeUserMessage: L10n.string("dirsize.invalid-response")
                        )
                    }
                    return FileDirectorySizeSummary(
                        totalBytes: totalBytes,
                        fileCount: Int(fileCount),
                        directoryCount: Int(directoryCount)
                    )
                }

                guard attempt + 1 < max(1, directorySizePollingPolicy.maxAttempts) else {
                    throw AppError(
                        category: .timeout,
                        isRetryable: true,
                        safeUserMessage: L10n.string("dirsize.timeout")
                    )
                }
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay)
                }
                let doubledDelay = max(delay, 1).multipliedReportingOverflow(by: 2)
                delay = min(
                    doubledDelay.overflow ? UInt64.max : doubledDelay.partialValue,
                    max(directorySizePollingPolicy.maximumDelayNanoseconds, 1)
                )
            }
            throw AppError(
                category: .timeout,
                isRetryable: true,
                safeUserMessage: L10n.string("dirsize.timeout")
            )
        } catch {
            if !taskFinished {
                await stopDirectorySizeTask(capability: capability, taskID: start.taskid)
            }
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            if let error = error as? DsmNetworkError {
                throw DsmErrorMapper.map(error)
            }
            throw translate(error)
        }
    }

    public func fileMD5(remotePath: String) async throws -> String {
        let capability = try requireCapability(DsmAPIName.fileStationMD5)
        let start = try await client.call(
            path: capability.path,
            api: capability.name,
            version: try selectedVersion(capability),
            method: "start",
            requestFormat: capability.requestFormat,
            parameters: ["file_path": .string(remotePath)],
            credential: credential,
            as: TaskStartPayload.self
        )

        do {
            var delay: UInt64 = 250_000_000
            while true {
                try Task.checkCancellation()
                let status = try await client.call(
                    path: capability.path,
                    api: capability.name,
                    version: try selectedVersion(capability),
                    method: "status",
                    requestFormat: capability.requestFormat,
                    parameters: ["taskid": .string(start.taskid)],
                    credential: credential,
                    as: FileMD5StatusPayload.self
                )
                if status.finished {
                    guard let value = status.md5?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !value.isEmpty else {
                        throw AppError(
                            category: .invalidResponse,
                            isRetryable: true,
                            safeUserMessage: L10n.string("shared.ddcb8aa6d1e5322c")
                        )
                    }
                    return value.lowercased()
                }
                try await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 1_000_000_000)
            }
        } catch {
            try? await client.callVoid(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "stop",
                requestFormat: capability.requestFormat,
                parameters: ["taskid": .string(start.taskid)],
                credential: credential
            )
            throw translate(error)
        }
    }

    private func stopDirectorySizeTask(capability: ApiCapability, taskID: String) async {
        guard let version = try? selectedVersion(capability) else { return }
        let pollingClient = client
        let pollingCredential = credential
        let stopTask = Task.detached {
            try? await pollingClient.callVoid(
                path: capability.path,
                api: capability.name,
                version: version,
                method: "stop",
                requestFormat: capability.requestFormat,
                parameters: ["taskid": .string(taskID)],
                credential: pollingCredential
            )
        }
        await stopTask.value
    }

    private func cleanSearch(capability: ApiCapability, taskID: String) async throws {
        try await client.callVoid(
            path: capability.path,
            api: capability.name,
            version: try selectedVersion(capability),
            method: "clean",
            requestFormat: capability.requestFormat,
            parameters: ["taskid": .string(taskID)],
            credential: credential
        )
    }

    private func stopSearch(capability: ApiCapability, taskID: String) async throws {
        try await client.callVoid(
            path: capability.path,
            api: capability.name,
            version: try selectedVersion(capability),
            method: "stop",
            requestFormat: capability.requestFormat,
            parameters: ["taskid": .string(taskID)],
            credential: credential
        )
    }

    public func listFavorites() async throws -> [FavoriteLocation] {
        try await listFavoritesPage(offset: 0, limit: Self.favoriteSnapshotLimit).locations
    }

    public func listFavoritesPage(offset: Int, limit: Int) async throws -> FileFavoritePage {
        let capability = try requireCapability(DsmAPIName.fileStationFavorite)
        guard capability.minVersion <= 2, capability.maxVersion >= 2 else {
            throw AppError(
                category: .versionUnsupported,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.03e86493986f245a")
            )
        }
        let requestedOffset = min(max(0, offset), Self.favoriteSnapshotLimit)
        let remainingCapacity = Self.favoriteSnapshotLimit - requestedOffset
        let requestedLimit = remainingCapacity == 0 ? 0 : min(max(1, limit), remainingCapacity)
        var rawOffset = 0
        var expectedTotal: Int?
        var metadataMode: Bool?
        var sourceTotal = 0
        var isTruncated = false
        var seenPaths = Set<String>()
        var orderedLocations: [FavoriteLocation] = []

        do {
            while rawOffset < Self.favoriteSnapshotLimit {
                try Task.checkCancellation()
                let boundedRemaining = expectedTotal.map {
                    max(0, min($0, Self.favoriteSnapshotLimit) - rawOffset)
                } ?? (Self.favoriteSnapshotLimit - rawOffset)
                guard boundedRemaining > 0 else { break }
                let requestLimit = min(Self.favoriteRequestLimit, boundedRemaining)
                let payload = try await client.call(
                    path: capability.path,
                    api: capability.name,
                    version: 2,
                    method: "list",
                    requestFormat: capability.requestFormat,
                    parameters: [
                        "offset": .integer(rawOffset),
                        "limit": .integer(requestLimit)
                    ],
                    credential: credential,
                    as: FavoritePagePayload.self
                )
                try Task.checkCancellation()
                guard payload.favorites.count <= requestLimit else {
                    throw Self.invalidFileLocationResponse()
                }

                let hasMetadata = payload.offset != nil
                if let metadataMode {
                    guard metadataMode == hasMetadata else {
                        throw Self.invalidFileLocationResponse()
                    }
                } else {
                    metadataMode = hasMetadata
                }
                if let responseOffset = payload.offset, let responseTotal = payload.total {
                    guard responseOffset == rawOffset else {
                        throw Self.invalidFileLocationResponse()
                    }
                    if let expectedTotal {
                        guard responseTotal == expectedTotal else {
                            throw Self.invalidFileLocationResponse()
                        }
                    } else {
                        expectedTotal = responseTotal
                    }
                    let boundedTotal = min(responseTotal, Self.favoriteSnapshotLimit)
                    if payload.favorites.isEmpty, rawOffset < boundedTotal {
                        throw Self.invalidFileLocationResponse()
                    }
                }

                for favorite in payload.favorites {
                    let canonicalPath = try Self.canonicalFileLocationPath(favorite.path)
                    let suppliedName = favorite.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedName = suppliedName?.isEmpty == false
                        ? suppliedName!
                        : String(canonicalPath.split(separator: "/").last ?? "")
                    guard !resolvedName.isEmpty, resolvedName.utf8.count <= 1_024 else {
                        throw Self.invalidFileLocationResponse()
                    }
                    if seenPaths.insert(canonicalPath).inserted {
                        orderedLocations.append(FavoriteLocation(
                            name: resolvedName,
                            path: canonicalPath
                        ))
                    }
                }

                let nextOffset = rawOffset + payload.favorites.count
                guard nextOffset <= Self.favoriteSnapshotLimit else {
                    throw Self.invalidFileLocationResponse()
                }
                sourceTotal = nextOffset
                if let expectedTotal {
                    let boundedTotal = min(expectedTotal, Self.favoriteSnapshotLimit)
                    guard nextOffset <= boundedTotal else {
                        throw Self.invalidFileLocationResponse()
                    }
                    if nextOffset >= boundedTotal {
                        sourceTotal = expectedTotal
                        isTruncated = expectedTotal > Self.favoriteSnapshotLimit
                        break
                    }
                    guard nextOffset > rawOffset else {
                        throw Self.invalidFileLocationResponse()
                    }
                } else {
                    if payload.favorites.count < requestLimit {
                        break
                    }
                    if nextOffset == Self.favoriteSnapshotLimit {
                        isTruncated = true
                        break
                    }
                    guard nextOffset > rawOffset else {
                        break
                    }
                }
                rawOffset = nextOffset
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DsmNetworkError {
            let mapped = DsmErrorMapper.map(error)
            if mapped.category == .cancelled { throw CancellationError() }
            throw mapped
        }

        let boundedLocations = Array(orderedLocations.prefix(Self.favoriteSnapshotLimit))
        let start = min(requestedOffset, boundedLocations.count)
        let end = min(start + requestedLimit, boundedLocations.count)
        return FileFavoritePage(
            locations: Array(boundedLocations[start..<end]),
            offset: start,
            nextOffset: end,
            total: boundedLocations.count,
            sourceTotal: sourceTotal,
            hasMore: end < boundedLocations.count,
            isTruncated: isTruncated
        )
    }

    public func addFavorite(path: String, name: String) async throws {
        let capability = try requireCapability(DsmAPIName.fileStationFavorite)
        try await client.callVoid(
            path: capability.path,
            api: capability.name,
            version: try selectedVersion(capability),
            method: "add",
            requestFormat: capability.requestFormat,
            parameters: ["path": .string(path), "name": .string(name)],
            credential: credential
        )
    }

    /// 收藏是统一写操作结果模型的低影响试点；旧方法保持不变，调用方可逐步迁移。
    public func addFavoriteResult(
        path: String,
        name: String
    ) async throws -> MutationResult {
        let operation = "favoriteAdd"
        if Task.isCancelled {
            return try makeMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "file-station.favorite.add.cancelled-before-submission"
            )
        }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"),
              path.count > 1,
              !normalizedName.isEmpty else {
            return try makeMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                diagnosticTag: "file-station.favorite.add.invalid-input"
            )
        }
        guard let capability = capabilities[DsmAPIName.fileStationFavorite],
              let version = capability.selectedVersion else {
            return try makeMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                diagnosticTag: "file-station.favorite.add.unsupported"
            )
        }

        do {
            try await client.callVoid(
                path: capability.path,
                api: capability.name,
                version: version,
                method: "add",
                requestFormat: capability.requestFormat,
                parameters: [
                    "path": .string(path),
                    "name": .string(normalizedName),
                ],
                credential: credential
            )
        } catch let error as DsmNetworkError {
            return try mutationResultForFavoriteSubmissionError(
                error,
                operation: operation
            )
        } catch {
            return try makeMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: .unknown,
                diagnosticTag: "file-station.favorite.add.submission-unknown"
            )
        }

        if Task.isCancelled {
            return try makeMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                diagnosticTag: "file-station.favorite.add.cancelled-after-submission"
            )
        }

        do {
            let favorites = try await listFavorites()
            guard favorites.contains(where: { $0.path == path }) else {
                return try makeMutationResult(
                    status: .confirmedFailure,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: false,
                    succeeded: 0,
                    failed: 1,
                    unknown: 0,
                    errorCategory: .server,
                    diagnosticTag: "file-station.favorite.add.readback-mismatch"
                )
            }
            return try makeMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 1,
                failed: 0,
                unknown: 0,
                diagnosticTag: "file-station.favorite.add.confirmed"
            )
        } catch let error as DsmNetworkError {
            return try mutationResultForFavoriteReadbackError(
                DsmErrorMapper.map(error),
                operation: operation
            )
        } catch let error as AppError {
            return try mutationResultForFavoriteReadbackError(
                error,
                operation: operation
            )
        } catch {
            return try makeMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: .unknown,
                diagnosticTag: "file-station.favorite.add.readback-unknown"
            )
        }
    }

    public func removeFavorite(path: String) async throws {
        let capability = try requireCapability(DsmAPIName.fileStationFavorite)
        try await client.callVoid(
            path: capability.path,
            api: capability.name,
            version: try selectedVersion(capability),
            method: "delete",
            requestFormat: capability.requestFormat,
            parameters: ["path": .string(path)],
            credential: credential
        )
    }

    private func mutationResultForFavoriteSubmissionError(
        _ error: DsmNetworkError,
        operation: String
    ) throws -> MutationResult {
        let mapped = DsmErrorMapper.map(error)
        switch error {
        case .invalidRequest:
            return try makeMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                diagnosticTag: "file-station.favorite.add.invalid-request"
            )
        case .api, .httpStatus:
            let status: MutationResultStatus = switch mapped.category {
            case .permissionDenied, .authenticationRequired:
                .permissionDenied
            case .apiUnavailable, .versionUnsupported:
                .unsupported
            default:
                .confirmedFailure
            }
            return try makeMutationResult(
                status: status,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: mutationErrorCategory(for: mapped.category),
                diagnosticTag: "file-station.favorite.add.rejected"
            )
        case .cancelled:
            return try makeMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                diagnosticTag: "file-station.favorite.add.cancelled-after-submission"
            )
        case .transport, .responseTooLarge, .invalidResponse:
            return try makeMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: mutationErrorCategory(for: mapped.category),
                diagnosticTag: "file-station.favorite.add.submitted-unverified"
            )
        }
    }

    private func mutationResultForFavoriteReadbackError(
        _ error: AppError,
        operation: String
    ) throws -> MutationResult {
        let status: MutationResultStatus = error.category == .cancelled
            ? .cancellationRequestedAfterSubmission
            : .submittedButUnverified
        return try makeMutationResult(
            status: status,
            operation: operation,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: 1,
            errorCategory: mutationErrorCategory(for: error.category),
            diagnosticTag: "file-station.favorite.add.readback-unverified"
        )
    }

    private func mutationResultForDeleteSubmissionError(
        _ error: DsmNetworkError,
        operation: String,
        itemCount: Int
    ) throws -> MutationResult {
        let mapped = DsmErrorMapper.map(error)
        switch error {
        case .invalidRequest:
            return try makeMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: itemCount,
                unknown: 0,
                errorCategory: .validation,
                diagnosticTag: "file-station.delete.invalid-request"
            )
        case .api:
            let status: MutationResultStatus = switch mapped.category {
            case .permissionDenied, .authenticationRequired:
                .permissionDenied
            case .apiUnavailable, .versionUnsupported:
                .unsupported
            default:
                .confirmedFailure
            }
            return try makeMutationResult(
                status: status,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: itemCount,
                unknown: 0,
                errorCategory: mutationErrorCategory(for: mapped.category),
                diagnosticTag: "file-station.delete.rejected"
            )
        case .httpStatus(let code, _):
            if 400..<500 ~= code {
                let status: MutationResultStatus =
                    mapped.category == .permissionDenied
                    || mapped.category == .authenticationRequired
                    ? .permissionDenied
                    : .confirmedFailure
                return try makeMutationResult(
                    status: status,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: false,
                    succeeded: 0,
                    failed: itemCount,
                    unknown: 0,
                    errorCategory: mutationErrorCategory(for: mapped.category),
                    diagnosticTag: "file-station.delete.http-rejected"
                )
            }
            return try makeMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: itemCount,
                errorCategory: mutationErrorCategory(for: mapped.category),
                diagnosticTag: "file-station.delete.http-unverified"
            )
        case .cancelled:
            return try makeMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: itemCount,
                diagnosticTag: "file-station.delete.cancelled-during-submission"
            )
        case .transport, .responseTooLarge, .invalidResponse:
            return try makeMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: itemCount,
                errorCategory: mutationErrorCategory(for: mapped.category),
                diagnosticTag: "file-station.delete.submitted-unverified"
            )
        }
    }

    private func verifyDeletedPaths(
        _ paths: [String],
        operation: String
    ) async throws -> MutationResult {
        var succeeded = 0
        var failed = 0
        var unknown = 0

        for (index, path) in paths.enumerated() {
            if Task.isCancelled {
                unknown += paths.count - index
                return try makeMutationResult(
                    status: .cancellationRequestedAfterSubmission,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: succeeded,
                    failed: failed,
                    unknown: unknown,
                    diagnosticTag: "file-station.delete.cancelled-during-readback"
                )
            }
            do {
                let items = try await getInfo(paths: [path])
                if items.contains(where: { $0.path == path }) {
                    failed += 1
                } else {
                    succeeded += 1
                }
            } catch let error as AppError {
                if error.category == .notFound {
                    succeeded += 1
                } else if error.category == .cancelled || Task.isCancelled {
                    unknown += paths.count - index
                    return try makeMutationResult(
                        status: .cancellationRequestedAfterSubmission,
                        operation: operation,
                        submitted: true,
                        requiresRefresh: true,
                        succeeded: succeeded,
                        failed: failed,
                        unknown: unknown,
                        errorCategory: mutationErrorCategory(for: error.category),
                        diagnosticTag: "file-station.delete.cancelled-during-readback"
                    )
                } else {
                    unknown += 1
                }
            } catch is CancellationError {
                unknown += paths.count - index
                return try makeMutationResult(
                    status: .cancellationRequestedAfterSubmission,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: succeeded,
                    failed: failed,
                    unknown: unknown,
                    diagnosticTag: "file-station.delete.cancelled-during-readback"
                )
            } catch {
                unknown += 1
            }
        }

        if unknown > 0 {
            return try makeMutationResult(
                status: succeeded > 0 ? .partialSuccess : .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: succeeded,
                failed: failed,
                unknown: unknown,
                errorCategory: .unknown,
                diagnosticTag: "file-station.delete.readback-unverified"
            )
        }
        if failed > 0 {
            return try makeMutationResult(
                status: succeeded > 0 ? .partialSuccess : .confirmedFailure,
                operation: operation,
                submitted: true,
                requiresRefresh: succeeded > 0,
                succeeded: succeeded,
                failed: failed,
                unknown: 0,
                errorCategory: .server,
                diagnosticTag: succeeded > 0
                    ? "file-station.delete.partial"
                    : "file-station.delete.readback-mismatch"
            )
        }
        return try makeMutationResult(
            status: .confirmedSuccess,
            operation: operation,
            submitted: true,
            requiresRefresh: false,
            succeeded: succeeded,
            failed: 0,
            unknown: 0,
            diagnosticTag: "file-station.delete.confirmed"
        )
    }

    private static func isValidDeletionPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1 else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func deletionPathsOverlap(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        lhs == rhs
            || lhs.hasPrefix(rhs + "/")
            || rhs.hasPrefix(lhs + "/")
    }

    private func makeMutationResult(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory? = nil,
        diagnosticTag: String
    ) throws -> MutationResult {
        try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: MutationResultCounts(
                succeeded: succeeded,
                failed: failed,
                unknown: unknown
            ),
            errorCategory: errorCategory,
            diagnosticTag: diagnosticTag
        )
    }

    private func mutationErrorCategory(
        for category: AppErrorCategory
    ) -> MutationErrorCategory {
        switch category {
        case .authenticationRequired, .otpRequired:
            .authentication
        case .permissionDenied:
            .permission
        case .conflict:
            .conflict
        case .networkUnavailable, .timeout, .tlsUntrusted, .tlsCertificateChanged:
            .network
        case .apiUnavailable, .versionUnsupported:
            .unsupported
        case .invalidResponse, .serverBusy, .remoteStorageFull:
            .server
        case .notFound,
             .localStorageFull,
             .partialFailure,
             .cancelled,
             .unknown:
            .unknown
        }
    }

    public func listShareLinks() async throws -> [FileShareLink] {
        do {
            return try await loadAllShareLinks()
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        } catch let error as ShareLinkReadbackError {
            throw shareLinkContractAppError(error)
        }
    }

    public func listShareLinksPage(
        offset: Int,
        limit: Int
    ) async throws -> FileShareLinkPage {
        guard fileShareLinkAvailability.status == .available else {
            throw AppError(
                category: .apiUnavailable,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.7dc6f291445bfb76")
            )
        }
        guard offset >= 0, (1...500).contains(limit) else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.88223e41ac45d405")
            )
        }
        do {
            return try await fetchShareLinkPage(offset: offset, limit: limit)
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        } catch let error as ShareLinkReadbackError {
            throw shareLinkContractAppError(error)
        }
    }

    public func createShareLink(
        paths: [String],
        password: String?,
        expiresAt: String?
    ) async throws -> FileShareLink {
        guard paths.count == 1,
              let path = paths.first,
              let target = try await getInfo(paths: [path]).first(where: { $0.path == path }) else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.88223e41ac45d405")
            )
        }
        let expiration = try expiresAt.flatMap {
            $0.isEmpty ? nil : try FileShareLinkCalendarDate(iso8601: $0)
        }
        let outcome = try await createShareLinkResult(FileShareLinkCreateRequest(
            target: target,
            password: password,
            expiresOn: expiration
        ))
        guard outcome.result.status == .confirmedSuccess,
              let link = outcome.confirmedLink else {
            throw AppError(
                category: outcome.result.errorCategory == .permission
                    ? .permissionDenied
                    : .invalidResponse,
                isRetryable: outcome.result.requiresRefresh,
                safeUserMessage: L10n.string("shared.88223e41ac45d405")
            )
        }
        return link
    }

    public func createShareLinkResult(
        _ request: FileShareLinkCreateRequest
    ) async throws -> FileShareLinkCreateOutcome {
        let operation = "shareLinkCreate"
        if Task.isCancelled {
            return try shareLinkOutcome(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                diagnosticTag: "file-station.share-link.cancelled-before-submission"
            )
        }
        guard fileShareLinkAvailability.status == .available,
              let capability = capabilities[DsmAPIName.fileStationSharing],
              capability.selectedVersion == 3 else {
            return try shareLinkOutcome(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                failed: 1,
                errorCategory: .unsupported,
                diagnosticTag: "file-station.share-link.unsupported"
            )
        }
        guard request.target.profileID == profileID,
              let targetPath = Self.normalizedShareLinkPath(request.target.path),
              targetPath == request.target.path else {
            return try shareLinkOutcome(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                failed: 1,
                errorCategory: .validation,
                diagnosticTag: "file-station.share-link.invalid-target"
            )
        }
        guard !activeShareLinkPaths.contains(targetPath),
              !activeDeletionPaths.contains(where: {
                  Self.deletionPathsOverlap($0, targetPath)
              }) else {
            return try shareLinkOutcome(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                failed: 1,
                errorCategory: .conflict,
                diagnosticTag: "file-station.share-link.duplicate-submission"
            )
        }

        activeShareLinkPaths.insert(targetPath)
        defer { activeShareLinkPaths.remove(targetPath) }

        let observedTarget: FileItem
        do {
            guard let observed = try await getInfo(paths: [targetPath])
                .first(where: { $0.path == targetPath }) else {
                return try shareLinkOutcome(
                    status: .confirmedFailure,
                    operation: operation,
                    submitted: false,
                    requiresRefresh: false,
                    failed: 1,
                    errorCategory: .conflict,
                    diagnosticTag: "file-station.share-link.target-missing"
                )
            }
            observedTarget = observed
        } catch {
            return try shareLinkPreflightFailure(error, operation: operation)
        }
        guard Self.matchesShareLinkBaseline(observedTarget, request.target) else {
            return try shareLinkOutcome(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                failed: 1,
                errorCategory: .conflict,
                diagnosticTag: "file-station.share-link.baseline-changed"
            )
        }
        guard observedTarget.permissions?.canRead == true else {
            return try shareLinkOutcome(
                status: .permissionDenied,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                failed: 1,
                errorCategory: .permission,
                diagnosticTag: "file-station.share-link.target-unreadable"
            )
        }

        let existingIDs: Set<String>
        do {
            existingIDs = Set(try await loadAllShareLinks().map(\.id))
        } catch {
            return try shareLinkPreflightFailure(error, operation: operation)
        }
        if Task.isCancelled {
            return try shareLinkOutcome(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                diagnosticTag: "file-station.share-link.cancelled-after-preflight"
            )
        }

        var parameters: [String: DsmParameterValue] = [
            "path": .stringArray([targetPath])
        ]
        if let password = request.password {
            parameters["password"] = .string(password)
        }
        if let availableOn = request.availableOn {
            parameters["date_available"] = .string(availableOn.iso8601)
        }
        if let expiresOn = request.expiresOn {
            parameters["date_expired"] = .string(expiresOn.iso8601)
        }

        var candidateID: String?
        var submissionErrorCategory: MutationErrorCategory?
        do {
            let payload = try await client.call(
                path: capability.path,
                api: capability.name,
                version: 3,
                method: "create",
                requestFormat: capability.requestFormat,
                parameters: parameters,
                credential: credential,
                as: ShareCreatePayload.self
            )
            guard payload.links[0].error == 0 else {
                let isPermissionDenied = payload.links[0].error == 105
                return try shareLinkOutcome(
                    status: isPermissionDenied ? .permissionDenied : .confirmedFailure,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: false,
                    failed: 1,
                    errorCategory: isPermissionDenied ? .permission : .server,
                    diagnosticTag: "file-station.share-link.item-rejected"
                )
            }
            candidateID = Self.shareLinkCandidateID(payload, targetPath: targetPath)
        } catch let error as DsmNetworkError {
            switch error {
            case .invalidRequest:
                return try shareLinkOutcome(
                    status: .confirmedFailure,
                    operation: operation,
                    submitted: false,
                    requiresRefresh: false,
                    failed: 1,
                    errorCategory: .validation,
                    diagnosticTag: "file-station.share-link.invalid-request"
                )
            case .api:
                let mapped = DsmErrorMapper.map(error)
                return try shareLinkOutcome(
                    status: mapped.category == .permissionDenied ||
                        mapped.category == .authenticationRequired
                        ? .permissionDenied
                        : .confirmedFailure,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: false,
                    failed: 1,
                    errorCategory: mutationErrorCategory(for: mapped.category),
                    diagnosticTag: "file-station.share-link.rejected"
                )
            case .cancelled:
                return try shareLinkOutcome(
                    status: .cancellationRequestedAfterSubmission,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    unknown: 1,
                    diagnosticTag: "file-station.share-link.cancelled-after-submission"
                )
            case .httpStatus, .responseTooLarge, .invalidResponse, .transport:
                submissionErrorCategory = mutationErrorCategory(
                    for: DsmErrorMapper.map(error).category
                )
            }
        } catch is CancellationError {
            return try shareLinkOutcome(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                diagnosticTag: "file-station.share-link.cancelled-after-submission"
            )
        } catch {
            submissionErrorCategory = .unknown
        }

        if Task.isCancelled {
            return try shareLinkOutcome(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                diagnosticTag: "file-station.share-link.cancelled-before-readback"
            )
        }

        let currentLinks: [FileShareLink]
        do {
            currentLinks = try await loadAllShareLinks()
        } catch {
            let cancelled = Task.isCancelled ||
                (error as? DsmNetworkError).map {
                    if case .cancelled = $0 { return true }
                    return false
                } == true
            return try shareLinkOutcome(
                status: cancelled
                    ? .cancellationRequestedAfterSubmission
                    : .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                errorCategory: cancelled
                    ? nil
                    : submissionErrorCategory ?? .unknown,
                diagnosticTag: cancelled
                    ? "file-station.share-link.cancelled-during-readback"
                    : "file-station.share-link.readback-unverified"
            )
        }

        let confirmed: FileShareLink?
        if let candidateID {
            if existingIDs.contains(candidateID) {
                confirmed = nil
            } else {
                let matches = currentLinks.filter {
                    $0.id == candidateID &&
                        $0.path == targetPath &&
                        $0.hasPassword == (request.password != nil) &&
                        $0.expiresAt == request.expiresOn?.iso8601
                }
                confirmed = matches.count == 1 ? matches[0] : nil
            }
        } else {
            let matches = currentLinks.filter {
                !existingIDs.contains($0.id) &&
                    $0.path == targetPath &&
                    $0.hasPassword == (request.password != nil) &&
                    $0.expiresAt == request.expiresOn?.iso8601
            }
            confirmed = matches.count == 1 ? matches[0] : nil
        }
        guard let confirmed else {
            return try shareLinkOutcome(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                errorCategory: submissionErrorCategory,
                diagnosticTag: "file-station.share-link.readback-mismatch"
            )
        }
        return try shareLinkOutcome(
            status: .confirmedSuccess,
            operation: operation,
            submitted: true,
            requiresRefresh: false,
            succeeded: 1,
            diagnosticTag: "file-station.share-link.confirmed",
            confirmedLink: confirmed
        )
    }

    public func deleteShareLinks(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let capability = try requireCapability(DsmAPIName.fileStationSharing)
        try await client.callVoid(
            path: capability.path,
            api: capability.name,
            version: try selectedVersion(capability),
            method: "delete",
            requestFormat: capability.requestFormat,
            parameters: ["id": .stringArray(ids)],
            credential: credential
        )
    }

    public func storageSpaceSummary() async throws -> StorageSpaceSummary? {
        let capability = try requireCapability(DsmAPIName.fileStationList)
        do {
            var volumes: [String: (total: Int64, remaining: Int64)] = [:]
            let pageSize = 500
            let maximumShareCount = 10_000
            var offset = 0
            var expectedTotal: Int?
            while true {
                let payload = try await client.call(
                    path: capability.path,
                    api: capability.name,
                    version: try selectedVersion(capability),
                    method: "list_share",
                    requestFormat: capability.requestFormat,
                    parameters: listParameters(offset: offset, limit: pageSize),
                    credential: credential,
                    as: FileListPayload.self
                )
                let shares = payload.shares ?? []
                guard shares.count <= pageSize,
                      !payload.containsOffset || payload.offset != nil,
                      !payload.containsTotal || payload.total != nil,
                      (payload.offset ?? offset) == offset else {
                    throw Self.invalidStorageSpaceResponse()
                }
                if let total = payload.total {
                    guard total >= 0,
                          total <= maximumShareCount,
                          offset <= total,
                          shares.count <= total - offset,
                          expectedTotal == nil || expectedTotal == total else {
                        throw Self.invalidStorageSpaceResponse()
                    }
                    expectedTotal = total
                } else {
                    guard expectedTotal == nil, shares.count < pageSize else {
                        throw Self.invalidStorageSpaceResponse()
                    }
                }
                if shares.isEmpty, let expectedTotal, offset < expectedTotal {
                    throw Self.invalidStorageSpaceResponse()
                }
                for share in shares {
                    let mountType = share.additional?.mountPointType?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    if let mountType, !mountType.isEmpty,
                       mountType != "normal", mountType != "shared_folder" {
                        continue
                    }
                    guard let key = Self.volumeIdentity(realPath: share.additional?.realPath) else {
                        throw Self.invalidStorageSpaceResponse()
                    }
                    guard let status = share.additional?.volumeStatus,
                          let total = status.totalBytes,
                          let remaining = status.remainingBytes,
                          total > 0,
                          remaining >= 0,
                          remaining <= total else {
                        throw Self.invalidStorageSpaceResponse()
                    }
                    let capacity = (total: total, remaining: remaining)
                    if let existing = volumes[key], existing != capacity {
                        throw Self.invalidStorageSpaceResponse()
                    }
                    volumes[key] = capacity
                }
                offset += shares.count
                if let expectedTotal {
                    if offset == expectedTotal { break }
                } else {
                    break
                }
            }
            guard !volumes.isEmpty else { return nil }

            var totalBytes: Int64 = 0
            var remainingBytes: Int64 = 0
            for volume in volumes.values {
                let totalResult = totalBytes.addingReportingOverflow(volume.total)
                let remainingResult = remainingBytes.addingReportingOverflow(volume.remaining)
                guard !totalResult.overflow, !remainingResult.overflow else {
                    throw AppError(
                        category: .invalidResponse,
                        isRetryable: false,
                        safeUserMessage: L10n.string("shared.fbb16df36e02d491")
                    )
                }
                totalBytes = totalResult.partialValue
                remainingBytes = remainingResult.partialValue
            }
            return StorageSpaceSummary(
                totalBytes: totalBytes,
                remainingBytes: remainingBytes,
                volumeCount: volumes.count
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    public func createRemoteMount(_ configuration: RemoteMountConfiguration) async throws {
        let normalized = try Self.validateRemoteMount(configuration)
        try await mountRemote(normalized)
        try await verifyRemoteMount(at: normalized.mountPoint, shouldExist: true)
    }

    public func updateRemoteMount(
        existingMountPoint: String,
        configuration: RemoteMountConfiguration
    ) async throws {
        let currentMountPoint = try Self.validateMountPoint(existingMountPoint)
        let normalized = try Self.validateRemoteMount(configuration)

        if currentMountPoint != normalized.mountPoint {
            try await mountRemote(normalized)
            do {
                try await verifyRemoteMount(at: normalized.mountPoint, shouldExist: true)
                try await unmountRemote(at: currentMountPoint)
                try await verifyRemoteMount(at: currentMountPoint, shouldExist: false)
            } catch {
                try? await unmountRemote(at: normalized.mountPoint)
                throw error
            }
            return
        }

        try await unmountRemote(at: currentMountPoint)
        try await verifyRemoteMount(at: currentMountPoint, shouldExist: false)
        do {
            try await mountRemote(normalized)
            try await verifyRemoteMount(at: normalized.mountPoint, shouldExist: true)
        } catch {
            throw AppError(
                category: .unknown,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.090ae84e6f05b2a9")
            )
        }
    }

    public func removeRemoteMount(mountPoint: String) async throws {
        let normalized = try Self.validateMountPoint(mountPoint)
        try await unmountRemote(at: normalized)
        try await verifyRemoteMount(at: normalized, shouldExist: false)
    }

    private func mountRemote(_ configuration: RemoteMountConfiguration) async throws {
        let capability = try requireCapability(DsmAPIName.fileStationMount)
        let remoteSource: String
        switch configuration.protocolType {
        case .smb:
            remoteSource = "//\(configuration.server)/\(configuration.remotePath)"
        case .nfs:
            remoteSource = "\(configuration.server):/\(configuration.remotePath)"
        }
        var parameters: [String: DsmParameterValue] = [
            "mount_type": .string(configuration.protocolType.rawValue),
            "connection_type": .string(configuration.protocolType.rawValue),
            "remote_path": .string(remoteSource),
            "src_folder": .string(remoteSource),
            "server": .string(configuration.server),
            "remote_folder": .string(configuration.remotePath),
            "mount_point": .string(configuration.mountPoint),
            "dst_folder": .string(configuration.mountPoint),
            "read_only": .boolean(configuration.readOnly)
        ]
        if configuration.protocolType == .smb {
            parameters["username"] = .string(configuration.username)
            parameters["account"] = .string(configuration.username)
            parameters["password"] = .string(configuration.password)
            parameters["passwd"] = .string(configuration.password)
            if !configuration.domain.isEmpty {
                parameters["domain"] = .string(configuration.domain)
            }
        }
        do {
            try await client.callVoid(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "mount_remote",
                requestFormat: capability.requestFormat,
                parameters: parameters,
                credential: credential
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    private func unmountRemote(at mountPoint: String) async throws {
        let capability = try requireCapability(DsmAPIName.fileStationMount)
        do {
            try await client.callVoid(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability),
                method: "unmount",
                requestFormat: capability.requestFormat,
                parameters: [
                    "path": .string(mountPoint),
                    "mount_point": .string(mountPoint),
                    "folder_path": .string(mountPoint)
                ],
                credential: credential
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    private func verifyRemoteMount(at mountPoint: String, shouldExist: Bool) async throws {
        for attempt in 0..<4 {
            let items = try? await getInfo(paths: [mountPoint])
            let isMounted = items?.contains(where: Self.isRemoteMount) == true
            if isMounted == shouldExist { return }
            if attempt < 3 {
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        throw AppError(
            category: .invalidResponse,
            isRetryable: true,
            safeUserMessage: shouldExist
                ? L10n.string("shared.698b9393500e69d3")
                : L10n.string("shared.8d2b1428252accb0")
        )
    }

    private func makeShareLink(_ payload: ShareListItemPayload) -> FileShareLink {
        return FileShareLink(
            id: payload.id,
            name: payload.name ?? URL(fileURLWithPath: payload.path).lastPathComponent,
            path: payload.path,
            url: payload.url,
            hasPassword: payload.hasPassword,
            expiresAt: payload.expiresAt
        )
    }

    private func fetchShareLinkPage(
        offset: Int,
        limit: Int
    ) async throws -> FileShareLinkPage {
        guard let capability = capabilities[DsmAPIName.fileStationSharing],
              capability.selectedVersion == 3 else {
            throw ShareLinkReadbackError.invalidPage
        }
        let payload = try await client.call(
            path: capability.path,
            api: capability.name,
            version: 3,
            method: "list",
            requestFormat: capability.requestFormat,
            parameters: ["offset": .integer(offset), "limit": .integer(limit)],
            credential: credential,
            as: SharePagePayload.self
        )
        guard payload.offset == offset else {
            throw ShareLinkReadbackError.invalidPage
        }
        let links = payload.links.map(makeShareLink)
        guard Set(links.map(\.id)).count == links.count else {
            throw ShareLinkReadbackError.duplicateID
        }
        return FileShareLinkPage(
            links: links,
            offset: payload.offset,
            total: payload.total,
            hasMore: payload.offset + links.count < payload.total,
            isTruncated: payload.total > 5_000
        )
    }

    private func loadAllShareLinks() async throws -> [FileShareLink] {
        var links: [FileShareLink] = []
        var seenIDs = Set<String>()
        var expectedTotal: Int?
        var offset = 0
        while true {
            let page = try await fetchShareLinkPage(offset: offset, limit: 500)
            if page.isTruncated {
                throw ShareLinkReadbackError.truncated
            }
            if let expectedTotal, page.total != expectedTotal {
                throw ShareLinkReadbackError.totalDrift
            }
            expectedTotal = page.total
            for link in page.links {
                guard seenIDs.insert(link.id).inserted else {
                    throw ShareLinkReadbackError.duplicateID
                }
                links.append(link)
            }
            let nextOffset = page.offset + page.links.count
            guard nextOffset <= page.total else {
                throw ShareLinkReadbackError.invalidPage
            }
            if nextOffset == page.total {
                return links
            }
            guard nextOffset > offset else {
                throw ShareLinkReadbackError.zeroProgress
            }
            offset = nextOffset
        }
    }

    private static func shareLinkCandidateID(
        _ payload: ShareCreatePayload,
        targetPath: String
    ) -> String? {
        let item = payload.links[0]
        return item.error == 0 && item.path == targetPath ? item.id : nil
    }

    private static func normalizedShareLinkPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard trimmed.hasPrefix("/"), trimmed != "/", trimmed.utf8.count <= 4_096,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              components.dropFirst().allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            return nil
        }
        return trimmed
    }

    private static func matchesShareLinkBaseline(
        _ observed: FileItem,
        _ baseline: FileItem
    ) -> Bool {
        guard observed.profileID == baseline.profileID,
              observed.path == baseline.path,
              observed.name == baseline.name,
              observed.kind == baseline.kind,
              observed.owner == baseline.owner,
              observed.group == baseline.group,
              observed.permissions == baseline.permissions,
              observed.mountPointType == baseline.mountPointType else {
            return false
        }
        if observed.kind == .directory {
            return true
        }
        return observed.sizeBytes == baseline.sizeBytes &&
            observed.times?.modifiedAt == baseline.times?.modifiedAt
    }

    private func shareLinkPreflightFailure(
        _ error: Error,
        operation: String
    ) throws -> FileShareLinkCreateOutcome {
        let mapped: AppError
        if let appError = error as? AppError {
            mapped = appError
        } else if let networkError = error as? DsmNetworkError {
            mapped = DsmErrorMapper.map(networkError)
        } else if error is CancellationError {
            return try shareLinkOutcome(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                diagnosticTag: "file-station.share-link.cancelled-during-preflight"
            )
        } else {
            return try shareLinkOutcome(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                failed: 1,
                errorCategory: .unknown,
                diagnosticTag: "file-station.share-link.preflight-failed"
            )
        }
        if mapped.category == .cancelled || Task.isCancelled {
            return try shareLinkOutcome(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                diagnosticTag: "file-station.share-link.cancelled-during-preflight"
            )
        }
        let status: MutationResultStatus = switch mapped.category {
        case .permissionDenied, .authenticationRequired: .permissionDenied
        case .apiUnavailable, .versionUnsupported: .unsupported
        default: .confirmedFailure
        }
        return try shareLinkOutcome(
            status: status,
            operation: operation,
            submitted: false,
            requiresRefresh: false,
            failed: 1,
            errorCategory: mutationErrorCategory(for: mapped.category),
            diagnosticTag: "file-station.share-link.preflight-failed"
        )
    }

    private func shareLinkOutcome(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = nil,
        diagnosticTag: String,
        confirmedLink: FileShareLink? = nil
    ) throws -> FileShareLinkCreateOutcome {
        FileShareLinkCreateOutcome(
            result: try makeMutationResult(
                status: status,
                operation: operation,
                submitted: submitted,
                requiresRefresh: requiresRefresh,
                succeeded: succeeded,
                failed: failed,
                unknown: unknown,
                errorCategory: errorCategory,
                diagnosticTag: diagnosticTag
            ),
            confirmedLink: confirmedLink
        )
    }

    private func shareLinkContractAppError(_ error: ShareLinkReadbackError) -> AppError {
        AppError(
            category: .invalidResponse,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.88223e41ac45d405")
        )
    }

    private static func isRemoteMount(_ item: FileItem) -> Bool {
        guard let type = item.mountPointType?.lowercased(), !type.isEmpty else { return false }
        return type != "normal" && type != "shared_folder"
    }

    private static func volumeIdentity(realPath: String?) -> String? {
        if let realPath {
            let components = realPath.split(separator: "/")
            if let volume = components.first, volume.lowercased().hasPrefix("volume") {
                return String(volume)
            }
        }
        // 无法确认所属卷时不纳入汇总，避免把同卷重复计算或把等容量的不同卷错误合并。
        return nil
    }

    private static func validateRemoteMount(
        _ configuration: RemoteMountConfiguration
    ) throws -> RemoteMountConfiguration {
        let server = configuration.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let remotePath = configuration.remotePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/\\ ").union(.newlines))
        let mountPoint = try validateMountPoint(configuration.mountPoint)
        guard !server.isEmpty,
              !remotePath.isEmpty,
              !server.contains("/"),
              !server.contains("\\"),
              !server.contains("@") else {
            throw AppError(
                category: .unknown,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.7fdf000bc1c98dab")
            )
        }
        return RemoteMountConfiguration(
            protocolType: configuration.protocolType,
            server: server,
            remotePath: remotePath,
            mountPoint: mountPoint,
            username: configuration.username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: configuration.password,
            domain: configuration.domain.trimmingCharacters(in: .whitespacesAndNewlines),
            readOnly: configuration.readOnly
        )
    }

    private static func validateMountPoint(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard trimmed.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw AppError(
                category: .unknown,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.cbcc1b6d8f173727")
            )
        }
        return "/" + components.joined(separator: "/")
    }

    private static func normalizedDirectorySizePath(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        let containsControlCharacters = trimmed.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
        guard trimmed.hasPrefix("/"),
              !components.isEmpty,
              trimmed.utf8.count <= 4_096,
              !containsControlCharacters,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw AppError(
                category: .unknown,
                isRetryable: false,
                safeUserMessage: L10n.string("dirsize.invalid-path")
            )
        }
        return "/" + components.joined(separator: "/")
    }

    private static func makeBackgroundTaskSummary(
        _ payload: BackgroundTaskPayload
    ) -> FileBackgroundTaskSummary? {
        guard let taskID = normalizedBackgroundTaskID(payload.taskID),
              let kind = backgroundTaskKind(api: payload.api),
              let finished = payload.finished else {
            return nil
        }

        let processedItems = nonnegativeInt(payload.processedItemCount)
        let processedBytes = nonnegativeInt64(payload.processedBytes)
        let resolvedTotal = nonnegativeInt64(payload.total)
        let totalItems: Int?
        let totalBytes: Int64?
        switch kind {
        case .copyOrMove:
            totalItems = nil
            totalBytes = resolvedTotal
        case .delete:
            totalItems = nonnegativeInt(resolvedTotal)
            totalBytes = nil
        case .compress, .extract:
            // 官方说明没有为这两类任务稳定定义 total 的单位，避免误导。
            totalItems = nil
            totalBytes = nil
        }

        let progress: Double?
        if let value = payload.progress,
           value.isFinite,
           value > 0,
           value <= 1 {
            progress = value
        } else {
            // 进行中的 0 可能表示服务端不支持进度，界面应显示不确定状态。
            progress = nil
        }

        let createdAt: Date?
        if let value = payload.creationTime,
           value.isFinite,
           value >= 946_684_800,
           value <= Date().timeIntervalSince1970 + 86_400 {
            createdAt = Date(timeIntervalSince1970: value)
        } else {
            createdAt = nil
        }

        return FileBackgroundTaskSummary(
            id: taskID,
            kind: kind,
            state: finished ? .finished : .active,
            progress: progress,
            createdAt: createdAt,
            processedItemCount: processedItems,
            totalItemCount: totalItems,
            processedBytes: processedBytes,
            totalBytes: totalBytes
        )
    }

    private static func normalizedBackgroundTaskID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    private static func backgroundTaskKind(api: String?) -> FileBackgroundTaskKind? {
        switch api {
        case "SYNO.FileStation.CopyMove": return .copyOrMove
        case "SYNO.FileStation.Delete": return .delete
        case "SYNO.FileStation.Compress": return .compress
        case "SYNO.FileStation.Extract": return .extract
        default: return nil
        }
    }

    private static func nonnegativeInt(_ value: Int64?) -> Int? {
        guard let value, value >= 0, value <= Int64(Int.max) else { return nil }
        return Int(value)
    }

    private static func nonnegativeInt64(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private func performFileItemMutation(
        operation: String,
        sourcePath: String?,
        destinationPath: String,
        reviewKey: String,
        expectedDirectory: Bool?,
        submit: (ApiCapability) async throws -> Void,
        preflight: () async throws -> FileItemMutationPreflight
    ) async throws -> FileItemMutationOutcome {
        let mutationPaths = Set([sourcePath, destinationPath].compactMap { $0 })
        let diagnosticOperation = operation == "createFolder" ? "create-folder" : "rename"
        let apiName = operation == "createFolder"
            ? DsmAPIName.fileStationCreateFolder
            : DsmAPIName.fileStationRename
        guard let capability = capabilities[apiName],
              capability.selectedVersion == 2,
              capability.requestFormat == .form,
              let listCapability = capabilities[DsmAPIName.fileStationList],
              (listCapability.selectedVersion ?? 0) >= 2,
              capabilities[DsmAPIName.fileStationCheckPermission]?.selectedVersion != nil else {
            return try fileItemMutationOutcome(
                status: .unsupported,
                operation: operation,
                submitted: false,
                failed: 1,
                errorCategory: .unsupported,
                diagnosticTag: "file-station.\(diagnosticOperation).unsupported"
            )
        }

        if let pendingReview = pendingFileItemMutationReviews[reviewKey] {
            let reviewed = await independentFileItemReadback(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                expectedDirectory: pendingReview.expectedDirectory
            )
            if case .confirmed(let item) = reviewed {
                pendingFileItemMutationReviews.removeValue(forKey: reviewKey)
                return try fileItemMutationOutcome(
                    status: .confirmedSuccess,
                    operation: operation,
                    submitted: true,
                    succeeded: 1,
                    diagnosticTag: "file-station.\(diagnosticOperation).review-confirmed",
                    item: item
                )
            }
            if case .unavailable(let error) = reviewed,
               let error,
               error.category == .authenticationRequired || error.category == .otpRequired {
                throw error
            }
            pendingFileItemMutationReviews[reviewKey] = pendingReview
            return try fileItemMutationOutcome(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                diagnosticTag: "file-station.\(diagnosticOperation).review-pending"
            )
        }
        if pendingFileItemMutationReviews.values.contains(where: {
            !$0.paths.isDisjoint(with: mutationPaths)
        }) || activeFileItemMutationPaths.contains(where: { active in
            mutationPaths.contains(where: { Self.deletionPathsOverlap(active, $0) })
        }) || activeDeletionPaths.contains(where: { active in
            mutationPaths.contains(where: { Self.deletionPathsOverlap(active, $0) })
        }) {
            return try fileItemMutationOutcome(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                failed: 1,
                errorCategory: .conflict,
                diagnosticTag: "file-station.\(diagnosticOperation).target-busy"
            )
        }

        activeFileItemMutationPaths.formUnion(mutationPaths)
        defer { activeFileItemMutationPaths.subtract(mutationPaths) }
        if Task.isCancelled {
            return try fileItemMutationOutcome(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                diagnosticTag: "file-station.\(diagnosticOperation).cancelled-before-preflight"
            )
        }
        var verifiedExpectedDirectory = expectedDirectory
        do {
            switch try await preflight() {
            case .allowed(let observedDirectory):
                verifiedExpectedDirectory = observedDirectory
            case .permission:
                return try fileItemMutationOutcome(
                    status: .permissionDenied,
                    operation: operation,
                    submitted: false,
                    failed: 1,
                    errorCategory: .permission,
                    diagnosticTag: "file-station.\(diagnosticOperation).preflight-rejected"
                )
            case .conflict:
                return try fileItemMutationOutcome(
                    status: .confirmedFailure,
                    operation: operation,
                    submitted: false,
                    failed: 1,
                    errorCategory: .conflict,
                    diagnosticTag: "file-station.\(diagnosticOperation).preflight-rejected"
                )
            }
        } catch {
            return try fileItemMutationPreflightOutcome(error, operation: operation)
        }
        guard let verifiedExpectedDirectory else {
            preconditionFailure("file-station.mutation.preflight-type-missing")
        }
        if Task.isCancelled {
            return try fileItemMutationOutcome(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                diagnosticTag: "file-station.\(diagnosticOperation).cancelled-after-preflight"
            )
        }

        var cancellationRequested = false
        var submissionErrorCategory: MutationErrorCategory?
        do {
            try await submit(capability)
        } catch let error as DsmNetworkError {
            switch error {
            case .invalidRequest:
                return try fileItemMutationOutcome(
                    status: .confirmedFailure,
                    operation: operation,
                    submitted: false,
                    failed: 1,
                    errorCategory: .validation,
                    diagnosticTag: "file-station.\(diagnosticOperation).invalid-request"
                )
            case .api:
                let mapped = DsmErrorMapper.map(error)
                if mapped.category == .authenticationRequired || mapped.category == .otpRequired {
                    throw mapped
                }
                return try fileItemMutationOutcome(
                    status: mapped.category == .permissionDenied ? .permissionDenied : .confirmedFailure,
                    operation: operation,
                    submitted: true,
                    failed: 1,
                    errorCategory: mutationErrorCategory(for: mapped.category),
                    diagnosticTag: "file-station.\(diagnosticOperation).rejected"
                )
            case .cancelled:
                cancellationRequested = true
            case .httpStatus(let code, _):
                if (400..<500).contains(code) {
                    let mapped = DsmErrorMapper.map(error)
                    if mapped.category == .authenticationRequired || mapped.category == .otpRequired {
                        throw mapped
                    }
                    return try fileItemMutationOutcome(
                        status: mapped.category == .permissionDenied ? .permissionDenied : .confirmedFailure,
                        operation: operation,
                        submitted: true,
                        failed: 1,
                        errorCategory: mutationErrorCategory(for: mapped.category),
                        diagnosticTag: "file-station.\(diagnosticOperation).http-rejected"
                    )
                }
                submissionErrorCategory = .server
            case .transport, .responseTooLarge, .invalidResponse:
                submissionErrorCategory = mutationErrorCategory(
                    for: DsmErrorMapper.map(error).category
                )
            }
        } catch is CancellationError {
            cancellationRequested = true
        } catch {
            submissionErrorCategory = .unknown
        }

        let readback = await independentFileItemReadback(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            expectedDirectory: verifiedExpectedDirectory
        )
        if case .confirmed(let confirmedItem) = readback {
            pendingFileItemMutationReviews.removeValue(forKey: reviewKey)
            return try fileItemMutationOutcome(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                succeeded: 1,
                diagnosticTag: "file-station.\(diagnosticOperation).confirmed",
                item: confirmedItem
            )
        }

        if case .unavailable(let error) = readback,
           let error,
           error.category == .authenticationRequired || error.category == .otpRequired {
            pendingFileItemMutationReviews[reviewKey] = PendingFileItemMutationReview(
                paths: mutationPaths,
                expectedDirectory: verifiedExpectedDirectory
            )
            throw error
        }
        pendingFileItemMutationReviews[reviewKey] = PendingFileItemMutationReview(
            paths: mutationPaths,
            expectedDirectory: verifiedExpectedDirectory
        )
        let cancelled = cancellationRequested || Task.isCancelled
        return try fileItemMutationOutcome(
            status: cancelled ? .cancellationRequestedAfterSubmission : .submittedButUnverified,
            operation: operation,
            submitted: true,
            requiresRefresh: true,
            unknown: 1,
            errorCategory: cancelled ? nil : submissionErrorCategory,
            diagnosticTag: "file-station.\(diagnosticOperation).readback-unverified"
        )
    }

    private func independentFileItemReadback(
        sourcePath: String?,
        destinationPath: String,
        expectedDirectory: Bool?
    ) async -> FileItemMutationReadback {
        let repository = self
        let task = Task {
            let paths = [sourcePath, destinationPath].compactMap { $0 }
            return try await repository.getInfo(paths: paths)
        }
        let items: [FileItem]
        do {
            items = try await task.value
        } catch let error as AppError {
            return .unavailable(error)
        } catch {
            return .unavailable(nil)
        }
        guard let destination = items.first(where: {
                  $0.path == destinationPath && $0.profileID == profileID
              }),
              Self.hasCanonicalMutationIdentity(destination),
              expectedDirectory.map({ destination.isDirectory == $0 }) ?? true,
              sourcePath.map({ source in !items.contains(where: { $0.path == source }) }) ?? true else {
            return .mismatch
        }
        return .confirmed(destination)
    }

    private func fileItemMutationPreflightOutcome(
        _ error: Error,
        operation: String
    ) throws -> FileItemMutationOutcome {
        let diagnosticOperation = operation == "createFolder" ? "create-folder" : "rename"
        if error is CancellationError ||
            (error as? AppError)?.category == .cancelled ||
            Task.isCancelled {
            return try fileItemMutationOutcome(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                diagnosticTag: "file-station.\(diagnosticOperation).preflight-cancelled"
            )
        }
        let mapped = (error as? AppError) ?? AppError(
            category: .unknown,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.7dc6f291445bfb76")
        )
        if mapped.category == .authenticationRequired || mapped.category == .otpRequired {
            throw mapped
        }
        return try fileItemMutationOutcome(
            status: mapped.category == .permissionDenied ? .permissionDenied : .confirmedFailure,
            operation: operation,
            submitted: false,
            failed: 1,
            errorCategory: mutationErrorCategory(for: mapped.category),
            diagnosticTag: "file-station.\(diagnosticOperation).preflight-failed"
        )
    }

    private func fileItemMutationOutcome(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = nil,
        diagnosticTag: String,
        item: FileItem? = nil
    ) throws -> FileItemMutationOutcome {
        FileItemMutationOutcome(
            result: try makeMutationResult(
                status: status,
                operation: operation,
                submitted: submitted,
                requiresRefresh: requiresRefresh,
                succeeded: succeeded,
                failed: failed,
                unknown: unknown,
                errorCategory: errorCategory,
                diagnosticTag: diagnosticTag
            ),
            item: item
        )
    }

    private static func normalizedMutationPath(_ value: String) -> String? {
        try? canonicalFileLocationPath(value)
    }

    private static func normalizedMutationName(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized == value,
              normalized != ".",
              normalized != "..",
              normalized.utf8.count <= 255,
              !normalized.contains("/"),
              !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return normalized
    }

    private static func mutationParentPath(_ path: String) -> String? {
        let components = path.split(separator: "/")
        guard components.count >= 2 else { return nil }
        return "/" + components.dropLast().joined(separator: "/")
    }

    private static func appendingMutationName(_ name: String, to parent: String) -> String? {
        normalizedMutationPath(parent + "/" + name)
    }

    private static func isRecycleMutationPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.lowercased() == "#recycle" }
    }

    private static func isRemoteMutationItem(_ item: FileItem) -> Bool {
        isRemoteMount(item)
    }

    private static func isSupportedCopyMoveSource(_ item: FileItem) -> Bool {
        switch item.kind {
        case .file:
            item.sizeBytes.map { $0 >= 0 } == true
        case .directory:
            true
        case .symlink, .unknown:
            false
        }
    }

    private static func hasCanonicalMutationIdentity(_ item: FileItem) -> Bool {
        normalizedMutationPath(item.path) == item.path &&
            item.name == item.path.split(separator: "/").last.map(String.init)
    }

    /// 文件位置契约只接受已经规范化的绝对路径，避免重复路径在分页后形成幽灵条目。
    private static func canonicalFileLocationPath(_ value: String) throws -> String {
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        let canonical = "/" + components.joined(separator: "/")
        guard !components.isEmpty,
              value == canonical,
              value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw invalidFileLocationResponse()
        }
        return canonical
    }

    private static func invalidFileLocationResponse() -> AppError {
        AppError(
            category: .invalidResponse,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.7aa519aeec359f04")
        )
    }

    private static func invalidStorageSpaceResponse() -> AppError {
        AppError(
            category: .invalidResponse,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.fbb16df36e02d491")
        )
    }

    private func requireCapability(_ name: String) throws -> ApiCapability {
        guard let capability = capabilities[name], capability.selectedVersion != nil else {
            throw AppError(
                category: .apiUnavailable,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.7dc6f291445bfb76")
            )
        }
        return capability
    }

    private func selectedVersion(_ capability: ApiCapability) throws -> Int {
        guard let version = capability.selectedVersion else {
            throw AppError(
                category: .versionUnsupported,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.03e86493986f245a")
            )
        }
        return version
    }

    private func selectedVersion(_ capability: ApiCapability, minimum: Int) throws -> Int {
        let version = try selectedVersion(capability)
        guard version >= minimum else {
            throw AppError(
                category: .versionUnsupported,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.03e86493986f245a")
            )
        }
        return version
    }

    private func apiURL(path: String) -> URL {
        var url = baseURL.appendingPathComponent("webapi", isDirectory: true)
        for segment in path.split(separator: "/") {
            url.appendPathComponent(String(segment), isDirectory: false)
        }
        return url
    }

    private func validateUploadSuccess(_ response: DsmHTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw AppError(
                category: response.statusCode >= 500 ? .serverBusy : .invalidResponse,
                isRetryable: response.statusCode >= 500,
                safeUserMessage: L10n.string("shared.d4522bd42ff2c232"),
                httpStatus: response.statusCode
            )
        }
        guard let envelope = try? JSONDecoder().decode(BinaryEnvelope.self, from: response.data) else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.7aa519aeec359f04")
            )
        }
        if let error = envelope.error {
            throw uploadError(code: error.code)
        }
        guard envelope.success else {
            throw AppError(
                category: .unknown,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.39e007a9db856aea")
            )
        }
    }

    private func uploadError(code: Int) -> AppError {
        switch code {
        case 105:
            AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.b99b8ea54fa7ef76"),
                dsmCode: code
            )
        case 106, 107, 119:
            AppError(
                category: .authenticationRequired,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.18b4f39557c377e4"),
                dsmCode: code
            )
        case 108:
            AppError(
                category: .unknown,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.074152c919ec8351"),
                dsmCode: code
            )
        case 115:
            AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.71de0e6207d12dc7"),
                dsmCode: code
            )
        case 1800:
            AppError(
                category: .invalidResponse,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.37312259aaed38d3"),
                dsmCode: code
            )
        case 1801:
            AppError(
                category: .timeout,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.bcf11673adce7bde"),
                dsmCode: code
            )
        case 1802:
            AppError(
                category: .invalidResponse,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.4758142343e27842"),
                dsmCode: code
            )
        case 1803:
            AppError(
                category: .cancelled,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.97f6118b6bbcfb02"),
                dsmCode: code
            )
        case 1804:
            AppError(
                category: .remoteStorageFull,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.5670981d6f978923"),
                dsmCode: code
            )
        case 1805:
            AppError(
                category: .conflict,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.6c7c8cc0b215216b"),
                dsmCode: code
            )
        default:
            AppError(
                category: .unknown,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.b0871c53768d919d", String(describing: code)),
                dsmCode: code
            )
        }
    }

    private func downloadError(code: Int) -> AppError {
        switch code {
        case 105:
            AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.b99b8ea54fa7ef76"),
                dsmCode: code
            )
        case 106, 107, 119:
            AppError(
                category: .authenticationRequired,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.18b4f39557c377e4"),
                dsmCode: code
            )
        default:
            AppError(
                category: .unknown,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.f259462cccf2903a"),
                dsmCode: code
            )
        }
    }

    private func validateBinaryResponse(_ response: DsmHTTPResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw AppError(
                category: response.statusCode >= 500 ? .serverBusy : .invalidResponse,
                isRetryable: response.statusCode >= 500,
                safeUserMessage: L10n.string("shared.236b6efd04c99cdc"),
                httpStatus: response.statusCode
            )
        }
        let contentType = response.headers["content-type"]?.lowercased() ?? ""
        if contentType.contains("application/json"),
           let envelope = try? JSONDecoder().decode(BinaryEnvelope.self, from: data) {
            if !envelope.success {
                let errorCode = envelope.error?.code ?? -1
                throw downloadError(code: errorCode)
            }
        }
        if contentType.contains("text/html") {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.15a56baee335807a")
            )
        }
    }

    private func translate(_ error: Error) -> Error {
        if Task.isCancelled {
            return CancellationError()
        }
        if error is CancellationError || error is MemoryPipeError {
            return CancellationError()
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return CancellationError()
        }
        if error is AppError || error is DsmCertificateTrustError {
            return error
        }
        if error is DsmTransportError {
            return AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.f98d542d79142efa")
            )
        }
        if let error = error as? URLError {
            return DsmErrorMapper.map(
                .transport(code: error.errorCode, requestID: UUID())
            )
        }
        return AppError(
            category: .unknown,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.71baa97fe8c71269")
        )
    }

    private func createMultipartBody(
        localURL: URL,
        boundary: String,
        fields: [String: String]
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanStashUpload-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw AppError(
                category: .localStorageFull,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.b625a77008c47c54")
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: bodyURL.path
        )

        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }
        func write(_ string: String) throws {
            guard let data = string.data(using: .utf8) else {
                throw DsmRequestError.parameterEncodingFailed
            }
            try output.write(contentsOf: data)
        }

        for (name, value) in fields.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            try write("\(value)\r\n")
        }

        let safeFilename = localURL.lastPathComponent
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\"", with: "'")
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n")
        try write("Content-Type: application/octet-stream\r\n\r\n")

        let input = try FileHandle(forReadingFrom: localURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
        return bodyURL
    }

    private static let additionalFields = [
        "real_path", "size", "owner", "time", "perm", "mount_point_type", "volume_status", "type"
    ]
    private static let getInfoChunkSize = 100
    private static let getInfoAdditionalFields = [
        "size", "owner", "time", "perm", "type", "mount_point_type"
    ]
    private static let favoriteRequestLimit = 500
    private static let favoriteSnapshotLimit = 5_000
    private static let recycleSharePageLimit = 200
    private static let recycleShareLimit = 500
    private static let virtualFolderRequestLimit = 500
    private static let virtualFolderSnapshotLimit = 5_000
    private static let virtualFolderAdditionalFields = ["mount_point_type", "perm"]
}

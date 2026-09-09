import Foundation

/// 照片库单空间持久化缓存结构
public struct PhotoSpaceCache: Codable, Equatable, Sendable {
    /// 照片及视频元数据列表
    public var items: [PhotoLibraryItem]
    /// 每个已扫描文件夹路径对应的照片 Path 列表集合，用于进行增量对比删除
    public var folderItemPaths: [String: [String]]
    /// 上次成功完成扫描的时间戳
    public var lastScannedAt: Date

    public init(
        items: [PhotoLibraryItem] = [],
        folderItemPaths: [String: [String]] = [:],
        lastScannedAt: Date = Date()
    ) {
        self.items = items
        self.folderItemPaths = folderItemPaths
        self.lastScannedAt = lastScannedAt
    }
}

/// 负责照片元数据在本地磁盘上的读写与持久化管理
public struct PhotoLibraryCacheStore: Sendable {
    private let baseURL: URL

    public init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseURL = baseURL
        } else {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseURL = cachesDir.appendingPathComponent(AppStorageNamespace.name("lanstash-photo-cache"), isDirectory: true)
        }
    }

    /// 读取指定账号与空间的本地持久化缓存
    public func load(profileID: UUID, spaceKind: PhotoSpaceKind) -> PhotoSpaceCache? {
        let fileURL = cacheFileURL(profileID: profileID, spaceKind: spaceKind)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()

            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                if let doubleVal = try? container.decode(Double.self) {
                    // 兼容毫秒或秒级的 Double 读入
                    return doubleVal > 10_000_000_000 ? Date(timeIntervalSince1970: doubleVal / 1000.0) : Date(timeIntervalSince1970: doubleVal)
                }
                let stringVal = try container.decode(String.self)
                if let date = Self.isoFormatterWithFraction.date(from: stringVal) ?? Self.isoFormatterStandard.date(from: stringVal) {
                    return date
                }
                return Date.distantPast
            }
            return try decoder.decode(PhotoSpaceCache.self, from: data)
        } catch {
            return nil
        }
    }

    private nonisolated(unsafe) static let isoFormatterWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let isoFormatterStandard = ISO8601DateFormatter()

    /// 保存指定账号与空间的本地持久化缓存
    public func save(_ cache: PhotoSpaceCache, profileID: UUID, spaceKind: PhotoSpaceKind) {
        let fileURL = cacheFileURL(profileID: profileID, spaceKind: spaceKind)
        let directoryURL = fileURL.deletingLastPathComponent()

        do {
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(cache)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 写入失败时不影响主程序运行
        }
    }

    /// 清理指定账号（或特定空间）的缓存
    public func remove(profileID: UUID, spaceKind: PhotoSpaceKind? = nil) {
        if let spaceKind {
            let fileURL = cacheFileURL(profileID: profileID, spaceKind: spaceKind)
            try? FileManager.default.removeItem(at: fileURL)
        } else {
            for kind in PhotoSpaceKind.allCases {
                let fileURL = cacheFileURL(profileID: profileID, spaceKind: kind)
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func cacheFileURL(profileID: UUID, spaceKind: PhotoSpaceKind) -> URL {
        baseURL.appendingPathComponent("photo_cache_\(profileID.uuidString)_\(spaceKind.rawValue).json")
    }
}

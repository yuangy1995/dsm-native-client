import CryptoKit
import Foundation

/// 照片缩略图磁盘持久化缓存管理
public struct PhotoThumbnailDiskCacheStore: Sendable {
    private let baseURL: URL

    public init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseURL = baseURL
        } else {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseURL = cachesDir.appendingPathComponent(AppStorageNamespace.name("lanstash-photo-thumbnails"), isDirectory: true)
        }
    }

    /// 从磁盘读取对应项目的缩略图数据
    public func load(profileID: UUID, itemID: String) -> Data? {
        let fileURL = cacheFileURL(profileID: profileID, itemID: itemID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    /// 同步检查对应项目的缩略图是否已持久化到磁盘，用于在发起后台读取前快速过滤空缓存。
    public func cacheFileExists(profileID: UUID, itemID: String) -> Bool {
        let fileURL = cacheFileURL(profileID: profileID, itemID: itemID)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// 将缩略图数据保存至本地磁盘
    public func save(_ data: Data, profileID: UUID, itemID: String) {
        let fileURL = cacheFileURL(profileID: profileID, itemID: itemID)
        let directoryURL = fileURL.deletingLastPathComponent()

        do {
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 忽略非致命写入异常
        }
    }

    /// 删除指定项目的磁盘缩略图
    public func remove(profileID: UUID, itemID: String) {
        let fileURL = cacheFileURL(profileID: profileID, itemID: itemID)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 清理整个账号（或全部）的缩略图磁盘缓存
    public func removeAll(profileID: UUID? = nil) {
        if let profileID {
            let prefix = profileID.uuidString.lowercased()
            guard let files = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else { return }
            for file in files where file.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: file)
            }
        } else {
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    /// 获取所有磁盘缩略图占用的总字节数
    public var diskUsageBytes: Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for file in files {
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func cacheFileURL(profileID: UUID, itemID: String) -> URL {
        let input = "\(profileID.uuidString)_\(itemID)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let hashString = digest.compactMap { String(format: "%02x", $0) }.joined()
        return baseURL.appendingPathComponent("\(profileID.uuidString.lowercased())_\(hashString).thumb")
    }
}

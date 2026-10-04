import CryptoKit
import DsmCore
import Foundation

/// Apple 展示层的 Office 格式白名单，不改变共享预览分类契约。
public enum OfficeDocumentFormat {
    public static let extensions: Set<String> = ["doc", "docx", "xls", "xlsx", "ppt", "pptx"]

    public static func supports(_ item: FileItem) -> Bool {
        !item.isDirectory && extensions.contains(item.fileExtension?.lowercased() ?? "")
    }

    public static func canPreview(_ item: FileItem) -> Bool {
        !item.isDirectory && (supports(item) || PreviewKind.classify(item) != .unsupported)
    }
}

public struct OfficeFileFingerprint: Codable, Equatable, Sendable {
    public let size: Int64
    public let md5: String
    public let sha256: String

    public static func read(_ url: URL) throws -> Self {
        _ = try OfficeLocalFileStamp.read(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var md5 = Insecure.MD5(), sha256 = SHA256()
        var size: Int64 = 0
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            size += Int64(bytes.count); md5.update(data: bytes); sha256.update(data: bytes)
        }
        return .init(size: size, md5: md5.finalize().map { String(format: "%02x", $0) }.joined(),
                     sha256: sha256.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

public struct OfficeLocalFileStamp: Equatable, Sendable {
    public let size: Int
    public let modifiedAt: Date?
    public let identifier: String

    public static func read(_ url: URL) throws -> Self {
        // URL 会缓存资源属性；编辑器原子替换后必须重新读取文件标识和时间。
        var refreshed = url
        refreshed.removeAllCachedResourceValues()
        let value = try refreshed.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                     .contentModificationDateKey, .fileResourceIdentifierKey])
        guard value.isRegularFile == true, value.isSymbolicLink != true, let size = value.fileSize else {
            throw OfficeEditingError.localFileUnavailable
        }
        return .init(size: size, modifiedAt: value.contentModificationDate,
                     identifier: String(describing: value.fileResourceIdentifier))
    }
}

public enum OfficeEditingError: Error { case localFileUnavailable, changedDuringRead, remoteChanged, invalidTarget, noApplication }

/// 每次回传使用独立快照，编辑器后续的保存不会改变正在上传的文件。
public struct OfficeUploadSnapshot: Sendable {
    public let directory: URL
    public let url: URL
    public let fingerprint: OfficeFileFingerprint
    public let sourceStamp: OfficeLocalFileStamp

    public static func create(from source: URL, remoteName: String, root: URL? = nil) throws -> Self {
        guard !remoteName.isEmpty, remoteName != ".", remoteName != "..",
              (remoteName as NSString).lastPathComponent == remoteName else { throw OfficeEditingError.invalidTarget }
        let manager = FileManager.default
        let directory = (root ?? manager.temporaryDirectory).appendingPathComponent("LanStashOfficeUpload-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(remoteName)
        do {
            let before = try OfficeLocalFileStamp.read(source)
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { coordinated in
                do { try manager.copyItem(at: coordinated, to: destination) }
                catch { copyError = error }
            }
            if let error = coordinationError ?? copyError as NSError? { throw error }
            let fingerprint = try OfficeFileFingerprint.read(destination)
            guard before == (try OfficeLocalFileStamp.read(source)), fingerprint.size == Int64(before.size) else {
                throw OfficeEditingError.changedDuringRead
            }
            return .init(directory: directory, url: destination, fingerprint: fingerprint, sourceStamp: before)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }
}

import CryptoKit
import DsmCore
import Foundation

protocol MobileTransferServing: Sendable {
    func upload(
        _ request: MobileUploadRequest,
        progress: @escaping FileTransferProgress
    ) async throws
    func reviewUpload(_ request: MobileUploadRequest) async throws -> MutationResult?
    func download(
        _ request: MobileDownloadRequest,
        progress: @escaping FileTransferProgress
    ) async throws
    func removePartialDownload(_ request: MobileDownloadRequest) async
}

/// 下载明确请求整文件；恢复从头下载，不冒充字节断点续传。
struct MobileFileTransferService: MobileTransferServing {
    let repository: any FileRepository
    private let applyProtection: @Sendable (URL, FileProtectionType) throws -> Void

    init(repository: any FileRepository,
         applyProtection: @escaping @Sendable (URL, FileProtectionType) throws -> Void = { url, protection in
             try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
         }) {
        self.repository = repository
        self.applyProtection = applyProtection
    }

    func upload(
        _ request: MobileUploadRequest,
        progress: @escaping FileTransferProgress
    ) async throws {
        try await repository.upload(
            localURL: request.localURL,
            to: request.folderPath,
            overwrite: request.overwrite,
            progress: progress
        )
    }

    func reviewUpload(_ request: MobileUploadRequest) async throws -> MutationResult? {
        // 同名和大小不足以确认未知上传；只读取原目标并比对完整内容，不重放写请求。
        let info = try await repository.getInfo(paths: [request.stableTarget])
        guard let remote = info.first(where: { $0.path == request.stableTarget }), !remote.isDirectory else { return nil }
        let values = try request.localURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              remote.sizeBytes == values.fileSize.map(Int64.init) else { return nil }
        let localHash = try await Task.detached {
            let handle = try FileHandle(forReadingFrom: request.localURL)
            defer { try? handle.close() }
            var hash = Insecure.MD5()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        let remoteHash = try await repository.fileMD5(remotePath: request.stableTarget)
        guard localHash.caseInsensitiveCompare(remoteHash) == .orderedSame else { return nil }
        return try MutationResult(status: .confirmedSuccess, operation: "upload", submitted: true,
            requiresRefresh: false, counts: MutationResultCounts(succeeded: 1, failed: 0, unknown: 0))
    }

    func download(
        _ request: MobileDownloadRequest,
        progress: @escaping FileTransferProgress
    ) async throws {
        try MobileTransferRecoveryStore.prepareDirectory(request.temporaryURL.deletingLastPathComponent())
        if let sources = request.archiveSources {
            guard MobileArchiveDownloadSelection.isValid(sources), request.remotePath == sources.first?.path,
                  request.stableTarget == MobileArchiveDownloadSelection.identity(sources) else {
                throw AppError(category: .invalidResponse, isRetryable: false, safeUserMessage: "")
            }
            try Task.checkCancellation()
            let current = try await repository.getInfo(paths: sources.map(\.path))
            try Task.checkCancellation()
            guard current.count == sources.count, sources.allSatisfy({ source in
                current.filter { $0.path == source.path && $0.profileID == request.profileID
                    && $0.isDirectory == source.isDirectory
                    && ($0.kind == .file || $0.kind == .directory) }.count == 1
            }) else {
                throw AppError(category: .conflict, isRetryable: false, safeUserMessage: "")
            }
            guard current.allSatisfy({ $0.permissions?.canRead != false }) else {
                throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "")
            }
            try await repository.downloadArchive(remotePaths: sources.map(\.path), to: request.temporaryURL, progress: progress)
        } else {
            try await repository.download(
                remotePath: request.remotePath,
                to: request.temporaryURL,
                expectedSize: nil,
                progress: progress
            )
        }
        // 下载可能移动系统临时文件；明确设置最终副本保护，不依赖原目录的继承规则。
        do {
            try applyProtection(request.temporaryURL, .complete)
        } catch {
            // 无法保护的副本不能等待重试或进入系统面板。
            Self.removeControlledTemporaryFile(at: request.temporaryURL)
            throw error
        }
    }

    func removePartialDownload(_ request: MobileDownloadRequest) async {
        await repository.removePartialDownload(to: request.temporaryURL)
        Self.removeControlledTemporaryFile(at: request.temporaryURL)
    }

    static func removeControlledTemporaryFile(
        at url: URL,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: url)
    }
}

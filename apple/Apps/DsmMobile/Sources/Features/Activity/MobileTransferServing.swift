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

/// 当前仅适配单文件前台传输。下载明确请求整文件，不进入未验证的分段续传路径。
struct MobileFileTransferService: MobileTransferServing {
    let repository: any FileRepository

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
        // 共享契约尚无可证明目标身份的上传回读；首版不猜测，也不发第二次写请求。
        nil
    }

    func download(
        _ request: MobileDownloadRequest,
        progress: @escaping FileTransferProgress
    ) async throws {
        try await repository.download(
            remotePath: request.remotePath,
            to: request.temporaryURL,
            expectedSize: nil,
            progress: progress
        )
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

import Foundation

/// 将已校验的下载副本保存到用户选择的位置，不要求拥有目标目录中任意其他文件的权限。
public enum DownloadedFileExporter {
    public static func export(from source: URL, to destination: URL, replaceExisting: Bool) async throws {
        try Task.checkCancellation()
        // 文件复制与协调是同步系统操作，不能占用照片界面的 MainActor。
        let operation = Task.detached {
            try exportSynchronously(from: source, to: destination, replaceExisting: replaceExisting)
        }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private static func exportSynchronously(from source: URL, to destination: URL, replaceExisting: Bool) throws {
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let replacementDirectory = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination, create: true
        )
        defer { try? manager.removeItem(at: replacementDirectory) }
        let prepared = replacementDirectory.appendingPathComponent("download")
        try manager.copyItem(at: source, to: prepared)
        try AtomicFilePromotion.synchronizeFile(at: prepared)
        try Task.checkCancellation()
        var coordinationError: NSError?
        var promotionError: Error?
        var promoted = false
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                try Task.checkCancellation()
                if manager.fileExists(atPath: coordinated.path) {
                    guard replaceExisting else { throw CocoaError(.fileWriteFileExists) }
                    _ = try manager.replaceItemAt(coordinated, withItemAt: prepared, backupItemName: nil, options: [.usingNewMetadataOnly])
                } else {
                    try manager.moveItem(at: prepared, to: coordinated)
                }
                promoted = true
            } catch { promotionError = error }
        }
        if let coordinationError { throw coordinationError }
        if let promotionError { throw promotionError }
        guard promoted else { throw CocoaError(.fileWriteUnknown) }
    }
}

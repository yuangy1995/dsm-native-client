import Foundation

/// 同一目录内把完整临时文件提升为用户可见文件。
///
/// 已有目标文件时只使用系统原子替换；任何替换前的失败都不得截断或删除旧文件。
enum AtomicFilePromotion {
    static func promote(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default,
        replaceExisting: ((URL, URL) throws -> Void)? = nil
    ) throws {
        let sourceDirectory = sourceURL.deletingLastPathComponent()
            .standardizedFileURL
        let destinationDirectory = destinationURL.deletingLastPathComponent()
            .standardizedFileURL
        guard sourceDirectory == destinationDirectory else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        try synchronizeFile(at: sourceURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            if let replaceExisting {
                try replaceExisting(destinationURL, sourceURL)
            } else {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: sourceURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            }
        } else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}

import DsmCore
import DsmPhotosFeature
import Foundation

/// 系统选择器的授权和临时 URL 不能跨进程恢复；队列只引用按账号隔离的自有副本。
struct MobilePhotoUploadStorage: Sendable {
    let recordURL: URL
    var sourcesURL: URL { recordURL.deletingPathExtension().appendingPathComponent("Sources", isDirectory: true) }

    static func forProfile(_ profile: NasProfile) -> Self {
        .init(recordURL: PhotoUploadRecoveryStore.forProfile(profile, bookmarkAccess: MobilePhotoUploadBookmarkAccess()).url)
    }

    func recoveryStore() -> PhotoUploadRecoveryStore {
        .init(url: recordURL, bookmarkAccess: MobilePhotoUploadBookmarkAccess(ownedRoot: sourcesURL))
    }

    func prepare(_ urls: [URL]) throws -> PhotoUploadPreparation {
        let original = try PhotoUploadPreparation.prepare(urls)
        var result = PhotoUploadPreparation()
        result.skippedCount = original.skippedCount
        result.includesDirectory = original.includesDirectory
        do {
            for file in original.files {
                try Task.checkCancellation()
                let directory = sourcesURL.appendingPathComponent(file.id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
                var root = sourcesURL
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try root.setResourceValues(values)
                let destination = directory.appendingPathComponent(file.url.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: file.url, to: destination)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600], ofItemAtPath: destination.path)
                    let copied = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    guard copied.isRegularFile == true, copied.isSymbolicLink != true,
                          copied.fileSize.map(Int64.init) == file.size, copied.contentModificationDate == file.modifiedAt else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    result.files.append(.init(id: file.id, url: destination, size: file.size,
                        modifiedAt: file.modifiedAt, directoryComponents: file.directoryComponents))
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
            }
            return result
        } catch { remove(result.files); throw error }
    }

    func remove(_ files: [PhotoUploadFile]) {
        for file in files {
            let directory = file.url.deletingLastPathComponent().standardizedFileURL
            guard directory.deletingLastPathComponent() == sourcesURL.standardizedFileURL,
                  UUID(uuidString: directory.lastPathComponent) != nil,
                  file.url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// 仅在队列成功恢复后清理未提交草稿；损坏记录和失效书签的副本继续保留。
    func removeUnreferencedCopies(keeping files: [PhotoUploadFile]) throws {
        guard !files.contains(where: \.requiresSourceSelection), FileManager.default.fileExists(atPath: sourcesURL.path) else { return }
        let retained = Set(files.map { $0.url.deletingLastPathComponent().resolvingSymlinksInPath() })
        for directory in try FileManager.default.contentsOfDirectory(at: sourcesURL, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  !retained.contains(directory.resolvingSymlinksInPath()),
                  try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else { continue }
            try FileManager.default.removeItem(at: directory)
        }
    }
}

import DsmPhotosFeature
import Foundation

/// iOS 使用系统选择器授予的文件访问，不使用 macOS 专有书签选项。
struct MobilePhotoUploadBookmarkAccess: PhotoUploadBookmarkAccess {
    var ownedRoot: URL? = nil

    private func validate(_ url: URL) throws {
        guard let ownedRoot else { return }
        let directory = url.standardizedFileURL.deletingLastPathComponent()
        guard url.isFileURL, directory.deletingLastPathComponent() == ownedRoot.standardizedFileURL,
              UUID(uuidString: directory.lastPathComponent) != nil,
              directory.resolvingSymlinksInPath().deletingLastPathComponent() == ownedRoot.resolvingSymlinksInPath(),
              try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory,
              try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    func makeBookmark(for url: URL) throws -> Data {
        try validate(url)
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        try validate(url)
        return (url, stale)
    }
}

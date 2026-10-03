import DsmPhotosFeature
import Foundation

/// iOS 使用系统选择器授予的文件访问，不使用 macOS 专有书签选项。
struct MobilePhotoUploadBookmarkAccess: PhotoUploadBookmarkAccess {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

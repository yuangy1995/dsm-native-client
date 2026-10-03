import DsmCore
import DsmPhotosFeature
import Foundation

/// macOS 保留原安全范围书签及只读授权；共享队列不改变已有文件格式。
struct MacPhotoUploadBookmarkAccess: PhotoUploadBookmarkAccess {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

extension PhotoUploadRecoveryStore {
    convenience init(url: URL) { self.init(url: url, bookmarkAccess: MacPhotoUploadBookmarkAccess()) }

    static func forProfile(_ profile: NasProfile) -> PhotoUploadRecoveryStore {
        forProfile(profile, bookmarkAccess: MacPhotoUploadBookmarkAccess())
    }
}

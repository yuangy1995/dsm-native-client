import Foundation

/// 文件授权由 App 所在平台提供，队列与回执格式保持独立于平台。
public protocol PhotoUploadBookmarkAccess: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool)
}

import Foundation

/// 来源摘要用于中断后的防重；请求摘要另外绑定目标目录和上传选项，不保存原始输入。
public struct DownloadTaskCreationIdentity: Codable, Equatable, Sendable {
    public let sourceDigest: String
    public let requestDigest: String
    public init(sourceDigest: String, requestDigest: String) {
        self.sourceDigest = sourceDigest; self.requestDigest = requestDigest
    }
    public var isValid: Bool {
        [sourceDigest, requestDigest].allSatisfy { value in
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
}

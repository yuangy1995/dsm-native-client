import Foundation

/// 公开 RSS Site 的必要投影；来源地址与所有者只参与内存中的身份摘要计算。
public struct DownloadRSSSite: Equatable, Sendable, Identifiable {
    public let id: Int
    public let identityDigest: String
    public let title: String
    public let isUpdating: Bool
    public let lastUpdate: Int64

    public init(id: Int, identityDigest: String, title: String, isUpdating: Bool, lastUpdate: Int64) {
        self.id = id; self.identityDigest = identityDigest; self.title = title
        self.isUpdating = isUpdating; self.lastUpdate = lastUpdate
    }
}

/// Feed 没有公开编号；id 是当前内容的本机摘要，不作为 NAS 请求参数。
public struct DownloadRSSFeed: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let sizeBytes: Int64
    public let time: Int64
    public let downloadURI: String

    public init(id: String, title: String, sizeBytes: Int64, time: Int64, downloadURI: String) {
        self.id = id; self.title = title; self.sizeBytes = sizeBytes; self.time = time; self.downloadURI = downloadURI
    }
}

public enum DownloadRSSRefreshReceipt: Equatable, Sendable {
    case accepted
    case unknown
    case denied
    case rejected
    case cancelledBeforeSubmission
}

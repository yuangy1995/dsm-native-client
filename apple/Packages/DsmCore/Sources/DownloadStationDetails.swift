import Foundation

/// 缺失统计保持 nil；真实的零速度仍显示为零。
public struct DownloadStationStatistics: Equatable, Sendable {
    public let downloadBytesPerSecond: Int64?
    public let uploadBytesPerSecond: Int64?
    public let emuleDownloadBytesPerSecond: Int64?
    public let emuleUploadBytesPerSecond: Int64?

    public init(downloadBytesPerSecond: Int64? = nil, uploadBytesPerSecond: Int64? = nil,
                emuleDownloadBytesPerSecond: Int64? = nil, emuleUploadBytesPerSecond: Int64? = nil) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.emuleDownloadBytesPerSecond = emuleDownloadBytesPerSecond
        self.emuleUploadBytesPerSecond = emuleUploadBytesPerSecond
    }
}

/// 官方 Task.getinfo 的详情只在当前会话使用，不写入恢复队列。
public struct DownloadStationTaskDetails: Equatable, Sendable {
    public let task: DownloadStationTask
    public let kind: String?
    public let owner: String?
    public let createdAt: Date?
    public let priority: String?
    public let connectedSeeders: Int?
    public let connectedLeechers: Int?
    public let totalPeers: Int?
    public let files: [DownloadStationTaskFile]?
    public let trackers: [DownloadStationTaskTracker]?
    public let peers: [DownloadStationTaskPeer]?

    public init(task: DownloadStationTask, kind: String? = nil, owner: String? = nil,
                createdAt: Date? = nil, priority: String? = nil, connectedSeeders: Int? = nil,
                connectedLeechers: Int? = nil, totalPeers: Int? = nil,
                files: [DownloadStationTaskFile]? = nil, trackers: [DownloadStationTaskTracker]? = nil,
                peers: [DownloadStationTaskPeer]? = nil) {
        self.task = task
        self.kind = kind
        self.owner = owner
        self.createdAt = createdAt
        self.priority = priority
        self.connectedSeeders = connectedSeeders
        self.connectedLeechers = connectedLeechers
        self.totalPeers = totalPeers
        self.files = files
        self.trackers = trackers
        self.peers = peers
    }
}

public struct DownloadStationTaskFile: Equatable, Sendable {
    /// NAS 返回的任务内文件名，不视为可直接删除的 NAS 绝对路径。
    public let name: String
    public let sizeBytes: Int64?
    public let downloadedBytes: Int64?
    public let priority: String?

    public init(name: String, sizeBytes: Int64?, downloadedBytes: Int64?, priority: String?) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.downloadedBytes = downloadedBytes
        self.priority = priority
    }
}

public struct DownloadStationTaskTracker: Equatable, Sendable {
    /// 只展示源站，不含 userinfo、路径、查询参数和 fragment，避免显示 tracker passkey。
    public let displayAddress: String
    public let status: String?
    public let seeds: Int?
    public let peers: Int?
    public let nextUpdateSeconds: Int?

    public init(displayAddress: String, status: String?, seeds: Int?, peers: Int?, nextUpdateSeconds: Int?) {
        self.displayAddress = displayAddress
        self.status = status
        self.seeds = seeds
        self.peers = peers
        self.nextUpdateSeconds = nextUpdateSeconds
    }
}

public struct DownloadStationTaskPeer: Equatable, Sendable {
    public let address: String
    public let client: String?
    public let progress: Double?
    public let downloadBytesPerSecond: Int64?
    public let uploadBytesPerSecond: Int64?

    public init(address: String, client: String?, progress: Double?,
                downloadBytesPerSecond: Int64?, uploadBytesPerSecond: Int64?) {
        self.address = address
        self.client = client
        self.progress = progress
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
    }
}

import Foundation

/// 与登录配置分离的本机任务记录。文件内容和目标路径均不进入备份或日志。
struct MobileTransferRecoveryStore: Sendable {
    struct Record: Codable, Sendable {
        let context: String
        var task: MobileActivityTask
        let request: MobileTransferRequest
    }

    private struct Envelope: Codable {
        let version: Int
        let records: [Record]
    }

    enum StoreError: Error { case unsupportedVersion, invalidRecord }

    let rootURL: URL
    var recordsURL: URL { rootURL.appendingPathComponent("tasks-v1.json") }
    var artifactsURL: URL { rootURL.appendingPathComponent("Documents", isDirectory: true) }

    static var application: Self {
        Self(rootURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LanStashTransfers", isDirectory: true))
    }

    func load() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: recordsURL.path) else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: recordsURL))
        guard envelope.version == 1 else { throw StoreError.unsupportedVersion }
        var ids = Set<UUID>()
        for record in envelope.records {
            guard ids.insert(record.task.id).inserted,
                  !record.context.isEmpty,
                  record.task.source == .app,
                  record.task.profileID == record.request.profileID,
                  record.task.stableTarget == record.request.stableTarget,
                  record.task.operation == record.request.activityOperation,
                  ownsArtifact(record.request.localURL) else { throw StoreError.invalidRecord }
        }
        return envelope.records
    }

    func save(_ records: [Record]) throws {
        try Self.prepareDirectory(rootURL)
        let data = try JSONEncoder().encode(Envelope(version: 1, records: records))
        try data.write(to: recordsURL, options: [.atomic, .completeFileProtection])
    }

    func ownsArtifact(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.resolvingSymlinksInPath().path
            .hasPrefix(artifactsURL.standardizedFileURL.resolvingSymlinksInPath().path + "/")
    }

    static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }
}

extension MobileTransferRequest {
    var localURL: URL {
        switch self {
        case .upload(let upload): upload.localURL
        case .download(let download): download.temporaryURL
        }
    }
}

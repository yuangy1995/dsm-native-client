import CryptoKit
import Darwin
import Foundation

/// 写入与下载缓存分离；未确认的修改不能被缓存回收或旧版配置重写删除。
public enum DesktopDriveWritebackError: Error, Equatable, Sendable {
    case disabled, busy, pendingChanges, conflict, outcomeUnknown, invalidItem, keptLocally
}

public enum DesktopDriveWritebackAvailability {
    /// 正式版提供编辑入口；每个挂载仍默认只读，须经用户确认单独启用。
    public static var isEnabled: Bool { true }
}

public struct DesktopDriveWritebackRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Operation: String, Codable, Sendable { case save, delete }
    public enum Phase: String, Codable, Sendable {
        case prepared, submitted, conflict, verified, keptLocally
        public var isPending: Bool { self != .verified && self != .keptLocally }
    }
    public let id: String
    public let mappingID: UUID
    public let itemIdentifier: String
    public let sourcePath: String?
    public let destinationPath: String
    public let isDirectory: Bool
    public let contentHash: String?
    public let contentSize: Int64?
    public let baseContentVersion: Data?
    public let createdAt: Date
    public var phase: Phase
    public var step: Int
    public var allowOverwrite: Bool
    public var verifiedItem: FileItem?
    /// 旧记录没有此字段，仍按保存处理；删除收据不能被保存流程接管。
    public let operation: Operation?
    public let recursive: Bool?
    public var restorationRequested: Bool?
    public var isDeletion: Bool { operation == .delete }

    public init(mappingID: UUID, itemIdentifier: String, sourcePath: String?, destinationPath: String,
                isDirectory: Bool, contentHash: String?, contentSize: Int64?, baseContentVersion: Data?,
                operation: Operation = .save, recursive: Bool = false) {
        self.mappingID = mappingID
        self.itemIdentifier = itemIdentifier
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.isDirectory = isDirectory
        self.contentHash = contentHash
        self.contentSize = contentSize
        self.baseContentVersion = baseContentVersion
        self.createdAt = Date()
        self.phase = .prepared
        self.step = 0
        self.allowOverwrite = false
        self.verifiedItem = nil
        self.operation = operation == .save ? nil : operation
        self.recursive = operation == .delete ? recursive : nil
        self.restorationRequested = nil
        let key = [mappingID.uuidString, itemIdentifier, sourcePath ?? "", destinationPath,
                   String(isDirectory), contentHash ?? "", baseContentVersion?.base64EncodedString() ?? ""]
            .joined(separator: "\u{0}")
        let operationKey = operation == .delete ? "delete\u{0}\(recursive)\u{0}" + key : key
        self.id = SHA256.hash(data: Data(operationKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 持有跨进程互斥直到异步操作结束；进程退出由内核释放，不靠过期时间重放写操作。
public final class DesktopDriveWritebackLease: @unchecked Sendable {
    private let descriptor: Int32
    fileprivate init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

public struct DesktopDriveWritebackStore: Sendable {
    private let directory: URL?

    public init(directory: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: DesktopDriveSharedContainer.appGroupIdentifier)) {
        self.directory = directory?.appendingPathComponent("desktop-drive-writeback-v1", isDirectory: true)
    }

    private func root(_ mappingID: UUID) throws -> URL {
        guard let directory else { throw DesktopDriveConfigurationStoreError.sharedContainerUnavailable }
        let root = directory.appendingPathComponent(mappingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }

    public func lock(mappingID: UUID) throws -> DesktopDriveWritebackLease {
        let url = try root(mappingID).appendingPathComponent("write.lock")
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw DesktopDriveWritebackError.busy
        }
        return DesktopDriveWritebackLease(descriptor)
    }

    public func isEnabled(mappingID: UUID) throws -> Bool {
        let url = try root(mappingID).appendingPathComponent("enabled.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try JSONDecoder().decode(Bool.self, from: Data(contentsOf: url))
    }

    /// 调用方须持有该挂载的 lease。
    public func setEnabled(_ enabled: Bool, mappingID: UUID) throws {
        if !enabled {
            try requireNoPendingChanges(mappingID: mappingID)
            try setDeletionEnabled(false, mappingID: mappingID)
        }
        try JSONEncoder().encode(enabled).write(to: root(mappingID).appendingPathComponent("enabled.json"), options: .atomic)
    }

    public func isDeletionEnabled(mappingID: UUID) throws -> Bool {
        guard try isEnabled(mappingID: mappingID) else { return false }
        let url = try root(mappingID).appendingPathComponent("deletion-enabled.state")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try JSONDecoder().decode(Bool.self, from: Data(contentsOf: url))
    }

    /// 删除授权独立保存；旧版的编辑开关不能自动授予删除权限。调用方须持有 lease。
    public func setDeletionEnabled(_ enabled: Bool, mappingID: UUID) throws {
        if enabled {
            guard try isEnabled(mappingID: mappingID) else { throw DesktopDriveWritebackError.disabled }
        } else {
            guard try !pendingRecords(mappingID: mappingID).contains(where: \.isDeletion) else {
                throw DesktopDriveWritebackError.pendingChanges
            }
        }
        // 使用独立状态文件，不让旧版将授权开关误读为待处理操作。
        try JSONEncoder().encode(enabled).write(to: root(mappingID).appendingPathComponent("deletion-enabled.state"), options: .atomic)
    }

    public func records(mappingID: UUID) throws -> [DesktopDriveWritebackRecord] {
        let entries = try FileManager.default.contentsOfDirectory(at: root(mappingID), includingPropertiesForKeys: nil)
        return try entries.filter { $0.pathExtension == "json" && $0.lastPathComponent != "enabled.json" }
            .map { try JSONDecoder().decode(DesktopDriveWritebackRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func pendingRecords(mappingID: UUID) throws -> [DesktopDriveWritebackRecord] {
        try records(mappingID: mappingID).filter { $0.phase.isPending }
    }

    public func requireNoPendingChanges(mappingID: UUID) throws {
        guard try pendingRecords(mappingID: mappingID).isEmpty else { throw DesktopDriveWritebackError.pendingChanges }
    }

    public func contentURL(for record: DesktopDriveWritebackRecord) throws -> URL {
        try recordDirectory(record).appendingPathComponent((record.destinationPath as NSString).lastPathComponent)
    }

    private func recordDirectory(_ record: DesktopDriveWritebackRecord) throws -> URL {
        guard record.id.count == 64, record.id.allSatisfy({ $0.isHexDigit }),
              Self.validFilename((record.destinationPath as NSString).lastPathComponent) else {
            throw DesktopDriveWritebackError.invalidItem
        }
        return try root(record.mappingID).appendingPathComponent(record.id, isDirectory: true)
    }

    /// 先安全复制内容，再发布记录；发布前中断的目录不代表已接受 NAS 写请求。
    public func prepare(_ requested: DesktopDriveWritebackRecord, contents: URL?) throws -> DesktopDriveWritebackRecord {
        let records = try records(mappingID: requested.mappingID)
        if let existing = records.first(where: { $0.id == requested.id }) { return existing }
        guard !records.contains(where: { existing in
            guard existing.phase.isPending else { return false }
            if existing.itemIdentifier == requested.itemIdentifier { return true }
            guard existing.isDeletion || requested.isDeletion else { return false }
            return [existing.sourcePath, existing.destinationPath].compactMap { $0 }.contains { path in
                [requested.sourcePath, requested.destinationPath].compactMap { $0 }.contains {
                    DesktopDrivePath.isAncestorOrSame(path, of: $0) || DesktopDrivePath.isAncestorOrSame($0, of: path)
                }
            }
        }) else {
            throw DesktopDriveWritebackError.pendingChanges
        }
        if let contents {
            let folder = try recordDirectory(requested)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let destination = try contentURL(for: requested)
            if FileManager.default.fileExists(atPath: destination.path) {
                // 仅清理本记录在发布前遗留的副本；源文件始终由系统持有。
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: contents, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.synchronize()
            guard try Self.hash(of: destination) == requested.contentHash else { throw DesktopDriveWritebackError.invalidItem }
        } else if requested.contentHash != nil {
            try FileManager.default.createDirectory(at: recordDirectory(requested), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try Data().write(to: contentURL(for: requested), options: .atomic)
        }
        try save(requested)
        return requested
    }

    public func save(_ record: DesktopDriveWritebackRecord) throws {
        _ = try recordDirectory(record)
        let url = try root(record.mappingID).appendingPathComponent(record.id + ".json")
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }

    public func complete(_ record: DesktopDriveWritebackRecord, item: FileItem) throws {
        var completed = record
        completed.phase = .verified
        completed.verifiedItem = item
        try save(completed)
        try removeCompletedContent(record)
    }

    public func completeDeletion(_ record: DesktopDriveWritebackRecord) throws {
        guard record.isDeletion else { throw DesktopDriveWritebackError.invalidItem }
        var completed = record
        completed.phase = .verified
        completed.verifiedItem = nil
        try save(completed)
    }

    /// 界面先完成用户选择的本机副本保存，再停止此操作；绝不把它标成 NAS 保存成功。
    public func keepLocally(_ record: DesktopDriveWritebackRecord) throws {
        var local = record
        local.phase = .keptLocally
        local.restorationRequested = nil
        try save(local)
        try removeCompletedContent(record)
    }

    private func removeCompletedContent(_ record: DesktopDriveWritebackRecord) throws {
        // 已回读确认后才删除备份内容，保留轻量收据处理系统的重复回调。
        if record.contentHash != nil {
            let url = try contentURL(for: record)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    public static func validFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    public static func hash(of url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DesktopDriveWritebackError.invalidItem }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

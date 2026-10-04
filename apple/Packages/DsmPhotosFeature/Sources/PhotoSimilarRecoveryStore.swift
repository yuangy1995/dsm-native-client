import DsmCore
import Foundation

/// 一次确认的相似分组批次与可撤销的完成记录使用同一个原子文件。
public struct PhotoSimilarRecovery: Codable, Sendable {
    public enum State: String, Codable, Sendable { case prepared, submitted, confirmed, rejected, cancelled }
    public struct Entry: Codable, Sendable {
        public var checkpoint: SynologyPhotosAlbumCheckpoint
        public var state: State
    }
    public let version: Int
    public let id: UUID
    public let identity: String
    public var entries: [Entry]
    public var undoReceipts: [SynologyPhotosAlbumCheckpoint]
    public var isFinished: Bool { entries.allSatisfy { [.confirmed, .rejected, .cancelled].contains($0.state) } }
    public func count(_ state: State) -> Int { entries.filter { $0.state == state }.count }

    init(checkpoints: [SynologyPhotosAlbumCheckpoint], identity: String, receipts: [SynologyPhotosAlbumCheckpoint]) throws {
        version = 1; id = UUID(); self.identity = identity
        entries = checkpoints.map { .init(checkpoint: $0, state: .prepared) }; undoReceipts = receipts
        try validate()
    }
    public func validate() throws {
        guard version == 1, !entries.isEmpty, entries.count <= 100, undoReceipts.count <= 100,
              Set(entries.map { $0.checkpoint.operationID }).count == entries.count,
              Set(undoReceipts.map(\.operationID)).count == undoReceipts.count,
              count(.submitted) <= 1 else { throw CocoaError(.coderReadCorrupt) }
        for entry in entries {
            let checkpoint = entry.checkpoint
            _ = try checkpoint.reviewMutation()
            guard "\(checkpoint.profileID.uuidString):\(checkpoint.userID)" == identity,
                  let value = checkpoint.similarDetails,
                  value.confirmed == (entry.state == .confirmed), checkpoint.rejected == (entry.state == .rejected),
                  (entry.state != .prepared && entry.state != .cancelled || !value.submitted),
                  (entry.state != .submitted || value.submitted && !value.confirmed && !checkpoint.rejected),
                  (entry.state != .confirmed || value.confirmed),
                  (entry.state != .rejected || checkpoint.rejected) else { throw CocoaError(.coderReadCorrupt) }
            if case .undo(let id) = value.edit, [.prepared, .submitted].contains(entry.state) {
                guard undoReceipts.contains(where: { $0.operationID == id && $0.similarDetails?.group == value.group && $0.similarDetails?.targets == value.targets }) else { throw CocoaError(.coderReadCorrupt) }
            }
        }
        for receipt in undoReceipts {
            _ = try receipt.reviewMutation()
            guard "\(receipt.profileID.uuidString):\(receipt.userID)" == identity,
                  receipt.similarDetails?.canUndo == true, !receipt.rejected else { throw CocoaError(.coderReadCorrupt) }
        }
    }
}

public final class PhotoSimilarRecoveryStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var acceptsWrites = true
    public init(url: URL) { self.url = url }
    public func suspendWrites() { lock.withLock { acceptsWrites = false } }
    public func load() throws -> PhotoSimilarRecovery? { try lock.withLock { try read() } }

    func start(_ checkpoints: [SynologyPhotosAlbumCheckpoint], identity: String, undoing: Bool) throws -> PhotoSimilarRecovery {
        try lock.withLock {
            let previous = try read()
            guard previous?.isFinished != false, previous.map({ $0.identity == identity }) ?? true else { throw CocoaError(.fileWriteNoPermission) }
            let value = try PhotoSimilarRecovery(checkpoints: checkpoints, identity: identity, receipts: undoing ? previous?.undoReceipts ?? [] : [])
            try write(value); return value
        }
    }
    func checkpoint(_ checkpoint: SynologyPhotosAlbumCheckpoint) throws {
        try lock.withLock {
            guard var batch = try read(), let index = batch.entries.firstIndex(where: { $0.checkpoint.operationID == checkpoint.operationID }),
                  [.prepared, .submitted].contains(batch.entries[index].state),
                  let previous = batch.entries[index].checkpoint.similarDetails, let value = checkpoint.similarDetails,
                  checkpoint.profileID == batch.entries[index].checkpoint.profileID, checkpoint.userID == batch.entries[index].checkpoint.userID,
                  value.group == previous.group, value.edit == previous.edit, value.targets == previous.targets,
                  !previous.submitted || value.submitted else { throw CocoaError(.fileWriteNoPermission) }
            batch.entries[index].checkpoint = checkpoint
            batch.entries[index].state = checkpoint.rejected ? .rejected : value.submitted ? .submitted : .prepared
            try write(batch)
        }
    }
    func finish(id: UUID, result: SynologyPhotosMutationResult) throws {
        try lock.withLock {
            guard var batch = try read(), let index = batch.entries.firstIndex(where: { $0.checkpoint.operationID == id }),
                  [.prepared, .submitted, .rejected].contains(batch.entries[index].state),
                  var value = batch.entries[index].checkpoint.similarDetails,
                  result.state == .confirmed || result.state == .rejected else { throw CocoaError(.fileWriteNoPermission) }
            if result.state == .confirmed {
                guard value.submitted else { throw CocoaError(.fileWriteNoPermission) }
                value.confirmed = true; value.resultingGroup = result.similarGroup
                batch.entries[index].checkpoint.similarDetails = value; batch.entries[index].state = .confirmed
                if case .undo(let original) = value.edit { batch.undoReceipts.removeAll { $0.operationID == original } }
                else if value.canUndo { batch.undoReceipts.append(batch.entries[index].checkpoint) }
            } else {
                batch.entries[index].checkpoint.rejected = true; batch.entries[index].state = .rejected
            }
            try write(batch)
        }
    }
    func cancelRemaining() throws {
        try lock.withLock {
            guard var batch = try read() else { return }
            for index in batch.entries.indices where batch.entries[index].state == .prepared { batch.entries[index].state = .cancelled }
            try write(batch)
        }
    }
    private func read() throws -> PhotoSimilarRecovery? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(PhotoSimilarRecovery.self, from: Data(contentsOf: url))
        try value.validate(); return value
    }
    private func write(_ value: PhotoSimilarRecovery) throws {
        guard acceptsWrites else { throw CocoaError(.fileWriteNoPermission) }
        try value.validate()
        let root = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
        var protected = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try JSONEncoder().encode(value).write(to: url, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

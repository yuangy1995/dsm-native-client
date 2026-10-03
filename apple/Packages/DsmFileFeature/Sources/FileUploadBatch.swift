import CryptoKit
import DsmCore
import DsmLocalization
import Foundation
import Observation

public enum FileUploadItemState: String, Codable, Sendable {
    case pending, running, succeeded, skipped, failed, conflict, paused, cancelled, unverified
    public var title: String {
        switch self {
        case .pending: L10n.string("files.upload.state.pending")
        case .running: L10n.string("files.upload.state.running")
        case .succeeded: L10n.string("files.upload.state.succeeded")
        case .skipped: L10n.string("files.upload.state.skipped")
        case .failed: L10n.string("files.upload.state.failed")
        case .conflict: L10n.string("files.upload.state.conflict")
        case .paused: L10n.string("files.upload.state.paused")
        case .cancelled: L10n.string("files.upload.state.cancelled")
        case .unverified: L10n.string("files.upload.state.unverified")
        }
    }
}

public struct FileUploadEntry: Identifiable, Sendable {
    public let source: FileUploadSource
    public var state: FileUploadItemState = .pending
    public var completedBytes: Int64 = 0
    public var message: String?
    public var needsReconciliation = false
    public var retryAllowed = true
    public var id: UUID { source.id }
}

@MainActor @Observable
public final class FileUploadBatch: Identifiable {
    public let id: UUID
    public let destination: String
    public let overwrite: Bool
    public private(set) var entries: [FileUploadEntry]
    public private(set) var isRunning = false
    public private(set) var isPaused = false
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private let repository: any FileRepository
    @ObservationIgnored public var onChange: ((FileUploadEntry) -> Void)?
    @ObservationIgnored public var onSettled: (() -> Void)?
    /// 移动持久队列在真正提交之前保存阶段；失败时不得发出写请求。
    @ObservationIgnored public var beforeSubmission: (() throws -> Void)?

    public init(sources: [FileUploadSource], destination: String, overwrite: Bool, repository: any FileRepository,
                id: UUID = UUID(), restoredEntries: [FileUploadEntryCheckpoint]? = nil) {
        self.id = id
        self.destination = destination
        self.overwrite = overwrite
        self.repository = repository
        let duplicatePaths = Set(Dictionary(grouping: sources.filter { $0.kind == .file || $0.kind == .directory }, by: \.relativePath)
            .filter { $0.value.count > 1 }.keys)
        entries = sources.map { source in
            var entry = FileUploadEntry(source: source)
            if duplicatePaths.contains(source.relativePath) {
                entry.state = .conflict; entry.message = L10n.string("files.upload.duplicateSource")
                entry.retryAllowed = false
            } else if source.kind == .symbolicLink {
                entry.state = .skipped; entry.message = L10n.string("files.upload.linkSkipped")
            } else if source.kind == .unreadable {
                entry.state = .failed; entry.message = L10n.string("files.upload.sourceUnavailable")
                entry.retryAllowed = false
            }
            return entry
        }
        if let restoredEntries {
            for index in entries.indices {
                guard let restored = restoredEntries.first(where: { $0.id == entries[index].id }) else { continue }
                entries[index].state = switch restored.state {
                case .pending: .paused
                case .running: .unverified
                default: restored.state
                }
                entries[index].completedBytes = restored.completedBytes
                entries[index].needsReconciliation = restored.needsReconciliation || restored.state == .running || restored.state == .unverified
                entries[index].retryAllowed = restored.retryAllowed
            }
            isPaused = entries.contains { $0.state == .paused }
        }
    }

    public var checkpoint: [FileUploadEntryCheckpoint] {
        entries.map { FileUploadEntryCheckpoint(id: $0.id, state: $0.state, completedBytes: $0.completedBytes,
            needsReconciliation: $0.needsReconciliation, retryAllowed: $0.retryAllowed) }
    }

    public var totalBytes: Int64 { entries.filter { $0.source.kind == .file }.reduce(0) { $0 + $1.source.size } }
    public var completedBytes: Int64 { entries.filter { $0.source.kind == .file }.reduce(0) { $0 + min($1.completedBytes, $1.source.size) } }
    public var finishedCount: Int { entries.filter { [.succeeded, .skipped].contains($0.state) }.count }
    public var hasPending: Bool { entries.contains { $0.state == .pending } }

    public func start() {
        guard operation == nil, hasPending else { return }
        isPaused = false; isRunning = true
        operation = Task { [weak self] in
            guard let self else { return }
            for entry in entries where entry.source.kind == .directory && entry.state == .pending {
                guard !Task.isCancelled else { break }
                await process(entry.id)
            }
            while !Task.isCancelled {
                let next = entries.filter { $0.source.kind == .file && $0.state == .pending }.prefix(2).map(\.id)
                guard !next.isEmpty else { break }
                await withTaskGroup(of: Void.self) { group in
                    for id in next { group.addTask { await self.process(id) } }
                }
            }
            isRunning = false; operation = nil
            onSettled?()
        }
    }

    public func pause() {
        guard isRunning else { return }
        isPaused = true
        for index in entries.indices where entries[index].state == .pending { set(index, state: .paused) }
        operation?.cancel()
    }

    public func resume() {
        guard !isRunning else { return }
        for index in entries.indices where entries[index].state == .paused { set(index, state: .pending) }
        isPaused = false
    }

    public func cancel() {
        isPaused = false
        for index in entries.indices where [.pending, .paused].contains(entries[index].state) { set(index, state: .cancelled) }
        operation?.cancel()
    }

    public func retryFailed() {
        guard !isRunning else { return }
        for index in entries.indices where [.failed, .conflict].contains(entries[index].state)
            && entries[index].retryAllowed { set(index, state: .pending) }
    }

    public func reconcileUnknown() async {
        guard !isRunning else { return }
        isRunning = true
        for index in entries.indices where entries[index].state == .unverified {
            do {
                let source = entries[index].source
                let remote = try await existingItem(source)
                if let remote, source.kind == .directory, remote.isDirectory {
                    // 同名目录允许合并；这里只确认目标可供后续上传，不声称本次请求创建了它。
                    set(index, state: .succeeded)
                } else if source.kind == .file, let remote, !remote.isDirectory,
                          try await matchesUploadedFile(source, remote: remote) { set(index, state: .succeeded) }
            } catch { /* 核对失败不重放写请求。 */ }
        }
        isRunning = false
        onSettled?()
    }

    private func process(_ id: UUID) async {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let source = entries[index].source
        guard !entries.contains(where: {
            $0.source.kind == .directory && source.relativePath.hasPrefix($0.source.relativePath + "/")
                && $0.state != .succeeded
        }) else {
            set(index, state: .failed, message: L10n.string("files.upload.parentFailed")); return
        }
        var submitted = false
        let wasUnverified = entries[index].needsReconciliation
        set(index, state: .running)
        do {
            try Task.checkCancellation()
            let existing = try await existingItem(source)
            if let existing, existing.isDirectory != (source.kind == .directory) {
                set(index, state: .conflict, message: L10n.string("files.upload.typeConflict")); return
            }
            if entries[index].needsReconciliation {
                if let existing {
                    if source.kind == .directory && existing.isDirectory {
                        set(index, state: .succeeded)
                    } else if source.kind == .file, try await matchesUploadedFile(source, remote: existing) {
                        set(index, state: .succeeded)
                    } else { set(index, state: .unverified, message: L10n.string("files.upload.unverified")) }
                    return
                }
                // 仅缺失目标可以重新按“不覆盖”发送；已存在目标不自动重放替换。
                entries[index].needsReconciliation = false
            }
            if source.kind == .directory {
                if existing == nil {
                    try Task.checkCancellation(); try beforeSubmission?(); submitted = true
                    let outcome = try await repository.createFolderResult(parentPath: parentPath(source), name: source.url.lastPathComponent)
                    guard outcome.result.status == .confirmedSuccess else {
                        if outcome.result.status == .cancelledBeforeSubmission {
                            set(index, state: isPaused ? .paused : .cancelled); return
                        }
                        if outcome.result.requiresRefresh { entries[index].needsReconciliation = true }
                        set(index, state: outcome.result.requiresRefresh ? (isPaused ? .paused : .unverified) : .failed,
                            message: L10n.string("files.upload.folderFailed")); return
                    }
                }
                set(index, state: .succeeded); return
            }
            if existing != nil && !overwrite {
                set(index, state: .skipped, message: L10n.string("files.upload.sameNameSkipped")); return
            }
            guard try Self.sourceIsUnchanged(source) else {
                entries[index].retryAllowed = false
                set(index, state: .failed, message: L10n.string("files.upload.sourceChanged")); return
            }
            try Task.checkCancellation(); try beforeSubmission?(); submitted = true
            try await repository.upload(localURL: source.url, to: parentPath(source), overwrite: overwrite && !wasUnverified) { [weak self] bytes, _ in
                Task { @MainActor in
                    guard let self, self.entries[index].state == .running else { return }
                    self.entries[index].completedBytes = min(bytes, source.size)
                    self.onChange?(self.entries[index])
                }
            }
            guard try Self.sourceIsUnchanged(source), let observed = try await existingItem(source),
                  !observed.isDirectory, observed.sizeBytes == source.size else {
                set(index, state: .unverified, message: L10n.string("files.upload.unverified")); return
            }
            set(index, state: .succeeded)
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? AppError)?.category == .cancelled
            if cancelled {
                entries[index].needsReconciliation = submitted
                set(index, state: isPaused ? .paused : submitted ? .unverified : .cancelled,
                    message: submitted ? L10n.string("files.upload.unverified") : nil)
            } else {
                let category = (error as? AppError)?.category
                let rejected = [.permissionDenied, .authenticationRequired, .remoteStorageFull, .conflict,
                                .apiUnavailable, .versionUnsupported].contains(category)
                set(index, state: submitted && !rejected ? .unverified : .failed,
                    message: submitted && !rejected ? L10n.string("files.upload.unverified")
                        : (error as? AppError)?.safeUserMessage ?? L10n.string("files.upload.failed"))
            }
        }
    }

    private func set(_ index: Int, state: FileUploadItemState, message: String? = nil) {
        entries[index].state = state; entries[index].message = message
        if state == .succeeded { entries[index].completedBytes = entries[index].source.size }
        if state == .pending { entries[index].completedBytes = 0 }
        onChange?(entries[index])
    }

    private func parentPath(_ source: FileUploadSource) -> String {
        let parent = (source.relativePath as NSString).deletingLastPathComponent
        return destination + (parent.isEmpty ? "" : "/" + parent)
    }

    private func existingItem(_ source: FileUploadSource) async throws -> FileItem? {
        var offset = 0
        while true {
            let page = try await repository.listFolder(path: parentPath(source), offset: offset, limit: 500)
            if let item = page.items.first(where: { $0.name == source.url.lastPathComponent }) { return item }
            guard page.hasMore else { return nil }
            guard !page.items.isEmpty else {
                throw AppError(category: .invalidResponse, isRetryable: true, safeUserMessage: L10n.string("files.upload.failed"))
            }
            offset = page.offset + page.items.count
        }
    }

    private static func sourceIsUnchanged(_ source: FileUploadSource) throws -> Bool {
        var ancestor = source.url.deletingLastPathComponent()
        let root = source.access.url.standardizedFileURL.path
        while ancestor.standardizedFileURL.path.hasPrefix(root + "/") || ancestor.standardizedFileURL.path == root {
            if try ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { return false }
            let parent = ancestor.deletingLastPathComponent()
            if parent == ancestor { break }
            ancestor = parent
        }
        let value = try source.url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey,
                                                          .fileSizeKey, .contentModificationDateKey])
        return value.isSymbolicLink != true && value.isRegularFile == true
            && Int64(value.fileSize ?? -1) == source.size && value.contentModificationDate == source.modifiedAt
    }

    private func matchesUploadedFile(_ source: FileUploadSource, remote: FileItem) async throws -> Bool {
        guard remote.sizeBytes == source.size, try Self.sourceIsUnchanged(source) else { return false }
        let localHash = try await Task.detached {
            let handle = try FileHandle(forReadingFrom: source.url)
            defer { try? handle.close() }
            var hash = Insecure.MD5()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        let remoteHash = try await repository.fileMD5(remotePath: remote.path)
        return localHash.caseInsensitiveCompare(remoteHash) == .orderedSame
    }
}

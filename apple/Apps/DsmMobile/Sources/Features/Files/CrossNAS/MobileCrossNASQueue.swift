import DsmCore
import DsmLocalization
import Foundation
import Observation

/// 两端都固定后才运行；恢复读取原清单，未取得回执的写入不会重新提交。
@MainActor @Observable
final class MobileCrossNASQueue {
    @ObservationIgnored var onSourceChanged: (@MainActor (String) async -> Void)?
    private let store: MobileCrossNASStore
    private var stored: [MobileCrossNASRecord] = []
    private var source: MobileCrossNASEndpoint?
    private var execution: Task<Void, Never>?
    private var preparation: Task<MobileCrossNASRecord, Error>?
    private var generation = UUID()
    private var preparingTargetID: UUID?
    private var loadFailed = false
    private(set) var isPreparing = false
    private(set) var runningID: UUID?
    private(set) var completedBytes: Int64 = 0
    private(set) var totalBytes: Int64?
    private(set) var error: MobileCrossNASFailure?
    private(set) var recoveryFailed = false

    init(rootURL: URL? = nil) {
        store = MobileCrossNASStore(root: rootURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileCrossNAS-" + UUID().uuidString, isDirectory: true))
        do { stored = try store.load() }
        catch { loadFailed = true; recoveryFailed = true }
    }

    var records: [MobileCrossNASRecord] { stored.filter { $0.sourceContext == source?.context } }
    var isWorking: Bool { isPreparing || execution != nil }

    func configure(source: MobileCrossNASEndpoint?) {
        guard self.source?.context != source?.context || self.source.map({ ObjectIdentifier($0.repository) }) != source.map({ ObjectIdentifier($0.repository) }) else { return }
        pause(); generation = UUID(); self.source = source; error = nil
    }

    func removeProfile(_ id: UUID) {
        if preparingTargetID == id { pause() }
        if let runningID, let record = stored.first(where: { $0.id == runningID }), record.sourceID == id || record.targetID == id { pause() }
        // 保留未知提交的记录；删除配置不能解除原目标限制。
        if source?.profile.id == id { configure(source: nil) }
    }

    func clearError() { error = nil }

    @discardableResult
    func submit(items: [FileItem], target: MobileCrossNASEndpoint, destination: String, moveSource: Bool) async -> UUID? {
        guard let source, !isWorking, !loadFailed, !recoveryFailed else { return nil }
        isPreparing = true; preparingTargetID = target.profile.id; error = nil
        let token = generation
        defer { isPreparing = false; preparation = nil; preparingTargetID = nil }
        do {
            let task = Task { try await MobileCrossNASPlan.prepare(items: items, source: source, target: target,
                destination: destination, moveSource: moveSource) }
            preparation = task
            let record = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            guard !stored.contains(where: { previous in
                previous.targetContext == record.targetContext && previous.phase != .finished &&
                previous.entries.contains { old in record.entries.contains { new in
                    old.destination == new.destination || old.destination.hasPrefix(new.destination + "/") || new.destination.hasPrefix(old.destination + "/")
                } }
            }) else { throw MobileCrossNASFailure.conflict }
            stored.append(record)
            guard save() else { stored.removeAll { $0.id == record.id }; return nil }
            run(record.id, source: source, target: target, deleting: false)
            return record.id
        } catch {
            if token == generation { self.error = Self.failure(error) }
            return nil
        }
    }

    func resume(_ id: UUID, target: MobileCrossNASEndpoint) {
        guard let source, let record = record(id), record.canContinue, matches(record, source, target),
              !isWorking, !recoveryFailed else { return }
        run(id, source: source, target: target, deleting: false)
    }

    /// 调用者必须展示独立删源确认；执行前再次逐项比对，不借用先前的显示状态。
    func removeSource(_ id: UUID, target: MobileCrossNASEndpoint) {
        guard let source, let record = record(id), record.canRemoveSource, matches(record, source, target),
              !isWorking, !recoveryFailed else { return }
        run(id, source: source, target: target, deleting: true)
    }

    func pause() { generation = UUID(); preparation?.cancel(); execution?.cancel() }

    func refresh(_ id: UUID, target: MobileCrossNASEndpoint) async {
        guard let source, let record = record(id), matches(record, source, target), !isWorking,
              !recoveryFailed else { return }
        isPreparing = true
        let token = generation
        defer { isPreparing = false }
        do {
            for index in record.entries.indices {
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                let entry = record.entries[index]
                if entry.status == .uncertain && !entry.source.isDirectory {
                    try await MobileCrossNASPlan.checkSource(entry, repository: source.repository)
                    try await MobileCrossNASPlan.checkTarget(entry, repository: target.repository)
                    guard token == generation else { throw CancellationError() }
                    update(id) { $0.entries[index].status = .copied }
                } else if entry.status == .deleteUncertain {
                    let parent = MobileCrossNASPlan.parent(entry.source.path)
                    let children = try await MobileCrossNASPlan.list(parent, repository: source.repository)
                    guard !children.contains(where: { $0.path == entry.source.path }) else { throw MobileCrossNASFailure.interrupted }
                    guard token == generation else { throw CancellationError() }
                    update(id) { $0.entries[index].status = .removed }
                }
                // 创建目录丢失回执时，单凭同名目录不能继续向其中写入。
            }
            guard token == generation, let current = self.record(id) else { throw CancellationError() }
            if current.entries.allSatisfy({ $0.status == .copied }) {
                try await verify(current, source: source, target: target, deletion: false)
            }
            guard token == generation else { throw CancellationError() }
            update(id) { value in
                value.phase = Self.restingPhase(value)
                value.failure = value.hasUnknown ? .interrupted : nil
            }
            _ = save()
        } catch {
            guard token == generation else { return }
            update(id) { $0.failure = Self.failure(error) }
            _ = save()
        }
    }

    private func run(_ id: UUID, source: MobileCrossNASEndpoint, target: MobileCrossNASEndpoint, deleting: Bool) {
        guard execution == nil else { return }
        runningID = id; completedBytes = 0; totalBytes = nil
        update(id) { $0.phase = deleting ? .removing : .copying; $0.failure = nil }
        guard save() else {
            update(id) { $0.phase = .interrupted; $0.failure = .recovery }
            runningID = nil; return
        }
        execution = Task { [weak self] in
            guard let self else { return }
            defer { self.execution = nil; self.runningID = nil }
            do {
                guard let record = self.record(id) else { return }
                if deleting {
                    try await self.verify(record, source: source, target: target, deletion: true)
                    for index in record.entries.indices.reversed() {
                        try Task.checkCancellation()
                        let entry = record.entries[index]
                        if entry.status == .removed { continue }
                        if entry.source.isDirectory {
                            let current = try await MobileCrossNASPlan.info(entry.source.path, repository: source.repository)
                            guard current.isDirectory, current.permissions?.canDelete == true,
                                  MobileCrossNASPlan.isLocal(current) else { throw MobileCrossNASFailure.permission }
                            guard try await MobileCrossNASPlan.list(entry.source.path, repository: source.repository).isEmpty else { throw MobileCrossNASFailure.changed }
                            try await MobileCrossNASPlan.checkTarget(entry, repository: target.repository)
                        } else {
                            try await MobileCrossNASPlan.checkSource(entry, repository: source.repository, forDeletion: true)
                            try await MobileCrossNASPlan.checkTarget(entry, repository: target.repository)
                        }
                        try Task.checkCancellation()
                        self.update(id) { $0.entries[index].status = .deleting }
                        guard self.save() else { throw MobileCrossNASFailure.recovery }
                        let outcome = try await source.repository.deleteResult(paths: [entry.source.path], recursive: false) { _, _ in }
                        guard outcome.operation == "fileDelete" else { throw MobileCrossNASFailure.interrupted }
                        if !outcome.submitted {
                            self.update(id) { $0.entries[index].status = .copied }
                            throw outcome.status == .permissionDenied ? MobileCrossNASFailure.permission : MobileCrossNASFailure.unavailable
                        }
                        guard outcome.status == .confirmedSuccess else { throw MobileCrossNASFailure.interrupted }
                        // 只有父目录完整回读确认缺失才计为删除完成。
                        let remaining = try await MobileCrossNASPlan.list(MobileCrossNASPlan.parent(entry.source.path), repository: source.repository)
                        guard !remaining.contains(where: { $0.path == entry.source.path }) else { throw MobileCrossNASFailure.interrupted }
                        self.update(id) { $0.entries[index].status = .removed }
                        guard self.save() else { throw MobileCrossNASFailure.recovery }
                    }
                } else {
                    for index in record.entries.indices {
                        try Task.checkCancellation()
                        let entry = record.entries[index]
                        if entry.status == .copied {
                            try await MobileCrossNASPlan.checkSource(entry, repository: source.repository)
                            try await MobileCrossNASPlan.checkTarget(entry, repository: target.repository)
                            continue
                        }
                        guard entry.status == .pending else { throw MobileCrossNASFailure.interrupted }
                        try await MobileCrossNASPlan.checkSource(entry, repository: source.repository)
                        let parent = MobileCrossNASPlan.parent(entry.destination)
                        let folder = try await MobileCrossNASPlan.info(parent, repository: target.repository)
                        guard folder.isDirectory, folder.permissions?.canWrite == true,
                              MobileCrossNASPlan.isLocal(folder) else { throw MobileCrossNASFailure.permission }
                        let existing = try await MobileCrossNASPlan.list(parent, repository: target.repository)
                        guard !existing.contains(where: { $0.name == entry.source.name }) else { throw MobileCrossNASFailure.conflict }
                        try Task.checkCancellation()
                        self.completedBytes = 0; self.totalBytes = nil
                        self.update(id) { $0.entries[index].status = .writing }
                        guard self.save() else { throw MobileCrossNASFailure.recovery }
                        if entry.source.isDirectory {
                            try await target.repository.createFolder(parentPath: parent, name: entry.source.name)
                        } else {
                            try await source.repository.copyCrossNAS(entry.source, to: target.repository, folder: parent) { [weak self] completed, total in
                                Task { @MainActor in
                                    guard let self, self.runningID == id, self.source?.context == source.context,
                                          self.record(id)?.entries[index].status == .writing else { return }
                                    self.completedBytes = completed; self.totalBytes = total
                                }
                            }
                        }
                        try Task.checkCancellation()
                        try await MobileCrossNASPlan.checkSource(entry, repository: source.repository)
                        try await MobileCrossNASPlan.checkTarget(entry, repository: target.repository)
                        self.update(id) { $0.entries[index].status = .copied }
                        guard self.save() else { throw MobileCrossNASFailure.recovery }
                    }
                    guard let current = self.record(id) else { return }
                    try await self.verify(current, source: source, target: target, deletion: false)
                }
                self.update(id) { $0.phase = deleting ? .finished : .copied; $0.failure = nil }
            } catch {
                self.update(id) { record in
                    for index in record.entries.indices {
                        if record.entries[index].status == .writing { record.entries[index].status = .uncertain }
                        if record.entries[index].status == .deleting { record.entries[index].status = .deleteUncertain }
                    }
                    record.phase = .interrupted
                    record.failure = Self.failure(error)
                }
            }
            _ = self.save()
            if deleting { await self.onSourceChanged?(source.context) }
        }
    }

    private func verify(_ record: MobileCrossNASRecord, source: MobileCrossNASEndpoint,
                        target: MobileCrossNASEndpoint, deletion: Bool) async throws {
        for entry in record.entries {
            if entry.status != .removed {
                try await MobileCrossNASPlan.checkSource(entry, repository: source.repository, forDeletion: deletion,
                    allowDirectoryChange: deletion && record.entries.contains { $0.status == .removed })
            }
            try await MobileCrossNASPlan.checkTarget(entry, repository: target.repository)
        }
        try await MobileCrossNASPlan.checkTree(record.entries.filter { $0.status != .removed }, repository: source.repository, target: false)
        try await MobileCrossNASPlan.checkTree(record.entries, repository: target.repository, target: true)
        try Task.checkCancellation()
    }

    private func record(_ id: UUID) -> MobileCrossNASRecord? { stored.first { $0.id == id } }
    private func update(_ id: UUID, _ transform: (inout MobileCrossNASRecord) -> Void) {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return }
        transform(&stored[index])
    }
    private func matches(_ record: MobileCrossNASRecord, _ source: MobileCrossNASEndpoint, _ target: MobileCrossNASEndpoint) -> Bool {
        record.sourceID == source.repository.profileID && record.sourceContext == source.context &&
        record.targetID == target.repository.profileID && record.targetContext == target.context
    }
    private func save() -> Bool {
        guard !loadFailed else { return false }
        do { try store.save(stored); return true }
        catch { recoveryFailed = true; self.error = .recovery; return false }
    }
    private static func restingPhase(_ record: MobileCrossNASRecord) -> MobileCrossNASPhase {
        if record.entries.allSatisfy({ $0.status == .removed }) { return .finished }
        if record.entries.allSatisfy({ $0.status == .copied }) { return .copied }
        return record.hasUnknown ? .interrupted : .paused
    }
    private static func failure(_ error: Error) -> MobileCrossNASFailure {
        if let error = error as? MobileCrossNASFailure { return error }
        if error is CancellationError { return .interrupted }
        switch (error as? AppError)?.category {
        case .permissionDenied: return .permission
        case .authenticationRequired, .otpRequired: return .connection
        case .conflict: return .conflict
        case .versionUnsupported: return .unavailable
        default: return .interrupted
        }
    }
}

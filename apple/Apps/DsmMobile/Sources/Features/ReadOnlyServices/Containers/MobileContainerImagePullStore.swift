import DsmCore
import Foundation
import Observation

/// 原任务编号只用于恢复读取；仓库名称和凭据不持久化。
@MainActor @Observable
final class MobileContainerImagePullStore {
    enum Phase: String, Codable { case prepared, awaitingReceipt, downloading, needsReview, ready, rejected, skipped }
    enum Failure: String, Codable { case denied, unavailable, trust, changed, failed }
    struct Entry: Identifiable, Codable, Equatable {
        var id: UUID { recovery.id }
        let context: String
        let createdAt: Date
        var recovery: ContainerImagePullRecovery
        var phase: Phase = .prepared
        var accepted = false
        var percentage: Double?
        var failure: Failure?
        var isProtected: Bool { ![Phase.ready, .rejected, .skipped].contains(phase) }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []
    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ImagePulls-\(UUID())")
        reload()
    }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func protects(repository: String, tag: String, context: String) -> Bool {
        failed || entries.contains { $0.context == context && ($0.isProtected || isExecuting($0.id)) && $0.recovery.matches(repository: repository, tag: tag) }
    }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let url = root.appendingPathComponent("image-pulls-v1.json")
            var values: [Entry] = []
            if FileManager.default.fileExists(atPath: url.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); values = envelope.entries
            }
            entries = values; failed = false
            let restored = values.map { entry in
                var value = entry
                if value.phase == .prepared { value.phase = .skipped }
                return value
            }
            if values != restored { try persist(restored) }
        } catch { failed = true }
    }
    func reserve(_ request: ContainerImagePullRequest, context: String) throws -> Entry {
        guard request.isValid, request.isConfirmed, !protects(repository: request.repository, tag: request.tag, context: context) else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        let value = Entry(context: context, createdAt: Date(), recovery: .init(id: request.id,
            target: ContainerImagePullRecovery.target(repository: request.repository, tag: request.tag), baselineImageIDs: []))
        try persist(entries + [value]); executing.insert(value.id); return value
    }
    func checkpoint(_ id: UUID, _ checkpoint: ContainerImagePullCheckpoint) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), executing.contains(id) else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        var values = entries, entry = entries[index]
        switch checkpoint {
        case .willSubmit(let recovery):
            guard entry.phase == .prepared, recovery.id == id, recovery.target == entry.recovery.target, recovery.taskID == nil else {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
            entry.recovery = recovery; entry.phase = .awaitingReceipt
        case .accepted(let recovery):
            guard entry.phase == .awaitingReceipt, recovery.id == id, recovery.target == entry.recovery.target,
                  recovery.baselineImageIDs == entry.recovery.baselineImageIDs else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            entry.recovery = recovery; entry.accepted = true
            entry.phase = recovery.taskID == nil ? .awaitingReceipt : .needsReview
        case .rejected:
            guard entry.phase == .awaitingReceipt, !entry.accepted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            entry.phase = .rejected; entry.failure = .failed
        }
        values[index] = entry; try persist(values)
    }
    func update(_ progress: ContainerImagePullProgress) throws {
        guard let index = entries.firstIndex(where: { $0.id == progress.id }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries, value = entries[index]
        guard progress.repository.isEmpty || value.recovery.matches(repository: progress.repository, tag: progress.tag) else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        // 已拒绝记录只能补充失败类别，不能被后来的读取改为成功。
        guard value.phase != .rejected || progress.stage == .rejected else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        if !progress.outcome.submitted {
            guard value.phase == .prepared else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            value.phase = progress.outcome.status == .cancelledBeforeSubmission ? .skipped : .rejected
        } else {
            guard value.phase != .prepared, value.phase != .skipped else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            switch progress.stage {
            case .awaitingReceipt: value.phase = .awaitingReceipt
            case .downloading: value.phase = .downloading
            case .needsReview: value.phase = .needsReview
            case .ready: value.phase = .ready
            case .rejected: value.phase = .rejected
            }
        }
        value.percentage = progress.percentage
        switch progress.outcome.errorCategory {
        case .permission, .authentication: value.failure = .denied
        case .unsupported: value.failure = .unavailable
        case .conflict: value.failure = .changed
        case .none: value.failure = nil
        default: value.failure = .failed
        }
        values[index] = value; try persist(values)
    }
    func finish(_ id: UUID, failure: Failure? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var values = entries
        if values[index].phase == .prepared { values[index].phase = failure == nil ? .skipped : .rejected }
        if let failure { values[index].failure = failure }
        try persist(values)
    }
    func end(_ id: UUID) { executing.remove(id) }
    func remove(_ id: UUID, context: String) throws {
        guard let entry = entry(id), entry.context == context, !entry.isProtected, !isExecuting(id) else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        try persist(entries.filter { $0.id != id })
    }
    private func persist(_ values: [Entry]) throws {
        guard !failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try validate(values)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(
                to: root.appendingPathComponent("image-pulls-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], protectedTargets: Set<String> = []
        for entry in values {
            guard ids.insert(entry.id).inserted, entry.recovery.isValid,
                  entry.context.count == 64, entry.context.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  entry.createdAt.timeIntervalSince1970.isFinite,
                  entry.percentage.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
                  entry.recovery.taskID == nil || entry.accepted,
                  ![Phase.downloading, .needsReview, .ready].contains(entry.phase) || entry.recovery.taskID != nil,
                  ![Phase.prepared, .skipped].contains(entry.phase) || (!entry.accepted && entry.recovery.taskID == nil) else {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
            if entry.isProtected, !protectedTargets.insert(entry.context + entry.recovery.target).inserted {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
        }
    }
}

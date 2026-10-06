import DsmCore
import Foundation
import Observation

/// 删除记录只保留目标摘要；结果未知时持续保护原标签或裸映像。
@MainActor @Observable
final class MobileContainerImageDeletionStore {
    enum Phase: String, Codable { case prepared, submitted, succeeded, rejected, skipped }
    enum Failure: String, Codable { case denied, unavailable, changed, trust, failed }
    struct Entry: Identifiable, Codable, Equatable {
        var id: UUID { recovery.id }
        let context: String
        let createdAt: Date
        let recovery: ContainerImageDeletionRecovery
        var phase: Phase = .prepared
        var accepted = false
        var removedTargetIDs: Set<String> = []
        var failure: Failure?
        var isProtected: Bool { phase == .prepared || phase == .submitted }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []
    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ImageDeletions-\(UUID())")
        reload()
    }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func protects(_ targets: [ContainerImageDeletionTarget], context: String) -> Bool {
        failed || entries.contains { entry in
            entry.context == context && (entry.isProtected || isExecuting(entry.id)) && entry.recovery.targets.contains { original in
                targets.contains(where: original.overlaps)
            }
        }
    }
    func protectsPull(repository: String, tag: String, context: String) -> Bool {
        let reference = ContainerImagePullRecovery.target(repository: repository, tag: tag)
        return failed || entries.contains {
            $0.context == context && ($0.isProtected || isExecuting($0.id)) && $0.recovery.targets.contains { $0.reference == reference }
        }
    }
    func protectsPull(_ pull: ContainerImagePullRecovery, context: String) -> Bool {
        failed || entries.contains {
            $0.context == context && ($0.isProtected || isExecuting($0.id)) && $0.recovery.targets.contains { $0.overlaps(pull) }
        }
    }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let url = root.appendingPathComponent("image-deletions-v1.json")
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
            if restored != values { try persist(restored) }
        } catch { failed = true }
    }
    func reserve(_ request: ContainerImageDeletionRequest, context: String) throws -> Entry {
        guard request.isConfirmed, request.isValid, !protects(request.recovery.targets, context: context) else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        let value = Entry(context: context, createdAt: Date(), recovery: request.recovery)
        try persist(entries + [value]); executing.insert(value.id); return value
    }
    func checkpoint(_ id: UUID, _ checkpoint: ContainerImageDeletionCheckpoint) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), isExecuting(id) else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        var values = entries
        switch checkpoint {
        case .willSubmit(let recovery):
            guard values[index].phase == .prepared, values[index].recovery == recovery else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].phase = .submitted
        case .accepted:
            guard values[index].phase == .submitted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].accepted = true
        case .rejected:
            guard values[index].phase == .submitted, !values[index].accepted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].phase = .rejected; values[index].failure = .failed
        }
        try persist(values)
    }
    func update(_ progress: ContainerImageDeletionProgress) throws {
        guard let index = entries.firstIndex(where: { $0.id == progress.id }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries, value = entries[index]
        let result = progress.outcome
        guard progress.removedTargetIDs.isSubset(of: value.recovery.targetIDs),
              progress.removedTargetIDs.count == result.counts.succeeded,
              value.phase != .rejected || (result.counts.unknown == 0 && result.counts.succeeded == 0) else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        if !result.submitted {
            guard value.phase == .prepared else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            value.phase = result.status == .cancelledBeforeSubmission ? .skipped : .rejected
        } else {
            guard value.phase == .submitted || value.phase == .rejected else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            value.removedTargetIDs.formUnion(progress.removedTargetIDs)
            if result.status == .confirmedSuccess { value.phase = .succeeded }
            else if result.counts.unknown == 0 { value.phase = .rejected }
        }
        switch result.errorCategory {
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
                to: root.appendingPathComponent("image-deletions-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], protected: [(String, ContainerImageDeletionTarget)] = []
        for value in values {
            guard ids.insert(value.id).inserted, value.recovery.isValid,
                  value.context.count == 64, value.context.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  value.createdAt.timeIntervalSince1970.isFinite,
                  value.removedTargetIDs.isSubset(of: value.recovery.targetIDs),
                  value.phase != .succeeded || value.removedTargetIDs == value.recovery.targetIDs,
                  ![Phase.prepared, .skipped, .rejected].contains(value.phase) || value.removedTargetIDs.isEmpty,
                  ![Phase.prepared, .skipped].contains(value.phase) || !value.accepted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if value.isProtected {
                for target in value.recovery.targets {
                    guard !protected.contains(where: { $0.0 == value.context && target.overlaps($0.1) }) else {
                        throw MobileTransferRecoveryStore.StoreError.invalidRecord
                    }
                }
                protected += value.recovery.targets.map { (value.context, $0) }
            }
        }
    }
}

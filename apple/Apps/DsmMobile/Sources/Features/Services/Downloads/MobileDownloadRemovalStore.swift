import DsmCore
import Foundation
import Observation

/// 只保存任务身份摘要、动作与阶段；任务移除不作为下载文件状态的证明。
@MainActor
@Observable
final class MobileDownloadRemovalStore {
    enum Phase: String, Codable { case planned, submitted, complete, failed, cancelled }
    enum Failure: String, Codable { case changed, denied, unavailable }
    struct Item: Codable, Equatable, Identifiable {
        let id: UUID
        let removal: DownloadTaskRemoval
        var phase: Phase = .planned
        var failure: Failure?
        var taskID: String { removal.taskID }
        init(removal: DownloadTaskRemoval) { id = UUID(); self.removal = removal }
    }
    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        let context: String
        let createdAt: Date
        var items: [Item]
        var hasSubmitted: Bool { items.contains { $0.phase == .submitted } }
        var hasPlanned: Bool { items.contains { $0.phase == .planned } }
        var hasUnfinished: Bool { hasSubmitted || hasPlanned }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("DownloadRemovals-\(UUID())")
        do {
            let url = self.root.appendingPathComponent("removals-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard value.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(value.entries); entries = value.entries
            }
        } catch { failed = true }
    }
    func entry(_ id: UUID, context: String) -> Entry? { entries.first { $0.id == id && $0.context == context } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func begin(_ id: UUID, context: String) -> Bool {
        guard !failed, entry(id, context: context) != nil else { return false }
        return executing.insert(id).inserted
    }
    func end(_ id: UUID) { executing.remove(id) }
    func protects(_ taskID: String, context: String) -> Bool {
        failed || entries.contains { $0.context == context && $0.items.contains {
            $0.taskID == taskID && ($0.phase == .planned || $0.phase == .submitted)
        } }
    }
    func reserve(_ entry: Entry) throws {
        guard entry.items.allSatisfy({ $0.phase == .planned && $0.failure == nil }) else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        try persist(entries + [entry])
    }
    func progress(_ itemID: UUID, in id: UUID, context: String, phase: Phase, failure: Failure? = nil) throws {
        try update(id, context: context) { entry in
            guard let index = entry.items.firstIndex(where: { $0.id == itemID }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            let old = entry.items[index].phase
            guard (old == .planned && [.submitted, .failed, .cancelled].contains(phase))
                    || (old == .submitted && [.complete, .failed, .cancelled].contains(phase)),
                  (phase == .failed) == (failure != nil) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            entry.items[index].phase = phase; entry.items[index].failure = failure
        }
    }
    func cancelRemaining(_ id: UUID, context: String) throws {
        // 立即保存取消，切换账号或终止进程也不能丢失用户决定；提交项保持不变。
        try update(id, context: context, requiresExecution: false) { entry in
            for index in entry.items.indices where entry.items[index].phase == .planned { entry.items[index].phase = .cancelled }
        }
    }
    func remove(_ id: UUID, context: String) throws {
        guard let entry = entry(id, context: context), !entry.hasUnfinished, !isExecuting(id) else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        try persist(entries.filter { $0.id != id })
    }
    private func update(_ id: UUID, context: String, requiresExecution: Bool = true, change: (inout Entry) throws -> Void) throws {
        guard !failed, !requiresExecution || isExecuting(id),
              let index = entries.firstIndex(where: { $0.id == id && $0.context == context }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var updated = entries; try change(&updated[index]); try persist(updated)
    }
    private func persist(_ values: [Entry]) throws {
        guard !failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try validate(values)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(
                to: root.appendingPathComponent("removals-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var identities: Set<UUID> = [], occupied: Set<String> = []
        for entry in values {
            guard identities.insert(entry.id).inserted, Self.isDigest(entry.context),
                  entry.createdAt.timeIntervalSince1970.isFinite, !entry.items.isEmpty,
                  Set(entry.items.map(\.taskID)).count == entry.items.count,
                  Set(entry.items.map { $0.removal.forceComplete }).count == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            for item in entry.items {
                guard identities.insert(item.id).inserted, item.removal.isValid,
                      (item.phase == .failed) == (item.failure != nil) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                if item.phase == .planned || item.phase == .submitted {
                    let key = try JSONEncoder().encode([entry.context, item.taskID]).base64EncodedString()
                    guard occupied.insert(key).inserted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                }
            }
        }
    }
    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

import DsmCore
import Foundation
import Observation

/// 删除批次只记录原身份和摘要；已经提交的消息不能通过取消、刷新或重新选择解除保护。
@MainActor
@Observable
final class MobileChatDeletionStore {
    enum Phase: String, Codable { case planned, submitted, complete, failed, cancelled }
    enum Failure: String, Codable { case changed, denied, unavailable }
    struct Item: Codable, Equatable, Identifiable {
        let id: UUID
        let source: ChatMessageDeletionSnapshot
        var phase: Phase = .planned
        var failure: Failure?
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
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ChatDeletion-\(UUID())")
        do {
            let url = self.root.appendingPathComponent("message-deletions-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard value.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(value.entries); entries = value.entries
            }
        } catch { failed = true }
    }

    func entry(_ id: UUID, in context: String) -> Entry? { entries.first { $0.id == id && $0.context == context } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func begin(_ id: UUID, in context: String) -> Bool {
        guard !failed, entry(id, in: context) != nil else { return false }
        return executing.insert(id).inserted
    }
    func end(_ id: UUID) { executing.remove(id) }
    func reserve(_ entry: Entry) throws {
        guard entry.items.allSatisfy({ $0.phase == .planned && $0.failure == nil }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try persist(entries + [entry])
    }
    func progress(_ itemID: UUID, in id: UUID, context: String, phase: Phase, failure: Failure? = nil) throws {
        try update(id, context: context) { entry in
            guard let index = entry.items.firstIndex(where: { $0.id == itemID }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            let old = entry.items[index].phase
            guard (old == .planned && [.submitted, .complete, .failed].contains(phase))
                    || (old == .submitted && [.complete, .failed].contains(phase)),
                  (phase == .failed) == (failure != nil) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            entry.items[index].phase = phase; entry.items[index].failure = failure
        }
    }
    func cancelRemaining(_ id: UUID, context: String) throws {
        guard !isExecuting(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try update(id, context: context, requiresExecution: false) { entry in
            for index in entry.items.indices where entry.items[index].phase == .planned { entry.items[index].phase = .cancelled }
        }
    }
    func remove(_ id: UUID, context: String) throws {
        guard let entry = entry(id, in: context), !entry.hasUnfinished, !isExecuting(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try persist(entries.filter { $0.id != id })
    }
    private func update(_ id: UUID, context: String, requiresExecution: Bool = true, change: (inout Entry) throws -> Void) throws {
        guard !failed, !requiresExecution || isExecuting(id),
              let index = entries.firstIndex(where: { $0.id == id && $0.context == context }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var updated = entries; try change(&updated[index]); try persist(updated)
    }
    private func persist(_ value: [Entry]) throws {
        guard !failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try validate(value)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: value)).write(
                to: root.appendingPathComponent("message-deletions-v1.json"), options: [.atomic, .completeFileProtection])
            entries = value
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var identities: Set<UUID> = [], occupied: Set<String> = []
        for entry in values {
            guard identities.insert(entry.id).inserted, !entry.context.isEmpty, entry.createdAt.timeIntervalSince1970.isFinite,
                  !entry.items.isEmpty, Set(entry.items.map { $0.source.conversationID }).count == 1,
                  Set(entry.items.map { $0.source.senderID }).count == 1,
                  Set(entry.items.map { $0.source.messageID }).count == entry.items.count else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            for item in entry.items {
                try item.source.validate()
                guard identities.insert(item.id).inserted, (item.phase == .failed) == (item.failure != nil) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                if item.phase == .planned || item.phase == .submitted {
                    let key = try JSONEncoder().encode([entry.context, item.source.conversationID, item.source.messageID]).base64EncodedString()
                    guard occupied.insert(key).inserted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                }
            }
        }
    }
}

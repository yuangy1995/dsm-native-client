import Foundation
import Observation

/// 单聊创建恢复只保存目标身份与提交阶段；后续读取不能重新触发创建。
@MainActor
@Observable
final class MobileChatConversationCreationStore {
    struct Entry: Codable, Equatable, Identifiable {
        enum Phase: String, Codable { case prepared, submitted }
        let id: UUID
        let context: String
        let userID: String
        var phase: Phase
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ChatConversationCreation-\(UUID())")
        do {
            let url = self.root.appendingPathComponent("conversation-creation-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard value.version == 1, Set(value.entries.map(\.id)).count == value.entries.count,
                      Set(value.entries.map(\.context)).count == value.entries.count,
                      value.entries.allSatisfy({ !$0.context.isEmpty && !$0.userID.isEmpty
                          && $0.userID == $0.userID.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
                    throw MobileTransferRecoveryStore.StoreError.invalidRecord
                }
                entries = value.entries
            }
        } catch { failed = true }
    }

    func pending(in context: String) -> Entry? { entries.first { $0.context == context } }
    func isExecuting(_ entry: Entry) -> Bool { executing.contains(entry.id) }
    func beginExecution(_ entry: Entry) -> Bool {
        guard entries.contains(where: { $0.id == entry.id && $0.context == entry.context && $0.userID == entry.userID }) else { return false }
        return executing.insert(entry.id).inserted
    }
    func endExecution(_ entry: Entry) { executing.remove(entry.id) }

    func reserve(_ entry: Entry) -> Bool {
        guard !failed, !entry.context.isEmpty, !entry.userID.isEmpty, entry.phase == .prepared,
              entry.userID == entry.userID.trimmingCharacters(in: .whitespacesAndNewlines),
              !entries.contains(where: { $0.id == entry.id || $0.context == entry.context }) else { return false }
        return persist(entries + [entry])
    }

    func markSubmitted(_ entry: Entry) throws {
        guard !failed, let index = entries.firstIndex(where: {
            $0.id == entry.id && $0.context == entry.context && $0.userID == entry.userID && $0.phase == .prepared
        }), executing.contains(entry.id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var updated = entries; updated[index].phase = .submitted
        guard persist(updated) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
    }

    @discardableResult
    func finish(_ entry: Entry) -> Bool {
        guard !failed, entries.contains(where: { $0.id == entry.id && $0.context == entry.context && $0.userID == entry.userID }) else { return false }
        return persist(entries.filter { $0.id != entry.id })
    }

    private func persist(_ value: [Entry]) -> Bool {
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: value)).write(
                to: root.appendingPathComponent("conversation-creation-v1.json"), options: [.atomic, .completeFileProtection])
            entries = value; return true
        } catch { failed = true; return false }
    }
}

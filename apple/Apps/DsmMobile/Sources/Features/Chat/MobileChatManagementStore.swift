import Foundation
import Observation

/// 只保留当前开发格式的操作身份，不保存会话名称、消息正文或认证资料。
@MainActor
@Observable
final class MobileChatManagementStore {
    struct Entry: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case pin, unpin, close }
        let id: UUID
        let context: String
        let kind: Kind
        let conversationID: String
        let messageID: String?
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    @ObservationIgnored private var executing: Set<UUID> = []

    func beginExecution(_ entry: Entry) { executing.insert(entry.id) }
    func endExecution(_ entry: Entry) { executing.remove(entry.id) }
    func isExecuting(_ entry: Entry) -> Bool { executing.contains(entry.id) }

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ChatManagement-\(UUID())")
        do {
            let url = self.root.appendingPathComponent("management-actions-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard value.version == 1, Set(value.entries.map(\.id)).count == value.entries.count,
                      value.entries.allSatisfy({ !$0.context.isEmpty && !$0.conversationID.isEmpty
                          && ($0.kind == .close ? $0.messageID == nil : $0.messageID?.isEmpty == false) }) else {
                    throw MobileTransferRecoveryStore.StoreError.invalidRecord
                }
                entries = value.entries
            }
        } catch { failed = true }
    }

    func reserve(_ entry: Entry) -> Bool {
        guard !failed, !entries.contains(where: { $0.id == entry.id || ($0.context == entry.context
            && $0.conversationID == entry.conversationID
            && ($0.kind == .close || entry.kind == .close || $0.messageID == entry.messageID)) }) else { return false }
        return persist(entries + [entry])
    }

    @discardableResult
    func finish(_ entry: Entry) -> Bool {
        guard !failed else { return false }
        return persist(entries.filter { $0.id != entry.id })
    }

    private func persist(_ value: [Entry]) -> Bool {
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: value)).write(
                to: root.appendingPathComponent("management-actions-v1.json"), options: [.atomic, .completeFileProtection])
            entries = value; return true
        } catch { failed = true; return false }
    }
}

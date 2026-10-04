import CryptoKit
import Foundation
import Observation

/// 只记录未结束消息操作的身份与摘要；重启恢复只读取，不重放写入。
@MainActor
@Observable
final class MobileChatInteractionStore {
    struct Entry: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case edit, reply }
        let id: UUID
        let context: String
        let kind: Kind
        let conversationID: String
        let messageID: String
        let threadID: String?
        let senderID: String
        let textDigest: String
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("MobileChat-\(UUID())")
        do {
            let url = self.root.appendingPathComponent("interactions-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let record = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard record.version == 1, Set(record.entries.map(\.id)).count == record.entries.count,
                      record.entries.allSatisfy({ !$0.context.isEmpty && !$0.conversationID.isEmpty
                          && !$0.messageID.isEmpty && !$0.senderID.isEmpty && $0.textDigest.count == 64 }) else {
                    throw MobileTransferRecoveryStore.StoreError.invalidRecord
                }
                entries = record.entries
            }
        } catch { failed = true }
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func reserve(_ entry: Entry) -> Bool {
        guard !failed, !entries.contains(where: { $0.id == entry.id || ($0.context == entry.context
            && $0.kind == entry.kind && $0.conversationID == entry.conversationID
            && $0.messageID == entry.messageID && (entry.kind == .edit || $0.textDigest == entry.textDigest)) }) else { return false }
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
                to: root.appendingPathComponent("interactions-v1.json"), options: [.atomic, .completeFileProtection])
            entries = value
            return true
        } catch { failed = true; return false }
    }
}

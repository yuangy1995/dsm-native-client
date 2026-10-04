import Foundation
import Observation

/// 当前开发格式只记录身份与摘要；未收到创建回执时不能通过同内容推断归属。
@MainActor
@Observable
final class MobileChatPollStore {
    struct Entry: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case create, vote }
        let id: UUID
        let context: String
        let kind: Kind
        let conversationID: String
        var messageID: String?
        let threadID: String?
        let contentDigest: String
        let choicesDigest: String?
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("MobileChatPolls-\(UUID())")
        do {
            let url = self.root.appendingPathComponent("polls-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard value.version == 1, Set(value.entries.map(\.id)).count == value.entries.count,
                      value.entries.allSatisfy({ !$0.context.isEmpty && !$0.conversationID.isEmpty && $0.contentDigest.count == 64
                          && ($0.messageID == nil || $0.messageID?.isEmpty == false)
                          && ($0.kind == .create || ($0.messageID != nil && $0.choicesDigest?.count == 64)) }) else {
                    throw MobileTransferRecoveryStore.StoreError.invalidRecord
                }
                entries = value.entries
            }
        } catch { failed = true }
    }

    func reserve(_ entry: Entry) -> Bool {
        guard !failed, !entries.contains(where: { $0.id == entry.id || ($0.context == entry.context
            && $0.conversationID == entry.conversationID && $0.kind == entry.kind
            && (entry.kind == .create || $0.messageID == entry.messageID)) }) else { return false }
        return persist(entries + [entry])
    }

    func recordCreatedMessage(_ id: String, entry: Entry) throws {
        guard !failed, !id.isEmpty, let index = entries.firstIndex(where: { $0.id == entry.id }),
              entries[index].messageID == nil || entries[index].messageID == id else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        var updated = entries; updated[index].messageID = id
        guard persist(updated) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
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
                to: root.appendingPathComponent("polls-v1.json"), options: [.atomic, .completeFileProtection])
            entries = value; return true
        } catch { failed = true; return false }
    }
}

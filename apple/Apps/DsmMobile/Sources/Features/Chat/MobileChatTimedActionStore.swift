import Foundation
import Observation

/// 当前开发格式只保存操作身份、时间与内容摘要，不保存消息正文或凭据。
@MainActor
@Observable
final class MobileChatTimedActionStore {
    struct Entry: Codable, Equatable, Identifiable {
        enum Kind: String, Codable {
            case setReminder, deleteReminder, createSchedule, deleteSchedule
            var isReminder: Bool { self == .setReminder || self == .deleteReminder }
        }
        let id: UUID
        let context: String
        let kind: Kind
        let conversationID: String
        var targetID: String?
        let time: Date
        let textDigest: String?
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("MobileChatTimedActions-\(UUID())")
        do {
            let url = self.root.appendingPathComponent("timed-actions-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard value.version == 1, Set(value.entries.map(\.id)).count == value.entries.count,
                      value.entries.allSatisfy({ !$0.context.isEmpty && !$0.conversationID.isEmpty
                          && $0.time.timeIntervalSince1970.isFinite
                          && ($0.kind == .createSchedule || $0.targetID?.isEmpty == false)
                          && ($0.targetID == nil || $0.targetID?.isEmpty == false)
                          && ($0.kind.isReminder || $0.textDigest?.count == 64) }) else {
                    throw MobileTransferRecoveryStore.StoreError.invalidRecord
                }
                entries = value.entries
            }
        } catch { failed = true }
    }

    func reserve(_ entry: Entry) -> Bool {
        guard !failed, !entries.contains(where: { $0.id == entry.id || ($0.context == entry.context
            && $0.conversationID == entry.conversationID && $0.kind.isReminder == entry.kind.isReminder
            && (($0.kind == .createSchedule && entry.kind == .createSchedule) || $0.targetID == entry.targetID)) }) else { return false }
        return persist(entries + [entry])
    }

    func recordCreatedSchedule(_ id: String, entry: Entry) throws {
        guard !failed, !id.isEmpty, let index = entries.firstIndex(where: { $0.id == entry.id && $0.kind == .createSchedule }),
              entries[index].targetID == nil || entries[index].targetID == id else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        var updated = entries; updated[index].targetID = id
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
                to: root.appendingPathComponent("timed-actions-v1.json"), options: [.atomic, .completeFileProtection])
            entries = value; return true
        } catch { failed = true; return false }
    }
}

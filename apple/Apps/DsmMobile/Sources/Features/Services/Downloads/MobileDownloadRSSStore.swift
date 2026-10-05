import Foundation
import Observation

/// 更新恢复只保留原站点摘要和日期；不保存订阅地址、用户名、标题或条目正文。
@MainActor
@Observable
final class MobileDownloadRSSStore {
    enum Phase: String, Codable { case submitted, accepted, updated, denied, rejected, cancelled }
    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        let context: String
        let siteID: Int
        let identityDigest: String
        let baseline: Int64
        let createdAt: Date
        var phase: Phase = .submitted
        var unfinished: Bool { phase == .submitted || phase == .accepted }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("DownloadRSS-\(UUID())")
        do {
            let url = self.root.appendingPathComponent("rss-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); entries = envelope.entries
            }
        } catch { failed = true }
    }

    func reserve(_ value: Entry) throws {
        guard value.phase == .submitted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try persist(entries.filter { $0.context != value.context || $0.siteID != value.siteID || $0.unfinished } + [value])
    }

    func progress(_ id: UUID, phase: Phase) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].unfinished,
              phase != .submitted, entries[index].phase == .submitted || phase == .updated else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        var values = entries; values[index].phase = phase; try persist(values)
    }

    private func persist(_ values: [Entry]) throws {
        guard !failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try validate(values)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(
                to: root.appendingPathComponent("rss-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }

    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], targets: Set<String> = []
        func digest(_ text: String) -> Bool { text.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        for entry in values {
            guard ids.insert(entry.id).inserted, digest(entry.context), digest(entry.identityDigest),
                  entry.siteID >= 0, entry.baseline >= 0, entry.createdAt.timeIntervalSince1970.isFinite,
                  !entry.unfinished || targets.insert(entry.context + ":" + String(entry.siteID)).inserted else {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
        }
    }
}

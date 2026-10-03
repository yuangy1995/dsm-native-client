import Foundation

/// 只保存未结束操作的身份；没有密码、会话或分享 URL。恢复不重放写请求。
@MainActor
final class MobileFileShareRecoveryStore {
    struct Entry: Codable, Hashable {
        let profileID: UUID
        let context: String
        let operation: String
        let target: String
    }
    private struct Envelope: Codable { let version: Int; let entries: Set<Entry> }
    private let root: URL
    private(set) var entries: Set<Entry> = []
    private(set) var failed = false

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("MobileSharing-\(UUID())")
        let file = self.root.appendingPathComponent("sharing-v1.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
                guard value.version == 1, value.entries.allSatisfy({ !$0.context.isEmpty && !$0.target.isEmpty
                    && ["create", "edit", "delete"].contains($0.operation) }) else {
                    throw MobileTransferRecoveryStore.StoreError.invalidRecord
                }
                entries = value.entries
            }
        } catch { failed = true }
    }

    func reserve(_ entry: Entry) -> Bool {
        guard !failed, !entries.contains(entry) else { return false }
        entries.insert(entry)
        do { try save(); return true } catch { failed = true; return false }
    }

    func finish(_ entry: Entry) {
        guard !failed else { return }
        let previous = entries
        entries.remove(entry)
        do { try save() } catch { entries = previous; failed = true }
    }

    func removeProfile(_ profileID: UUID) {
        guard !failed else { return }
        let previous = entries
        entries = entries.filter { $0.profileID != profileID }
        do { try save() } catch { entries = previous; failed = true }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var protectedRoot = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedRoot.setResourceValues(values)
        try JSONEncoder().encode(Envelope(version: 1, entries: entries)).write(
            to: root.appendingPathComponent("sharing-v1.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

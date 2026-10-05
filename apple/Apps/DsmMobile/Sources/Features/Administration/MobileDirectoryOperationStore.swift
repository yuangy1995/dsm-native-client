import CryptoKit
import DsmCore
import Foundation
import Observation

/// 只保存账号上下文、目标与资料摘要，名称、邮件、群组正文和密码不落盘。
@MainActor @Observable
final class MobileDirectoryOperationStore {
    enum Phase: String, Codable { case prepared, submitted, succeeded, failed, cancelled }
    enum Failure: String, Codable { case denied, unavailable, changed, failed }
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let context: String
        let action: NasDirectoryAction
        let target: String
        let originalID: Int64?
        let expected: String?
        let includesGroups: Bool
        let requiresAcknowledgement: Bool
        let createdAt: Date
        var phase: Phase = .prepared
        var accepted = false
        var failure: Failure?
        var isUnfinished: Bool { phase == .prepared || phase == .submitted }
        var isDeletion: Bool { action == .deleteUser || action == .deleteGroup }
        var kind: NasAccount.Kind { action == .saveUser || action == .deleteUser ? .user : .group }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("Directory-\(UUID())")
        reload()
    }
    static func digest(_ values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func target(kind: NasAccount.Kind, name: String) -> String { digest([kind.rawValue, name.lowercased()]) }
    private static func signature(name: String, description: String, email: String?, expired: Bool, groups: [String]?) -> String {
        digest([name, description, email ?? "", String(expired)] + (groups?.sorted() ?? []))
    }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let url = root.appendingPathComponent("directory-operations-v1.json")
            let values: [Entry]
            if FileManager.default.fileExists(atPath: url.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); values = envelope.entries
            } else { values = [] }
            failed = false; entries = values
            if values.contains(where: { $0.phase == .prepared }) {
                try persist(values.map { var value = $0; if value.phase == .prepared { value.phase = .cancelled }; return value })
            }
        } catch { failed = true }
    }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func protects(_ change: NasDirectoryChange, context: String) -> Bool {
        let target = Self.target(kind: change.kind, name: change.name)
        return failed || entries.contains { $0.context == context && $0.target == target && ($0.isUnfinished || executing.contains($0.id)) }
    }
    func reserve(_ change: NasDirectoryChange, context: String) throws -> Entry {
        guard !protects(change, context: context) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let expected: String?, includesGroups: Bool
        switch change {
        case .saveUser(let original, let draft, _):
            let groups = draft.groups ?? original?.groups
            includesGroups = groups != nil
            expected = Self.signature(name: change.name, description: draft.description, email: draft.email, expired: draft.isExpired, groups: groups)
        case .saveGroup(_, let draft):
            includesGroups = false
            expected = Self.signature(name: change.name, description: draft.description, email: nil, expired: false, groups: nil)
        case .delete: includesGroups = false; expected = nil
        }
        let value = Entry(id: UUID(), context: context, action: change.action,
            target: Self.target(kind: change.kind, name: change.name), originalID: change.original?.numericID,
            expected: expected, includesGroups: includesGroups, requiresAcknowledgement: change.requiresAcknowledgement, createdAt: Date())
        try persist(entries + [value]); executing.insert(value.id); return value
    }
    func checkpoint(_ id: UUID, stage: NasDirectoryCheckpoint) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), executing.contains(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries
        switch stage {
        case .willSubmit:
            guard values[index].phase == .prepared else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].phase = .submitted
        case .accepted:
            guard values[index].phase == .submitted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].accepted = true
        }
        try persist(values)
    }
    func finish(_ id: UUID, phase: Phase, failure: Failure? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isUnfinished,
              ![Phase.prepared, .submitted].contains(phase),
              phase != .succeeded || entries[index].phase == .submitted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries; values[index].phase = phase; values[index].failure = failure
        try persist(values)
    }
    func end(_ id: UUID) { executing.remove(id) }
    func resolve(_ directory: NasAccountDirectory, context: String) throws {
        for entry in entries where entry.context == context && entry.phase == .submitted && !isExecuting(entry.id) {
            let current = (entry.kind == .user ? directory.users : directory.groups).first { Self.target(kind: $0.kind, name: $0.name) == entry.target }
            if entry.isDeletion {
                if current == nil { try finish(entry.id, phase: .succeeded) }
            } else if let current, let description = current.description, current.numericID != nil,
                      entry.originalID == nil || entry.originalID == current.numericID,
                      entry.kind == .group || current.canEdit && current.email != nil,
                      !entry.includesGroups || current.groups != nil,
                      !entry.requiresAcknowledgement || entry.accepted,
                      Self.signature(name: current.name, description: description, email: current.email,
                          expired: current.isExpired, groups: entry.includesGroups ? current.groups : nil) == entry.expected {
                try finish(entry.id, phase: .succeeded)
            }
        }
    }
    func remove(_ id: UUID, context: String) throws {
        guard let value = entry(id), value.context == context, !value.isUnfinished, !isExecuting(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try persist(entries.filter { $0.id != id })
    }
    private func persist(_ values: [Entry]) throws {
        guard !failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try validate(values)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(
                to: root.appendingPathComponent("directory-operations-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], targets: Set<String> = []
        for entry in values {
            guard ids.insert(entry.id).inserted, Self.isDigest(entry.context), Self.isDigest(entry.target),
                  entry.createdAt.timeIntervalSince1970.isFinite, entry.originalID.map({ $0 >= 0 }) ?? true,
                  entry.isDeletion == (entry.expected == nil), entry.expected.map(Self.isDigest) ?? true,
                  !entry.isDeletion || entry.originalID != nil,
                  (entry.phase == .failed) == (entry.failure != nil),
                  !entry.accepted || ![Phase.prepared, .cancelled].contains(entry.phase),
                  !entry.requiresAcknowledgement || !entry.isDeletion,
                  entry.originalID != nil || entry.requiresAcknowledgement,
                  entry.phase != .succeeded || !entry.requiresAcknowledgement || entry.accepted,
                  !entry.includesGroups || entry.action == .saveUser else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if entry.isUnfinished, !targets.insert(entry.context + entry.target).inserted { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        }
    }
    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

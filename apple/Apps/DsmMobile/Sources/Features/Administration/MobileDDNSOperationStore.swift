import CryptoKit
import DsmCore
import Foundation
import Observation

/// 仅保存身份和配置摘要；密码、域名、账号与网络地址不进入持久记录。
@MainActor @Observable
final class MobileDDNSOperationStore {
    enum Phase: String, Codable { case prepared, submitted, succeeded, failed, cancelled, unconfirmed }
    enum Failure: String, Codable { case denied, unavailable, changed, failed }
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let context: String
        let action: NasDDNSAction
        let provider: String?
        let expected: String?
        let needsCredentialAcknowledgement: Bool
        let createdAt: Date
        var phase: Phase = .prepared
        var accepted = false
        var failure: Failure?
        var isUnfinished: Bool { phase == .prepared || phase == .submitted }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("DDNS-\(UUID())")
        reload()
    }
    static func digest(_ values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func signature(_ record: NasDDNSRecord) -> String {
        digest([record.providerID, record.hostname.lowercased(), record.username ?? "",
                String(record.isEnabled), String(record.heartbeat)])
    }
    static func signature(_ draft: NasDDNSDraft) -> String {
        digest([draft.normalizedProviderID, draft.normalizedHostname, draft.normalizedUsername,
                String(draft.isEnabled), String(draft.heartbeat)])
    }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let url = root.appendingPathComponent("ddns-operations-v1.json")
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
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func protects(_ change: NasDDNSChange, context: String) -> Bool {
        let target = change.providerID.map { Self.digest([$0]) }
        return failed || entries.contains {
            $0.context == context && ($0.isUnfinished || executing.contains($0.id))
                && ($0.provider == nil || target == nil || $0.provider == target)
        }
    }
    func reserve(_ change: NasDDNSChange, context: String) throws -> Entry {
        guard !protects(change, context: context) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let signature = change.draft.map(Self.signature)
        let credentialOnly = change.action == .save && (change.draft.map { draft in
            !draft.password.isEmpty && draft.providerID != "Synology"
                && change.original.map(Self.signature) == signature
        } ?? false)
        let value = Entry(id: UUID(), context: context, action: change.action,
            provider: change.providerID.map { Self.digest([$0]) }, expected: change.action == .save ? signature : nil,
            needsCredentialAcknowledgement: credentialOnly, createdAt: Date())
        try persist(entries + [value]); executing.insert(value.id); return value
    }
    func checkpoint(_ id: UUID, stage: NasDDNSCheckpoint) throws {
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
    func resolve(_ directory: NasDDNSDirectory, context: String) throws {
        for entry in entries where entry.context == context && entry.phase == .submitted && !isExecuting(entry.id) {
            let current = directory.records.first { Self.digest([$0.providerID]) == entry.provider }
            switch entry.action {
            case .save:
                if let current, Self.signature(current) == entry.expected,
                   !entry.needsCredentialAcknowledgement || entry.accepted { try finish(entry.id, phase: .succeeded) }
            case .delete:
                if current == nil { try finish(entry.id, phase: .succeeded) }
            case .test, .updateAddress:
                // 瞬时动作不能凭列表推断结果；没有回执时仅允许新的显式操作，不自动重发。
                try finish(entry.id, phase: entry.accepted ? .succeeded : .unconfirmed)
            }
        }
    }
    func remove(_ id: UUID, context: String) throws {
        guard let value = entry(id), value.context == context, !value.isUnfinished, !isExecuting(id) else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        try persist(entries.filter { $0.id != id })
    }
    private func persist(_ values: [Entry]) throws {
        guard !failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try validate(values)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(
                to: root.appendingPathComponent("ddns-operations-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], providers: [String: Set<String>] = [:]
        for entry in values {
            guard ids.insert(entry.id).inserted, Self.isDigest(entry.context), entry.createdAt.timeIntervalSince1970.isFinite,
                  entry.provider.map(Self.isDigest) ?? (entry.action == .updateAddress),
                  (entry.action == .updateAddress) == (entry.provider == nil),
                  (entry.action == .save) == (entry.expected != nil), entry.expected.map(Self.isDigest) ?? true,
                  (entry.phase == .failed) == (entry.failure != nil),
                  entry.phase != .unconfirmed || [.test, .updateAddress].contains(entry.action),
                  !entry.accepted || ![Phase.prepared, .cancelled].contains(entry.phase),
                  !entry.needsCredentialAcknowledgement || entry.action == .save else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if entry.isUnfinished {
                let target = entry.provider ?? "all"
                let previous = providers[entry.context] ?? []
                guard !previous.contains(target), !previous.contains("all"), target != "all" || previous.isEmpty else {
                    throw MobileTransferRecoveryStore.StoreError.invalidRecord
                }
                providers[entry.context, default: []].insert(target)
            }
        }
    }
    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

import CryptoKit
import DsmCore
import Foundation
import Observation

/// 服务设置共用一个受保护记录文件；地址、端口正文、账号和凭据均不落盘。
@MainActor @Observable
final class MobileServiceOperationStore {
    enum Stage: String, Codable { case prepared, submitted, verified, rejected, skipped }
    enum Phase: String { case prepared, submitted, succeeded, partial, failed, cancelled }
    enum Failure: String, Codable { case denied, unavailable, changed, failed }
    struct Part: Equatable, Codable {
        let step: NasServiceStep
        let expected: String
        var stage: Stage = .prepared
        var accepted = false
        var hasPartialFields = false
    }
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let context: String
        let kind: NasServiceKind
        let createdAt: Date
        var parts: [Part]
        var failure: Failure?
        var isUnfinished: Bool { parts.contains { $0.stage == .prepared || $0.stage == .submitted } }
        var hasSavedChanges: Bool { parts.contains { $0.stage == .verified || $0.hasPartialFields } }
        var phase: Phase {
            if parts.contains(where: { $0.stage == .submitted }) { return .submitted }
            if parts.contains(where: { $0.stage == .prepared }) { return .prepared }
            if parts.allSatisfy({ $0.stage == .verified }) { return failure == nil ? .succeeded : .partial }
            if hasSavedChanges { return .partial }
            return failure == nil ? .cancelled : .failed
        }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []
    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("Services-\(UUID())")
        reload()
    }
    static func signature(_ value: NasServiceSettings, step: NasServiceStep) -> String {
        let data = (try? JSONEncoder().encode(value.fields(for: step, verifying: true))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let url = root.appendingPathComponent("service-operations-v1.json")
            let values: [Entry]
            if FileManager.default.fileExists(atPath: url.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); values = envelope.entries
            } else { values = [] }
            failed = false; entries = values
            if values.contains(where: { $0.parts.contains { $0.stage == .prepared } }) {
                try persist(values.map { value in
                    var value = value
                    for index in value.parts.indices where value.parts[index].stage == .prepared { value.parts[index].stage = .skipped }
                    return value
                })
            }
        } catch { failed = true }
    }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func protects(_ kind: NasServiceKind, context: String) -> Bool {
        failed || entries.contains { $0.context == context && $0.kind == kind && ($0.isUnfinished || executing.contains($0.id)) }
    }
    func reserve(_ change: NasServiceChange, context: String) throws -> Entry {
        guard !protects(change.kind, context: context), let steps = change.orderedSteps else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let value = Entry(id: UUID(), context: context, kind: change.kind, createdAt: Date(),
            parts: steps.map { .init(step: $0, expected: Self.signature(change.desired, step: $0)) })
        try persist(entries + [value]); executing.insert(value.id); return value
    }
    func checkpoint(_ id: UUID, _ checkpoint: NasServiceCheckpoint) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), executing.contains(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let step: NasServiceStep
        switch checkpoint { case .willSubmit(let value), .accepted(let value), .verified(let value), .partial(let value), .rejected(let value): step = value }
        guard let part = entries[index].parts.firstIndex(where: { $0.step == step }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries
        switch checkpoint {
        case .willSubmit:
            guard values[index].parts[part].stage == .prepared,
                  values[index].parts.prefix(part).allSatisfy({ $0.stage == .verified }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].parts[part].stage = .submitted
        case .accepted:
            guard values[index].parts[part].stage == .submitted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].parts[part].accepted = true
        case .verified, .partial, .rejected:
            guard values[index].parts[part].stage == .submitted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if case .verified = checkpoint { values[index].parts[part].stage = .verified }
            else if case .rejected = checkpoint { values[index].parts[part].stage = .rejected }
            else { values[index].parts[part].hasPartialFields = true }
        }
        try persist(values)
    }
    /// 已提交部分保持保护；未提交的后续部分只能由新的明确保存动作启动。
    func stop(_ id: UUID, failure: Failure? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries
        for part in values[index].parts.indices where values[index].parts[part].stage == .prepared { values[index].parts[part].stage = .skipped }
        values[index].failure = failure
        try persist(values)
    }
    func end(_ id: UUID) { executing.remove(id) }
    func resolve(_ value: NasServiceSettings, context: String) throws {
        var values = entries
        for index in values.indices where values[index].context == context && values[index].kind == value.kind && !executing.contains(values[index].id) {
            for part in values[index].parts.indices where values[index].parts[part].stage == .submitted {
                if Self.signature(value, step: values[index].parts[part].step) == values[index].parts[part].expected {
                    values[index].parts[part].stage = .verified
                }
            }
        }
        if values != entries { try persist(values) }
    }
    func remove(_ id: UUID, context: String) throws {
        guard let value = entry(id), value.context == context, !value.isUnfinished, !executing.contains(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try persist(entries.filter { $0.id != id })
    }
    private func persist(_ values: [Entry]) throws {
        guard !failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try validate(values)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(to: root.appendingPathComponent("service-operations-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], targets: Set<String> = []
        for value in values {
            guard ids.insert(value.id).inserted, Self.isDigest(value.context), value.createdAt.timeIntervalSince1970.isFinite,
                  !value.parts.isEmpty, value.parts.count <= NasServiceStep.allCases.filter({ $0.kind == value.kind }).count,
                  Set(value.parts.map(\.step)).count == value.parts.count,
                  value.parts.filter({ $0.stage == .submitted }).count <= 1,
                  value.parts.allSatisfy({ $0.step.kind == value.kind && Self.isDigest($0.expected)
                      && (!$0.accepted || $0.stage == .submitted || $0.stage == .verified)
                      && (!$0.hasPartialFields || $0.stage == .submitted || $0.stage == .verified) }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if value.isUnfinished, !targets.insert(value.context + value.kind.rawValue).inserted { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if let pending = value.parts.firstIndex(where: { $0.stage == .submitted }) {
                guard value.parts.prefix(pending).allSatisfy({ $0.stage == .verified }),
                      value.parts.dropFirst(pending + 1).allSatisfy({ $0.stage == .prepared || $0.stage == .skipped }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            }
        }
    }
    private static func isDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

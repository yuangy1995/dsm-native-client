import CryptoKit
import DsmCore
import Foundation
import Observation

/// 服务设置共用受保护记录；配置、账号和凭据不落盘，防火墙回执仅供原任务读取。
@MainActor @Observable
final class MobileServiceOperationStore {
    enum Stage: String, Codable { case prepared, submitted, verified, rejected, skipped }
    enum Phase: String { case prepared, submitted, succeeded, partial, failed, cancelled }
    enum Failure: String, Codable { case denied, unavailable, changed, failed }
    struct Part: Equatable, Codable {
        let step: NasServiceStep
        let expected: String
        var target: String? = nil
        var stage: Stage = .prepared
        var accepted = false
        var hasPartialFields = false
        var requiresFirewallTask = false
        var firewallTaskID: String? = nil
        var firewallTaskSucceeded: Bool? = nil
        var firewallCleanupRequested = false
    }
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let context: String
        let kind: NasServiceKind
        var networkOwner: String? = nil
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
    static func targetSignature(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
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
    func networkEntries(owner: String) -> [Entry] { entries.filter { $0.kind == .ethernet && $0.networkOwner == owner } }
    func protectsNetwork(owner: String) -> Bool { failed || networkEntries(owner: owner).contains { $0.isUnfinished || executing.contains($0.id) } }
    func reserve(_ change: NasServiceChange, context: String, networkOwner: String? = nil) throws -> Entry {
        guard !protects(change.kind, context: context), let steps = change.orderedSteps else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        if change.kind == .ethernet {
            guard let networkOwner, !protectsNetwork(owner: networkOwner) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        }
        let target = change.ethernetTarget
        let appliesFirewall: Bool
        if case .security(let settings) = change.desired { appliesFirewall = settings.isFirewallEnabled == true } else { appliesFirewall = false }
        let value = Entry(id: UUID(), context: context, kind: change.kind, networkOwner: change.kind == .ethernet ? networkOwner : nil, createdAt: Date(),
            parts: steps.map { .init(step: $0, expected: Self.signature(target.map { .ethernet([$0]) } ?? change.desired, step: $0),
                                   target: target.map { Self.targetSignature($0.id) }, requiresFirewallTask: $0 == .firewall && appliesFirewall) })
        try persist(entries + [value]); executing.insert(value.id); return value
    }
    func checkpoint(_ id: UUID, _ checkpoint: NasServiceCheckpoint) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), executing.contains(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let step: NasServiceStep
        switch checkpoint { case .willSubmit(let value), .accepted(let value), .verified(let value), .partial(let value), .rejected(let value): step = value
        case .firewallTaskStarted, .firewallTaskFinished, .willCleanFirewallTask: step = .firewall }
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
        case .firewallTaskStarted(let taskID):
            guard values[index].parts[part].requiresFirewallTask, values[index].parts[part].stage == .submitted,
                  values[index].parts[part].firewallTaskID == nil, !taskID.isEmpty else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].parts[part].firewallTaskID = taskID
        case .firewallTaskFinished(let succeeded):
            guard values[index].parts[part].stage == .submitted, values[index].parts[part].firewallTaskID != nil,
                  values[index].parts[part].firewallTaskSucceeded == nil else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].parts[part].firewallTaskSucceeded = succeeded
        case .willCleanFirewallTask:
            guard values[index].parts[part].stage == .submitted, values[index].parts[part].firewallTaskSucceeded != nil,
                  !values[index].parts[part].firewallCleanupRequested else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].parts[part].firewallCleanupRequested = true
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
                if values[index].parts[part].firewallTaskSucceeded == false {
                    values[index].parts[part].stage = .rejected; values[index].failure = .failed; continue
                }
                if Self.matches(value, part: values[index].parts[part]) {
                    values[index].parts[part].stage = .verified
                }
            }
        }
        if values != entries { try persist(values) }
    }
    func finishFirewallTask(_ id: UUID, succeeded: Bool, context: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.context == context }), !executing.contains(id),
              let part = entries[index].parts.firstIndex(where: { $0.requiresFirewallTask && $0.stage == .submitted }),
              entries[index].parts[part].firewallTaskID != nil, entries[index].parts[part].firewallTaskSucceeded == nil else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries; values[index].parts[part].firewallTaskSucceeded = succeeded
        try persist(values)
    }
    /// 仅在重新登录并明确选择原记录后调用；不会移动记录账号或触发任何设置请求。
    func resolveNetwork(_ id: UUID, value: NasServiceSettings, owner: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].networkOwner == owner,
              entries[index].kind == .ethernet, !executing.contains(id), value.kind == .ethernet else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries
        for part in values[index].parts.indices where values[index].parts[part].stage == .submitted {
            if Self.matches(value, part: values[index].parts[part]) { values[index].parts[part].stage = .verified }
        }
        if values != entries { try persist(values) }
    }
    private static func matches(_ value: NasServiceSettings, part: Part) -> Bool {
        if part.requiresFirewallTask && part.firewallTaskSucceeded != true { return false }
        if part.step == .ethernet {
            guard case .ethernet(let values) = value, let target = part.target,
                  let match = values.first(where: { Self.targetSignature($0.id) == target }) else { return false }
            return Self.signature(.ethernet([match]), step: .ethernet) == part.expected
        }
        return Self.signature(value, step: part.step) == part.expected
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
                      && (value.kind == .ethernet ? $0.target.map(Self.isDigest) == true && value.networkOwner.map(Self.isDigest) == true : $0.target == nil && value.networkOwner == nil)
                      && (!$0.accepted || $0.stage == .submitted || $0.stage == .verified || $0.requiresFirewallTask && $0.stage == .rejected)
                      && (!$0.requiresFirewallTask || $0.step == .firewall)
                      && ($0.firewallTaskID == nil || $0.requiresFirewallTask && $0.firewallTaskID?.isEmpty == false)
                      && ($0.firewallTaskSucceeded == nil || $0.firewallTaskID != nil)
                      && (!$0.firewallCleanupRequested || $0.firewallTaskSucceeded != nil)
                      && (!$0.requiresFirewallTask || $0.stage != .verified || $0.firewallTaskSucceeded == true)
                      && (!$0.hasPartialFields || $0.stage == .submitted || $0.stage == .verified) }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if value.isUnfinished, !targets.insert(value.context + value.kind.rawValue).inserted { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if value.isUnfinished, let owner = value.networkOwner, !targets.insert("network:" + owner).inserted { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if let pending = value.parts.firstIndex(where: { $0.stage == .submitted }) {
                guard value.parts.prefix(pending).allSatisfy({ $0.stage == .verified }),
                      value.parts.dropFirst(pending + 1).allSatisfy({ $0.stage == .prepared || $0.stage == .skipped }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            }
        }
    }
    private static func isDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

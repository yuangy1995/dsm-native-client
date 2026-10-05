import CryptoKit
import DsmCore
import Foundation
import Observation

/// 只保存身份/配置摘要与数字编号；脚本、名称、执行用户和输出均不落盘。
@MainActor @Observable
final class MobileScheduledTaskStore {
    enum Phase: String, Codable { case prepared, submitted, succeeded, accepted, failed, cancelled }
    enum Failure: String, Codable { case denied, unavailable, changed, failed }
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let context: String
        let action: NasScheduledTaskAction
        let target: String
        let originalID: Int?
        let expected: String?
        let createdAt: Date
        var phase: Phase = .prepared
        var accepted = false
        var existingIDs: [Int]?
        var failure: Failure?
        var isUnfinished: Bool { phase == .prepared || phase == .submitted }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []
    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ScheduledTasks-\(UUID())")
        reload()
    }
    static func digest(_ values: [String?]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func target(_ task: NasScheduledTask) -> String { digest([task.id, task.realOwner]) }
    static func creationTarget(name: String, owner: String?) -> String { digest([name, owner]) }
    static func signature(_ draft: NasScheduledTaskDraft) -> String { digest(draft.savedFields.map(Optional.some)) }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let file = root.appendingPathComponent("scheduled-tasks-v1.json")
            let values: [Entry]
            if FileManager.default.fileExists(atPath: file.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
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
    func protects(task: NasScheduledTask?, context: String) -> Bool {
        failed || entries.contains { entry in
            entry.context == context && (entry.isUnfinished || executing.contains(entry.id))
                && (entry.action == .create || task.map { entry.originalID == Int($0.id) } == true)
        }
    }
    func reserve(_ change: NasScheduledTaskChange, context: String) throws -> Entry {
        guard change.isValid, !protects(task: change.task, context: context) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let target: String
        if let task = change.task { target = Self.target(task) }
        else if let desired = change.desiredDraft { target = Self.creationTarget(name: desired.normalizedName, owner: desired.normalizedOwner) }
        else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let value = Entry(id: UUID(), context: context, action: change.action, target: target,
            originalID: change.task.flatMap { Int($0.id) }, expected: change.action == .disable ? change.task.map { Self.digest($0.managementTargetFields + ["false"]) } : change.desiredDraft.map(Self.signature), createdAt: Date())
        try persist(entries + [value]); executing.insert(value.id); return value
    }
    func checkpoint(_ id: UUID, _ checkpoint: NasScheduledTaskCheckpoint) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), executing.contains(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries
        switch checkpoint {
        case .willSubmit(let existingIDs):
            guard values[index].phase == .prepared else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].phase = .submitted
            values[index].existingIDs = values[index].action == .create ? existingIDs : nil
        case .accepted:
            guard values[index].phase == .submitted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].accepted = true
        }
        try persist(values)
    }
    func finish(_ id: UUID, phase: Phase, failure: Failure? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isUnfinished,
              phase != .prepared && phase != .submitted,
              phase != .succeeded || entries[index].phase == .submitted && entries[index].action != .run,
              phase != .accepted || entries[index].action == .run && entries[index].accepted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries; values[index].phase = phase; values[index].failure = failure
        try persist(values)
    }
    func end(_ id: UUID) { executing.remove(id) }
    func candidate(for entry: Entry, tasks: [NasScheduledTask]) -> NasScheduledTask? {
        let matches: [NasScheduledTask]
        if entry.action == .create {
            guard entry.accepted, let oldIDs = entry.existingIDs else { return nil }
            matches = tasks.filter { !oldIDs.contains(Int($0.id) ?? -1) && Self.creationTarget(name: $0.name, owner: $0.owner) == entry.target }
        } else { matches = tasks.filter { Int($0.id) == entry.originalID && Self.target($0) == entry.target } }
        return matches.count == 1 ? matches.first : nil
    }
    func resolve(_ id: UUID, tasks: [NasScheduledTask], draft: NasScheduledTaskDraft? = nil) throws {
        guard let value = entry(id), value.phase == .submitted, !isExecuting(id) else { return }
        if value.action == .run {
            if value.accepted { try finish(id, phase: .accepted) }
        } else if value.action == .delete {
            if !tasks.contains(where: { Int($0.id) == value.originalID }) { try finish(id, phase: .succeeded) }
        } else if value.action == .disable, let task = candidate(for: value, tasks: tasks), task.isEnabledKnown, !task.isEnabled,
                  Self.digest(task.managementTargetFields + ["false"]) == value.expected {
            try finish(id, phase: .succeeded)
        } else if value.action != .disable, let task = candidate(for: value, tasks: tasks), task.type == "script", let draft,
                  draft.matches(task), Self.signature(draft) == value.expected {
            try finish(id, phase: .succeeded)
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
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(to: root.appendingPathComponent("scheduled-tasks-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], pending: Set<String> = []
        for value in values {
            let needsConfiguration = [.create, .save, .enable, .disable].contains(value.action)
            guard ids.insert(value.id).inserted, Self.isDigest(value.context), Self.isDigest(value.target),
                  value.createdAt.timeIntervalSince1970.isFinite,
                  needsConfiguration == (value.expected != nil), value.expected.map(Self.isDigest) ?? true,
                  value.action == .create ? value.originalID == nil : value.originalID.map({ $0 >= 0 }) == true,
                  !value.accepted || [.submitted, .succeeded, .accepted].contains(value.phase),
                  value.action != .create || value.phase != .succeeded || value.accepted,
                  value.phase != .accepted || value.action == .run && value.accepted,
                  value.action != .run || value.phase != .succeeded else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if let oldIDs = value.existingIDs {
                guard value.action == .create, oldIDs.count < 1_000, Set(oldIDs).count == oldIDs.count, oldIDs.allSatisfy({ $0 >= 0 }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            }
            if value.action == .create && [.submitted, .succeeded].contains(value.phase), value.existingIDs == nil { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if value.isUnfinished, !pending.insert(value.context + value.target).inserted { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        }
    }
    private static func isDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

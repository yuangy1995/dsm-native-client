import CryptoKit
import DsmCore
import Foundation
import Observation

/// 仅保存配置摘要和用户明确选择的墙上时间，配置正文不进入操作历史。
@MainActor @Observable
final class MobileRegionOperationStore {
    enum Phase: String, Codable { case prepared, saving, saved, synchronizing, succeeded, partial, failed, cancelled }
    enum Failure: String, Codable { case denied, unavailable, changed, failed }
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let context: String
        let expected: String
        let synchronizationOnly: Bool
        let needsSynchronization: Bool
        let manualWallTime: Date?
        let createdAt: Date
        var submittedAt: Date?
        var phase: Phase = .prepared
        var saveAccepted = false
        var syncAccepted = false
        var failure: Failure?
        var isUnfinished: Bool { [.prepared, .saving, .saved, .synchronizing].contains(phase) }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("Region-\(UUID())")
        reload()
    }
    static func signature(_ value: NasRegionSettings) -> String {
        let fields = [value.normalizedDateFormat, value.normalizedTimeFormat, value.timeZone, String(value.isNetworkTimeEnabled)]
            + (value.isNetworkTimeEnabled ? value.normalizedTimeServers : [])
        return SHA256.hash(data: try! JSONEncoder().encode(fields)).map { String(format: "%02x", $0) }.joined()
    }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let url = root.appendingPathComponent("region-operations-v1.json")
            var values: [Entry] = []
            if FileManager.default.fileExists(atPath: url.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); values = envelope.entries
            }
            failed = false; entries = values
            if values.contains(where: { $0.phase == .prepared }) {
                try persist(values.map { var value = $0; if value.phase == .prepared { value.phase = .cancelled }; return value })
            }
        } catch { failed = true }
    }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func protects(_ context: String) -> Bool {
        failed || entries.contains { $0.context == context && ($0.isUnfinished || isExecuting($0.id)) }
    }
    func reserve(_ change: NasRegionChange, context: String) throws -> Entry {
        guard change.isValid, !protects(context) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let value = Entry(id: UUID(), context: context, expected: Self.signature(change.desired),
            synchronizationOnly: change.isSynchronizationOnly, needsSynchronization: change.requiresSynchronization,
            manualWallTime: change.editsManualTime ? change.desired.manualDate.map { NasRegionChange.wallTime($0) } : nil,
            createdAt: Date())
        try persist(entries + [value]); executing.insert(value.id); return value
    }
    func checkpoint(_ id: UUID, stage: NasRegionCheckpoint) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), isExecuting(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries
        switch stage {
        case .willSave:
            guard values[index].phase == .prepared, !values[index].synchronizationOnly else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].phase = .saving; values[index].submittedAt = Date()
        case .saved:
            guard values[index].phase == .saving else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].saveAccepted = true
        case .configurationVerified:
            guard values[index].phase == .saving else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].phase = .saved
        case .willSynchronize:
            guard values[index].needsSynchronization,
                  values[index].phase == .saved || values[index].synchronizationOnly && values[index].phase == .prepared else {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
            values[index].phase = .synchronizing
            if values[index].submittedAt == nil { values[index].submittedAt = Date() }
        case .synchronized:
            guard values[index].phase == .synchronizing else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].syncAccepted = true
        }
        try persist(values)
    }
    func finish(_ id: UUID, phase: Phase, failure: Failure? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isUnfinished,
              ![Phase.prepared, .saving, .saved, .synchronizing].contains(phase),
              phase != .succeeded || entries[index].submittedAt != nil else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries; values[index].phase = phase; values[index].failure = failure
        try persist(values)
    }
    func end(_ id: UUID) { executing.remove(id) }
    func resolve(_ value: NasRegionSettings, context: String, now: Date = Date()) throws {
        for entry in entries where entry.context == context && entry.isUnfinished && !isExecuting(entry.id) {
            if entry.phase == .synchronizing {
                // 校时没有可查询的任务编号；只读恢复不能再次触发它，也不能凭配置相同推断成功。
                let completed = entry.syncAccepted && Self.signature(value) == entry.expected
                try finish(entry.id, phase: completed ? .succeeded : .partial)
                continue
            }
            guard [.saving, .saved].contains(entry.phase), Self.signature(value) == entry.expected else { continue }
            if let expected = entry.manualWallTime {
                guard entry.saveAccepted, let actual = value.manualDate, let submitted = entry.submittedAt else { continue }
                let elapsed = now.timeIntervalSince(submitted)
                guard elapsed >= 0, abs(NasRegionChange.wallTime(actual).timeIntervalSince(expected) - elapsed) <= 120 else { continue }
            }
            try finish(entry.id, phase: entry.needsSynchronization ? .partial : .succeeded)
        }
    }
    func remove(_ id: UUID, context: String) throws {
        guard let entry = entry(id), entry.context == context, !entry.isUnfinished, !isExecuting(id) else {
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
                to: root.appendingPathComponent("region-operations-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], contexts: Set<String> = []
        for entry in values {
            guard ids.insert(entry.id).inserted, Self.isDigest(entry.context), Self.isDigest(entry.expected),
                  entry.createdAt.timeIntervalSince1970.isFinite,
                  entry.submittedAt?.timeIntervalSince1970.isFinite ?? true,
                  entry.manualWallTime?.timeIntervalSince1970.isFinite ?? true,
                  entry.phase == .failed ? entry.failure != nil : entry.phase == .partial || entry.failure == nil,
                  !entry.synchronizationOnly || entry.needsSynchronization && entry.manualWallTime == nil && !entry.saveAccepted,
                  !entry.syncAccepted || entry.needsSynchronization && entry.submittedAt != nil,
                  ![Phase.saving, .saved, .synchronizing, .succeeded, .partial].contains(entry.phase) || entry.submittedAt != nil,
                  !entry.isUnfinished || contexts.insert(entry.context).inserted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        }
    }
    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

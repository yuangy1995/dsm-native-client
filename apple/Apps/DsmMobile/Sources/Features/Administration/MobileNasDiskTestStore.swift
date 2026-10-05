import CryptoKit
import DsmCore
import Foundation
import Observation

/// 检测记录只保留身份摘要及操作阶段，不保存磁盘标识、序列号、日志或会话。
@MainActor
@Observable
final class MobileNasDiskTestStore {
    enum Phase: String, Codable { case planned, submitted, succeeded, failed, cancelled }
    enum Failure: String, Codable { case denied, changed, unavailable }
    struct Entry: Identifiable, Codable, Equatable {
        let id: UUID
        let context: String
        let disk: String
        let action: NasDiskTestAction
        let createdAt: Date
        var phase: Phase = .planned
        var failure: Failure?
        var isUnfinished: Bool { phase == .planned || phase == .submitted }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("NasDiskTests-\(UUID())")
        reload()
    }

    static func identity(_ disk: NasDisk) -> String {
        let data = (try? JSONEncoder().encode([disk.id, disk.deviceID, disk.supportsSmartTest ? "true" : "false"])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func reload() {
        guard executing.isEmpty else { return }
        do {
            let url = root.appendingPathComponent("disk-tests-v1.json")
            let values: [Entry]
            if FileManager.default.fileExists(atPath: url.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); values = envelope.entries
            } else { values = [] }
            failed = false; entries = values
            // 发送边界前必须已有 submitted 记录；跨重启的 planned 可以确认未发送。
            if values.contains(where: { $0.phase == .planned }) {
                try persist(values.map { value in
                    var value = value
                    if value.phase == .planned { value.phase = .cancelled }
                    return value
                })
            }
        } catch { failed = true }
    }

    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func protects(disk: String, context: String) -> Bool {
        failed || entries.contains { $0.disk == disk && $0.context == context && ($0.isUnfinished || executing.contains($0.id)) }
    }
    func reserve(context: String, disk: String, action: NasDiskTestAction) throws -> Entry {
        guard !protects(disk: disk, context: context) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let entry = Entry(id: UUID(), context: context, disk: disk, action: action, createdAt: Date())
        try persist(entries + [entry]); executing.insert(entry.id); return entry
    }
    func end(_ id: UUID) { executing.remove(id) }
    func progress(_ id: UUID, phase: Phase, failure: Failure? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let old = entries[index].phase
        guard (old == .planned && [.submitted, .failed, .cancelled].contains(phase))
                || (old == .submitted && [.succeeded, .failed, .cancelled].contains(phase)),
              phase != .submitted || executing.contains(id),
              (phase == .failed) == (failure != nil) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var updated = entries; updated[index].phase = phase; updated[index].failure = failure
        try persist(updated)
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
                to: root.appendingPathComponent("disk-tests-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], occupied: Set<String> = []
        for entry in values {
            guard ids.insert(entry.id).inserted, Self.digest(entry.context), Self.digest(entry.disk),
                  entry.createdAt.timeIntervalSince1970.isFinite,
                  (entry.phase == .failed) == (entry.failure != nil) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if entry.isUnfinished, !occupied.insert(entry.context + entry.disk).inserted {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
        }
    }
    private static func digest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

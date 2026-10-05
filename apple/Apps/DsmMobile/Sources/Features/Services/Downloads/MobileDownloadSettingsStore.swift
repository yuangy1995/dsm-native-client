import DsmCore
import Foundation
import Observation

/// 只保存变更字段；目录用于继续未提交步骤，受完整文件保护并排除备份。
@MainActor
@Observable
final class MobileDownloadSettingsStore {
    enum Phase: String, Codable { case planned, submitted, complete, failed, cancelled }
    enum Failure: String, Codable { case changed, denied, unavailable }
    struct Step: Codable, Equatable, Identifiable {
        var id: DownloadSettingsField.Group { change.group }
        let change: DownloadSettingsChange
        var phase: Phase = .planned
        var failure: Failure?
    }
    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        let context: String
        let createdAt: Date
        var steps: [Step]
        var hasSubmitted: Bool { steps.contains { $0.phase == .submitted } }
        var hasPlanned: Bool { steps.contains { $0.phase == .planned } }
        var unfinished: Bool { hasSubmitted || hasPlanned }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("DownloadSettings-\(UUID())")
        do {
            let url = self.root.appendingPathComponent("settings-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); entries = envelope.entries
            }
        } catch { failed = true }
    }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func begin(_ id: UUID) -> Bool { !failed && entry(id) != nil && executing.insert(id).inserted }
    func end(_ id: UUID) { executing.remove(id) }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func reserve(_ value: Entry) throws {
        guard value.steps.allSatisfy({ $0.phase == .planned && $0.failure == nil }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        // 当前账号只保留最近一次已结束保存和未完成保存，不积累设置历史中的路径。
        try persist(entries.filter { $0.context != value.context || $0.unfinished } + [value])
    }
    func progress(_ id: UUID, group: DownloadSettingsField.Group, phase: Phase, failure: Failure? = nil) throws {
        guard executing.contains(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try update(id) { entry in
            guard let index = entry.steps.firstIndex(where: { $0.id == group }),
                  (entry.steps[index].phase == .planned && [.submitted, .failed, .cancelled].contains(phase))
                    || (entry.steps[index].phase == .submitted && [.complete, .failed, .cancelled].contains(phase)) else {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
            entry.steps[index].phase = phase; entry.steps[index].failure = failure
        }
    }
    func cancelRemaining(_ id: UUID) throws {
        try update(id) { entry in
            for index in entry.steps.indices where entry.steps[index].phase == .planned { entry.steps[index].phase = .cancelled }
        }
    }
    private func update(_ id: UUID, body: (inout Entry) throws -> Void) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries; try body(&values[index]); try persist(values)
    }
    private func persist(_ values: [Entry]) throws {
        guard !failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try validate(values)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(
                to: root.appendingPathComponent("settings-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], contexts: Set<String> = []
        for entry in values {
            guard ids.insert(entry.id).inserted, entry.context.count == 64,
                  entry.context.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  entry.createdAt.timeIntervalSince1970.isFinite, !entry.steps.isEmpty, entry.steps.count <= 2,
                  Set(entry.steps.map(\.id)).count == entry.steps.count,
                  entry.steps.allSatisfy({ $0.change.isValid && ($0.phase == .failed) == ($0.failure != nil) }),
                  !entry.unfinished || contexts.insert(entry.context).inserted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        }
    }
}

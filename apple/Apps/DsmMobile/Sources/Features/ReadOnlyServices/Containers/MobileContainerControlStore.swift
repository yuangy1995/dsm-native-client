import CryptoKit
import DsmCore
import Foundation
import Observation

/// 只持久化账号/目标摘要、启动时间与逐项提交边界；名称和日志正文留在内存。
@MainActor @Observable
final class MobileContainerControlStore {
    enum Phase: String, Codable { case prepared, submitted, succeeded, failed, skipped }
    enum Failure: String, Codable { case denied, unavailable, changed, failed }
    struct Item: Equatable, Codable {
        let identity: String
        let name: String
        let previousStartedAt: Date?
        var phase: Phase = .prepared
        var accepted = false
        var failure: Failure?
        func matches(_ target: ContainerControlState) -> Bool {
            identity == digest(target.id) && name == digest(target.name)
        }
    }
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let context: String
        let action: ContainerAction
        let createdAt: Date
        var items: [Item]
        var isProtected: Bool { items.contains { $0.phase == .prepared || $0.phase == .submitted } }
        var completedCount: Int { items.filter { $0.phase == .succeeded }.count }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []
    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ContainerControls-\(UUID())")
        reload()
    }
    nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func protects(_ targets: [ContainerControlState], context: String) -> Bool {
        failed || entries.contains { entry in
            entry.context == context && entry.items.contains { item in
                (item.phase == .prepared || item.phase == .submitted || isExecuting(entry.id)) && targets.contains {
                    item.identity == Self.digest($0.id) || item.name == Self.digest($0.name)
                }
            }
        }
    }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let url = root.appendingPathComponent("container-controls-v1.json")
            var values: [Entry] = []
            if FileManager.default.fileExists(atPath: url.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); values = envelope.entries
            }
            entries = values; failed = false
            let restored = values.map { entry in
                var value = entry
                for index in value.items.indices where value.items[index].phase == .prepared { value.items[index].phase = .skipped }
                return value
            }
            if values != restored { try persist(restored) }
        } catch { failed = true }
    }
    func reserve(_ targets: [ContainerControlState], action: ContainerAction, context: String) throws -> Entry {
        guard !targets.isEmpty, targets.allSatisfy({ $0.supports(action) }), !protects(targets, context: context),
              Set(targets.map(\.id)).count == targets.count, Set(targets.map(\.name)).count == targets.count else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        let entry = Entry(id: UUID(), context: context, action: action, createdAt: Date(), items: targets.map {
            Item(identity: Self.digest($0.id), name: Self.digest($0.name), previousStartedAt: $0.startedAt)
        })
        try persist(entries + [entry]); executing.insert(entry.id); return entry
    }
    func checkpoint(_ id: UUID, index: Int, stage: ContainerControlStage) throws {
        guard let position = entries.firstIndex(where: { $0.id == id }), executing.contains(id),
              entries[position].items.indices.contains(index) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries, item = entries[position].items[index]
        switch stage {
        case .willSubmit:
            guard item.phase == .prepared else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            item.phase = .submitted
        case .accepted:
            guard item.phase == .submitted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            item.accepted = true
        case .rejected:
            guard item.phase == .submitted, !item.accepted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            item.phase = .failed; item.failure = .failed
        case .verified:
            guard item.phase == .submitted, item.accepted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            item.phase = .succeeded
        }
        values[position].items[index] = item; try persist(values)
    }
    func finish(_ id: UUID, failedIndex: Int? = nil, failure: Failure? = nil) throws {
        guard let position = entries.firstIndex(where: { $0.id == id }) else { return }
        var values = entries
        for index in values[position].items.indices {
            if values[position].items[index].phase == .prepared {
                values[position].items[index].phase = index == failedIndex ? .failed : .skipped
            }
            if index == failedIndex, values[position].items[index].phase == .failed {
                values[position].items[index].failure = failure ?? .failed
            }
        }
        try persist(values)
    }
    func end(_ id: UUID) { executing.remove(id) }
    func resolve(_ targets: [ContainerControlState], context: String) throws {
        var values = entries
        for position in values.indices where values[position].context == context && !isExecuting(values[position].id) {
            for index in values[position].items.indices where values[position].items[index].phase == .submitted {
                let item = values[position].items[index]
                if let target = targets.first(where: item.matches),
                   target.verifies(values[position].action, previousStartedAt: item.previousStartedAt) {
                    values[position].items[index].phase = .succeeded
                }
            }
        }
        if values != entries { try persist(values) }
    }
    func remove(_ id: UUID, context: String) throws {
        guard let value = entry(id), value.context == context, !value.isProtected, !isExecuting(id) else {
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
                to: root.appendingPathComponent("container-controls-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        func isDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        var ids: Set<UUID> = [], protectedIDs: Set<String> = [], protectedNames: Set<String> = []
        for entry in values {
            guard ids.insert(entry.id).inserted, isDigest(entry.context), entry.createdAt.timeIntervalSince1970.isFinite,
                  !entry.items.isEmpty, Set(entry.items.map(\.identity)).count == entry.items.count,
                  Set(entry.items.map(\.name)).count == entry.items.count else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            for item in entry.items {
                guard isDigest(item.identity), isDigest(item.name),
                      item.previousStartedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                      entry.action != .restart || item.previousStartedAt != nil,
                      !item.accepted || [.submitted, .succeeded].contains(item.phase),
                      item.failure == nil || item.phase == .failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                if item.phase == .prepared || item.phase == .submitted {
                    guard protectedIDs.insert(entry.context + item.identity).inserted,
                          protectedNames.insert(entry.context + item.name).inserted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                }
            }
        }
    }
}

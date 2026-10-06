import DsmCore
import Foundation
import Observation

/// 映像删除只持久保存摘要与阶段；不记录名称、主机、存储位置或凭据。
@MainActor @Observable
final class MobileVirtualMachineImageStore {
    typealias Phase = MobileVirtualMachineControlStore.Phase
    typealias Failure = MobileVirtualMachineControlStore.Failure
    struct Item: Equatable, Codable {
        let identity: String
        let snapshot: String
        let source: VirtualMachineImageState.Source
        var phase: Phase = .prepared
        var accepted = false
        var failure: Failure?
        func matches(_ target: VirtualMachineImageState) -> Bool {
            source == target.source && identity == digest(target.id) && snapshot == (try? Self.snapshot(target))
        }
        static func snapshot(_ target: VirtualMachineImageState) throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return digest(String(decoding: try encoder.encode(target), as: UTF8.self))
        }
    }
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let context: String
        let createdAt: Date
        var items: [Item]
        var isProtected: Bool { items.contains { $0.phase == .prepared || $0.phase == .submitted } }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []
    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("VirtualMachineImages-\(UUID())")
        reload()
    }
    nonisolated static func digest(_ value: String) -> String { MobileVirtualMachineControlStore.digest(value) }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func protects(imageID: String, context: String) -> Bool {
        failed || entries.contains { entry in
            entry.context == context && entry.items.contains {
                ($0.phase == .prepared || $0.phase == .submitted || isExecuting(entry.id)) && $0.identity == Self.digest(imageID)
            }
        }
    }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let url = root.appendingPathComponent("virtual-machine-images-v1.json")
            var values: [Entry] = [], isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
            if FileManager.default.fileExists(atPath: url.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); values = envelope.entries
            } else if entries.contains(where: \.isProtected) { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            entries = values; failed = false
            let restored = values.map { entry in
                var value = entry
                for index in value.items.indices where value.items[index].phase == .prepared { value.items[index].phase = .skipped }
                return value
            }
            if values != restored { try persist(restored) }
        } catch { failed = true }
    }
    func reserve(_ targets: [VirtualMachineImageState], context: String) throws -> Entry {
        guard !targets.isEmpty, targets.allSatisfy(\.canDelete),
              !targets.contains(where: { protects(imageID: $0.id, context: context) }) else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        let entry = Entry(id: UUID(), context: context, createdAt: Date(), items: try targets.map {
            Item(identity: Self.digest($0.id), snapshot: try Item.snapshot($0), source: $0.source)
        })
        try persist(entries + [entry]); executing.insert(entry.id); return entry
    }
    func checkpoint(_ id: UUID, index: Int, stage: VirtualMachineControlStage) throws {
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
            if values[position].items[index].phase == .prepared { values[position].items[index].phase = index == failedIndex ? .failed : .skipped }
            if index == failedIndex, values[position].items[index].phase == .failed { values[position].items[index].failure = failure ?? .failed }
        }
        try persist(values)
    }
    func end(_ id: UUID) { executing.remove(id) }
    func resolve(_ inventory: VirtualMachineImageInventory, context: String) throws {
        guard !inventory.isFrozen else { return }
        let identities = Set(inventory.images.map { Self.digest($0.id) })
        var values = entries
        for position in values.indices where values[position].context == context && !isExecuting(values[position].id) {
            for index in values[position].items.indices {
                let item = values[position].items[index]
                if item.phase == .submitted, item.accepted, item.source == inventory.source, !identities.contains(item.identity) {
                    values[position].items[index].phase = .succeeded
                }
            }
        }
        if values != entries { try persist(values) }
    }
    func remove(_ id: UUID, context: String) throws {
        guard let entry = entry(id), entry.context == context, !entry.isProtected, !isExecuting(id) else {
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
                to: root.appendingPathComponent("virtual-machine-images-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        func isDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        var ids: Set<UUID> = [], protectedIDs: Set<String> = []
        for entry in values {
            guard ids.insert(entry.id).inserted, isDigest(entry.context), entry.createdAt.timeIntervalSince1970.isFinite,
                  !entry.items.isEmpty, Set(entry.items.map(\.identity)).count == entry.items.count else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            for item in entry.items {
                guard isDigest(item.identity), isDigest(item.snapshot), item.phase != .succeeded || item.accepted,
                      !item.accepted || [.submitted, .succeeded].contains(item.phase),
                      item.failure == nil || item.phase == .failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                if item.phase == .prepared || item.phase == .submitted {
                    guard protectedIDs.insert(entry.context + item.identity).inserted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                }
            }
        }
    }
}

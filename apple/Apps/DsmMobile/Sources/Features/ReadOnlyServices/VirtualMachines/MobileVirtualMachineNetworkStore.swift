import DsmCore
import Foundation
import Observation

/// 网络恢复只保存摘要，不写入名称、地址、接口正文或登录凭据。
@MainActor @Observable
final class MobileVirtualMachineNetworkStore {
    typealias Phase = MobileVirtualMachineControlStore.Phase
    typealias Failure = MobileVirtualMachineControlStore.Failure
    enum Kind: String, Codable { case rename, delete }
    struct Item: Equatable, Codable {
        let identity: String
        let name: String
        let topology: String
        let guests: Set<String>
        let newName: String?
        let reservedNames: Set<String>
        var phase: Phase = .prepared
        var accepted = false
        var failure: Failure?
        func matches(_ target: VirtualMachineNetworkState) -> Bool {
            identity == digest(target.id) && (name == digest(target.name) || newName == digest(target.name))
        }
    }
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let context: String
        let action: Kind
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
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("VirtualMachineNetworks-\(UUID())")
        reload()
    }
    nonisolated static func digest(_ value: String) -> String { MobileVirtualMachineControlStore.digest(value) }
    private static func topology(_ target: VirtualMachineNetworkState) throws -> String {
        let value = VirtualMachineNetworkState(id: target.id, name: "", type: target.type, hostID: target.hostID,
            vlanID: target.vlanID, interfaces: target.interfaces, guests: target.guests)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func protects(networkID: String, context: String) -> Bool {
        failed || entries.contains { entry in
            entry.context == context && entry.items.contains {
                ($0.phase == .prepared || $0.phase == .submitted || isExecuting(entry.id)) && $0.identity == Self.digest(networkID)
            }
        }
    }
    func protects(guestID: String, context: String) -> Bool {
        failed || entries.contains { entry in
            entry.context == context && entry.items.contains {
                ($0.phase == .prepared || $0.phase == .submitted || isExecuting(entry.id)) && $0.guests.contains(Self.digest(guestID))
            }
        }
    }
    func protects(name: String, context: String) -> Bool {
        failed || entries.contains { entry in
            entry.context == context && entry.items.contains {
                ($0.phase == .prepared || $0.phase == .submitted || isExecuting(entry.id))
                    && $0.reservedNames.contains(MobileVirtualMachineCreationStore.nameDigest(name))
            }
        }
    }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let url = root.appendingPathComponent("virtual-machine-networks-v1.json")
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
    func reserve(_ targets: [VirtualMachineNetworkState], newName: String?, context: String) throws -> Entry {
        guard !targets.isEmpty, newName == nil || targets.count == 1,
              newName.map(VirtualMachineNetworkState.isValidName) ?? true,
              !targets.contains(where: { protects(networkID: $0.id, context: context) || protects(name: $0.name, context: context) }),
              newName.map({ !protects(name: $0, context: context) }) ?? true else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        let entry = Entry(id: UUID(), context: context, action: newName == nil ? .delete : .rename, createdAt: Date(), items: try targets.map {
            Item(identity: Self.digest($0.id), name: Self.digest($0.name), topology: try Self.topology($0),
                 guests: Set($0.guests.map { Self.digest($0.id) }), newName: newName.map(Self.digest),
                 reservedNames: Set([$0.name, newName].compactMap { $0 }.map(MobileVirtualMachineCreationStore.nameDigest)))
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
    func resolve(_ inventory: VirtualMachineNetworkInventory, context: String) throws {
        guard !inventory.isFrozen else { return }
        var values = entries
        for position in values.indices where values[position].context == context && !isExecuting(values[position].id) {
            for index in values[position].items.indices where values[position].items[index].phase == .submitted {
                let item = values[position].items[index]
                guard item.accepted else { continue }
                let current = inventory.networks.first { Self.digest($0.id) == item.identity }
                if values[position].action == .delete {
                    if current == nil { values[position].items[index].phase = .succeeded }
                } else if let current, item.newName == Self.digest(current.name), try item.topology == Self.topology(current) {
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
                to: root.appendingPathComponent("virtual-machine-networks-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        func isDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        var ids: Set<UUID> = [], protectedIDs: Set<String> = [], protectedNames: Set<String> = []
        for entry in values {
            guard ids.insert(entry.id).inserted, isDigest(entry.context), entry.createdAt.timeIntervalSince1970.isFinite,
                  !entry.items.isEmpty, entry.action != .rename || entry.items.count == 1,
                  Set(entry.items.map(\.identity)).count == entry.items.count else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            for item in entry.items {
                guard isDigest(item.identity), isDigest(item.name), isDigest(item.topology), item.guests.allSatisfy(isDigest), !item.reservedNames.isEmpty, item.reservedNames.allSatisfy(isDigest),
                      (entry.action == .rename ? item.newName.map(isDigest) == true : item.newName == nil),
                      item.phase != .succeeded || item.accepted, !item.accepted || [.submitted, .succeeded].contains(item.phase),
                      item.failure == nil || item.phase == .failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                if item.phase == .prepared || item.phase == .submitted {
                    guard protectedIDs.insert(entry.context + item.identity).inserted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                    for name in item.reservedNames {
                        guard protectedNames.insert(entry.context + name).inserted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                    }
                }
            }
        }
    }
}

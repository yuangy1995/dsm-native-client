import CryptoKit
import DsmCore
import Foundation
import Observation

/// 只持久化账号/目标摘要与逐项回执边界；名称留在当前会话内存。
@MainActor @Observable
final class MobileVirtualMachineControlStore {
    enum Kind: String, Codable, CaseIterable {
        case powerOn, shutdown, powerOff, restart, delete, edit
        static var controlCases: [Self] { allCases.filter { $0 != .edit } }
        init(_ action: VirtualMachinePowerAction) {
            switch action { case .powerOn: self = .powerOn; case .shutdown: self = .shutdown; case .powerOff: self = .powerOff; case .restart: self = .restart }
        }
        var controlAction: VirtualMachinePowerAction? { VirtualMachinePowerAction(rawValue: rawValue) }
        func supports(_ target: VirtualMachineControlState) -> Bool {
            if let controlAction { return target.supports(controlAction) }
            return self == .delete && target.canDelete
        }
    }
    enum Phase: String, Codable { case prepared, submitted, succeeded, failed, skipped }
    enum Failure: String, Codable { case denied, unavailable, changed, failed }
    struct Item: Equatable, Codable {
        let identity: String
        let name: String
        var phase: Phase = .prepared
        var accepted = false
        var failure: Failure?
        var settings: [String: String]?
        func matches(_ target: VirtualMachineControlState) -> Bool {
            identity == digest(target.id) && (name == digest(target.name) || settings?["name"] == digest(target.name))
        }
    }
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let context: String
        let action: Kind
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
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("VirtualMachineControls-\(UUID())")
        reload()
    }
    nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func protects(_ targets: [VirtualMachineControlState], context: String) -> Bool {
        failed || entries.contains { entry in
            entry.context == context && entry.items.contains { item in
                (item.phase == .prepared || item.phase == .submitted || isExecuting(entry.id)) && targets.contains {
                    item.identity == Self.digest($0.id) || item.name == Self.digest($0.name) || item.settings?["name"] == Self.digest($0.name)
                }
            }
        }
    }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let url = root.appendingPathComponent("virtual-machine-controls-v1.json")
            var values: [Entry] = []
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
            if FileManager.default.fileExists(atPath: url.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); values = envelope.entries
            } else if entries.contains(where: \.isProtected) {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
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
    func reserve(_ targets: [VirtualMachineControlState], action: Kind, context: String) throws -> Entry {
        guard !targets.isEmpty, targets.allSatisfy(action.supports), !protects(targets, context: context),
              Set(targets.map(\.id)).count == targets.count, Set(targets.map(\.name)).count == targets.count else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        let entry = Entry(id: UUID(), context: context, action: action, createdAt: Date(), items: targets.map {
            Item(identity: Self.digest($0.id), name: Self.digest($0.name))
        })
        try persist(entries + [entry]); executing.insert(entry.id); return entry
    }
    func protects(_ target: VirtualMachineSettingsState, context: String) -> Bool {
        protects([.init(id: target.id, name: target.name, status: target.status, availableActions: [], allowsDeletion: false)], context: context)
    }
    func reserveEdit(_ target: VirtualMachineSettingsState, update: VirtualMachineUpdate, context: String) throws -> Entry {
        guard target.canEdit, !protects(target, context: context) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = ["name": update.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? target.name]
        if let value = update.description { values["desc"] = value }
        if let value = update.cpuCount { values["vcpu_num"] = String(value) }
        if let value = update.memoryMiB { values["memory_mib"] = String(value) }
        if let value = update.cpuWeight { values["cpu_weight"] = String(value) }
        if let value = update.startupBehavior { values["autorun"] = String(value.rawValue) }
        let entry = Entry(id: UUID(), context: context, action: .edit, createdAt: Date(), items: [
            Item(identity: Self.digest(target.id), name: Self.digest(target.name), settings: values.mapValues(Self.digest))
        ])
        try persist(entries + [entry]); executing.insert(entry.id); return entry
    }
    func needsSettings(_ target: VirtualMachineControlState, context: String) -> Bool {
        entries.contains { entry in
            entry.context == context && entry.action == .edit && !isExecuting(entry.id) && entry.items.contains {
                $0.identity == Self.digest(target.id) && $0.phase == .submitted && $0.accepted
            }
        }
    }
    func resolveSettings(_ target: VirtualMachineSettingsState, context: String) throws {
        var fields = ["name": Self.digest(target.name)]
        if let value = target.description { fields["desc"] = Self.digest(value) }
        if let value = target.cpuCount { fields["vcpu_num"] = Self.digest(String(value)) }
        if let value = target.memoryMiB { fields["memory_mib"] = Self.digest(String(value)) }
        if let value = target.cpuWeight { fields["cpu_weight"] = Self.digest(String(value)) }
        if let value = target.startupBehavior { fields["autorun"] = Self.digest(String(value.rawValue)) }
        var values = entries
        for position in values.indices where values[position].context == context && values[position].action == .edit && !isExecuting(values[position].id) {
            guard let item = values[position].items.first, item.identity == Self.digest(target.id), item.phase == .submitted,
                  item.accepted, let settings = item.settings, settings.allSatisfy({ fields[$0.key] == $0.value }) else { continue }
            values[position].items[0].phase = .succeeded
        }
        if values != entries { try persist(values) }
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
    func resolve(_ targets: [VirtualMachineControlState], context: String) throws {
        var values = entries
        for position in values.indices where values[position].context == context && !isExecuting(values[position].id) {
            for index in values[position].items.indices where values[position].items[index].phase == .submitted {
                let item = values[position].items[index]
                let action = values[position].action
                guard item.accepted else { continue }
                if action == .delete {
                    // 只由共享层严格解析的完整目录证明原 ID 已消失；同名新实例不是删除目标。
                    if !targets.contains(where: { Self.digest($0.id) == item.identity }) {
                        values[position].items[index].phase = .succeeded
                    }
                } else if let action = action.controlAction, let target = targets.first(where: item.matches),
                          target.verifies(action) {
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
                to: root.appendingPathComponent("virtual-machine-controls-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        func isDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        var ids: Set<UUID> = [], protectedIDs: Set<String> = [], protectedNames: Set<String> = []
        for entry in values {
            guard ids.insert(entry.id).inserted, isDigest(entry.context), entry.createdAt.timeIntervalSince1970.isFinite,
                  entry.action != .edit || entry.items.count == 1,
                  !entry.items.isEmpty, Set(entry.items.map(\.identity)).count == entry.items.count,
                  Set(entry.items.map(\.name)).count == entry.items.count else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            for item in entry.items {
                if entry.action == .edit {
                    guard let settings = item.settings, settings["name"] != nil,
                          Set(settings.keys).isSubset(of: ["name", "desc", "vcpu_num", "memory_mib", "cpu_weight", "autorun"]),
                          settings.values.allSatisfy(isDigest) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                } else if item.settings != nil { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                guard isDigest(item.identity), isDigest(item.name),
                      item.phase != .succeeded || item.accepted,
                      entry.action != .restart || item.phase != .succeeded,
                      !item.accepted || [.submitted, .succeeded].contains(item.phase),
                      item.failure == nil || item.phase == .failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                if item.phase == .prepared || item.phase == .submitted {
                    guard protectedIDs.insert(entry.context + item.identity).inserted,
                          protectedNames.insert(entry.context + item.name).inserted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                    if let newName = item.settings?["name"], newName != item.name {
                        guard protectedNames.insert(entry.context + newName).inserted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                    }
                }
            }
        }
    }
}

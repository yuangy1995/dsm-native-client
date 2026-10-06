import CryptoKit
import DsmCore
import Foundation
import Observation

/// 创建只保存参数及身份摘要。已提交记录不能移除，也不会在恢复时重发。
@MainActor @Observable
final class MobileVirtualMachineCreationStore {
    enum Phase: String, Codable { case prepared, submitted, succeeded, failed, skipped }
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let context: String
        let nameDigest: String
        let createdAt: Date
        var phase = Phase.prepared
        var tracking: VirtualMachineCreationTracking?
        var isProtected: Bool { phase == .prepared || phase == .submitted }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []
    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("VirtualMachineCreation-\(UUID())")
        reload()
    }
    nonisolated static func nameDigest(_ name: String) -> String {
        MobileVirtualMachineControlStore.digest(name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")))
    }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func protects(name: String, id: String? = nil, context: String) -> Bool {
        failed || entries.contains {
            $0.context == context && ($0.isProtected || isExecuting($0.id))
                && ($0.nameDigest == Self.nameDigest(name) || (id != nil && $0.tracking?.guestIdentityDigest == MobileVirtualMachineControlStore.digest(id!)))
        }
    }
    func protectsResource(kind: String, id: String, context: String) -> Bool {
        failed || entries.contains {
            $0.context == context && ($0.isProtected || isExecuting($0.id))
                && $0.tracking?.resourceIdentityDigests[kind] == MobileVirtualMachineControlStore.digest(id)
        }
    }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let file = root.appendingPathComponent("virtual-machine-creations-v1.json")
            var values: [Entry] = [], isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
            if FileManager.default.fileExists(atPath: file.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); values = envelope.entries
            } else if entries.contains(where: \.isProtected) { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            entries = values; failed = false
            for index in values.indices where values[index].phase == .prepared { values[index].phase = .skipped }
            if values != entries { try persist(values) }
        } catch { failed = true }
    }
    func reserve(name: String, context: String) throws -> Entry {
        guard !protects(name: name, context: context) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let value = Entry(id: UUID(), context: context, nameDigest: Self.nameDigest(name), createdAt: Date())
        try persist(entries + [value]); executing.insert(value.id); return value
    }
    func checkpoint(_ id: UUID, stage: VirtualMachineCreationStage) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries, entry = values[index]
        switch stage {
        case .willSubmit(let tracking):
            guard entry.phase == .prepared, tracking.isValid, tracking.nameDigest == entry.nameDigest,
                  tracking.taskIdentityDigest == nil, tracking.guestIdentityDigest == nil else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            entry.phase = .submitted; entry.tracking = tracking
        case .accepted(let tracking), .taskSucceeded(let tracking):
            guard entry.phase == .submitted, let old = entry.tracking, tracking.isValid, tracking.requestID == old.requestID,
                  tracking.nameDigest == old.nameDigest, tracking.parameterDigests == old.parameterDigests,
                  tracking.configurationDigest == old.configurationDigest, tracking.existingIdentityDigests == old.existingIdentityDigests,
                  tracking.resourceIdentityDigests == old.resourceIdentityDigests,
                  tracking.taskIdentityDigest != nil, old.taskIdentityDigest == nil || old.taskIdentityDigest == tracking.taskIdentityDigest,
                  old.guestIdentityDigest == nil || old.guestIdentityDigest == tracking.guestIdentityDigest else {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
            if case .taskSucceeded = stage, tracking.guestIdentityDigest == nil { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            entry.tracking = tracking
        case .succeeded(let guestID):
            guard entry.phase == .submitted, let tracking = entry.tracking,
                  tracking.guestIdentityDigest == MobileVirtualMachineControlStore.digest(guestID) else {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
            entry.phase = .succeeded
        case .rejected:
            guard entry.phase == .submitted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            entry.phase = .failed
        }
        values[index] = entry; try persist(values)
    }
    func finish(_ id: UUID, failed: Bool) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].phase == .prepared else { return }
        var values = entries; values[index].phase = failed ? .failed : .skipped; try persist(values)
    }
    func end(_ id: UUID) { executing.remove(id) }
    func remove(_ id: UUID, context: String) throws {
        guard let value = entry(id), value.context == context, !value.isProtected, !isExecuting(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try persist(entries.filter { $0.id != id })
    }
    private func persist(_ values: [Entry]) throws {
        guard !failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try validate(values)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(
                to: root.appendingPathComponent("virtual-machine-creations-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        func digest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        var ids: Set<UUID> = [], protectedNames: Set<String> = [], requests: Set<UUID> = []
        for entry in values {
            guard ids.insert(entry.id).inserted, digest(entry.context), digest(entry.nameDigest), entry.createdAt.timeIntervalSince1970.isFinite,
                  entry.phase != .prepared || entry.tracking == nil,
                  entry.phase != .submitted || entry.tracking != nil,
                  entry.phase != .succeeded || entry.tracking?.guestIdentityDigest != nil else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if let tracking = entry.tracking {
                guard tracking.isValid, tracking.nameDigest == entry.nameDigest, requests.insert(tracking.requestID).inserted,
                      tracking.guestIdentityDigest.map({ !tracking.existingIdentityDigests.contains($0) }) != false else {
                    throw MobileTransferRecoveryStore.StoreError.invalidRecord
                }
            }
            if entry.isProtected, !protectedNames.insert(entry.context + entry.nameDigest).inserted { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        }
    }
}

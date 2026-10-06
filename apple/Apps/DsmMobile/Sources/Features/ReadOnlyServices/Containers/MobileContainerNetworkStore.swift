import DsmCore
import Foundation
import Observation

@MainActor @Observable
final class MobileContainerNetworkStore {
    enum Phase: String, Codable { case prepared, submitted, succeeded, existing, absent, rejected, skipped }
    enum Action: String, Codable { case create, delete }
    struct Entry: Identifiable, Codable, Equatable {
        let id: UUID
        let context: String
        let createdAt: Date
        let action: Action
        let creation: ContainerNetworkCreationIdentity?
        let deletion: ContainerNetworkDeletionIdentity?
        var phase: Phase = .prepared
        var accepted = false
        var denied = false
        var name: String { creation?.name ?? deletion!.name }
        var isProtected: Bool { phase == .prepared || phase == .submitted }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private var file: URL { root.appendingPathComponent("network-operations-v1.json") }
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []
    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("NetworkOperations-\(UUID())")
        reload()
    }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func protects(name: String, identity: String? = nil, context: String) -> Bool {
        failed || entries.contains {
            $0.context == context && ($0.name == name || (identity != nil && $0.deletion?.id == identity))
                && ($0.isProtected || isExecuting($0.id))
        }
    }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            var values: [Entry] = []
            if FileManager.default.fileExists(atPath: file.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); values = envelope.entries
            } else if entries.contains(where: \.isProtected) { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            entries = values; failed = false
            let restored = values.map { entry in
                var entry = entry
                if entry.phase == .prepared { entry.phase = .skipped }
                return entry
            }
            if restored != values { try persist(restored) }
        } catch { failed = true }
    }
    func reserve(context: String, creation: ContainerNetworkCreation? = nil, deletions: [ContainerNetwork] = []) throws -> [Entry] {
        guard (creation != nil && deletions.isEmpty) || (creation == nil && !deletions.isEmpty) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let values: [Entry]
        if let creation {
            guard creation.validationIssue == nil else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values = [.init(id: UUID(), context: context, createdAt: Date(), action: .create, creation: .init(creation), deletion: nil)]
        } else {
            guard deletions.allSatisfy(\.canDelete) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values = deletions.map { .init(id: UUID(), context: context, createdAt: Date(), action: .delete, creation: nil, deletion: .init($0)) }
        }
        guard values.allSatisfy({ !protects(name: $0.name, identity: $0.deletion?.id, context: context) }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try persist(entries + values); executing.formUnion(values.map(\.id)); return values
    }
    func checkpoint(_ id: UUID, _ stage: ContainerNetworkMutationStage) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), isExecuting(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries
        switch stage {
        case .willSubmit:
            guard values[index].phase == .prepared else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].phase = .submitted
        case .accepted:
            guard values[index].phase == .submitted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].accepted = true
        case .rejected:
            guard values[index].phase == .submitted, !values[index].accepted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].phase = .rejected
        case .verified:
            guard values[index].phase == .submitted, values[index].accepted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].phase = .succeeded
        }
        try persist(values)
    }
    func resolve(_ id: UUID, phase: Phase) throws {
        guard [.succeeded, .existing, .absent].contains(phase), let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].phase == .submitted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries; values[index].phase = phase; try persist(values)
    }
    func finish(_ ids: [UUID], denied: Bool = false) throws {
        var values = entries
        for index in values.indices where ids.contains(values[index].id) {
            if values[index].phase == .prepared { values[index].phase = .skipped }
            if values[index].phase != .succeeded { values[index].denied = denied }
        }
        try persist(values)
    }
    func end(_ ids: [UUID]) { executing.subtract(ids) }
    func remove(_ id: UUID, context: String) throws {
        guard let entry = entry(id), entry.context == context, !entry.isProtected, !isExecuting(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try persist(entries.filter { $0.id != id })
    }
    private func persist(_ values: [Entry]) throws {
        guard !failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try validate(values)
        do {
            if !entries.isEmpty && !FileManager.default.fileExists(atPath: file.path) { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(to: file, options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], protected: Set<String> = []
        for entry in values {
            guard ids.insert(entry.id).inserted, ContainerNetworkCreationIdentity.validDigest(entry.context),
                  entry.createdAt.timeIntervalSince1970.isFinite,
                  (entry.action == .create && entry.creation?.isValid == true && entry.deletion == nil)
                    || (entry.action == .delete && entry.deletion?.isValid == true && entry.creation == nil),
                  ![Phase.prepared, .skipped, .rejected].contains(entry.phase) || !entry.accepted,
                  entry.phase != .existing || (entry.action == .create && !entry.accepted),
                  entry.phase != .absent || (entry.action == .delete && !entry.accepted),
                  entry.phase != .succeeded || entry.accepted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if entry.isProtected && !protected.insert(entry.context + entry.name).inserted { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        }
    }
}

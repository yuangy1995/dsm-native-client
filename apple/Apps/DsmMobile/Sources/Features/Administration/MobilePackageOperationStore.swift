import CryptoKit
import DsmCore
import Foundation
import Observation

/// 套件记录只保存摘要和阶段，不保存来源地址、配置正文或凭据。
@MainActor @Observable
final class MobilePackageOperationStore {
    enum Phase: String, Codable { case prepared, submitted, succeeded, failed, cancelled }
    enum Failure: String, Codable { case denied, unavailable, changed, failed }
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let context: String
        let kind: NasPackagePreferenceKind
        let original: String?
        let target: String?
        let sourceURL: String?
        let oldSourceURL: String?
        let createdAt: Date
        var phase: Phase = .prepared
        var accepted = false
        var failure: Failure?
        var isProtected: Bool { phase == .prepared || phase == .submitted }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private struct SettingsSignature: Encodable {
        let beta: Bool; let email: Bool; let desktop: Bool; let policy: String; let volume: String; let packages: [[String]]
    }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []
    init(root: URL?) { self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("PackageOperations-\(UUID())"); reload() }
    nonisolated static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(value)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func signature(_ settings: NasPackageCenterSettings) -> String {
        digest(SettingsSignature(beta: settings.betaEnabled, email: settings.emailNotifications, desktop: settings.desktopNotifications,
            policy: settings.updatePolicy.rawValue, volume: settings.defaultVolumeID,
            packages: settings.updatePolicy == .selected ? settings.packageUpdates.filter { $0.policy != .manual }.sorted { $0.id < $1.id }.map { [$0.id, $0.policy.rawValue] } : []))
    }
    nonisolated static func signature(_ source: NasPackageSource) -> String { digest([source.name, source.url]) }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let url = root.appendingPathComponent("package-operations-v1.json")
            var values: [Entry] = []
            if FileManager.default.fileExists(atPath: url.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); values = envelope.entries
            }
            entries = values; failed = false
            let restored = values.map { entry in var value = entry; if value.phase == .prepared { value.phase = .cancelled }; return value }
            if restored != values { try persist(restored) }
        } catch { failed = true }
    }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func protects(context: String) -> Bool { failed || entries.contains { $0.context == context && ($0.isProtected || executing.contains($0.id)) } }
    func reserve(_ change: NasPackagePreferenceChange, context: String) throws -> Entry {
        guard change.isValid, !protects(context: context) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let original: String?, target: String?, sourceURL: String?, oldSourceURL: String?
        switch change {
        case .settings(let before, let after):
            original = Self.signature(before.settings); target = Self.signature(after); sourceURL = nil; oldSourceURL = nil
        case .saveSource(let value, let before):
            guard let normalized = value.normalizedForEditing else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            original = before.map(Self.signature); target = Self.signature(normalized)
            sourceURL = Self.digest(normalized.url); oldSourceURL = before.map { Self.digest($0.url) }
        case .removeSource(let value):
            original = Self.signature(value); target = nil; sourceURL = nil; oldSourceURL = Self.digest(value.url)
        }
        let value = Entry(id: UUID(), context: context, kind: change.kind, original: original, target: target,
            sourceURL: sourceURL, oldSourceURL: oldSourceURL, createdAt: Date())
        try persist(entries + [value]); executing.insert(value.id); return value
    }
    func checkpoint(_ id: UUID, _ checkpoint: NasPackagePreferenceCheckpoint) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), executing.contains(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries
        if checkpoint == .willSubmit {
            guard values[index].phase == .prepared else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].phase = .submitted
        } else {
            guard values[index].phase == .submitted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].accepted = true
        }
        try persist(values)
    }
    func finish(_ id: UUID, phase: Phase, failure: Failure? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isProtected,
              [.succeeded, .failed, .cancelled].contains(phase),
              phase != .succeeded || entries[index].phase == .submitted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries; values[index].phase = phase; values[index].failure = failure; try persist(values)
    }
    func end(_ id: UUID) { executing.remove(id) }
    func resolve(_ snapshot: NasPackagePreferencesSnapshot, context: String) throws {
        guard snapshot.settings.updatePolicy != .selected || snapshot.unknownUpdateIDs.isEmpty else { return }
        for value in entries where value.context == context && value.kind == .settings && value.phase == .submitted && !isExecuting(value.id) {
            if value.target == Self.signature(snapshot.settings) { try finish(value.id, phase: .succeeded) }
        }
    }
    func resolve(_ sources: [NasPackageSource], context: String) throws {
        let urls = Set(sources.map { Self.digest($0.url) }), targets = Set(sources.map(Self.signature))
        for value in entries where value.context == context && value.kind != .settings && value.phase == .submitted && !isExecuting(value.id) {
            let matches: Bool
            if value.kind == .removeSource { matches = value.oldSourceURL.map { !urls.contains($0) } == true }
            else { matches = value.target.map(targets.contains) == true && (value.oldSourceURL == nil || value.oldSourceURL == value.sourceURL || value.oldSourceURL.map { !urls.contains($0) } == true) }
            if matches { try finish(value.id, phase: .succeeded) }
        }
    }
    func remove(_ id: UUID, context: String) throws {
        guard let value = entry(id), value.context == context, !value.isProtected, !isExecuting(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try persist(entries.filter { $0.id != id })
    }
    private func persist(_ values: [Entry]) throws {
        guard !failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try validate(values)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(to: root.appendingPathComponent("package-operations-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], contexts: Set<String> = []
        for value in values {
            guard ids.insert(value.id).inserted, Self.isDigest(value.context), value.createdAt.timeIntervalSince1970.isFinite,
                  [value.original, value.target, value.sourceURL, value.oldSourceURL].allSatisfy({ $0.map(Self.isDigest) ?? true }),
                  !value.accepted || [.submitted, .succeeded].contains(value.phase) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            switch value.kind {
            case .settings: guard value.original != nil, value.target != nil, value.sourceURL == nil, value.oldSourceURL == nil else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            case .saveSource: guard value.target != nil, value.sourceURL != nil, (value.original == nil) == (value.oldSourceURL == nil) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            case .removeSource: guard value.original != nil, value.oldSourceURL != nil, value.target == nil, value.sourceURL == nil else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            }
            if value.isProtected, !contexts.insert(value.context).inserted { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        }
    }
    private static func isDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

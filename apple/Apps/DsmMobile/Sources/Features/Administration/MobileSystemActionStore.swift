import CryptoKit
import DsmCore
import Foundation
import Observation

/// 记录只保存不可逆摘要、动作和阶段，不包含连接内容、设备标识或会话凭据原文。
@MainActor @Observable
final class MobileSystemActionStore {
    enum Phase: String, Codable { case prepared, submitted, succeeded, accepted, released, failed, cancelled }
    enum Failure: String, Codable { case denied, unavailable, changed, failed }
    struct Target: Equatable, Codable {
        let web: Bool
        let identity: String
        let account: String
        let source: String?
        let description: String?
        init(_ value: NasConnection) {
            web = value.isWebConnection
            identity = MobileSystemActionStore.digest([web ? value.deviceID : value.processID])
            account = MobileSystemActionStore.digest([value.account])
            source = value.source.map { MobileSystemActionStore.digest([$0]) }
            description = value.description.map { MobileSystemActionStore.digest([$0]) }
        }
        func mayRemain(in value: NasConnection) -> Bool {
            let raw = web ? value.deviceID : value.processID
            if let raw, !raw.isEmpty { return MobileSystemActionStore.digest([raw]) == identity }
            let other = Self(value)
            return account == other.account
                && (source == nil || other.source == nil || source == other.source)
                && (description == nil || other.description == nil || description == other.description)
        }
    }
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let context: String
        let action: NasSystemActionKind
        let target: Target?
        let session: String?
        let createdAt: Date
        var phase: Phase = .prepared
        var accepted = false
        var failure: Failure?
        var isProtected: Bool { phase == .prepared || phase == .submitted || phase == .accepted }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []
    init(root: URL?) { self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("SystemActions-\(UUID())"); reload() }
    nonisolated static func digest(_ values: [String?]) -> String {
        SHA256.hash(data: (try? JSONEncoder().encode(values)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let url = root.appendingPathComponent("system-actions-v1.json")
            var values: [Entry] = []
            if FileManager.default.fileExists(atPath: url.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); values = envelope.entries
            }
            entries = values; failed = false
            let recovered = values.map { entry in
                var value = entry
                if value.phase == .prepared { value.phase = .cancelled }
                if value.phase == .submitted && value.action != .disconnect && value.accepted { value.phase = .accepted }
                return value
            }
            if recovered != values { try persist(recovered) }
        } catch { failed = true }
    }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func protects(_ action: NasSystemAction, context: String) -> Bool {
        failed || entries.contains { entry in
            guard entry.context == context, entry.isProtected || executing.contains(entry.id) else { return false }
            if let connection = action.connection { return entry.target?.mayRemain(in: connection) == true }
            return entry.action != .disconnect
        }
    }
    func reserve(_ action: NasSystemAction, context: String, session: String?) throws -> Entry {
        guard !protects(action, context: context), action.connection?.hasDisconnectIdentity != false,
              action.connection != nil || session.map(Self.isDigest) == true else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let value = Entry(id: UUID(), context: context, action: action.kind, target: action.connection.map(Target.init),
                          session: action.connection == nil ? session : nil, createdAt: Date())
        try persist(entries + [value]); executing.insert(value.id); return value
    }
    func checkpoint(_ id: UUID, _ checkpoint: NasSystemActionCheckpoint) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), executing.contains(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries
        switch checkpoint {
        case .willSubmit:
            guard values[index].phase == .prepared else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].phase = .submitted
        case .accepted:
            guard values[index].phase == .submitted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            values[index].accepted = true
        }
        try persist(values)
    }
    func finish(_ id: UUID, phase: Phase, failure: Failure? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isProtected,
              [.succeeded, .accepted, .failed, .cancelled].contains(phase),
              phase != .succeeded || entries[index].action == .disconnect && entries[index].phase == .submitted,
              phase != .accepted || entries[index].action != .disconnect && entries[index].accepted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries; values[index].phase = phase; values[index].failure = failure; try persist(values)
    }
    func end(_ id: UUID) { executing.remove(id) }
    func resolveConnections(_ page: NasConnectionPage, context: String) throws {
        guard page.isCompleteForManagement else { return }
        for value in entries where value.context == context && value.action == .disconnect && value.phase == .submitted && !isExecuting(value.id) {
            if let target = value.target, !page.connections.contains(where: { target.mayRemain(in: $0) }) { try finish(value.id, phase: .succeeded) }
        }
    }
    func canReleasePower(context: String, session: String) -> Bool {
        let values = entries.filter { $0.context == context && $0.action != .disconnect && $0.isProtected }
        return !failed && Self.isDigest(session) && !values.isEmpty && values.allSatisfy { $0.session != session && !isExecuting($0.id) && $0.phase != .prepared }
    }
    /// 仅在新登录、明确设备恢复确认与只读预检后调用，不宣称上次电源动作已经完成。
    func releasePower(context: String, session: String) throws {
        guard canReleasePower(context: context, session: session) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try persist(entries.map { entry in
            var value = entry
            if value.context == context && value.action != .disconnect && value.isProtected { value.phase = .released }
            return value
        })
    }
    func remove(_ id: UUID, context: String) throws {
        guard let entry = entry(id), entry.context == context, !entry.isProtected, !isExecuting(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try persist(entries.filter { $0.id != id })
    }
    private func persist(_ values: [Entry]) throws {
        guard !failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try validate(values)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(to: root.appendingPathComponent("system-actions-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], protected: Set<String> = []
        for value in values {
            guard ids.insert(value.id).inserted, Self.isDigest(value.context), value.createdAt.timeIntervalSince1970.isFinite,
                  (value.action == .disconnect) == (value.target != nil),
                  value.action == .disconnect ? value.session == nil : value.session.map(Self.isDigest) == true,
                  !value.accepted || [.submitted, .succeeded, .accepted, .released].contains(value.phase),
                  value.phase != .accepted || value.action != .disconnect && value.accepted,
                  value.phase != .succeeded || value.action == .disconnect,
                  value.phase != .released || value.action != .disconnect else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if let target = value.target {
                guard Self.isDigest(target.identity), Self.isDigest(target.account),
                      [target.source, target.description].allSatisfy({ $0.map(Self.isDigest) ?? true }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            }
            let key = value.context + (value.target.map { ($0.web ? "web:" : "service:") + $0.identity } ?? "power")
            if value.isProtected, !protected.insert(key).inserted { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        }
    }
    private static func isDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

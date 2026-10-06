import CryptoKit
import DsmCore
import Foundation
import Observation

/// 安装恢复只保留目标摘要与提交边界；不会持久化安装选项、下载地址或 NAS 暂存标识。
@MainActor @Observable
final class MobilePackageInstallationStore {
    enum Phase: String, Codable { case prepared, active, completed, partial, failed, cancelled, interrupted }
    struct Target: Equatable, Codable {
        let packageID: String
        let version: String
        let sameVersion: Bool
        init(_ package: NasPackageCatalogEntry) {
            packageID = MobilePackageOperationStore.digest(package.packageID)
            version = MobilePackageOperationStore.digest(package.version)
            sameVersion = package.installedVersion == package.version
        }
        func matches(_ package: NasPackage) -> Bool {
            guard ["running", "stopped", "active", "inactive"].contains(package.status?.lowercased() ?? ""),
                  let version = package.version else { return false }
            return packageID == MobilePackageOperationStore.digest(package.id) && self.version == MobilePackageOperationStore.digest(version)
        }
    }
    struct Step: Equatable, Codable {
        let kind: NasPackageInstallationCheckpoint.Step
        let index: Int
        let target: Target?
        let synchronous: Bool
        var stage: NasPackageInstallationCheckpoint.Stage
        var unresolvedInstallation: Bool { kind == .install && stage != .verified && stage != .rejected }
    }
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let context: String
        let createdAt: Date
        let isUpload: Bool
        let totalCount: Int
        var operationID: UUID?
        var phase: Phase = .prepared
        var steps: [Step] = []
        var completedCount: Int { steps.filter { $0.kind == .install && $0.stage == .verified }.count }
        var isProtected: Bool { phase == .prepared || phase == .active }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []
    init(root: URL?) { self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("PackageInstallation-\(UUID())"); reload() }
    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func protects(_ context: String) -> Bool { failed || entries.contains { $0.context == context && ($0.isProtected || isExecuting($0.id)) } }
    func reload() {
        guard executing.isEmpty else { return }
        do {
            let url = root.appendingPathComponent("package-installations-v1.json")
            var values: [Entry] = []
            if FileManager.default.fileExists(atPath: url.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(envelope.entries); values = envelope.entries
            }
            entries = values; failed = false
            let restored = values.map { entry in
                var value = entry
                if value.phase == .prepared { value.phase = .cancelled }
                else if value.phase == .active && !value.steps.contains(where: \.unresolvedInstallation) {
                    value.phase = value.completedCount == value.totalCount ? .completed : value.completedCount > 0 ? .partial : .interrupted
                }
                return value
            }
            if values != restored { try persist(restored) }
        } catch { failed = true }
    }
    func reserve(context: String, totalCount: Int, isUpload: Bool) throws -> Entry {
        guard !protects(context), totalCount > 0 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let entry = Entry(id: UUID(), context: context, createdAt: Date(), isUpload: isUpload, totalCount: totalCount)
        try persist(entries + [entry]); executing.insert(entry.id); return entry
    }
    func begin(_ id: UUID, context: String) throws {
        guard !failed, let entry = entry(id), entry.context == context, entry.isProtected, !isExecuting(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        executing.insert(id)
    }
    func end(_ id: UUID) { executing.remove(id) }
    func checkpoint(_ id: UUID, _ event: NasPackageInstallationCheckpoint) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), isExecuting(id),
              entries[index].operationID == nil || entries[index].operationID == event.id,
              event.totalCount == entries[index].totalCount, (0..<event.totalCount).contains(event.completedCount) else {
            throw MobileTransferRecoveryStore.StoreError.invalidRecord
        }
        var values = entries, entry = values[index]
        entry.operationID = event.id; entry.phase = .active
        let target = event.package.map(Target.init)
        if event.stage == .willSubmit {
            guard !entry.steps.contains(where: { $0.kind == event.step && $0.index == event.completedCount }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            entry.steps.append(.init(kind: event.step, index: event.completedCount, target: target,
                                     synchronous: event.isSynchronousInstallation, stage: event.stage))
        } else {
            guard let stepIndex = entry.steps.lastIndex(where: { $0.kind == event.step && $0.index == event.completedCount }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            let previous = entry.steps[stepIndex]
            guard previous.target == target || (event.step == .upload && previous.target == nil && event.stage == .prepared),
                  ![NasPackageInstallationCheckpoint.Stage.rejected, .verified].contains(previous.stage) || previous.stage == event.stage else {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
            entry.steps[stepIndex] = .init(kind: previous.kind, index: previous.index, target: target,
                                         synchronous: previous.synchronous, stage: event.stage)
        }
        values[index] = entry; try persist(values)
    }
    func finish(_ id: UUID, phase: NasPackageInstallProgress.Phase?) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var values = entries
        if values[index].steps.contains(where: \.unresolvedInstallation) { values[index].phase = .active }
        else if values[index].completedCount == values[index].totalCount { values[index].phase = .completed }
        else if values[index].completedCount > 0 && (phase == .failed || phase == .cancelled || phase == nil) { values[index].phase = .partial }
        else if phase == .cancelled { values[index].phase = .cancelled }
        else if phase == .failed { values[index].phase = .failed }
        else if phase == nil { values[index].phase = values[index].steps.isEmpty ? .failed : .interrupted }
        else { values[index].phase = .active }
        try persist(values)
    }
    /// 进程退出后只读取完整目录，不恢复旧表单、下载或依赖提交。
    func resolve(_ packages: [NasPackage], context: String) throws {
        for entry in entries where entry.context == context && entry.phase == .active && !isExecuting(entry.id) {
            var updated = entry
            for index in updated.steps.indices {
                let step = updated.steps[index]
                guard step.unresolvedInstallation, let target = step.target,
                      !target.sameVersion || (step.synchronous && step.stage == .accepted), packages.contains(where: target.matches) else { continue }
                updated.steps[index].stage = .verified
            }
            if !updated.steps.contains(where: \.unresolvedInstallation) {
                updated.phase = updated.completedCount == updated.totalCount ? .completed : updated.completedCount > 0 ? .partial : .interrupted
            }
            if updated != entry { try persist(entries.map { $0.id == entry.id ? updated : $0 }) }
        }
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
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(to: root.appendingPathComponent("package-installations-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], contexts: Set<String> = []
        for entry in values {
            guard ids.insert(entry.id).inserted, isDigest(entry.context), entry.totalCount > 0,
                  !entry.isUpload || entry.totalCount == 1, entry.createdAt.timeIntervalSince1970.isFinite,
                  entry.steps.isEmpty || entry.operationID != nil else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            var steps: Set<String> = []
            for step in entry.steps {
                guard (0..<entry.totalCount).contains(step.index), steps.insert("\(step.kind.rawValue):\(step.index)").inserted,
                      step.target.map({ isDigest($0.packageID) && isDigest($0.version) }) ?? (step.kind == .upload),
                      !step.synchronous || step.kind == .install else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            }
            if entry.phase == .completed, entry.completedCount != entry.totalCount { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if !entry.isProtected, entry.steps.contains(where: \.unresolvedInstallation) { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if entry.isProtected, !contexts.insert(entry.context).inserted { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        }
    }
    private func isDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

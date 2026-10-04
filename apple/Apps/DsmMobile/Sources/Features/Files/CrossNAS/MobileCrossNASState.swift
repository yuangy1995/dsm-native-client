import DsmCore
import Foundation

struct MobileCrossNASEndpoint: Sendable {
    let profile: NasProfile
    let repository: any MobileCrossNASRepository
    var context: String { MobileWorkspaceIdentity(profile).storageIdentifier }
}

enum MobileCrossNASItemStatus: String, Codable, Sendable {
    case pending, writing, copied, uncertain, deleting, removed, deleteUncertain
}

enum MobileCrossNASPhase: String, Codable, Sendable {
    case paused, copying, copied, removing, finished, interrupted
}

enum MobileCrossNASFailure: String, Codable, Error, Sendable {
    case connection, permission, changed, conflict, interrupted, recovery, invalid, unavailable
}

struct MobileCrossNASEntry: Codable, Identifiable, Equatable, Sendable {
    var id: String { source.path }
    let source: FileItem
    let destination: String
    let digest: String?
    var status: MobileCrossNASItemStatus = .pending
}

struct MobileCrossNASRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let sourceID: UUID
    let sourceContext: String
    let sourceName: String
    let targetID: UUID
    let targetContext: String
    let targetName: String
    let destination: String
    let moveSource: Bool
    var entries: [MobileCrossNASEntry]
    var phase: MobileCrossNASPhase = .paused
    var failure: MobileCrossNASFailure?

    var isRunning: Bool { phase == .copying || phase == .removing }
    var hasUnknown: Bool { entries.contains { [.writing, .uncertain, .deleting, .deleteUncertain].contains($0.status) } }
    var canContinue: Bool { !isRunning && !hasUnknown && entries.contains { $0.status == .pending } }
    var canRemoveSource: Bool { moveSource && !isRunning && entries.contains { $0.status == .copied } && entries.allSatisfy { $0.status == .copied || $0.status == .removed } }
    var completedCount: Int { entries.filter { $0.status == .copied || $0.status == .removed }.count }

    /// 恢复内容不能改变目标或把一项写入解释为另一账号的任务。
    var isValid: Bool {
        guard sourceID != targetID, !sourceContext.isEmpty, !targetContext.isEmpty,
              MobileCrossNASPlan.validPath(destination), !entries.isEmpty,
              Set(entries.map(\.source.path)).count == entries.count,
              Set(entries.map(\.destination)).count == entries.count else { return false }
        var directories: [String: String] = [:]
        var rootParents = Set<String>()
        for entry in entries {
            guard MobileCrossNASPlan.canSelect(entry.source, profileID: sourceID),
                  MobileCrossNASPlan.validPath(entry.destination),
                  entry.destination.hasPrefix(destination + "/"),
                  MobileCrossNASPlan.leaf(entry.destination) == entry.source.name,
                  entry.source.isDirectory ? entry.digest == nil : MobileCrossNASPlan.validDigest(entry.digest),
                  moveSource || ![.deleting, .removed, .deleteUncertain].contains(entry.status) else { return false }
            let targetParent = MobileCrossNASPlan.parent(entry.destination)
            if targetParent == destination { rootParents.insert(MobileCrossNASPlan.parent(entry.source.path)) }
            else if directories[MobileCrossNASPlan.parent(entry.source.path)] != targetParent { return false }
            if entry.source.isDirectory { directories[entry.source.path] = entry.destination }
        }
        return rootParents.count == 1
    }
}

struct MobileCrossNASStore {
    private struct Envelope: Codable { let version: Int; let records: [MobileCrossNASRecord] }
    let root: URL
    var file: URL { root.appendingPathComponent("queue-v1.json") }

    func load() throws -> [MobileCrossNASRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
        guard envelope.version == 1, Set(envelope.records.map(\.id)).count == envelope.records.count,
              envelope.records.allSatisfy(\.isValid) else { throw MobileCrossNASFailure.recovery }
        return envelope.records.map { original in
            var record = original
            for index in record.entries.indices {
                switch record.entries[index].status {
                case .writing: record.entries[index].status = .uncertain
                case .deleting: record.entries[index].status = .deleteUncertain
                default: break
                }
            }
            if record.isRunning { record.phase = record.hasUnknown ? .interrupted : .paused }
            return record
        }
    }

    func save(_ records: [MobileCrossNASRecord]) throws {
        guard records.allSatisfy(\.isValid) else { throw MobileCrossNASFailure.recovery }
        try MobileTransferRecoveryStore.prepareDirectory(root)
        try JSONEncoder().encode(Envelope(version: 1, records: records)).write(to: file,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

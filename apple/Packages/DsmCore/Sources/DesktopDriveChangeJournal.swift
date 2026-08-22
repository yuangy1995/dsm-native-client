import Foundation

/// File Provider 增量枚举中的项目变化类型。
public enum DesktopDriveChangeJournalEntryKind: String, Codable, Equatable, Sendable {
    case updated
    case deleted
}

/// 一条可重放的 File Provider 目录变化。
public struct DesktopDriveChangeJournalEntry: Codable, Equatable, Sendable {
    public let revision: Int64
    public let kind: DesktopDriveChangeJournalEntryKind
    public let itemIdentifier: String
    public let item: FileItem?

    public init(
        revision: Int64,
        kind: DesktopDriveChangeJournalEntryKind,
        itemIdentifier: String,
        item: FileItem?
    ) {
        self.revision = revision
        self.kind = kind
        self.itemIdentifier = itemIdentifier
        self.item = item
    }
}

/// 保存在 App Group 配置快照中的目录快照与有限历史。
///
/// `generation` 会在无法可靠复用旧日志时更换，迫使旧锚点走系统的完整重新枚举路径，
/// 而不是猜测遗漏的增量变化。
public struct DesktopDriveChangeJournal: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generation: UUID
    public var currentRevision: Int64
    /// 仍可安全读取全部后续变化的最小锚点修订号。
    public var minimumAnchorRevision: Int64
    public var snapshot: [String: FileItem]
    public var entries: [DesktopDriveChangeJournalEntry]

    public init(
        snapshot: [String: FileItem],
        generation: UUID = UUID()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generation = generation
        currentRevision = 0
        minimumAnchorRevision = 0
        self.snapshot = snapshot
        entries = []
    }

    /// 把最新完整目录快照折算为按修订号有序的更新与删除事件。
    public mutating func apply(
        snapshot currentSnapshot: [String: FileItem],
        maximumEntryCount: Int
    ) {
        let retainedLimit = max(maximumEntryCount, 1)

        for identifier in snapshot.keys.sorted() where currentSnapshot[identifier] == nil {
            append(
                kind: .deleted,
                itemIdentifier: identifier,
                item: nil
            )
        }
        for identifier in currentSnapshot.keys.sorted() {
            guard let item = currentSnapshot[identifier], snapshot[identifier] != item else {
                continue
            }
            append(
                kind: .updated,
                itemIdentifier: identifier,
                item: item
            )
        }
        snapshot = currentSnapshot

        while entries.count > retainedLimit {
            let removed = entries.removeFirst()
            minimumAnchorRevision = max(minimumAnchorRevision, removed.revision)
        }
    }

    /// 仅在可证明日志顺序和内容完整时允许继续复用原 generation。
    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              currentRevision >= 0,
              minimumAnchorRevision >= 0,
              minimumAnchorRevision <= currentRevision else {
            return false
        }
        var previousRevision = minimumAnchorRevision
        for entry in entries {
            let expectedRevision = previousRevision.addingReportingOverflow(1)
            guard !expectedRevision.overflow,
                  entry.revision == expectedRevision.partialValue,
                  entry.revision <= currentRevision,
                  !entry.itemIdentifier.isEmpty else {
                return false
            }
            switch entry.kind {
            case .updated where entry.item == nil:
                return false
            case .deleted where entry.item != nil:
                return false
            default:
                break
            }
            previousRevision = entry.revision
        }
        // 若中间修订号缺失，旧锚点无法证明能重放完整变化，必须失效而不是继续同步。
        return previousRevision == currentRevision
    }

    private mutating func append(
        kind: DesktopDriveChangeJournalEntryKind,
        itemIdentifier: String,
        item: FileItem?
    ) {
        let next = currentRevision.addingReportingOverflow(1)
        // Int64 溢出时不再复用当前 generation；调用方会重建安全基线。
        guard !next.overflow else {
            schemaVersion = -1
            return
        }
        currentRevision = next.partialValue
        entries.append(
            .init(
                revision: currentRevision,
                kind: kind,
                itemIdentifier: itemIdentifier,
                item: item
            )
        )
    }
}

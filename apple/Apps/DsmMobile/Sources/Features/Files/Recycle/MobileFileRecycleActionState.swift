import DsmCore
import Foundation

enum MobileFileRecycleActionOperation: String, Equatable, Sendable {
    case moveToRecycle
    case restoreFromRecycle
}

enum MobileFileRecycleActionPhase: Equatable, Sendable {
    case confirming
    case submitting
    case result
    case review
}

enum MobileFileRecycleActionFeedback: Equatable, Sendable {
    case permission
    case unsupported
    case conflict
}

struct MobileFileRecycleActionPresentation: Equatable, Sendable {
    let profileID: UUID
    let operation: MobileFileRecycleActionOperation
    let source: FileItem
    let sourceParentPath: String
    let destinationPath: String
    let recycleLocation: FileRecycleLocation?
    var phase: MobileFileRecycleActionPhase = .confirming
    var feedback: MobileFileRecycleActionFeedback?
    var completedBytes: Int64 = 0
    var totalBytes: Int64?
    var cancellationRequested = false

    var progressFraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

struct MobileFileRecycleActionSuccess: Equatable, Sendable {
    let profileID: UUID
    let operation: MobileFileRecycleActionOperation
    let sourceParentPath: String
    let destinationParentPath: String
    let sourcePath: String
    let destinationPath: String
    let item: FileItem
}

struct MobileFileRecycleActionReviewKey: Hashable, Sendable {
    let profileID: UUID
    let operation: MobileFileRecycleActionOperation
    let sourcePath: String
    let destinationPath: String
}

@MainActor
final class MobileFileRecycleActionReviewBlocker {
    static let shared = MobileFileRecycleActionReviewBlocker()
    private var keys: Set<MobileFileRecycleActionReviewKey> = []

    func contains(_ key: MobileFileRecycleActionReviewKey) -> Bool { keys.contains(key) }
    func insert(_ key: MobileFileRecycleActionReviewKey) { keys.insert(key) }
    func purge(profileID: UUID) { keys = keys.filter { $0.profileID != profileID } }
}

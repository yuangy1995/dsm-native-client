import DsmCore
import Foundation

enum MobileFileCopyMovePhase: Equatable, Sendable {
    case browsing
    case loadingDestination
    case submitting
    case review
}

enum MobileFileCopyMoveFeedback: Equatable, Sendable {
    case permission
    case unsupported
    case conflict
    case invalidDestination
}

struct MobileFileCopyMoveDestinationState: Equatable, Sendable {
    var path = ""
    var history: [String] = []
    var folders: [FileItem] = []
    var nextOffset = 0
    var hasMore = false
    var pageState: MobilePageState = .loading
    var isLoadingMore = false
    var loadMoreFailed = false
    var hasRefreshError = false
}

struct MobileFileCopyMovePresentation: Equatable, Sendable {
    let profileID: UUID
    let operation: FileCopyMoveOperation
    let source: FileItem
    let sourceParentPath: String
    let readOnlyRoots: [String]
    var destination = MobileFileCopyMoveDestinationState()
    var phase: MobileFileCopyMovePhase = .browsing
    var feedback: MobileFileCopyMoveFeedback?
    var completedBytes: Int64 = 0
    var totalBytes: Int64?
    var cancellationRequested = false

    var progressFraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

struct MobileFileCopyMoveSuccess: Equatable, Sendable {
    let profileID: UUID
    let operation: FileCopyMoveOperation
    let sourceParentPath: String
    let destinationFolderPath: String
    let item: FileItem
}

struct MobileFileCopyMoveReviewKey: Hashable, Sendable {
    let profileID: UUID
    let operation: FileCopyMoveOperation
    let source: FileItem
    let destinationFolderPath: String
}

@MainActor
final class MobileFileCopyMoveReviewBlocker {
    static let shared = MobileFileCopyMoveReviewBlocker()
    private var keys: Set<MobileFileCopyMoveReviewKey> = []

    func contains(_ key: MobileFileCopyMoveReviewKey) -> Bool { keys.contains(key) }
    func insert(_ key: MobileFileCopyMoveReviewKey) { keys.insert(key) }
    func purge(profileID: UUID) { keys = keys.filter { $0.profileID != profileID } }
}

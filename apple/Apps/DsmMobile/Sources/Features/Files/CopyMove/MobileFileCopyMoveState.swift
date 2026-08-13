import DsmCore
import Foundation

enum MobileFileCopyMovePhase: Equatable, Sendable {
    case browsing
    case loadingDestination
    case submitting
    case completed
    case review
}

enum MobileFileCopyMoveFeedback: Equatable, Sendable {
    case permission
    case unsupported
    case conflict
    case failed
    case invalidDestination
}

enum MobileFileCopyMoveItemStatus: Equatable, Sendable {
    case notStarted
    case submitting
    case confirmed
    case failed
    case pendingReview
    case cancelled
}

struct MobileFileCopyMoveItemState: Equatable, Sendable {
    let source: FileItem
    var status: MobileFileCopyMoveItemStatus = .notStarted
    var feedback: MobileFileCopyMoveFeedback?
    var confirmedItem: FileItem?
}

struct MobileFileCopyMoveBatchCounts: Equatable, Sendable {
    let confirmed: Int
    let failed: Int
    let pendingReview: Int
    let cancelled: Int
    let notStarted: Int

    var total: Int { confirmed + failed + pendingReview + cancelled + notStarted }
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
    let sources: [FileItem]
    let sourceParentPath: String
    let readOnlyRoots: [String]
    var destination = MobileFileCopyMoveDestinationState()
    var phase: MobileFileCopyMovePhase = .browsing
    var feedback: MobileFileCopyMoveFeedback?
    var completedBytes: Int64 = 0
    var totalBytes: Int64?
    var cancellationRequested = false

    var itemStates: [MobileFileCopyMoveItemState]
    var currentItemIndex: Int?

    init(
        profileID: UUID,
        operation: FileCopyMoveOperation,
        source: FileItem,
        sources: [FileItem]? = nil,
        sourceParentPath: String,
        readOnlyRoots: [String]
    ) {
        let frozenSources = sources ?? [source]
        self.profileID = profileID
        self.operation = operation
        self.source = source
        self.sources = frozenSources
        self.sourceParentPath = sourceParentPath
        self.readOnlyRoots = readOnlyRoots
        itemStates = frozenSources.map { MobileFileCopyMoveItemState(source: $0) }
    }

    var isBatch: Bool { sources.count > 1 }

    var currentSource: FileItem? {
        guard let currentItemIndex, itemStates.indices.contains(currentItemIndex) else { return nil }
        return itemStates[currentItemIndex].source
    }

    var currentItemNumber: Int? { currentItemIndex.map { $0 + 1 } }

    var batchCounts: MobileFileCopyMoveBatchCounts {
        MobileFileCopyMoveBatchCounts(
            confirmed: itemStates.count { $0.status == .confirmed },
            failed: itemStates.count { $0.status == .failed },
            pendingReview: itemStates.count { $0.status == .pendingReview },
            cancelled: itemStates.count { $0.status == .cancelled },
            notStarted: itemStates.count { $0.status == .notStarted || $0.status == .submitting }
        )
    }

    var progressFraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    var canSubmitDestination: Bool {
        guard !destination.path.isEmpty,
              destination.path != sourceParentPath else { return false }
        return !sources.contains {
            $0.kind == .directory &&
                (destination.path == $0.path || destination.path.hasPrefix($0.path + "/"))
        }
    }
}

struct MobileFileCopyMoveSuccess: Equatable, Sendable {
    let profileID: UUID
    let operation: FileCopyMoveOperation
    let sourceParentPath: String
    let destinationFolderPath: String
    let item: FileItem
    let confirmedItems: [FileItem]

    init(
        profileID: UUID,
        operation: FileCopyMoveOperation,
        sourceParentPath: String,
        destinationFolderPath: String,
        item: FileItem,
        confirmedItems: [FileItem]? = nil
    ) {
        self.profileID = profileID
        self.operation = operation
        self.sourceParentPath = sourceParentPath
        self.destinationFolderPath = destinationFolderPath
        self.item = item
        self.confirmedItems = confirmedItems ?? [item]
    }
}

struct MobileFileCopyMoveReviewKey: Hashable, Sendable {
    let profileID: UUID
    let operation: FileCopyMoveOperation
    let sourcePath: String
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

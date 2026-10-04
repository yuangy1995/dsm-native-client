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
    case recovery
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

struct MobileFileCopyMoveReviewKey: Hashable, Codable, Sendable {
    let profileID: UUID
    let context: String
    let operation: FileCopyMoveOperation
    let sourcePath: String
    let destinationFolderPath: String
}

/// 提交前保存原目标，进程退出、断线或换账号均不能解除未知操作的限制。
@MainActor
final class MobileFileCopyMoveReviewBlocker {
    static let shared = MobileFileCopyMoveReviewBlocker()
    private struct Recovery: Codable { let version: Int; let keys: Set<MobileFileCopyMoveReviewKey> }
    private var keys: Set<MobileFileCopyMoveReviewKey> = []
    private let root: URL?
    private(set) var recoveryFailed = false

    init(rootURL: URL? = nil) {
        root = rootURL
        guard let file = root?.appendingPathComponent("pending-v1.json"),
              FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let value = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: file))
            guard value.version == 1, value.keys.allSatisfy({ !$0.context.isEmpty && $0.sourcePath.hasPrefix("/") && $0.destinationFolderPath.hasPrefix("/") }) else {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
            keys = value.keys
        } catch { recoveryFailed = true }
    }

    func contains(_ key: MobileFileCopyMoveReviewKey) -> Bool {
        keys.contains { old in
            guard old.profileID == key.profileID, old.context == key.context else { return false }
            // 同一源或其子树不能改换目标重试，目标也不能与未结束输出重叠。
            let oldPaths = [old.sourcePath, Self.destination(old)]
            let newPaths = [key.sourcePath, Self.destination(key)]
            return oldPaths.contains { left in newPaths.contains { right in
                left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
            } }
        }
    }

    @discardableResult func insert(_ key: MobileFileCopyMoveReviewKey) -> Bool {
        keys.insert(key)
        return persist()
    }
    func remove(_ key: MobileFileCopyMoveReviewKey) {
        let old = keys; keys.remove(key)
        if !persist() { keys = old }
    }
    func purge(profileID: UUID) {
        let old = keys; keys = keys.filter { $0.profileID != profileID }
        if !persist() { keys = old }
    }

    private static func destination(_ key: MobileFileCopyMoveReviewKey) -> String {
        key.destinationFolderPath + "/" + (key.sourcePath.split(separator: "/").last.map(String.init) ?? "")
    }
    private func persist() -> Bool {
        guard !recoveryFailed else { return false }
        guard let root else { return true }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var directory = root, values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try JSONEncoder().encode(Recovery(version: 1, keys: keys)).write(to: root.appendingPathComponent("pending-v1.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { recoveryFailed = true; return false }
    }
}

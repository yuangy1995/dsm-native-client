import DsmCore
import Foundation

enum MobileFileRecycleActionOperation: String, Codable, Sendable {
    case delete
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
    case recovery
    case failed
}

struct MobileFileRecycleActionPresentation: Equatable, Sendable {
    let profileID: UUID
    let operation: MobileFileRecycleActionOperation
    let source: FileItem
    let sourceParentPath: String
    let destinationPath: String
    let recycleLocation: FileRecycleLocation?
    var itemStates: [MobileFileRecycleItemState] = []
    var currentItemIndex: Int?
    var isBatch: Bool { itemStates.count > 1 }
    var currentSource: FileItem { currentItemIndex.flatMap { itemStates.indices.contains($0) ? itemStates[$0].source : nil } ?? source }
    func count(_ status: MobileFileRecycleItemStatus) -> Int { itemStates.count { $0.status == status } }
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

enum MobileFileRecycleItemStatus: Equatable, Sendable {
    case notStarted, submitting, confirmed, failed, pendingReview, cancelled
}

struct MobileFileRecycleItemState: Equatable, Sendable {
    let source: FileItem
    let destinationPath: String
    var status: MobileFileRecycleItemStatus = .notStarted
    var feedback: MobileFileRecycleActionFeedback?
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

struct MobileFileRecycleActionReviewKey: Hashable, Codable, Sendable {
    let profileID: UUID
    let context: String
    let operation: MobileFileRecycleActionOperation
    let sourcePath: String
    let destinationPath: String
}

/// 提交前保存原目标，进程退出、断线或换账号均不能解除未知操作的限制。
@MainActor
final class MobileFileRecycleActionReviewBlocker {
    static let shared = MobileFileRecycleActionReviewBlocker()
    private struct Recovery: Codable { let version: Int; let keys: Set<MobileFileRecycleActionReviewKey> }
    private var keys: Set<MobileFileRecycleActionReviewKey> = []
    private let root: URL?
    private(set) var recoveryFailed = false

    init(rootURL: URL? = nil) {
        root = rootURL
        guard let file = root?.appendingPathComponent("pending-v1.json"),
              FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let value = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: file))
            guard value.version == 1, value.keys.allSatisfy({ !$0.context.isEmpty && $0.sourcePath.hasPrefix("/") && ($0.operation == .delete || $0.destinationPath.hasPrefix("/")) }) else {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
            keys = value.keys
        } catch { recoveryFailed = true }
    }

    func contains(_ key: MobileFileRecycleActionReviewKey) -> Bool {
        keys.contains { old in
            guard old.profileID == key.profileID, old.context == key.context else { return false }
            // 同一源或其子树不能改换目标重试，目标也不能与未结束输出重叠。
            let oldPaths = [old.sourcePath, old.destinationPath].filter { !$0.isEmpty }
            let newPaths = [key.sourcePath, key.destinationPath].filter { !$0.isEmpty }
            return oldPaths.contains { left in newPaths.contains { right in
                left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
            } }
        }
    }

    @discardableResult func insert(_ key: MobileFileRecycleActionReviewKey) -> Bool {
        keys.insert(key)
        return persist()
    }
    func remove(_ key: MobileFileRecycleActionReviewKey) {
        let old = keys; keys.remove(key)
        if !persist() { keys = old }
    }
    func purge(profileID: UUID) {
        let old = keys; keys = keys.filter { $0.profileID != profileID }
        if !persist() { keys = old }
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

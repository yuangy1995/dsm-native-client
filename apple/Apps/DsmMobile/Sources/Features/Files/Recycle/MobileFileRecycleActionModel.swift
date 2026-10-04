import DsmCore
import DsmNetwork
import Foundation
import Observation

protocol MobileFileRecycleMutating: AnyObject, Sendable {
    var profileID: UUID { get }
    func getInfo(paths: [String]) async throws -> [FileItem]
    func deleteResult(paths: [String], progress: @escaping FileTransferProgress) async throws -> MutationResult
    func moveToRecycleResult(
        _ request: FileMoveToRecycleRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileRecycleMutationOutcome
    func restoreFromRecycleResult(
        _ request: FileRestoreFromRecycleRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileRecycleMutationOutcome
}

extension DsmFileRepository: MobileFileRecycleMutating {}

@MainActor
@Observable
final class MobileFileRecycleActionModel {
    private(set) var activeProfileID: UUID?
    private(set) var presentation: MobileFileRecycleActionPresentation?
    @ObservationIgnored private var repositoryIdentity: ObjectIdentifier?
    @ObservationIgnored private var requestTask: Task<FileRecycleMutationOutcome, Error>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var context = ""
    var activation: Int { generation }
    @ObservationIgnored private let blocker: MobileFileRecycleActionReviewBlocker

    init(blocker: MobileFileRecycleActionReviewBlocker = .shared) {
        self.blocker = blocker
    }

    var isPresented: Bool { presentation != nil }

    func activate(profileID: UUID?, repository: (any MobileFileRecycleMutating)?, context: String? = nil) {
        deactivate()
        guard let profileID,
              let repository,
              repository.profileID == profileID else { return }
        self.context = context ?? profileID.uuidString
        activeProfileID = profileID
        repositoryIdentity = ObjectIdentifier(repository)
    }

    func beginMoveToRecycle(
        item: FileItem,
        parentPath: String,
        source: MobileFileLocationSource,
        visibleItems: [FileItem],
        recycleLocations: [FileRecycleLocation],
        repository: any MobileFileRecycleMutating
    ) {
        guard isActive(repository), presentation?.phase != .submitting,
              let recycleLocation = Self.recycleLocation(
                  for: item.path,
                  in: recycleLocations
              ),
              let destinationPath = Self.moveDestinationPath(
                  itemPath: item.path,
                  recycleLocation: recycleLocation
              ),
              Self.canMoveToRecycle(
                  item: item,
                  parentPath: parentPath,
                  source: source,
                  visibleItems: visibleItems,
                  recycleLocations: recycleLocations,
                  profileID: repository.profileID
              ) else { return }
        generation &+= 1
        presentation = MobileFileRecycleActionPresentation(
            profileID: repository.profileID,
            operation: .moveToRecycle,
            source: item,
            sourceParentPath: parentPath,
            destinationPath: destinationPath,
            recycleLocation: recycleLocation,
            itemStates: [.init(source: item, destinationPath: destinationPath)],
            totalBytes: item.sizeBytes
        )
    }

    func beginRestoreFromRecycle(
        item: FileItem,
        parentPath: String,
        source: MobileFileLocationSource,
        visibleItems: [FileItem],
        repository: any MobileFileRecycleMutating
    ) {
        guard isActive(repository), presentation?.phase != .submitting,
              let destinationPath = Self.restoreDestinationPath(for: item.path),
              Self.canRestoreFromRecycle(
                  item: item,
                  parentPath: parentPath,
                  source: source,
                  visibleItems: visibleItems,
                  profileID: repository.profileID
              ) else { return }
        generation &+= 1
        presentation = MobileFileRecycleActionPresentation(
            profileID: repository.profileID,
            operation: .restoreFromRecycle,
            source: item,
            sourceParentPath: parentPath,
            destinationPath: destinationPath,
            recycleLocation: nil,
            itemStates: [.init(source: item, destinationPath: destinationPath)],
            totalBytes: item.sizeBytes
        )
    }

    /// 单项和批量共用冻结快照；同一目录最多 20 项，禁止删除共享根与回收站容器。
    func begin(
        operation: MobileFileRecycleActionOperation, items: [FileItem], parentPath: String,
        source: MobileFileLocationSource, visibleItems: [FileItem], readOnlyRoots: [String] = [],
        repository: any MobileFileRecycleMutating
    ) {
        guard isActive(repository), presentation?.phase != .submitting,
              operation != .moveToRecycle, let first = items.first, items.count <= 20,
              Set(items.map(\.path)).count == items.count,
              items.allSatisfy({ item in
                  operation == .delete
                    ? Self.canDelete(item: item, parentPath: parentPath, source: source,
                        visibleItems: visibleItems, readOnlyRoots: readOnlyRoots, profileID: repository.profileID)
                    : Self.canRestoreFromRecycle(item: item, parentPath: parentPath, source: source,
                        visibleItems: visibleItems, profileID: repository.profileID)
              }) else { return }
        generation &+= 1
        let states = items.map { MobileFileRecycleItemState(source: $0,
            destinationPath: operation == .delete ? "" : Self.restoreDestinationPath(for: $0.path)!) }
        presentation = .init(profileID: repository.profileID, operation: operation, source: first,
            sourceParentPath: parentPath, destinationPath: states[0].destinationPath,
            recycleLocation: nil, itemStates: states)
    }

    func removeProfile(_ profileID: UUID) { blocker.purge(profileID: profileID) }

    func submit(repository: any MobileFileRecycleMutating, expectedActivation: Int? = nil) async -> MobileFileRecycleActionSuccess? {
        guard var snapshot = presentation, snapshot.phase == .confirming,
              expectedActivation.map({ $0 == generation }) ?? true,
              isActive(repository), snapshot.profileID == repository.profileID else { return nil }
        let requestGeneration = generation, identity = ObjectIdentifier(repository), requestContext = context
        snapshot.phase = .submitting
        snapshot.feedback = nil
        snapshot.cancellationRequested = false
        presentation = snapshot
        var firstSuccess: MobileFileRecycleActionSuccess?
        for index in snapshot.itemStates.indices {
            guard isCurrent(snapshot.profileID, identity, requestGeneration),
                  presentation?.cancellationRequested != true else { break }
            let entry = snapshot.itemStates[index]
            let key = MobileFileRecycleActionReviewKey(profileID: snapshot.profileID, context: requestContext,
                operation: snapshot.operation, sourcePath: entry.source.path, destinationPath: entry.destinationPath)
            if blocker.recoveryFailed || blocker.contains(key) || !blocker.insert(key) {
                presentation?.itemStates[index].status = .pendingReview
                presentation?.feedback = blocker.recoveryFailed ? .recovery : nil
                presentation?.phase = .review
                break
            }
            presentation?.currentItemIndex = index
            presentation?.itemStates[index].status = .submitting
            presentation?.completedBytes = 0
            presentation?.totalBytes = entry.source.sizeBytes
            let operation = snapshot.operation, profileID = snapshot.profileID, location = snapshot.recycleLocation
            let progress: FileTransferProgress = { [weak self] completed, total in
                Task { @MainActor [weak self] in
                    self?.applyProgress(completed: completed, total: total, profileID: profileID,
                        identity: identity, generation: requestGeneration, itemIndex: index)
                }
            }
            let task = Task {
                switch operation {
                case .delete:
                    return try await Self.delete(entry.source, repository: repository, progress: progress)
                case .moveToRecycle:
                    guard let location else { throw MobileFileRecycleActionInternalError.missingRecycleLocation }
                    return try await repository.moveToRecycleResult(.init(profileID: profileID,
                        item: entry.source, recycleLocation: location), progress: progress)
                case .restoreFromRecycle:
                    return try await repository.restoreFromRecycleResult(.init(profileID: profileID,
                        item: entry.source), progress: progress)
                }
            }
            requestTask = task
            do {
                let outcome = try await task.value
                let status = Self.classify(outcome, operation: snapshot.operation, entry: entry)
                // 迟到的明确结果只解除其原始记录，不写回新账号或新弹窗。
                if status != .pendingReview { blocker.remove(key) }
                guard isCurrent(snapshot.profileID, identity, requestGeneration) else { return nil }
                requestTask = nil
                presentation?.itemStates[index].status = status
                if status == .confirmed {
                    firstSuccess = firstSuccess ?? .init(profileID: snapshot.profileID, operation: snapshot.operation,
                        sourceParentPath: snapshot.sourceParentPath,
                        destinationParentPath: Self.parentPath(of: entry.destinationPath) ?? "",
                        sourcePath: entry.source.path, destinationPath: entry.destinationPath,
                        item: outcome.item ?? entry.source)
                } else if status == .failed {
                    let feedback: MobileFileRecycleActionFeedback = outcome.result.errorCategory == .permission || outcome.result.status == .permissionDenied
                        ? .permission : (outcome.result.status == .unsupported ? .unsupported :
                            (outcome.result.errorCategory == .conflict || outcome.result.errorCategory == .validation ? .conflict : .failed))
                    presentation?.itemStates[index].feedback = feedback
                    presentation?.feedback = feedback
                } else if status == .pendingReview {
                    presentation?.phase = .review
                    break
                } else if status == .cancelled {
                    break
                }
            } catch {
                guard isCurrent(snapshot.profileID, identity, requestGeneration) else { return nil }
                requestTask = nil
                presentation?.itemStates[index].status = .pendingReview
                presentation?.phase = .review
                break
            }
        }
        guard isCurrent(snapshot.profileID, identity, requestGeneration) else { return nil }
        if presentation?.phase != .review {
            if !snapshot.isBatch, firstSuccess != nil { presentation = nil }
            else if !snapshot.isBatch, presentation?.itemStates.first?.status == .cancelled {
                presentation?.phase = .confirming
                presentation?.cancellationRequested = false
            } else { presentation?.phase = .result }
        }
        return firstSuccess
    }

    /// 删除前重新读取原对象和明确的删除权限，不能用旧列表删除已被替换的项目。
    private static func delete(_ source: FileItem, repository: any MobileFileRecycleMutating,
                               progress: @escaping FileTransferProgress) async throws -> FileRecycleMutationOutcome {
        func preflightResult(_ status: MutationResultStatus, _ category: MutationErrorCategory? = nil) throws -> FileRecycleMutationOutcome {
            .init(result: try MutationResult(status: status, operation: "fileDelete", submitted: false,
                requiresRefresh: false, counts: .init(succeeded: 0, failed: status == .cancelledBeforeSubmission ? 0 : 1, unknown: 0),
                errorCategory: category), sourcePath: source.path, destinationPath: "", item: nil)
        }
        do {
            try Task.checkCancellation()
            let values = try await repository.getInfo(paths: [source.path])
            try Task.checkCancellation()
            guard values.count == 1, let observed = values.first,
                  observed.profileID == source.profileID, observed.path == source.path,
                  observed.name == source.name, observed.kind == source.kind,
                  isConfirmedItemIdentity(observed, source: source),
                  observed.times?.modifiedAt == source.times?.modifiedAt, !isRemote(observed) else {
                return try preflightResult(.confirmedFailure, .conflict)
            }
            guard observed.permissions?.canDelete == true else { return try preflightResult(.permissionDenied, .permission) }
        } catch is CancellationError { return try preflightResult(.cancelledBeforeSubmission) }
        catch { return try preflightResult(.confirmedFailure, .network) }
        let result = try await repository.deleteResult(paths: [source.path], progress: progress)
        return .init(result: result, sourcePath: source.path, destinationPath: "", item: nil)
    }

    private static func classify(_ outcome: FileRecycleMutationOutcome, operation: MobileFileRecycleActionOperation,
                                 entry: MobileFileRecycleItemState) -> MobileFileRecycleItemStatus {
        let result = outcome.result
        guard result.operation == (operation == .delete ? "fileDelete" : operation.rawValue),
              outcome.sourcePath == entry.source.path, outcome.destinationPath == entry.destinationPath else { return .pendingReview }
        switch result.status {
        case .confirmedSuccess:
            guard result.submitted, result.counts.succeeded == 1, result.counts.failed == 0,
                  result.counts.unknown == 0 else { return .pendingReview }
            if operation == .delete { return outcome.item == nil ? .confirmed : .pendingReview }
            guard let item = outcome.item, item.profileID == entry.source.profileID,
                  item.path == entry.destinationPath, item.name == entry.source.name,
                  item.kind == entry.source.kind, isConfirmedItemIdentity(item, source: entry.source),
                  item.isRecyclePath == (operation == .moveToRecycle), !isRemote(item) else { return .pendingReview }
            return .confirmed
        case .cancelledBeforeSubmission: return .cancelled
        case .permissionDenied, .unsupported, .confirmedFailure:
            return result.counts.unknown == 0 && result.counts.succeeded == 0 ? .failed : .pendingReview
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess: return .pendingReview
        }
    }

    func requestCancellation() {
        guard var current = presentation,
              current.phase == .submitting,
              !current.cancellationRequested else { return }
        current.cancellationRequested = true
        presentation = current
        requestTask?.cancel()
    }

    func dismiss() {
        guard presentation?.phase != .submitting else { return }
        generation &+= 1
        requestTask?.cancel()
        requestTask = nil
        presentation = nil
    }

    func deactivate() {
        generation &+= 1
        requestTask?.cancel()
        requestTask = nil
        presentation = nil
        activeProfileID = nil
        repositoryIdentity = nil
    }

    static func canDelete(item: FileItem, parentPath: String, source: MobileFileLocationSource,
                          visibleItems: [FileItem], readOnlyRoots: [String] = [], profileID: UUID) -> Bool {
        (!source.isReadOnlyLocation || source == .recycle) && item.profileID == profileID &&
            isSupportedRecycleItem(item) && visibleItems.contains(item) &&
            isCanonicalAbsolutePath(parentPath) && isCanonicalAbsolutePath(item.path) &&
            Self.parentPath(of: item.path) == parentPath &&
            item.name == item.path.split(separator: "/").last.map(String.init) &&
            item.name.lowercased() != "#recycle" && !isRemote(item) &&
            !readOnlyRoots.contains { item.path == $0 || item.path.hasPrefix($0 + "/") }
    }

    static func canMoveToRecycle(
        item: FileItem,
        parentPath: String,
        source: MobileFileLocationSource,
        visibleItems: [FileItem],
        recycleLocations: [FileRecycleLocation],
        profileID: UUID
    ) -> Bool {
        !source.isReadOnlyLocation &&
            item.profileID == profileID &&
            isSupportedRecycleItem(item) &&
            visibleItems.contains(item) &&
            isCanonicalAbsolutePath(parentPath) &&
            isCanonicalAbsolutePath(item.path) &&
            Self.parentPath(of: item.path) == parentPath &&
            !item.isRecyclePath &&
            !isRemote(item) &&
            recycleLocation(for: item.path, in: recycleLocations) != nil
    }

    static func canRestoreFromRecycle(
        item: FileItem,
        parentPath: String,
        source: MobileFileLocationSource,
        visibleItems: [FileItem],
        profileID: UUID
    ) -> Bool {
        source == .recycle &&
            item.profileID == profileID &&
            isSupportedRecycleItem(item) &&
            visibleItems.contains(item) &&
            isCanonicalAbsolutePath(parentPath) &&
            isCanonicalAbsolutePath(item.path) &&
            Self.parentPath(of: item.path) == parentPath &&
            item.isRecyclePath &&
            !isRemote(item) &&
            restoreDestinationPath(for: item.path) != nil
    }

    private func applyProgress(
        completed: Int64,
        total: Int64?,
        profileID: UUID,
        identity: ObjectIdentifier,
        generation requestGeneration: Int,
        itemIndex: Int
    ) {
        guard completed >= 0,
              isCurrent(profileID, identity, requestGeneration),
              var current = presentation,
              current.phase == .submitting, current.currentItemIndex == itemIndex else { return }
        if let total, total >= 0, completed <= total { current.totalBytes = total }
        guard current.totalBytes.map({ completed <= $0 }) ?? true,
              completed >= current.completedBytes else { return }
        current.completedBytes = completed
        presentation = current
    }

    private func isActive(_ repository: any MobileFileRecycleMutating) -> Bool {
        activeProfileID == repository.profileID &&
            repositoryIdentity == ObjectIdentifier(repository)
    }

    private func isCurrent(
        _ profileID: UUID,
        _ identity: ObjectIdentifier,
        _ requestGeneration: Int
    ) -> Bool {
        activeProfileID == profileID &&
            repositoryIdentity == identity &&
            generation == requestGeneration
    }

    static func moveDestinationPath(
        itemPath: String,
        recycleLocation: FileRecycleLocation
    ) -> String? {
        guard isCanonicalAbsolutePath(itemPath),
              isCanonicalAbsolutePath(recycleLocation.sharePath),
              isCanonicalAbsolutePath(recycleLocation.recyclePath),
              recycleLocation.recyclePath == recycleLocation.sharePath + "/#recycle",
              itemPath.hasPrefix(recycleLocation.sharePath + "/") else { return nil }
        let suffix = String(itemPath.dropFirst(recycleLocation.sharePath.count))
        let destination = recycleLocation.recyclePath + suffix
        return isCanonicalAbsolutePath(destination) &&
            destination.hasPrefix(recycleLocation.recyclePath + "/")
            ? destination
            : nil
    }

    static func restoreDestinationPath(for recyclePath: String) -> String? {
        guard isCanonicalAbsolutePath(recyclePath) else { return nil }
        let parts = recyclePath.split(separator: "/")
        guard parts.count >= 3,
              parts[1].lowercased() == "#recycle" else { return nil }
        let restored = "/" + ([parts[0]] + parts.dropFirst(2)).joined(separator: "/")
        return isCanonicalAbsolutePath(restored) &&
            !containsRecycleSegment(restored)
            ? restored
            : nil
    }

    static func recycleLocation(
        for itemPath: String,
        in locations: [FileRecycleLocation]
    ) -> FileRecycleLocation? {
        locations.first { location in
            moveDestinationPath(itemPath: itemPath, recycleLocation: location) != nil
        }
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path != "/",
              !path.hasSuffix("/"),
              !path.contains("//"),
              !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func parentPath(of path: String) -> String? {
        let components = path.split(separator: "/")
        guard components.count >= 2 else { return nil }
        return "/" + components.dropLast().joined(separator: "/")
    }

    private static func containsRecycleSegment(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.lowercased() == "#recycle" }
    }

    private static func isRemote(_ item: FileItem) -> Bool {
        guard let type = item.mountPointType?.lowercased(), !type.isEmpty else { return false }
        return type != "normal" && type != "shared_folder"
    }

    private static func isSupportedRecycleItem(_ item: FileItem) -> Bool {
        switch item.kind {
        case .file:
            return item.sizeBytes.map { $0 >= 0 } == true
        case .directory:
            return true
        default:
            return false
        }
    }

    private static func isConfirmedItemIdentity(_ item: FileItem, source: FileItem) -> Bool {
        switch source.kind {
        case .file:
            return item.sizeBytes == source.sizeBytes
        case .directory:
            return true
        default:
            return false
        }
    }
}

private enum MobileFileRecycleActionInternalError: Error {
    case missingRecycleLocation
}

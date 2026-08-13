import DsmCore
import DsmNetwork
import Foundation
import Observation

protocol MobileFileRecycleMutating: AnyObject, Sendable {
    var profileID: UUID { get }
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
    @ObservationIgnored private let blocker: MobileFileRecycleActionReviewBlocker

    init(blocker: MobileFileRecycleActionReviewBlocker = .shared) {
        self.blocker = blocker
    }

    var isPresented: Bool { presentation != nil }

    func activate(profileID: UUID?, repository: (any MobileFileRecycleMutating)?) {
        deactivate()
        guard let profileID,
              let repository,
              repository.profileID == profileID else { return }
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
        guard isActive(repository),
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
        guard isActive(repository),
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
            totalBytes: item.sizeBytes
        )
    }

    func submit(repository: any MobileFileRecycleMutating) async -> MobileFileRecycleActionSuccess? {
        guard var snapshot = presentation,
              snapshot.phase == .confirming,
              isActive(repository),
              snapshot.profileID == repository.profileID else { return nil }
        let reviewKey = MobileFileRecycleActionReviewKey(
            profileID: snapshot.profileID,
            operation: snapshot.operation,
            sourcePath: snapshot.source.path,
            destinationPath: snapshot.destinationPath
        )
        guard !blocker.contains(reviewKey) else {
            enterReview(snapshot)
            return nil
        }

        snapshot.phase = .submitting
        snapshot.feedback = nil
        snapshot.completedBytes = 0
        snapshot.totalBytes = snapshot.source.sizeBytes
        presentation = snapshot
        let requestGeneration = generation
        let identity = ObjectIdentifier(repository)
        let progressProfileID = snapshot.profileID
        let task = Task {
            switch snapshot.operation {
            case .moveToRecycle:
                guard let recycleLocation = snapshot.recycleLocation else {
                    throw MobileFileRecycleActionInternalError.missingRecycleLocation
                }
                return try await repository.moveToRecycleResult(
                    FileMoveToRecycleRequest(
                        profileID: snapshot.profileID,
                        item: snapshot.source,
                        recycleLocation: recycleLocation
                    )
                ) { [weak self] completed, total in
                    Task { @MainActor [weak self] in
                        self?.applyProgress(
                            completed: completed,
                            total: total,
                            profileID: progressProfileID,
                            identity: identity,
                            generation: requestGeneration
                        )
                    }
                }
            case .restoreFromRecycle:
                return try await repository.restoreFromRecycleResult(
                    FileRestoreFromRecycleRequest(
                        profileID: snapshot.profileID,
                        item: snapshot.source
                    )
                ) { [weak self] completed, total in
                    Task { @MainActor [weak self] in
                        self?.applyProgress(
                            completed: completed,
                            total: total,
                            profileID: progressProfileID,
                            identity: identity,
                            generation: requestGeneration
                        )
                    }
                }
            }
        }
        requestTask = task

        do {
            let outcome = try await task.value
            guard isCurrent(snapshot.profileID, identity, requestGeneration) else { return nil }
            requestTask = nil
            return handle(outcome, snapshot: snapshot, reviewKey: reviewKey)
        } catch {
            guard isCurrent(snapshot.profileID, identity, requestGeneration) else { return nil }
            requestTask = nil
            blocker.insert(reviewKey)
            enterReview(snapshot)
            return nil
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

    private func handle(
        _ outcome: FileRecycleMutationOutcome,
        snapshot: MobileFileRecycleActionPresentation,
        reviewKey: MobileFileRecycleActionReviewKey
    ) -> MobileFileRecycleActionSuccess? {
        switch outcome.result.status {
        case .confirmedSuccess:
            guard let item = outcome.item,
                  outcome.sourcePath == snapshot.source.path,
                  outcome.destinationPath == snapshot.destinationPath,
                  item.profileID == snapshot.profileID,
                  item.path == snapshot.destinationPath,
                  item.name == snapshot.source.name,
                  item.kind == snapshot.source.kind,
                  Self.isConfirmedItemIdentity(item, source: snapshot.source),
                  isConfirmedDestination(item, for: snapshot.operation) else {
                blocker.insert(reviewKey)
                enterReview(snapshot)
                return nil
            }
            presentation = nil
            return MobileFileRecycleActionSuccess(
                profileID: snapshot.profileID,
                operation: snapshot.operation,
                sourceParentPath: snapshot.sourceParentPath,
                destinationParentPath: Self.parentPath(of: snapshot.destinationPath) ?? "",
                sourcePath: snapshot.source.path,
                destinationPath: snapshot.destinationPath,
                item: item
            )
        case .cancelledBeforeSubmission:
            var confirming = snapshot
            confirming.phase = .confirming
            confirming.feedback = nil
            confirming.cancellationRequested = false
            presentation = confirming
        case .permissionDenied:
            enterResult(snapshot, feedback: .permission)
        case .unsupported:
            enterResult(snapshot, feedback: .unsupported)
        case .confirmedFailure:
            enterResult(
                snapshot,
                feedback: outcome.result.errorCategory == .permission ? .permission : .conflict
            )
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
            blocker.insert(reviewKey)
            enterReview(snapshot)
        }
        return nil
    }

    private func applyProgress(
        completed: Int64,
        total: Int64?,
        profileID: UUID,
        identity: ObjectIdentifier,
        generation requestGeneration: Int
    ) {
        guard completed >= 0,
              isCurrent(profileID, identity, requestGeneration),
              var current = presentation,
              current.phase == .submitting else { return }
        if let total, total >= 0, completed <= total { current.totalBytes = total }
        guard current.totalBytes.map({ completed <= $0 }) ?? true,
              completed >= current.completedBytes else { return }
        current.completedBytes = completed
        presentation = current
    }

    private func enterResult(
        _ snapshot: MobileFileRecycleActionPresentation,
        feedback: MobileFileRecycleActionFeedback
    ) {
        var result = snapshot
        result.phase = .result
        result.feedback = feedback
        result.cancellationRequested = false
        presentation = result
    }

    private func enterReview(_ snapshot: MobileFileRecycleActionPresentation) {
        var review = snapshot
        review.phase = .review
        review.feedback = nil
        presentation = review
    }

    private func isConfirmedDestination(
        _ item: FileItem,
        for operation: MobileFileRecycleActionOperation
    ) -> Bool {
        switch operation {
        case .moveToRecycle:
            item.isRecyclePath && !Self.isRemote(item)
        case .restoreFromRecycle:
            !item.isRecyclePath && !Self.isRemote(item)
        }
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

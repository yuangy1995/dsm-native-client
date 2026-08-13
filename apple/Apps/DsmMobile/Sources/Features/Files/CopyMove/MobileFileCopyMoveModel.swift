import DsmCore
import DsmNetwork
import Foundation
import Observation

protocol MobileFileCopyMoving: AnyObject, Sendable {
    var profileID: UUID { get }
    func listShares(offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage
    func listFolder(path: String, offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage
    func copyMoveResult(
        _ request: FileCopyMoveRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileCopyMoveOutcome
}

extension DsmFileRepository: MobileFileCopyMoving {}

@MainActor
@Observable
final class MobileFileCopyMoveModel {
    static let pageSize = 200
    static let maximumBatchCount = 20
    private(set) var activeProfileID: UUID?
    private(set) var presentation: MobileFileCopyMovePresentation?
    @ObservationIgnored private var repositoryIdentity: ObjectIdentifier?
    @ObservationIgnored private var requestTask: Task<FileCopyMoveOutcome, Error>?
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let blocker: MobileFileCopyMoveReviewBlocker

    init(blocker: MobileFileCopyMoveReviewBlocker = .shared) {
        self.blocker = blocker
    }

    var isPresented: Bool { presentation != nil }

    func activate(profileID: UUID?, repository: (any MobileFileCopyMoving)?) {
        deactivate()
        guard let profileID, let repository, repository.profileID == profileID else { return }
        activeProfileID = profileID
        repositoryIdentity = ObjectIdentifier(repository)
    }

    func begin(
        operation: FileCopyMoveOperation,
        item: FileItem,
        parentPath: String,
        source: MobileFileLocationSource,
        visibleItems: [FileItem],
        readOnlyRoots: [String],
        repository: any MobileFileCopyMoving
    ) {
        guard let frozenItem = Self.validatedItem(
            item,
            parentPath: parentPath,
            source: source,
            visibleItems: visibleItems,
            readOnlyRoots: readOnlyRoots,
            profileID: repository.profileID
        ) else { return }
        present(
            operation: operation,
            items: [frozenItem],
            parentPath: parentPath,
            readOnlyRoots: readOnlyRoots,
            repository: repository
        )
    }

    func begin(
        operation: FileCopyMoveOperation,
        items: [FileItem],
        parentPath: String,
        source: MobileFileLocationSource,
        visibleItems: [FileItem],
        readOnlyRoots: [String],
        repository: any MobileFileCopyMoving
    ) {
        let frozenItems = Self.validatedBatch(
            items: items,
            parentPath: parentPath,
            source: source,
            visibleItems: visibleItems,
            readOnlyRoots: readOnlyRoots,
            profileID: repository.profileID
        )
        guard !frozenItems.isEmpty else { return }
        present(
            operation: operation,
            items: frozenItems,
            parentPath: parentPath,
            readOnlyRoots: readOnlyRoots,
            repository: repository
        )
    }

    private func present(
        operation: FileCopyMoveOperation,
        items: [FileItem],
        parentPath: String,
        readOnlyRoots: [String],
        repository: any MobileFileCopyMoving
    ) {
        guard isActive(repository),
              requestTask == nil,
              presentation?.phase != .submitting,
              let first = items.first else { return }
        generation &+= 1
        presentation = MobileFileCopyMovePresentation(
            profileID: repository.profileID,
            operation: operation,
            source: first,
            sources: items,
            sourceParentPath: parentPath,
            readOnlyRoots: readOnlyRoots
        )
        loadInitial(repository: repository)
    }

    func retry(repository: any MobileFileCopyMoving) {
        guard presentation?.phase == .browsing else { return }
        loadInitial(repository: repository)
    }

    func openFolder(_ folder: FileItem, repository: any MobileFileCopyMoving) {
        guard let snapshot = presentation,
              snapshot.phase == .browsing,
              isActive(repository),
              snapshot.destination.folders.contains(folder),
              Self.isAllowedFolder(
                folder,
                profileID: snapshot.profileID,
                readOnlyRoots: snapshot.readOnlyRoots
              ) else { return }
        loadDestination(
            path: folder.path,
            history: snapshot.destination.history + [snapshot.destination.path],
            baseline: snapshot.destination,
            repository: repository
        )
    }

    func goBack(repository: any MobileFileCopyMoving) {
        guard let snapshot = presentation,
              snapshot.phase == .browsing,
              let path = snapshot.destination.history.last else { return }
        loadDestination(
            path: path,
            history: Array(snapshot.destination.history.dropLast()),
            baseline: snapshot.destination,
            repository: repository
        )
    }

    func goUp(repository: any MobileFileCopyMoving) {
        guard let snapshot = presentation,
              snapshot.phase == .browsing,
              !snapshot.destination.path.isEmpty else { return }
        let parent = Self.parentPath(of: snapshot.destination.path) ?? ""
        loadDestination(
            path: parent,
            history: snapshot.destination.history,
            baseline: snapshot.destination,
            repository: repository
        )
    }

    func loadMore(repository: any MobileFileCopyMoving) {
        guard var snapshot = presentation,
              snapshot.phase == .browsing,
              snapshot.destination.hasMore,
              !snapshot.destination.isLoadingMore,
              isActive(repository) else { return }
        let profileID = snapshot.profileID
        let identity = ObjectIdentifier(repository)
        let requestGeneration = generation
        let path = snapshot.destination.path
        let offset = snapshot.destination.nextOffset
        snapshot.destination.isLoadingMore = true
        snapshot.destination.loadMoreFailed = false
        presentation = snapshot
        browseTask?.cancel()
        browseTask = Task { [weak self] in
            do {
                let page = try await Self.fetch(repository, path: path, offset: offset)
                guard let self, self.isCurrent(profileID, identity, requestGeneration),
                      var current = self.presentation,
                      current.destination.path == path,
                      page.offset == offset else { return }
                guard page.folderPath == path else { throw MobileFileCopyMoveError.wrongFolder }
                let added = Self.allowedFolders(
                    page.items,
                    profileID: profileID,
                    readOnlyRoots: current.readOnlyRoots,
                    sources: current.sources
                )
                guard !page.hasMore || !added.isEmpty else { throw MobileFileCopyMoveError.zeroProgress }
                var paths = Set(current.destination.folders.map(\.path))
                current.destination.folders.append(contentsOf: added.filter { paths.insert($0.path).inserted })
                current.destination.nextOffset = page.offset + page.items.count
                current.destination.hasMore = page.hasMore
                current.destination.isLoadingMore = false
                self.presentation = current
            } catch is CancellationError {
            } catch {
                guard let self, self.isCurrent(profileID, identity, requestGeneration),
                      var current = self.presentation else { return }
                current.destination.isLoadingMore = false
                current.destination.loadMoreFailed = true
                self.presentation = current
            }
        }
    }

    func submit(repository: any MobileFileCopyMoving) async -> MobileFileCopyMoveSuccess? {
        guard var snapshot = presentation,
              snapshot.phase == .browsing,
              isActive(repository),
              snapshot.profileID == repository.profileID else { return nil }
        guard Self.isCanonicalAbsolutePath(snapshot.destination.path),
              !Self.isReadOnlyPath(snapshot.destination.path, roots: snapshot.readOnlyRoots),
              snapshot.canSubmitDestination else {
            setFeedback(.invalidDestination)
            return nil
        }
        for (index, item) in snapshot.sources.enumerated() {
            let key = reviewKey(for: item, snapshot: snapshot)
            guard !blocker.contains(key) else {
                snapshot.itemStates[index].status = .pendingReview
                snapshot.currentItemIndex = index
                enterReview(snapshot)
                return nil
            }
        }

        snapshot.phase = .submitting
        snapshot.feedback = nil
        snapshot.currentItemIndex = 0
        snapshot.itemStates[0].status = .submitting
        snapshot.completedBytes = 0
        snapshot.totalBytes = snapshot.sources[0].sizeBytes
        presentation = snapshot
        let requestGeneration = generation
        let identity = ObjectIdentifier(repository)
        let progressProfileID = snapshot.profileID
        var confirmedItems: [FileItem] = []

        for index in snapshot.sources.indices {
            guard isCurrent(snapshot.profileID, identity, requestGeneration) else { return nil }
            let source = snapshot.sources[index]
            snapshot.currentItemIndex = index
            snapshot.itemStates[index].status = .submitting
            snapshot.completedBytes = 0
            snapshot.totalBytes = source.sizeBytes
            snapshot.cancellationRequested = false
            presentation = snapshot
            let key = reviewKey(for: source, snapshot: snapshot)
            let request = FileCopyMoveRequest(
                profileID: snapshot.profileID,
                operation: snapshot.operation,
                source: source,
                destinationFolderPath: snapshot.destination.path,
                overwrite: false
            )
            let task = Task {
                try await repository.copyMoveResult(request) { [weak self] completed, total in
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
            requestTask = task
            do {
                let outcome = try await task.value
                guard isCurrent(snapshot.profileID, identity, requestGeneration) else { return nil }
                requestTask = nil
                switch classify(outcome, source: source, snapshot: snapshot) {
                case .confirmed(let item):
                    snapshot.itemStates[index].status = .confirmed
                    snapshot.itemStates[index].confirmedItem = item
                    confirmedItems.append(item)
                case .failed(let feedback):
                    snapshot.itemStates[index].status = .failed
                    snapshot.itemStates[index].feedback = feedback
                    snapshot.feedback = feedback
                case .cancelled:
                    snapshot.itemStates[index].status = .cancelled
                    snapshot.cancellationRequested = false
                    snapshot.phase = snapshot.isBatch ? .completed : .browsing
                    presentation = snapshot
                    return successSummary(for: snapshot, confirmedItems: confirmedItems)
                case .pendingReview:
                    snapshot.itemStates[index].status = .pendingReview
                    blocker.insert(key)
                    enterReview(snapshot)
                    return successSummary(for: snapshot, confirmedItems: confirmedItems)
                }
            } catch {
                guard isCurrent(snapshot.profileID, identity, requestGeneration) else { return nil }
                requestTask = nil
                snapshot.itemStates[index].status = .pendingReview
                blocker.insert(key)
                enterReview(snapshot)
                return successSummary(for: snapshot, confirmedItems: confirmedItems)
            }
        }

        snapshot.currentItemIndex = nil
        snapshot.cancellationRequested = false
        if snapshot.isBatch {
            snapshot.phase = .completed
            presentation = snapshot
            return successSummary(for: snapshot, confirmedItems: confirmedItems)
        }
        guard let item = confirmedItems.first else {
            snapshot.phase = .browsing
            presentation = snapshot
            return nil
        }
        presentation = nil
        return MobileFileCopyMoveSuccess(
            profileID: snapshot.profileID,
            operation: snapshot.operation,
            sourceParentPath: snapshot.sourceParentPath,
            destinationFolderPath: snapshot.destination.path,
            item: item
        )
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
        browseTask?.cancel()
        requestTask?.cancel()
        browseTask = nil
        requestTask = nil
        presentation = nil
    }

    func deactivate() {
        generation &+= 1
        browseTask?.cancel()
        requestTask?.cancel()
        browseTask = nil
        requestTask = nil
        presentation = nil
        activeProfileID = nil
        repositoryIdentity = nil
    }

    static func canBegin(
        item: FileItem,
        parentPath: String,
        source: MobileFileLocationSource,
        visibleItems: [FileItem],
        readOnlyRoots: [String],
        profileID: UUID
    ) -> Bool {
        canUseItem(
            item,
            parentPath: parentPath,
            source: source,
            visibleItems: visibleItems,
            readOnlyRoots: readOnlyRoots,
            profileID: profileID,
            allowDirectory: true
        )
    }

    static func canBeginBatchItem(
        item: FileItem,
        parentPath: String,
        source: MobileFileLocationSource,
        visibleItems: [FileItem],
        readOnlyRoots: [String],
        profileID: UUID
    ) -> Bool {
        canUseItem(
            item,
            parentPath: parentPath,
            source: source,
            visibleItems: visibleItems,
            readOnlyRoots: readOnlyRoots,
            profileID: profileID,
            allowDirectory: false
        )
    }

    private static func canUseItem(
        _ item: FileItem,
        parentPath: String,
        source: MobileFileLocationSource,
        visibleItems: [FileItem],
        readOnlyRoots: [String],
        profileID: UUID,
        allowDirectory: Bool
    ) -> Bool {
        !source.isReadOnlyLocation &&
            item.profileID == profileID &&
            isSupportedSourceItem(item, allowDirectory: allowDirectory) &&
            visibleItems.contains(item) &&
            isCanonicalAbsolutePath(parentPath) &&
            Self.parentPath(of: item.path) == parentPath &&
            isCanonicalAbsolutePath(item.path) &&
            !item.isRecyclePath &&
            !isRemote(item) &&
            !isReadOnlyPath(item.path, roots: readOnlyRoots)
    }

    private static func validatedItem(
        _ item: FileItem,
        parentPath: String,
        source: MobileFileLocationSource,
        visibleItems: [FileItem],
        readOnlyRoots: [String],
        profileID: UUID
    ) -> FileItem? {
        canUseItem(
            item,
            parentPath: parentPath,
            source: source,
            visibleItems: visibleItems,
            readOnlyRoots: readOnlyRoots,
            profileID: profileID,
            allowDirectory: true
        ) ? item : nil
    }

    private static func validatedBatch(
        items: [FileItem],
        parentPath: String,
        source: MobileFileLocationSource,
        visibleItems: [FileItem],
        readOnlyRoots: [String],
        profileID: UUID
    ) -> [FileItem] {
        guard (1...maximumBatchCount).contains(items.count) else { return [] }
        var paths: Set<String> = []
        let frozen = items.filter { paths.insert($0.path).inserted }
        guard !frozen.isEmpty, frozen.count <= maximumBatchCount,
              frozen.allSatisfy({
                  canBeginBatchItem(
                      item: $0,
                      parentPath: parentPath,
                      source: source,
                      visibleItems: visibleItems,
                      readOnlyRoots: readOnlyRoots,
                      profileID: profileID
                  )
              }) else { return [] }
        return frozen
    }

    private func loadInitial(repository: any MobileFileCopyMoving) {
        guard let snapshot = presentation else { return }
        loadDestination(
            path: "",
            history: [],
            baseline: snapshot.destination,
            repository: repository
        )
    }

    private func loadDestination(
        path: String,
        history: [String],
        baseline: MobileFileCopyMoveDestinationState,
        repository: any MobileFileCopyMoving
    ) {
        guard var snapshot = presentation,
              snapshot.phase == .browsing,
              isActive(repository),
              path.isEmpty || Self.isCanonicalAbsolutePath(path),
              !Self.isReadOnlyPath(path, roots: snapshot.readOnlyRoots) else { return }
        let profileID = snapshot.profileID
        let identity = ObjectIdentifier(repository)
        generation &+= 1
        let requestGeneration = generation
        snapshot.phase = .loadingDestination
        snapshot.feedback = nil
        presentation = snapshot
        browseTask?.cancel()
        browseTask = Task { [weak self] in
            do {
                let page = try await Self.fetch(repository, path: path, offset: 0)
                guard let self, self.isCurrent(profileID, identity, requestGeneration),
                      var current = self.presentation,
                      page.offset == 0 else { return }
                guard page.folderPath == path else { throw MobileFileCopyMoveError.wrongFolder }
                let folders = Self.allowedFolders(
                    page.items,
                    profileID: profileID,
                    readOnlyRoots: current.readOnlyRoots,
                    sources: current.sources
                )
                current.destination = MobileFileCopyMoveDestinationState(
                    path: path,
                    history: history,
                    folders: folders,
                    nextOffset: page.items.count,
                    hasMore: page.hasMore,
                    pageState: folders.isEmpty ? .empty : .content
                )
                current.phase = .browsing
                self.presentation = current
            } catch is CancellationError {
            } catch {
                guard let self, self.isCurrent(profileID, identity, requestGeneration),
                      var current = self.presentation else { return }
                current.destination = baseline
                current.phase = .browsing
                if baseline.pageState == .content || baseline.pageState == .empty {
                    current.destination.hasRefreshError = true
                } else {
                    current.destination.pageState = .error
                }
                self.presentation = current
            }
        }
    }

    private enum ClassifiedOutcome {
        case confirmed(FileItem)
        case failed(MobileFileCopyMoveFeedback)
        case cancelled
        case pendingReview
    }

    private func classify(
        _ outcome: FileCopyMoveOutcome,
        source: FileItem,
        snapshot: MobileFileCopyMovePresentation
    ) -> ClassifiedOutcome {
        switch outcome.result.status {
        case .confirmedSuccess:
            let expectedPath = snapshot.destination.path + "/" + source.name
            guard outcome.result.operation == snapshot.operation.rawValue,
                  outcome.result.submitted,
                  !outcome.result.requiresRefresh,
                  outcome.result.counts.succeeded == 1,
                  outcome.result.counts.failed == 0,
                  outcome.result.counts.unknown == 0,
                  outcome.sourcePath == source.path,
                  outcome.destinationPath == expectedPath,
                  let item = outcome.item,
                  item.profileID == snapshot.profileID,
                  item.path == expectedPath,
                  item.name == source.name,
                  item.kind == source.kind,
                  Self.isConfirmedItem(item, source: source),
                  !item.isRecyclePath,
                  !Self.isRemote(item) else {
                return .pendingReview
            }
            return .confirmed(item)
        case .cancelledBeforeSubmission:
            return .cancelled
        case .permissionDenied:
            return .failed(.permission)
        case .unsupported:
            return .failed(.unsupported)
        case .confirmedFailure:
            switch outcome.result.errorCategory {
            case .permission:
                return .failed(.permission)
            case .conflict:
                return .failed(.conflict)
            default:
                return .failed(.failed)
            }
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
            return .pendingReview
        }
    }

    private func reviewKey(
        for source: FileItem,
        snapshot: MobileFileCopyMovePresentation
    ) -> MobileFileCopyMoveReviewKey {
        MobileFileCopyMoveReviewKey(
            profileID: snapshot.profileID,
            operation: snapshot.operation,
            sourcePath: source.path,
            destinationFolderPath: snapshot.destination.path
        )
    }

    private func successSummary(
        for snapshot: MobileFileCopyMovePresentation,
        confirmedItems: [FileItem]
    ) -> MobileFileCopyMoveSuccess? {
        guard let first = confirmedItems.first else { return nil }
        return MobileFileCopyMoveSuccess(
            profileID: snapshot.profileID,
            operation: snapshot.operation,
            sourceParentPath: snapshot.sourceParentPath,
            destinationFolderPath: snapshot.destination.path,
            item: first,
            confirmedItems: confirmedItems
        )
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

    private func setFeedback(_ feedback: MobileFileCopyMoveFeedback) {
        guard var current = presentation else { return }
        current.feedback = feedback
        presentation = current
    }

    private func enterReview(_ snapshot: MobileFileCopyMovePresentation) {
        var review = snapshot
        review.phase = .review
        review.feedback = nil
        presentation = review
    }

    private func isActive(_ repository: any MobileFileCopyMoving) -> Bool {
        activeProfileID == repository.profileID && repositoryIdentity == ObjectIdentifier(repository)
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

    private static func fetch(
        _ repository: any MobileFileCopyMoving,
        path: String,
        offset: Int
    ) async throws -> FilePage {
        let options = FileListOptions(typeFilter: path.isEmpty ? .all : .folders)
        return path.isEmpty
            ? try await repository.listShares(offset: offset, limit: pageSize, options: options)
            : try await repository.listFolder(path: path, offset: offset, limit: pageSize, options: options)
    }

    private static func allowedFolders(
        _ items: [FileItem],
        profileID: UUID,
        readOnlyRoots: [String],
        sources: [FileItem]
    ) -> [FileItem] {
        items.filter {
            isAllowedFolder($0, profileID: profileID, readOnlyRoots: readOnlyRoots) &&
                !isInvalidDestination($0.path, for: sources)
        }
    }

    private static func isAllowedFolder(
        _ item: FileItem,
        profileID: UUID,
        readOnlyRoots: [String]
    ) -> Bool {
        item.profileID == profileID && item.isDirectory && item.kind == .directory &&
            isCanonicalAbsolutePath(item.path) &&
            !item.isRecyclePath && !isRemote(item) &&
            !isReadOnlyPath(item.path, roots: readOnlyRoots)
    }

    private static func isReadOnlyPath(_ path: String, roots: [String]) -> Bool {
        containsRecycleSegment(path) || roots.contains { root in
            isCanonicalAbsolutePath(root) && (path == root || path.hasPrefix(root + "/"))
        }
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", !path.hasSuffix("/"),
              !path.contains("//"), !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func parentPath(of path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    private static func containsRecycleSegment(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.lowercased() == "#recycle" }
    }

    private static func isRemote(_ item: FileItem) -> Bool {
        guard let type = item.mountPointType?.lowercased(), !type.isEmpty else { return false }
        return type != "normal" && type != "shared_folder"
    }

    private static func isSupportedSourceItem(_ item: FileItem, allowDirectory: Bool) -> Bool {
        switch item.kind {
        case .file:
            item.sizeBytes.map { $0 >= 0 } == true
        case .directory:
            allowDirectory
        case .symlink, .unknown:
            false
        }
    }

    private static func isInvalidDestination(_ path: String, for sources: [FileItem]) -> Bool {
        sources.contains {
            $0.kind == .directory && (path == $0.path || path.hasPrefix($0.path + "/"))
        }
    }

    private static func isConfirmedItem(_ item: FileItem, source: FileItem) -> Bool {
        switch source.kind {
        case .file:
            item.kind == .file && item.sizeBytes == source.sizeBytes
        case .directory:
            item.kind == .directory
        case .symlink, .unknown:
            false
        }
    }
}

private enum MobileFileCopyMoveError: Error { case zeroProgress, wrongFolder }

import DsmCore
import DsmNetwork
import Foundation
import Observation

protocol MobileFileShareLinkServing: Sendable {
    var profileID: UUID { get }
    var fileShareLinkAvailability: FileShareLinkAvailability { get }
    func listShareLinksPage(offset: Int, limit: Int) async throws -> FileShareLinkPage
    func createShareLinkResult(
        _ request: FileShareLinkCreateRequest
    ) async throws -> FileShareLinkCreateOutcome
    func deleteShareLinks(ids: [String]) async throws
}

extension DsmFileRepository: MobileFileShareLinkServing {}

@MainActor
@Observable
final class MobileFileShareLinkModel {
    private struct ManagedLinkSnapshot: Sendable {
        let links: [FileShareLink]
        let total: Int
        let isTruncated: Bool
    }

    private enum ManagedLinkDeletionOutcome: Sendable {
        case confirmed
        case targetChanged
        case needsReview
        case permissionDenied
        case unsupported
        case cancelledBeforeSubmission
    }

    private static let shareLinkPageSize = 500
    private static let maximumShareLinkScanCount = 5_000

    private(set) var state = MobileFileShareLinkState()

    @ObservationIgnored private let mutationCoordinator: MobileMutationCoordinator
    @ObservationIgnored private let clipboard: any MobileClipboardWriting
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let timeZone: @Sendable () -> TimeZone
    @ObservationIgnored private var profileID: UUID?
    @ObservationIgnored private var repository: (any MobileFileShareLinkServing)?
    @ObservationIgnored private var repositoryIdentity: ObjectIdentifier?
    @ObservationIgnored private var submissionTask: Task<Void, Never>?
    @ObservationIgnored private var managementTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var reviewBlockedTargets: [UUID: Set<String>] = [:]

    init(
        mutationCoordinator: MobileMutationCoordinator = MobileMutationCoordinator(),
        clipboard: any MobileClipboardWriting = MobileSystemClipboard(),
        now: @escaping @Sendable () -> Date = Date.init,
        timeZone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.mutationCoordinator = mutationCoordinator
        self.clipboard = clipboard
        self.now = now
        self.timeZone = timeZone
    }

    var isAvailable: Bool {
        repository?.fileShareLinkAvailability.status == .available
    }

    var canSubmit: Bool {
        state.phase == .form && state.password.count <= 16
    }

    var canRefreshManagement: Bool {
        switch state.phase {
        case .managementEmpty, .managementContent, .managementError:
            managementTask == nil
        default:
            false
        }
    }

    func activate(profileID: UUID?, repository: (any MobileFileShareLinkServing)?) {
        guard let profileID,
              let repository,
              repository.profileID == profileID else {
            deactivate()
            return
        }
        let identity = ObjectIdentifier(repository as AnyObject)
        if self.profileID != profileID || repositoryIdentity != identity {
            submissionTask?.cancel()
            submissionTask = nil
            managementTask?.cancel()
            managementTask = nil
            resetPresentation()
            generation &+= 1
        }
        self.profileID = profileID
        self.repository = repository
        repositoryIdentity = identity
    }

    func begin(for item: FileItem) {
        guard submissionTask == nil,
              managementTask == nil,
              state.phase != .creating,
              let profileID,
              item.profileID == profileID,
              repository?.profileID == profileID else { return }
        let requiresReview = reviewBlockedTargets[profileID]?.contains(item.path) == true
        state = MobileFileShareLinkState(
            isPresented: true,
            phase: requiresReview ? .reviewRequired : (isAvailable ? .form : .confirmedFailure),
            target: item,
            failure: isAvailable || requiresReview ? nil : .unsupported,
            canRetry: false
        )
    }

    func beginManagement(for item: FileItem) {
        guard submissionTask == nil,
              managementTask == nil,
              let profileID,
              let repository,
              item.profileID == profileID,
              repository.profileID == profileID else { return }
        state = MobileFileShareLinkState(
            isPresented: true,
            phase: isAvailable ? .managementLoading : .managementUnsupported,
            target: item
        )
        guard isAvailable else { return }
        loadManagedLinks(for: item)
    }

    func showCreateFormFromManagement() {
        guard let profileID,
              let target = state.target,
              target.profileID == profileID,
              state.phase == .managementEmpty || state.phase == .managementContent else { return }
        let requiresReview = reviewBlockedTargets[profileID]?.contains(target.path) == true
        state.password = ""
        state.expiration = .never
        state.failure = nil
        state.canRetry = false
        state.copied = false
        state.confirmedLink = nil
        state.pendingDeletion = nil
        state.deletionFailure = nil
        state.phase = requiresReview ? .reviewRequired : .form
    }

    func refreshManagement() {
        guard canRefreshManagement,
              let target = state.target else { return }
        state.phase = .managementLoading
        state.pendingDeletion = nil
        state.deletionFailure = nil
        state.copiedManagedLinkID = nil
        loadManagedLinks(for: target)
    }

    func setPassword(_ value: String) {
        state.password = value
    }

    func setExpiration(_ value: MobileFileShareLinkExpiration) {
        state.expiration = value
    }

    func submit() {
        guard submissionTask == nil,
              state.phase == .form || (state.phase == .confirmedFailure && state.canRetry),
              state.password.count <= 16,
              let profileID,
              let repository,
              repository.profileID == profileID,
              let target = state.target,
              target.profileID == profileID else { return }

        let request: FileShareLinkCreateRequest
        do {
            request = try FileShareLinkCreateRequest(
                target: target,
                password: state.password,
                expiresOn: expirationDate(for: state.expiration)
            )
        } catch {
            state.phase = .confirmedFailure
            state.failure = .generic
            state.canRetry = true
            return
        }

        state.phase = .creating
        state.failure = nil
        state.canRetry = false
        state.copied = false
        state.confirmedLink = nil
        let requestGeneration = generation
        let targetPath = target.path
        reviewBlockedTargets[profileID, default: []].insert(targetPath)
        submissionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let execution = try await mutationCoordinator.perform(
                    profileID: profileID,
                    operation: "shareLinkCreate",
                    stableTarget: targetPath
                ) {
                    try await repository.createShareLinkResult(request)
                }
                guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                switch execution {
                case .duplicateInFlight:
                    reviewBlockedTargets[profileID]?.remove(targetPath)
                    finishFailure(.duplicate, canRetry: false)
                case .submitted(let outcome):
                    finish(outcome, expectedPath: targetPath)
                    if state.phase == .confirmedSuccess ||
                        !Self.requiresManualReview(outcome.result.status) &&
                        outcome.result.status != .confirmedSuccess {
                        reviewBlockedTargets[profileID]?.remove(targetPath)
                    }
                }
            } catch {
                guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                state.phase = .reviewRequired
                state.password = ""
                state.confirmedLink = nil
            }
            if isCurrent(profileID: profileID, generation: requestGeneration) {
                submissionTask = nil
            }
        }
    }

    func copyConfirmedLink() {
        guard let url = confirmedURL else { return }
        clipboard.copySensitiveURL(url)
        state.copied = true
    }

    func presentSystemShare() {
        guard let url = confirmedURL else { return }
        state.sharePresentation = MobileFileSharePresentation(url: url)
    }

    func copyManagedLink(_ link: FileShareLink) {
        guard let target = state.target,
              state.managedLinks.contains(where: { Self.exactLink($0, link) }),
              let url = Self.trustedURL(link, expectedPath: target.path) else { return }
        clipboard.copySensitiveURL(url)
        state.copiedManagedLinkID = link.id
    }

    func presentManagedLinkShare(_ link: FileShareLink) {
        guard let target = state.target,
              state.managedLinks.contains(where: { Self.exactLink($0, link) }),
              let url = Self.trustedURL(link, expectedPath: target.path) else { return }
        state.sharePresentation = MobileFileSharePresentation(url: url)
    }

    func beginDeleteManagedLink(_ link: FileShareLink) {
        guard state.phase == .managementContent,
              managementTask == nil,
              state.managedLinks.contains(where: { Self.exactLink($0, link) }) else { return }
        state.pendingDeletion = link
        state.deletionFailure = nil
        state.phase = .deletionConfirm
    }

    func cancelDeleteManagedLink() {
        guard state.phase == .deletionConfirm else { return }
        state.pendingDeletion = nil
        state.deletionFailure = nil
        state.phase = state.managedLinks.isEmpty ? .managementEmpty : .managementContent
    }

    func confirmDeleteManagedLink() {
        guard state.phase == .deletionConfirm,
              managementTask == nil,
              let profileID,
              let repository,
              let target = state.target,
              target.profileID == profileID,
              repository.profileID == profileID,
              let link = state.pendingDeletion,
              state.managedLinks.contains(where: { Self.exactLink($0, link) }) else { return }

        state.phase = .deleting
        state.deletionFailure = nil
        state.copiedManagedLinkID = nil
        let requestGeneration = generation
        managementTask = Task { [weak self] in
            guard let self else { return }
            do {
                let execution = try await mutationCoordinator.perform(
                    profileID: profileID,
                    operation: "shareLinkDelete",
                    stableTarget: link.id
                ) {
                    try await Self.deleteAndConfirm(
                        link,
                        targetPath: target.path,
                        repository: repository
                    )
                }
                guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                switch execution {
                case .duplicateInFlight:
                    finishDeletionFailure(.duplicate)
                case .submitted(let outcome):
                    finishDeletion(outcome, requested: link)
                }
            } catch {
                guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                finishDeletionFailure(Self.deletionFailure(for: error))
            }
            if isCurrent(profileID: profileID, generation: requestGeneration) {
                managementTask = nil
            }
        }
    }

    func dismissDeletionFeedback() {
        switch state.phase {
        case .deletionConfirmed, .deletionReviewRequired, .deletionFailure:
            state.pendingDeletion = nil
            state.deletionFailure = nil
            state.phase = state.managedLinks.isEmpty ? .managementEmpty : .managementContent
        default:
            break
        }
    }

    func shareDidDismiss() {
        state.sharePresentation = nil
    }

    func dismiss() {
        if state.phase == .creating {
            requestCancellation()
            return
        }
        submissionTask?.cancel()
        submissionTask = nil
        managementTask?.cancel()
        managementTask = nil
        generation &+= 1
        resetPresentation()
    }

    func requestCancellation() {
        guard state.phase == .creating else { return }
        submissionTask?.cancel()
    }

    func deactivate() {
        submissionTask?.cancel()
        submissionTask = nil
        managementTask?.cancel()
        managementTask = nil
        generation &+= 1
        profileID = nil
        repository = nil
        repositoryIdentity = nil
        resetPresentation()
    }

    func purge(profileID: UUID) {
        reviewBlockedTargets[profileID] = nil
        if self.profileID == profileID {
            deactivate()
        }
    }

    private var confirmedURL: URL? {
        guard state.phase == .confirmedSuccess,
              let target = state.target,
              let link = state.confirmedLink else { return nil }
        return Self.trustedURL(link, expectedPath: target.path)
    }

    private func loadManagedLinks(for target: FileItem) {
        guard let profileID,
              let repository,
              target.profileID == profileID,
              repository.profileID == profileID else { return }
        let requestGeneration = generation
        managementTask?.cancel()
        managementTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await Self.loadManagedLinkSnapshot(
                    targetPath: target.path,
                    repository: repository
                )
                guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                state.managedLinks = snapshot.links
                state.managedLinkTotal = snapshot.total
                state.managedLinksTruncated = snapshot.isTruncated
                state.pendingDeletion = nil
                state.deletionFailure = nil
                state.phase = snapshot.links.isEmpty ? .managementEmpty : .managementContent
            } catch {
                guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                state.managedLinks = []
                state.managedLinkTotal = 0
                state.managedLinksTruncated = false
                state.pendingDeletion = nil
                state.deletionFailure = nil
                state.phase = isAvailable ? .managementError : .managementUnsupported
            }
            if isCurrent(profileID: profileID, generation: requestGeneration) {
                managementTask = nil
            }
        }
    }

    private func finish(_ outcome: FileShareLinkCreateOutcome, expectedPath: String) {
        switch outcome.result.status {
        case .confirmedSuccess:
            guard let link = outcome.confirmedLink,
                  Self.trustedURL(link, expectedPath: expectedPath) != nil else {
                state.phase = .reviewRequired
                state.confirmedLink = nil
                return
            }
            state.phase = .confirmedSuccess
            state.confirmedLink = link
            state.password = ""
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
            state.phase = .reviewRequired
            state.confirmedLink = nil
            state.password = ""
        case .permissionDenied:
            finishFailure(.permission, canRetry: false)
        case .unsupported:
            finishFailure(.unsupported, canRetry: false)
        case .cancelledBeforeSubmission:
            finishFailure(.generic, canRetry: true)
        case .confirmedFailure:
            let failure: MobileFileShareLinkFailure = switch outcome.result.errorCategory {
            case .permission, .authentication: .permission
            case .unsupported: .unsupported
            case .conflict: .changed
            default: .generic
            }
            finishFailure(failure, canRetry: failure == .generic && !outcome.result.submitted)
        }
    }

    private func finishFailure(_ failure: MobileFileShareLinkFailure, canRetry: Bool) {
        state.phase = .confirmedFailure
        state.failure = failure
        state.canRetry = canRetry
        state.confirmedLink = nil
        state.password = ""
    }

    private func finishDeletion(_ outcome: ManagedLinkDeletionOutcome, requested: FileShareLink) {
        switch outcome {
        case .confirmed:
            state.managedLinks.removeAll { Self.exactLink($0, requested) }
            state.managedLinkTotal = max(0, state.managedLinkTotal - 1)
            state.phase = .deletionConfirmed
        case .targetChanged:
            finishDeletionFailure(.changed)
        case .needsReview:
            state.phase = .deletionReviewRequired
        case .permissionDenied:
            finishDeletionFailure(.permission)
        case .unsupported:
            finishDeletionFailure(.unsupported)
        case .cancelledBeforeSubmission:
            finishDeletionFailure(.generic)
        }
    }

    private func finishDeletionFailure(_ failure: MobileFileShareLinkDeletionFailure) {
        state.phase = .deletionFailure
        state.deletionFailure = failure
    }

    private func expirationDate(
        for expiration: MobileFileShareLinkExpiration
    ) throws -> FileShareLinkCalendarDate? {
        guard expiration.rawValue > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone()
        guard let date = calendar.date(
            byAdding: .day,
            value: expiration.rawValue,
            to: now()
        ) else { throw FileShareLinkContractError.invalidDate }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return try FileShareLinkCalendarDate(
            year: components.year!,
            month: components.month!,
            day: components.day!
        )
    }

    private func isCurrent(profileID: UUID, generation: UInt64) -> Bool {
        self.profileID == profileID
            && self.generation == generation
            && repository?.profileID == profileID
    }

    private func resetPresentation() {
        state = MobileFileShareLinkState()
    }

    private static func requiresManualReview(_ status: MutationResultStatus) -> Bool {
        switch status {
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
            true
        case .confirmedSuccess, .confirmedFailure, .cancelledBeforeSubmission,
             .permissionDenied, .unsupported:
            false
        }
    }

    private static func trustedURL(_ link: FileShareLink, expectedPath: String) -> URL? {
        guard link.path == expectedPath,
              !link.id.isEmpty,
              let url = URL(string: link.url),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil,
              url.user == nil,
              url.password == nil else { return nil }
        return url
    }

    private static func loadManagedLinkSnapshot(
        targetPath: String,
        repository: any MobileFileShareLinkServing
    ) async throws -> ManagedLinkSnapshot {
        var offset = 0
        var total = 0
        var scanned = 0
        var links: [FileShareLink] = []
        var seenIDs = Set<String>()
        var isTruncated = false

        while scanned < maximumShareLinkScanCount {
            let page = try await repository.listShareLinksPage(offset: offset, limit: shareLinkPageSize)
            total = max(total, page.total)
            for link in page.links where link.path == targetPath && !link.id.isEmpty {
                if seenIDs.insert(link.id).inserted {
                    links.append(link)
                }
            }
            scanned += page.links.count
            if page.isTruncated || scanned >= maximumShareLinkScanCount {
                isTruncated = page.isTruncated || page.hasMore || total > scanned
                break
            }
            guard page.hasMore, !page.links.isEmpty else { break }
            offset = page.offset + page.links.count
        }

        return ManagedLinkSnapshot(
            links: links,
            total: total,
            isTruncated: isTruncated
        )
    }

    private static func deleteAndConfirm(
        _ link: FileShareLink,
        targetPath: String,
        repository: any MobileFileShareLinkServing
    ) async throws -> ManagedLinkDeletionOutcome {
        guard repository.fileShareLinkAvailability.status == .available else { return .unsupported }
        if Task.isCancelled { return .cancelledBeforeSubmission }

        let before = try await loadManagedLinkSnapshot(targetPath: targetPath, repository: repository)
        guard before.links.contains(where: { exactLink($0, link) }) else { return .targetChanged }
        if Task.isCancelled { return .cancelledBeforeSubmission }

        do {
            try await repository.deleteShareLinks(ids: [link.id])
        } catch let error as AppError {
            switch error.category {
            case .permissionDenied, .authenticationRequired, .otpRequired:
                return .permissionDenied
            case .apiUnavailable, .versionUnsupported:
                return .unsupported
            case .cancelled:
                return .needsReview
            default:
                return .needsReview
            }
        } catch is CancellationError {
            return .needsReview
        } catch {
            return .needsReview
        }

        if Task.isCancelled { return .needsReview }
        do {
            let after = try await loadManagedLinkSnapshot(targetPath: targetPath, repository: repository)
            return after.links.contains(where: { exactLink($0, link) })
                ? .needsReview
                : .confirmed
        } catch {
            return .needsReview
        }
    }

    private static func deletionFailure(for error: Error) -> MobileFileShareLinkDeletionFailure {
        guard let appError = error as? AppError else { return .generic }
        switch appError.category {
        case .permissionDenied, .authenticationRequired, .otpRequired:
            return .permission
        case .apiUnavailable, .versionUnsupported:
            return .unsupported
        case .conflict, .notFound:
            return .changed
        default:
            return .generic
        }
    }

    private static func exactLink(_ left: FileShareLink, _ right: FileShareLink) -> Bool {
        left.id == right.id &&
            left.path == right.path &&
            left.url == right.url &&
            left.hasPassword == right.hasPassword &&
            left.expiresAt == right.expiresAt
    }
}

import DsmCore
import DsmNetwork
import Foundation
import Observation

protocol MobileFileShareLinkServing: Sendable {
    var profileID: UUID { get }
    var fileShareLinkAvailability: FileShareLinkAvailability { get }
    func createShareLinkResult(
        _ request: FileShareLinkCreateRequest
    ) async throws -> FileShareLinkCreateOutcome
}

extension DsmFileRepository: MobileFileShareLinkServing {}

@MainActor
@Observable
final class MobileFileShareLinkModel {
    private(set) var state = MobileFileShareLinkState()

    @ObservationIgnored private let mutationCoordinator: MobileMutationCoordinator
    @ObservationIgnored private let clipboard: any MobileClipboardWriting
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let timeZone: @Sendable () -> TimeZone
    @ObservationIgnored private var profileID: UUID?
    @ObservationIgnored private var repository: (any MobileFileShareLinkServing)?
    @ObservationIgnored private var repositoryIdentity: ObjectIdentifier?
    @ObservationIgnored private var submissionTask: Task<Void, Never>?
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
            resetPresentation()
            generation &+= 1
        }
        self.profileID = profileID
        self.repository = repository
        repositoryIdentity = identity
    }

    func begin(for item: FileItem) {
        guard submissionTask == nil,
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
}

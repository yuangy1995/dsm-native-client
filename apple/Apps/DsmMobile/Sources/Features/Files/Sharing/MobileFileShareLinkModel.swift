import DsmCore
import DsmNetwork
import Foundation
import Observation

/// 写方法沿用共享 Repository 的结果契约：提交前错误可抛出，提交后错误返回 MutationResult，禁止重放。
protocol MobileFileShareLinkServing: Sendable {
    var profileID: UUID { get }
    var fileShareLinkAvailability: FileShareLinkAvailability { get }
    func listShareLinksPage(offset: Int, limit: Int) async throws -> FileShareLinkPage
    func createShareLinkResult(
        _ request: FileShareLinkCreateRequest
    ) async throws -> FileShareLinkCreateOutcome
    func deleteShareLinkResult(_ link: FileShareLink) async throws -> MutationResult
    func editShareLink(_ request: FileShareLinkEditRequest) async throws -> FileShareLinkEditOutcome
    func loadFileStationAdvancedAccess() async throws -> FileStationAdvancedAccess
    func listFileStationPrincipals(prefix: String, offset: Int, limit: Int) async throws -> FileStationPrincipalPage
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

    private static let shareLinkPageSize = 500

    private(set) var state = MobileFileShareLinkState()

    @ObservationIgnored private let recovery: MobileFileShareRecoveryStore
    private var context = ""
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
        rootURL: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        timeZone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.recovery = MobileFileShareRecoveryStore(root: rootURL)
        self.mutationCoordinator = mutationCoordinator
        self.clipboard = clipboard
        self.now = now
        self.timeZone = timeZone
    }

    var isAvailable: Bool {
        repository?.fileShareLinkAvailability.status == .available
    }

    var canSubmit: Bool {
        state.phase == .form && !recovery.failed && !state.targets.isEmpty && state.password.count <= 16
            && (!state.isFileRequest || canCreateFileRequest)
            && (try? createRequests()) != nil
    }

    var canRefreshManagement: Bool {
        switch state.phase {
        case .managementEmpty, .managementContent, .managementError:
            managementTask == nil
        default:
            false
        }
    }

    func activate(profileID: UUID?, repository: (any MobileFileShareLinkServing)?, context: String? = nil) {
        guard let profileID,
              let repository,
              repository.profileID == profileID else {
            deactivate()
            return
        }
        let identity = ObjectIdentifier(repository as AnyObject)
        let nextContext = context ?? profileID.uuidString
        if self.profileID != profileID || repositoryIdentity != identity || self.context != nextContext {
            submissionTask?.cancel()
            submissionTask = nil
            managementTask?.cancel()
            managementTask = nil
            resetPresentation()
            generation &+= 1
        }
        self.context = nextContext
        self.profileID = profileID
        self.repository = repository
        repositoryIdentity = identity
        reviewBlockedTargets[profileID] = Set(recovery.entries.filter { $0.context == nextContext && $0.operation == "create" }.map(\.target))
    }

    var canCreateFileRequest: Bool {
        state.advancedAccess?.writesEnabled == true && !state.targets.isEmpty
            && state.targets.allSatisfy { $0.isDirectory && $0.permissions?.canWrite == true }
    }

    func begin(for item: FileItem) { begin(for: [item]) }

    func begin(for items: [FileItem]) {
        var seen = Set<String>()
        let items = items.filter { seen.insert($0.path).inserted }
        guard let item = items.first, items.allSatisfy({ $0.profileID == item.profileID }) else { return }
        guard submissionTask == nil,
              managementTask == nil,
              state.phase != .creating,
              let profileID,
              item.profileID == profileID,
              repository?.profileID == profileID else { return }
        let requiresReview = items.count == 1 && items.contains { reviewBlockedTargets[profileID]?.contains($0.path) == true }
        state = MobileFileShareLinkState(
            isPresented: true,
            phase: requiresReview ? .reviewRequired : (isAvailable ? .form : .confirmedFailure),
            target: items.count == 1 ? item : nil,
            targets: items,
            failure: isAvailable || requiresReview ? nil : .unsupported,
            canRetry: false
        )
        loadAdvancedAccess()
    }

    func beginManagement(for item: FileItem? = nil) {
        guard submissionTask == nil,
              managementTask == nil,
              let profileID,
              let repository,
              item == nil || item?.profileID == profileID,
              repository.profileID == profileID else { return }
        state = MobileFileShareLinkState(
            isPresented: true,
            phase: isAvailable ? .managementLoading : .managementUnsupported,
            target: item, targets: item.map { [$0] } ?? []
        )
        state.blockedLinkIDs = Set(recovery.entries.filter { $0.context == context && $0.operation != "create" }.map(\.target))
        guard isAvailable else { return }
        loadManagedLinks()
        loadAdvancedAccess()
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
        state.targets = [target]
        state.availableOn = nil; state.isFileRequest = false
    }

    func refreshManagement() {
        guard canRefreshManagement else { return }
        state.phase = .managementLoading
        state.pendingDeletion = nil
        state.deletionFailure = nil
        state.copiedManagedLinkID = nil
        loadManagedLinks()
        loadAdvancedAccess()
    }

    func retryCreation() {
        guard state.phase == .confirmedFailure, state.canRetry else { return }
        state.phase = .form; state.failure = nil; state.canRetry = false
    }

    func setPassword(_ value: String) {
        state.password = value
    }

    func setExpiration(_ value: MobileFileShareLinkExpiration) {
        state.expiration = value
    }

    func setAvailableOn(_ date: Date?) { state.availableOn = date }
    func setCustomExpiration(_ date: Date) { state.customExpiration = date }
    func setFileRequest(_ value: Bool) { state.isFileRequest = value && canCreateFileRequest }
    func setRequestName(_ value: String) { state.requestName = value }
    func setRequestMessage(_ value: String) { state.requestMessage = value }

    private func createRequests() throws -> [FileShareLinkCreateRequest] {
        try state.targets.map { target in
            try FileShareLinkCreateRequest(target: target, password: state.password,
                availableOn: try state.availableOn.map(calendarDate),
                expiresOn: state.expiration == .custom ? calendarDate(state.customExpiration) : expirationDate(for: state.expiration),
                fileRequest: state.isFileRequest ? .init(name: state.requestName, message: state.requestMessage) : nil)
        }
    }

    func submit() {
        if state.targets.count > 1 { submitBatch(); return }
        guard submissionTask == nil,
              state.phase == .form || (state.phase == .confirmedFailure && state.canRetry),
              state.password.count <= 16,
              !state.isFileRequest || canCreateFileRequest,
              let profileID,
              let repository,
              repository.profileID == profileID,
              !state.targets.isEmpty,
              let target = state.target,
              target.profileID == profileID else { return }

        let request: FileShareLinkCreateRequest
        do {
            request = try createRequests()[0]
        } catch {
            state.phase = .confirmedFailure
            state.failure = .generic
            state.canRetry = true
            return
        }

        guard recovery.reserve(.init(profileID: profileID, context: context, operation: "create", target: target.path)) else {
            state.password = ""
            if recovery.failed { finishFailure(.recovery, canRetry: false) } else { state.phase = .reviewRequired }
            return
        }
        let requestContext = context
        state.password = ""
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
                    recovery.finish(.init(profileID: profileID, context: requestContext, operation: "create", target: targetPath))
                    reviewBlockedTargets[profileID]?.remove(targetPath)
                    finishFailure(.duplicate, canRetry: false)
                case .submitted(let outcome):
                    finish(outcome, expectedPath: targetPath)
                    if state.phase == .confirmedSuccess ||
                        !Self.requiresManualReview(outcome.result.status) &&
                        outcome.result.status != .confirmedSuccess {
                        recovery.finish(.init(profileID: profileID, context: requestContext, operation: "create", target: targetPath))
                        reviewBlockedTargets[profileID]?.remove(targetPath)
                    }
                }
            } catch {
                guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                recovery.finish(.init(profileID: profileID, context: requestContext, operation: "create", target: targetPath))
                reviewBlockedTargets[profileID]?.remove(targetPath)
                let failure = Self.creationFailure(for: error)
                finishFailure(failure, canRetry: failure == .generic)
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
        guard state.managedLinks.contains(link),
              let url = Self.trustedURL(link, expectedPath: link.path) else { return }
        clipboard.copySensitiveURL(url)
        state.copiedManagedLinkID = link.id
    }

    func presentManagedLinkShare(_ link: FileShareLink) {
        guard let url = trustedManagedURL(link) else { return }
        state.sharePresentation = MobileFileSharePresentation(url: url)
    }

    func beginDeleteManagedLink(_ link: FileShareLink) {
        guard state.phase == .managementContent,
              managementTask == nil,
              !state.blockedLinkIDs.contains(link.id),
              state.managedLinks.contains(link) else { return }
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
              repository.profileID == profileID,
              let link = state.pendingDeletion,
              state.managedLinks.contains(where: { Self.exactLink($0, link) }) else { return }

        guard recovery.reserve(.init(profileID: profileID, context: context, operation: "delete", target: link.id)) else {
            if recovery.failed { finishDeletionFailure(.recovery) } else { state.phase = .deletionReviewRequired }
            return
        }
        let requestContext = context
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
                    try await repository.deleteShareLinkResult(link)
                }
                guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                switch execution {
                case .duplicateInFlight:
                    recovery.finish(.init(profileID: profileID, context: requestContext, operation: "delete", target: link.id))
                    finishDeletionFailure(.duplicate)
                case .submitted(let outcome):
                    if !Self.requiresManualReview(outcome.status) {
                        recovery.finish(.init(profileID: profileID, context: requestContext, operation: "delete", target: link.id))
                    }
                    finishDeletion(outcome, requested: link)
                }
            } catch {
                guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                // 共享结果方法只在提交前抛出；提交后失败统一返回未知结果。
                recovery.finish(.init(profileID: profileID, context: requestContext, operation: "delete", target: link.id))
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

    func purge(profileID: UUID, removeRecovery: Bool = false) {
        if removeRecovery { recovery.removeProfile(profileID) }
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

    private func loadManagedLinks() {
        guard let profileID, let repository, repository.profileID == profileID else { return }
        let targetPath = state.target?.path
        let requestGeneration = generation
        managementTask?.cancel()
        managementTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await Self.loadManagedLinkSnapshot(
                    targetPath: targetPath,
                    repository: repository
                )
                guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                if !snapshot.isTruncated {
                    for entry in recovery.entries where entry.context == context && entry.operation == "delete"
                        && !snapshot.links.contains(where: { $0.id == entry.target }) && targetPath == nil {
                        recovery.finish(entry); state.blockedLinkIDs.remove(entry.target)
                    }
                }
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

    var recoveryFailed: Bool { recovery.failed }
    var advancedAccess: FileStationAdvancedAccess? { state.advancedAccess }

    func trustedManagedURL(_ link: FileShareLink) -> URL? {
        guard state.managedLinks.contains(link) || state.itemResults.contains(where: { $0.link == link }) || state.confirmedLink == link else { return nil }
        return Self.trustedURL(link, expectedPath: link.path)
    }

    func copyLinks(_ links: [FileShareLink]) {
        let urls = links.compactMap(trustedManagedURL)
        guard !urls.isEmpty else { return }
        clipboard.copySensitiveURLs(urls)
        state.copied = true
    }

    func calendarDate(_ date: Date) throws -> FileShareLinkCalendarDate {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone()
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return try .init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    private func loadAdvancedAccess() {
        guard let repository, let profileID else { return }
        let requestGeneration = generation
        Task { [weak self] in
            let access = try? await repository.loadFileStationAdvancedAccess()
            guard let self, isCurrent(profileID: profileID, generation: requestGeneration) else { return }
            state.advancedAccess = access
        }
    }

    func principals(prefix: String, offset: Int) async throws -> FileStationPrincipalPage {
        guard let repository, let profileID else { throw CancellationError() }
        let requestGeneration = generation
        let page = try await repository.listFileStationPrincipals(prefix: prefix, offset: offset, limit: 200)
        guard isCurrent(profileID: profileID, generation: requestGeneration) else { throw CancellationError() }
        return page
    }

    private func submitBatch() {
        guard submissionTask == nil, canSubmit, let profileID, let repository,
              let requests = try? createRequests() else { return }
        state.phase = .creating; state.itemResults = []; state.password = ""
        let requestGeneration = generation, requestContext = context
        submissionTask = Task { [weak self] in
            guard let self else { return }
            for request in requests {
                guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                let entry = MobileFileShareRecoveryStore.Entry(profileID: profileID, context: requestContext, operation: "create", target: request.target.path)
                var status: MutationResultStatus = .cancelledBeforeSubmission
                var link: FileShareLink?
                if !Task.isCancelled {
                    if recovery.reserve(entry) {
                        reviewBlockedTargets[profileID, default: []].insert(request.target.path)
                        do {
                            let execution = try await mutationCoordinator.perform(profileID: profileID,
                                operation: "shareLinkCreate", stableTarget: request.target.path) {
                                try await repository.createShareLinkResult(request)
                            }
                            switch execution {
                            case .duplicateInFlight: status = .cancelledBeforeSubmission
                            case .submitted(let outcome):
                                status = outcome.result.status
                                if status == .confirmedSuccess {
                                    if let result = outcome.confirmedLink,
                                       Self.trustedURL(result, expectedPath: request.target.path) != nil { link = result }
                                    else { status = .submittedButUnverified }
                                }
                            }
                        } catch { status = Self.creationFailure(for: error) == .permission ? .permissionDenied : .confirmedFailure }
                        if !Self.requiresManualReview(status) {
                            recovery.finish(entry); reviewBlockedTargets[profileID]?.remove(request.target.path)
                        }
                    } else { status = recovery.failed ? .confirmedFailure : .submittedButUnverified }
                }
                guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                state.itemResults.append(.init(id: request.target.path, name: request.target.name, status: status, link: link))
            }
            state.password = ""; state.phase = .batchResults; submissionTask = nil
        }
    }

    /// 表单捕获完整原对象；逐项串行提交，未知结果不重放，也不丢弃其他项的成功结果。
    func editManagedLinks(_ requests: [FileShareLinkEditRequest]) {
        guard !requests.isEmpty, Set(requests.map { $0.baseline.id }).count == requests.count,
              requests.allSatisfy({ state.managedLinks.contains($0.baseline) && !state.blockedLinkIDs.contains($0.baseline.id) }),
              state.phase == .managementContent, managementTask == nil else { return }
        manage(links: requests.map(\.baseline), edits: requests)
    }

    func deleteManagedLinks(_ links: [FileShareLink]) {
        guard !links.isEmpty, Set(links.map(\.id)).count == links.count,
              links.allSatisfy({ state.managedLinks.contains($0) && !state.blockedLinkIDs.contains($0.id) }),
              state.phase == .managementContent, managementTask == nil else { return }
        manage(links: links, edits: nil)
    }

    private func manage(links: [FileShareLink], edits: [FileShareLinkEditRequest]?) {
        guard let repository, let profileID else { return }
        let requestGeneration = generation, requestContext = context
        let operation = edits == nil ? "delete" : "edit"
        state.phase = .managing; state.itemResults = []; state.password = ""
        managementTask = Task { [weak self] in
            guard let self else { return }
            for (index, link) in links.enumerated() {
                guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                let entry = MobileFileShareRecoveryStore.Entry(profileID: profileID, context: requestContext, operation: operation, target: link.id)
                var status: MutationResultStatus = .cancelledBeforeSubmission
                var updated: FileShareLink?
                if !Task.isCancelled {
                    if recovery.reserve(entry) {
                        do {
                            let edit = edits?[index]
                            let execution = try await mutationCoordinator.perform(profileID: profileID,
                                operation: "shareLinkManage", stableTarget: link.id) {
                                if let edit { return try await repository.editShareLink(edit) }
                                let result = try await repository.deleteShareLinkResult(link)
                                return FileShareLinkEditOutcome(result: result, confirmedLink: nil)
                            }
                            switch execution {
                            case .duplicateInFlight: status = .cancelledBeforeSubmission
                            case .submitted(let outcome):
                                status = outcome.result.status
                                updated = outcome.confirmedLink
                                if edits != nil && status == .confirmedSuccess &&
                                    (updated?.id != link.id || updated?.path != link.path || updated?.url != link.url) {
                                    status = .submittedButUnverified; updated = nil
                                }
                            }
                        } catch {
                            status = (error as? AppError)?.category == .permissionDenied ? .permissionDenied : .confirmedFailure
                        }
                        if !Self.requiresManualReview(status) { recovery.finish(entry) }
                    } else { status = recovery.failed ? .confirmedFailure : .submittedButUnverified }
                }
                guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                if Self.requiresManualReview(status) { state.blockedLinkIDs.insert(link.id) }
                if status == .confirmedSuccess {
                    if let updated, let i = state.managedLinks.firstIndex(where: { $0.id == link.id }) { state.managedLinks[i] = updated }
                    else if edits == nil { state.managedLinks.removeAll { $0.id == link.id } }
                }
                state.itemResults.append(.init(id: link.id, name: link.name, status: status, link: status == .confirmedSuccess ? updated : nil))
            }
            state.phase = .batchResults; managementTask = nil
        }
    }

    func returnToManagement() {
        guard submissionTask == nil, managementTask == nil else { return }
        state.phase = .managementLoading; loadManagedLinks()
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

    private func finishDeletion(_ outcome: MutationResult, requested: FileShareLink) {
        switch outcome.status {
        case .confirmedSuccess:
            state.managedLinks.removeAll { $0.id == requested.id }
            state.managedLinkTotal = max(0, state.managedLinkTotal - 1)
            state.phase = .deletionConfirmed
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
            state.blockedLinkIDs.insert(requested.id)
            state.phase = .deletionReviewRequired
        case .permissionDenied: finishDeletionFailure(.permission)
        case .unsupported: finishDeletionFailure(.unsupported)
        case .confirmedFailure: finishDeletionFailure(.changed)
        case .cancelledBeforeSubmission: finishDeletionFailure(.generic)
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
        targetPath: String?,
        repository: any MobileFileShareLinkServing
    ) async throws -> ManagedLinkSnapshot {
        var offset = 0
        var total = 0
        var links: [FileShareLink] = []
        var seenIDs = Set<String>()
        var isTruncated = false

        while true {
            let page = try await repository.listShareLinksPage(offset: offset, limit: shareLinkPageSize)
            guard page.offset == offset, page.total >= offset + page.links.count,
                  offset == 0 || total == page.total,
                  !page.links.isEmpty || !page.hasMore,
                  page.isTruncated || page.hasMore == (offset + page.links.count < page.total) else { throw CancellationError() }
            total = page.total
            guard Set(page.links.map(\.id)).count == page.links.count,
                  page.links.allSatisfy({ !seenIDs.contains($0.id) }) else { throw CancellationError() }
            for link in page.links where (targetPath == nil || link.path == targetPath) && !link.id.isEmpty {
                links.append(link)
            }
            seenIDs.formUnion(page.links.map(\.id))
            if page.isTruncated {
                isTruncated = true
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

    private static func creationFailure(for error: Error) -> MobileFileShareLinkFailure {
        switch deletionFailure(for: error) {
        case .permission: .permission
        case .changed: .changed
        case .unsupported: .unsupported
        case .duplicate: .duplicate
        case .generic: .generic
        case .recovery: .recovery
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
        left == right
    }
}

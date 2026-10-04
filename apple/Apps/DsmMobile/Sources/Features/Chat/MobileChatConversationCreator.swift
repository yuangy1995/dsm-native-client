import DsmCore
import Foundation
import Observation

enum MobileChatConversationCreatorPageState: Equatable, Sendable {
    case loading
    case empty
    case error
    case content
}

@MainActor
@Observable
final class MobileChatConversationCreator {
    private var repository: any ChatRepository
    private(set) var availability: ChatAvailability
    private(set) var users: [ChatUser] = []
    private(set) var pageState: MobileChatConversationCreatorPageState = .loading
    private var submitting = false
    var isSubmitting: Bool { submitting || directEntry.map(recovery.isExecuting) == true || groupRecovery.isBusy(in: context) }
    private(set) var errorCategory: AppErrorCategory?
    private(set) var repositoryGeneration = 0
    private var selectedGroupID: UUID?
    private var deferredRepository: (any ChatRepository)?
    private var deferredAvailability: ChatAvailability?
    let context: String
    private let recovery: MobileChatConversationCreationStore
    private let groupRecovery: MobileChatGroupCreationStore
    private var isActive = true
    private weak var owner: MobileChatModel?
    private var directEntry: MobileChatConversationCreationStore.Entry? { recovery.pending(in: context) }
    var storageFailed: Bool { recovery.failed || groupRecovery.failed }
    var canResumeDirectCreation: Bool { directEntry?.phase == .prepared }
    var groupEntries: [MobileChatGroupCreationStore.Entry] {
        groupRecovery.entries.filter { $0.context == context }.sorted { $0.createdAt < $1.createdAt }
    }
    var groupEntry: MobileChatGroupCreationStore.Entry? {
        guard directEntry == nil else { return nil }
        return selectedGroupID.flatMap { groupRecovery.entry($0, in: context) }
    }
    var canContinueGroup: Bool { canCreateGroup && groupEntry.map { $0.receipt?.canContinue ?? true } == true }

    init(repository: any ChatRepository, availability: ChatAvailability,
         context: String = UUID().uuidString, recovery: MobileChatConversationCreationStore? = nil,
         groupRecovery: MobileChatGroupCreationStore? = nil, owner: MobileChatModel? = nil) {
        self.repository = repository
        self.availability = availability
        self.context = context
        self.recovery = recovery ?? MobileChatConversationCreationStore(root: nil)
        self.groupRecovery = groupRecovery ?? MobileChatGroupCreationStore(root: nil)
        self.owner = owner
        selectedGroupID = groupEntries.first?.id
    }

    var canCreateDirect: Bool {
        availability.status == .available
            && availability.supportedFeatures.contains(.directConversation)
            && owner?.forwarding?.blocksContactCreation != true
    }

    var canCreateGroup: Bool {
        availability.status == .available
            && availability.supportedFeatures.contains(.groupConversation)
            && availability.supportedFeatures.contains(.groupMembers)
    }

    var requiresReview: Bool { groupEntry != nil || directEntry != nil }
    var pendingDirectUserID: String? { directEntry?.userID }
    var pendingGroupTitle: String? { groupEntry?.title }
    var pendingGroupMemberIDs: [String] { groupEntry?.memberIDs ?? [] }
    var pendingIsGroup: Bool { groupEntry != nil && directEntry == nil }

    func selectGroupEntry(_ id: UUID) {
        guard isActive, !isSubmitting, directEntry == nil, groupRecovery.entry(id, in: context) != nil else { return }
        selectedGroupID = id; errorCategory = nil
    }

    func startAnotherConversation() {
        guard isActive, !isSubmitting, directEntry == nil else { return }
        selectedGroupID = nil; errorCategory = nil
    }

    func cancelPreparedGroup() {
        guard isActive, !isSubmitting, let entry = groupEntry, entry.receipt == nil else { return }
        do { try groupRecovery.discardPrepared(entry); selectedGroupID = nil; errorCategory = nil }
        catch { errorCategory = .unknown }
    }

    func updateAvailability(_ value: ChatAvailability) {
        availability = value
    }

    func rebind(repository: any ChatRepository, availability: ChatAvailability) {
        isActive = true
        self.availability = availability
        guard !submitting else {
            repositoryGeneration &+= 1
            deferredRepository = repository
            deferredAvailability = availability
            return
        }
        applyRepositoryBinding(repository, availability: availability)
    }

    func invalidate() {
        isActive = false
        repositoryGeneration &+= 1
    }

    private func applyRepositoryBinding(
        _ repository: any ChatRepository,
        availability: ChatAvailability
    ) {
        self.availability = availability
        self.repository = repository
        repositoryGeneration &+= 1
        users = []
        pageState = .loading
        errorCategory = nil
    }

    func loadUsers() async {
        guard isActive, !isSubmitting else { return }
        let generation = repositoryGeneration
        let boundRepository = repository
        pageState = .loading
        errorCategory = nil
        do {
            let values = try await boundRepository.listUsers()
            try Task.checkCancellation()
            guard isActive, generation == repositoryGeneration else { return }
            users = values
                .filter { !$0.isDisabled && $0.isCurrentUser != true }
                .sorted {
                    let order = $0.displayName.localizedStandardCompare($1.displayName)
                    return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
                }
            pageState = users.isEmpty ? .empty : .content
        } catch is CancellationError {
            return
        } catch {
            guard isActive, generation == repositoryGeneration else { return }
            users = []
            pageState = .error
            errorCategory = Self.category(for: error)
        }
    }

    func openDirectConversation(userID: String) async -> ChatConversationCreateOutcome? {
        let normalizedID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActive, !isSubmitting, groupEntry == nil, !normalizedID.isEmpty,
              owner?.forwarding?.blocksContactCreation != true else { return nil }
        guard !storageFailed else { errorCategory = .unknown; return nil }
        let entry: MobileChatConversationCreationStore.Entry
        if let existing = directEntry {
            guard existing.userID == normalizedID else { errorCategory = .conflict; return nil }
            entry = existing
        } else {
            guard canCreateDirect else { return nil }
            entry = .init(id: UUID(), context: context, userID: normalizedID, phase: .prepared)
            guard recovery.reserve(entry) else { errorCategory = .unknown; return nil }
        }
        guard recovery.beginExecution(entry) else { return nil }
        submitting = true
        errorCategory = nil
        let generation = repositoryGeneration, boundRepository = repository
        defer {
            recovery.endExecution(entry)
            submitting = false
            applyDeferredRepositoryIfNeeded()
        }
        do {
            let outcome: ChatConversationCreateOutcome
            if entry.phase == .submitted {
                outcome = try await boundRepository.recoverDirectConversation(userID: entry.userID, clientRequestID: entry.id)
            } else {
                outcome = try await boundRepository.openDirectConversationResult(userID: entry.userID, clientRequestID: entry.id) { [weak self] in
                    try await MainActor.run {
                        guard let self, self.isActive, self.repositoryGeneration == generation, !Task.isCancelled else {
                            throw CancellationError()
                        }
                        try self.recovery.markSubmitted(entry)
                    }
                }
            }
            let unfinished = outcome.result.status == .submittedButUnverified
                || outcome.result.status == .cancellationRequestedAfterSubmission
                || outcome.result.status == .partialSuccess
            if !unfinished, !recovery.finish(entry) {
                if isActive, generation == repositoryGeneration { errorCategory = .unknown }
                return nil
            }
            guard isActive, generation == repositoryGeneration else { return nil }
            errorCategory = Self.category(for: outcome.result)
            return outcome
        } catch {
            if directEntry?.phase == .prepared, !recovery.failed { recovery.finish(entry) }
            guard isActive, generation == repositoryGeneration else { return nil }
            errorCategory = recovery.failed ? .unknown
                : (directEntry?.phase == .submitted ? .partialFailure : Self.category(for: error))
            return nil
        }
    }

    func createGroup(title: String, memberIDs: [String]) async -> ChatConversationCreateOutcome? {
        guard isActive, !isSubmitting, directEntry == nil, !storageFailed else { return nil }
        let entry: MobileChatGroupCreationStore.Entry
        do {
            let draft = try ChatGroupDraft(clientRequestID: groupEntry?.id ?? UUID(), title: title, memberIDs: memberIDs, isEncrypted: false)
            if let pending = groupEntry ?? groupRecovery.matching(draft, in: context) {
                guard pending.title == draft.title, pending.memberIDs == draft.memberIDs else {
                    errorCategory = .conflict; return nil
                }
                entry = pending
            } else {
                guard canCreateGroup else { return nil }
                entry = .init(id: draft.clientRequestID, context: context, title: draft.title, memberIDs: draft.memberIDs, createdAt: Date())
                try groupRecovery.reserve(entry)
            }
            selectedGroupID = entry.id
        } catch {
            errorCategory = storageFailed ? .unknown : Self.category(for: error); return nil
        }
        return await submitGroup(entry, continueSteps: false)
    }

    func refreshGroup() async -> ChatConversationCreateOutcome? {
        guard let entry = groupEntry, entry.receipt != nil else { return nil }
        return await submitGroup(entry, continueSteps: false)
    }

    func continueGroup() async -> ChatConversationCreateOutcome? {
        guard canContinueGroup, let entry = groupEntry else { return nil }
        return await submitGroup(entry, continueSteps: true)
    }

    private func submitGroup(_ entry: MobileChatGroupCreationStore.Entry, continueSteps: Bool) async -> ChatConversationCreateOutcome? {
        guard isActive, !isSubmitting, !storageFailed, directEntry == nil,
              groupRecovery.begin(entry.id, in: context) else { return nil }
        submitting = true
        let generation = repositoryGeneration, boundRepository = repository
        errorCategory = nil
        defer {
            groupRecovery.end(entry.id)
            submitting = false
            applyDeferredRepositoryIfNeeded()
        }
        do {
            let record: @Sendable (ChatGroupCreateReceipt) async throws -> Void = { [weak self] receipt in
                try await MainActor.run {
                    guard let self else { throw CancellationError() }
                    let old = self.groupRecovery.entry(entry.id, in: entry.context)?.receipt
                    let willSubmit = old == nil || (receipt.join == .submitted && old?.join != .submitted)
                        || (receipt.invite == .submitted && old?.invite != .submitted)
                    if willSubmit {
                        guard self.isActive, self.repositoryGeneration == generation, self.canCreateGroup, !Task.isCancelled else {
                            throw CancellationError()
                        }
                    }
                    // 收到的回执始终归回原账号，切换页面或账号不能丢弃已发生的创建。
                    try self.groupRecovery.record(receipt, in: entry.context)
                }
            }
            let outcome: ChatConversationCreateOutcome
            if let receipt = entry.receipt {
                outcome = continueSteps
                    ? try await boundRepository.continueGroupCreation(entry.draft(), receipt: receipt, recordProgress: record)
                    : try await boundRepository.recoverGroupCreation(receipt, recordProgress: record)
            } else {
                guard canCreateGroup else { return nil }
                outcome = try await boundRepository.createGroupResult(entry.draft(), recordProgress: record)
            }
            try groupRecovery.finish(entry, outcome: outcome)
            guard isActive, generation == repositoryGeneration else { return nil }
            errorCategory = Self.category(for: outcome.result)
            return outcome
        } catch {
            // 保存前或提交前失败的草稿可重新准备；已提交的任何部分都不能被清除重建。
            if groupRecovery.entry(entry.id, in: context)?.receipt == nil, !groupRecovery.failed {
                groupRecovery.end(entry.id)
                try? groupRecovery.discardPrepared(entry)
            }
            guard isActive, generation == repositoryGeneration else { return nil }
            errorCategory = storageFailed ? .unknown : (groupEntry?.receipt != nil ? .partialFailure : Self.category(for: error))
            return nil
        }
    }

    private func applyDeferredRepositoryIfNeeded() {
        guard let deferredRepository else { return }
        let availability = deferredAvailability ?? self.availability
        self.deferredRepository = nil
        deferredAvailability = nil
        applyRepositoryBinding(deferredRepository, availability: availability)
    }

    private static func category(for result: MutationResult) -> AppErrorCategory? {
        switch result.status {
        case .confirmedSuccess:
            return nil
        case .permissionDenied:
            return .permissionDenied
        case .unsupported:
            return .apiUnavailable
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
            return .partialFailure
        case .cancelledBeforeSubmission:
            return .cancelled
        case .confirmedFailure:
            return result.errorCategory == .authentication ? .authenticationRequired : .invalidResponse
        }
    }

    private static func category(for error: Error) -> AppErrorCategory {
        if let appError = error as? AppError { return appError.category }
        if error is ChatContractError { return .invalidResponse }
        return .networkUnavailable
    }

}

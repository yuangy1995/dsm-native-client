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
    var isSubmitting: Bool { submitting || directEntry.map(recovery.isExecuting) == true }
    private(set) var errorCategory: AppErrorCategory?
    private(set) var repositoryGeneration = 0
    private var pendingDraft: PendingDraft?
    private var pendingRequiresReadbackOnly = false
    private var deferredRepository: (any ChatRepository)?
    private var deferredAvailability: ChatAvailability?
    let context: String
    private let recovery: MobileChatConversationCreationStore
    private var isActive = true
    private weak var owner: MobileChatModel?
    private var directEntry: MobileChatConversationCreationStore.Entry? { recovery.pending(in: context) }
    var storageFailed: Bool { recovery.failed }
    var canResumeDirectCreation: Bool { directEntry?.phase == .prepared }

    init(repository: any ChatRepository, availability: ChatAvailability,
         context: String = UUID().uuidString, recovery: MobileChatConversationCreationStore? = nil, owner: MobileChatModel? = nil) {
        self.repository = repository
        self.availability = availability
        self.context = context
        self.recovery = recovery ?? MobileChatConversationCreationStore(root: nil)
        self.owner = owner
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

    var requiresReview: Bool { pendingDraft != nil || directEntry != nil }
    var pendingDirectUserID: String? { directEntry?.userID }
    var pendingGroupTitle: String? { pendingDraft?.groupDraft.title }
    var pendingGroupMemberIDs: [String] { pendingDraft?.groupDraft.memberIDs ?? [] }
    var pendingIsGroup: Bool { pendingDraft != nil }

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
        if pendingDraft != nil {
            pendingRequiresReadbackOnly = true
            return
        }
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
        guard isActive, !isSubmitting, pendingDraft == nil, !normalizedID.isEmpty,
              owner?.forwarding?.blocksContactCreation != true else { return nil }
        guard !recovery.failed else { errorCategory = .unknown; return nil }
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
        guard isActive, canCreateGroup, directEntry == nil, !recovery.failed else { return nil }
        let requestID = pendingDraft?.requestID ?? UUID()
        let groupDraft: ChatGroupDraft
        do {
            groupDraft = try ChatGroupDraft(
                clientRequestID: requestID,
                title: title,
                memberIDs: memberIDs,
                isEncrypted: false
            )
        } catch {
            errorCategory = Self.category(for: error)
            return nil
        }
        let draft = PendingDraft(
            requestID: requestID,
            groupDraft: groupDraft
        )
        return await submit(draft) {
            try await repository.createGroupResult(groupDraft)
        }
    }

    private func submit(
        _ draft: PendingDraft,
        operation: () async throws -> ChatConversationCreateOutcome
    ) async -> ChatConversationCreateOutcome? {
        guard !isSubmitting, pendingDraft == nil || pendingDraft == draft else {
            errorCategory = .conflict
            return nil
        }
        submitting = true
        let generation = repositoryGeneration
        errorCategory = nil
        defer {
            submitting = false
            applyDeferredRepositoryIfNeeded()
        }
        do {
            let outcome = pendingRequiresReadbackOnly
                ? try await reviewPendingDraft(draft)
                : try await operation()
            if outcome.result.status == .submittedButUnverified
                || outcome.result.status == .cancellationRequestedAfterSubmission {
                pendingDraft = draft
                errorCategory = .partialFailure
            } else {
                pendingDraft = nil
                pendingRequiresReadbackOnly = false
                errorCategory = Self.category(for: outcome.result)
            }
            guard isActive, generation == repositoryGeneration else { return nil }
            return outcome
        } catch is CancellationError {
            return nil
        } catch {
            errorCategory = Self.category(for: error)
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

    private func reviewPendingDraft(
        _ draft: PendingDraft
    ) async throws -> ChatConversationCreateOutcome {
        do {
            let conversations = try await repository.listConversations()
            let groupDraft = draft.groupDraft
            var confirmed: ChatConversation?
            for conversation in conversations
            where conversation.kind == .group && !conversation.isEncrypted && conversation.title == groupDraft.title {
                let members = try await repository.listConversationMembers(conversationID: conversation.id)
                if Set(groupDraft.memberIDs).isSubset(of: Set(members.map(\.id))) {
                    confirmed = conversation
                    break
                }
            }
            return try readbackOutcome(draft: draft, confirmedConversation: confirmed)
        } catch {
            return try readbackOutcome(
                draft: draft,
                confirmedConversation: nil,
                cancelled: error is CancellationError
            )
        }
    }

    private func readbackOutcome(
        draft: PendingDraft,
        confirmedConversation: ChatConversation?,
        cancelled: Bool = false
    ) throws -> ChatConversationCreateOutcome {
        let confirmed = confirmedConversation != nil
        return ChatConversationCreateOutcome(
            result: try MutationResult(
                status: confirmed
                    ? .confirmedSuccess
                    : (cancelled
                        ? .cancellationRequestedAfterSubmission
                        : .submittedButUnverified),
                operation: "chatGroupCreate",
                submitted: true,
                requiresRefresh: !confirmed,
                counts: MutationResultCounts(
                    succeeded: confirmed ? 1 : 0,
                    failed: 0,
                    unknown: confirmed ? 0 : 1
                ),
                errorCategory: confirmed ? nil : (cancelled ? .network : .unknown),
                diagnosticTag: confirmed
                    ? "chat.conversation-create.readback-confirmed"
                    : "chat.conversation-create.readback-pending"
            ),
            clientRequestID: draft.requestID,
            confirmedConversation: confirmedConversation
        )
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

    private struct PendingDraft: Equatable {
        let requestID: UUID
        let groupDraft: ChatGroupDraft
    }
}

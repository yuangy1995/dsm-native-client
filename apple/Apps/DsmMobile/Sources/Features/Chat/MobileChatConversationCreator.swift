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
    private(set) var isSubmitting = false
    private(set) var errorCategory: AppErrorCategory?
    private(set) var repositoryGeneration = 0
    private var pendingDraft: PendingDraft?
    private var pendingRequiresReadbackOnly = false
    private var deferredRepository: (any ChatRepository)?
    private var deferredAvailability: ChatAvailability?

    init(repository: any ChatRepository, availability: ChatAvailability) {
        self.repository = repository
        self.availability = availability
    }

    var canCreateDirect: Bool {
        availability.status == .available
            && availability.supportedFeatures.contains(.directConversation)
    }

    var canCreateGroup: Bool {
        availability.status == .available
            && availability.supportedFeatures.contains(.groupConversation)
            && availability.supportedFeatures.contains(.groupMembers)
    }

    var requiresReview: Bool { pendingDraft != nil }
    var pendingDirectUserID: String? { pendingDraft?.directUserID }
    var pendingGroupTitle: String? { pendingDraft?.groupDraft?.title }
    var pendingGroupMemberIDs: [String] { pendingDraft?.groupDraft?.memberIDs ?? [] }
    var pendingIsGroup: Bool { pendingDraft?.groupDraft != nil }

    func updateAvailability(_ value: ChatAvailability) {
        availability = value
    }

    func rebind(repository: any ChatRepository, availability: ChatAvailability) {
        self.availability = availability
        guard !isSubmitting else {
            deferredRepository = repository
            deferredAvailability = availability
            return
        }
        applyRepositoryBinding(repository, availability: availability)
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
        guard !isSubmitting else { return }
        let generation = repositoryGeneration
        let boundRepository = repository
        pageState = .loading
        errorCategory = nil
        do {
            let values = try await boundRepository.listUsers()
            try Task.checkCancellation()
            guard generation == repositoryGeneration else { return }
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
            guard generation == repositoryGeneration else { return }
            users = []
            pageState = .error
            errorCategory = Self.category(for: error)
        }
    }

    func openDirectConversation(userID: String) async -> ChatConversationCreateOutcome? {
        let normalizedID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canCreateDirect, !normalizedID.isEmpty else { return nil }
        let draft = PendingDraft(
            requestID: pendingDraft?.requestID ?? UUID(),
            directUserID: normalizedID,
            groupDraft: nil
        )
        return await submit(draft) {
            try await repository.openDirectConversationResult(
                userID: normalizedID,
                clientRequestID: draft.requestID
            )
        }
    }

    func createGroup(title: String, memberIDs: [String]) async -> ChatConversationCreateOutcome? {
        guard canCreateGroup else { return nil }
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
            directUserID: nil,
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
        isSubmitting = true
        errorCategory = nil
        defer {
            isSubmitting = false
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
            let confirmed: ChatConversation?
            if let userID = draft.directUserID {
                confirmed = conversations.first {
                    $0.kind == .direct && $0.memberIDs.contains(userID)
                }
            } else if let groupDraft = draft.groupDraft {
                var match: ChatConversation?
                for conversation in conversations
                where conversation.kind == .group && conversation.title == groupDraft.title {
                    let members = try await repository.listConversationMembers(
                        conversationID: conversation.id
                    )
                    if Set(groupDraft.memberIDs).isSubset(of: Set(members.map(\.id))) {
                        match = conversation
                        break
                    }
                }
                confirmed = match
            } else {
                confirmed = nil
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
                operation: draft.groupDraft == nil
                    ? "chatDirectConversationCreate"
                    : "chatGroupCreate",
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
        let directUserID: String?
        let groupDraft: ChatGroupDraft?
    }
}

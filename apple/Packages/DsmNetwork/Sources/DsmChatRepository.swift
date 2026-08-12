import DsmCore
import Foundation
import DsmLocalization

/// 通过 DSM 登录会话访问 Synology Chat 套件的适配器。
///
/// `SYNO.Chat.*` 普通用户聊天接口没有公开契约，因此所有调用都必须先通过
/// `SYNO.API.Info` 能力发现，并集中在本文件内，避免内部协议扩散到界面和业务层。
public actor DsmChatRepository: ChatRepository {
    private let capabilities: CapabilitySet
    private let credential: DsmSessionCredential
    private let client: DsmAPIClient
    private let baseURL: URL
    private let transport: any DsmHTTPTransport
    private let realtimeClient: DsmChatRealtimeClient
    private var completedMessages: [UUID: ChatMessage] = [:]
    private var pendingMessageSends: [UUID: PendingChatMessageSendReview] = [:]
    private var pendingAttachmentSends: [UUID: PendingChatAttachmentSendReview] = [:]
    private var completedDirectConversations: [UUID: ChatConversation] = [:]
    private var completedGroups: [UUID: ChatConversation] = [:]
    private var directConversationDrafts: [UUID: String] = [:]
    private var groupConversationDrafts: [UUID: ChatGroupDraft] = [:]
    private var pendingDirectConversations: [UUID: PendingDirectConversationCreate] = [:]
    private var pendingGroupConversations: [UUID: PendingGroupConversationCreate] = [:]
    private var terminalDirectConversationOutcomes: [UUID: ChatConversationCreateOutcome] = [:]
    private var terminalGroupConversationOutcomes: [UUID: ChatConversationCreateOutcome] = [:]
    private var isCreatingConversation = false
    private var conversationCreateWaiters: [CheckedContinuation<Void, Never>] = []
    private var completedReminders: [UUID: ChatReminder] = [:]
    private var completedReminderDeletions: Set<UUID> = []
    private var completedScheduledMessages: [UUID: ChatScheduledMessage] = [:]
    private var completedScheduledMessageDeletions: Set<UUID> = []
    private var completedMessageDeletions: Set<UUID> = []
    private var completedConversationClosures: Set<UUID> = []
    private var completedMessageForwards: Set<UUID> = []
    private var completedPinChanges: Set<UUID> = []
    private var knownUsersByID: [String: ChatUser] = [:]
    private var cachedCurrentUserID: String?
    private let currentAccountName: String?
    private var avatarCache: [String: Data] = [:]
    private var unavailableAvatarUserIDs: Set<String> = []

    public init(
        profile: NasProfile,
        capabilities: CapabilitySet,
        session: AuthSession,
        transport: (any DsmHTTPTransport)? = nil
    ) throws {
        let resolvedTransport = transport ?? URLSessionTransport(
            expectedHost: profile.host,
            pinnedCertificateSHA256: profile.pinnedCertificateSHA256,
            requiresSystemCertificateTrust: DsmQuickConnectResolver.isTrustedRelayHost(profile.host)
        )
        let resolvedBaseURL = try DsmEndpoint.baseURL(for: profile)
        self.capabilities = capabilities
        self.baseURL = resolvedBaseURL
        self.transport = resolvedTransport
        currentAccountName = Self.normalizedIdentityName(profile.usernameHint)
        let resolvedCredential = DsmSessionCredential(
            sid: session.sid,
            synoToken: session.synoToken
        )
        credential = resolvedCredential
        client = DsmAPIClient(
            baseURL: resolvedBaseURL,
            transport: resolvedTransport
        )
        realtimeClient = DsmChatRealtimeClient(
            baseURL: resolvedBaseURL,
            credential: resolvedCredential,
            expectedHost: profile.host,
            pinnedCertificateSHA256: profile.pinnedCertificateSHA256,
            requiresSystemCertificateTrust: DsmQuickConnectResolver.isTrustedRelayHost(profile.host)
        )
    }

    public func realtimeEvents() async -> AsyncStream<ChatRealtimeEvent> {
        await realtimeClient.events()
    }

    public func startRealtime() async {
        await realtimeClient.start()
    }

    public func stopRealtime() async {
        await realtimeClient.stop()
    }

    public func availability() async -> ChatAvailability {
        guard hasCapability(DsmAPIName.chatChannel),
              hasCapability(DsmAPIName.chatUser) else {
            return ChatAvailability(status: .unavailable)
        }
        var features: Set<ChatFeature> = [.deleteOwnMessage, .closeConversation]
        if supportsFormCapability(DsmAPIName.chatChannelAnonymous, version: 2) {
            features.insert(.directConversation)
        }
        if supportsFormCapability(DsmAPIName.chatChannelNamed, version: 1),
           supportsFormCapability(DsmAPIName.chatChannelMember, version: 1) {
            features.insert(.groupConversation)
        }
        if hasCapability(DsmAPIName.chatPostReminder) {
            features.insert(.reminder)
            features.insert(.reminderManagement)
        }
        if hasCapability(DsmAPIName.chatPostVote) {
            features.insert(.poll)
        }
        if hasCapability(DsmAPIName.chatPostSchedule) {
            features.insert(.scheduledMessage)
        }
        if supportsVersion(DsmAPIName.chatPost, version: 5) {
            features.formUnion([.textMessage, .emoji, .messageForward, .pinnedMessages])
        }
        if hasCapability(DsmAPIName.chatChannelMember) {
            features.insert(.groupMembers)
        }
        if supportsAttachmentUpload {
            features.formUnion([.imageAttachment, .videoAttachment, .fileAttachment])
        }
        if hasCapability(DsmAPIName.chatPostFile) {
            features.insert(.attachmentDownload)
        }
        return ChatAvailability(status: .available, supportedFeatures: features)
    }

    public func listUsers() async throws -> [ChatUser] {
        try await listUsers(loadAvatars: true)
    }

    private func listUsers(loadAvatars: Bool) async throws -> [ChatUser] {
        let payload = try await call(
            DsmAPIName.chatUser,
            method: "list",
            parameters: [:]
        )
        let currentUserID = currentUserID(from: payload)
        cachedCurrentUserID = currentUserID ?? cachedCurrentUserID
        let parsedUsers = userValues(from: payload).compactMap {
            makeUser(from: $0, currentUserID: currentUserID)
        }
        let resolvedUsers: [ChatUser]
        if loadAvatars {
            resolvedUsers = await usersByLoadingAvatars(parsedUsers)
        } else {
            resolvedUsers = parsedUsers
        }
        let users = resolvedUsers.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        for user in users { knownUsersByID[user.id] = user }
        return users
    }

    public func listConversations() async throws -> [ChatConversation] {
        let users = try await call(DsmAPIName.chatUser, method: "list", parameters: [:])
        let channels = try await call(DsmAPIName.chatChannel, method: "list", parameters: [:])
        let currentUserID = currentUserID(from: users)
        cachedCurrentUserID = currentUserID ?? cachedCurrentUserID
        let names = userValues(from: users).reduce(into: [String: String]()) { result, value in
            guard let user = makeUser(from: value, currentUserID: currentUserID) else { return }
            result[user.id] = user.displayName
            knownUsersByID[user.id] = user
        }
        return channels.array(for: "channels").compactMap {
            makeConversation(from: $0, userNames: names, currentUserID: currentUserID)
        }
        .sorted {
            ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
    }

    public func listConversationMembers(conversationID: String) async throws -> [ChatUser] {
        let normalizedID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { throw ChatContractError.emptyConversationID }
        let payload = try await call(
            DsmAPIName.chatChannelMember,
            method: "get",
            parameters: ["channel_id": .string(normalizedID)],
            version: 1
        )
        let object = payload.objectValue ?? [:]
        let brokenMemberIDs = Set(
            object.array(for: "broken_user_ids").compactMap(\.stringValue)
        )
        let memberIDs = object.array(for: "user_ids")
            .compactMap(\.stringValue)
            .filter { !brokenMemberIDs.contains($0) }
        guard !memberIDs.isEmpty else { return [] }
        let missingIDs = memberIDs.filter { knownUsersByID[$0] == nil }
        if !missingIDs.isEmpty {
            _ = try await listUsers(loadAvatars: false)
        }
        return memberIDs.compactMap { knownUsersByID[$0] }
    }

    public func listPinnedMessages(conversationID: String) async throws -> [ChatMessage] {
        let normalizedID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { throw ChatContractError.emptyConversationID }
        let payload = try await call(
            DsmAPIName.chatPost,
            method: "search",
            parameters: [
                "channel_id": .string(normalizedID),
                "offset": .integer(0),
                "limit": .integer(100),
                "has": .stringArray(["pin"]),
                "sort_by": .string("last_pin_at"),
                "sort_by_array": .stringArray(["is_sticky", "last_pin_at"])
            ],
            version: 5
        )
        let values = payload.array(for: "search_results").isEmpty
            ? payload.array(for: "posts")
            : payload.array(for: "search_results")
        return values.compactMap {
            makeMessage(from: $0, fallbackConversationID: normalizedID)
        }
        .filter(\.isPinned)
        .sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
    }

    public func setMessagePinned(
        conversationID: String,
        messageID: String,
        isPinned: Bool,
        clientRequestID: UUID
    ) async throws {
        if completedPinChanges.contains(clientRequestID) { return }
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedConversationID.isEmpty else { throw ChatContractError.emptyConversationID }
        guard !normalizedMessageID.isEmpty else {
            throw AppError(
                category: .notFound,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.9a0677d885f715fd")
            )
        }
        try await callVoid(
            DsmAPIName.chatPost,
            method: isPinned ? "pin" : "unpin",
            parameters: ["post_id": .string(normalizedMessageID)],
            version: 5
        )
        let pinnedMessages = try await listPinnedMessages(conversationID: normalizedConversationID)
        guard pinnedMessages.contains(where: { $0.id == normalizedMessageID }) == isPinned else {
            throw AppError(
                category: .partialFailure,
                isRetryable: true,
                safeUserMessage: isPinned
                    ? L10n.string("shared.1d62e7d6335efb1d")
                    : L10n.string("shared.13594aba892f3da9")
            )
        }
        completedPinChanges.insert(clientRequestID)
    }

    public func forwardMessage(
        messageID: String,
        toConversationIDs: [String],
        clientRequestID: UUID
    ) async throws {
        if completedMessageForwards.contains(clientRequestID) { return }
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetIDs = Array(Set(toConversationIDs.compactMap { value -> String? in
            let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        })).sorted()
        guard !normalizedMessageID.isEmpty else {
            throw AppError(
                category: .notFound,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.9c54e8bb76140412")
            )
        }
        guard !targetIDs.isEmpty else { throw ChatContractError.emptyConversationID }
        let numericTargetIDs = try targetIDs.map { id -> Int in
            guard let value = Int(id) else {
                throw AppError(
                    category: .invalidResponse,
                    isRetryable: false,
                    safeUserMessage: L10n.string("shared.555f70678d804174")
                )
            }
            return value
        }
        try await callVoid(
            DsmAPIName.chatPost,
            method: "forward",
            parameters: [
                "post_id": .string(normalizedMessageID),
                "channel_ids": .integerArray(numericTargetIDs)
            ],
            version: 5
        )
        completedMessageForwards.insert(clientRequestID)
    }

    public func listMessages(
        conversationID: String,
        before cursor: String?,
        limit: Int
    ) async throws -> ChatMessagePage {
        let safeLimit = min(max(limit, 1), 100)
        let offset = max(Int(cursor ?? "0") ?? 0, 0)
        let payload = try await call(
            DsmAPIName.chatPost,
            method: "list",
            parameters: [
                "channel_id": .string(conversationID),
                "limit": .integer(safeLimit),
                "offset": .integer(offset)
            ]
        )
        let postValues = payload.array(for: "posts")
        let messages = postValues.compactMap {
            makeMessage(from: $0, fallbackConversationID: conversationID)
        }
        .sorted { $0.sentAt < $1.sentAt }
        let total = payload.objectValue?.firstInt(for: ["total"])
        // 游标按服务器原始记录数推进；部分附件操作会附带不可展示的辅助记录。
        let nextOffset = offset + postValues.count
        let hasMore = total.map { nextOffset < $0 } ?? (postValues.count == safeLimit)
        return ChatMessagePage(
            messages: messages,
            previousCursor: hasMore ? String(nextOffset) : nil,
            hasMoreBefore: hasMore
        )
    }

    public func openDirectConversation(
        userID: String,
        clientRequestID: UUID
    ) async throws -> ChatConversation {
        let outcome = try await openDirectConversationResult(
            userID: userID,
            clientRequestID: clientRequestID
        )
        return try confirmedConversation(from: outcome)
    }

    public func openDirectConversationResult(
        userID: String,
        clientRequestID: UUID
    ) async throws -> ChatConversationCreateOutcome {
        await acquireConversationCreatePermit()
        defer { releaseConversationCreatePermit() }
        if Task.isCancelled {
            return try conversationCreateCancelledBeforeSubmission(
                operation: "chatDirectConversationCreate",
                requestID: clientRequestID
            )
        }
        let normalizedID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            return try conversationCreateFailure(
                operation: "chatDirectConversationCreate",
                requestID: clientRequestID,
                category: .validation,
                tag: "chat.direct-create.invalid-user"
            )
        }
        guard directConversationDrafts[clientRequestID].map({ $0 == normalizedID }) ?? true else {
            return try conversationCreateFailure(
                operation: "chatDirectConversationCreate",
                requestID: clientRequestID,
                category: .validation,
                tag: "chat.direct-create.draft-mismatch"
            )
        }
        directConversationDrafts[clientRequestID] = normalizedID
        if let terminal = terminalDirectConversationOutcomes[clientRequestID] { return terminal }
        if let completed = completedDirectConversations[clientRequestID] {
            return try conversationCreateSuccess(
                operation: "chatDirectConversationCreate",
                requestID: clientRequestID,
                conversation: completed
            )
        }
        if let pending = pendingDirectConversations[clientRequestID] {
            return try await finishPendingDirectConversation(pending)
        }
        guard supportsFormCapability(DsmAPIName.chatChannelAnonymous, version: 2) else {
            return try conversationCreateUnsupported(
                operation: "chatDirectConversationCreate",
                requestID: clientRequestID,
                tag: "chat.direct-create.unsupported"
            )
        }

        let users: [ChatUser]
        do {
            users = try await listUsers(loadAvatars: false)
        } catch {
            if isCancellationError(error) {
                return try conversationCreateCancelledBeforeSubmission(
                    operation: "chatDirectConversationCreate",
                    requestID: clientRequestID
                )
            }
            throw error
        }
        guard users.contains(where: { $0.id == normalizedID && !$0.isDisabled && $0.isCurrentUser != true }) else {
            return try conversationCreateFailure(
                operation: "chatDirectConversationCreate",
                requestID: clientRequestID,
                category: .validation,
                tag: "chat.direct-create.user-unavailable"
            )
        }
        let conversations: [ChatConversation]
        do {
            conversations = try await listConversations()
        } catch {
            if isCancellationError(error) {
                return try conversationCreateCancelledBeforeSubmission(
                    operation: "chatDirectConversationCreate",
                    requestID: clientRequestID
                )
            }
            throw error
        }
        if let existing = directConversation(in: conversations, userID: normalizedID) {
            completedDirectConversations[clientRequestID] = existing
            return try conversationCreateSuccess(
                operation: "chatDirectConversationCreate",
                requestID: clientRequestID,
                conversation: existing
            )
        }

        pendingDirectConversations[clientRequestID] = PendingDirectConversationCreate(
            requestID: clientRequestID,
            userID: normalizedID
        )
        do {
            _ = try await callRaw(
                DsmAPIName.chatChannelAnonymous,
                method: "initiate",
                parameters: [
                    "user_ids": .stringArray([normalizedID]),
                    "encrypted": .boolean(false),
                    "channel_key_encs": .string("[]")
                ],
                version: 2
            )
            return try await finishPendingDirectConversation(
                PendingDirectConversationCreate(requestID: clientRequestID, userID: normalizedID)
            )
        } catch let error as DsmNetworkError {
            if isExplicitWriteRejection(error) {
                pendingDirectConversations[clientRequestID] = nil
                let outcome = try conversationCreateRejection(
                    error,
                    operation: "chatDirectConversationCreate",
                    requestID: clientRequestID,
                    candidate: nil,
                    tagPrefix: "chat.direct-create"
                )
                terminalDirectConversationOutcomes[clientRequestID] = outcome
                return outcome
            }
            return try conversationCreateUnknown(
                operation: "chatDirectConversationCreate",
                requestID: clientRequestID,
                cancelled: isCancellation(error),
                candidate: nil,
                tag: "chat.direct-create.submit-unknown"
            )
        }
    }

    public func createGroup(_ draft: ChatGroupDraft) async throws -> ChatConversation {
        let outcome = try await createGroupResult(draft)
        return try confirmedConversation(from: outcome)
    }

    public func createGroupResult(_ draft: ChatGroupDraft) async throws -> ChatConversationCreateOutcome {
        await acquireConversationCreatePermit()
        defer { releaseConversationCreatePermit() }
        if Task.isCancelled {
            return try conversationCreateCancelledBeforeSubmission(
                operation: "chatGroupCreate",
                requestID: draft.clientRequestID
            )
        }
        guard groupConversationDrafts[draft.clientRequestID].map({ $0 == draft }) ?? true else {
            return try conversationCreateFailure(
                operation: "chatGroupCreate",
                requestID: draft.clientRequestID,
                category: .validation,
                tag: "chat.group-create.draft-mismatch"
            )
        }
        groupConversationDrafts[draft.clientRequestID] = draft
        if let terminal = terminalGroupConversationOutcomes[draft.clientRequestID] { return terminal }
        if let completed = completedGroups[draft.clientRequestID] {
            return try conversationCreateSuccess(
                operation: "chatGroupCreate",
                requestID: draft.clientRequestID,
                conversation: completed
            )
        }
        if let pending = pendingGroupConversations[draft.clientRequestID] {
            return try await finishPendingGroupConversation(pending)
        }
        guard !draft.isEncrypted else {
            return try conversationCreateUnsupported(
                operation: "chatGroupCreate",
                requestID: draft.clientRequestID,
                tag: "chat.group-create.encryption-unsupported"
            )
        }
        guard supportsFormCapability(DsmAPIName.chatChannelNamed, version: 1),
              supportsFormCapability(DsmAPIName.chatChannelMember, version: 1) else {
            return try conversationCreateUnsupported(
                operation: "chatGroupCreate",
                requestID: draft.clientRequestID,
                tag: "chat.group-create.unsupported"
            )
        }

        let users: [ChatUser]
        do {
            users = try await listUsers(loadAvatars: false)
        } catch {
            if isCancellationError(error) {
                return try conversationCreateCancelledBeforeSubmission(
                    operation: "chatGroupCreate",
                    requestID: draft.clientRequestID
                )
            }
            throw error
        }
        let selectableIDs = Set(users.filter { !$0.isDisabled && $0.isCurrentUser != true }.map(\.id))
        guard Set(draft.memberIDs).isSubset(of: selectableIDs) else {
            return try conversationCreateFailure(
                operation: "chatGroupCreate",
                requestID: draft.clientRequestID,
                category: .validation,
                tag: "chat.group-create.member-unavailable"
            )
        }
        let conversations: [ChatConversation]
        let existing: ChatConversation?
        do {
            conversations = try await listConversations()
            existing = try await matchingGroup(in: conversations, draft: draft)
        } catch {
            if isCancellationError(error) {
                return try conversationCreateCancelledBeforeSubmission(
                    operation: "chatGroupCreate",
                    requestID: draft.clientRequestID
                )
            }
            throw error
        }
        if let existing {
            completedGroups[draft.clientRequestID] = existing
            return try conversationCreateSuccess(
                operation: "chatGroupCreate",
                requestID: draft.clientRequestID,
                conversation: existing
            )
        }

        let named = try requireCapability(DsmAPIName.chatChannelNamed)
        var pending = PendingGroupConversationCreate(draft: draft, candidateID: nil)
        pendingGroupConversations[draft.clientRequestID] = pending
        do {
            let created = try await client.call(
                path: named.path,
                api: named.name,
                version: try selectedVersion(named, requiring: 1),
                method: "create",
                requestFormat: .form,
                parameters: ["name": .string(draft.title), "type": .string("private")],
                credential: credential,
                as: ChatJSON.self
            )
            guard let channelID = created.objectValue?.firstString(for: ["channel_id", "id"]) else {
                return try conversationCreateUnknown(
                    operation: "chatGroupCreate",
                    requestID: draft.clientRequestID,
                    cancelled: false,
                    candidate: nil,
                    tag: "chat.group-create.missing-candidate"
                )
            }
            pending = PendingGroupConversationCreate(draft: draft, candidateID: channelID)
            pendingGroupConversations[draft.clientRequestID] = pending
            do {
                try await client.callVoid(
                    path: named.path,
                    api: named.name,
                    version: 1,
                    method: "join",
                    requestFormat: .form,
                    parameters: ["channel_id": .string(channelID)],
                    credential: credential
                )
            } catch let error as DsmNetworkError {
                if case .api(let code, _) = error, code == 117 {
                    // 117 表示创建者已经在群聊中，可继续邀请成员。
                } else {
                    return try groupStageFailure(error, pending: pending, stage: "join")
                }
            }
            do {
                try await client.callVoid(
                    path: named.path,
                    api: named.name,
                    version: 1,
                    method: "invite",
                    requestFormat: .form,
                    parameters: [
                        "channel_id": .string(channelID),
                        "user_ids": .stringArray(draft.memberIDs),
                        "channel_key_encs": .string("[]")
                    ],
                    credential: credential
                )
            } catch let error as DsmNetworkError {
                return try groupStageFailure(error, pending: pending, stage: "invite")
            }
            return try await finishPendingGroupConversation(pending)
        } catch let error as DsmNetworkError {
            if isExplicitWriteRejection(error) {
                pendingGroupConversations[draft.clientRequestID] = nil
                let outcome = try conversationCreateRejection(
                    error,
                    operation: "chatGroupCreate",
                    requestID: draft.clientRequestID,
                    candidate: nil,
                    tagPrefix: "chat.group-create"
                )
                terminalGroupConversationOutcomes[draft.clientRequestID] = outcome
                return outcome
            }
            return try conversationCreateUnknown(
                operation: "chatGroupCreate",
                requestID: draft.clientRequestID,
                cancelled: isCancellation(error),
                candidate: nil,
                tag: "chat.group-create.submit-unknown"
            )
        }
    }

    private func finishPendingDirectConversation(
        _ pending: PendingDirectConversationCreate
    ) async throws -> ChatConversationCreateOutcome {
        do {
            let conversations = try await listConversations()
            guard let confirmed = directConversation(in: conversations, userID: pending.userID) else {
                return try conversationCreateUnknown(
                    operation: "chatDirectConversationCreate",
                    requestID: pending.requestID,
                    cancelled: false,
                    candidate: nil,
                    tag: "chat.direct-create.readback-pending"
                )
            }
            let requestID = pending.requestID
            pendingDirectConversations[requestID] = nil
            completedDirectConversations[requestID] = confirmed
            return try conversationCreateSuccess(
                operation: "chatDirectConversationCreate",
                requestID: requestID,
                conversation: confirmed
            )
        } catch {
            return try conversationCreateUnknown(
                operation: "chatDirectConversationCreate",
                requestID: pending.requestID,
                cancelled: isCancellationError(error),
                candidate: nil,
                tag: "chat.direct-create.readback-failed"
            )
        }
    }

    private func acquireConversationCreatePermit() async {
        guard isCreatingConversation else {
            isCreatingConversation = true
            return
        }
        await withCheckedContinuation { continuation in
            conversationCreateWaiters.append(continuation)
        }
    }

    private func releaseConversationCreatePermit() {
        guard !conversationCreateWaiters.isEmpty else {
            isCreatingConversation = false
            return
        }
        conversationCreateWaiters.removeFirst().resume()
    }

    private func finishPendingGroupConversation(
        _ pending: PendingGroupConversationCreate
    ) async throws -> ChatConversationCreateOutcome {
        do {
            let conversations = try await listConversations()
            let candidates = conversations.filter { conversation in
                conversation.kind == .group
                    && (pending.candidateID.map { conversation.id == $0 }
                        ?? (conversation.title == pending.draft.title))
            }
            for candidate in candidates {
                let members = try await listConversationMembers(conversationID: candidate.id)
                if Set(pending.draft.memberIDs).isSubset(of: Set(members.map(\.id))) {
                    pendingGroupConversations[pending.draft.clientRequestID] = nil
                    completedGroups[pending.draft.clientRequestID] = candidate
                    return try conversationCreateSuccess(
                        operation: "chatGroupCreate",
                        requestID: pending.draft.clientRequestID,
                        conversation: candidate
                    )
                }
            }
            return try conversationCreateUnknown(
                operation: "chatGroupCreate",
                requestID: pending.draft.clientRequestID,
                cancelled: false,
                candidate: nil,
                tag: "chat.group-create.readback-pending"
            )
        } catch {
            return try conversationCreateUnknown(
                operation: "chatGroupCreate",
                requestID: pending.draft.clientRequestID,
                cancelled: isCancellationError(error),
                candidate: nil,
                tag: "chat.group-create.readback-failed"
            )
        }
    }

    private func matchingGroup(
        in conversations: [ChatConversation],
        draft: ChatGroupDraft
    ) async throws -> ChatConversation? {
        for conversation in conversations where conversation.kind == .group && conversation.title == draft.title {
            let members = try await listConversationMembers(conversationID: conversation.id)
            if Set(draft.memberIDs).isSubset(of: Set(members.map(\.id))) {
                return conversation
            }
        }
        return nil
    }

    private func directConversation(
        in conversations: [ChatConversation],
        userID: String
    ) -> ChatConversation? {
        conversations.first { $0.kind == .direct && $0.memberIDs.contains(userID) }
    }

    private func groupStageFailure(
        _ error: DsmNetworkError,
        pending: PendingGroupConversationCreate,
        stage: String
    ) throws -> ChatConversationCreateOutcome {
        if isExplicitWriteRejection(error) {
            return try conversationCreateUnknown(
                operation: "chatGroupCreate",
                requestID: pending.draft.clientRequestID,
                cancelled: false,
                candidate: nil,
                errorCategory: mutationErrorCategory(for: error),
                tag: "chat.group-create.\(stage)-rejected-pending"
            )
        }
        return try conversationCreateUnknown(
            operation: "chatGroupCreate",
            requestID: pending.draft.clientRequestID,
            cancelled: isCancellation(error),
            candidate: nil,
            tag: "chat.group-create.\(stage)-unknown"
        )
    }

    private func conversationCreateSuccess(
        operation: String,
        requestID: UUID,
        conversation: ChatConversation
    ) throws -> ChatConversationCreateOutcome {
        ChatConversationCreateOutcome(
            result: try MutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 1, failed: 0, unknown: 0),
                diagnosticTag: "chat.conversation-create.confirmed"
            ),
            clientRequestID: requestID,
            confirmedConversation: conversation
        )
    }

    private func conversationCreateFailure(
        operation: String,
        requestID: UUID,
        category: MutationErrorCategory,
        tag: String
    ) throws -> ChatConversationCreateOutcome {
        ChatConversationCreateOutcome(
            result: try MutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: category,
                diagnosticTag: tag
            ),
            clientRequestID: requestID,
            confirmedConversation: nil
        )
    }

    private func conversationCreateUnsupported(
        operation: String,
        requestID: UUID,
        tag: String
    ) throws -> ChatConversationCreateOutcome {
        ChatConversationCreateOutcome(
            result: try MutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                diagnosticTag: tag
            ),
            clientRequestID: requestID,
            confirmedConversation: nil
        )
    }

    private func conversationCreateCancelledBeforeSubmission(
        operation: String,
        requestID: UUID
    ) throws -> ChatConversationCreateOutcome {
        ChatConversationCreateOutcome(
            result: try MutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 0, unknown: 0),
                diagnosticTag: "chat.conversation-create.cancelled-before-submit"
            ),
            clientRequestID: requestID,
            confirmedConversation: nil
        )
    }

    private func conversationCreateUnknown(
        operation: String,
        requestID: UUID,
        cancelled: Bool,
        candidate: ChatConversation?,
        errorCategory: MutationErrorCategory? = nil,
        tag: String
    ) throws -> ChatConversationCreateOutcome {
        ChatConversationCreateOutcome(
            result: try MutationResult(
                status: cancelled ? .cancellationRequestedAfterSubmission : .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                counts: MutationResultCounts(succeeded: 0, failed: 0, unknown: 1),
                errorCategory: errorCategory ?? (cancelled ? .network : .unknown),
                diagnosticTag: tag
            ),
            clientRequestID: requestID,
            confirmedConversation: candidate
        )
    }

    private func conversationCreateRejection(
        _ error: DsmNetworkError,
        operation: String,
        requestID: UUID,
        candidate: ChatConversation?,
        requiresRefresh: Bool = false,
        tagPrefix: String
    ) throws -> ChatConversationCreateOutcome {
        let category = mutationErrorCategory(for: error)
        let status: MutationResultStatus
        switch category {
        case .permission:
            status = .permissionDenied
        case .unsupported:
            status = .unsupported
        default:
            status = .confirmedFailure
        }
        return ChatConversationCreateOutcome(
            result: try MutationResult(
                status: status,
                operation: operation,
                submitted: true,
                requiresRefresh: requiresRefresh || candidate != nil,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: category,
                diagnosticTag: "\(tagPrefix).rejected"
            ),
            clientRequestID: requestID,
            confirmedConversation: candidate
        )
    }

    private func mutationErrorCategory(for error: DsmNetworkError) -> MutationErrorCategory {
        switch mapChatError(error).category {
        case .permissionDenied:
            .permission
        case .authenticationRequired, .otpRequired:
            .authentication
        case .apiUnavailable, .versionUnsupported:
            .unsupported
        default:
            .server
        }
    }

    private func confirmedConversation(
        from outcome: ChatConversationCreateOutcome
    ) throws -> ChatConversation {
        if outcome.result.status == .confirmedSuccess,
           let conversation = outcome.confirmedConversation {
            return conversation
        }
        let category: AppErrorCategory
        switch outcome.result.errorCategory {
        case .authentication: category = .authenticationRequired
        case .permission: category = .permissionDenied
        case .unsupported: category = .apiUnavailable
        case .validation: category = .invalidResponse
        default: category = .partialFailure
        }
        throw AppError(
            category: category,
            isRetryable: outcome.result.requiresRefresh,
            safeUserMessage: L10n.string("shared.34b76b919bd5bf65")
        )
    }

    private func isExplicitWriteRejection(_ error: DsmNetworkError) -> Bool {
        switch error {
        case .api:
            true
        case .invalidRequest, .httpStatus, .responseTooLarge, .invalidResponse, .transport, .cancelled:
            false
        }
    }

    private func isCancellation(_ error: DsmNetworkError) -> Bool {
        if case .cancelled = error { return true }
        return false
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? AppError)?.category == .cancelled
    }

    public func sendMessage(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessage {
        if let completed = completedMessages[draft.clientRequestID] { return completed }
        guard draft.localAttachmentURLs.count <= 1 else {
            throw unsupported(L10n.string("shared.fa24cc9d55caa0ef"))
        }
        if let localURL = draft.localAttachmentURLs.first {
            if let pending = pendingAttachmentSends[draft.clientRequestID] {
                let outcome = try await finishPendingChatAttachmentSend(pending)
                guard outcome.result.status == .confirmedSuccess,
                      let message = outcome.confirmedMessage else {
                    throw AppError(
                        category: outcome.result.status == .unsupported ? .apiUnavailable : .partialFailure,
                        isRetryable: outcome.result.status != .submittedButUnverified,
                        safeUserMessage: L10n.string("shared.f975fe7c14e442cf")
                    )
                }
                return message
            }
            let uploaded = try await uploadAttachment(
                localURL: localURL,
                draft: draft,
                progress: progress
            )
            completedMessages[draft.clientRequestID] = uploaded
            return uploaded
        }
        let outcome = try await sendMessageResult(draft, progress: progress)
        guard outcome.result.status == .confirmedSuccess,
              let message = outcome.confirmedMessage else {
            throw AppError(
                category: outcome.result.status == .unsupported ? .apiUnavailable : .partialFailure,
                isRetryable: outcome.result.status != .submittedButUnverified,
                safeUserMessage: L10n.string("shared.f975fe7c14e442cf")
            )
        }
        return message
    }

    public func sendMessageResult(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessageSendOutcome {
        if let completed = completedMessages[draft.clientRequestID] {
            return try chatTextOutcome(
                status: .confirmedSuccess,
                submitted: true,
                succeeded: 1,
                diagnosticTag: "chat.text-send.confirmed",
                draft: draft,
                message: completed
            )
        }
        guard draft.localAttachmentURLs.isEmpty else {
            return try chatTextOutcome(
                status: .unsupported,
                submitted: false,
                failed: 1,
                errorCategory: .unsupported,
                diagnosticTag: "chat.text-send.attachments-unsupported",
                draft: draft
            )
        }
        guard draft.text != nil else {
            return try chatTextOutcome(
                status: .confirmedFailure,
                submitted: false,
                failed: 1,
                errorCategory: .validation,
                diagnosticTag: "chat.text-send.empty",
                draft: draft
            )
        }
        guard supportsVersion(DsmAPIName.chatPost, version: 5) else {
            return try chatTextOutcome(
                status: .unsupported,
                submitted: false,
                failed: 1,
                errorCategory: .unsupported,
                diagnosticTag: "chat.text-send.version-unsupported",
                draft: draft
            )
        }
        if let pending = pendingMessageSends[draft.clientRequestID] {
            return try await finishPendingChatTextSend(pending)
        }
        if Task.isCancelled {
            return try chatTextOutcome(
                status: .cancelledBeforeSubmission,
                submitted: false,
                diagnosticTag: "chat.text-send.cancelled-before-submit",
                draft: draft
            )
        }

        do {
            let payload = try await call(
                DsmAPIName.chatPost,
                method: "create",
                parameters: [
                    "channel_id": .string(draft.conversationID),
                    "message": .string(draft.text ?? "")
                ],
                version: 5
            )
            guard let pending = makePendingChatTextSend(from: payload, draft: draft) else {
                let review = PendingChatMessageSendReview(draft: draft, candidateMessageID: nil)
                pendingMessageSends[draft.clientRequestID] = review
                return try chatTextOutcome(
                    status: .submittedButUnverified,
                    submitted: true,
                    requiresRefresh: true,
                    unknown: 1,
                    errorCategory: .server,
                    diagnosticTag: "chat.text-send.missing-id",
                    draft: draft
                )
            }
            pendingMessageSends[draft.clientRequestID] = pending
            return try await finishPendingChatTextSend(pending)
        } catch let error as AppError where error.category == .permissionDenied {
            return try chatTextOutcome(
                status: .permissionDenied,
                submitted: true,
                failed: 1,
                errorCategory: .permission,
                diagnosticTag: "chat.text-send.permission",
                draft: draft
            )
        } catch let error as AppError where error.category == .cancelled {
            let review = PendingChatMessageSendReview(draft: draft, candidateMessageID: nil)
            pendingMessageSends[draft.clientRequestID] = review
            return try chatTextOutcome(
                status: .cancellationRequestedAfterSubmission,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                errorCategory: .network,
                diagnosticTag: "chat.text-send.cancelled-after-submit",
                draft: draft
            )
        } catch is CancellationError {
            let review = PendingChatMessageSendReview(draft: draft, candidateMessageID: nil)
            pendingMessageSends[draft.clientRequestID] = review
            return try chatTextOutcome(
                status: .cancellationRequestedAfterSubmission,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                errorCategory: .network,
                diagnosticTag: "chat.text-send.cancelled-after-submit",
                draft: draft
            )
        } catch {
            let review = PendingChatMessageSendReview(draft: draft, candidateMessageID: nil)
            pendingMessageSends[draft.clientRequestID] = review
            return try chatTextOutcome(
                status: .submittedButUnverified,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                errorCategory: .unknown,
                diagnosticTag: "chat.text-send.unverified",
                draft: draft
            )
        }
    }

    public func sendAttachmentMessageResult(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessageSendOutcome {
        if let completed = completedMessages[draft.clientRequestID] {
            return try chatAttachmentOutcome(
                status: .confirmedSuccess,
                submitted: true,
                succeeded: 1,
                diagnosticTag: "chat.attachment-send.confirmed",
                draft: draft,
                message: completed
            )
        }
        guard draft.localAttachmentURLs.count == 1 else {
            return try chatAttachmentOutcome(
                status: .unsupported,
                submitted: false,
                failed: 1,
                errorCategory: .unsupported,
                diagnosticTag: "chat.attachment-send.single-file-required",
                draft: draft
            )
        }
        if let pending = pendingAttachmentSends[draft.clientRequestID] {
            return try await finishPendingChatAttachmentSend(pending)
        }
        guard supportsAttachmentUpload else {
            return try chatAttachmentOutcome(
                status: .unsupported,
                submitted: false,
                failed: 1,
                errorCategory: .unsupported,
                diagnosticTag: "chat.attachment-send.version-unsupported",
                draft: draft
            )
        }
        if Task.isCancelled {
            return try chatAttachmentOutcome(
                status: .cancelledBeforeSubmission,
                submitted: false,
                diagnosticTag: "chat.attachment-send.cancelled-before-submit",
                draft: draft
            )
        }

        // 先保留请求标识，避免并发调用在 multipart 构建或上传期间重复提交。
        pendingAttachmentSends[draft.clientRequestID] = PendingChatAttachmentSendReview(
            draft: draft,
            candidateMessageID: nil,
            expectedFileName: draft.localAttachmentURLs[0].lastPathComponent,
            expectedFileSize: nil
        )
        let submissionState = ChatAttachmentSubmissionState()
        do {
            let receipt = try await uploadAttachmentReceipt(
                localURL: draft.localAttachmentURLs[0],
                draft: draft,
                progress: progress,
                submissionState: submissionState
            )
            let pending = PendingChatAttachmentSendReview(
                draft: draft,
                candidateMessageID: receipt.candidateMessageID,
                expectedFileName: receipt.localFileName,
                expectedFileSize: receipt.localFileSize
            )
            pendingAttachmentSends[draft.clientRequestID] = pending
            guard pending.candidateMessageID != nil else {
                return try chatAttachmentOutcome(
                    status: .submittedButUnverified,
                    submitted: true,
                    requiresRefresh: true,
                    unknown: 1,
                    errorCategory: .server,
                    diagnosticTag: "chat.attachment-send.missing-id",
                    draft: draft
                )
            }
            return try await finishPendingChatAttachmentSend(pending)
        } catch {
            let appError = error as? AppError
            let isCancellation = error is CancellationError || appError?.category == .cancelled

            guard submissionState.hasStarted else {
                pendingAttachmentSends[draft.clientRequestID] = nil
                if isCancellation || Task.isCancelled {
                    return try chatAttachmentOutcome(
                        status: .cancelledBeforeSubmission,
                        submitted: false,
                        diagnosticTag: "chat.attachment-send.cancelled-before-submit",
                        draft: draft
                    )
                }
                if appError?.category == .apiUnavailable {
                    return try chatAttachmentOutcome(
                        status: .unsupported,
                        submitted: false,
                        failed: 1,
                        errorCategory: .unsupported,
                        diagnosticTag: "chat.attachment-send.unsupported",
                        draft: draft
                    )
                }
                if appError?.category == .permissionDenied {
                    return try chatAttachmentOutcome(
                        status: .permissionDenied,
                        submitted: false,
                        failed: 1,
                        errorCategory: .permission,
                        diagnosticTag: "chat.attachment-send.local-permission",
                        draft: draft
                    )
                }
                return try chatAttachmentOutcome(
                    status: .confirmedFailure,
                    submitted: false,
                    failed: 1,
                    errorCategory: .unknown,
                    diagnosticTag: "chat.attachment-send.prepare-failed",
                    draft: draft
                )
            }

            if appError?.category == .permissionDenied {
                pendingAttachmentSends[draft.clientRequestID] = nil
                return try chatAttachmentOutcome(
                    status: .permissionDenied,
                    submitted: true,
                    failed: 1,
                    errorCategory: .permission,
                    diagnosticTag: "chat.attachment-send.permission",
                    draft: draft
                )
            }

            let pending = PendingChatAttachmentSendReview(
                draft: draft,
                candidateMessageID: nil,
                expectedFileName: draft.localAttachmentURLs[0].lastPathComponent,
                expectedFileSize: nil
            )
            pendingAttachmentSends[draft.clientRequestID] = pending
            if isCancellation {
                return try chatAttachmentOutcome(
                    status: .cancellationRequestedAfterSubmission,
                    submitted: true,
                    requiresRefresh: true,
                    unknown: 1,
                    errorCategory: .network,
                    diagnosticTag: "chat.attachment-send.cancelled-after-submit",
                    draft: draft
                )
            }
            return try chatAttachmentOutcome(
                status: .submittedButUnverified,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                errorCategory: .unknown,
                diagnosticTag: "chat.attachment-send.unverified",
                draft: draft
            )
        }
    }

    private func makePendingChatTextSend(
        from payload: ChatJSON,
        draft: ChatMessageDraft
    ) -> PendingChatMessageSendReview? {
        let candidate = makeMessage(from: payload, fallbackConversationID: draft.conversationID)
        let candidateID = candidate?.id ?? payload.objectValue?.firstString(for: ["post_id", "id"])
        guard let candidateID, !candidateID.isEmpty else { return nil }
        return PendingChatMessageSendReview(draft: draft, candidateMessageID: candidateID)
    }

    private func finishPendingChatTextSend(
        _ pending: PendingChatMessageSendReview
    ) async throws -> ChatMessageSendOutcome {
        guard let candidateID = pending.candidateMessageID else {
            return try chatTextOutcome(
                status: .submittedButUnverified,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                errorCategory: .unknown,
                diagnosticTag: "chat.text-send.review-pending",
                draft: pending.draft
            )
        }
        do {
            let page = try await listMessages(
                conversationID: pending.draft.conversationID,
                before: nil,
                limit: 50
            )
            guard let confirmed = page.messages.first(where: {
                isConfirmedChatTextMessage($0, pending: pending, candidateID: candidateID)
            }) else {
                return try chatTextOutcome(
                    status: .submittedButUnverified,
                    submitted: true,
                    requiresRefresh: true,
                    unknown: 1,
                    errorCategory: .unknown,
                    diagnosticTag: "chat.text-send.readback-mismatch",
                    draft: pending.draft
                )
            }
            let result = confirmedSentMessage(confirmed, draft: pending.draft)
            pendingMessageSends[pending.draft.clientRequestID] = nil
            completedMessages[pending.draft.clientRequestID] = result
            return try chatTextOutcome(
                status: .confirmedSuccess,
                submitted: true,
                succeeded: 1,
                diagnosticTag: "chat.text-send.confirmed",
                draft: pending.draft,
                message: result
            )
        } catch let error as AppError where error.category == .permissionDenied {
            return try chatTextOutcome(
                status: .permissionDenied,
                submitted: true,
                failed: 1,
                errorCategory: .permission,
                diagnosticTag: "chat.text-send.readback-permission",
                draft: pending.draft
            )
        } catch {
            return try chatTextOutcome(
                status: .submittedButUnverified,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                errorCategory: .unknown,
                diagnosticTag: "chat.text-send.readback-failed",
                draft: pending.draft
            )
        }
    }

    private func isConfirmedChatTextMessage(
        _ message: ChatMessage,
        pending: PendingChatMessageSendReview,
        candidateID: String
    ) -> Bool {
        message.id == candidateID &&
            message.conversationID == pending.draft.conversationID &&
            message.isFromCurrentUser == true &&
            message.text == pending.draft.text
    }

    private func confirmedSentMessage(
        _ message: ChatMessage,
        draft: ChatMessageDraft
    ) -> ChatMessage {
        ChatMessage(
            id: message.id,
            clientRequestID: draft.clientRequestID,
            conversationID: message.conversationID,
            senderID: message.senderID,
            senderDisplayName: message.senderDisplayName,
            isFromCurrentUser: true,
            sentAt: message.sentAt,
            text: message.text ?? draft.text,
            attachments: message.attachments,
            poll: message.poll,
            deliveryState: .sent,
            encryptionState: message.encryptionState,
            pinnedAt: message.pinnedAt
        )
    }

    private func chatTextOutcome(
        status: MutationResultStatus,
        submitted: Bool,
        requiresRefresh: Bool = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = nil,
        diagnosticTag: String,
        draft: ChatMessageDraft,
        message: ChatMessage? = nil
    ) throws -> ChatMessageSendOutcome {
        ChatMessageSendOutcome(
            result: try MutationResult(
                status: status,
                operation: "chatTextSend",
                submitted: submitted,
                requiresRefresh: requiresRefresh,
                counts: MutationResultCounts(
                    succeeded: succeeded,
                    failed: failed,
                    unknown: unknown
                ),
                errorCategory: errorCategory,
                diagnosticTag: diagnosticTag
            ),
            conversationID: draft.conversationID,
            clientRequestID: draft.clientRequestID,
            confirmedMessage: message
        )
    }

    /// 附件提交的确认必须来自稳定 post 标识的回读，不能以正文或时间推测成功。
    private func finishPendingChatAttachmentSend(
        _ pending: PendingChatAttachmentSendReview
    ) async throws -> ChatMessageSendOutcome {
        guard let candidateID = pending.candidateMessageID else {
            return try chatAttachmentOutcome(
                status: .submittedButUnverified,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                errorCategory: .unknown,
                diagnosticTag: "chat.attachment-send.review-pending",
                draft: pending.draft
            )
        }
        do {
            let page = try await listMessages(
                conversationID: pending.draft.conversationID,
                before: nil,
                limit: 50
            )
            guard let confirmed = page.messages.first(where: {
                isConfirmedChatAttachmentMessage($0, pending: pending, candidateID: candidateID)
            }) else {
                return try chatAttachmentOutcome(
                    status: .submittedButUnverified,
                    submitted: true,
                    requiresRefresh: true,
                    unknown: 1,
                    errorCategory: .unknown,
                    diagnosticTag: "chat.attachment-send.readback-mismatch",
                    draft: pending.draft
                )
            }
            let result = confirmedSentMessage(confirmed, draft: pending.draft)
            pendingAttachmentSends[pending.draft.clientRequestID] = nil
            completedMessages[pending.draft.clientRequestID] = result
            return try chatAttachmentOutcome(
                status: .confirmedSuccess,
                submitted: true,
                succeeded: 1,
                diagnosticTag: "chat.attachment-send.confirmed",
                draft: pending.draft,
                message: result
            )
        } catch let error as AppError where error.category == .permissionDenied {
            return try chatAttachmentOutcome(
                status: .permissionDenied,
                submitted: true,
                failed: 1,
                errorCategory: .permission,
                diagnosticTag: "chat.attachment-send.readback-permission",
                draft: pending.draft
            )
        } catch let error as AppError where error.category == .cancelled {
            return try chatAttachmentOutcome(
                status: .cancellationRequestedAfterSubmission,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                errorCategory: .network,
                diagnosticTag: "chat.attachment-send.cancelled-during-readback",
                draft: pending.draft
            )
        } catch is CancellationError {
            return try chatAttachmentOutcome(
                status: .cancellationRequestedAfterSubmission,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                errorCategory: .network,
                diagnosticTag: "chat.attachment-send.cancelled-during-readback",
                draft: pending.draft
            )
        } catch {
            return try chatAttachmentOutcome(
                status: .submittedButUnverified,
                submitted: true,
                requiresRefresh: true,
                unknown: 1,
                errorCategory: .unknown,
                diagnosticTag: "chat.attachment-send.readback-failed",
                draft: pending.draft
            )
        }
    }

    private func isConfirmedChatAttachmentMessage(
        _ message: ChatMessage,
        pending: PendingChatAttachmentSendReview,
        candidateID: String
    ) -> Bool {
        guard message.attachments.count == 1,
              let attachment = message.attachments.first,
              attachment.fileName == pending.expectedFileName else { return false }
        if let expectedFileSize = pending.expectedFileSize,
           attachment.sizeBytes != expectedFileSize {
            return false
        }
        return message.id == candidateID &&
            message.conversationID == pending.draft.conversationID &&
            message.isFromCurrentUser == true &&
            message.text == pending.draft.text
    }

    private func chatAttachmentOutcome(
        status: MutationResultStatus,
        submitted: Bool,
        requiresRefresh: Bool = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = nil,
        diagnosticTag: String,
        draft: ChatMessageDraft,
        message: ChatMessage? = nil
    ) throws -> ChatMessageSendOutcome {
        ChatMessageSendOutcome(
            result: try MutationResult(
                status: status,
                operation: "chatAttachmentSend",
                submitted: submitted,
                requiresRefresh: requiresRefresh,
                counts: MutationResultCounts(
                    succeeded: succeeded,
                    failed: failed,
                    unknown: unknown
                ),
                errorCategory: errorCategory,
                diagnosticTag: diagnosticTag
            ),
            conversationID: draft.conversationID,
            clientRequestID: draft.clientRequestID,
            confirmedMessage: message
        )
    }

    /// 使用 Chat Server 2.4.1-22111 官方网页客户端当前采用的内部上传契约。
    /// `SYNO.Chat.Post/create` v5 与 multipart 的 `file` 字段均不是群晖公开 API，
    /// 因此仅在运行时能力范围明确包含 v5 时启用，并保持关闭型兼容策略。
    private func uploadAttachment(
        localURL: URL,
        draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessage {
        let receipt = try await uploadAttachmentReceipt(
            localURL: localURL,
            draft: draft,
            progress: progress,
            submissionState: nil
        )
        if let message = receipt.message { return message }

        // 旧发送入口在上传响应缺少完整消息时，也只允许按稳定 post 标识回读。
        let pending = PendingChatAttachmentSendReview(
            draft: draft,
            candidateMessageID: receipt.candidateMessageID,
            expectedFileName: receipt.localFileName,
            expectedFileSize: receipt.localFileSize
        )
        pendingAttachmentSends[draft.clientRequestID] = pending
        let outcome = try await finishPendingChatAttachmentSend(pending)
        guard outcome.result.status == .confirmedSuccess,
              let message = outcome.confirmedMessage else {
            throw AppError(
                category: .partialFailure,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.05430b68cf645911")
            )
        }
        return message
    }

    private func uploadAttachmentReceipt(
        localURL: URL,
        draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress,
        submissionState: ChatAttachmentSubmissionState?
    ) async throws -> ChatAttachmentUploadReceipt {
        guard supportsAttachmentUpload else {
            throw unsupported(L10n.string("shared.45cf7cd4f9a97d94"))
        }
        guard localURL.isFileURL else {
            throw AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.8367989b81565b26")
            )
        }
        let securityScoped = localURL.startAccessingSecurityScopedResource()
        defer {
            if securityScoped { localURL.stopAccessingSecurityScopedResource() }
        }
        let values: URLResourceValues
        do {
            values = try localURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.8718d3431b4e4db8")
            )
        }
        guard values.isRegularFile == true else {
            throw AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.18c37943b50afde0")
            )
        }

        let capability = try requireCapability(DsmAPIName.chatPost)
        let boundary = "LanStash-Chat-\(UUID().uuidString)"
        let fields = [
            "api": capability.name,
            "version": "5",
            "method": "create",
            "channel_id": draft.conversationID,
            "type": "file",
            "message": draft.text ?? "",
            "is_thread": "false",
            "_sid": credential.sid,
            "SynoToken": credential.synoToken ?? "",
            "synotoken": credential.synoToken ?? ""
        ]
        let bodyURL: URL
        do {
            bodyURL = try createChatMultipartBody(
                localURL: localURL,
                boundary: boundary,
                fields: fields
            )
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError(
                category: .localStorageFull,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.b08c2bc40f69afca")
            )
        }
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        guard let binaryTransport = transport as? any DsmBinaryHTTPTransport else {
            throw unsupported(L10n.string("shared.75457fae2010a2d6"))
        }
        var uploadURL = apiURL(path: capability.path)
        if var components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false) {
            let queryItems = [
                URLQueryItem(name: "api", value: capability.name),
                URLQueryItem(name: "version", value: "5"),
                URLQueryItem(name: "method", value: "create")
            ]
            components.queryItems = queryItems
            uploadURL = components.url ?? uploadURL
        }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bodySize = try? bodyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            request.setValue(String(bodySize), forHTTPHeaderField: "Content-Length")
        }
        if let cookie = credential.cookieHeaderValue {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let token = credential.synoToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-SYNO-TOKEN")
        }

        let response: DsmHTTPResponse
        do {
            try Task.checkCancellation()
            submissionState?.markStarted()
            response = try await binaryTransport.upload(request, from: bodyURL, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DsmCertificateTrustError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw DsmErrorMapper.map(.transport(code: error.errorCode, requestID: UUID()))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw mapChatError(.httpStatus(code: response.statusCode, requestID: UUID()))
        }
        let envelope: ChatUploadEnvelope
        do {
            envelope = try JSONDecoder().decode(ChatUploadEnvelope.self, from: response.data)
        } catch {
            throw invalidChatResponse()
        }
        if let code = envelope.error?.code {
            throw mapChatError(.api(code: code, requestID: UUID()))
        }
        guard envelope.success else { throw invalidChatResponse() }

        let parsed = envelope.data.flatMap {
            makeMessage(from: $0, fallbackConversationID: draft.conversationID)
        }
        let rawCandidateMessageID = parsed?.id
            ?? envelope.data?.objectValue?.firstString(for: ["post_id", "id"])
        let candidateMessageID = rawCandidateMessageID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stableCandidateMessageID = candidateMessageID?.isEmpty == false ? candidateMessageID : nil
        let localFileSize = values.fileSize.map(Int64.init)
        let message = parsed.map { parsed in
            ChatMessage(
                id: parsed.id,
                clientRequestID: draft.clientRequestID,
                conversationID: parsed.conversationID,
                senderID: parsed.senderID,
                senderDisplayName: parsed.senderDisplayName,
                isFromCurrentUser: true,
                sentAt: parsed.sentAt,
                text: parsed.text ?? draft.text,
                attachments: parsed.attachments.isEmpty
                    ? [makeLocalAttachment(localURL: localURL, fileSize: localFileSize)]
                    : parsed.attachments,
                deliveryState: .sent,
                encryptionState: parsed.encryptionState,
                pinnedAt: parsed.pinnedAt
            )
        }
        return ChatAttachmentUploadReceipt(
            message: message,
            candidateMessageID: stableCandidateMessageID,
            localFileName: localURL.lastPathComponent,
            localFileSize: localFileSize
        )
    }

    public func deleteMessage(
        conversationID: String,
        messageID: String,
        clientRequestID: UUID
    ) async throws {
        if completedMessageDeletions.contains(clientRequestID) { return }
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedConversationID.isEmpty else { throw ChatContractError.emptyConversationID }
        guard !normalizedMessageID.isEmpty else {
            throw AppError(
                category: .notFound,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.13d2195deb6baac7")
            )
        }

        let currentPage = try await listMessages(
            conversationID: normalizedConversationID,
            before: nil,
            limit: 100
        )
        guard let message = currentPage.messages.first(where: { $0.id == normalizedMessageID }) else {
            completedMessageDeletions.insert(clientRequestID)
            return
        }
        guard isOwnedByCurrentUser(message) else {
            throw AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.66a12c2de716c8cf")
            )
        }

        // 内部 API：SYNO.Chat.Post/delete 尚无公开开发者契约，必须由能力发现和实机复查共同保护。
        try await callVoid(
            DsmAPIName.chatPost,
            method: "delete",
            parameters: ["post_id": .string(normalizedMessageID)]
        )
        let verifiedPage = try await listMessages(
            conversationID: normalizedConversationID,
            before: nil,
            limit: 100
        )
        guard !verifiedPage.messages.contains(where: { $0.id == normalizedMessageID }) else {
            throw AppError(
                category: .partialFailure,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.aacd70e29509b789")
            )
        }
        completedMessageDeletions.insert(clientRequestID)
    }

    public func closeConversation(
        conversationID: String,
        clientRequestID: UUID
    ) async throws {
        if completedConversationClosures.contains(clientRequestID) { return }
        let normalizedID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { throw ChatContractError.emptyConversationID }
        let currentConversations = try await listConversations()
        guard currentConversations.contains(where: { $0.id == normalizedID }) else {
            completedConversationClosures.insert(clientRequestID)
            return
        }

        // 内部 API：群晖客户端称此操作为“关闭会话”；消息会进入 Chat 归档而不是本地直接抹除。
        try await callVoid(
            DsmAPIName.chatChannel,
            method: "close",
            parameters: ["channel_id": .string(normalizedID)]
        )
        let verifiedConversations = try await listConversations()
        guard !verifiedConversations.contains(where: { $0.id == normalizedID }) else {
            throw AppError(
                category: .partialFailure,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.6d5ebb57592ff9fa")
            )
        }
        completedConversationClosures.insert(clientRequestID)
    }

    public func setReminder(
        messageID: String,
        remindAt: Date,
        clientRequestID: UUID
    ) async throws -> ChatReminder {
        if let completed = completedReminders[clientRequestID] { return completed }
        _ = try await call(
            DsmAPIName.chatPostReminder,
            method: "set",
            parameters: [
                "post_id": .string(messageID),
                "remind_at": .string(String(Int64(remindAt.timeIntervalSince1970 * 1_000)))
            ]
        )
        let reminder = ChatReminder(id: messageID, messageID: messageID, remindAt: remindAt)
        completedReminders[clientRequestID] = reminder
        return reminder
    }

    public func listReminders(conversationID: String) async throws -> [ChatReminder] {
        let normalizedID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { throw ChatContractError.emptyConversationID }
        let payload = try await call(
            DsmAPIName.chatPostReminder,
            method: "list",
            parameters: ["channel_id": .string(normalizedID)]
        )
        return reminderValues(from: payload).compactMap(makeReminder)
            .sorted { $0.remindAt < $1.remindAt }
    }

    public func deleteReminder(
        messageID: String,
        conversationID: String,
        clientRequestID: UUID
    ) async throws {
        if completedReminderDeletions.contains(clientRequestID) { return }
        let normalizedID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw AppError(
                category: .notFound,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.e2b9e4ad28f0f80f")
            )
        }
        // 内部 API：参数来自当前 Chat Server 官方网页客户端静态契约。
        try await callVoid(
            DsmAPIName.chatPostReminder,
            method: "delete",
            parameters: ["post_id": .string(normalizedID)]
        )
        let remaining = try await listReminders(conversationID: conversationID)
        guard !remaining.contains(where: { $0.messageID == normalizedID }) else {
            throw AppError(
                category: .partialFailure,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.1d064651a58beeb6")
            )
        }
        completedReminderDeletions.insert(clientRequestID)
    }

    public func loadAttachmentThumbnail(
        messageID: String,
        size: ChatAttachmentThumbnailSize
    ) async throws -> Data {
        let request = try attachmentRequest(
            messageID: messageID,
            method: "thumbnail",
            parameters: ["type": .string(size.rawValue)],
            accept: "image/*"
        )
        let response = try await sendAttachmentRequest(request)
        guard !response.data.isEmpty,
              response.data.count <= 10 * 1_024 * 1_024,
              Self.isImageResponse(response) else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.eb9c8d1011e2d6ba")
            )
        }
        return response.data
    }

    public func downloadAttachment(
        messageID: String,
        to destinationURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws {
        guard destinationURL.isFileURL else {
            throw AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.5c8573de7cce9571")
            )
        }
        let request = try attachmentRequest(
            messageID: messageID,
            method: "get",
            parameters: [:],
            accept: "application/octet-stream"
        )
        guard let binaryTransport = transport as? any DsmBinaryHTTPTransport else {
            throw unsupported(L10n.string("shared.2f586b376a3ea058"))
        }
        let stagingURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".lanstash-chat-\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        let response: DsmHTTPResponse
        do {
            response = try await binaryTransport.download(request, to: stagingURL, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DsmCertificateTrustError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw DsmErrorMapper.map(.transport(code: error.errorCode, requestID: UUID()))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw mapChatError(.httpStatus(code: response.statusCode, requestID: UUID()))
        }
        if Self.isJSONResponse(response) {
            throw invalidChatResponse()
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingURL.path)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagingURL)
            } else {
                try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
            }
        } catch {
            throw AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.7e9dc7f9a89fe205")
            )
        }
    }

    public func listScheduledMessages(conversationID: String) async throws -> [ChatScheduledMessage] {
        let normalizedID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { throw ChatContractError.emptyConversationID }
        let payload = try await call(
            DsmAPIName.chatPostSchedule,
            method: "list",
            parameters: ["channel_id": .string(normalizedID)]
        )
        return scheduledMessageValues(from: payload).compactMap(makeScheduledMessage)
            .sorted { $0.sendAt < $1.sendAt }
    }

    public func createScheduledMessage(
        conversationID: String,
        text: String,
        sendAt: Date,
        clientRequestID: UUID
    ) async throws -> ChatScheduledMessage {
        if let completed = completedScheduledMessages[clientRequestID] { return completed }
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedConversationID.isEmpty else { throw ChatContractError.emptyConversationID }
        guard !normalizedText.isEmpty else { throw ChatContractError.emptyMessage }
        guard sendAt > Date() else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.412848e827fc7e08")
            )
        }

        let existing = try await listScheduledMessages(conversationID: normalizedConversationID).first {
            $0.conversationID == normalizedConversationID
                && $0.text == normalizedText
                && abs($0.sendAt.timeIntervalSince(sendAt)) < 1
        }
        if let existing {
            completedScheduledMessages[clientRequestID] = existing
            return existing
        }
        let payload = try await call(
            DsmAPIName.chatPostSchedule,
            method: "create",
            parameters: [
                "channel_id": .string(normalizedConversationID),
                "message": .string(normalizedText),
                "send_at": .string(String(Int64(sendAt.timeIntervalSince1970 * 1_000)))
            ]
        )
        let parsed: ChatScheduledMessage?
        if let responseMessage = makeScheduledMessage(from: payload) {
            parsed = responseMessage
        } else {
            parsed = try await listScheduledMessages(conversationID: normalizedConversationID).first {
                $0.conversationID == normalizedConversationID
                    && $0.text == normalizedText
                    && abs($0.sendAt.timeIntervalSince(sendAt)) < 1
            }
        }
        guard let parsed else {
            throw AppError(
                category: .partialFailure,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.653720b44687243d")
            )
        }
        completedScheduledMessages[clientRequestID] = parsed
        return parsed
    }

    public func deleteScheduledMessage(
        id: String,
        conversationID: String,
        clientRequestID: UUID
    ) async throws {
        if completedScheduledMessageDeletions.contains(clientRequestID) { return }
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw AppError(
                category: .notFound,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.783c6fb80b2f8038")
            )
        }
        try await callVoid(
            DsmAPIName.chatPostSchedule,
            method: "delete",
            parameters: ["cronjob_id": .string(normalizedID)]
        )
        let remaining = try await listScheduledMessages(conversationID: conversationID)
        guard !remaining.contains(where: { $0.id == normalizedID }) else {
            throw AppError(
                category: .partialFailure,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.ee8e0d0abe0030d9")
            )
        }
        completedScheduledMessageDeletions.insert(clientRequestID)
    }

    public func createPoll(_ draft: ChatPollDraft) async throws -> ChatMessage {
        if let completed = completedMessages[draft.clientRequestID] { return completed }
        let options = try pollOptionsJSON(for: draft)
        let payload = try await call(
            DsmAPIName.chatPostVote,
            method: "create",
            parameters: [
                "channel_id": .string(draft.conversationID),
                "message": .string(draft.question),
                "choices": .stringArray(draft.options),
                "options": .string(options)
            ]
        )
        var parsed = makeMessage(from: payload, fallbackConversationID: draft.conversationID)
        if parsed == nil,
           let page = try? await listMessages(
               conversationID: draft.conversationID,
               before: nil,
               limit: 50
           ) {
            parsed = page.messages.last {
                $0.text == draft.question
                    && isOwnedByCurrentUser($0)
                    && abs($0.sentAt.timeIntervalSinceNow) <= 180
            }
        }
        guard let parsed else {
            throw AppError(
                category: .partialFailure,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.e188f125e55257f2")
            )
        }
        let poll = ChatPoll(
            id: parsed.id,
            question: draft.question,
            allowsMultipleSelection: draft.allowsMultipleSelection,
            isAnonymous: draft.isAnonymous,
            closesAt: draft.closesAt,
            options: draft.options.enumerated().map {
                ChatPollOption(id: "\(parsed.id)-choice-\($0.offset)", text: $0.element)
            }
        )
        let result = ChatMessage(
            id: parsed.id,
            clientRequestID: draft.clientRequestID,
            conversationID: parsed.conversationID,
            senderID: parsed.senderID,
            senderDisplayName: parsed.senderDisplayName,
            isFromCurrentUser: true,
            sentAt: parsed.sentAt,
            text: parsed.text ?? draft.question,
            attachments: parsed.attachments,
            poll: poll,
            deliveryState: .sent,
            encryptionState: parsed.encryptionState,
            pinnedAt: parsed.pinnedAt
        )
        completedMessages[draft.clientRequestID] = result
        return result
    }

    private func pollOptionsJSON(for draft: ChatPollDraft) throws -> String {
        guard draft.closesAt == nil else {
            throw unsupported(L10n.string("shared.adce1daf145b81a7"))
        }
        let values: [String: Any] = [
            "multiple": draft.allowsMultipleSelection,
            "anonymous": draft.isAnonymous,
            "add_option": false
        ]
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else {
            throw invalidChatResponse()
        }
        return result
    }

    private func reminderValues(from payload: ChatJSON) -> [ChatJSON] {
        if let values = payload.arrayValue { return values }
        guard let object = payload.objectValue else { return [] }
        for key in ["posts", "reminders", "reminder_list", "items", "list", "results"] {
            if let values = object[key]?.arrayValue { return values }
        }
        if object.firstString(for: ["post_id", "message_id"]) != nil {
            return [payload]
        }
        return []
    }

    private func scheduledMessageValues(from payload: ChatJSON) -> [ChatJSON] {
        if let values = payload.arrayValue { return values }
        guard let object = payload.objectValue else { return [] }
        for key in ["schedules", "schedule_posts", "scheduled_posts", "cronjobs", "items", "list", "results"] {
            if let values = object[key]?.arrayValue { return values }
        }
        if object.firstString(for: ["cronjob_id", "id"]) != nil { return [payload] }
        return []
    }

    private func makeScheduledMessage(from value: ChatJSON) -> ChatScheduledMessage? {
        guard let object = value.objectValue,
              let id = object.firstString(for: ["cronjob_id", "schedule_id", "id"]),
              let conversationID = object.firstString(for: ["channel_id", "conversation_id"]),
              let text = object.firstNonEmptyString(for: ["message", "text", "content"]),
              let rawTime = object.firstDouble(for: ["send_at", "scheduled_at", "time"]),
              let sendAt = Self.date(from: rawTime) else { return nil }
        return ChatScheduledMessage(
            id: id,
            conversationID: conversationID,
            text: text,
            sendAt: sendAt
        )
    }

    private func makeReminder(from value: ChatJSON) -> ChatReminder? {
        guard let object = value.objectValue,
              let messageID = object.firstString(for: ["post_id", "message_id"]) else { return nil }
        let props = object["props"]?.objectValue
        guard let rawTime = object.firstDouble(for: ["remind_at", "reminde_at", "reminder_at", "time"])
                ?? props?.firstDouble(for: ["remind_at", "reminde_at", "reminder_at", "time"]),
              let remindAt = Self.date(from: rawTime) else { return nil }
        return ChatReminder(
            id: object.firstString(for: ["reminder_id", "id"]) ?? messageID,
            messageID: messageID,
            remindAt: remindAt
        )
    }

    private func attachmentRequest(
        messageID: String,
        method: String,
        parameters: [String: DsmParameterValue],
        accept: String
    ) throws -> URLRequest {
        let normalizedID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw AppError(
                category: .notFound,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.db9c3774706d968a")
            )
        }
        let capability = try requireCapability(DsmAPIName.chatPostFile)
        var request = try DsmRequestBuilder.build(
            baseURL: baseURL,
            path: capability.path,
            api: capability.name,
            version: try selectedVersion(capability),
            method: method,
            requestFormat: capability.requestFormat,
            parameters: parameters.merging(["post_id": .string(normalizedID)]) { current, _ in current },
            credential: nil,
            httpMethod: "GET"
        )
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let cookie = credential.cookieHeaderValue {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let synoToken = credential.synoToken, !synoToken.isEmpty {
            request.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN")
        }
        return request
    }

    private func sendAttachmentRequest(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let response: DsmHTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as DsmCertificateTrustError {
            throw error
        } catch let error as URLError {
            throw DsmErrorMapper.map(.transport(code: error.errorCode, requestID: UUID()))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw mapChatError(.httpStatus(code: response.statusCode, requestID: UUID()))
        }
        guard !Self.isJSONResponse(response) else { throw invalidChatResponse() }
        return response
    }

    private static func isImageResponse(_ response: DsmHTTPResponse) -> Bool {
        let contentType = response.headers.first {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value.lowercased()
        return contentType?.hasPrefix("image/") == true || hasKnownImageSignature(response.data)
    }

    private static func isJSONResponse(_ response: DsmHTTPResponse) -> Bool {
        let contentType = response.headers.first {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value.lowercased()
        return contentType?.contains("json") == true
    }

    private func call(
        _ name: String,
        method: String,
        parameters: [String: DsmParameterValue],
        version: Int? = nil
    ) async throws -> ChatJSON {
        let capability = try requireCapability(name)
        do {
            return try await client.call(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability, requiring: version),
                method: method,
                requestFormat: capability.requestFormat,
                parameters: parameters,
                credential: credential,
                as: ChatJSON.self
            )
        } catch let error as DsmNetworkError {
            throw mapChatError(error)
        }
    }

    private func callRaw(
        _ name: String,
        method: String,
        parameters: [String: DsmParameterValue],
        version: Int
    ) async throws -> ChatJSON {
        let capability = try requireCapability(name)
        return try await client.call(
            path: capability.path,
            api: capability.name,
            version: try selectedVersion(capability, requiring: version),
            method: method,
            requestFormat: .form,
            parameters: parameters,
            credential: credential,
            as: ChatJSON.self
        )
    }

    /// 调用只返回成功状态、不携带 `data` 的 Chat 写操作。
    ///
    /// Chat Server 的删除消息、关闭会话等内部接口在成功时通常只返回
    /// `{ "success": true }`。若按读取接口强制解析 `data`，会在写入已经
    /// 生效后错误地向用户报告失败。
    private func callVoid(
        _ name: String,
        method: String,
        parameters: [String: DsmParameterValue],
        version: Int? = nil
    ) async throws {
        let capability = try requireCapability(name)
        do {
            try await client.callVoid(
                path: capability.path,
                api: capability.name,
                version: try selectedVersion(capability, requiring: version),
                method: method,
                requestFormat: capability.requestFormat,
                parameters: parameters,
                credential: credential
            )
        } catch let error as DsmNetworkError {
            throw mapChatError(error)
        }
    }

    private func makeConversation(
        from value: ChatJSON,
        userNames: [String: String],
        currentUserID: String?
    ) -> ChatConversation? {
        guard let object = value.objectValue,
              let id = object.firstString(for: ["channel_id", "id"]) else { return nil }
        let rawMembers = object.array(for: "members").isEmpty
            ? object.array(for: "member_ids")
            : object.array(for: "members")
        let memberIDs = rawMembers.compactMap { member in
            member.stringValue
                ?? member.objectValue?.firstString(for: ["user_id", "member_id", "id"])
        }
        let rawName = object.firstString(for: ["name", "channel_name"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let type = object.firstString(for: ["type", "channel_type"]) ?? ""
        let declaredMemberCount = object.firstInt(for: ["member_count", "members_count", "total_members"])
        let resolvedMemberCount = declaredMemberCount ?? memberIDs.count
        let normalizedType = type.lowercased()
        let isDirect = normalizedType == "direct"
            || normalizedType == "anonymous"
            || (rawName.isEmpty && resolvedMemberCount <= 2 && normalizedType != "chatbot")
        let title: String
        if !isDirect, !rawName.isEmpty {
            title = rawName
        } else {
            let otherMemberIDs = memberIDs.filter { $0 != currentUserID }
            let visibleMemberIDs = otherMemberIDs.isEmpty ? memberIDs : otherMemberIDs
            title = visibleMemberIDs.compactMap { userNames[$0] }.joined(separator: "、")
        }
        let lastPost = object["last_post"]?.objectValue
        return ChatConversation(
            id: id,
            kind: isDirect ? .direct : .group,
            title: title.isEmpty ? L10n.string("shared.4b3510b8d86ea785") : title,
            memberIDs: memberIDs,
            memberCount: declaredMemberCount ?? (memberIDs.isEmpty ? nil : memberIDs.count),
            lastMessageSummary: lastPost?.firstString(for: ["message", "text", "content"])
                ?? object.firstString(for: ["last_message", "last_message_summary", "last_post_message"]),
            lastActivityAt: Self.date(from: lastPost?.firstDouble(for: ["create_at", "created_at"])
                ?? object.firstDouble(for: ["update_at", "last_activity_at"])),
            unreadCount: object.firstInt(for: ["unread", "unread_count"]) ?? 0,
            isEncrypted: object.firstBool(for: ["encrypted", "is_encrypted"]) ?? false
        )
    }

    private func makeMessage(
        from value: ChatJSON,
        fallbackConversationID: String
    ) -> ChatMessage? {
        guard let object = value.objectValue,
              let id = object.firstString(for: ["post_id", "id"]) else { return nil }
        let conversationID = object.firstString(for: ["channel_id", "conversation_id"])
            ?? fallbackConversationID
        let creator = object["creator"]?.objectValue
            ?? object["user"]?.objectValue
            ?? object["sender"]?.objectValue
            ?? object["author"]?.objectValue
            ?? object["creator_info"]?.objectValue
        let senderID = object.firstNonEmptyString(for: ["creator_id", "user_id", "sender_id", "author_id", "owner_id"])
            ?? object["creator"]?.stringValue
            ?? object["user"]?.stringValue
            ?? object["sender"]?.stringValue
            ?? object["author"]?.stringValue
            ?? creator?.firstNonEmptyString(for: ["user_id", "creator_id", "sender_id", "author_id", "uid", "id"])
            ?? "unknown"
        let senderName = object.firstNonEmptyString(
            for: ["creator_name", "creator_nickname", "sender_name", "author_name", "nickname", "username", "user_name"]
        )
            ?? creator?.firstNonEmptyString(
                for: ["nickname", "display_name", "displayname", "name", "username", "user_name", "account"]
            )
            ?? knownUsersByID[senderID]?.displayName
        let isCurrentUser = object.firstBool(for: ["is_my_post", "is_mine", "is_current_user"])
            ?? creator?.firstBool(for: ["is_login", "is_current", "is_current_user", "is_self", "is_me"])
            ?? cachedCurrentUserID.map { $0 == senderID }
        let attachments = makeAttachments(from: object, messageID: id)
        let poll = makePoll(from: object, messageID: id)
        let text = object.firstString(for: ["message", "text", "content"])
        let isEncrypted = object.firstBool(for: ["encrypted", "is_encrypted"]) ?? false
        let rawPinnedAt = object.firstDouble(for: ["last_pin_at", "pinned_at"])
        let pinnedAt = rawPinnedAt.flatMap { $0 > 0 ? Self.date(from: $0) : nil }
        let hasVisibleText = text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        // Chat Server 在附件操作后可能返回无正文、无附件的辅助记录。
        // 这类记录不是实际用户消息，不能生成空头像行。
        guard hasVisibleText || !attachments.isEmpty || poll != nil || isEncrypted else {
            return nil
        }
        return ChatMessage(
            id: id,
            conversationID: conversationID,
            senderID: senderID,
            senderDisplayName: senderName,
            isFromCurrentUser: isCurrentUser,
            sentAt: Self.date(from: object.firstDouble(for: ["create_at", "created_at", "timestamp"])) ?? Date(),
            text: text,
            attachments: attachments,
            poll: poll,
            encryptionState: isEncrypted ? .locked : .notEncrypted,
            pinnedAt: pinnedAt
        )
    }

    private func makePoll(
        from object: [String: ChatJSON],
        messageID: String
    ) -> ChatPoll? {
        let rawValue = object["vote"] ?? object["poll"] ?? object["vote_info"]
        let decodedValue: ChatJSON?
        if let encoded = rawValue?.stringValue,
           let data = encoded.data(using: .utf8) {
            decodedValue = try? JSONDecoder().decode(ChatJSON.self, from: data)
        } else {
            decodedValue = rawValue
        }
        guard let pollObject = decodedValue?.objectValue else { return nil }

        var rawChoices = pollObject.array(for: "choices")
        if rawChoices.isEmpty { rawChoices = pollObject.array(for: "options") }
        let choices = rawChoices.enumerated().compactMap { index, value -> ChatPollOption? in
            if let text = value.stringValue {
                return ChatPollOption(id: "\(messageID)-choice-\(index)", text: text)
            }
            guard let choice = value.objectValue,
                  let text = choice.firstNonEmptyString(for: ["choice", "text", "name", "title"]) else {
                return nil
            }
            return ChatPollOption(
                id: choice.firstString(for: ["choice_id", "option_id", "id"])
                    ?? "\(messageID)-choice-\(index)",
                text: text,
                voteCount: choice.firstInt(for: ["vote_count", "count", "votes"]) ?? 0,
                isSelectedByCurrentUser: choice.firstBool(
                    for: ["selected", "is_selected", "is_voted", "voted"]
                ) ?? false
            )
        }
        guard !choices.isEmpty else { return nil }

        let settings = pollSettings(from: pollObject["options"]) ?? pollObject
        return ChatPoll(
            id: pollObject.firstString(for: ["vote_id", "poll_id", "id"]) ?? messageID,
            question: pollObject.firstNonEmptyString(for: ["message", "question", "title"])
                ?? object.firstNonEmptyString(for: ["message", "text", "content"])
                ?? L10n.string("shared.3c5a0fdbcf55aaa8"),
            allowsMultipleSelection: settings.firstBool(for: ["multiple", "allow_multiple"]) ?? false,
            isAnonymous: settings.firstBool(for: ["anonymous", "is_anonymous"]) ?? false,
            closesAt: Self.date(from: settings.firstDouble(for: ["expire_at", "close_at", "closes_at"])),
            isClosed: pollObject.firstBool(for: ["closed", "is_closed", "expired"]) ?? false,
            options: choices
        )
    }

    private func pollSettings(from value: ChatJSON?) -> [String: ChatJSON]? {
        if let object = value?.objectValue { return object }
        guard let encoded = value?.stringValue,
              let data = encoded.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ChatJSON.self, from: data) else { return nil }
        return decoded.objectValue
    }

    private func makeAttachments(
        from object: [String: ChatJSON],
        messageID: String
    ) -> [ChatAttachment] {
        var values = object.array(for: "files")
        if values.isEmpty { values = object.array(for: "attachments") }
        if values.isEmpty, let file = object["file_props"] {
            if let encoded = file.stringValue,
               let data = encoded.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(ChatJSON.self, from: data) {
                values = [decoded]
            } else {
                values = [file]
            }
        }
        if values.isEmpty,
           let type = object.firstString(for: ["type", "post_type"])?.lowercased(),
           type == "file" || type == "image" || type == "video" {
            values = [.object(object)]
        }
        return values.enumerated().compactMap { index, value in
            let fileObject = value.objectValue ?? [:]
            let name = fileObject.firstNonEmptyString(
                for: ["name", "file_name", "filename", "title"]
            ) ?? object.firstNonEmptyString(for: ["file_name", "filename"])
            guard let name else { return nil }
            let mediaType = fileObject.firstNonEmptyString(
                for: ["content_type", "mime_type", "media_type"]
            )
            let extensionName = fileObject.firstNonEmptyString(for: ["type", "extension"])
                ?? URL(fileURLWithPath: name).pathExtension
            let kind = Self.attachmentKind(fileName: name, mediaType: mediaType, extensionName: extensionName)
            return ChatAttachment(
                id: fileObject.firstString(for: ["file_id", "id", "uuid"])
                    ?? "\(messageID)-attachment-\(index)",
                kind: kind,
                fileName: name,
                mediaType: mediaType,
                sizeBytes: fileObject.firstDouble(for: ["size", "file_size", "bytes"]).map(Int64.init),
                durationMilliseconds: fileObject.firstDouble(for: ["duration", "duration_ms"]).map(Int64.init),
                thumbnailAvailable: fileObject.firstBool(for: ["has_thumbnail", "thumbnail_available"])
            )
        }
    }

    private func makeLocalAttachment(localURL: URL, fileSize: Int64?) -> ChatAttachment {
        let name = localURL.lastPathComponent
        return ChatAttachment(
            id: "local-file-\(UUID().uuidString)",
            kind: Self.attachmentKind(
                fileName: name,
                mediaType: nil,
                extensionName: localURL.pathExtension
            ),
            fileName: name,
            sizeBytes: fileSize,
            thumbnailAvailable: false
        )
    }

    private static func attachmentKind(
        fileName: String,
        mediaType: String?,
        extensionName: String?
    ) -> ChatAttachmentKind {
        let media = mediaType?.lowercased() ?? ""
        let ext = (extensionName?.isEmpty == false ? extensionName : URL(fileURLWithPath: fileName).pathExtension)?
            .lowercased() ?? ""
        if media.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff"].contains(ext) {
            return .image
        }
        if media.hasPrefix("video/") || ["mov", "mp4", "m4v", "avi", "mkv", "3gp", "webm"].contains(ext) {
            return .video
        }
        return .file
    }

    private static func date(from raw: Double?) -> Date? {
        guard let raw else { return nil }
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
    }

    private func isOwnedByCurrentUser(_ message: ChatMessage) -> Bool {
        if message.isFromCurrentUser == true { return true }
        if cachedCurrentUserID == message.senderID { return true }
        guard let currentAccountName else { return false }
        return Self.normalizedIdentityName(message.senderDisplayName) == currentAccountName
            || Self.normalizedIdentityName(knownUsersByID[message.senderID]?.displayName) == currentAccountName
    }

    private static func normalizedIdentityName(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }

    private func makeUser(from value: ChatJSON, currentUserID: String?) -> ChatUser? {
        guard let object = value.objectValue,
              let id = object.firstNonEmptyString(
                  for: ["user_id", "member_id", "uid", "account_id", "id"]
              ) else { return nil }
        let profile = object["profile"]?.objectValue
        let name = object.firstNonEmptyString(
            for: ["nickname", "display_name", "displayname", "name", "username", "user_name", "account", "login_name"]
        )
            ?? profile?.firstNonEmptyString(
                for: ["nickname", "display_name", "displayname", "name", "username", "user_name", "account"]
            )
            ?? L10n.string("shared.806312613840681c", String(describing: id))
        let explicitCurrent = object.firstBool(
            for: ["is_login", "is_current", "is_current_user", "is_self", "is_me"]
        )
        let avatarAvailable = object.firstBool(
            for: ["has_avatar", "avatar_available", "is_avatar_exist"]
        ) ?? (object.firstNonEmptyString(for: ["avatar", "avatar_url", "avatar_path"]) != nil ? true : nil)
        return ChatUser(
            id: id,
            displayName: name,
            avatarAvailable: avatarAvailable,
            isDisabled: object.firstBool(for: ["disabled", "is_disabled"]) ?? false,
            isCurrentUser: explicitCurrent ?? currentUserID.map { $0 == id }
        )
    }

    private func currentUserID(from payload: ChatJSON) -> String? {
        if let object = payload.objectValue,
           let id = object.firstString(
               for: ["current_user_id", "login_user_id", "my_user_id", "self_user_id"]
           ) {
            return id
        }
        if let object = payload.objectValue {
            let currentUser = object["current_user"]?.objectValue
                ?? object["login_user"]?.objectValue
                ?? object["me"]?.objectValue
            if let id = currentUser?.firstString(for: ["user_id", "id"]) {
                return id
            }
        }
        for user in userValues(from: payload) {
            guard let object = user.objectValue,
                  object.firstBool(
                      for: ["is_login", "is_current", "is_current_user", "is_self", "is_me"]
                  ) == true else { continue }
            return object.firstString(for: ["user_id", "member_id", "id"])
        }
        return nil
    }

    private func userValues(from payload: ChatJSON) -> [ChatJSON] {
        if let values = payload.arrayValue { return values }
        guard let object = payload.objectValue else { return [] }
        for key in ["users", "user", "user_list", "list", "members", "items", "results"] {
            if let values = object[key]?.arrayValue { return values }
            if let values = object[key]?.objectValue?.values { return Array(values) }
        }
        let values = object.values.filter { value in
            guard let candidate = value.objectValue else { return false }
            return candidate.firstNonEmptyString(
                for: ["user_id", "member_id", "uid", "account_id", "id"]
            ) != nil
        }
        return values
    }

    private func usersByLoadingAvatars(_ users: [ChatUser]) async -> [ChatUser] {
        guard let capability = capabilities[DsmAPIName.chatUserAvatar],
              capability.selectedVersion != nil else { return users }

        var resolved: [ChatUser] = []
        resolved.reserveCapacity(users.count)
        for user in users {
            let avatarData: Data?
            if let cached = avatarCache[user.id] {
                avatarData = cached
            } else if unavailableAvatarUserIDs.contains(user.id) || user.avatarAvailable != true {
                avatarData = nil
            } else {
                avatarData = await loadAvatar(userID: user.id, capability: capability)
                if let avatarData {
                    avatarCache[user.id] = avatarData
                } else {
                    unavailableAvatarUserIDs.insert(user.id)
                }
            }
            resolved.append(ChatUser(
                id: user.id,
                displayName: user.displayName,
                avatarAvailable: avatarData != nil ? true : user.avatarAvailable,
                avatarData: avatarData,
                isDisabled: user.isDisabled,
                isCurrentUser: user.isCurrentUser
            ))
        }
        return resolved
    }

    private func loadAvatar(userID: String, capability: ApiCapability) async -> Data? {
        guard let version = capability.selectedVersion,
              let request = try? DsmRequestBuilder.build(
                  baseURL: baseURL,
                  path: capability.path,
                  api: capability.name,
                  version: version,
                  method: "get",
                  requestFormat: capability.requestFormat,
                  parameters: ["user_id": .string(userID)],
                  credential: nil,
                  httpMethod: "GET"
              ) else { return nil }
        var imageRequest = request
        imageRequest.setValue("image/*", forHTTPHeaderField: "Accept")
        if let cookie = credential.cookieHeaderValue {
            imageRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let synoToken = credential.synoToken, !synoToken.isEmpty {
            imageRequest.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN")
        }
        guard let response = try? await transport.send(imageRequest),
              (200..<300).contains(response.statusCode),
              !response.data.isEmpty,
              response.data.count <= 2 * 1_024 * 1_024 else { return nil }
        let contentType = response.headers.first {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value.lowercased()
        guard contentType?.hasPrefix("image/") == true || Self.hasKnownImageSignature(response.data) else {
            return nil
        }
        return response.data
    }

    private static func hasKnownImageSignature(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }
        return bytes.count >= 12
            && Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46]
            && Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50]
    }

    private func hasCapability(_ name: String) -> Bool {
        capabilities[name]?.selectedVersion != nil
    }

    private func supportsVersion(_ name: String, version: Int) -> Bool {
        guard let capability = capabilities[name], capability.selectedVersion != nil else { return false }
        return capability.minVersion <= version && capability.maxVersion >= version
    }

    private func supportsFormCapability(_ name: String, version: Int) -> Bool {
        guard let capability = capabilities[name], capability.requestFormat == .form else {
            return false
        }
        return capability.selectedVersion != nil
            && capability.minVersion <= version
            && capability.maxVersion >= version
    }

    private var supportsAttachmentUpload: Bool {
        guard let capability = capabilities[DsmAPIName.chatPost] else { return false }
        return capability.minVersion <= 5 && capability.maxVersion >= 5
    }

    private func apiURL(path: String) -> URL {
        var url = baseURL.appendingPathComponent("webapi", isDirectory: true)
        for segment in path.split(separator: "/") {
            url.appendPathComponent(String(segment), isDirectory: false)
        }
        return url
    }

    private func createChatMultipartBody(
        localURL: URL,
        boundary: String,
        fields: [String: String]
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanStashChatUpload-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw AppError(
                category: .localStorageFull,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.1991ca3be9f3f977")
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bodyURL.path)
        do {
            let output = try FileHandle(forWritingTo: bodyURL)
            defer { try? output.close() }
            func write(_ string: String) throws {
                guard let data = string.data(using: .utf8) else {
                    throw DsmRequestError.parameterEncodingFailed
                }
                try output.write(contentsOf: data)
            }
            for (name, value) in fields.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
                try write("--\(boundary)\r\n")
                try write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                try write("\(value)\r\n")
            }
            let safeFilename = localURL.lastPathComponent
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\"", with: "'")
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n")
            try write("Content-Type: application/octet-stream\r\n\r\n")
            let input = try FileHandle(forReadingFrom: localURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try write("\r\n--\(boundary)--\r\n")
            return bodyURL
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
    }

    private func requireCapability(_ name: String) throws -> ApiCapability {
        guard let capability = capabilities[name], capability.selectedVersion != nil else {
            throw unsupported(L10n.string("shared.6b69d0465e549886"))
        }
        return capability
    }

    private func selectedVersion(
        _ capability: ApiCapability,
        requiring requiredVersion: Int? = nil
    ) throws -> Int {
        if let requiredVersion {
            guard capability.minVersion <= requiredVersion,
                  capability.maxVersion >= requiredVersion else {
                throw unsupported(L10n.string("shared.b83cd19b612731fc"))
            }
            return requiredVersion
        }
        guard let version = capability.selectedVersion else {
            throw unsupported(L10n.string("shared.adc2581886c52925"))
        }
        return version
    }

    private func mapChatError(_ error: DsmNetworkError) -> AppError {
        if case .api(let code, let requestID) = error, code == 119 {
            return AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.75b08cdfd652ff42"),
                dsmCode: code,
                requestID: requestID
            )
        }
        return DsmErrorMapper.map(error)
    }

    private func unsupported(_ message: String) -> AppError {
        AppError(category: .apiUnavailable, isRetryable: false, safeUserMessage: message)
    }

    private func invalidChatResponse() -> AppError {
        AppError(
            category: .invalidResponse,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.cee51e4469010a94")
        )
    }
}

private struct PendingDirectConversationCreate: Equatable, Sendable {
    let requestID: UUID
    let userID: String
}

private struct PendingGroupConversationCreate: Equatable, Sendable {
    let draft: ChatGroupDraft
    let candidateID: String?
}

private struct PendingChatMessageSendReview: Sendable {
    let draft: ChatMessageDraft
    let candidateMessageID: String?
}

private struct PendingChatAttachmentSendReview: Sendable {
    let draft: ChatMessageDraft
    let candidateMessageID: String?
    let expectedFileName: String
    let expectedFileSize: Int64?
}

private struct ChatAttachmentUploadReceipt: Sendable {
    let message: ChatMessage?
    let candidateMessageID: String?
    let localFileName: String
    let localFileSize: Int64?
}

/// 记录 multipart 是否已经交给传输层，取消结果据此区分提交前与提交后。
private final class ChatAttachmentSubmissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
}

/// 用于兼容 Chat Server 不同版本返回字段的最小动态 JSON 类型。
private indirect enum ChatJSON: Decodable, Sendable {
    case object([String: ChatJSON])
    case array([ChatJSON])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode([String: ChatJSON].self) { self = .object(value) }
        else if let value = try? container.decode([ChatJSON].self) { self = .array(value) }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: L10n.string("shared.8181f74b8a7bf4dc")) }
    }

    var objectValue: [String: ChatJSON]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [ChatJSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value ? String(Int64(value)) : String(value)
        case .boolean(let value): value ? "true" : "false"
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .boolean(let value): value
        case .number(let value): value != 0
        case .string(let value): ["true", "1", "yes"].contains(value.lowercased())
        default: nil
        }
    }

    func array(for key: String) -> [ChatJSON] {
        objectValue?.array(for: key) ?? []
    }
}

private struct ChatUploadEnvelope: Decodable, Sendable {
    let success: Bool
    let data: ChatJSON?
    let error: ChatUploadError?
}

private struct ChatUploadError: Decodable, Sendable {
    let code: Int
}

private extension Dictionary where Key == String, Value == ChatJSON {
    func array(for key: String) -> [ChatJSON] {
        guard case .array(let value)? = self[key] else { return [] }
        return value
    }

    func firstString(for keys: [String]) -> String? {
        keys.lazy.compactMap { self[$0]?.stringValue }.first
    }

    func firstNonEmptyString(for keys: [String]) -> String? {
        keys.lazy.compactMap { key in
            guard let value = self[key]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }.first
    }

    func firstDouble(for keys: [String]) -> Double? {
        keys.lazy.compactMap { self[$0]?.doubleValue }.first
    }

    func firstInt(for keys: [String]) -> Int? {
        firstDouble(for: keys).map(Int.init)
    }

    func firstBool(for keys: [String]) -> Bool? {
        keys.lazy.compactMap { self[$0]?.boolValue }.first
    }
}

import DsmCore
import Foundation
import UniformTypeIdentifiers

/// 移动端 Chat 能力边界：仅转发已接入原生主流程的能力，其余方法保持拒绝。
struct MobileReadOnlyChatRepository: ChatRepository, Sendable {
    let base: any ChatRepository

    func availability() async -> ChatAvailability {
        let value = await base.availability()
        let mobileScope: Set<ChatFeature> = [
            .directConversation,
            .groupConversation,
            .textMessage,
            .imageAttachment,
            .videoAttachment,
            .fileAttachment,
            .attachmentDownload,
            .groupMembers,
            .pinnedMessages,
            .deleteOwnMessage,
            .messageSearch,
            .messageEditing,
            .threadedReplies,
            .poll,
            .pollVoting,
            .reminder,
            .reminderManagement,
            .scheduledMessage,
            .closeConversation,
            .messageForward
        ]
        var mobileFeatures = value.status == .available
            ? value.supportedFeatures.intersection(mobileScope)
            : []
        // 投票与提醒需要 Post v5 的原消息回读能力。
        if !value.supportedFeatures.contains(.messageSearch) { mobileFeatures.subtract([.poll, .pollVoting, .reminder, .reminderManagement]) }
        return ChatAvailability(status: value.status, supportedFeatures: mobileFeatures)
    }

    func listUsers() async throws -> [ChatUser] {
        try await base.listUsers()
    }

    func listConversations() async throws -> [ChatConversation] {
        try await base.listConversations()
    }

    func listMessages(
        conversationID: String,
        before cursor: String?,
        limit: Int
    ) async throws -> ChatMessagePage {
        try await base.listMessages(conversationID: conversationID, before: cursor, limit: limit)
    }

    func realtimeEvents() async -> AsyncStream<ChatRealtimeEvent> {
        await base.realtimeEvents()
    }

    func startRealtime() async {
        await base.startRealtime()
    }

    func stopRealtime() async {
        await base.stopRealtime()
    }

    func openDirectConversation(
        userID: String,
        clientRequestID: UUID
    ) async throws -> ChatConversation {
        let outcome = try await openDirectConversationResult(
            userID: userID,
            clientRequestID: clientRequestID
        )
        guard outcome.result.status == .confirmedSuccess,
              let conversation = outcome.confirmedConversation else {
            throw MobileReadOnlyChatRepositoryError.operationUnavailable
        }
        return conversation
    }

    func createGroup(_ draft: ChatGroupDraft) async throws -> ChatConversation {
        let outcome = try await createGroupResult(draft)
        guard outcome.result.status == .confirmedSuccess,
              let conversation = outcome.confirmedConversation else {
            throw MobileReadOnlyChatRepositoryError.operationUnavailable
        }
        return conversation
    }

    func openDirectConversationResult(
        userID: String,
        clientRequestID: UUID
    ) async throws -> ChatConversationCreateOutcome {
        let value = await base.availability()
        guard value.status == .available,
              value.supportedFeatures.contains(.directConversation) else {
            return try unsupportedConversationCreate(
                operation: "chatDirectConversationCreate",
                clientRequestID: clientRequestID
            )
        }
        return try await base.openDirectConversationResult(
            userID: userID,
            clientRequestID: clientRequestID
        )
    }

    func openDirectConversationResult(
        userID: String,
        clientRequestID: UUID,
        willSubmit: @escaping @Sendable () async throws -> Void
    ) async throws -> ChatConversationCreateOutcome {
        let value = await base.availability()
        guard value.status == .available, value.supportedFeatures.contains(.directConversation) else {
            return try unsupportedConversationCreate(operation: "chatDirectConversationCreate", clientRequestID: clientRequestID)
        }
        return try await base.openDirectConversationResult(userID: userID, clientRequestID: clientRequestID, willSubmit: willSubmit)
    }

    func recoverDirectConversation(userID: String, clientRequestID: UUID) async throws -> ChatConversationCreateOutcome {
        try await base.recoverDirectConversation(userID: userID, clientRequestID: clientRequestID)
    }

    func createGroupResult(
        _ draft: ChatGroupDraft
    ) async throws -> ChatConversationCreateOutcome {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func createGroupResult(
        _ draft: ChatGroupDraft,
        recordProgress: @escaping @Sendable (ChatGroupCreateReceipt) async throws -> Void
    ) async throws -> ChatConversationCreateOutcome {
        let value = await base.availability()
        guard value.status == .available,
              value.supportedFeatures.contains(.groupConversation),
              value.supportedFeatures.contains(.groupMembers),
              !draft.isEncrypted else {
            return try unsupportedConversationCreate(
                operation: "chatGroupCreate",
                clientRequestID: draft.clientRequestID
            )
        }
        return try await base.createGroupResult(draft, recordProgress: recordProgress)
    }

    func recoverGroupCreation(
        _ receipt: ChatGroupCreateReceipt,
        recordProgress: @escaping @Sendable (ChatGroupCreateReceipt) async throws -> Void
    ) async throws -> ChatConversationCreateOutcome {
        try await base.recoverGroupCreation(receipt, recordProgress: recordProgress)
    }

    func continueGroupCreation(
        _ draft: ChatGroupDraft, receipt: ChatGroupCreateReceipt,
        recordProgress: @escaping @Sendable (ChatGroupCreateReceipt) async throws -> Void
    ) async throws -> ChatConversationCreateOutcome {
        let value = await base.availability()
        guard value.status == .available, value.supportedFeatures.contains(.groupConversation),
              value.supportedFeatures.contains(.groupMembers), !draft.isEncrypted else {
            return try await base.recoverGroupCreation(receipt, recordProgress: recordProgress)
        }
        return try await base.continueGroupCreation(draft, receipt: receipt, recordProgress: recordProgress)
    }

    func sendMessage(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessage {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func sendMessageResult(_ draft: ChatMessageDraft, progress: @escaping FileTransferProgress) async throws -> ChatMessageSendOutcome {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func sendMessageResult(_ draft: ChatMessageDraft, progress: @escaping FileTransferProgress,
                           recordProgress: @escaping @Sendable (ChatMessageSendReceipt) async throws -> Void) async throws -> ChatMessageSendOutcome {
        let value = await base.availability()
        guard value.status == .available, value.supportedFeatures.contains(.textMessage),
              draft.localAttachmentURLs.isEmpty, draft.text?.isEmpty == false,
              draft.threadID == nil || value.supportedFeatures.contains(.threadedReplies) else {
            throw MobileReadOnlyChatRepositoryError.operationUnavailable
        }
        return try await base.sendMessageResult(draft, progress: progress, recordProgress: recordProgress)
    }

    func recoverMessageSend(_ receipt: ChatMessageSendReceipt,
                            recordProgress: @escaping @Sendable (ChatMessageSendReceipt) async throws -> Void) async throws -> ChatMessageSendOutcome {
        try await base.recoverMessageSend(receipt, recordProgress: recordProgress)
    }

    func recoverMessageSend(_ receipt: ChatMessageSendReceipt) async throws -> ChatMessageSendOutcome {
        try await base.recoverMessageSend(receipt)
    }

    func searchMessages(query: String, conversationID: String?, cursor: String?, limit: Int) async throws -> ChatSearchPage {
        try await require(.messageSearch)
        return try await base.searchMessages(query: query, conversationID: conversationID, cursor: cursor, limit: limit)
    }

    func message(conversationID: String, messageID: String, threadID: String?) async throws -> ChatMessage? {
        let value = await availability()
        guard value.status == .available,
              !value.supportedFeatures.isDisjoint(with: [.messageSearch, .messageEditing, .threadedReplies, .poll, .pollVoting, .reminder]) else {
            throw MobileReadOnlyChatRepositoryError.operationUnavailable
        }
        return try await base.message(conversationID: conversationID, messageID: messageID, threadID: threadID)
    }

    func listReplies(conversationID: String, threadID: String, before: String?, limit: Int) async throws -> ChatMessagePage {
        try await require(.threadedReplies)
        return try await base.listReplies(conversationID: conversationID, threadID: threadID, before: before, limit: limit)
    }

    func editingPolicy() async throws -> ChatEditingPolicy {
        try await require(.messageEditing)
        return try await base.editingPolicy()
    }

    func editMessage(_ original: ChatMessage, text: String, clientRequestID: UUID) async throws -> ChatMessage {
        try await require(.messageEditing)
        return try await base.editMessage(original, text: text, clientRequestID: clientRequestID)
    }

    private func require(_ feature: ChatFeature) async throws {
        let value = await availability()
        guard value.status == .available, value.supportedFeatures.contains(feature) else {
            throw MobileReadOnlyChatRepositoryError.operationUnavailable
        }
    }

    func sendAttachmentMessageResult(_ draft: ChatMessageDraft, progress: @escaping FileTransferProgress) async throws -> ChatMessageSendOutcome {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func sendAttachmentMessageResult(_ draft: ChatMessageDraft, progress: @escaping FileTransferProgress,
                                    recordProgress: @escaping @Sendable (ChatMessageSendReceipt) async throws -> Void) async throws -> ChatMessageSendOutcome {
        let value = await base.availability()
        guard value.status == .available,
              draft.localAttachmentURLs.count == 1,
              let localURL = draft.localAttachmentURLs.first else {
            throw MobileReadOnlyChatRepositoryError.operationUnavailable
        }
        let kind = MobileChatAttachmentSelection.kind(
            contentType: UTType(filenameExtension: localURL.pathExtension),
            fileName: localURL.lastPathComponent
        )
        guard value.supportedFeatures.contains(MobileChatAttachmentSelection.requiredFeature(for: kind)) else {
            throw MobileReadOnlyChatRepositoryError.operationUnavailable
        }
        return try await base.sendAttachmentMessageResult(draft, progress: progress, recordProgress: recordProgress)
    }

    func deleteMessage(
        conversationID: String,
        messageID: String,
        clientRequestID: UUID
    ) async throws {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func deleteMessage(
        _ original: ChatMessageDeletionSnapshot, clientRequestID: UUID,
        willSubmit: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await require(.deleteOwnMessage)
        try await base.deleteMessage(original, clientRequestID: clientRequestID, willSubmit: willSubmit)
    }

    func recoverMessageDeletion(_ original: ChatMessageDeletionSnapshot, clientRequestID: UUID) async throws -> Bool {
        try await base.recoverMessageDeletion(original, clientRequestID: clientRequestID)
    }

    func closeConversation(
        conversationID: String,
        clientRequestID: UUID
    ) async throws {
        try await require(.closeConversation)
        try await base.closeConversation(conversationID: conversationID, clientRequestID: clientRequestID)
    }

    func listConversationMembers(conversationID: String) async throws -> [ChatUser] {
        let value = await base.availability()
        guard value.status == .available,
              value.supportedFeatures.contains(.groupMembers) else {
            throw MobileReadOnlyChatRepositoryError.operationUnavailable
        }
        return try await base.listConversationMembers(conversationID: conversationID)
    }

    func listPinnedMessages(conversationID: String) async throws -> [ChatMessage] {
        let value = await base.availability()
        guard value.status == .available,
              value.supportedFeatures.contains(.pinnedMessages) else {
            throw MobileReadOnlyChatRepositoryError.operationUnavailable
        }
        let messages = try await base.listPinnedMessages(conversationID: conversationID)
        // 被过滤的对象不能作为取消公告后“不存在”的证明。
        guard messages.allSatisfy({ $0.conversationID == conversationID && $0.isPinned && $0.encryptionState == .notEncrypted }) else {
            throw MobileReadOnlyChatRepositoryError.operationUnavailable
        }
        return messages
    }

    func setMessagePinned(
        conversationID: String,
        messageID: String,
        isPinned: Bool,
        clientRequestID: UUID
    ) async throws {
        try await require(.pinnedMessages)
        try await base.setMessagePinned(conversationID: conversationID, messageID: messageID,
            isPinned: isPinned, clientRequestID: clientRequestID)
    }

    func forwardMessage(
        messageID: String,
        toConversationIDs: [String],
        clientRequestID: UUID
    ) async throws {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func forwardMessage(
        _ original: ChatMessage, toConversationIDs: [String], clientRequestID: UUID,
        recordProgress: @escaping @Sendable (ChatForwardReceipt) async throws -> Void
    ) async throws -> ChatForwardReceipt {
        try await require(.messageForward)
        return try await base.forwardMessage(original, toConversationIDs: toConversationIDs,
            clientRequestID: clientRequestID, recordProgress: recordProgress)
    }

    func recoverForward(
        _ receipt: ChatForwardReceipt,
        recordProgress: @escaping @Sendable (ChatForwardReceipt) async throws -> Void
    ) async throws -> ChatForwardReceipt {
        try await base.recoverForward(receipt, recordProgress: recordProgress)
    }

    func setReminder(
        messageID: String,
        remindAt: Date,
        clientRequestID: UUID
    ) async throws -> ChatReminder {
        try await require(.reminder)
        return try await base.setReminder(messageID: messageID, remindAt: remindAt, clientRequestID: clientRequestID)
    }

    func listReminders(conversationID: String) async throws -> [ChatReminder] {
        try await require(.reminderManagement)
        return try await base.listReminders(conversationID: conversationID)
    }

    func deleteReminder(
        messageID: String,
        conversationID: String,
        clientRequestID: UUID
    ) async throws {
        try await require(.reminderManagement)
        try await base.deleteReminder(messageID: messageID, conversationID: conversationID, clientRequestID: clientRequestID)
    }

    func loadAttachmentThumbnail(
        messageID: String,
        size: ChatAttachmentThumbnailSize
    ) async throws -> Data {
        let value = await base.availability()
        guard value.status == .available,
              value.supportedFeatures.contains(.attachmentDownload) else {
            throw MobileReadOnlyChatRepositoryError.operationUnavailable
        }
        return try await base.loadAttachmentThumbnail(messageID: messageID, size: size)
    }

    func downloadAttachment(
        messageID: String,
        to destinationURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws {
        let value = await base.availability()
        guard value.status == .available,
              value.supportedFeatures.contains(.attachmentDownload) else {
            throw MobileReadOnlyChatRepositoryError.operationUnavailable
        }
        try await base.downloadAttachment(
            messageID: messageID,
            to: destinationURL,
            progress: progress
        )
    }

    func listScheduledMessages(conversationID: String) async throws -> [ChatScheduledMessage] {
        try await require(.scheduledMessage)
        return try await base.listScheduledMessages(conversationID: conversationID)
    }

    func createScheduledMessage(
        conversationID: String,
        text: String,
        sendAt: Date,
        clientRequestID: UUID
    ) async throws -> ChatScheduledMessage {
        try await require(.scheduledMessage)
        return try await base.createScheduledMessage(conversationID: conversationID, text: text, sendAt: sendAt, clientRequestID: clientRequestID)
    }

    func createScheduledMessage(
        conversationID: String, text: String, sendAt: Date, clientRequestID: UUID,
        recordCreatedSchedule: @escaping @Sendable (String) async throws -> Void
    ) async throws -> ChatScheduledMessage {
        try await require(.scheduledMessage)
        return try await base.createScheduledMessage(conversationID: conversationID, text: text, sendAt: sendAt,
            clientRequestID: clientRequestID, recordCreatedSchedule: recordCreatedSchedule)
    }

    func deleteScheduledMessage(
        id: String,
        conversationID: String,
        clientRequestID: UUID
    ) async throws {
        try await require(.scheduledMessage)
        try await base.deleteScheduledMessage(id: id, conversationID: conversationID, clientRequestID: clientRequestID)
    }

    func createPoll(_ draft: ChatPollDraft) async throws -> ChatMessage {
        try await require(.poll)
        return try await base.createPoll(draft)
    }

    func createPoll(_ draft: ChatPollDraft, recordCreatedMessage: @escaping @Sendable (String) async throws -> Void) async throws -> ChatMessage {
        try await require(.poll)
        return try await base.createPoll(draft, recordCreatedMessage: recordCreatedMessage)
    }

    func pollMessage(conversationID: String, messageID: String, threadID: String?) async throws -> ChatMessage? {
        try await require(.pollVoting)
        return try await base.pollMessage(conversationID: conversationID, messageID: messageID, threadID: threadID)
    }

    func vote(_ message: ChatMessage, choiceIDs: Set<String>, clientRequestID: UUID) async throws -> ChatMessage {
        try await require(.pollVoting)
        return try await base.vote(message, choiceIDs: choiceIDs, clientRequestID: clientRequestID)
    }

    private func unsupportedConversationCreate(
        operation: String,
        clientRequestID: UUID
    ) throws -> ChatConversationCreateOutcome {
        ChatConversationCreateOutcome(
            result: try MutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                diagnosticTag: "chat.conversation-create.unsupported"
            ),
            clientRequestID: clientRequestID,
            confirmedConversation: nil
        )
    }
}

enum MobileReadOnlyChatRepositoryError: Error, Equatable, Sendable {
    case operationUnavailable
}

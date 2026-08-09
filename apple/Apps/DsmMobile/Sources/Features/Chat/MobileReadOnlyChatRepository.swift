import DsmCore
import Foundation

/// 移动端 Chat 能力边界：开放会话、消息基础读取和纯文字发送；附件与高级动作继续关闭。
struct MobileReadOnlyChatRepository: ChatRepository, Sendable {
    let base: any ChatRepository

    func availability() async -> ChatAvailability {
        let value = await base.availability()
        let mobileFeatures: Set<ChatFeature> = value.status == .available &&
            value.supportedFeatures.contains(.textMessage)
            ? [.textMessage]
            : []
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
        AsyncStream { $0.finish() }
    }

    func startRealtime() async {}

    func stopRealtime() async {}

    func openDirectConversation(
        userID: String,
        clientRequestID: UUID
    ) async throws -> ChatConversation {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func createGroup(_ draft: ChatGroupDraft) async throws -> ChatConversation {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func sendMessage(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessage {
        let outcome = try await sendMessageResult(draft, progress: progress)
        guard outcome.result.status == .confirmedSuccess,
              let message = outcome.confirmedMessage else {
            throw MobileReadOnlyChatRepositoryError.operationUnavailable
        }
        return message
    }

    func sendMessageResult(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessageSendOutcome {
        let value = await base.availability()
        guard value.status == .available,
              value.supportedFeatures.contains(.textMessage),
              draft.localAttachmentURLs.isEmpty,
              draft.text?.isEmpty == false else {
            throw MobileReadOnlyChatRepositoryError.operationUnavailable
        }
        return try await base.sendMessageResult(draft, progress: progress)
    }

    func deleteMessage(
        conversationID: String,
        messageID: String,
        clientRequestID: UUID
    ) async throws {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func closeConversation(
        conversationID: String,
        clientRequestID: UUID
    ) async throws {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func listConversationMembers(conversationID: String) async throws -> [ChatUser] {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func listPinnedMessages(conversationID: String) async throws -> [ChatMessage] {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func setMessagePinned(
        conversationID: String,
        messageID: String,
        isPinned: Bool,
        clientRequestID: UUID
    ) async throws {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func forwardMessage(
        messageID: String,
        toConversationIDs: [String],
        clientRequestID: UUID
    ) async throws {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func setReminder(
        messageID: String,
        remindAt: Date,
        clientRequestID: UUID
    ) async throws -> ChatReminder {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func listReminders(conversationID: String) async throws -> [ChatReminder] {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func deleteReminder(
        messageID: String,
        conversationID: String,
        clientRequestID: UUID
    ) async throws {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func loadAttachmentThumbnail(
        messageID: String,
        size: ChatAttachmentThumbnailSize
    ) async throws -> Data {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func downloadAttachment(
        messageID: String,
        to destinationURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func listScheduledMessages(conversationID: String) async throws -> [ChatScheduledMessage] {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func createScheduledMessage(
        conversationID: String,
        text: String,
        sendAt: Date,
        clientRequestID: UUID
    ) async throws -> ChatScheduledMessage {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func deleteScheduledMessage(
        id: String,
        conversationID: String,
        clientRequestID: UUID
    ) async throws {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func createPoll(_ draft: ChatPollDraft) async throws -> ChatMessage {
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }
}

enum MobileReadOnlyChatRepositoryError: Error, Equatable, Sendable {
    case operationUnavailable
}

import DsmCore
import Foundation
import UniformTypeIdentifiers

/// 移动端 Chat 能力边界：只透传当前受限范围内的会话读取、文字和单附件消息能力。
struct MobileReadOnlyChatRepository: ChatRepository, Sendable {
    let base: any ChatRepository

    func availability() async -> ChatAvailability {
        let value = await base.availability()
        let mobileScope: Set<ChatFeature> = [
            .textMessage,
            .imageAttachment,
            .videoAttachment,
            .fileAttachment,
            .attachmentDownload,
            .groupMembers,
            .pinnedMessages
        ]
        let mobileFeatures = value.status == .available
            ? value.supportedFeatures.intersection(mobileScope)
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

    func sendAttachmentMessageResult(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessageSendOutcome {
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
        return try await base.sendAttachmentMessageResult(draft, progress: progress)
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
        return try await base.listPinnedMessages(conversationID: conversationID)
            .filter {
                $0.conversationID == conversationID
                    && $0.pinnedAt != nil
                    && $0.encryptionState == .notEncrypted
            }
            .prefix(100)
            .map {
                ChatMessage(
                    id: $0.id,
                    clientRequestID: nil,
                    conversationID: $0.conversationID,
                    senderID: $0.senderID,
                    senderDisplayName: $0.senderDisplayName,
                    isFromCurrentUser: $0.isFromCurrentUser,
                    sentAt: $0.sentAt,
                    text: $0.text,
                    attachments: [],
                    poll: nil,
                    deliveryState: .sent,
                    encryptionState: .notEncrypted,
                    pinnedAt: $0.pinnedAt
                )
            }
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

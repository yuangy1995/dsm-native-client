import Foundation
import DsmLocalization

public enum ChatFeature: String, Codable, CaseIterable, Hashable, Sendable {
    case directConversation
    case groupConversation
    case textMessage
    case emoji
    case imageAttachment
    case videoAttachment
    case fileAttachment
    case voiceMessage
    case reminder
    case poll
    case encryptedConversation
    case deleteOwnMessage
    case closeConversation
    case attachmentDownload
    case reminderManagement
    case scheduledMessage
    case messageForward
    case groupMembers
    case pinnedMessages
}

public enum ChatAvailabilityStatus: String, Codable, Sendable {
    case unavailable
    case requiresValidation
    case available
}

public enum ChatRealtimeEvent: Equatable, Sendable {
    case connected
    case contentChanged
    case disconnected
}

public struct ChatAvailability: Codable, Equatable, Sendable {
    public let status: ChatAvailabilityStatus
    public let supportedFeatures: Set<ChatFeature>

    public init(
        status: ChatAvailabilityStatus,
        supportedFeatures: Set<ChatFeature> = []
    ) {
        self.status = status
        self.supportedFeatures = supportedFeatures
    }
}

public struct ChatUser: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let avatarAvailable: Bool?
    public let avatarData: Data?
    public let isDisabled: Bool
    public let isCurrentUser: Bool?

    public init(
        id: String,
        displayName: String,
        avatarAvailable: Bool? = nil,
        avatarData: Data? = nil,
        isDisabled: Bool = false,
        isCurrentUser: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarAvailable = avatarAvailable
        self.avatarData = avatarData
        self.isDisabled = isDisabled
        self.isCurrentUser = isCurrentUser
    }
}

public enum ChatConversationKind: String, Codable, Sendable {
    case direct
    case group
}

public struct ChatConversation: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let kind: ChatConversationKind
    public let title: String
    public let memberIDs: [String]
    public let memberCount: Int?
    public let lastMessageSummary: String?
    public let lastActivityAt: Date?
    public let unreadCount: Int
    public let isEncrypted: Bool

    public init(
        id: String,
        kind: ChatConversationKind,
        title: String,
        memberIDs: [String],
        memberCount: Int? = nil,
        lastMessageSummary: String? = nil,
        lastActivityAt: Date? = nil,
        unreadCount: Int = 0,
        isEncrypted: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.memberIDs = memberIDs
        self.memberCount = memberCount.map { max(0, $0) }
        self.lastMessageSummary = lastMessageSummary
        self.lastActivityAt = lastActivityAt
        self.unreadCount = max(0, unreadCount)
        self.isEncrypted = isEncrypted
    }
}

public enum ChatAttachmentKind: String, Codable, Sendable {
    case image
    case video
    case file
    case voice
}

public struct ChatAttachment: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let kind: ChatAttachmentKind
    public let fileName: String
    public let mediaType: String?
    public let sizeBytes: Int64?
    public let durationMilliseconds: Int64?
    public let thumbnailAvailable: Bool?

    public init(
        id: String,
        kind: ChatAttachmentKind,
        fileName: String,
        mediaType: String? = nil,
        sizeBytes: Int64? = nil,
        durationMilliseconds: Int64? = nil,
        thumbnailAvailable: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.mediaType = mediaType
        self.sizeBytes = sizeBytes.map { max(0, $0) }
        self.durationMilliseconds = durationMilliseconds.map { max(0, $0) }
        self.thumbnailAvailable = thumbnailAvailable
    }
}

public enum ChatMessageDeliveryState: String, Codable, Sendable {
    case sending
    case sent
    case failed
}

public enum ChatEncryptionState: String, Codable, Sendable {
    case notEncrypted
    case locked
    case unlocked
    case recoveryRequired
    case unsupported
}

public struct ChatPollOption: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let text: String
    public let voteCount: Int
    public let isSelectedByCurrentUser: Bool

    public init(
        id: String,
        text: String,
        voteCount: Int = 0,
        isSelectedByCurrentUser: Bool = false
    ) {
        self.id = id
        self.text = text
        self.voteCount = max(0, voteCount)
        self.isSelectedByCurrentUser = isSelectedByCurrentUser
    }
}

public struct ChatPoll: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let question: String
    public let allowsMultipleSelection: Bool
    public let isAnonymous: Bool
    public let closesAt: Date?
    public let isClosed: Bool
    public let options: [ChatPollOption]

    public init(
        id: String,
        question: String,
        allowsMultipleSelection: Bool,
        isAnonymous: Bool,
        closesAt: Date? = nil,
        isClosed: Bool = false,
        options: [ChatPollOption]
    ) {
        self.id = id
        self.question = question
        self.allowsMultipleSelection = allowsMultipleSelection
        self.isAnonymous = isAnonymous
        self.closesAt = closesAt
        self.isClosed = isClosed
        self.options = options
    }
}

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let clientRequestID: UUID?
    public let conversationID: String
    public let senderID: String
    public let senderDisplayName: String?
    public let isFromCurrentUser: Bool?
    public let sentAt: Date
    public let text: String?
    public let attachments: [ChatAttachment]
    public let poll: ChatPoll?
    public let deliveryState: ChatMessageDeliveryState
    public let encryptionState: ChatEncryptionState
    public let pinnedAt: Date?

    public init(
        id: String,
        clientRequestID: UUID? = nil,
        conversationID: String,
        senderID: String,
        senderDisplayName: String? = nil,
        isFromCurrentUser: Bool? = nil,
        sentAt: Date,
        text: String? = nil,
        attachments: [ChatAttachment] = [],
        poll: ChatPoll? = nil,
        deliveryState: ChatMessageDeliveryState = .sent,
        encryptionState: ChatEncryptionState = .notEncrypted,
        pinnedAt: Date? = nil
    ) {
        self.id = id
        self.clientRequestID = clientRequestID
        self.conversationID = conversationID
        self.senderID = senderID
        self.senderDisplayName = senderDisplayName
        self.isFromCurrentUser = isFromCurrentUser
        self.sentAt = sentAt
        self.text = text
        self.attachments = attachments
        self.poll = poll
        self.deliveryState = deliveryState
        self.encryptionState = encryptionState
        self.pinnedAt = pinnedAt
    }

    public var isPinned: Bool {
        pinnedAt != nil
    }
}

public struct ChatMessagePage: Codable, Equatable, Sendable {
    public let messages: [ChatMessage]
    public let previousCursor: String?
    public let hasMoreBefore: Bool

    public init(
        messages: [ChatMessage],
        previousCursor: String?,
        hasMoreBefore: Bool
    ) {
        self.messages = messages
        self.previousCursor = previousCursor
        self.hasMoreBefore = hasMoreBefore
    }
}

public struct ChatReminder: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let messageID: String
    public let remindAt: Date

    public init(id: String, messageID: String, remindAt: Date) {
        self.id = id
        self.messageID = messageID
        self.remindAt = remindAt
    }
}

public struct ChatScheduledMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let conversationID: String
    public let text: String
    public let sendAt: Date

    public init(id: String, conversationID: String, text: String, sendAt: Date) {
        self.id = id
        self.conversationID = conversationID
        self.text = text
        self.sendAt = sendAt
    }
}

public enum ChatAttachmentThumbnailSize: String, Codable, Sendable {
    case small = "sm"
    case large = "lg"
}

public enum ChatContractError: Error, Equatable, Sendable {
    case emptyUserID
    case emptyConversationID
    case emptyGroupTitle
    case insufficientGroupMembers
    case emptyMessage
    case emptyPollQuestion
    case insufficientPollOptions
    case duplicatePollOptions
}

extension ChatContractError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyUserID:
            L10n.string("shared.006df27b0005ac55")
        case .emptyConversationID:
            L10n.string("shared.6c08b32c5cb3f9d5")
        case .emptyGroupTitle:
            L10n.string("shared.bc20c155e8acbe13")
        case .insufficientGroupMembers:
            L10n.string("shared.88fc95a3dca1fdef")
        case .emptyMessage:
            L10n.string("shared.9af2434b7b841a78")
        case .emptyPollQuestion:
            L10n.string("shared.7b82ce1bdda1e2e7")
        case .insufficientPollOptions:
            L10n.string("shared.bfa23e166962ce12")
        case .duplicatePollOptions:
            L10n.string("shared.c7b4b7f12f23c5c3")
        }
    }
}

public struct ChatGroupDraft: Equatable, Sendable {
    public let clientRequestID: UUID
    public let title: String
    public let memberIDs: [String]
    public let isEncrypted: Bool

    public init(
        clientRequestID: UUID = UUID(),
        title: String,
        memberIDs: [String],
        isEncrypted: Bool
    ) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw ChatContractError.emptyGroupTitle }
        let normalizedMembers = memberIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let uniqueMembers = Array(Set(normalizedMembers)).sorted()
        guard uniqueMembers.count >= 2 else {
            throw ChatContractError.insufficientGroupMembers
        }
        self.clientRequestID = clientRequestID
        self.title = normalizedTitle
        self.memberIDs = uniqueMembers
        self.isEncrypted = isEncrypted
    }
}

public struct ChatMessageDraft: Equatable, Sendable {
    public let clientRequestID: UUID
    public let conversationID: String
    public let text: String?
    public let localAttachmentURLs: [URL]

    public init(
        clientRequestID: UUID = UUID(),
        conversationID: String,
        text: String?,
        localAttachmentURLs: [URL] = []
    ) throws {
        let normalizedConversationID = conversationID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedConversationID.isEmpty else {
            throw ChatContractError.emptyConversationID
        }
        let normalizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedText?.isEmpty == false || !localAttachmentURLs.isEmpty else {
            throw ChatContractError.emptyMessage
        }
        self.clientRequestID = clientRequestID
        self.conversationID = normalizedConversationID
        self.text = normalizedText?.isEmpty == false ? normalizedText : nil
        self.localAttachmentURLs = localAttachmentURLs
    }
}

public struct ChatMessageSendOutcome: Equatable, Sendable {
    public let result: MutationResult
    public let conversationID: String
    public let clientRequestID: UUID
    public let confirmedMessage: ChatMessage?

    public init(
        result: MutationResult,
        conversationID: String,
        clientRequestID: UUID,
        confirmedMessage: ChatMessage?
    ) {
        self.result = result
        self.conversationID = conversationID
        self.clientRequestID = clientRequestID
        self.confirmedMessage = confirmedMessage
    }
}

public struct ChatConversationCreateOutcome: Equatable, Sendable {
    public let result: MutationResult
    public let clientRequestID: UUID
    public let confirmedConversation: ChatConversation?

    public init(
        result: MutationResult,
        clientRequestID: UUID,
        confirmedConversation: ChatConversation?
    ) {
        self.result = result
        self.clientRequestID = clientRequestID
        self.confirmedConversation = confirmedConversation
    }
}

public struct ChatPollDraft: Equatable, Sendable {
    public let clientRequestID: UUID
    public let conversationID: String
    public let question: String
    public let options: [String]
    public let allowsMultipleSelection: Bool
    public let isAnonymous: Bool
    public let closesAt: Date?

    public init(
        clientRequestID: UUID = UUID(),
        conversationID: String,
        question: String,
        options: [String],
        allowsMultipleSelection: Bool,
        isAnonymous: Bool,
        closesAt: Date? = nil
    ) throws {
        let normalizedConversationID = conversationID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedConversationID.isEmpty else {
            throw ChatContractError.emptyConversationID
        }
        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuestion.isEmpty else { throw ChatContractError.emptyPollQuestion }
        let normalizedOptions = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard normalizedOptions.count >= 2 else {
            throw ChatContractError.insufficientPollOptions
        }
        let canonicalOptions = normalizedOptions.map { $0.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ) }
        guard Set(canonicalOptions).count == normalizedOptions.count else {
            throw ChatContractError.duplicatePollOptions
        }
        self.clientRequestID = clientRequestID
        self.conversationID = normalizedConversationID
        self.question = normalizedQuestion
        self.options = normalizedOptions
        self.allowsMultipleSelection = allowsMultipleSelection
        self.isAnonymous = isAnonymous
        self.closesAt = closesAt
    }
}

public protocol ChatRepository: Sendable {
    func availability() async -> ChatAvailability
    func listUsers() async throws -> [ChatUser]
    func listConversations() async throws -> [ChatConversation]
    func listMessages(
        conversationID: String,
        before cursor: String?,
        limit: Int
    ) async throws -> ChatMessagePage
    func openDirectConversation(
        userID: String,
        clientRequestID: UUID
    ) async throws -> ChatConversation
    func openDirectConversationResult(
        userID: String,
        clientRequestID: UUID
    ) async throws -> ChatConversationCreateOutcome
    func createGroup(_ draft: ChatGroupDraft) async throws -> ChatConversation
    func createGroupResult(_ draft: ChatGroupDraft) async throws -> ChatConversationCreateOutcome
    func sendMessage(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessage
    func sendMessageResult(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessageSendOutcome
    func sendAttachmentMessageResult(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessageSendOutcome
    func deleteMessage(
        conversationID: String,
        messageID: String,
        clientRequestID: UUID
    ) async throws
    func closeConversation(
        conversationID: String,
        clientRequestID: UUID
    ) async throws
    func listConversationMembers(conversationID: String) async throws -> [ChatUser]
    func listPinnedMessages(conversationID: String) async throws -> [ChatMessage]
    func setMessagePinned(
        conversationID: String,
        messageID: String,
        isPinned: Bool,
        clientRequestID: UUID
    ) async throws
    func forwardMessage(
        messageID: String,
        toConversationIDs: [String],
        clientRequestID: UUID
    ) async throws
    func setReminder(
        messageID: String,
        remindAt: Date,
        clientRequestID: UUID
    ) async throws -> ChatReminder
    func listReminders(conversationID: String) async throws -> [ChatReminder]
    func deleteReminder(
        messageID: String,
        conversationID: String,
        clientRequestID: UUID
    ) async throws
    func loadAttachmentThumbnail(
        messageID: String,
        size: ChatAttachmentThumbnailSize
    ) async throws -> Data
    func downloadAttachment(
        messageID: String,
        to destinationURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws
    func listScheduledMessages(conversationID: String) async throws -> [ChatScheduledMessage]
    func createScheduledMessage(
        conversationID: String,
        text: String,
        sendAt: Date,
        clientRequestID: UUID
    ) async throws -> ChatScheduledMessage
    func deleteScheduledMessage(
        id: String,
        conversationID: String,
        clientRequestID: UUID
    ) async throws
    func createPoll(_ draft: ChatPollDraft) async throws -> ChatMessage
    func realtimeEvents() async -> AsyncStream<ChatRealtimeEvent>
    func startRealtime() async
    func stopRealtime() async
}

public extension ChatRepository {
    func openDirectConversationResult(
        userID: String,
        clientRequestID: UUID
    ) async throws -> ChatConversationCreateOutcome {
        ChatConversationCreateOutcome(
            result: try MutationResult(
                status: .unsupported,
                operation: "chatDirectConversationCreate",
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                diagnosticTag: "chat.direct-create.unsupported"
            ),
            clientRequestID: clientRequestID,
            confirmedConversation: nil
        )
    }

    func createGroupResult(_ draft: ChatGroupDraft) async throws -> ChatConversationCreateOutcome {
        ChatConversationCreateOutcome(
            result: try MutationResult(
                status: .unsupported,
                operation: "chatGroupCreate",
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                diagnosticTag: "chat.group-create.unsupported"
            ),
            clientRequestID: draft.clientRequestID,
            confirmedConversation: nil
        )
    }

    func sendMessage(_ draft: ChatMessageDraft) async throws -> ChatMessage {
        try await sendMessage(draft, progress: { _, _ in })
    }

    func sendMessageResult(_ draft: ChatMessageDraft) async throws -> ChatMessageSendOutcome {
        try await sendMessageResult(draft, progress: { _, _ in })
    }

    func sendAttachmentMessageResult(_ draft: ChatMessageDraft) async throws -> ChatMessageSendOutcome {
        try await sendAttachmentMessageResult(draft, progress: { _, _ in })
    }

    func sendMessageResult(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessageSendOutcome {
        ChatMessageSendOutcome(
            result: try MutationResult(
                status: .unsupported,
                operation: "chatTextSend",
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                diagnosticTag: "chat.text-send.unsupported"
            ),
            conversationID: draft.conversationID,
            clientRequestID: draft.clientRequestID,
            confirmedMessage: nil
        )
    }

    func sendAttachmentMessageResult(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessageSendOutcome {
        ChatMessageSendOutcome(
            result: try MutationResult(
                status: .unsupported,
                operation: "chatAttachmentSend",
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                diagnosticTag: "chat.attachment-send.unsupported"
            ),
            conversationID: draft.conversationID,
            clientRequestID: draft.clientRequestID,
            confirmedMessage: nil
        )
    }

    func realtimeEvents() async -> AsyncStream<ChatRealtimeEvent> {
        AsyncStream { $0.finish() }
    }

    func startRealtime() async {}
    func stopRealtime() async {}
}

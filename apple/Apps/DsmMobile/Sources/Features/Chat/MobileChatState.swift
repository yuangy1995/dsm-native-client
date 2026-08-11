import DsmCore
import Foundation

struct MobileChatMessageCache: Equatable, Sendable {
    var messages: [ChatMessage] = []
    var previousCursor: String?
    var hasMoreBefore = false
}

struct MobileChatProfileState: Equatable, Sendable {
    var availability = ChatAvailability(status: .requiresValidation)
    var conversations: [ChatConversation] = []
    var visibleConversations: [ChatConversation] = []
    var pinnedConversationIDs: [String] = []
    var conversationFilter = ""
    var selectedConversationID: String?
    var messagesByConversation: [String: MobileChatMessageCache] = [:]
    var draftsByConversation: [String: String] = [:]
    var sendReviewBlockedTextsByConversation: [String: Set<String>] = [:]
    var conversationPageState: MobilePageState = .loading
    var messagePageState: MobilePageState = .empty
    var isRefreshingConversations = false
    var isRefreshingMessages = false
    var isLoadingMoreMessages = false
    var isSendingMessage = false
    var isPreparingAttachment = false
    var isSendingAttachment = false
    var attachmentProgressFraction: Double?
    var attachmentReviewRequired = false
    var attachmentThumbnailsByMessageID: [String: Data] = [:]
    var loadingAttachmentThumbnailIDs: Set<String> = []
    var remoteAttachmentMessageID: String?
    var remoteAttachmentProgressFraction: Double?
    var remoteAttachmentErrorMessageID: String?
    var loadMoreMessagesFailed = false
    var conversationErrorCategory: AppErrorCategory?
    var messageErrorCategory: AppErrorCategory?
    var sendErrorCategory: AppErrorCategory?
    var attachmentErrorCategory: AppErrorCategory?
    var remoteAttachmentErrorCategory: AppErrorCategory?

    var selectedConversation: ChatConversation? {
        guard let selectedConversationID else { return nil }
        return conversations.first { $0.id == selectedConversationID }
    }

    var selectedConversationIsEncrypted: Bool {
        selectedConversation?.isEncrypted == true
    }

    func isConversationPinned(_ conversationID: String) -> Bool {
        pinnedConversationIDs.contains(conversationID)
    }

    var selectedMessages: MobileChatMessageCache {
        guard let selectedConversationID else { return MobileChatMessageCache() }
        return messagesByConversation[selectedConversationID] ?? MobileChatMessageCache()
    }

    var selectedDraft: String {
        guard let selectedConversationID else { return "" }
        return draftsByConversation[selectedConversationID] ?? ""
    }

    var selectedDraftRequiresReview: Bool {
        guard let selectedConversationID else { return false }
        let normalized = selectedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return sendReviewBlockedTextsByConversation[selectedConversationID]?.contains(normalized) == true
    }

    var canSendSelectedDraft: Bool {
        guard selectedConversation?.isEncrypted == false,
              availability.supportedFeatures.contains(.textMessage),
              !isSendingMessage,
              !isPreparingAttachment,
              !isSendingAttachment,
              !selectedDraftRequiresReview else {
            return false
        }
        return !selectedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

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
    var conversationFilter = ""
    var selectedConversationID: String?
    var messagesByConversation: [String: MobileChatMessageCache] = [:]
    var conversationPageState: MobilePageState = .loading
    var messagePageState: MobilePageState = .empty
    var isRefreshingConversations = false
    var isRefreshingMessages = false
    var isLoadingMoreMessages = false
    var loadMoreMessagesFailed = false
    var conversationErrorCategory: AppErrorCategory?
    var messageErrorCategory: AppErrorCategory?

    var selectedConversation: ChatConversation? {
        guard let selectedConversationID else { return nil }
        return conversations.first { $0.id == selectedConversationID }
    }

    var selectedConversationIsEncrypted: Bool {
        selectedConversation?.isEncrypted == true
    }

    var selectedMessages: MobileChatMessageCache {
        guard let selectedConversationID else { return MobileChatMessageCache() }
        return messagesByConversation[selectedConversationID] ?? MobileChatMessageCache()
    }
}

import DsmCore
import Foundation
import Observation

/// 搜索与线程拥有独立游标；写入绑定创建本模型时的账号与 Repository。
@MainActor
@Observable
final class MobileChatInteractionModel {
    let context: String
    private let repository: any ChatRepository
    let recovery: MobileChatInteractionStore
    private weak var owner: MobileChatModel?
    private var active = true
    private var searchGeneration = 0
    private var focusGeneration = 0
    private(set) var availability = ChatAvailability(status: .requiresValidation)
    private(set) var policy = ChatEditingPolicy(allowsEditing: false)
    private(set) var searchQuery = ""
    private(set) var searchConversationID: String?
    private(set) var searchMessages: [ChatMessage] = []
    private(set) var searchCursor: String?
    private(set) var isSearching = false
    private(set) var searchError = false
    private(set) var hasSearched = false
    private(set) var root: ChatMessage?
    private(set) var focusedMessage: ChatMessage?
    private(set) var replies = MobileChatMessageCache()
    private(set) var isLoadingThread = false
    private(set) var threadError = false
    private(set) var missingMessage = false
    private(set) var isMutating = false
    private(set) var mutationErrorKey: String?
    private(set) var isRecovering = false

    init(context: String, repository: any ChatRepository, recovery: MobileChatInteractionStore, owner: MobileChatModel? = nil) {
        self.context = context; self.repository = repository; self.recovery = recovery; self.owner = owner
    }

    var canSearch: Bool { active && availability.status == .available && availability.supportedFeatures.contains(.messageSearch) }
    var canReply: Bool { active && availability.status == .available && availability.supportedFeatures.isSuperset(of: [.threadedReplies, .textMessage]) && root != nil && !isMutating && !recovery.failed }
    var pending: [MobileChatInteractionStore.Entry] { recovery.entries.filter { $0.context == context } }

    func updateAvailability(_ value: ChatAvailability) {
        availability = value
        if value.status != .available {
            searchGeneration &+= 1; searchMessages = []; searchCursor = nil; isSearching = false
            policy = ChatEditingPolicy(allowsEditing: false)
            closeDiscussion()
        }
    }

    func invalidate() {
        active = false; searchGeneration &+= 1; focusGeneration &+= 1
        searchMessages = []; root = nil; focusedMessage = nil; replies = MobileChatMessageCache()
        isSearching = false; isLoadingThread = false
    }

    func closeDiscussion() {
        focusGeneration &+= 1
        root = nil; focusedMessage = nil; replies = MobileChatMessageCache(); isLoadingThread = false
    }

    func loadPolicy() async {
        guard active, availability.supportedFeatures.contains(.messageEditing) else { return }
        let value = (try? await repository.editingPolicy()) ?? ChatEditingPolicy(allowsEditing: false)
        guard active else { return }
        policy = value
    }

    func canEdit(_ message: ChatMessage) -> Bool {
        active && availability.status == .available && availability.supportedFeatures.contains(.messageEditing) && policy.permits(message)
            && message.deliveryState == .sent && !isMutating && !recovery.failed
            && owner?.state.deletingMessageID == nil
            && owner?.management?.blocksWrites(in: message.conversationID) != true
            && !pending.contains { $0.kind == .edit && $0.conversationID == message.conversationID && $0.messageID == message.id }
    }

    func containsFocusedMessage(conversationID: String, messageID: String) -> Bool {
        guard active else { return false }
        return ([root, focusedMessage].compactMap { $0 } + replies.messages).contains {
            $0.conversationID == conversationID && $0.id == messageID && $0.encryptionState == .notEncrypted
        }
    }

    func canSendReply(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canReply, let root, !body.isEmpty,
              owner?.management?.blocksWrites(in: root.conversationID) != true else { return false }
        return !pending.contains { $0.kind == .reply && $0.conversationID == root.conversationID
            && $0.messageID == root.id && $0.textDigest == MobileChatInteractionStore.digest(body) }
    }

    func search(_ query: String, conversationID: String?, more: Bool = false) async {
        guard canSearch else { return }
        let body = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if more { guard !isSearching, body == searchQuery, conversationID == searchConversationID, searchCursor != nil else { return } }
        searchGeneration &+= 1
        let generation = searchGeneration
        let cursor = more ? searchCursor : nil
        searchQuery = body; searchConversationID = conversationID; searchError = false
        if !more { searchMessages = []; searchCursor = nil }
        hasSearched = !body.isEmpty
        guard !body.isEmpty else { isSearching = false; return }
        isSearching = true
        do {
            let page = try await repository.searchMessages(query: body, conversationID: conversationID, cursor: cursor, limit: 25)
            guard active, generation == searchGeneration else { return }
            guard page.messages.allSatisfy({ conversationID == nil || $0.conversationID == conversationID }),
                  page.nextCursor == nil || page.nextCursor != cursor else { throw InteractionError.invalidResponse }
            let safe = page.messages.filter { $0.encryptionState == .notEncrypted }
            if more {
                let keys = Set(searchMessages.map { $0.conversationID + ":" + $0.id })
                searchMessages += safe.filter { !keys.contains($0.conversationID + ":" + $0.id) }
            } else { searchMessages = safe }
            searchCursor = page.nextCursor; isSearching = false
        } catch {
            guard active, generation == searchGeneration else { return }
            searchError = true; isSearching = false
        }
    }

    func open(_ message: ChatMessage) async {
        guard active, message.encryptionState == .notEncrypted else { return }
        focusGeneration &+= 1
        let generation = focusGeneration
        root = nil; focusedMessage = nil; replies = MobileChatMessageCache()
        threadError = false; missingMessage = false; isLoadingThread = true; mutationErrorKey = nil
        do {
            let value = try await repository.message(conversationID: message.conversationID, messageID: message.id, threadID: message.threadID)
            guard active, generation == focusGeneration else { return }
            guard let value else { missingMessage = true; isLoadingThread = false; return }
            guard value.id == message.id, value.conversationID == message.conversationID,
                  value.encryptionState == .notEncrypted else { throw InteractionError.invalidResponse }
            focusedMessage = value
            let rootID = value.threadID ?? value.id
            if rootID == value.id { root = value }
            else {
                let parent = try await repository.message(conversationID: value.conversationID, messageID: rootID, threadID: nil)
                guard active, generation == focusGeneration else { return }
                guard let parent, parent.id == rootID, parent.conversationID == value.conversationID,
                      parent.encryptionState == .notEncrypted else { throw InteractionError.invalidResponse }
                root = parent
            }
            isLoadingThread = false
            if availability.supportedFeatures.contains(.threadedReplies) { await loadReplies() }
            await loadPolicy()
            await recoverEdits()
        } catch {
            guard active, generation == focusGeneration else { return }
            isLoadingThread = false; threadError = true
        }
    }

    func loadReplies(more: Bool = false) async {
        guard active, let root, !isLoadingThread, availability.supportedFeatures.contains(.threadedReplies) else { return }
        if more { guard replies.hasMoreBefore, replies.previousCursor != nil else { return } }
        let generation = focusGeneration
        let cursor = more ? replies.previousCursor : nil
        isLoadingThread = true; threadError = false
        do {
            let page = try await repository.listReplies(conversationID: root.conversationID, threadID: root.id, before: cursor, limit: 50)
            guard active, generation == focusGeneration else { return }
            guard page.messages.allSatisfy({ $0.conversationID == root.conversationID && $0.threadID == root.id
                && $0.id != root.id && $0.encryptionState == .notEncrypted }),
                  !page.hasMoreBefore || (page.previousCursor != nil && page.previousCursor != cursor) else {
                throw InteractionError.invalidResponse
            }
            var values = more ? replies.messages : []
            for message in page.messages {
                if let index = values.firstIndex(where: { $0.id == message.id }) { values[index] = message }
                else { values.append(message) }
            }
            replies = MobileChatMessageCache(messages: values.sorted { $0.sentAt < $1.sentAt },
                previousCursor: page.previousCursor, hasMoreBefore: page.hasMoreBefore)
            isLoadingThread = false
        } catch {
            guard active, generation == focusGeneration else { return }
            threadError = true; isLoadingThread = false
        }
    }

    @discardableResult
    func edit(_ original: ChatMessage, text: String) async -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit(original), !body.isEmpty, body != original.text else { return false }
        let entry = MobileChatInteractionStore.Entry(id: UUID(), context: context, kind: .edit,
            conversationID: original.conversationID, messageID: original.id, threadID: original.threadID,
            senderID: original.senderID, textDigest: MobileChatInteractionStore.digest(body))
        guard recovery.reserve(entry) else { mutationErrorKey = "mobile.chat.interaction.storage-error"; return false }
        isMutating = true; mutationErrorKey = nil
        defer { isMutating = false }
        do {
            let value = try await repository.editMessage(original, text: body, clientRequestID: entry.id)
            guard matchesEdit(value, entry: entry) else { throw InteractionError.invalidResponse }
            guard recovery.finish(entry) else { mutationErrorKey = "mobile.chat.interaction.storage-error"; return false }
            guard active else { return false }
            update(value)
            return true
        } catch {
            if let error = error as? AppError, error.category != .partialFailure {
                recovery.finish(entry)
                if active { mutationErrorKey = "mobile.chat.interaction.edit-failed" }
            } else if active { mutationErrorKey = "mobile.chat.interaction.edit-pending" }
            return false
        }
    }

    @discardableResult
    func sendReply(_ text: String) async -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendReply(body), let root else { return false }
        let entry = MobileChatInteractionStore.Entry(id: UUID(), context: context, kind: .reply,
            conversationID: root.conversationID, messageID: root.id, threadID: root.id,
            senderID: root.senderID, textDigest: MobileChatInteractionStore.digest(body))
        guard recovery.reserve(entry) else { mutationErrorKey = "mobile.chat.interaction.storage-error"; return false }
        isMutating = true; mutationErrorKey = nil
        let generation = focusGeneration
        defer { isMutating = false }
        do {
            let draft = try ChatMessageDraft(clientRequestID: entry.id, conversationID: root.conversationID, text: body, threadID: root.id)
            let outcome = try await repository.sendMessageResult(draft)
            if outcome.result.status == .confirmedSuccess, outcome.clientRequestID == entry.id,
               outcome.conversationID == root.conversationID, let value = outcome.confirmedMessage,
               value.conversationID == root.conversationID, value.threadID == root.id,
               value.clientRequestID == nil || value.clientRequestID == entry.id,
               value.text == body, value.encryptionState == .notEncrypted, value.isFromCurrentUser == true, value.deliveryState == .sent {
                guard recovery.finish(entry) else { mutationErrorKey = "mobile.chat.interaction.storage-error"; return false }
                guard active else { return false }
                if self.root?.id == root.id, self.root?.conversationID == root.conversationID,
                   !replies.messages.contains(where: { $0.id == value.id }) { replies.messages.append(value) }
                return true
            }
            if !outcome.result.submitted { recovery.finish(entry) }
            if active, generation == focusGeneration {
                mutationErrorKey = outcome.result.submitted ? "mobile.chat.interaction.reply-pending" : "mobile.chat.interaction.reply-failed"
            }
        } catch {
            // Repository 已提交后的网络失败返回带 submitted 的结果；抛出的普通 AppError 来自写前校验。
            if let error = error as? AppError, error.category != .partialFailure {
                recovery.finish(entry)
                if active, generation == focusGeneration { mutationErrorKey = "mobile.chat.interaction.reply-failed" }
            } else if active, generation == focusGeneration {
                mutationErrorKey = "mobile.chat.interaction.reply-pending"
            }
        }
        return false
    }

    func recoverEdits() async {
        guard active, !isMutating, !isRecovering, !recovery.failed else { return }
        isRecovering = true
        defer { isRecovering = false }
        for entry in pending where entry.kind == .edit {
            guard active else { return }
            if let value = try? await repository.message(conversationID: entry.conversationID, messageID: entry.messageID, threadID: entry.threadID),
               matchesEdit(value, entry: entry), recovery.finish(entry), active {
                update(value)
                if mutationErrorKey == "mobile.chat.interaction.edit-pending" { mutationErrorKey = nil }
            }
        }
    }

    private enum InteractionError: Error { case invalidResponse }

    private func matchesEdit(_ message: ChatMessage, entry: MobileChatInteractionStore.Entry) -> Bool {
        message.id == entry.messageID && message.conversationID == entry.conversationID
            && (message.threadID ?? message.id) == (entry.threadID ?? entry.messageID)
            && message.senderID == entry.senderID && message.isFromCurrentUser == true && message.encryptionState == .notEncrypted
            && message.text.map(MobileChatInteractionStore.digest) == entry.textDigest
    }

    func update(_ message: ChatMessage) {
        if focusedMessage?.id == message.id, focusedMessage?.conversationID == message.conversationID { focusedMessage = message }
        if root?.id == message.id, root?.conversationID == message.conversationID { root = message }
        if let index = replies.messages.firstIndex(where: { $0.id == message.id && $0.conversationID == message.conversationID }) { replies.messages[index] = message }
        if let index = searchMessages.firstIndex(where: { $0.id == message.id && $0.conversationID == message.conversationID }) { searchMessages[index] = message }
        owner?.applyInteractionMessage(message)
    }
}

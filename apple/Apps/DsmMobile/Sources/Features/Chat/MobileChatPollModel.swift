import DsmCore
import Foundation
import Observation

@MainActor
@Observable
final class MobileChatPollModel {
    let context: String
    let recovery: MobileChatPollStore
    private let repository: any ChatRepository
    private weak var owner: MobileChatModel?
    private var active = true
    private var generation = 0
    private(set) var availability = ChatAvailability(status: .requiresValidation)
    private(set) var message: ChatMessage?
    private(set) var lastCreatedMessage: ChatMessage?
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private(set) var missing = false
    private(set) var isMutating = false
    private(set) var isRecovering = false
    private(set) var errorKey: String?

    init(context: String, repository: any ChatRepository, recovery: MobileChatPollStore, owner: MobileChatModel? = nil) {
        self.context = context; self.repository = repository; self.recovery = recovery; self.owner = owner
    }

    var pending: [MobileChatPollStore.Entry] { recovery.entries.filter { $0.context == context } }
    var hasVoting: Bool { active && availability.status == .available && availability.supportedFeatures.contains(.pollVoting) }

    func updateAvailability(_ value: ChatAvailability) {
        availability = value
        if value.status != .available { close() }
    }
    func invalidate() { active = false; close(); lastCreatedMessage = nil }
    func close() { generation &+= 1; message = nil; isLoading = false; loadFailed = false; missing = false; errorKey = nil }

    func canCreate(in conversation: ChatConversation) -> Bool {
        active && availability.status == .available && availability.supportedFeatures.contains(.poll)
            && owner?.management?.blocksWrites(in: conversation.id) != true
            && !conversation.isEncrypted && !isMutating && !isRecovering && !recovery.failed
            && (owner == nil || owner?.state.selectedConversationID == conversation.id)
            && !pending.contains { $0.kind == .create && $0.conversationID == conversation.id }
    }

    func canVote(_ value: ChatMessage, choices: Set<String>) -> Bool {
        guard hasVoting, let poll = value.poll, !isMutating, !isRecovering, !isLoading, !loadFailed, !recovery.failed,
              value.encryptionState == .notEncrypted, value.deliveryState == .sent,
              !poll.isClosed, poll.closesAt.map({ $0 > Date() }) != false,
              !choices.isEmpty, poll.allowsMultipleSelection || choices.count == 1,
              choices.isSubset(of: Set(poll.options.map(\.id))),
              choices != Set(poll.options.filter(\.isSelectedByCurrentUser).map(\.id)),
              owner?.management?.blocksWrites(in: value.conversationID) != true,
              owner?.state.deletingMessageID != value.id,
              owner?.deletion?.protects(value) != true else { return false }
        return !pending.contains { $0.kind == .vote && $0.conversationID == value.conversationID && $0.messageID == value.id }
    }

    func open(_ original: ChatMessage) async {
        guard hasVoting else { return }
        generation &+= 1; let current = generation
        message = nil; isLoading = true; loadFailed = false; missing = false; errorKey = nil
        defer { if active, generation == current { isLoading = false } }
        do {
            let value = try await repository.pollMessage(conversationID: original.conversationID, messageID: original.id, threadID: original.threadID)
            guard active, generation == current else { return }
            guard let value else { missing = true; return }
            guard value.id == original.id, value.conversationID == original.conversationID,
                  value.poll != nil, value.encryptionState == .notEncrypted else { throw PollError.invalidResponse }
            message = value; apply(value)
            for entry in pending where entry.kind == .vote && entry.messageID == value.id && entry.conversationID == value.conversationID {
                if matches(value, entry: entry) { recovery.finish(entry) }
            }
        } catch { if active, generation == current { loadFailed = true } }
    }

    func create(in conversation: ChatConversation, question: String, options: [String], multiple: Bool, anonymous: Bool) async -> Bool {
        guard canCreate(in: conversation), !Task.isCancelled else { return false }
        let draft: ChatPollDraft
        do {
            guard (2...10).contains(options.count), options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw PollError.invalidInput }
            draft = try ChatPollDraft(conversationID: conversation.id, question: question, options: options,
                allowsMultipleSelection: multiple, isAnonymous: anonymous)
        } catch { errorKey = "mobile.chat.poll.invalid"; return false }
        isMutating = true; errorKey = nil
        defer { isMutating = false }
        // 冻结草稿后重读可见会话，不能使用旧页面的加密/访问状态发起写入。
        do {
            let values = try await repository.listConversations()
            guard active, !Task.isCancelled else { return false }
            guard values.contains(where: { $0.id == conversation.id && !$0.isEncrypted }) else { throw PollError.unavailable }
        } catch { if active { errorKey = "mobile.chat.poll.create-failed" }; return false }
        let entry = MobileChatPollStore.Entry(id: draft.clientRequestID, context: context, kind: .create,
            conversationID: draft.conversationID, messageID: nil, threadID: nil,
            contentDigest: Self.digest(draft), choicesDigest: nil)
        guard recovery.reserve(entry) else { errorKey = "mobile.chat.interaction.storage-error"; return false }
        do {
            let store = recovery
            let value = try await repository.createPoll(draft) { id in try await store.recordCreatedMessage(id, entry: entry) }
            guard let saved = recovery.entries.first(where: { $0.id == entry.id }), matches(value, entry: saved),
                  value.clientRequestID == nil || value.clientRequestID == entry.id else { throw PollError.invalidResponse }
            guard recovery.finish(entry) else { if active { errorKey = "mobile.chat.interaction.storage-error" }; return false }
            guard active else { return false }
            lastCreatedMessage = value; apply(value, created: true); return true
        } catch {
            handle(error, entry: entry, pendingKey: "mobile.chat.poll.create-pending", failureKey: "mobile.chat.poll.create-failed")
            return false
        }
    }

    func vote(_ original: ChatMessage, choices: Set<String>) async -> Bool {
        guard canVote(original, choices: choices), !Task.isCancelled else { return false }
        let entry = MobileChatPollStore.Entry(id: UUID(), context: context, kind: .vote, conversationID: original.conversationID,
            messageID: original.id, threadID: original.threadID, contentDigest: Self.digest(original.poll!, includeIDs: true),
            choicesDigest: Self.choicesDigest(choices))
        guard recovery.reserve(entry) else { errorKey = "mobile.chat.interaction.storage-error"; return false }
        isMutating = true; errorKey = nil
        defer { isMutating = false }
        do {
            let value = try await repository.vote(original, choiceIDs: choices, clientRequestID: entry.id)
            guard matches(value, entry: entry) else { throw PollError.invalidResponse }
            guard recovery.finish(entry) else { if active { errorKey = "mobile.chat.interaction.storage-error" }; return false }
            guard active else { return false }
            if message?.id == value.id, message?.conversationID == value.conversationID { message = value }
            apply(value); return true
        } catch {
            handle(error, entry: entry, pendingKey: "mobile.chat.poll.vote-pending", failureKey: "chat.vote.unavailable")
            return false
        }
    }

    func recover() async {
        guard active, !isMutating, !isRecovering, !recovery.failed else { return }
        isRecovering = true
        defer { isRecovering = false }
        for entry in pending {
            guard active, !Task.isCancelled else { return }
            guard let id = entry.messageID else { continue }
            do {
                // 同时重读当前账号与会话，重启后的 Repository 尚无作者身份缓存。
                let value = try await repository.pollMessage(conversationID: entry.conversationID, messageID: id, threadID: entry.threadID)
                guard active else { return }
                if let value, matches(value, entry: entry), recovery.finish(entry) {
                    if message?.id == id, message?.conversationID == value.conversationID { message = value }
                    apply(value, created: entry.kind == .create)
                    errorKey = nil
                }
            } catch { /* 恢复只有读取；失败保留原记录与该目标限制。 */ }
        }
    }

    private func handle(_ error: Error, entry: MobileChatPollStore.Entry, pendingKey: String, failureKey: String) {
        // 共享 Repository 将发送后的网络/取消/回读失败转换为 partialFailure。
        let rejected = (error as? AppError).map { $0.category != .partialFailure } == true
            || error is MobileReadOnlyChatRepositoryError
        if rejected { recovery.finish(entry) }
        if active { errorKey = recovery.failed ? "mobile.chat.interaction.storage-error" : (rejected ? failureKey : pendingKey) }
    }

    private func matches(_ value: ChatMessage, entry: MobileChatPollStore.Entry) -> Bool {
        guard value.id == entry.messageID, value.conversationID == entry.conversationID,
              value.encryptionState == .notEncrypted, value.deliveryState == .sent, let poll = value.poll else { return false }
        if entry.kind == .create {
            return value.isFromCurrentUser == true && Self.digest(poll, includeIDs: false) == entry.contentDigest
        }
        return (value.threadID ?? value.id) == (entry.threadID ?? entry.messageID)
            && Self.digest(poll, includeIDs: true) == entry.contentDigest
            && Self.choicesDigest(Set(poll.options.filter(\.isSelectedByCurrentUser).map(\.id))) == entry.choicesDigest
    }

    private func apply(_ value: ChatMessage, created: Bool = false) { owner?.applyPollMessage(value, created: created) }

    private static func digest(_ draft: ChatPollDraft) -> String {
        digest(ChatPoll(id: "", question: draft.question, allowsMultipleSelection: draft.allowsMultipleSelection,
            isAnonymous: draft.isAnonymous, closesAt: draft.closesAt,
            options: draft.options.map { ChatPollOption(id: "", text: $0) }), includeIDs: false)
    }
    private static func digest(_ poll: ChatPoll, includeIDs: Bool) -> String {
        let fields = [poll.question, String(poll.allowsMultipleSelection), String(poll.isAnonymous),
                      poll.closesAt.map { String($0.timeIntervalSince1970) } ?? ""] + poll.options.map(\.text)
            + (includeIDs ? [poll.id] + poll.options.map(\.id) : [])
        return hash(fields)
    }
    private static func choicesDigest(_ choices: Set<String>) -> String { hash(choices.sorted()) }
    private static func hash(_ fields: [String]) -> String {
        // 长度前缀避免正文换行或分隔字符产生相同的结构摘要。
        MobileChatInteractionStore.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
    }
    private enum PollError: Error { case invalidInput, invalidResponse, unavailable }
}

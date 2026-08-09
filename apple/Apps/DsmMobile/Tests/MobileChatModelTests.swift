import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatModelTests: XCTestCase {
    func test只读适配层拒绝写入附件和高级能力且不调用底层() async throws {
        let base = ChatRepositoryStub(
            availability: ChatAvailability(
                status: .available,
                supportedFeatures: [.textMessage, .groupConversation]
            ),
            conversations: []
        )
        let repository = MobileReadOnlyChatRepository(base: base)
        let draft = try ChatMessageDraft(conversationID: "conversation", text: "不会发送")
        let groupDraft = try ChatGroupDraft(
            title: "不会创建",
            memberIDs: ["member-1", "member-2"],
            isEncrypted: false
        )
        let pollDraft = try ChatPollDraft(
            conversationID: "conversation",
            question: "不会投票",
            options: ["A", "B"],
            allowsMultipleSelection: false,
            isAnonymous: false
        )

        await assertReadOnlyFailure {
            try await repository.openDirectConversation(userID: "user", clientRequestID: UUID())
        }
        await assertReadOnlyFailure { try await repository.createGroup(groupDraft) }
        await assertReadOnlyFailure { try await repository.sendMessage(draft) }
        await assertReadOnlyFailure {
            try await repository.deleteMessage(
                conversationID: "conversation",
                messageID: "message",
                clientRequestID: UUID()
            )
        }
        await assertReadOnlyFailure {
            try await repository.closeConversation(
                conversationID: "conversation",
                clientRequestID: UUID()
            )
        }
        await assertReadOnlyFailure {
            try await repository.listConversationMembers(conversationID: "conversation")
        }
        await assertReadOnlyFailure {
            try await repository.setMessagePinned(
                conversationID: "conversation",
                messageID: "message",
                isPinned: true,
                clientRequestID: UUID()
            )
        }
        await assertReadOnlyFailure {
            try await repository.forwardMessage(
                messageID: "message",
                toConversationIDs: ["another"],
                clientRequestID: UUID()
            )
        }
        await assertReadOnlyFailure {
            try await repository.setReminder(
                messageID: "message",
                remindAt: Date(),
                clientRequestID: UUID()
            )
        }
        await assertReadOnlyFailure {
            try await repository.listReminders(conversationID: "conversation")
        }
        await assertReadOnlyFailure {
            try await repository.deleteReminder(
                messageID: "message",
                conversationID: "conversation",
                clientRequestID: UUID()
            )
        }
        await assertReadOnlyFailure {
            try await repository.loadAttachmentThumbnail(messageID: "message", size: .small)
        }
        await assertReadOnlyFailure {
            try await repository.downloadAttachment(
                messageID: "message",
                to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                progress: { _, _ in }
            )
        }
        await assertReadOnlyFailure {
            try await repository.listPinnedMessages(conversationID: "conversation")
        }
        await assertReadOnlyFailure {
            try await repository.listScheduledMessages(conversationID: "conversation")
        }
        await assertReadOnlyFailure {
            try await repository.createScheduledMessage(
                conversationID: "conversation",
                text: "不会发送",
                sendAt: Date(),
                clientRequestID: UUID()
            )
        }
        await assertReadOnlyFailure {
            try await repository.deleteScheduledMessage(
                id: "scheduled",
                conversationID: "conversation",
                clientRequestID: UUID()
            )
        }
        await assertReadOnlyFailure { try await repository.createPoll(pollDraft) }

        let availability = await repository.availability()
        XCTAssertEqual(availability.status, .available)
        XCTAssertTrue(availability.supportedFeatures.isEmpty)
        let events = await repository.realtimeEvents()
        var receivedEvents: [ChatRealtimeEvent] = []
        for await event in events { receivedEvents.append(event) }
        await repository.startRealtime()
        await repository.stopRealtime()

        let nonReadCallCount = await base.nonReadCallCount()
        let realtimeCallCount = await base.realtimeCallCount()
        XCTAssertEqual(nonReadCallCount, 0)
        XCTAssertEqual(realtimeCallCount, 0)
        XCTAssertTrue(receivedEvents.isEmpty)
    }

    func test激活会发现可用性并加载会话首屏() async {
        let conversation = Self.conversation(id: "c1", title: "家庭")
        let repository = ChatRepositoryStub(conversations: [conversation])
        let model = MobileChatModel()

        await model.activate(profileID: UUID(), repository: repository)

        XCTAssertEqual(model.state.availability.status, .available)
        XCTAssertEqual(model.state.visibleConversations, [conversation])
        XCTAssertEqual(model.state.conversationPageState, .content)
        let requestCount = await repository.conversationRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func test本地筛选为空使用筛选空态且不重复读取会话() async {
        let repository = ChatRepositoryStub(
            conversations: [Self.conversation(id: "c1", title: "项目讨论")]
        )
        let model = MobileChatModel()
        await model.activate(profileID: UUID(), repository: repository)

        model.setConversationFilter("家庭")

        XCTAssertTrue(model.state.visibleConversations.isEmpty)
        XCTAssertEqual(model.state.conversationPageState, .filteredEmpty)
        let requestCount = await repository.conversationRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func test服务不可用时不读取会话并保留明确可用性() async {
        let repository = ChatRepositoryStub(
            availability: ChatAvailability(status: .unavailable),
            conversations: [Self.conversation(id: "never", title: "不应读取")]
        )
        let model = MobileChatModel()

        await model.activate(profileID: UUID(), repository: repository)

        XCTAssertEqual(model.state.availability.status, .unavailable)
        XCTAssertEqual(model.state.conversationPageState, .empty)
        XCTAssertTrue(model.state.conversations.isEmpty)
        let requestCount = await repository.conversationRequestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func test需要验证时不读取会话且不暴露底层能力() async {
        let repository = ChatRepositoryStub(
            availability: ChatAvailability(
                status: .requiresValidation,
                supportedFeatures: [.textMessage]
            ),
            conversations: [Self.conversation(id: "never", title: "不应读取")]
        )
        let model = MobileChatModel()

        await model.activate(profileID: UUID(), repository: repository)

        XCTAssertEqual(model.state.availability.status, .requiresValidation)
        XCTAssertTrue(model.state.availability.supportedFeatures.isEmpty)
        XCTAssertEqual(model.state.conversationPageState, .empty)
        let requestCount = await repository.conversationRequestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func test选择非加密会话加载消息首屏并按ID去重排序() async {
        let conversation = Self.conversation(id: "c1", title: "家庭")
        let later = Self.message(id: "m2", conversationID: conversation.id, seconds: 20)
        let earlier = Self.message(id: "m1", conversationID: conversation.id, seconds: 10)
        let replacement = Self.message(
            id: "m1",
            conversationID: conversation.id,
            seconds: 10,
            text: "更新后的正文"
        )
        let repository = ChatRepositoryStub(
            conversations: [conversation],
            pages: [
                .init(conversationID: conversation.id, cursor: nil): ChatMessagePage(
                    messages: [later, earlier, replacement],
                    previousCursor: "raw-cursor-1",
                    hasMoreBefore: true
                )
            ]
        )
        let model = MobileChatModel()
        await model.activate(profileID: UUID(), repository: repository)

        await model.selectConversation(conversation)

        XCTAssertEqual(model.state.selectedMessages.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(model.state.selectedMessages.messages.first?.text, "更新后的正文")
        XCTAssertEqual(model.state.selectedMessages.previousCursor, "raw-cursor-1")
        XCTAssertTrue(model.state.selectedMessages.hasMoreBefore)
        XCTAssertEqual(model.state.messagePageState, .content)
    }

    func test向上分页透传原始Cursor并合并去重() async {
        let conversation = Self.conversation(id: "c1", title: "家庭")
        let middle = Self.message(id: "m2", conversationID: conversation.id, seconds: 20)
        let latest = Self.message(id: "m3", conversationID: conversation.id, seconds: 30)
        let oldest = Self.message(id: "m1", conversationID: conversation.id, seconds: 10)
        let repository = ChatRepositoryStub(
            conversations: [conversation],
            pages: [
                .init(conversationID: conversation.id, cursor: nil): .init(
                    messages: [middle, latest],
                    previousCursor: "opaque::cursor/一",
                    hasMoreBefore: true
                ),
                .init(conversationID: conversation.id, cursor: "opaque::cursor/一"): .init(
                    messages: [oldest, middle],
                    previousCursor: "opaque::cursor/二",
                    hasMoreBefore: false
                )
            ]
        )
        let model = MobileChatModel()
        await model.activate(profileID: UUID(), repository: repository)
        await model.selectConversation(conversation)

        await model.loadMoreMessages()

        XCTAssertEqual(model.state.selectedMessages.messages.map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(model.state.selectedMessages.previousCursor, "opaque::cursor/二")
        XCTAssertFalse(model.state.selectedMessages.hasMoreBefore)
        let requests = await repository.messageRequests()
        XCTAssertEqual(
            requests,
            [
                .init(conversationID: conversation.id, cursor: nil),
                .init(conversationID: conversation.id, cursor: "opaque::cursor/一")
            ]
        )
    }

    func test加载更多失败保留已有消息和Cursor() async {
        let conversation = Self.conversation(id: "c1", title: "家庭")
        let existing = Self.message(id: "m2", conversationID: conversation.id, seconds: 20)
        let firstKey = ChatMessageRequest(conversationID: conversation.id, cursor: nil)
        let moreKey = ChatMessageRequest(conversationID: conversation.id, cursor: "cursor")
        let repository = ChatRepositoryStub(
            conversations: [conversation],
            pages: [
                firstKey: .init(messages: [existing], previousCursor: "cursor", hasMoreBefore: true)
            ],
            failures: [moreKey: Self.networkError]
        )
        let model = MobileChatModel()
        await model.activate(profileID: UUID(), repository: repository)
        await model.selectConversation(conversation)

        await model.loadMoreMessages()

        XCTAssertEqual(model.state.selectedMessages.messages, [existing])
        XCTAssertEqual(model.state.selectedMessages.previousCursor, "cursor")
        XCTAssertTrue(model.state.loadMoreMessagesFailed)
        XCTAssertEqual(model.state.messageErrorCategory, .networkUnavailable)
    }

    func test刷新失败保留已有消息() async {
        let conversation = Self.conversation(id: "c1", title: "家庭")
        let existing = Self.message(id: "m1", conversationID: conversation.id, seconds: 10)
        let request = ChatMessageRequest(conversationID: conversation.id, cursor: nil)
        let repository = ChatRepositoryStub(
            conversations: [conversation],
            pages: [request: .init(messages: [existing], previousCursor: nil, hasMoreBefore: false)]
        )
        let model = MobileChatModel()
        await model.activate(profileID: UUID(), repository: repository)
        await model.selectConversation(conversation)
        await repository.setFailure(Self.networkError, for: request)

        await model.refreshMessages()

        XCTAssertEqual(model.state.selectedMessages.messages, [existing])
        XCTAssertEqual(model.state.messagePageState, .content)
        XCTAssertEqual(model.state.messageErrorCategory, .networkUnavailable)
    }

    func test加密会话可见但不会请求或缓存正文() async {
        let encrypted = Self.conversation(id: "secret", title: "加密会话", isEncrypted: true)
        let repository = ChatRepositoryStub(
            conversations: [encrypted],
            pages: [
                .init(conversationID: encrypted.id, cursor: nil): .init(
                    messages: [Self.message(
                        id: "secret-message",
                        conversationID: encrypted.id,
                        seconds: 1,
                        text: "不得进入模型"
                    )],
                    previousCursor: nil,
                    hasMoreBefore: false
                )
            ]
        )
        let model = MobileChatModel()
        let profileID = UUID()
        await model.activate(profileID: profileID, repository: repository)

        await model.selectConversation(encrypted)

        XCTAssertTrue(model.state.selectedConversationIsEncrypted)
        XCTAssertTrue(model.state.selectedMessages.messages.isEmpty)
        XCTAssertNil(model.profiles[profileID]?.messagesByConversation[encrypted.id])
        let messageRequests = await repository.messageRequests()
        XCTAssertTrue(messageRequests.isEmpty)
    }

    func test会话从普通更新为加密时清除已有正文缓存() async {
        let plain = Self.conversation(id: "c1", title: "会话")
        let encrypted = Self.conversation(id: "c1", title: "会话", isEncrypted: true)
        let repository = ChatRepositoryStub(
            conversations: [plain],
            pages: [
                .init(conversationID: plain.id, cursor: nil): .init(
                    messages: [Self.message(id: "m1", conversationID: plain.id, seconds: 1)],
                    previousCursor: nil,
                    hasMoreBefore: false
                )
            ]
        )
        let model = MobileChatModel()
        let profileID = UUID()
        await model.activate(profileID: profileID, repository: repository)
        await model.selectConversation(plain)
        await repository.setConversations([encrypted])

        await model.reloadConversations()

        XCTAssertTrue(model.state.selectedConversationIsEncrypted)
        XCTAssertTrue(model.state.selectedMessages.messages.isEmpty)
        XCTAssertNil(model.profiles[profileID]?.messagesByConversation[plain.id])
    }

    func test消息页混入其他会话正文时不会进入当前缓存() async {
        let conversation = Self.conversation(id: "c1", title: "会话")
        let valid = Self.message(id: "valid", conversationID: conversation.id, seconds: 1)
        let foreign = Self.message(id: "foreign", conversationID: "c2", seconds: 2)
        let repository = ChatRepositoryStub(
            conversations: [conversation],
            pages: [
                .init(conversationID: conversation.id, cursor: nil): .init(
                    messages: [valid, foreign],
                    previousCursor: nil,
                    hasMoreBefore: false
                )
            ]
        )
        let model = MobileChatModel()
        await model.activate(profileID: UUID(), repository: repository)

        await model.selectConversation(conversation)

        XCTAssertEqual(model.state.selectedMessages.messages, [valid])
    }

    func test消息刷新阻塞时会话刷新可独立完成且最终状态收口() async {
        let conversation = Self.conversation(id: "c1", title: "会话")
        let request = ChatMessageRequest(conversationID: conversation.id, cursor: nil)
        let message = Self.message(id: "m1", conversationID: conversation.id, seconds: 1)
        let repository = ChatRepositoryStub(
            conversations: [conversation],
            pages: [request: .init(messages: [message], previousCursor: nil, hasMoreBefore: false)]
        )
        let model = MobileChatModel()
        await model.activate(profileID: UUID(), repository: repository)
        await model.selectConversation(conversation)
        await repository.blockMessage(request)

        let messageTask = Task { await model.refreshMessages() }
        await repository.waitUntilMessageBlocked(request)
        await model.reloadConversations()
        await repository.releaseMessage(request)
        await messageTask.value

        XCTAssertFalse(model.state.isRefreshingConversations)
        XCTAssertFalse(model.state.isRefreshingMessages)
        XCTAssertFalse(model.state.isLoadingMoreMessages)
        XCTAssertEqual(model.state.selectedMessages.messages, [message])
    }

    func test消息刷新阻塞时加载更多不会取消刷新或发起分页请求() async {
        let conversation = Self.conversation(id: "c1", title: "会话")
        let refreshRequest = ChatMessageRequest(conversationID: conversation.id, cursor: nil)
        let pageRequest = ChatMessageRequest(conversationID: conversation.id, cursor: "older")
        let message = Self.message(id: "m1", conversationID: conversation.id, seconds: 1)
        let repository = ChatRepositoryStub(
            conversations: [conversation],
            pages: [
                refreshRequest: .init(
                    messages: [message],
                    previousCursor: "older",
                    hasMoreBefore: true
                ),
                pageRequest: .init(messages: [], previousCursor: nil, hasMoreBefore: false)
            ]
        )
        let model = MobileChatModel()
        await model.activate(profileID: UUID(), repository: repository)
        await model.selectConversation(conversation)
        await repository.blockMessage(refreshRequest)

        let refreshTask = Task { await model.refreshMessages() }
        await repository.waitUntilMessageBlocked(refreshRequest)
        XCTAssertTrue(model.state.isRefreshingMessages)
        await model.loadMoreMessages()
        let requestsWhileBlocked = await repository.messageRequests()
        XCTAssertEqual(requestsWhileBlocked, [refreshRequest, refreshRequest])
        XCTAssertFalse(requestsWhileBlocked.contains(pageRequest))
        await repository.releaseMessage(refreshRequest)
        await refreshTask.value

        XCTAssertFalse(model.state.isRefreshingMessages)
        XCTAssertFalse(model.state.isLoadingMoreMessages)
        XCTAssertFalse(model.state.loadMoreMessagesFailed)
        XCTAssertEqual(model.state.selectedMessages.messages, [message])
    }

    func test消息首屏阻塞时本地筛选不取消读取且最终完成() async {
        let conversation = Self.conversation(id: "c1", title: "家庭会话")
        let request = ChatMessageRequest(conversationID: conversation.id, cursor: nil)
        let message = Self.message(id: "m1", conversationID: conversation.id, seconds: 1)
        let repository = ChatRepositoryStub(
            conversations: [conversation],
            pages: [request: .init(messages: [message], previousCursor: nil, hasMoreBefore: false)],
            blockedMessageRequests: [request]
        )
        let model = MobileChatModel()
        await model.activate(profileID: UUID(), repository: repository)

        let task = Task { await model.selectConversation(conversation) }
        await repository.waitUntilMessageBlocked(request)
        model.setConversationFilter("家庭")
        await repository.releaseMessage(request)
        await task.value

        XCTAssertEqual(model.state.conversationFilter, "家庭")
        XCTAssertEqual(model.state.selectedMessages.messages, [message])
        XCTAssertFalse(model.state.isRefreshingMessages)
        XCTAssertFalse(model.state.isLoadingMoreMessages)
    }

    func test会话刷新阻塞时选择缓存消息且两条状态最终收口() async {
        let conversationA = Self.conversation(id: "a", title: "A")
        let conversationB = Self.conversation(id: "b", title: "B")
        let messageA = Self.message(id: "a1", conversationID: "a", seconds: 1)
        let messageB = Self.message(id: "b1", conversationID: "b", seconds: 2)
        let repository = ChatRepositoryStub(
            conversations: [conversationA, conversationB],
            pages: [
                .init(conversationID: "a", cursor: nil): .init(
                    messages: [messageA], previousCursor: nil, hasMoreBefore: false
                ),
                .init(conversationID: "b", cursor: nil): .init(
                    messages: [messageB], previousCursor: nil, hasMoreBefore: false
                )
            ]
        )
        let model = MobileChatModel()
        await model.activate(profileID: UUID(), repository: repository)
        await model.selectConversation(conversationA)
        await model.selectConversation(conversationB)
        await repository.blockConversationList()

        let refreshTask = Task { await model.reloadConversations() }
        await repository.waitUntilConversationListBlocked()
        await model.selectConversation(conversationA)
        XCTAssertEqual(model.state.selectedMessages.messages, [messageA])
        await repository.releaseConversationList()
        await refreshTask.value

        XCTAssertFalse(model.state.isRefreshingConversations)
        XCTAssertFalse(model.state.isRefreshingMessages)
        XCTAssertFalse(model.state.isLoadingMoreMessages)
        XCTAssertEqual(model.state.selectedMessages.messages, [messageA])
    }

    func test切换Profile后迟到会话结果不能覆盖当前Profile() async {
        let profileA = UUID()
        let profileB = UUID()
        let repositoryA = ChatRepositoryStub(
            conversations: [Self.conversation(id: "a", title: "A")],
            blockedConversationList: true
        )
        let conversationB = Self.conversation(id: "b", title: "B")
        let repositoryB = ChatRepositoryStub(conversations: [conversationB])
        let model = MobileChatModel()

        let oldTask = Task { await model.activate(profileID: profileA, repository: repositoryA) }
        await repositoryA.waitUntilConversationListBlocked()
        await model.activate(profileID: profileB, repository: repositoryB)
        await repositoryA.releaseConversationList()
        await oldTask.value

        XCTAssertEqual(model.activeProfileID, profileB)
        XCTAssertEqual(model.state.visibleConversations, [conversationB])
        XCTAssertTrue(model.profiles[profileA]?.conversations.isEmpty == true)
    }

    func test切换会话后迟到消息结果不能覆盖当前会话() async {
        let conversationA = Self.conversation(id: "a", title: "A")
        let conversationB = Self.conversation(id: "b", title: "B")
        let requestA = ChatMessageRequest(conversationID: "a", cursor: nil)
        let messageB = Self.message(id: "b1", conversationID: "b", seconds: 1)
        let repository = ChatRepositoryStub(
            conversations: [conversationA, conversationB],
            pages: [
                requestA: .init(
                    messages: [Self.message(id: "a1", conversationID: "a", seconds: 1)],
                    previousCursor: nil,
                    hasMoreBefore: false
                ),
                .init(conversationID: "b", cursor: nil): .init(
                    messages: [messageB],
                    previousCursor: nil,
                    hasMoreBefore: false
                )
            ],
            blockedMessageRequests: [requestA]
        )
        let model = MobileChatModel()
        await model.activate(profileID: UUID(), repository: repository)

        let oldTask = Task { await model.selectConversation(conversationA) }
        await repository.waitUntilMessageBlocked(requestA)
        await model.selectConversation(conversationB)
        await repository.releaseMessage(requestA)
        await oldTask.value

        XCTAssertEqual(model.state.selectedConversationID, conversationB.id)
        XCTAssertEqual(model.state.selectedMessages.messages, [messageB])
        XCTAssertNil(model.state.messagesByConversation[conversationA.id])
    }

    func test离开会取消请求且迟到结果不会恢复活动Profile() async {
        let repository = ChatRepositoryStub(
            conversations: [Self.conversation(id: "a", title: "A")],
            blockedConversationList: true
        )
        let model = MobileChatModel()

        let task = Task { await model.activate(profileID: UUID(), repository: repository) }
        await repository.waitUntilConversationListBlocked()
        model.deactivate()
        await repository.releaseConversationList()
        await task.value

        XCTAssertNil(model.activeProfileID)
        XCTAssertTrue(model.state.conversations.isEmpty)
    }

    func test同Profile使用NilRepository会清除旧绑定() async {
        let profileID = UUID()
        let repository = ChatRepositoryStub(conversations: [])
        let model = MobileChatModel()
        await model.activate(profileID: profileID, repository: repository)

        await model.activate(profileID: profileID, repository: nil)
        await model.reloadConversations()

        XCTAssertNil(model.activeProfileID)
        let requestCount = await repository.conversationRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func test切回Profile会恢复筛选选择和消息缓存且不重复加载() async {
        let profileA = UUID()
        let profileB = UUID()
        let conversationA = Self.conversation(id: "a", title: "家庭 A")
        let messageA = Self.message(id: "a1", conversationID: "a", seconds: 1)
        let repositoryA = ChatRepositoryStub(
            conversations: [conversationA],
            pages: [
                .init(conversationID: "a", cursor: nil): .init(
                    messages: [messageA],
                    previousCursor: nil,
                    hasMoreBefore: false
                )
            ]
        )
        let repositoryB = ChatRepositoryStub(conversations: [])
        let model = MobileChatModel()
        await model.activate(profileID: profileA, repository: repositoryA)
        model.setConversationFilter("家庭")
        await model.selectConversation(conversationA)
        await model.activate(profileID: profileB, repository: repositoryB)

        await model.activate(profileID: profileA, repository: repositoryA)

        XCTAssertEqual(model.state.conversationFilter, "家庭")
        XCTAssertEqual(model.state.selectedConversationID, conversationA.id)
        XCTAssertEqual(model.state.selectedMessages.messages, [messageA])
        let conversationRequests = await repositoryA.conversationRequestCount()
        let messageRequests = await repositoryA.messageRequests()
        XCTAssertEqual(conversationRequests, 1)
        XCTAssertEqual(messageRequests.count, 1)
    }

    func test停用后重新激活同Profile仍恢复筛选选择和消息缓存() async {
        let profileID = UUID()
        let conversation = Self.conversation(id: "c1", title: "家庭")
        let message = Self.message(id: "m1", conversationID: conversation.id, seconds: 1)
        let repository = ChatRepositoryStub(
            conversations: [conversation],
            pages: [
                .init(conversationID: conversation.id, cursor: nil): .init(
                    messages: [message], previousCursor: nil, hasMoreBefore: false
                )
            ]
        )
        let model = MobileChatModel()
        await model.activate(profileID: profileID, repository: repository)
        model.setConversationFilter("家庭")
        await model.selectConversation(conversation)

        model.deactivate()
        await model.activate(profileID: profileID, repository: repository)

        XCTAssertEqual(model.state.conversationFilter, "家庭")
        XCTAssertEqual(model.state.selectedConversationID, conversation.id)
        XCTAssertEqual(model.state.selectedMessages.messages, [message])
        let conversationRequestCount = await repository.conversationRequestCount()
        let messageRequestCount = await repository.messageRequests().count
        XCTAssertEqual(conversationRequestCount, 1)
        XCTAssertEqual(messageRequestCount, 1)
    }

    func test停用后同Profile绑定新Repository且刷新不会调用旧会话() async {
        let profileID = UUID()
        let conversation = Self.conversation(id: "c1", title: "家庭")
        let cachedMessage = Self.message(id: "m1", conversationID: conversation.id, seconds: 1)
        let oldRepository = ChatRepositoryStub(
            conversations: [conversation],
            pages: [
                .init(conversationID: conversation.id, cursor: nil): .init(
                    messages: [cachedMessage], previousCursor: nil, hasMoreBefore: false
                )
            ]
        )
        let model = MobileChatModel()
        await model.activate(profileID: profileID, repository: oldRepository)
        await model.selectConversation(conversation)

        model.deactivate()

        let refreshedConversation = Self.conversation(id: "c1", title: "新的会话标题")
        let newRepository = ChatRepositoryStub(conversations: [refreshedConversation])
        await model.activate(profileID: profileID, repository: newRepository)

        XCTAssertEqual(model.state.selectedMessages.messages, [cachedMessage])
        await model.reloadConversations()

        let oldRequestCount = await oldRepository.conversationRequestCount()
        let newRequestCount = await newRepository.conversationRequestCount()
        XCTAssertEqual(oldRequestCount, 1)
        XCTAssertEqual(newRequestCount, 1)
        XCTAssertEqual(model.state.selectedConversation?.title, "新的会话标题")
        XCTAssertEqual(model.state.selectedMessages.messages, [cachedMessage])
    }

    func test清除Profile后同ID重连必须重新读取且不保留旧消息() async {
        let profileID = UUID()
        let conversation = Self.conversation(id: "c1", title: "家庭")
        let oldMessage = Self.message(
            id: "old",
            conversationID: conversation.id,
            seconds: 1,
            text: "退出前正文"
        )
        let oldRepository = ChatRepositoryStub(
            conversations: [conversation],
            pages: [
                .init(conversationID: conversation.id, cursor: nil): .init(
                    messages: [oldMessage], previousCursor: nil, hasMoreBefore: false
                )
            ]
        )
        let model = MobileChatModel()
        await model.activate(profileID: profileID, repository: oldRepository)
        await model.selectConversation(conversation)

        model.purge(profileID: profileID)

        XCTAssertNil(model.activeProfileID)
        XCTAssertNil(model.profiles[profileID])

        let newMessage = Self.message(
            id: "new",
            conversationID: conversation.id,
            seconds: 2,
            text: "重新登录正文"
        )
        let newRepository = ChatRepositoryStub(
            conversations: [conversation],
            pages: [
                .init(conversationID: conversation.id, cursor: nil): .init(
                    messages: [newMessage], previousCursor: nil, hasMoreBefore: false
                )
            ]
        )
        await model.activate(profileID: profileID, repository: newRepository)

        XCTAssertNil(model.state.selectedConversationID)
        XCTAssertTrue(model.state.messagesByConversation.isEmpty)
        let conversationRequestCount = await newRepository.conversationRequestCount()
        XCTAssertEqual(conversationRequestCount, 1)

        await model.selectConversation(conversation)

        XCTAssertEqual(model.state.selectedMessages.messages, [newMessage])
        XCTAssertFalse(model.state.selectedMessages.messages.contains(oldMessage))
        let messageRequestCount = await newRepository.messageRequests().count
        XCTAssertEqual(messageRequestCount, 1)
    }

    private func assertReadOnlyFailure<T>(
        _ operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("应拒绝非只读操作", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? MobileReadOnlyChatRepositoryError,
                .operationUnavailable,
                file: file,
                line: line
            )
        }
    }

    private static func conversation(
        id: String,
        title: String,
        isEncrypted: Bool = false
    ) -> ChatConversation {
        ChatConversation(
            id: id,
            kind: .group,
            title: title,
            memberIDs: [],
            isEncrypted: isEncrypted
        )
    }

    private static func message(
        id: String,
        conversationID: String,
        seconds: TimeInterval,
        text: String = "正文"
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            conversationID: conversationID,
            senderID: "sender",
            sentAt: Date(timeIntervalSince1970: seconds),
            text: text
        )
    }

    private static let networkError = AppError(
        category: .networkUnavailable,
        isRetryable: true,
        safeUserMessage: "测试网络错误"
    )
}

private struct ChatMessageRequest: Hashable, Sendable {
    let conversationID: String
    let cursor: String?
}

private actor ChatRepositoryStub: ChatRepository {
    private let availabilityValue: ChatAvailability
    private var conversationValues: [ChatConversation]
    private var pages: [ChatMessageRequest: ChatMessagePage]
    private var failures: [ChatMessageRequest: AppError]
    private var conversationRequests = 0
    private var messageRequestValues: [ChatMessageRequest] = []
    private var rejectedBaseCalls = 0
    private var realtimeBaseCalls = 0

    private var blocksConversationList: Bool
    private var conversationListContinuation: CheckedContinuation<Void, Never>?
    private var conversationListBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedMessageRequests: Set<ChatMessageRequest>
    private var messageContinuations: [ChatMessageRequest: CheckedContinuation<Void, Never>] = [:]
    private var messageBlockedWaiters: [ChatMessageRequest: [CheckedContinuation<Void, Never>]] = [:]

    init(
        availability: ChatAvailability = ChatAvailability(status: .available),
        conversations: [ChatConversation],
        pages: [ChatMessageRequest: ChatMessagePage] = [:],
        failures: [ChatMessageRequest: AppError] = [:],
        blockedConversationList: Bool = false,
        blockedMessageRequests: Set<ChatMessageRequest> = []
    ) {
        availabilityValue = availability
        conversationValues = conversations
        self.pages = pages
        self.failures = failures
        blocksConversationList = blockedConversationList
        self.blockedMessageRequests = blockedMessageRequests
    }

    func availability() async -> ChatAvailability { availabilityValue }

    func listUsers() async throws -> [ChatUser] { [] }

    func listConversations() async throws -> [ChatConversation] {
        conversationRequests += 1
        if blocksConversationList {
            conversationListBlockedWaiters.forEach { $0.resume() }
            conversationListBlockedWaiters.removeAll()
            await withCheckedContinuation { conversationListContinuation = $0 }
        }
        return conversationValues
    }

    func listMessages(
        conversationID: String,
        before cursor: String?,
        limit: Int
    ) async throws -> ChatMessagePage {
        let request = ChatMessageRequest(conversationID: conversationID, cursor: cursor)
        messageRequestValues.append(request)
        if blockedMessageRequests.contains(request) {
            messageBlockedWaiters.removeValue(forKey: request)?.forEach { $0.resume() }
            await withCheckedContinuation { messageContinuations[request] = $0 }
        }
        if let failure = failures[request] { throw failure }
        return pages[request] ?? ChatMessagePage(
            messages: [],
            previousCursor: nil,
            hasMoreBefore: false
        )
    }

    func setFailure(_ error: AppError, for request: ChatMessageRequest) {
        failures[request] = error
    }

    func setConversations(_ conversations: [ChatConversation]) {
        conversationValues = conversations
    }

    func blockConversationList() {
        blocksConversationList = true
    }

    func blockMessage(_ request: ChatMessageRequest) {
        blockedMessageRequests.insert(request)
    }

    func conversationRequestCount() -> Int { conversationRequests }
    func messageRequests() -> [ChatMessageRequest] { messageRequestValues }
    func nonReadCallCount() -> Int { rejectedBaseCalls }
    func realtimeCallCount() -> Int { realtimeBaseCalls }

    func waitUntilConversationListBlocked() async {
        guard conversationListContinuation == nil else { return }
        await withCheckedContinuation { conversationListBlockedWaiters.append($0) }
    }

    func releaseConversationList() {
        blocksConversationList = false
        conversationListContinuation?.resume()
        conversationListContinuation = nil
    }

    func waitUntilMessageBlocked(_ request: ChatMessageRequest) async {
        guard messageContinuations[request] == nil else { return }
        await withCheckedContinuation { messageBlockedWaiters[request, default: []].append($0) }
    }

    func releaseMessage(_ request: ChatMessageRequest) {
        blockedMessageRequests.remove(request)
        messageContinuations.removeValue(forKey: request)?.resume()
    }

    func openDirectConversation(
        userID: String,
        clientRequestID: UUID
    ) async throws -> ChatConversation {
        rejectedBaseCalls += 1
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func createGroup(_ draft: ChatGroupDraft) async throws -> ChatConversation {
        rejectedBaseCalls += 1
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func sendMessage(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessage {
        rejectedBaseCalls += 1
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func deleteMessage(
        conversationID: String,
        messageID: String,
        clientRequestID: UUID
    ) async throws { rejectedBaseCalls += 1 }

    func closeConversation(
        conversationID: String,
        clientRequestID: UUID
    ) async throws { rejectedBaseCalls += 1 }

    func listConversationMembers(conversationID: String) async throws -> [ChatUser] {
        rejectedBaseCalls += 1
        return []
    }

    func listPinnedMessages(conversationID: String) async throws -> [ChatMessage] {
        rejectedBaseCalls += 1
        return []
    }

    func setMessagePinned(
        conversationID: String,
        messageID: String,
        isPinned: Bool,
        clientRequestID: UUID
    ) async throws { rejectedBaseCalls += 1 }

    func forwardMessage(
        messageID: String,
        toConversationIDs: [String],
        clientRequestID: UUID
    ) async throws { rejectedBaseCalls += 1 }

    func setReminder(
        messageID: String,
        remindAt: Date,
        clientRequestID: UUID
    ) async throws -> ChatReminder {
        rejectedBaseCalls += 1
        return ChatReminder(id: "unexpected", messageID: messageID, remindAt: remindAt)
    }

    func listReminders(conversationID: String) async throws -> [ChatReminder] {
        rejectedBaseCalls += 1
        return []
    }

    func deleteReminder(
        messageID: String,
        conversationID: String,
        clientRequestID: UUID
    ) async throws { rejectedBaseCalls += 1 }

    func loadAttachmentThumbnail(
        messageID: String,
        size: ChatAttachmentThumbnailSize
    ) async throws -> Data {
        rejectedBaseCalls += 1
        return Data()
    }

    func downloadAttachment(
        messageID: String,
        to destinationURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws { rejectedBaseCalls += 1 }

    func listScheduledMessages(conversationID: String) async throws -> [ChatScheduledMessage] {
        rejectedBaseCalls += 1
        return []
    }

    func createScheduledMessage(
        conversationID: String,
        text: String,
        sendAt: Date,
        clientRequestID: UUID
    ) async throws -> ChatScheduledMessage {
        rejectedBaseCalls += 1
        return ChatScheduledMessage(
            id: "unexpected",
            conversationID: conversationID,
            text: text,
            sendAt: sendAt
        )
    }

    func deleteScheduledMessage(
        id: String,
        conversationID: String,
        clientRequestID: UUID
    ) async throws { rejectedBaseCalls += 1 }

    func createPoll(_ draft: ChatPollDraft) async throws -> ChatMessage {
        rejectedBaseCalls += 1
        throw MobileReadOnlyChatRepositoryError.operationUnavailable
    }

    func realtimeEvents() async -> AsyncStream<ChatRealtimeEvent> {
        realtimeBaseCalls += 1
        return AsyncStream { $0.finish() }
    }

    func startRealtime() async { realtimeBaseCalls += 1 }
    func stopRealtime() async { realtimeBaseCalls += 1 }
}

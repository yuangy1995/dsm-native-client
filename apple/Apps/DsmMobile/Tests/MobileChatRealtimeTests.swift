import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatRealtimeTests: XCTestCase {
    func test其他设备已经读到更晚消息时不回写旧缓存时间() async throws {
        let (model, transport, _) = try await fixture()
        let time = Int(model.state.selectedMessages.messages.last!.sentAt.timeIntervalSince1970 * 1_000) + 10_000
        await transport.setViewedAt(time)
        await model.reloadConversations()
        model.enterConversation("27"); await model.setForegroundRealtimeActive(true)
        model.updateVisibleMessage("60", isVisible: true, conversationID: "27")
        try await Task.sleep(for: .milliseconds(25))
        let requests = await transport.readTimes
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(model.state.selectedConversation?.lastViewedAt, Date(timeIntervalSince1970: Double(time) / 1_000))
        await model.setForegroundRealtimeActive(false)
    }

    func test读取和预加载历史不推进已读且最新真实可见后只同步一次() async throws {
        let (model, transport, repository) = try await fixture()
        let conversation = try XCTUnwrap(model.state.selectedConversation)
        model.enterConversation(conversation.id)
        await model.setForegroundRealtimeActive(true)
        model.updateVisibleMessage("11", isVisible: true, conversationID: "27")
        await model.loadMoreMessages()
        var times = await transport.readTimes
        XCTAssertTrue(times.isEmpty); XCTAssertEqual(model.state.selectedConversation?.unreadCount, 3)
        XCTAssertEqual(model.state.selectedMessages.messages.count, 60)
        model.updateVisibleMessage("60", isVisible: true, conversationID: "27")
        await eventually { model.state.selectedConversation?.unreadCount == 0 }
        times = await transport.readTimes
        XCTAssertEqual(times.count, 1)
        XCTAssertEqual(times.first, Int(model.state.selectedMessages.messages.last!.sentAt.timeIntervalSince1970 * 1_000))
        model.updateVisibleMessage("60", isVisible: true, conversationID: "27")
        await repository.emit(.contentChanged)
        try await Task.sleep(for: .milliseconds(40))
        times = await transport.readTimes; XCTAssertEqual(times.count, 1)
        await model.setForegroundRealtimeActive(false)
    }

    func test同步失败保留未读并在下一次可见时重试() async throws {
        let (model, transport, _) = try await fixture()
        await transport.setRejectReads(true)
        model.enterConversation("27"); await model.setForegroundRealtimeActive(true)
        await eventually { await transport.conversationReads >= 2 && !model.state.isRefreshingConversations }
        model.updateVisibleMessage("60", isVisible: true, conversationID: "27")
        await eventually { await transport.readTimes.count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.state.selectedConversation?.unreadCount, 3)
        await transport.setRejectReads(false)
        model.updateVisibleMessage("60", isVisible: false, conversationID: "27")
        model.updateVisibleMessage("60", isVisible: true, conversationID: "27")
        await eventually { model.state.selectedConversation?.unreadCount == 0 }
        let times = await transport.readTimes; XCTAssertEqual(times.count, 2)
        await model.setForegroundRealtimeActive(false)
    }

    func test后台离页旧页面实例均不能标记已读() async throws {
        let (model, transport, _) = try await fixture()
        let old = UUID(), current = UUID()
        model.enterConversation("27", ownerID: old)
        model.updateVisibleMessage("60", isVisible: true, conversationID: "27", ownerID: old)
        var times = await transport.readTimes; XCTAssertTrue(times.isEmpty)
        model.enterConversation("27", ownerID: current)
        await model.setForegroundRealtimeActive(true)
        model.updateVisibleMessage("60", isVisible: true, conversationID: "27", ownerID: old)
        model.leaveConversation("27", ownerID: old)
        times = await transport.readTimes; XCTAssertTrue(times.isEmpty)
        XCTAssertEqual(model.state.visibleConversationID, "27")
        model.leaveChatPage()
        model.updateVisibleMessage("60", isVisible: true, conversationID: "27", ownerID: current)
        times = await transport.readTimes; XCTAssertTrue(times.isEmpty)
        await model.setForegroundRealtimeActive(false)
    }

    func test迟到已读回执不覆盖新账号() async throws {
        let (model, transport, repository) = try await fixture()
        model.enterConversation("27"); await model.setForegroundRealtimeActive(true)
        await transport.setDelayReads(true)
        model.updateVisibleMessage("60", isVisible: true, conversationID: "27")
        await eventually { await transport.isReadBlocked() }
        let next = UUID()
        model.deactivate(); await model.activate(profileID: next, repository: repository)
        await transport.releaseRead()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.activeProfileID, next)
        XCTAssertTrue(model.state.synchronizedReadThroughByConversationID.isEmpty)
        XCTAssertNil(model.state.visibleConversationID)
        model.deactivate()
    }

    func test本人最新消息使用同一已读流程且不会遗留未读() async throws {
        let (model, transport, _) = try await fixture()
        await transport.appendMessage(isCurrentUser: true)
        await model.reloadConversations(); await model.refreshMessages()
        XCTAssertEqual(model.state.selectedMessages.messages.last?.isFromCurrentUser, true)
        model.enterConversation("27"); await model.setForegroundRealtimeActive(true)
        model.updateVisibleMessage("61", isVisible: true, conversationID: "27")
        await eventually { model.state.selectedConversation?.unreadCount == 0 }
        await model.setForegroundRealtimeActive(false)
    }

    func test阅读历史期间实时刷新仅更新会话且保留分页草稿和位置() async throws {
        let (model, transport, repository) = try await fixture()
        model.enterConversation("27"); await model.loadMoreMessages(); model.setDraft("合成草稿")
        let before = model.state.selectedMessages
        await model.setForegroundRealtimeActive(true)
        await transport.appendMessage(); await repository.emit(.contentChanged)
        await eventually { model.state.selectedConversation?.lastMessageSummary == "Sample message 61" }
        XCTAssertEqual(model.state.selectedMessages, before); XCTAssertEqual(model.state.selectedDraft, "合成草稿")
        let reads = await transport.readTimes; XCTAssertTrue(reads.isEmpty)
        await model.setForegroundRealtimeActive(false)
    }

    func test最新页与历史重叠时合并且保留原先最早游标() async throws {
        let (model, transport, _) = try await fixture()
        await model.loadMoreMessages()
        await transport.appendMessage()
        await model.refreshMessages(preservingHistory: true)
        XCTAssertEqual(model.state.selectedMessages.messages.count, 61)
        XCTAssertEqual(model.state.selectedMessages.messages.first?.id, "1")
        XCTAssertEqual(model.state.selectedMessages.messages.last?.id, "61")
        XCTAssertFalse(model.state.selectedMessages.hasMoreBefore)
        XCTAssertNil(model.state.selectedMessages.previousCursor)
    }

    func test超过一页新消息时保留历史而显式最新请求可重新定位() async throws {
        let (model, transport, _) = try await fixture()
        let previous = model.state.selectedMessages
        await transport.setCount(130)
        await model.refreshMessages(preservingHistory: true)
        XCTAssertEqual(model.state.selectedMessages, previous)
        await model.refreshMessages()
        XCTAssertEqual(model.state.selectedMessages.messages.first?.id, "81")
        XCTAssertEqual(model.state.selectedMessages.messages.last?.id, "130")
        XCTAssertTrue(model.state.selectedMessages.hasMoreBefore)
    }

    func test线程仅最新回复可见时调用线程已读且关闭后不再调用() async throws {
        let (model, transport, _) = try await fixture()
        let root = try XCTUnwrap(model.state.selectedMessages.messages.last)
        let interaction = try XCTUnwrap(model.interaction)
        await model.setForegroundRealtimeActive(true)
        await interaction.open(root)
        interaction.synchronizeVisibleReply("101", isVisible: true)
        var views = await transport.replyViews; XCTAssertEqual(views, 0)
        interaction.synchronizeVisibleReply("102", isVisible: true)
        await eventually { await transport.replyViews == 1 }
        interaction.closeDiscussion(); interaction.synchronizeVisibleReply("102", isVisible: true)
        views = await transport.replyViews; XCTAssertEqual(views, 1)
        await model.setForegroundRealtimeActive(false)
    }

    func test工作区首次在文件页也订阅且切换设置不重建聊天模型() async throws {
        let (_, transport, repository) = try await fixture()
        let (defaults, name) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        let app = MobileAppModel(defaults: defaults, chatNotificationDriver: MobileChatNotificationUIDriver())
        let profile = try profile()
        app.activeProfile = profile; app.capabilities = capabilities(); app.chatRepository = repository
        app.availableOptionalModules = [.chat]; app.settingsStore.setVisible(true, module: .chat); app.isConnected = true
        XCTAssertEqual(app.selectedModule, .files)
        await app.updateChatForeground(true)
        await eventually { await repository.starts == 1 }
        let sender = app.chatModel.sending
        app.selectModule(.chat); await app.loadSelectedModule(); app.selectModule(.settings)
        XCTAssertTrue(sender === app.chatModel.sending)
        XCTAssertEqual(app.chatModel.activeProfileID, profile.id)
        await transport.appendMessage(); await repository.emit(.contentChanged)
        await eventually { app.chatModel.state.conversations.first?.lastMessageSummary == "Sample message 61" }
        app.setModule(.chat, isVisible: false)
        XCTAssertNil(app.chatModel.activeProfileID)
        await eventually { await repository.stops >= 1 }
    }

    func test停止前台会取消未完成刷新且旧事件不再读取() async throws {
        let (model, transport, repository) = try await fixture()
        await model.setForegroundRealtimeActive(true)
        await eventually { await repository.starts == 1 }
        await model.setForegroundRealtimeActive(false)
        let before = await transport.conversationReads
        await repository.emit(.contentChanged)
        try await Task.sleep(for: .milliseconds(40))
        let after = await transport.conversationReads
        XCTAssertEqual(before, after)
    }

    func fixture() async throws -> (MobileChatModel, MobileChatRealtimeUITransport, MobileChatRealtimeRepositoryProbe) {
        let transport = MobileChatRealtimeUITransport()
        let base = try DsmChatRepository(profile: profile(), capabilities: capabilities(),
            session: AuthSession(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        let repository = MobileChatRealtimeRepositoryProbe(base: base)
        let (defaults, name) = isolatedDefaults()
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let notifications = MobileChatNotifications(defaults: defaults, driver: MobileChatNotificationUIDriver())
        let model = MobileChatModel(realtimePollingIntervalNanoseconds: 60_000_000_000,
            realtimeDebounceIntervalNanoseconds: 5_000_000, notifications: notifications)
        await model.activate(profileID: UUID(), repository: repository)
        await model.selectConversation(try XCTUnwrap(model.state.conversations.first { $0.id == "27" }))
        addTeardownBlock { @MainActor in model.deactivate() }
        return (model, transport, repository)
    }

    private func capabilities() -> CapabilitySet {
        CapabilitySet(Dictionary(uniqueKeysWithValues: [DsmAPIName.chatChannel: 2, DsmAPIName.chatUser: 1,
            DsmAPIName.chatPost: 8, DsmAPIName.chatPostSubscribe: 2, DsmAPIName.chatPostReminder: 1].map {
            ($0.key, ApiCapability(name: $0.key, path: "entry.cgi", minVersion: 1, maxVersion: $0.value,
                requestFormat: .form, selectedVersion: $0.value, verified: false))
        }))
    }
    private func profile() throws -> NasProfile { try NasProfile(displayName: "Synthetic", host: "fixture.invalid", port: 5001, usernameHint: "fixture") }
    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "MobileChatRealtimeTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
    private func eventually(_ condition: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 { if await condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        XCTFail("未出现预期状态", file: file, line: line)
    }
}

/// 保留真实请求与解析，只把实时连接替换成可控事件，测试不访问任何网络。
actor MobileChatRealtimeRepositoryProbe: ChatRepository {
    let base: any ChatRepository
    private var continuation: AsyncStream<ChatRealtimeEvent>.Continuation?
    private(set) var starts = 0
    private(set) var stops = 0
    init(base: any ChatRepository) { self.base = base }
    func realtimeEvents() -> AsyncStream<ChatRealtimeEvent> { let pair = AsyncStream<ChatRealtimeEvent>.makeStream(); continuation = pair.continuation; return pair.stream }
    func startRealtime() { starts += 1 }
    func stopRealtime() { stops += 1; continuation?.finish() }
    func emit(_ event: ChatRealtimeEvent) { continuation?.yield(event) }
    func availability() async -> ChatAvailability { await base.availability() }
    func listUsers() async throws -> [ChatUser] { try await base.listUsers() }
    func listConversations() async throws -> [ChatConversation] { try await base.listConversations() }
    func listMessages(conversationID: String, before cursor: String?, limit: Int) async throws -> ChatMessagePage { try await base.listMessages(conversationID: conversationID, before: cursor, limit: limit) }
    func markRead(conversationID: String, through: Date) async throws -> ChatConversation { try await base.markRead(conversationID: conversationID, through: through) }
    func markThreadRead(conversationID: String, threadID: String, lastMessageID: String) async throws { try await base.markThreadRead(conversationID: conversationID, threadID: threadID, lastMessageID: lastMessageID) }
    func message(conversationID: String, messageID: String, threadID: String?) async throws -> ChatMessage? { try await base.message(conversationID: conversationID, messageID: messageID, threadID: threadID) }
    func listReplies(conversationID: String, threadID: String, before: String?, limit: Int) async throws -> ChatMessagePage { try await base.listReplies(conversationID: conversationID, threadID: threadID, before: before, limit: limit) }
    func listReminders(conversationID: String) async throws -> [ChatReminder] { try await base.listReminders(conversationID: conversationID) }
    func editingPolicy() async throws -> ChatEditingPolicy { try await base.editingPolicy() }
    func openDirectConversation(userID: String, clientRequestID: UUID) async throws -> ChatConversation { throw URLError(.unsupportedURL) }
    func createGroup(_ draft: ChatGroupDraft) async throws -> ChatConversation { throw URLError(.unsupportedURL) }
    func sendMessage(_ draft: ChatMessageDraft, progress: @escaping FileTransferProgress) async throws -> ChatMessage { throw URLError(.unsupportedURL) }
    func deleteMessage(conversationID: String, messageID: String, clientRequestID: UUID) async throws { throw URLError(.unsupportedURL) }
    func closeConversation(conversationID: String, clientRequestID: UUID) async throws { throw URLError(.unsupportedURL) }
    func listConversationMembers(conversationID: String) async throws -> [ChatUser] { throw URLError(.unsupportedURL) }
    func listPinnedMessages(conversationID: String) async throws -> [ChatMessage] { throw URLError(.unsupportedURL) }
    func setMessagePinned(conversationID: String, messageID: String, isPinned: Bool, clientRequestID: UUID) async throws { throw URLError(.unsupportedURL) }
    func forwardMessage(messageID: String, toConversationIDs: [String], clientRequestID: UUID) async throws { throw URLError(.unsupportedURL) }
    func setReminder(messageID: String, remindAt: Date, clientRequestID: UUID) async throws -> ChatReminder { throw URLError(.unsupportedURL) }
    func deleteReminder(messageID: String, conversationID: String, clientRequestID: UUID) async throws { throw URLError(.unsupportedURL) }
    func loadAttachmentThumbnail(messageID: String, size: ChatAttachmentThumbnailSize) async throws -> Data { throw URLError(.unsupportedURL) }
    func downloadAttachment(messageID: String, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws { throw URLError(.unsupportedURL) }
    func listScheduledMessages(conversationID: String) async throws -> [ChatScheduledMessage] { throw URLError(.unsupportedURL) }
    func createScheduledMessage(conversationID: String, text: String, sendAt: Date, clientRequestID: UUID) async throws -> ChatScheduledMessage { throw URLError(.unsupportedURL) }
    func deleteScheduledMessage(id: String, conversationID: String, clientRequestID: UUID) async throws { throw URLError(.unsupportedURL) }
    func createPoll(_ draft: ChatPollDraft) async throws -> ChatMessage { throw URLError(.unsupportedURL) }
}

import DsmCore
import DsmLocalization
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
extension ChatWorkspaceModelTests {
    func test聊天发送与恢复提示不包含开发复核用语() {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        let keys = ["chat.send.check", "chat.send.pending", "chat.send.unconfirmed", "chat.conversation.unconfirmed",
                    "chat.poll.unconfirmed", "chat.forward.unconfirmed", "chat.reminder.unavailable", "chat.schedule.unavailable"]
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for key in keys {
                let text = L10n.string(key).lowercased()
                XCTAssertNotEqual(text, key)
                for forbidden in ["待确认", "核对", "验证", "awaiting confirmation", "check result", "verification"] {
                    XCTAssertFalse(text.contains(forbidden), "\(key) 不应向用户显示内部过程")
                }
            }
        }
    }

    func test一对一会话可以读取置顶消息但不扩大置顶写范围() async {
        let active = conversation(id: "one", title: "测试聊天", activity: Date())
        let message = message(id: "pinned", conversationID: active.id, date: Date())
        let repository = ChatRepositoryStub(conversations: [active], messagesByConversation: [active.id: [message]])
        try? await repository.setMessagePinned(conversationID: active.id, messageID: message.id, isPinned: true, clientRequestID: UUID())
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        await model.loadPinnedMessages()
        XCTAssertEqual(model.pinnedMessages.map(\.id), [message.id])
        XCTAssertFalse(model.canPin(message))
    }

    func test图片预览直接读取原文件且不要求已有缩略图() async throws {
        let active = conversation(id: "one", title: "测试聊天", activity: Date())
        let data = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let repository = ChatRepositoryStub(conversations: [active], downloadedAttachmentData: data)
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        let attachment = ChatAttachment(id: "image", kind: .image, fileName: "sample.png", sizeBytes: Int64(data.count))
        XCTAssertNil(model.thumbnailData(for: "image-message"))
        let image = await model.loadAttachmentPreview(messageID: "image-message", attachment: attachment)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size.width, 1)
        XCTAssertNil(model.thumbnailData(for: "image-message"))
    }

    func test加密会话不读取正文且关闭全部消息写入口() async {
        let encrypted = ChatConversation(id: "encrypted", kind: .direct, title: "加密测试",
                                         memberIDs: ["peer"], unreadCount: 3, isEncrypted: true)
        let repository = ChatRepositoryStub(conversations: [encrypted])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        await model.refreshForegroundChat()
        XCTAssertFalse(model.canSendText)
        XCTAssertFalse(model.canSendAttachments)
        XCTAssertFalse(model.canDownloadAttachments)
        XCTAssertFalse(model.canCreatePoll)
        XCTAssertFalse(model.canScheduleMessages)
        XCTAssertFalse(model.canManageReminders)
        XCTAssertFalse(model.canDeleteOwnMessages)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.totalUnreadCount, 3)
        let sent = await model.send(text: "不能按普通消息发送")
        let calls = await repository.sentTexts()
        XCTAssertFalse(sent)
        XCTAssertTrue(calls.isEmpty)
    }

    func test同名成员不能获得本人消息归属和删除入口() async {
        let active = conversation(id: "one", title: "测试聊天", activity: Date())
        let repository = ChatRepositoryStub(conversations: [active], users: [
            ChatUser(id: "self", displayName: "本人", isCurrentUser: true),
            ChatUser(id: "peer", displayName: "testaccount", isCurrentUser: false)
        ])
        let model = ChatWorkspaceModel(repository: repository, currentAccountName: "testaccount")
        await model.loadIfNeeded()
        let other = ChatMessage(id: "other", conversationID: active.id, senderID: "peer",
            senderDisplayName: "testaccount", isFromCurrentUser: false, sentAt: Date(), text: "他人消息")
        XCTAssertEqual(model.currentUserID, "self")
        XCTAssertFalse(model.isCurrentUser(other))
        XCTAssertFalse(model.canDelete(other))
        let own = ChatMessage(id: "own", conversationID: active.id, senderID: "self", sentAt: Date(), text: "本人消息")
        XCTAssertTrue(model.isCurrentUser(own))
        XCTAssertTrue(model.canDelete(own))
    }

    func test未知发送不认领附近同文消息且核对沿用原请求() async throws {
        let active = conversation(id: "one", title: "测试聊天", activity: Date())
        let old = ChatMessage(id: "existing", conversationID: active.id, senderID: "self", isFromCurrentUser: true,
                              sentAt: Date().addingTimeInterval(-60), text: "相同正文")
        let repository = ChatRepositoryStub(conversations: [active], messagesByConversation: [active.id: [old]])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        await repository.makeNextSendUnconfirmed()
        let sent = await model.send(text: "相同正文")
        XCTAssertFalse(sent)
        let local = try XCTUnwrap(model.messages.first { $0.deliveryState == .failed })
        XCTAssertTrue(model.isAwaitingMessageConfirmation(local.id))
        let readsBefore = await repository.messageReads()
        await model.retryMessage(id: local.id)
        let readsAfter = await repository.messageReads()
        XCTAssertEqual(readsAfter, readsBefore + 1, "刷新聊天必须真正更新消息，不能只返回内存状态")
        XCTAssertEqual(model.messages.filter { $0.id == old.id }.count, 1)
        XCTAssertTrue(model.messages.contains { $0.id == local.id })
        model.removeFailedMessage(id: local.id)
        XCTAssertTrue(model.messages.contains { $0.id == local.id }, "待确认消息不能被当成普通失败草稿丢弃")
        let requestIDs = await repository.sendRequestIDs()
        XCTAssertEqual(requestIDs.count, 2)
        XCTAssertEqual(Set(requestIDs).count, 1)
    }

    func test自动核对确认后合并服务器消息且不保留失败副本() async throws {
        let active = conversation(id: "one", title: "测试聊天", activity: Date())
        let repository = ChatRepositoryStub(conversations: [active])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        await repository.makeNextSendUnconfirmed()
        _ = await model.send(text: "待核对")
        let local = try XCTUnwrap(model.messages.first)
        let confirmed = ChatMessage(id: "server", conversationID: active.id, senderID: "self",
            isFromCurrentUser: true, sentAt: Date(), text: "待核对")
        await repository.replaceMessages([confirmed], in: active.id)
        await repository.confirmPendingSend(with: confirmed)
        await model.refreshCurrentConversation()
        XCTAssertEqual(model.messages.map(\.id), ["server"])
        XCTAssertFalse(model.isAwaitingMessageConfirmation(local.id))
        XCTAssertNil(model.sendFailureMessage(for: local.id))
    }

    func test切换会话期间发送失败仍更新原会话草稿() async throws {
        let first = conversation(id: "one", title: "会话一", activity: Date())
        let second = conversation(id: "two", title: "会话二", activity: Date())
        let repository = ChatRepositoryStub(conversations: [first, second], sendFailuresRemaining: 1)
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        await model.selectConversation(id: first.id)
        await repository.holdNextSend()
        let task = Task { await model.send(text: "会话一的消息") }
        for _ in 0..<1_000 {
            if await repository.isSendHeld() { break }
            await Task.yield()
        }
        let held = await repository.isSendHeld()
        XCTAssertTrue(held)
        await model.selectConversation(id: second.id)
        await repository.releaseSend()
        _ = await task.value
        XCTAssertTrue(model.messages.isEmpty)
        await model.selectConversation(id: first.id)
        let failed = try XCTUnwrap(model.messages.first)
        XCTAssertEqual(failed.deliveryState, .failed)
        XCTAssertNotNil(model.sendFailureMessage(for: failed.id))
        await model.retryMessage(id: failed.id)
        XCTAssertEqual(model.messages.first?.deliveryState, .sent)
    }

    func test刷新完整消息页会移除服务器已删除的记录() async {
        let active = conversation(id: "one", title: "测试聊天", activity: Date())
        let deleted = message(id: "deleted", conversationID: active.id, date: Date(timeIntervalSince1970: 1))
        let kept = message(id: "kept", conversationID: active.id, date: Date(timeIntervalSince1970: 2))
        let repository = ChatRepositoryStub(conversations: [active], queuedMessagePagesByConversation: [active.id: [
            ChatMessagePage(messages: [deleted, kept], previousCursor: nil, hasMoreBefore: false),
            ChatMessagePage(messages: [kept], previousCursor: nil, hasMoreBefore: false)
        ]])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        await model.refreshCurrentConversation()
        XCTAssertEqual(model.messages.map(\.id), [kept.id])
    }

    func test刷新最新页保留未覆盖的更早历史() async {
        let active = conversation(id: "one", title: "测试聊天", activity: Date())
        let old = message(id: "old", conversationID: active.id, date: Date(timeIntervalSince1970: 1))
        let boundary = message(id: "boundary", conversationID: active.id, date: Date(timeIntervalSince1970: 2))
        let removed = message(id: "removed", conversationID: active.id, date: Date(timeIntervalSince1970: 3))
        let latest = message(id: "latest", conversationID: active.id, date: Date(timeIntervalSince1970: 4))
        let repository = ChatRepositoryStub(conversations: [active], queuedMessagePagesByConversation: [active.id: [
            ChatMessagePage(messages: [old, boundary, removed], previousCursor: "50", hasMoreBefore: true),
            ChatMessagePage(messages: [boundary, latest], previousCursor: "50", hasMoreBefore: true)
        ]])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        await model.refreshCurrentConversation()
        XCTAssertEqual(model.messages.map(\.id), [old.id, boundary.id, latest.id])
        XCTAssertTrue(model.hasMoreMessagesBefore)
    }

    func test当前会话读取失败时保留新未读数和已有消息() async {
        let time = Date(timeIntervalSince1970: 1_000)
        let active = ChatConversation(id: "one", kind: .direct, title: "测试", memberIDs: [], lastActivityAt: time, unreadCount: 2)
        let repository = ChatRepositoryStub(conversations: [active], messagesByConversation: [active.id: [message(id: "old", conversationID: active.id, date: time)]])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        await model.refreshForegroundChat()
        model.isChatWindowActive = true
        model.updateVisibleMessage(model.messages.last(where: { $0.deliveryState == .sent })?.id)
        await model.synchronizeVisibleReadState()
        XCTAssertEqual(model.totalUnreadCount, 0)
        await repository.replaceConversations([ChatConversation(id: active.id, kind: .direct, title: active.title,
            memberIDs: [], lastActivityAt: time.addingTimeInterval(60), unreadCount: 5)])
        await repository.setMessageReadsFailing(true)
        await model.refreshForegroundChat()
        XCTAssertEqual(model.totalUnreadCount, 5)
        XCTAssertEqual(model.messages.map(\.id), ["old"])
        XCTAssertNotNil(model.messageLoadError)
    }

    func test空消息页或未知活动时间不冒充已读() async {
        let active = ChatConversation(id: "one", kind: .direct, title: "测试", memberIDs: [], unreadCount: 3)
        let repository = ChatRepositoryStub(conversations: [active])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        await model.refreshForegroundChat()
        XCTAssertEqual(model.totalUnreadCount, 3)
    }

    func test附件草稿按会话隔离且迟到发送不使用新会话() async {
        let first = conversation(id: "one", title: "会话一", activity: Date())
        let second = conversation(id: "two", title: "会话二", activity: Date())
        let repository = ChatRepositoryStub(conversations: [first, second])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        await model.selectConversation(id: first.id)
        let url = URL(fileURLWithPath: "/synthetic/attachment.txt")
        model.updateAttachments([url], for: first.id)
        await model.selectConversation(id: second.id)
        XCTAssertTrue(model.attachmentURLs(for: second.id).isEmpty)
        XCTAssertEqual(model.attachmentURLs(for: first.id), [url])
        let sent = await model.send(text: "旧会话提交", attachmentURLs: [url], conversationID: first.id)
        let calls = await repository.sentTexts()
        XCTAssertFalse(sent)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(model.attachmentURLs(for: first.id), [url])
    }

    func test群聊未知结果保留完整草稿并沿用同一请求() async {
        let repository = ChatRepositoryStub(conversations: [])
        await repository.useGroupStatuses([.submittedButUnverified, .confirmedSuccess])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        let first = await model.createGroup(title: "测试群", memberIDs: ["a", "b"], isEncrypted: false)
        XCTAssertFalse(first)
        XCTAssertNotNil(model.pendingGroupDraft)
        let second = await model.createGroup(title: "测试群", memberIDs: ["b", "a"], isEncrypted: false)
        XCTAssertTrue(second)
        XCTAssertNil(model.pendingGroupDraft)
        let ids = await repository.groupRequestIDs()
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 1)
    }
}

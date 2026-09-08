import DsmCore
import DsmLocalization
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class ChatWorkspaceModelTests: XCTestCase {
    func test缺少摘要不显示无消息且载入记录后保留会话预览() async throws {
        let first = ChatConversation(id: "first", kind: .group, title: "测试群", memberIDs: ["user-1"], lastActivityAt: Date(timeIntervalSince1970: 200))
        let second = ChatConversation(id: "second", kind: .direct, title: "测试会话", memberIDs: ["user-1"], lastActivityAt: Date(timeIntervalSince1970: 100))
        let item = ChatMessage(id: "one", conversationID: first.id, senderID: "user-1", sentAt: Date(timeIntervalSince1970: 200), text: "已存在的测试消息")
        let model = ChatWorkspaceModel(repository: ChatRepositoryStub(conversations: [first, second], messagesByConversation: [first.id: [item]]))
        XCTAssertEqual(model.conversationSummary(first), L10n.string("chat.preview.open"))
        await model.loadIfNeeded()
        XCTAssertEqual(model.conversationSummary(first), item.text)
        XCTAssertEqual(model.conversationSummary(second), L10n.string("chat.preview.open"))
        await model.selectConversation(id: second.id)
        XCTAssertEqual(model.conversationSummary(first), item.text)
        XCTAssertEqual(model.conversationSummary(second), L10n.string("chat.preview.open"))
    }

    func test关闭消息模块后不读取会话且重新开启后可恢复() async {
        let active = conversation(id: "conversation-1", title: "测试聊天", activity: Date())
        let repository = ChatRepositoryStub(conversations: [active])
        let model = ChatWorkspaceModel(repository: repository)

        model.setModuleEnabled(false)
        await model.loadIfNeeded()

        XCTAssertFalse(model.isModuleEnabled)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertFalse(model.canUseMessaging)

        model.setModuleEnabled(true)
        await model.loadIfNeeded()

        XCTAssertEqual(model.conversations.map(\.id), ["conversation-1"])
    }

    func test未验证服务保持关闭且不展示空会话误导用户() async {
        let model = ChatWorkspaceModel(repository: UnverifiedDsmChatRepository())

        await model.loadIfNeeded()

        XCTAssertEqual(model.availability.status, .requiresValidation)
        XCTAssertFalse(model.canUseMessaging)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.statusMessage, L10n.string("ui.9984c9276092ef03"))
    }

    func test可用服务按最近活动排序并载入第一段会话() async throws {
        let recentDate = Date(timeIntervalSince1970: 2_000)
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let recent = conversation(id: "recent", title: "最近聊天", activity: recentDate)
        let old = conversation(id: "old", title: "较早聊天", activity: oldDate)
        let repository = ChatRepositoryStub(
            conversations: [old, recent],
            messagesByConversation: [
                "recent": [message(id: "message-1", conversationID: "recent", date: recentDate)]
            ]
        )
        let model = ChatWorkspaceModel(repository: repository)

        await model.loadIfNeeded()

        XCTAssertEqual(model.conversations.map(\.id), ["recent", "old"])
        XCTAssertEqual(model.selectedConversationID, "recent")
        XCTAssertEqual(model.messages.map(\.id), ["message-1"])
        XCTAssertTrue(model.canSendText)
    }

    func test发送成功后加入当前会话且清理文字空白() async throws {
        let activeConversation = conversation(
            id: "conversation-1",
            title: "测试聊天",
            activity: Date(timeIntervalSince1970: 1_000)
        )
        let repository = ChatRepositoryStub(conversations: [activeConversation])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()

        let succeeded = await model.send(text: "  你好 👋  ")
        let sentTexts = await repository.sentTexts()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.messages.last?.text, "你好 👋")
        XCTAssertEqual(sentTexts, ["你好 👋"])
    }

    func test创建投票后加入当前会话并显示成功提示() async throws {
        let active = conversation(id: "conversation-1", title: "测试聊天", activity: Date())
        let repository = ChatRepositoryStub(conversations: [active])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()

        let succeeded = await model.createPoll(
            question: "周末去哪？",
            options: ["公园", "博物馆"],
            allowsMultipleSelection: false,
            isAnonymous: true
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.messages.last?.poll?.question, "周末去哪？")
        XCTAssertEqual(model.activeToast?.text, L10n.string("ui.8c6ec0e6eb0022db"))
    }

    func test设置和取消提醒同步本地列表() async {
        let active = conversation(id: "conversation-1", title: "测试聊天", activity: Date())
        let repository = ChatRepositoryStub(conversations: [active])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        let remindAt = Date().addingTimeInterval(3_600)

        let created = await model.setReminder(messageID: "message-1", remindAt: remindAt)
        XCTAssertTrue(created)
        XCTAssertEqual(model.reminder(for: "message-1")?.remindAt, remindAt)
        let deleted = await model.deleteReminder(messageID: "message-1")
        XCTAssertTrue(deleted)
        XCTAssertNil(model.reminder(for: "message-1"))
    }

    func test附件缩略图和下载接入模型状态() async throws {
        let active = conversation(id: "conversation-1", title: "测试聊天", activity: Date())
        let repository = ChatRepositoryStub(conversations: [active])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        let attachment = ChatAttachment(id: "file-1", kind: .image, fileName: "sample.png")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatWorkspaceModelTests-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destination) }

        await model.loadAttachmentThumbnail(messageID: "message-1", attachment: attachment)
        let downloaded = await model.downloadAttachment(
            messageID: "message-1",
            attachment: attachment,
            to: destination
        )

        XCTAssertNotNil(model.thumbnailData(for: "message-1"))
        XCTAssertTrue(downloaded)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "attachment")
    }

    func testNAS没有图片缩略图时下载原文件生成本机预览() async throws {
        let active = conversation(id: "conversation-1", title: "测试聊天", activity: Date())
        let imageData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let repository = ChatRepositoryStub(
            conversations: [active],
            attachmentThumbnailShouldFail: true,
            downloadedAttachmentData: imageData
        )
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        let attachment = ChatAttachment(
            id: "file-heic",
            kind: .image,
            fileName: "IMG_3765.HEIC",
            sizeBytes: Int64(imageData.count),
            thumbnailAvailable: false
        )

        await model.loadAttachmentThumbnail(messageID: "message-heic", attachment: attachment)

        XCTAssertNotNil(model.thumbnailData(for: "message-heic"))
    }

    func test进入会话后立即清除本地未读数字() async {
        let active = ChatConversation(
            id: "conversation-1",
            kind: .direct,
            title: "测试聊天",
            memberIDs: ["user-1"],
            lastMessageSummary: "三条新消息",
            lastActivityAt: Date(timeIntervalSince1970: 3_000),
            unreadCount: 3
        )
        let repository = ChatRepositoryStub(
            conversations: [active],
            messagesByConversation: [active.id: [
                message(id: "message-1", conversationID: active.id, date: Date(timeIntervalSince1970: 3_000))
            ]]
        )
        let model = ChatWorkspaceModel(repository: repository)

        await model.loadIfNeeded()

        XCTAssertEqual(model.selectedConversationID, active.id)
        XCTAssertEqual(model.conversations.first?.unreadCount, 0)
    }

    func test读完切换会话后前台刷新不会恢复旧未读数字() async {
        let readConversation = ChatConversation(
            id: "conversation-read",
            kind: .direct,
            title: "已读聊天",
            memberIDs: ["user-1"],
            lastMessageSummary: "三条新消息",
            lastActivityAt: Date(timeIntervalSince1970: 3_000),
            unreadCount: 3
        )
        let otherConversation = conversation(
            id: "conversation-other",
            title: "其他聊天",
            activity: Date(timeIntervalSince1970: 2_000)
        )
        let repository = ChatRepositoryStub(
            conversations: [readConversation, otherConversation],
            messagesByConversation: [
                readConversation.id: [
                    message(id: "message-read", conversationID: readConversation.id, date: Date(timeIntervalSince1970: 3_000))
                ]
            ]
        )
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        await model.selectConversation(id: otherConversation.id)

        await model.refreshForegroundChat()

        XCTAssertEqual(
            model.conversations.first(where: { $0.id == readConversation.id })?.unreadCount,
            0
        )
    }

    func test离开消息页面后工作区同步仍更新未读数且不会自动标记已读() async {
        let unreadConversation = ChatConversation(
            id: "conversation-unread",
            kind: .direct,
            title: "未读聊天",
            memberIDs: ["user-1"],
            lastMessageSummary: "新消息",
            lastActivityAt: Date(timeIntervalSince1970: 4_000),
            unreadCount: 4
        )
        let repository = ChatRepositoryStub(conversations: [unreadConversation])
        let model = ChatWorkspaceModel(repository: repository)

        await model.syncWorkspaceChat(isChatVisible: false)

        XCTAssertEqual(model.availability.status, .available)
        XCTAssertNil(model.selectedConversationID)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.totalUnreadCount, 4)
        XCTAssertEqual(model.conversations.first?.unreadCount, 4)
    }

    func test本地置顶按NAS保存并在重新打开后保持排序() async throws {
        let suiteName = "ChatWorkspaceModelTests-Pins-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileID = UUID()
        let recent = conversation(
            id: "conversation-recent",
            title: "最近会话",
            activity: Date(timeIntervalSince1970: 3_000)
        )
        let older = conversation(
            id: "conversation-older",
            title: "较早会话",
            activity: Date(timeIntervalSince1970: 1_000)
        )
        let repository = ChatRepositoryStub(conversations: [recent, older])
        let firstModel = ChatWorkspaceModel(
            repository: repository,
            profileID: profileID,
            defaults: defaults
        )
        await firstModel.loadIfNeeded()

        firstModel.toggleConversationPin(id: older.id)

        XCTAssertEqual(firstModel.conversations.map(\.id), [older.id, recent.id])
        XCTAssertTrue(firstModel.isConversationPinned(older.id))
        XCTAssertEqual(firstModel.activeToast?.text, L10n.string("ui.b1bade10a9e4aa94"))

        let reopenedModel = ChatWorkspaceModel(
            repository: repository,
            profileID: profileID,
            defaults: defaults
        )
        await reopenedModel.loadIfNeeded()

        XCTAssertEqual(reopenedModel.conversations.map(\.id), [older.id, recent.id])
        XCTAssertTrue(reopenedModel.isConversationPinned(older.id))

        let otherProfileModel = ChatWorkspaceModel(
            repository: repository,
            profileID: UUID(),
            defaults: defaults
        )
        await otherProfileModel.loadIfNeeded()
        XCTAssertEqual(otherProfileModel.conversations.map(\.id), [recent.id, older.id])
        XCTAssertFalse(otherProfileModel.isConversationPinned(older.id))

        reopenedModel.toggleConversationPin(id: older.id)
        XCTAssertEqual(reopenedModel.conversations.map(\.id), [recent.id, older.id])
        XCTAssertEqual(reopenedModel.activeToast?.text, L10n.string("ui.b45a48730dd4f8ba"))
    }

    func test实时事件会刷新工作区未读数并切换定时校准间隔() async throws {
        let initial = ChatConversation(
            id: "conversation-realtime",
            kind: .direct,
            title: "实时聊天",
            memberIDs: ["user-1"],
            unreadCount: 0
        )
        let updated = ChatConversation(
            id: initial.id,
            kind: .direct,
            title: initial.title,
            memberIDs: initial.memberIDs,
            lastMessageSummary: "刚收到的新消息",
            lastActivityAt: Date(timeIntervalSince1970: 5_000),
            unreadCount: 3
        )
        let repository = ChatRepositoryStub(conversations: [initial])
        let model = ChatWorkspaceModel(repository: repository)

        await model.syncWorkspaceChat(isChatVisible: false)
        await repository.replaceConversations([updated])
        await repository.emitRealtime(.connected)
        await repository.emitRealtime(.contentChanged)
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertTrue(model.isRealtimeConnected)
        XCTAssertEqual(model.workspaceSyncIntervalSeconds, 30)
        XCTAssertEqual(model.totalUnreadCount, 3)
        await model.stopRealtime()
        XCTAssertFalse(model.isRealtimeConnected)
        XCTAssertEqual(model.workspaceSyncIntervalSeconds, 5)
    }

    func test创建和取消定时消息同步本地列表() async {
        let active = conversation(id: "conversation-1", title: "测试聊天", activity: Date())
        let repository = ChatRepositoryStub(conversations: [active])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        let sendAt = Date().addingTimeInterval(7_200)

        let created = await model.createScheduledMessage(text: "稍后见", sendAt: sendAt)
        let scheduledID = model.scheduledMessages.first?.id

        XCTAssertTrue(created)
        XCTAssertEqual(model.scheduledMessages.first?.text, "稍后见")
        let deleted = await model.deleteScheduledMessage(id: scheduledID ?? "")
        XCTAssertTrue(deleted)
        XCTAssertTrue(model.scheduledMessages.isEmpty)
    }

    func test向上分页会合并更早消息并保持唯一顺序() async {
        let active = conversation(id: "conversation-1", title: "测试聊天", activity: Date())
        let older = [
            message(id: "message-1", conversationID: active.id, date: Date(timeIntervalSince1970: 1)),
            message(id: "message-2", conversationID: active.id, date: Date(timeIntervalSince1970: 2))
        ]
        let latest = [
            message(id: "message-3", conversationID: active.id, date: Date(timeIntervalSince1970: 3)),
            message(id: "message-4", conversationID: active.id, date: Date(timeIntervalSince1970: 4))
        ]
        let repository = ChatRepositoryStub(
            conversations: [active],
            queuedMessagePagesByConversation: [active.id: [
                ChatMessagePage(messages: latest, previousCursor: "2", hasMoreBefore: true),
                ChatMessagePage(messages: older, previousCursor: nil, hasMoreBefore: false)
            ]]
        )
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()

        let anchorID = await model.loadEarlierMessages()

        XCTAssertEqual(anchorID, "message-3")
        XCTAssertEqual(model.messages.map(\.id), ["message-1", "message-2", "message-3", "message-4"])
        XCTAssertFalse(model.hasMoreMessagesBefore)
    }

    func test切换会话会分别保留内存草稿() async {
        let first = conversation(id: "conversation-1", title: "聊天一", activity: Date())
        let second = conversation(id: "conversation-2", title: "聊天二", activity: Date())
        let repository = ChatRepositoryStub(conversations: [first, second])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()

        model.updateDraft("第一段草稿", for: first.id)
        await model.selectConversation(id: second.id)
        model.updateDraft("第二段草稿", for: second.id)

        XCTAssertEqual(model.draftText(for: first.id), "第一段草稿")
        XCTAssertEqual(model.draftText(for: second.id), "第二段草稿")
    }

    func test发送失败显示本地失败消息并可手动重试() async {
        let active = conversation(id: "conversation-1", title: "测试聊天", activity: Date())
        let repository = ChatRepositoryStub(conversations: [active], sendFailuresRemaining: 1)
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        model.updateDraft("需要重试", for: active.id)

        let succeeded = await model.send(text: model.draftText(for: active.id))
        let failed = model.messages.first

        XCTAssertFalse(succeeded)
        XCTAssertEqual(failed?.deliveryState, .failed)
        XCTAssertEqual(model.draftText(for: active.id), "")
        XCTAssertNotNil(failed.flatMap { model.sendFailureMessage(for: $0.id) })

        await model.retryMessage(id: failed?.id ?? "")

        XCTAssertEqual(model.messages.count, 1)
        XCTAssertEqual(model.messages.first?.deliveryState, .sent)
        XCTAssertEqual(model.messages.first?.text, "需要重试")
    }

    func test附件失败后保留文件并在重试时再次上传() async throws {
        let active = conversation(id: "conversation-1", title: "测试聊天", activity: Date())
        let repository = ChatRepositoryStub(conversations: [active], sendFailuresRemaining: 1)
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatWorkspaceModelTests-\(UUID().uuidString).png")
        try Data("image".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let succeeded = await model.send(text: "图片说明", attachmentURLs: [fileURL])
        let failedID = try XCTUnwrap(model.messages.first?.id)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.messages.first?.attachments.first?.fileName, fileURL.lastPathComponent)
        await model.retryMessage(id: failedID)

        XCTAssertEqual(model.messages.first?.deliveryState, .sent)
        XCTAssertEqual(model.messages.first?.attachments.first?.fileName, fileURL.lastPathComponent)
        let sentAttachmentNames = await repository.sentAttachmentNames()
        XCTAssertEqual(sentAttachmentNames, [fileURL.lastPathComponent, fileURL.lastPathComponent])
    }

    func test前台增量刷新只合并新消息并显示提示() async {
        let active = conversation(id: "conversation-1", title: "测试聊天", activity: Date())
        let first = message(id: "message-1", conversationID: active.id, date: Date(timeIntervalSince1970: 1))
        let second = ChatMessage(
            id: "message-2",
            conversationID: active.id,
            senderID: "other-user",
            isFromCurrentUser: false,
            sentAt: Date(timeIntervalSince1970: 2),
            text: "新消息"
        )
        let repository = ChatRepositoryStub(
            conversations: [active],
            queuedMessagePagesByConversation: [active.id: [
                ChatMessagePage(messages: [first], previousCursor: nil, hasMoreBefore: false),
                ChatMessagePage(messages: [first, second], previousCursor: nil, hasMoreBefore: false)
            ]]
        )
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()

        await model.refreshCurrentConversation()

        XCTAssertEqual(model.messages.map(\.id), ["message-1", "message-2"])
        XCTAssertEqual(model.newMessageCount, 1)
    }

    func test使用登录账号识别当前用户并将其消息标记为自己() async {
        let repository = ChatRepositoryStub(
            conversations: [conversation(
                id: "conversation-1",
                title: "测试聊天",
                activity: Date(timeIntervalSince1970: 1_000)
            )],
            users: [ChatUser(id: "user-1", displayName: "YuangY")]
        )
        let model = ChatWorkspaceModel(
            repository: repository,
            currentAccountName: " yuangy "
        )
        await model.loadIfNeeded()
        let ownMessage = ChatMessage(
            id: "message-1",
            conversationID: "conversation-1",
            senderID: "user-1",
            isFromCurrentUser: false,
            sentAt: Date(),
            text: "这是我发送的消息"
        )

        XCTAssertEqual(model.currentUserID, "user-1")
        XCTAssertTrue(model.isCurrentUser(ownMessage))
    }

    func test登录账号不会把其他成员的消息标记为自己() async {
        let repository = ChatRepositoryStub(
            conversations: [conversation(
                id: "conversation-1",
                title: "测试聊天",
                activity: Date(timeIntervalSince1970: 1_000)
            )],
            users: [
                ChatUser(id: "current-user", displayName: "yuangy"),
                ChatUser(id: "other-user", displayName: "chenwh")
            ]
        )
        let model = ChatWorkspaceModel(
            repository: repository,
            currentAccountName: "yuangy"
        )
        await model.loadIfNeeded()
        let otherMessage = ChatMessage(
            id: "message-2",
            conversationID: "conversation-1",
            senderID: "other-user",
            senderDisplayName: "chenwh",
            sentAt: Date(),
            text: "这是其他成员的消息"
        )

        XCTAssertFalse(model.isCurrentUser(otherMessage))
    }

    func test批量删除自己的消息后直接同步当前会话() async {
        let activeConversation = conversation(
            id: "conversation-1",
            title: "测试聊天",
            activity: Date(timeIntervalSince1970: 1_000)
        )
        let ownMessages = ["message-1", "message-2"].map { id in
            ChatMessage(
                id: id,
                conversationID: activeConversation.id,
                senderID: "current-user",
                isFromCurrentUser: true,
                sentAt: Date(),
                text: "待删除消息"
            )
        }
        let repository = ChatRepositoryStub(
            conversations: [activeConversation],
            messagesByConversation: [activeConversation.id: ownMessages]
        )
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()

        let deletedCount = await model.deleteMessages(ids: Set(ownMessages.map(\.id)))

        XCTAssertEqual(deletedCount, 2)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.statusMessage)
        XCTAssertEqual(
            model.activeToast?.text,
            L10n.string("ui.b60d233a7f488b7e", String(describing: 2))
        )
    }

    func test不能删除其他成员发送的消息() async {
        let activeConversation = conversation(
            id: "conversation-1",
            title: "测试聊天",
            activity: Date(timeIntervalSince1970: 1_000)
        )
        let otherMessage = ChatMessage(
            id: "message-1",
            conversationID: activeConversation.id,
            senderID: "other-user",
            isFromCurrentUser: false,
            sentAt: Date(),
            text: "其他成员消息"
        )
        let repository = ChatRepositoryStub(
            conversations: [activeConversation],
            messagesByConversation: [activeConversation.id: [otherMessage]]
        )
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()

        let deletedCount = await model.deleteMessages(ids: [otherMessage.id])

        XCTAssertEqual(deletedCount, 0)
        XCTAssertEqual(model.messages.map(\.id), [otherMessage.id])
        XCTAssertEqual(model.statusMessage, L10n.string("ui.66a12c2de716c8cf"))
    }

    func test可以将收发双方的文字和附件消息转发到其他会话() async {
        let source = conversation(
            id: "conversation-source",
            title: "来源会话",
            activity: Date(timeIntervalSince1970: 2_000)
        )
        let target = conversation(
            id: "conversation-target",
            title: "目标会话",
            activity: Date(timeIntervalSince1970: 1_000)
        )
        let incoming = ChatMessage(
            id: "message-incoming",
            conversationID: source.id,
            senderID: "other-user",
            isFromCurrentUser: false,
            sentAt: Date(timeIntervalSince1970: 1_000),
            text: "对方的消息"
        )
        let outgoingAttachment = ChatMessage(
            id: "message-attachment",
            conversationID: source.id,
            senderID: "current-user",
            isFromCurrentUser: true,
            sentAt: Date(timeIntervalSince1970: 1_100),
            text: "附件说明",
            attachments: [
                ChatAttachment(id: "attachment-1", kind: .image, fileName: "示例图片.jpg")
            ]
        )
        let repository = ChatRepositoryStub(
            conversations: [target, source],
            messagesByConversation: [source.id: [incoming, outgoingAttachment]]
        )
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()

        XCTAssertTrue(model.canForward(incoming))
        XCTAssertTrue(model.canForward(outgoingAttachment))

        let succeeded = await model.forwardMessages(
            ids: [incoming.id, outgoingAttachment.id],
            to: [target.id]
        )
        let forwardedMessageIDs = await repository.forwardedMessageIDs()
        let forwardedTargets = await repository.forwardedTargetConversationIDs()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(forwardedMessageIDs, [incoming.id, outgoingAttachment.id])
        XCTAssertEqual(forwardedTargets, [[target.id], [target.id]])
        XCTAssertEqual(
            model.activeToast?.text,
            L10n.string(
                "ui.6fed19067a9ae071",
                String(describing: 2),
                String(describing: 1)
            )
        )
    }

    func test可以先建立单聊再向没有聊天记录的联系人转发() async {
        let source = conversation(
            id: "conversation-source",
            title: "来源会话",
            activity: Date(timeIntervalSince1970: 2_000)
        )
        let message = ChatMessage(
            id: "message-1",
            conversationID: source.id,
            senderID: "other-user",
            isFromCurrentUser: false,
            sentAt: Date(timeIntervalSince1970: 1_000),
            text: "需要转发的消息"
        )
        let recipient = ChatUser(
            id: "recipient",
            displayName: "新联系人"
        )
        let repository = ChatRepositoryStub(
            conversations: [source],
            users: [
                ChatUser(
                    id: "current-user",
                    displayName: "当前用户",
                    isCurrentUser: true
                ),
                recipient
            ],
            messagesByConversation: [source.id: [message]]
        )
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()

        let succeeded = await model.forwardMessages(
            ids: [message.id],
            to: [],
            newDirectUserIDs: [recipient.id]
        )
        let forwardedTargets = await repository.forwardedTargetConversationIDs()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(forwardedTargets, [["direct-\(recipient.id)"]])
        XCTAssertTrue(model.conversations.contains { $0.id == "direct-\(recipient.id)" })
        XCTAssertEqual(
            model.activeToast?.text,
            L10n.string("ui.47bb06634893688d", String(describing: 1))
        )
    }

    func test批量关闭会话后直接同步会话列表() async {
        let first = conversation(id: "conversation-1", title: "聊天一", activity: Date())
        let second = conversation(id: "conversation-2", title: "聊天二", activity: Date())
        let repository = ChatRepositoryStub(conversations: [first, second])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        model.toggleConversationPin(id: first.id)

        let closedCount = await model.closeConversations(ids: [first.id, second.id])

        XCTAssertEqual(closedCount, 2)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertTrue(model.pinnedConversationIDs.isEmpty)
        XCTAssertNil(model.selectedConversationID)
        XCTAssertNil(model.statusMessage)
        XCTAssertEqual(
            model.activeToast?.text,
            L10n.string("ui.027eaf484175e27a", String(describing: 2))
        )
    }

    private func conversation(
        id: String,
        title: String,
        activity: Date
    ) -> ChatConversation {
        ChatConversation(
            id: id,
            kind: .direct,
            title: title,
            memberIDs: ["user-1"],
            lastMessageSummary: "上一条消息",
            lastActivityAt: activity
        )
    }

    private func message(id: String, conversationID: String, date: Date) -> ChatMessage {
        ChatMessage(
            id: id,
            conversationID: conversationID,
            senderID: "user-1",
            sentAt: date,
            text: "测试消息"
        )
    }
}

// 供模型回归与合成页面共用，不连接真实消息服务。
actor ChatRepositoryStub: ChatRepository {
    private let availableFeatures: Set<ChatFeature>
    private var storedConversations: [ChatConversation]
    private let users: [ChatUser]
    private var messagesByConversation: [String: [ChatMessage]]
    private var queuedMessagePagesByConversation: [String: [ChatMessagePage]]
    private var sendFailuresRemaining: Int
    private var recordedSentTexts: [String] = []
    private var recordedAttachmentNames: [String] = []
    private var recordedConversationIDs: [String] = []
    private var recordedForwardedMessageIDs: [String] = []
    private var recordedForwardedTargetIDs: [[String]] = []
    private var pinnedMessageIDs: Set<String> = []
    private var storedReminders: [ChatReminder] = []
    private var storedScheduledMessages: [ChatScheduledMessage] = []
    private let attachmentThumbnailShouldFail: Bool
    private let downloadedAttachmentData: Data
    private var realtimeContinuation: AsyncStream<ChatRealtimeEvent>.Continuation?

    init(
        conversations: [ChatConversation],
        users: [ChatUser] = [ChatUser(id: "user-1", displayName: "测试用户")],
        messagesByConversation: [String: [ChatMessage]] = [:],
        queuedMessagePagesByConversation: [String: [ChatMessagePage]] = [:],
        sendFailuresRemaining: Int = 0,
        attachmentThumbnailShouldFail: Bool = false,
        downloadedAttachmentData: Data = Data("attachment".utf8),
        availableFeatures: Set<ChatFeature> = [
            .directConversation,
            .groupConversation,
            .textMessage,
            .emoji,
            .imageAttachment,
            .videoAttachment,
            .fileAttachment,
            .attachmentDownload,
            .reminder,
            .reminderManagement,
            .scheduledMessage,
            .poll,
            .deleteOwnMessage,
            .closeConversation,
            .messageForward,
            .groupMembers,
            .pinnedMessages
        ]
    ) {
        self.storedConversations = conversations
        self.users = users
        self.messagesByConversation = messagesByConversation
        self.queuedMessagePagesByConversation = queuedMessagePagesByConversation
        self.sendFailuresRemaining = sendFailuresRemaining
        self.attachmentThumbnailShouldFail = attachmentThumbnailShouldFail
        self.downloadedAttachmentData = downloadedAttachmentData
        self.availableFeatures = availableFeatures
    }

    func availability() async -> ChatAvailability {
        ChatAvailability(status: .available, supportedFeatures: availableFeatures)
    }

    func listUsers() async throws -> [ChatUser] {
        users
    }

    func listConversations() async throws -> [ChatConversation] {
        storedConversations
    }

    func listMessages(
        conversationID: String,
        before cursor: String?,
        limit: Int
    ) async throws -> ChatMessagePage {
        if var pages = queuedMessagePagesByConversation[conversationID], !pages.isEmpty {
            let page = pages.removeFirst()
            queuedMessagePagesByConversation[conversationID] = pages
            return page
        }
        return ChatMessagePage(
            messages: Array((messagesByConversation[conversationID] ?? []).suffix(limit)),
            previousCursor: nil,
            hasMoreBefore: false
        )
    }

    func openDirectConversation(
        userID: String,
        clientRequestID: UUID
    ) async throws -> ChatConversation {
        let opened = ChatConversation(
            id: "direct-\(userID)",
            kind: .direct,
            title: users.first(where: { $0.id == userID })?.displayName ?? "聊天",
            memberIDs: [userID]
        )
        storedConversations.append(opened)
        return opened
    }

    func createGroup(_ draft: ChatGroupDraft) async throws -> ChatConversation {
        let created = ChatConversation(
            id: "group-1",
            kind: .group,
            title: draft.title,
            memberIDs: draft.memberIDs,
            isEncrypted: draft.isEncrypted
        )
        storedConversations.append(created)
        return created
    }

    func sendMessage(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessage {
        recordedSentTexts.append(draft.text ?? "")
        recordedAttachmentNames.append(contentsOf: draft.localAttachmentURLs.map(\.lastPathComponent))
        recordedConversationIDs.append(draft.conversationID)
        if !draft.localAttachmentURLs.isEmpty {
            progress(1, 2)
        }
        if sendFailuresRemaining > 0 {
            sendFailuresRemaining -= 1
            throw AppError(
                category: .networkUnavailable,
                isRetryable: true,
                safeUserMessage: "连接中断，请检查网络后重试。"
            )
        }
        let attachments = draft.localAttachmentURLs.map {
            ChatAttachment(
                id: "sent-file-\($0.lastPathComponent)",
                kind: .image,
                fileName: $0.lastPathComponent
            )
        }
        if !draft.localAttachmentURLs.isEmpty {
            progress(2, 2)
        }
        let sent = ChatMessage(
            id: "sent-\(recordedSentTexts.count)",
            clientRequestID: draft.clientRequestID,
            conversationID: draft.conversationID,
            senderID: "current-user",
            sentAt: Date(timeIntervalSince1970: 3_000 + Double(recordedSentTexts.count)),
            text: draft.text,
            attachments: attachments
        )
        messagesByConversation[draft.conversationID, default: []].append(sent)
        return sent
    }

    func deleteMessage(
        conversationID: String,
        messageID: String,
        clientRequestID: UUID
    ) async throws {
        messagesByConversation[conversationID, default: []].removeAll { $0.id == messageID }
    }

    func closeConversation(
        conversationID: String,
        clientRequestID: UUID
    ) async throws {
        storedConversations.removeAll { $0.id == conversationID }
        messagesByConversation[conversationID] = nil
    }

    func listConversationMembers(conversationID: String) async throws -> [ChatUser] {
        let memberIDs = storedConversations
            .first(where: { $0.id == conversationID })?
            .memberIDs ?? []
        return users.filter { memberIDs.contains($0.id) }
    }

    func listPinnedMessages(conversationID: String) async throws -> [ChatMessage] {
        (messagesByConversation[conversationID] ?? [])
            .filter { pinnedMessageIDs.contains($0.id) }
            .map { messageWithPinnedState($0, isPinned: true) }
    }

    func setMessagePinned(
        conversationID: String,
        messageID: String,
        isPinned: Bool,
        clientRequestID: UUID
    ) async throws {
        if isPinned {
            pinnedMessageIDs.insert(messageID)
        } else {
            pinnedMessageIDs.remove(messageID)
        }
    }

    func forwardMessage(
        messageID: String,
        toConversationIDs: [String],
        clientRequestID: UUID
    ) async throws {
        recordedForwardedMessageIDs.append(messageID)
        recordedForwardedTargetIDs.append(toConversationIDs)
    }

    func setReminder(
        messageID: String,
        remindAt: Date,
        clientRequestID: UUID
    ) async throws -> ChatReminder {
        let reminder = ChatReminder(id: "reminder-1", messageID: messageID, remindAt: remindAt)
        storedReminders.removeAll { $0.messageID == messageID }
        storedReminders.append(reminder)
        return reminder
    }

    func listReminders(conversationID: String) async throws -> [ChatReminder] {
        storedReminders
    }

    func deleteReminder(
        messageID: String,
        conversationID: String,
        clientRequestID: UUID
    ) async throws {
        storedReminders.removeAll { $0.messageID == messageID }
    }

    func loadAttachmentThumbnail(
        messageID: String,
        size: ChatAttachmentThumbnailSize
    ) async throws -> Data {
        if attachmentThumbnailShouldFail {
            throw AppError(
                category: .invalidResponse,
                isRetryable: true,
                safeUserMessage: "没有可用缩略图。"
            )
        }
        return Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
    }

    func downloadAttachment(
        messageID: String,
        to destinationURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws {
        let data = downloadedAttachmentData
        progress(0, Int64(data.count))
        try data.write(to: destinationURL, options: .atomic)
        progress(Int64(data.count), Int64(data.count))
    }

    func listScheduledMessages(conversationID: String) async throws -> [ChatScheduledMessage] {
        storedScheduledMessages.filter { $0.conversationID == conversationID }
    }

    func createScheduledMessage(
        conversationID: String,
        text: String,
        sendAt: Date,
        clientRequestID: UUID
    ) async throws -> ChatScheduledMessage {
        let scheduled = ChatScheduledMessage(
            id: "schedule-\(storedScheduledMessages.count + 1)",
            conversationID: conversationID,
            text: text,
            sendAt: sendAt
        )
        storedScheduledMessages.append(scheduled)
        return scheduled
    }

    func deleteScheduledMessage(
        id: String,
        conversationID: String,
        clientRequestID: UUID
    ) async throws {
        storedScheduledMessages.removeAll { $0.id == id }
    }

    func createPoll(_ draft: ChatPollDraft) async throws -> ChatMessage {
        ChatMessage(
            id: "poll-1",
            clientRequestID: draft.clientRequestID,
            conversationID: draft.conversationID,
            senderID: "current-user",
            sentAt: Date(timeIntervalSince1970: 4_000),
            poll: ChatPoll(
                id: "poll-1",
                question: draft.question,
                allowsMultipleSelection: draft.allowsMultipleSelection,
                isAnonymous: draft.isAnonymous,
                closesAt: draft.closesAt,
                options: draft.options.enumerated().map { index, text in
                    ChatPollOption(id: "option-\(index)", text: text)
                }
            )
        )
    }

    func realtimeEvents() async -> AsyncStream<ChatRealtimeEvent> {
        let pair = AsyncStream<ChatRealtimeEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        realtimeContinuation = pair.continuation
        return pair.stream
    }

    func startRealtime() async {}

    func stopRealtime() async {
        realtimeContinuation?.finish()
        realtimeContinuation = nil
    }

    func emitRealtime(_ event: ChatRealtimeEvent) {
        realtimeContinuation?.yield(event)
    }

    func replaceConversations(_ values: [ChatConversation]) {
        storedConversations = values
    }

    func sentTexts() -> [String] {
        recordedSentTexts
    }

    func sentAttachmentNames() -> [String] {
        recordedAttachmentNames
    }

    func sentConversationIDs() -> [String] {
        recordedConversationIDs
    }

    func forwardedMessageIDs() -> [String] {
        recordedForwardedMessageIDs
    }

    func forwardedTargetConversationIDs() -> [[String]] {
        recordedForwardedTargetIDs
    }

    private func messageWithPinnedState(_ message: ChatMessage, isPinned: Bool) -> ChatMessage {
        ChatMessage(
            id: message.id,
            clientRequestID: message.clientRequestID,
            conversationID: message.conversationID,
            senderID: message.senderID,
            senderDisplayName: message.senderDisplayName,
            isFromCurrentUser: message.isFromCurrentUser,
            sentAt: message.sentAt,
            text: message.text,
            attachments: message.attachments,
            poll: message.poll,
            deliveryState: message.deliveryState,
            encryptionState: message.encryptionState,
            pinnedAt: isPinned ? Date(timeIntervalSince1970: 2_000) : nil
        )
    }
}

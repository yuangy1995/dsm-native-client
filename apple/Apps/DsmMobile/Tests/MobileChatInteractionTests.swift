import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatInteractionTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ChatInteractionTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func make(_ transport: MobileChatUITransport, root: URL, context: String = "test-context") async throws -> MobileChatInteractionModel {
        let repository = try makeRepository(transport)
        _ = try await repository.listConversations()
        let model = MobileChatInteractionModel(context: context, repository: repository, recovery: MobileChatInteractionStore(root: root))
        model.updateAvailability(await repository.availability())
        await model.loadPolicy()
        return model
    }

    private func makeRepository(_ transport: MobileChatUITransport) throws -> MobileReadOnlyChatRepository {
        let profile = try NasProfile(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
        let versions = [DsmAPIName.chatChannel: 2, DsmAPIName.chatUser: 1, DsmAPIName.chatPost: 8, DsmAPIName.chatAdminSetting: 3, DsmAPIName.chatPostFile: 2]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version, verified: false))
        }))
        return MobileReadOnlyChatRepository(base: try DsmChatRepository(profile: profile, capabilities: capabilities,
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport))
    }

    private var seed: ChatMessage {
        ChatMessage(id: "9001", conversationID: "27", senderID: "1", sentAt: .now, text: "Sample message 1")
    }

    func test搜索使用独立游标完整加载并保留范围() async throws {
        let transport = MobileChatUITransport()
        let model = try await make(transport, root: root())
        await model.search(" Sample ", conversationID: "27")
        XCTAssertEqual(model.searchMessages.count, 25); XCTAssertEqual(model.searchCursor, "25")
        await model.search("Sample", conversationID: "27", more: true)
        XCTAssertEqual(model.searchMessages.count, 28); XCTAssertNil(model.searchCursor)
        let requests = await transport.searches()
        XCTAssertEqual(requests.map { $0.1 }, ["[27]", "[27]"])
        XCTAssertEqual(requests.map { $0.2 }, ["0", "25"])
        await model.search("Sample", conversationID: nil)
        let all = await transport.searches()
        XCTAssertEqual(all.last?.1, "[]"); XCTAssertEqual(all.last?.2, "0")
    }

    func test新的搜索覆盖旧查询迟到响应且空词不发请求() async throws {
        let transport = MobileChatUITransport()
        let model = try await make(transport, root: root())
        let first = Task { await model.search("slow", conversationID: nil) }
        while await transport.searches().isEmpty { await Task.yield() }
        await model.search("missing", conversationID: nil)
        await first.value
        XCTAssertEqual(model.searchQuery, "missing"); XCTAssertTrue(model.searchMessages.isEmpty)
        XCTAssertTrue(model.hasSearched); XCTAssertFalse(model.isSearching)
        await model.search("  ", conversationID: nil)
        XCTAssertFalse(model.hasSearched)
        let calls = await transport.searches(); XCTAssertEqual(calls.count, 2)
    }

    func test搜索跨会话数据不能显示为当前聊天结果() async throws {
        let model = try await make(MobileChatUITransport(), root: root())
        await model.search("Sample", conversationID: "28")
        XCTAssertTrue(model.searchError); XCTAssertTrue(model.searchMessages.isEmpty)
    }

    func test编辑只开放本人并同时更新原消息和搜索缓存() async throws {
        let transport = MobileChatUITransport()
        let model = try await make(transport, root: root())
        await model.search("Sample", conversationID: nil)
        await model.open(seed)
        let original = try XCTUnwrap(model.root)
        XCTAssertTrue(model.canEdit(original))
        XCTAssertFalse(model.canEdit(try XCTUnwrap(model.replies.messages.first)))
        let success = await model.edit(original, text: "Edited sample")
        XCTAssertTrue(success); XCTAssertEqual(model.root?.text, "Edited sample")
        XCTAssertEqual(model.searchMessages.first?.text, "Edited sample"); XCTAssertTrue(model.pending.isEmpty)
        let counts = await transport.writeCounts(); XCTAssertEqual(counts.0, 1)
    }

    func test编辑策略关闭时零写入() async throws {
        let transport = MobileChatUITransport(state: "chat-readonly")
        let model = try await make(transport, root: root())
        await model.open(seed)
        let success = await model.edit(try XCTUnwrap(model.root), text: "Edited sample")
        XCTAssertFalse(success); XCTAssertTrue(model.pending.isEmpty)
        let counts = await transport.writeCounts(); XCTAssertEqual(counts.0, 0)
    }

    func test编辑未知落盘不存正文重启只读完成() async throws {
        let directory = try root()
        let transport = MobileChatUITransport(state: "chat-edit-unknown")
        let model = try await make(transport, root: directory)
        await model.open(seed)
        let original = try XCTUnwrap(model.root)
        let success = await model.edit(original, text: "Edited sample")
        XCTAssertFalse(success); XCTAssertEqual(model.pending.count, 1); XCTAssertFalse(model.canEdit(original))
        let record = try String(contentsOf: directory.appendingPathComponent("interactions-v1.json"), encoding: .utf8)
        XCTAssertFalse(record.contains("Edited sample")); XCTAssertFalse(record.contains("Sample message")); XCTAssertFalse(record.contains("synthetic"))
        model.invalidate()
        let recoveredTransport = MobileChatUITransport(state: "chat-edit-restored")
        let recovered = try await make(recoveredTransport, root: directory)
        await recovered.open(seed)
        XCTAssertTrue(recovered.pending.isEmpty); XCTAssertEqual(recovered.root?.text, "Edited sample")
        let counts = await recoveredTransport.writeCounts(); XCTAssertEqual(counts.0, 0)
    }

    func test未知记录跨账号隔离且不可被别的账号完成() async throws {
        let directory = try root()
        let transport = MobileChatUITransport(state: "chat-edit-unknown")
        let first = try await make(transport, root: directory, context: "account-a")
        await first.open(seed); _ = await first.edit(try XCTUnwrap(first.root), text: "Edited sample")
        let other = try await make(MobileChatUITransport(state: "chat-edit-restored"), root: directory, context: "account-b")
        await other.open(seed)
        XCTAssertTrue(other.pending.isEmpty); XCTAssertEqual(other.recovery.entries.count, 1)
        XCTAssertEqual(other.recovery.entries.first?.context, "account-a")
    }

    func test写前保存失败不提交消息() async throws {
        let directory = try root().appendingPathComponent("not-a-directory")
        try Data().write(to: directory)
        let transport = MobileChatUITransport()
        let model = try await make(transport, root: directory)
        await model.open(seed)
        let success = await model.edit(try XCTUnwrap(model.root), text: "Edited sample")
        XCTAssertFalse(success); XCTAssertTrue(model.recovery.failed)
        let counts = await transport.writeCounts(); XCTAssertEqual(counts.0, 0)
        XCTAssertFalse(model.canSendReply("new reply"))
    }

    func test同目标连续点击和换会话不产生第二次编辑() async throws {
        let transport = MobileChatUITransport(state: "chat-edit-slow")
        let model = try await make(transport, root: root())
        await model.open(seed)
        let original = try XCTUnwrap(model.root)
        let first = Task { await model.edit(original, text: "Edited sample") }
        while await transport.writeCounts().0 == 0 { await Task.yield() }
        let second = await model.edit(original, text: "other text")
        XCTAssertFalse(second)
        model.invalidate()
        let firstResult = await first.value
        XCTAssertFalse(firstResult); XCTAssertNil(model.root)
        XCTAssertTrue(model.recovery.entries.isEmpty)
        let counts = await transport.writeCounts(); XCTAssertEqual(counts.0, 1)
    }

    func test线程根与回复独立读取并发送到原线程() async throws {
        let transport = MobileChatUITransport()
        let model = try await make(transport, root: root())
        await model.open(seed)
        XCTAssertEqual(model.root?.id, "9001"); XCTAssertEqual(model.replies.messages.map(\.id), ["9100"])
        let success = await model.sendReply("New reply")
        XCTAssertTrue(success); XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.replies.messages.last?.threadID, "9001"); XCTAssertEqual(model.replies.messages.last?.text, "New reply")
        let counts = await transport.writeCounts(); XCTAssertEqual(counts.1, 1)
    }

    func test回复未知重启后相同内容不重发其他内容仍可发送() async throws {
        let directory = try root()
        let transport = MobileChatUITransport(state: "chat-reply-unknown")
        let model = try await make(transport, root: directory)
        await model.open(seed)
        let first = await model.sendReply("Unknown reply")
        XCTAssertFalse(first); XCTAssertEqual(model.pending.count, 1)
        XCTAssertFalse(model.canSendReply(" Unknown reply "))
        let restoredTransport = MobileChatUITransport()
        let restored = try await make(restoredTransport, root: directory)
        await restored.open(seed)
        let duplicate = await restored.sendReply("Unknown reply")
        XCTAssertFalse(duplicate); XCTAssertTrue(restored.canSendReply("Different reply"))
        let counts = await restoredTransport.writeCounts(); XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(restored.pending.count, 1)
    }

    func test线程分页保留完整历史并排除定位记录() async throws {
        let model = try await make(MobileChatUITransport(state: "chat-thread-pages"), root: root())
        await model.open(seed)
        XCTAssertEqual(model.replies.messages.count, 50); XCTAssertTrue(model.replies.hasMoreBefore)
        await model.loadReplies(more: true)
        XCTAssertEqual(model.replies.messages.count, 60); XCTAssertFalse(model.replies.hasMoreBefore)
        XCTAssertEqual(Set(model.replies.messages.map(\.id)).count, 60)
        let reply = try XCTUnwrap(model.replies.messages.first)
        await model.open(reply)
        XCTAssertEqual(model.root?.id, "9001"); XCTAssertEqual(model.focusedMessage?.id, "9100")
    }

    func test回复发送中刷新仍完成原草稿不会提示重新发送() async throws {
        let transport = MobileChatUITransport(state: "chat-reply-slow")
        let model = try await make(transport, root: root())
        await model.open(seed)
        let task = Task { await model.sendReply("Reply during refresh") }
        while await transport.writeCounts().1 == 0 { await Task.yield() }
        await model.open(seed)
        let sent = await task.value
        XCTAssertTrue(sent); XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.replies.messages.last?.text, "Reply during refresh")
        let counts = await transport.writeCounts(); XCTAssertEqual(counts.1, 1)
    }

    func test回复写前无法读取根消息时解除草稿限制且零提交() async throws {
        let transport = MobileChatUITransport()
        let model = try await make(transport, root: root())
        await model.open(seed); await transport.setReadFailures(true)
        let sent = await model.sendReply("Retryable reply")
        XCTAssertFalse(sent); XCTAssertTrue(model.pending.isEmpty)
        XCTAssertTrue(model.canSendReply("Retryable reply"))
        let counts = await transport.writeCounts(); XCTAssertEqual(counts.1, 0)
    }

    func test关闭线程不保留消息或接受迟到搜索() async throws {
        let transport = MobileChatUITransport()
        let model = try await make(transport, root: root())
        await model.open(seed); XCTAssertTrue(model.containsFocusedMessage(conversationID: "27", messageID: "9100"))
        model.closeDiscussion()
        XCTAssertNil(model.root); XCTAssertTrue(model.replies.messages.isEmpty); XCTAssertFalse(model.canSendReply("reply"))
        let search = Task { await model.search("slow", conversationID: nil) }
        while await transport.searches().isEmpty { await Task.yield() }
        model.invalidate(); await search.value
        XCTAssertTrue(model.searchMessages.isEmpty); XCTAssertFalse(model.isSearching)
    }

    func test线程附件关闭后清除加载状态再次打开仍可读取和导出() async throws {
        let directory = try root(), transport = MobileChatUITransport(state: "chat-thread-attachment")
        let chat = MobileChatModel(attachmentRootURL: directory.appendingPathComponent("Attachments"), interactionRecoveryRoot: directory.appendingPathComponent("Recovery"))
        await chat.activate(profileID: UUID(), repository: try makeRepository(transport))
        let interaction = try XCTUnwrap(chat.interaction)
        await interaction.open(seed)
        let reply = try XCTUnwrap(interaction.replies.messages.first), attachment = try XCTUnwrap(reply.attachments.first)
        XCTAssertTrue(chat.canUseRemoteAttachment(attachment, in: reply))
        chat.loadAttachmentThumbnail(for: reply)
        XCTAssertTrue(chat.state.loadingAttachmentThumbnailIDs.contains(reply.id))
        interaction.closeDiscussion()
        try await wait { !chat.state.loadingAttachmentThumbnailIDs.contains(reply.id) }
        XCTAssertNil(chat.state.attachmentThumbnailsByMessageID[reply.id])
        await interaction.open(seed); chat.loadAttachmentThumbnail(for: reply)
        try await wait { chat.state.attachmentThumbnailsByMessageID[reply.id] != nil }
        chat.saveRemoteAttachment(attachment, in: reply)
        XCTAssertEqual(chat.state.remoteAttachmentMessageID, reply.id)
        interaction.closeDiscussion(); chat.cancelRemoteAttachmentDownload()
        XCTAssertNil(chat.state.remoteAttachmentMessageID)
        await interaction.open(seed); chat.saveRemoteAttachment(attachment, in: reply)
        try await wait { chat.remoteAttachmentPresentation != nil }
        let presentation = try XCTUnwrap(chat.remoteAttachmentPresentation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: presentation.localURL.path))
        chat.dismissRemoteAttachmentPresentation()
        XCTAssertFalse(FileManager.default.fileExists(atPath: presentation.localURL.path))
        chat.deactivate()
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待明确的异步状态超时")
    }

    func test消息不存在与读取失败分别呈现() async throws {
        let transport = MobileChatUITransport()
        let model = try await make(transport, root: root())
        await model.open(ChatMessage(id: "9999", conversationID: "27", senderID: "1", sentAt: .now, text: "missing"))
        XCTAssertTrue(model.missingMessage); XCTAssertFalse(model.threadError)
        await transport.setReadFailures(true)
        await model.open(seed)
        XCTAssertFalse(model.missingMessage); XCTAssertTrue(model.threadError)
        XCTAssertFalse(model.canSendReply("reply"))
    }

    func test损坏或非当前恢复格式保留原文件并拒绝写入() throws {
        for data in [Data("not-json".utf8), Data(#"{"version":2,"entries":[]}"#.utf8)] {
            let directory = try root(), file = directory.appendingPathComponent("interactions-v1.json")
            try data.write(to: file)
            let store = MobileChatInteractionStore(root: directory)
            XCTAssertTrue(store.failed); XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }
}

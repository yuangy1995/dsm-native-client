import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatManagementTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatManagementTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func repository(_ transport: MobileChatManagementUITransport, channelVersion: Int = 5, postVersion: Int = 8) throws -> MobileReadOnlyChatRepository {
        let profile = try NasProfile(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
        let versions = [DsmAPIName.chatChannel: channelVersion, DsmAPIName.chatPost: postVersion, DsmAPIName.chatUser: 1, DsmAPIName.chatPostFile: 2]
        let caps = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version, verified: false))
        }))
        return MobileReadOnlyChatRepository(base: try DsmChatRepository(profile: profile, capabilities: caps,
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport))
    }
    private func make(_ transport: MobileChatManagementUITransport, root: URL? = nil, context: String = "fixture") async throws -> (MobileChatManagementModel, MobileReadOnlyChatRepository) {
        let repo = try repository(transport)
        let model = MobileChatManagementModel(context: context, repository: repo, recovery: MobileChatManagementStore(root: try root ?? directory()))
        model.updateAvailability(await repo.availability()); return (model, repo)
    }
    private func message(_ repo: MobileReadOnlyChatRepository, pinned: Bool = false) async throws -> ChatMessage {
        let value = try await repo.message(conversationID: "27", messageID: pinned ? "9002" : "9001", threadID: nil)
        return try XCTUnwrap(value)
    }
    private func conversations(_ repo: MobileReadOnlyChatRepository) async throws -> [ChatConversation] { try await repo.listConversations() }

    func test置顶及取消绑定原消息并回读最终状态() async throws {
        let transport = MobileChatManagementUITransport(); let (model, repo) = try await make(transport)
        let original = try await message(repo)
        let pinned = await model.setPinned(original, isPinned: true); XCTAssertTrue(pinned)
        let updated = try await message(repo); XCTAssertTrue(updated.isPinned)
        let unpinned = await model.setPinned(updated, isPinned: false); XCTAssertTrue(unpinned)
        XCTAssertTrue(model.pending.isEmpty)
        let calls = await transport.counts().writes
        XCTAssertEqual(calls.map { $0.0 }, ["pin", "unpin"]); XCTAssertEqual(calls.map { $0.1 }, ["9001", "9001"])
        XCTAssertEqual(calls.map { $0.2 }, ["5", "5"])
    }
    func test完整公告分页保留附件不截断到一百条() async throws {
        let transport = MobileChatManagementUITransport(); await transport.manyPins()
        let repo = try repository(transport); let values = try await repo.listPinnedMessages(conversationID: "27")
        XCTAssertEqual(values.count, 112); XCTAssertEqual(Set(values.map(\.id)).count, 112)
        XCTAssertEqual(values.first { $0.id == "9002" }?.attachments.first?.fileName, "sample.png")
        XCTAssertEqual(values.first { $0.id == "9003" }?.poll?.options.map(\.text), ["Alpha", "Beta"])
        let calls = await transport.counts(); XCTAssertEqual(calls.reads, 2); XCTAssertTrue(calls.writes.isEmpty)
    }
    func test原消息被编辑时不置顶或取消公告() async throws {
        for pinned in [false, true] {
            let transport = MobileChatManagementUITransport(); let (model, repo) = try await make(transport)
            let original = try await message(repo, pinned: pinned); await transport.changeContent()
            let saved = await model.setPinned(original, isPinned: !pinned)
            XCTAssertFalse(saved); XCTAssertEqual(model.errorKey, "mobile.chat.management.changed")
            let calls = await transport.counts(); XCTAssertTrue(calls.writes.isEmpty)
        }
    }
    func test其他客户端重新置顶时旧快照不能取消() async throws {
        let transport = MobileChatManagementUITransport(); let (model, repo) = try await make(transport)
        let original = try await message(repo, pinned: true); await transport.changePinTime()
        let saved = await model.setPinned(original, isPinned: false); XCTAssertFalse(saved)
        let calls = await transport.counts(); XCTAssertTrue(calls.writes.isEmpty)
    }
    func test会话不可见加密或不是群聊时零置顶() async throws {
        for mode in 0..<3 {
            let transport = MobileChatManagementUITransport(); let (model, repo) = try await make(transport)
            let original = try await message(repo); await transport.setAccess(encrypted: mode == 0, missing: mode == 1, direct: mode == 2)
            let saved = await model.setPinned(original, isPinned: true); XCTAssertFalse(saved)
            let calls = await transport.counts(); XCTAssertTrue(calls.writes.isEmpty)
        }
    }
    func test三种写入丢回执重启只读取不重放() async throws {
        for kind in 0..<3 {
            let transport = MobileChatManagementUITransport(state: "chat-management-unknown"); let root = try directory()
            let (model, repo) = try await make(transport, root: root)
            if kind == 2 { await model.close([try await conversations(repo)[0]]) }
            else { let original = try await message(repo, pinned: kind == 1); let saved = await model.setPinned(original, isPinned: kind == 0); XCTAssertFalse(saved) }
            XCTAssertEqual(model.pending.count, 1)
            let record = try String(contentsOf: root.appendingPathComponent("management-actions-v1.json"), encoding: .utf8)
            XCTAssertFalse(record.contains("Sample")); XCTAssertFalse(record.contains("synthetic"))
            await transport.setReadFailures(false)
            let (restarted, _) = try await make(transport, root: root); await restarted.recover()
            XCTAssertTrue(restarted.pending.isEmpty)
            let calls = await transport.counts(); XCTAssertEqual(calls.writes.count, 1)
        }
    }
    func test三种明确拒绝解除目标限制() async throws {
        for kind in 0..<3 {
            let transport = MobileChatManagementUITransport(state: "chat-management-denied"); let (model, repo) = try await make(transport)
            if kind == 2 { await model.close([try await conversations(repo)[0]]) }
            else { let original = try await message(repo, pinned: kind == 1); let saved = await model.setPinned(original, isPinned: kind == 0); XCTAssertFalse(saved) }
            XCTAssertTrue(model.pending.isEmpty); XCTAssertEqual(model.errorKey, "mobile.chat.management.failed")
        }
    }
    func test批量关闭逐项核查并使用五版接口() async throws {
        let transport = MobileChatManagementUITransport(); let (model, repo) = try await make(transport)
        await model.close(try await conversations(repo))
        XCTAssertEqual(model.closeResults["27"], .closed); XCTAssertEqual(model.closeResults["28"], .closed)
        let remaining = try await conversations(repo); XCTAssertTrue(remaining.isEmpty)
        let calls = await transport.counts(); XCTAssertEqual(calls.writes.map { $0.0 }, ["close", "close"])
        XCTAssertEqual(calls.writes.map { $0.2 }, ["5", "5"])
    }
    func test关闭未知暂停后续项且恢复不会擅自继续() async throws {
        let transport = MobileChatManagementUITransport(state: "chat-management-unknown"); let (model, repo) = try await make(transport)
        let originals = try await conversations(repo); await model.close(originals)
        XCTAssertEqual(model.closeResults["27"], .pending); XCTAssertNil(model.closeResults["28"])
        await model.close(originals); await transport.setReadFailures(false); await model.recover()
        XCTAssertEqual(model.closeResults["27"], .closed); XCTAssertNil(model.closeResults["28"])
        let calls = await transport.counts(); XCTAssertEqual(calls.writes.count, 1)
    }
    func test批量关闭明确拒绝仍可处理下一项() async throws {
        let transport = MobileChatManagementUITransport(state: "chat-management-denied"); let (model, repo) = try await make(transport)
        await model.close(try await conversations(repo))
        XCTAssertEqual(model.closeResults["27"], .failed); XCTAssertEqual(model.closeResults["28"], .failed)
        let calls = await transport.counts(); XCTAssertEqual(calls.writes.count, 2)
    }
    func test关闭不读取加密消息并允许移除该会话() async throws {
        let transport = MobileChatManagementUITransport(); await transport.setAccess(encrypted: true)
        let (model, repo) = try await make(transport); await model.close([try await conversations(repo)[0]])
        XCTAssertEqual(model.closeResults["27"], .closed)
        let calls = await transport.counts(); XCTAssertEqual(calls.writes.map { $0.0 }, ["close"])
    }
    func test会话已经消失时关闭零提交() async throws {
        let transport = MobileChatManagementUITransport(); let (model, repo) = try await make(transport)
        let originals = try await conversations(repo); await transport.setAccess(missing: true); await model.close(originals)
        XCTAssertEqual(model.closeResults.count, 2)
        let calls = await transport.counts(); XCTAssertTrue(calls.writes.isEmpty)
    }
    func test会话确认后身份属性改变时零关闭() async throws {
        let transport = MobileChatManagementUITransport(); let (model, repo) = try await make(transport)
        let originals = try await conversations(repo); await transport.setAccess(encrypted: true); await model.close(originals)
        XCTAssertEqual(model.closeResults["27"], .failed)
        let calls = await transport.counts(); XCTAssertTrue(calls.writes.isEmpty)
    }
    func test重复点击置顶或关闭只提交一次() async throws {
        for closing in [false, true] {
            let transport = MobileChatManagementUITransport(state: "chat-management-slow"); let (model, repo) = try await make(transport)
            let original = try await message(repo); let values = try await conversations(repo)
            let task = Task { if closing { await model.close([values[0]]) } else { _ = await model.setPinned(original, isPinned: true) } }
            while await transport.counts().writes.isEmpty { await Task.yield() }
            if closing { await model.close([values[0]]) } else { let saved = await model.setPinned(original, isPinned: true); XCTAssertFalse(saved) }
            await task.value; let calls = await transport.counts(); XCTAssertEqual(calls.writes.count, 1)
        }
    }
    func test提交前取消零请求提交中取消保留原身份() async throws {
        for during in [false, true] {
            let transport = MobileChatManagementUITransport(state: "chat-management-slow"); let (model, repo) = try await make(transport)
            let original = try await message(repo)
            let task = Task { await model.setPinned(original, isPinned: true) }
            if during { while await transport.counts().writes.isEmpty { await Task.yield() } }
            task.cancel(); let saved = await task.value; XCTAssertFalse(saved)
            XCTAssertEqual(model.pending.count, during ? 1 : 0)
            let calls = await transport.counts(); XCTAssertEqual(calls.writes.count, during ? 1 : 0)
        }
    }
    func test失效模型迟到响应不更新页面或开启下一项() async throws {
        let transport = MobileChatManagementUITransport(state: "chat-management-slow"); let (model, repo) = try await make(transport)
        let originals = try await conversations(repo)
        let task = Task { await model.close(originals) }
        while await transport.counts().writes.isEmpty { await Task.yield() }
        model.invalidate(); await task.value
        XCTAssertTrue(model.closeResults.isEmpty); XCTAssertTrue(model.pending.isEmpty)
        let calls = await transport.counts(); XCTAssertEqual(calls.writes.count, 1)
    }
    func test其他账号不读取或解除恢复记录() async throws {
        let transport = MobileChatManagementUITransport(state: "chat-management-unknown"); let root = try directory()
        let (model, repo) = try await make(transport, root: root); await model.close([try await conversations(repo)[0]])
        let before = await transport.counts(); let (other, _) = try await make(transport, root: root, context: "other")
        await other.recover(); let after = await transport.counts()
        XCTAssertEqual(before.reads, after.reads); XCTAssertTrue(other.pending.isEmpty); XCTAssertEqual(other.recovery.entries.count, 1)
    }
    func test重复列表身份不能作为置顶或关闭证据() async throws {
        let transport = MobileChatManagementUITransport(); let (model, repo) = try await make(transport)
        let original = try await message(repo); let values = try await conversations(repo); await transport.setDuplicate(true)
        let saved = await model.setPinned(original, isPinned: true); XCTAssertFalse(saved); await model.close(values)
        let calls = await transport.counts(); XCTAssertTrue(calls.writes.isEmpty)
    }
    func test恢复文件损坏或无法落盘时零写入() async throws {
        for corrupted in [false, true] {
            let root = try directory()
            if corrupted { try Data("broken".utf8).write(to: root.appendingPathComponent("management-actions-v1.json")) }
            else { try FileManager.default.removeItem(at: root); try Data().write(to: root) }
            let transport = MobileChatManagementUITransport(); let (model, repo) = try await make(transport, root: root)
            let original = try await message(repo); let saved = await model.setPinned(original, isPinned: true); XCTAssertFalse(saved)
            await model.close(try await conversations(repo)); XCTAssertTrue(model.recovery.failed)
            let calls = await transport.counts(); XCTAssertTrue(calls.writes.isEmpty)
        }
    }
    func test缺少固定版本能力不开放写入() async throws {
        let transport = MobileChatManagementUITransport(); let repo = try repository(transport, channelVersion: 4, postVersion: 4)
        let availability = await repo.availability(); XCTAssertFalse(availability.supportedFeatures.contains(.closeConversation)); XCTAssertFalse(availability.supportedFeatures.contains(.pinnedMessages))
        do { try await repo.closeConversation(conversationID: "27", clientRequestID: UUID()); XCTFail("缺能力不得关闭") }
        catch { XCTAssertTrue(error is MobileReadOnlyChatRepositoryError) }
        do { try await repo.setMessagePinned(conversationID: "27", messageID: "9001", isPinned: true, clientRequestID: UUID()); XCTFail("缺能力不得置顶") }
        catch { XCTAssertTrue(error is MobileReadOnlyChatRepositoryError) }
        let calls = await transport.counts(); XCTAssertTrue(calls.writes.isEmpty)
    }

    func test关闭结果未知时原会话不能发送且其他会话不受限() async throws {
        let transport = MobileChatManagementUITransport(state: "chat-management-unknown")
        let repo = try repository(transport)
        let chat = MobileChatModel(interactionRecoveryRoot: try directory())
        await chat.activate(profileID: UUID(), repository: repo, context: "fixture")
        let original = try XCTUnwrap(chat.state.conversations.first { $0.id == "27" })
        await chat.selectConversation(original); chat.setDraft("Unsent draft")
        XCTAssertTrue(chat.canSendSelectedDraft)
        let management = try XCTUnwrap(chat.management); await management.close([original])
        XCTAssertFalse(chat.canSendSelectedDraft); XCTAssertTrue(management.blocksWrites(in: "27")); XCTAssertFalse(management.blocksWrites(in: "28"))
        await chat.sendSelectedMessage()
        let calls = await transport.counts(); XCTAssertEqual(calls.writes.map { $0.0 }, ["close"])
        XCTAssertEqual(chat.state.selectedDraft, "Unsent draft")
    }

    func test关闭恢复随会话刷新清除原目标并保留草稿() async throws {
        let transport = MobileChatManagementUITransport(state: "chat-management-unknown"); let root = try directory()
        let repo = try repository(transport); let chat = MobileChatModel(interactionRecoveryRoot: root)
        await chat.activate(profileID: UUID(), repository: repo, context: "fixture")
        let original = try XCTUnwrap(chat.state.conversations.first { $0.id == "27" }); await chat.selectConversation(original)
        chat.setDraft("Unsent draft"); await chat.management?.close([original]); XCTAssertEqual(chat.management?.pending.count, 1)
        await transport.setReadFailures(false); await chat.reloadConversations()
        XCTAssertEqual(chat.management?.pending.count, 0); XCTAssertFalse(chat.state.conversations.contains { $0.id == "27" })
        XCTAssertNil(chat.state.selectedConversationID); XCTAssertEqual(chat.state.draftsByConversation["27"], "Unsent draft")
        let calls = await transport.counts(); XCTAssertEqual(calls.writes.count, 1)
    }

    func test公告失败只反馈给原消息() async throws {
        let transport = MobileChatManagementUITransport(state: "chat-management-denied"); let (model, repo) = try await make(transport)
        let original = try await message(repo); let other = try await message(repo, pinned: true)
        let saved = await model.setPinned(original, isPinned: true); XCTAssertFalse(saved)
        XCTAssertEqual(model.error(for: original), "mobile.chat.management.failed"); XCTAssertNil(model.error(for: other))
    }

    func test受保护公告不得过滤后作为取消成功的证据() async throws {
        let transport = MobileChatManagementUITransport(); let (model, _) = try await make(transport)
        let entry = MobileChatManagementStore.Entry(id: UUID(), context: model.context, kind: .unpin, conversationID: "27", messageID: "9002")
        XCTAssertTrue(model.recovery.reserve(entry)); await transport.setEncryptedMessages(); await model.recover()
        XCTAssertEqual(model.pending, [entry])
        let calls = await transport.counts(); XCTAssertTrue(calls.writes.isEmpty)
    }

    func test较早公告附件可预览而切到其他会话后不可复用() async throws {
        let transport = MobileChatManagementUITransport(); let repo = try repository(transport)
        let chat = MobileChatModel(interactionRecoveryRoot: try directory())
        await chat.activate(profileID: UUID(), repository: repo, context: "fixture")
        let original = try XCTUnwrap(chat.state.conversations.first { $0.id == "27" })
        let other = try XCTUnwrap(chat.state.conversations.first { $0.id == "28" }); await chat.selectConversation(original)
        XCTAssertFalse(chat.state.selectedMessages.messages.contains { $0.id == "9100" })
        await transport.manyPins(); await chat.loadConversationAnnouncements(forceRefresh: true)
        let announcement = try XCTUnwrap(chat.state.selectedConversationAnnouncements.first { $0.id == "9100" })
        let attachment = try XCTUnwrap(announcement.attachments.first)
        XCTAssertTrue(chat.canUseRemoteAttachment(attachment, in: announcement))
        await chat.selectConversation(other)
        XCTAssertFalse(chat.canUseRemoteAttachment(attachment, in: announcement))
    }

    func test旧请求尚在执行时重新绑定不能提前解除其恢复限制() async throws {
        let transport = MobileChatManagementUITransport(state: "chat-management-slow"); let (old, repo) = try await make(transport)
        let original = try await message(repo); let task = Task { await old.setPinned(original, isPinned: true) }
        while await transport.counts().writes.isEmpty { await Task.yield() }
        old.invalidate(); await transport.pinElsewhere(original.id)
        let next = MobileChatManagementModel(context: old.context, repository: repo, recovery: old.recovery)
        next.updateAvailability(await repo.availability()); let before = await transport.counts()
        await next.recover(); let after = await transport.counts()
        XCTAssertEqual(next.pending.count, 1); XCTAssertEqual(before.reads, after.reads); XCTAssertFalse(next.canPin(original))
        let saved = await task.value; XCTAssertFalse(saved); XCTAssertTrue(next.pending.isEmpty)
        let calls = await transport.counts(); XCTAssertEqual(calls.writes.count, 1)
    }
}

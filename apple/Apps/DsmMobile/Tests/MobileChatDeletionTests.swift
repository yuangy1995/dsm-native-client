import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatDeletionTests: XCTestCase {
    func test多条本人消息按原时间删除并保存逐项结果() async throws {
        let root = try root(), transport = MobileChatDeletionUITransport(), (model, repo) = try await make(transport, root: root)
        let messages = try await messages(repo)
        XCTAssertFalse(model.canSelect(try XCTUnwrap(messages.first { $0.id == "9003" })))
        let own = messages.filter { $0.isFromCurrentUser == true }
        let id = try XCTUnwrap(model.createBatch(own.reversed()))
        XCTAssertNil(model.createBatch(own))
        await model.run(id, continuePlanned: true)
        XCTAssertEqual(model.entry(id)?.items.map(\.phase), [.complete, .complete])
        XCTAssertEqual(MobileChatDeletionStore(root: root).entries, model.entries)
        let writes = await transport.recordedWrites(); XCTAssertEqual(writes, ["9001", "9002"])
        let data = try String(contentsOf: root.appendingPathComponent("message-deletions-v1.json"), encoding: .utf8)
        XCTAssertFalse(data.contains("Sample message")); XCTAssertFalse(data.contains("Sample.pdf"))
    }

    func test删除未知重启先只读恢复再明确继续未开始项() async throws {
        let root = try root(), transport = MobileChatDeletionUITransport(state: "chat-deletion-partial")
        let (model, repo) = try await make(transport, root: root)
        let own = try await messages(repo).filter { $0.isFromCurrentUser == true }
        let id = try XCTUnwrap(model.createBatch(own))
        await model.run(id, continuePlanned: true)
        XCTAssertEqual(model.entry(id)?.items.map(\.phase), [.submitted, .planned])
        let next = MobileChatDeletionUITransport(state: "chat-deletion-restored"), (restored, _) = try await make(next, root: root)
        // 即使传入继续，本轮进入时有已提交项，也不能越界启动下一项。
        await restored.run(id, continuePlanned: true)
        XCTAssertEqual(restored.entry(id)?.items.map(\.phase), [.complete, .planned])
        let readsOnly = await next.recordedWrites(); XCTAssertTrue(readsOnly.isEmpty)
        await restored.run(id, continuePlanned: true)
        XCTAssertEqual(restored.entry(id)?.items.map(\.phase), [.complete, .complete])
        let writes = await next.recordedWrites(); XCTAssertEqual(writes, ["9002"])
    }

    func test丢回执消息仍在不重删且取消只保留未开始消息() async throws {
        let root = try root(), transport = MobileChatDeletionUITransport(state: "chat-deletion-unknown")
        let (model, repo) = try await make(transport, root: root), own = try await messages(repo).filter { $0.isFromCurrentUser == true }
        let id = try XCTUnwrap(model.createBatch(own)); await model.run(id, continuePlanned: true)
        let next = MobileChatDeletionUITransport(), (restored, _) = try await make(next, root: root)
        await restored.run(id, continuePlanned: false); await restored.run(id, continuePlanned: true)
        XCTAssertEqual(restored.entry(id)?.items.map(\.phase), [.submitted, .planned])
        restored.cancelRemaining(id); restored.remove(id)
        XCTAssertEqual(restored.entry(id)?.items.map(\.phase), [.submitted, .cancelled])
        XCTAssertFalse(restored.canSelect(own[0])); XCTAssertTrue(restored.canSelect(own[1]))
        let writes = await next.recordedWrites(); XCTAssertTrue(writes.isEmpty)
    }

    func test部分明确拒绝保留成功结果且新选择使用新身份() async throws {
        let transport = MobileChatDeletionUITransport(state: "chat-deletion-denied"), (model, repo) = try await make(transport, root: root())
        let own = try await messages(repo).filter { $0.isFromCurrentUser == true }, id = try XCTUnwrap(model.createBatch(own))
        await model.run(id, continuePlanned: true)
        XCTAssertEqual(model.entry(id)?.items.map(\.phase), [.complete, .failed])
        XCTAssertEqual(model.entry(id)?.items.last?.failure, .denied)
        XCTAssertTrue(model.canSelect(own[1]))
        let next = try XCTUnwrap(model.createBatch([own[1]]))
        XCTAssertNotEqual(model.entry(next)?.items.first?.id, model.entry(id)?.items.last?.id)
    }

    func test未开始项原文改变后零删除且显示内容变化() async throws {
        let transport = MobileChatDeletionUITransport(), (model, repo) = try await make(transport, root: root())
        let source = try await source(repo), id = try XCTUnwrap(model.createBatch([source]))
        await transport.change(source.id); await model.run(id, continuePlanned: true)
        XCTAssertEqual(model.entry(id)?.items.first?.phase, .failed)
        XCTAssertEqual(model.entry(id)?.items.first?.failure, .changed)
        let writes = await transport.recordedWrites(); XCTAssertTrue(writes.isEmpty)
    }

    func test删除写前落盘失败零请求且不覆盖原记录() async throws {
        let root = try root(), transport = MobileChatDeletionUITransport(), (model, repo) = try await make(transport, root: root)
        let source = try await source(repo), id = try XCTUnwrap(model.createBatch([source]))
        let file = root.appendingPathComponent("message-deletions-v1.json"), saved = try Data(contentsOf: file)
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("saved.json"))
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await model.run(id, continuePlanned: true)
        XCTAssertTrue(model.recovery.failed); XCTAssertEqual(model.entry(id)?.items.first?.phase, .planned)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("saved.json")), saved)
        let writes = await transport.recordedWrites(); XCTAssertTrue(writes.isEmpty)
    }

    func test删除完成记录保存失败仍保留提交项并阻止后续删除() async throws {
        let root = try root(), transport = MobileChatDeletionUITransport(), (model, repo) = try await make(transport, root: root)
        let own = try await messages(repo).filter { $0.isFromCurrentUser == true }, id = try XCTUnwrap(model.createBatch(own))
        await transport.onWrite {
            let file = root.appendingPathComponent("message-deletions-v1.json")
            try? FileManager.default.moveItem(at: file, to: root.appendingPathComponent("saved.json"))
            try? FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
        await model.run(id, continuePlanned: true); await model.run(id, continuePlanned: true)
        XCTAssertTrue(model.recovery.failed); XCTAssertEqual(model.entry(id)?.items.map(\.phase), [.submitted, .planned])
        let writes = await transport.recordedWrites(); XCTAssertEqual(writes, ["9001"])
    }

    func test重复点击切账号和迟到结果只更新原批次() async throws {
        let root = try root(), transport = MobileChatDeletionUITransport(state: "chat-deletion-slow")
        let (model, repo) = try await make(transport, root: root)
        let own = try await messages(repo).filter { $0.isFromCurrentUser == true }
        let id = try XCTUnwrap(model.createBatch(own))
        let work = Task { await model.run(id, continuePlanned: true) }
        while await transport.recordedWrites().isEmpty { await Task.yield() }
        await model.run(id, continuePlanned: true); model.invalidate()
        let other = MobileChatDeletionModel(context: "account-b", repository: repo, recovery: model.recovery)
        await other.run(id, continuePlanned: true); await work.value
        XCTAssertTrue(other.entries.isEmpty); XCTAssertNil(model.errorKey)
        XCTAssertEqual(model.entry(id)?.items.map(\.phase), [.complete, .planned])
        let writes = await transport.recordedWrites(); XCTAssertEqual(writes, ["9001"])
    }

    func test同账号重绑定仍共享执行锁且不能提前恢复() async throws {
        let transport = MobileChatDeletionUITransport(state: "chat-deletion-slow"), repo = try repository(transport), owner = MobileChatModel()
        let profileID = UUID(); await owner.activate(profileID: profileID, repository: repo, context: "account-a")
        let conversation = try XCTUnwrap(owner.state.conversations.first); await owner.selectConversation(conversation)
        let model = try XCTUnwrap(owner.deletion), id = try XCTUnwrap(model.createBatch(owner.state.selectedMessages.messages.filter { $0.isFromCurrentUser == true }))
        let work = Task { await model.run(id, continuePlanned: true) }
        while await transport.recordedWrites().isEmpty { await Task.yield() }
        await owner.activate(profileID: profileID, repository: repo, context: "account-a")
        let rebound = try XCTUnwrap(owner.deletion); XCTAssertTrue(rebound.isBusy)
        await rebound.run(id, continuePlanned: true); await work.value
        XCTAssertEqual(rebound.entry(id)?.items.map(\.phase), [.complete, .planned])
        XCTAssertFalse(rebound.isBusy)
        let writes = await transport.recordedWrites(); XCTAssertEqual(writes, ["9001"])
    }

    func test删除准备期间取消仍未提交的消息均显示保留() async throws {
        let transport = MobileChatDeletionUITransport(), (model, repo) = try await make(transport, root: root())
        let own = try await messages(repo).filter { $0.isFromCurrentUser == true }
        let id = try XCTUnwrap(model.createBatch(own))
        await transport.onNextMessageRead { await MainActor.run { model.cancelRemaining(id) } }
        await model.run(id, continuePlanned: true)
        XCTAssertEqual(model.entry(id)?.items.map(\.phase), [.cancelled, .cancelled])
        let writes = await transport.recordedWrites(); XCTAssertTrue(writes.isEmpty)
    }

    func test删除准备期间切换账号保留计划项且不开始提交() async throws {
        let transport = MobileChatDeletionUITransport(), (model, repo) = try await make(transport, root: root())
        let own = try await messages(repo).filter { $0.isFromCurrentUser == true }
        let id = try XCTUnwrap(model.createBatch(own))
        await transport.onNextMessageRead { await MainActor.run { model.invalidate() } }
        await model.run(id, continuePlanned: true)
        XCTAssertEqual(model.entry(id)?.items.map(\.phase), [.planned, .planned])
        let writes = await transport.recordedWrites(); XCTAssertTrue(writes.isEmpty)
    }

    func test取消正在执行批次只阻止下一条() async throws {
        let transport = MobileChatDeletionUITransport(state: "chat-deletion-slow"), (model, repo) = try await make(transport, root: root())
        let own = try await messages(repo).filter { $0.isFromCurrentUser == true }
        let id = try XCTUnwrap(model.createBatch(own))
        let work = Task { await model.run(id, continuePlanned: true) }
        while await transport.recordedWrites().isEmpty { await Task.yield() }
        model.cancelRemaining(id); await work.value
        XCTAssertEqual(model.entry(id)?.items.map(\.phase), [.complete, .cancelled])
        let writes = await transport.recordedWrites(); XCTAssertEqual(writes, ["9001"])
    }

    func test能力撤回允许只读恢复但不继续新删除() async throws {
        let transport = MobileChatDeletionUITransport(state: "chat-deletion-partial"), (model, repo) = try await make(transport, root: root())
        let own = try await messages(repo).filter { $0.isFromCurrentUser == true }
        let id = try XCTUnwrap(model.createBatch(own))
        await model.run(id, continuePlanned: true); await transport.resolve()
        model.updateAvailability(.init(status: .unavailable))
        await model.run(id, continuePlanned: false); await model.run(id, continuePlanned: true)
        XCTAssertEqual(model.entry(id)?.items.map(\.phase), [.complete, .planned])
        let writes = await transport.recordedWrites(); XCTAssertEqual(writes, ["9001"])
    }

    func test恢复失去会话访问不能清除提交项或解除原消息保护() async throws {
        let transport = MobileChatDeletionUITransport(state: "chat-deletion-unknown"), (model, repo) = try await make(transport, root: root())
        let source = try await source(repo), id = try XCTUnwrap(model.createBatch([source]))
        await model.run(id, continuePlanned: true); await transport.setAccess(visible: false)
        await model.run(id, continuePlanned: false)
        XCTAssertEqual(model.entry(id)?.items.first?.phase, .submitted); XCTAssertFalse(model.canSelect(source))
    }

    func test准备删除保护编辑转发提醒公告关闭与线程回复() async throws {
        let transport = MobileChatDeletionUITransport(), repo = try repository(transport), owner = MobileChatModel()
        await owner.activate(profileID: UUID(), repository: repo, context: "account-a")
        let conversation = try XCTUnwrap(owner.state.conversations.first); await owner.selectConversation(conversation)
        let source = try XCTUnwrap(owner.state.selectedMessages.messages.first), deletion = try XCTUnwrap(owner.deletion)
        await owner.interaction?.loadPolicy()
        await owner.interaction?.open(source)
        XCTAssertTrue(owner.interaction?.canSendReply("合成回复") == true)
        XCTAssertTrue(owner.interaction?.canEdit(source) == true); XCTAssertTrue(owner.forwarding?.canSelect(source) == true)
        let id = try XCTUnwrap(deletion.createBatch([source]))
        XCTAssertFalse(owner.canDeleteMessage(source)); XCTAssertFalse(owner.interaction?.canEdit(source) == true)
        XCTAssertFalse(owner.forwarding?.canSelect(source) == true); XCTAssertFalse(owner.management?.canPin(source) == true)
        XCTAssertFalse(owner.timedActions?.canSetReminder(source) == true); XCTAssertFalse(owner.management?.canClose(conversation) == true)
        XCTAssertFalse(owner.interaction?.canSendReply("合成回复") == true)
        XCTAssertTrue(owner.hasUnfinishedChatWrite(in: conversation.id))
        deletion.cancelRemaining(id); XCTAssertTrue(owner.canDeleteMessage(source))
    }

    func test损坏删除记录阻止危险动作且保留原文件() async throws {
        let root = try root(), file = root.appendingPathComponent("message-deletions-v1.json")
        try Data("broken".utf8).write(to: file)
        let transport = MobileChatDeletionUITransport(), repo = try repository(transport), owner = MobileChatModel(interactionRecoveryRoot: root)
        await owner.activate(profileID: UUID(), repository: repo, context: "account-a")
        let conversation = try XCTUnwrap(owner.state.conversations.first); await owner.selectConversation(conversation)
        let source = try XCTUnwrap(owner.state.selectedMessages.messages.first)
        XCTAssertFalse(owner.canDeleteMessage(source)); XCTAssertFalse(owner.forwarding?.canSelect(source) == true)
        XCTAssertFalse(owner.management?.canClose(conversation) == true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken")
    }

    private func source(_ repo: any ChatRepository) async throws -> ChatMessage {
        let values = try await messages(repo)
        return try XCTUnwrap(values.first)
    }
    private func messages(_ repo: any ChatRepository) async throws -> [ChatMessage] {
        try await repo.listMessages(conversationID: "27", before: nil, limit: 50).messages
    }
    private func make(_ transport: MobileChatDeletionUITransport, root: URL) async throws -> (MobileChatDeletionModel, any ChatRepository) {
        let repo = try repository(transport)
        _ = try await repo.listConversations()
        let model = MobileChatDeletionModel(context: "account-a", repository: repo, recovery: MobileChatDeletionStore(root: root))
        model.updateAvailability(await repo.availability()); return (model, repo)
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ChatDeletionTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func repository(_ transport: MobileChatDeletionUITransport) throws -> MobileReadOnlyChatRepository {
        let profile = try NasProfile(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
        let versions = [DsmAPIName.chatChannel: 5, DsmAPIName.chatUser: 1, DsmAPIName.chatPost: 8, DsmAPIName.chatAdminSetting: 3,
                        DsmAPIName.chatPostReminder: 1, DsmAPIName.chatPostVote: 1]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version, verified: false))
        }))
        return MobileReadOnlyChatRepository(base: try DsmChatRepository(profile: profile, capabilities: capabilities,
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport))
    }
}

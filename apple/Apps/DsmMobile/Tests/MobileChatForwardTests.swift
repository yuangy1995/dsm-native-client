import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatForwardTests: XCTestCase {
    func test他人附件消息按描述回读转发并不保存附件名() async throws {
        let root = try root(), transport = MobileChatForwardUITransport(state: "chat-forward-attachment")
        let (model, repository) = try await make(transport, root: root)
        let values = try await repository.listMessages(conversationID: "27", before: nil, limit: 50).messages
        let source = try XCTUnwrap(values.first { $0.id == "9002" })
        XCTAssertEqual(source.attachments.first?.fileName, "Sample.pdf"); XCTAssertEqual(source.isFromCurrentUser, false)
        let id = try XCTUnwrap(model.createBatch(messages: [source], conversationIDs: ["28"], contactIDs: []))
        await model.run(id, continuePlanned: true)
        XCTAssertEqual(model.entry(id)?.items.first?.phase, .complete)
        let data = try String(contentsOf: root.appendingPathComponent("forwarding-v1.json"), encoding: .utf8)
        XCTAssertFalse(data.contains("Sample.pdf"))
        let writes = await transport.recordedWrites(); XCTAssertEqual(writes.map(\.0), ["9002"])
    }

    func test多条消息按时间转发到多个会话且每项回执落盘() async throws {
        let root = try root(), transport = MobileChatForwardUITransport()
        let (model, repository) = try await make(transport, root: root)
        let messages = try await repository.listMessages(conversationID: "27", before: nil, limit: 50).messages
        let id = try XCTUnwrap(model.createBatch(messages: messages.reversed(), conversationIDs: ["28", "30"], contactIDs: []))
        await model.run(id, continuePlanned: true)
        let stored = try XCTUnwrap(MobileChatForwardStore(root: root).entries.first)
        XCTAssertFalse(stored.hasUnfinished); XCTAssertEqual(stored.items.map(\.phase), [.complete, .complete])
        XCTAssertTrue(stored.items.allSatisfy { $0.receipt?.isComplete == true })
        let writes = await transport.recordedWrites()
        XCTAssertEqual(writes.map(\.0), ["9001", "9002"]); XCTAssertTrue(writes.allSatisfy { $0.1 == [28, 30] })
        let data = try String(contentsOf: root.appendingPathComponent("forwarding-v1.json"), encoding: .utf8)
        XCTAssertFalse(data.contains("Sample message")); XCTAssertFalse(data.contains("Sample author"))
    }

    func test新联系人完成单聊后与已有会话一起转发() async throws {
        let transport = MobileChatForwardUITransport(), (model, repo) = try await make(transport, root: root())
        XCTAssertEqual(model.contacts.map(\.id), ["2"])
        let source = try await source(repo)
        let id = try XCTUnwrap(model.createBatch(messages: [source], conversationIDs: ["28"], contactIDs: ["2"]))
        await model.run(id, continuePlanned: true)
        let entry = try XCTUnwrap(model.entry(id))
        XCTAssertFalse(entry.hasUnfinished); XCTAssertEqual(entry.targetIDs, ["28", "29"])
        let directWrites = await transport.recordedDirectWrites(), writes = await transport.recordedWrites()
        XCTAssertEqual(directWrites, 1); XCTAssertEqual(writes.first?.1, [28, 29])
    }

    func test新联系人未知后重启只读恢复且明确继续才转发() async throws {
        let root = try root(), transport = MobileChatForwardUITransport(state: "chat-forward-contact-unknown")
        let (model, repo) = try await make(transport, root: root)
        let source = try await source(repo)
        let id = try XCTUnwrap(model.createBatch(messages: [source], conversationIDs: [], contactIDs: ["2"]))
        await model.run(id, continuePlanned: true)
        XCTAssertEqual(model.entry(id)?.destinations.first?.phase, .submitted)
        XCTAssertEqual(model.entry(id)?.items.first?.phase, .planned)
        let initialWrites = await transport.recordedWrites(); XCTAssertTrue(initialWrites.isEmpty)
        let restoredTransport = MobileChatForwardUITransport(state: "chat-forward-contact-restored")
        let (restored, _) = try await make(restoredTransport, root: root)
        await restored.run(id, continuePlanned: false)
        XCTAssertEqual(restored.entry(id)?.destinations.first?.phase, .complete)
        XCTAssertEqual(restored.entry(id)?.items.first?.phase, .planned)
        let recoveredWrites = await restoredTransport.recordedWrites(); XCTAssertTrue(recoveredWrites.isEmpty)
        await restored.run(id, continuePlanned: true)
        XCTAssertEqual(restored.entry(id)?.items.first?.phase, .complete)
        let directWrites = await restoredTransport.recordedDirectWrites(); XCTAssertEqual(directWrites, 0)
    }

    func test部分接收人完成后重启仅补查询且不自动发下一条() async throws {
        let root = try root(), transport = MobileChatForwardUITransport(state: "chat-forward-partial")
        let (model, repo) = try await make(transport, root: root)
        let sources = try await repo.listMessages(conversationID: "27", before: nil, limit: 50).messages
        let id = try XCTUnwrap(model.createBatch(messages: sources, conversationIDs: ["28", "30"], contactIDs: []))
        await model.run(id, continuePlanned: true)
        let pending = try XCTUnwrap(model.entry(id))
        XCTAssertEqual(pending.items.map(\.phase), [.submitted, .planned])
        XCTAssertNotNil(pending.items[0].receipt?.targets[0].confirmedMessageID)
        XCTAssertNil(pending.items[0].receipt?.targets[1].confirmedMessageID)
        let next = MobileChatForwardUITransport(receipts: pending.items.compactMap(\.receipt))
        let (restored, _) = try await make(next, root: root)
        await restored.run(id, continuePlanned: false)
        XCTAssertEqual(restored.entry(id)?.items.map(\.phase), [.complete, .planned])
        let recoveryWrites = await next.recordedWrites(); XCTAssertTrue(recoveryWrites.isEmpty)
        await restored.run(id, continuePlanned: true)
        XCTAssertEqual(restored.entry(id)?.items.map(\.phase), [.complete, .complete])
        let finalWrites = await next.recordedWrites(); XCTAssertEqual(finalWrites.map(\.0), ["9002"])
    }

    func test丢回执后重启不认领相同内容不重发且允许取消未开始项() async throws {
        let root = try root(), transport = MobileChatForwardUITransport(state: "chat-forward-unknown")
        let (model, repo) = try await make(transport, root: root)
        let sources = try await repo.listMessages(conversationID: "27", before: nil, limit: 50).messages
        let id = try XCTUnwrap(model.createBatch(messages: sources, conversationIDs: ["28"], contactIDs: []))
        await model.run(id, continuePlanned: true)
        let receipts = try XCTUnwrap(model.entry(id)).items.compactMap(\.receipt)
        XCTAssertEqual(receipts.first?.acknowledged, false)
        let next = MobileChatForwardUITransport(receipts: receipts)
        let (restored, _) = try await make(next, root: root)
        await restored.run(id, continuePlanned: false); await restored.run(id, continuePlanned: true)
        XCTAssertEqual(restored.entry(id)?.items.map(\.phase), [.submitted, .planned])
        restored.cancelRemaining(id)
        XCTAssertEqual(restored.entry(id)?.items.map(\.phase), [.submitted, .cancelled])
        restored.remove(id); XCTAssertNotNil(restored.entry(id))
        XCTAssertFalse(restored.canSelect(sources[0])); XCTAssertTrue(restored.canSelect(sources[1]))
        let writes = await next.recordedWrites(); XCTAssertTrue(writes.isEmpty)
    }

    func test明确拒绝结束原项并允许新身份重新选择() async throws {
        let transport = MobileChatForwardUITransport(state: "chat-forward-denied"), (model, repo) = try await make(transport, root: root())
        let source = try await source(repo)
        let id = try XCTUnwrap(model.createBatch(messages: [source], conversationIDs: ["28"], contactIDs: []))
        await model.run(id, continuePlanned: true)
        XCTAssertEqual(model.entry(id)?.items.first?.phase, .failed); XCTAssertTrue(model.canSelect(source))
        let next = try XCTUnwrap(model.createBatch(messages: [source], conversationIDs: ["28"], contactIDs: []))
        XCTAssertNotEqual(next, id)
        XCTAssertNotEqual(model.entry(id)?.items.first?.id, model.entry(next)?.items.first?.id)
    }

    func test重启后尚未发送的原文已改变则零写入() async throws {
        let root = try root(), transport = MobileChatForwardUITransport(), (model, repo) = try await make(transport, root: root)
        let source = try await source(repo)
        let id = try XCTUnwrap(model.createBatch(messages: [source], conversationIDs: ["28"], contactIDs: []))
        await transport.changeSource()
        let (restored, _) = try await make(transport, root: root)
        await restored.run(id, continuePlanned: true)
        XCTAssertEqual(restored.entry(id)?.items.first?.phase, .failed)
        let writes = await transport.recordedWrites(); XCTAssertTrue(writes.isEmpty)
    }

    func test保存失败不能发出转发请求() async throws {
        let root = try root(), transport = MobileChatForwardUITransport(), (model, repo) = try await make(transport, root: root)
        let source = try await source(repo)
        let id = try XCTUnwrap(model.createBatch(messages: [source], conversationIDs: ["28"], contactIDs: []))
        try FileManager.default.removeItem(at: root); try Data("occupied".utf8).write(to: root)
        await model.run(id, continuePlanned: true)
        XCTAssertTrue(model.recovery.failed); XCTAssertEqual(model.entry(id)?.items.first?.phase, .planned)
        let writes = await transport.recordedWrites(); XCTAssertTrue(writes.isEmpty)
    }

    func test成功回执保存失败保留原写前记录并阻止重发() async throws {
        let root = try root(), transport = MobileChatForwardUITransport(), (model, repo) = try await make(transport, root: root)
        let source = try await source(repo)
        let id = try XCTUnwrap(model.createBatch(messages: [source], conversationIDs: ["28"], contactIDs: []))
        await transport.onWrite {
            let file = root.appendingPathComponent("forwarding-v1.json")
            try? FileManager.default.moveItem(at: file, to: root.appendingPathComponent("saved.json"))
            try? FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
        await model.run(id, continuePlanned: true); await model.run(id, continuePlanned: true)
        XCTAssertTrue(model.recovery.failed); XCTAssertEqual(model.entry(id)?.items.first?.receipt?.acknowledged, false)
        let writes = await transport.recordedWrites(); XCTAssertEqual(writes.count, 1)
    }

    func test重复点击和切换账号后只保存原上下文结果() async throws {
        let root = try root(), transport = MobileChatForwardUITransport(state: "chat-forward-slow")
        let (model, repo) = try await make(transport, root: root)
        let sources = try await repo.listMessages(conversationID: "27", before: nil, limit: 50).messages
        let id = try XCTUnwrap(model.createBatch(messages: sources, conversationIDs: ["28"], contactIDs: []))
        let first = Task { await model.run(id, continuePlanned: true) }
        while await transport.recordedWrites().isEmpty { await Task.yield() }
        await model.run(id, continuePlanned: true)
        model.invalidate()
        let other = MobileChatForwardModel(context: "other-account", repository: repo, recovery: model.recovery)
        await other.run(id, continuePlanned: true)
        await first.value
        XCTAssertTrue(other.entries.isEmpty); XCTAssertNil(model.errorKey)
        XCTAssertEqual(model.entry(id)?.items.map(\.phase), [.complete, .planned])
        let writes = await transport.recordedWrites(); XCTAssertEqual(writes.count, 1)
    }

    func test准备批次占用来源及目标且与独立单聊创建互斥() async throws {
        let transport = MobileChatForwardUITransport(), repo = try repository(transport), owner = MobileChatModel()
        let profileID = UUID(); await owner.activate(profileID: profileID, repository: repo, context: "account-a")
        let conversation = try XCTUnwrap(owner.state.conversations.first { $0.id == "27" })
        await owner.selectConversation(conversation)
        let forward = try XCTUnwrap(owner.forwarding); await forward.loadTargets(sourceConversationID: "27")
        let source = try XCTUnwrap(owner.state.selectedMessages.messages.first)
        XCTAssertTrue(forward.canSelect(source))
        let id = try XCTUnwrap(forward.createBatch(messages: [source], conversationIDs: ["28"], contactIDs: ["2"]))
        XCTAssertFalse(owner.canDeleteMessage(source)); XCTAssertFalse(owner.interaction?.canEdit(source) == true)
        XCTAssertTrue(owner.hasUnfinishedChatWrite(in: "27")); XCTAssertTrue(owner.hasUnfinishedChatWrite(in: "28"))
        XCTAssertFalse(owner.conversationCreator?.canCreateDirect == true)
        let outcome = await owner.conversationCreator?.openDirectConversation(userID: "2"); XCTAssertNil(outcome)
        let creates = await transport.recordedDirectWrites(); XCTAssertEqual(creates, 0)
        forward.cancelRemaining(id)
        XCTAssertTrue(owner.conversationCreator?.canCreateDirect == true)
    }

    func test能力撤回后仍可刷新已有回执且不发送计划项() async throws {
        let transport = MobileChatForwardUITransport(state: "chat-forward-partial"), (model, repo) = try await make(transport, root: root())
        let sources = try await repo.listMessages(conversationID: "27", before: nil, limit: 50).messages
        let id = try XCTUnwrap(model.createBatch(messages: sources, conversationIDs: ["28", "30"], contactIDs: []))
        await model.run(id, continuePlanned: true)
        model.updateAvailability(.init(status: .unavailable))
        await transport.resolvePartial(); await model.run(id, continuePlanned: false); await model.run(id, continuePlanned: true)
        XCTAssertEqual(model.entry(id)?.items.map(\.phase), [.complete, .planned])
        let writes = await transport.recordedWrites(); XCTAssertEqual(writes.count, 1)
    }

    func test转发过程中取消只结束当前消息而不发送剩余项() async throws {
        let transport = MobileChatForwardUITransport(state: "chat-forward-slow"), (model, repo) = try await make(transport, root: root())
        let sources = try await repo.listMessages(conversationID: "27", before: nil, limit: 50).messages
        let id = try XCTUnwrap(model.createBatch(messages: sources, conversationIDs: ["28"], contactIDs: []))
        let task = Task { await model.run(id, continuePlanned: true) }
        while await transport.recordedWrites().isEmpty { await Task.yield() }
        model.cancelRemaining(id)
        await task.value
        XCTAssertEqual(model.entry(id)?.items.map(\.phase), [.complete, .cancelled])
        let writes = await transport.recordedWrites(); XCTAssertEqual(writes.count, 1)
    }

    func test恢复存储损坏时其他创建入口不能绕过未知单聊() async throws {
        for file in ["forwarding-v1.json", "conversation-creation-v1.json"] {
            let root = try root(); try Data("broken".utf8).write(to: root.appendingPathComponent(file))
            let transport = MobileChatForwardUITransport(), repo = try repository(transport)
            let owner = MobileChatModel(interactionRecoveryRoot: root)
            await owner.activate(profileID: UUID(), repository: repo, context: "account-a")
            let forwarding = try XCTUnwrap(owner.forwarding)
            await forwarding.loadTargets(sourceConversationID: "27")
            XCTAssertFalse(forwarding.canSelectNewContact)
            if file == "forwarding-v1.json" {
                XCTAssertFalse(owner.conversationCreator?.canCreateDirect == true)
                let outcome = await owner.conversationCreator?.openDirectConversation(userID: "2"); XCTAssertNil(outcome)
                XCTAssertTrue(owner.hasUnfinishedChatWrite(in: "27"))
            }
            let writes = await transport.recordedDirectWrites(); XCTAssertEqual(writes, 0)
        }
    }

    private func source(_ repo: any ChatRepository) async throws -> ChatMessage {
        let value = try await repo.message(conversationID: "27", messageID: "9001", threadID: "0")
        return try XCTUnwrap(value)
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ChatForwardTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func make(_ transport: MobileChatForwardUITransport, root: URL) async throws -> (MobileChatForwardModel, any ChatRepository) {
        let repo = try repository(transport); _ = try await repo.listConversations()
        let model = MobileChatForwardModel(context: "account-a", repository: repo, recovery: MobileChatForwardStore(root: root))
        model.updateAvailability(await repo.availability()); await model.loadTargets(sourceConversationID: "27")
        return (model, repo)
    }
    private func repository(_ transport: MobileChatForwardUITransport) throws -> MobileReadOnlyChatRepository {
        let profile = try NasProfile(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
        let versions = [DsmAPIName.chatChannel: 5, DsmAPIName.chatUser: 1, DsmAPIName.chatPost: 8, DsmAPIName.chatChannelAnonymous: 2, DsmAPIName.chatAdminSetting: 3]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version, verified: false))
        }))
        return MobileReadOnlyChatRepository(base: try DsmChatRepository(profile: profile, capabilities: capabilities,
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport))
    }
}

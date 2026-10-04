import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatPollTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatPollTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func repository(_ transport: MobileChatPollUITransport, postVersion: Int = 8) throws -> MobileReadOnlyChatRepository {
        let profile = try NasProfile(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
        let versions = [DsmAPIName.chatChannel: 2, DsmAPIName.chatUser: 1, DsmAPIName.chatPost: postVersion, DsmAPIName.chatPostVote: 1]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version, verified: false))
        }))
        return MobileReadOnlyChatRepository(base: try DsmChatRepository(profile: profile, capabilities: capabilities,
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport))
    }
    private func make(_ transport: MobileChatPollUITransport, root: URL? = nil, context: String = "fixture-context") async throws -> MobileChatPollModel {
        let repository = try repository(transport)
        let model = MobileChatPollModel(context: context, repository: repository, recovery: MobileChatPollStore(root: try root ?? directory()))
        model.updateAvailability(await repository.availability())
        return model
    }
    private var conversation: ChatConversation { ChatConversation(id: "27", kind: .group, title: "Sample chat", memberIDs: ["1", "2"]) }
    private var seed: ChatMessage { ChatMessage(id: "9300", conversationID: "27", senderID: "1", sentAt: .now, text: "Sample poll") }
    private func create(_ model: MobileChatPollModel, question: String = "Lunch?") async -> Bool {
        await model.create(in: conversation, question: question, options: ["Pasta", "Soup"], multiple: false, anonymous: false)
    }

    func test创建使用对象选项和设置并显示本人回读结果() async throws {
        let transport = MobileChatPollUITransport(); let model = try await make(transport)
        let success = await model.create(in: conversation, question: " Lunch? ", options: [" Pasta ", "Soup"], multiple: true, anonymous: true)
        XCTAssertTrue(success); XCTAssertTrue(model.pending.isEmpty)
        let value = try XCTUnwrap(model.lastCreatedMessage)
        XCTAssertEqual(value.id, "9400"); XCTAssertEqual(value.poll?.question, "Lunch?")
        XCTAssertEqual(value.poll?.options.map(\.text), ["Pasta", "Soup"])
        XCTAssertEqual(value.poll?.allowsMultipleSelection, true); XCTAssertEqual(value.poll?.isAnonymous, true)
        XCTAssertEqual(value.isFromCurrentUser, true)
        let counts = await transport.counts(); XCTAssertEqual(counts.creates, 1)
    }

    func test创建重复点击只发送一次() async throws {
        let transport = MobileChatPollUITransport(state: "chat-poll-create-slow"); let model = try await make(transport)
        let first = Task { await create(model) }
        while await transport.counts().creates == 0 { await Task.yield() }
        let second = await create(model)
        XCTAssertFalse(second); let firstResult = await first.value; XCTAssertTrue(firstResult)
        let counts = await transport.counts(); XCTAssertEqual(counts.creates, 1)
    }

    func test非法选项在写前拒绝且没有恢复记录() async throws {
        let transport = MobileChatPollUITransport(); let model = try await make(transport)
        for options in [["One"], ["One", "one"], ["One", ""], (1...11).map(String.init)] {
            let result = await model.create(in: conversation, question: "Lunch?", options: options, multiple: false, anonymous: false)
            XCTAssertFalse(result); XCTAssertEqual(model.errorKey, "mobile.chat.poll.invalid")
        }
        XCTAssertTrue(model.pending.isEmpty); let counts = await transport.counts(); XCTAssertEqual(counts.creates, 0)
    }

    func test刷新发现会话加密或失去访问权时零写入() async throws {
        for state in ["chat-poll-encrypted", "chat-poll-no-access"] {
            let transport = MobileChatPollUITransport(state: state); let model = try await make(transport)
            let success = await create(model); XCTAssertFalse(success); XCTAssertTrue(model.pending.isEmpty)
            let counts = await transport.counts(); XCTAssertEqual(counts.creates, 0)
        }
    }

    func test创建回执先落盘且重启只读恢复不保存正文() async throws {
        let root = try directory(); let transport = MobileChatPollUITransport(state: "chat-poll-create-read-failure")
        let model = try await make(transport, root: root)
        let success = await create(model); XCTAssertFalse(success)
        XCTAssertEqual(model.pending.first?.messageID, "9400"); XCTAssertFalse(model.canCreate(in: conversation))
        let json = try String(contentsOf: root.appendingPathComponent("polls-v1.json"), encoding: .utf8)
        for value in ["Lunch?", "Pasta", "Soup", "synthetic", "voters", "sid"] { XCTAssertFalse(json.contains(value)) }
        model.invalidate(); await transport.setReadFailures(false)
        let restored = try await make(transport, root: root); await restored.recover()
        XCTAssertTrue(restored.pending.isEmpty); XCTAssertTrue(restored.canCreate(in: conversation))
        let counts = await transport.counts(); XCTAssertEqual(counts.creates, 1)
    }

    func test缺少创建回执不认领相同投票且重启不重发() async throws {
        let root = try directory(); let transport = MobileChatPollUITransport(state: "chat-poll-create-unknown")
        let model = try await make(transport, root: root)
        let first = await create(model); XCTAssertFalse(first); XCTAssertNil(model.pending.first?.messageID)
        model.invalidate()
        let restored = try await make(transport, root: root); await restored.recover()
        let second = await create(restored, question: "Another question")
        XCTAssertFalse(second); XCTAssertEqual(restored.pending.count, 1)
        let counts = await transport.counts(); XCTAssertEqual(counts.creates, 1)
    }

    func test恢复不能用他人的相同投票认领创建结果() async throws {
        let root = try directory(); let transport = MobileChatPollUITransport(state: "chat-poll-wrong-author")
        let model = try await make(transport, root: root); let result = await create(model)
        XCTAssertFalse(result); model.invalidate()
        let restored = try await make(transport, root: root); await restored.recover()
        XCTAssertEqual(restored.pending.count, 1); XCTAssertFalse(restored.canCreate(in: conversation))
        let counts = await transport.counts(); XCTAssertEqual(counts.creates, 1)
    }

    func test明确拒绝允许修改后重试而不遗留未知记录() async throws {
        let transport = MobileChatPollUITransport(state: "chat-poll-create-denied"); let model = try await make(transport)
        let result = await create(model); XCTAssertFalse(result)
        XCTAssertTrue(model.pending.isEmpty); XCTAssertTrue(model.canCreate(in: conversation))
        XCTAssertEqual(model.errorKey, "mobile.chat.poll.create-failed")
    }

    func test落盘失败不创建以及损坏文件保持原样() async throws {
        let root = try directory(); let record = root.appendingPathComponent("polls-v1.json")
        try Data("broken".utf8).write(to: record)
        let transport = MobileChatPollUITransport(); let model = try await make(transport, root: root)
        let result = await create(model); XCTAssertFalse(result); XCTAssertTrue(model.recovery.failed)
        XCTAssertEqual(try String(contentsOf: record, encoding: .utf8), "broken")
        let parent = try directory(); let file = parent.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let failed = try await make(transport, root: file); let failedResult = await create(failed)
        XCTAssertFalse(failedResult); XCTAssertTrue(failed.recovery.failed)
        let counts = await transport.counts(); XCTAssertEqual(counts.creates, 0)
    }

    func test创建回执无法保存时不误报成功也不重复发送() async throws {
        let root = try directory()
        let transport = MobileChatPollUITransport(afterCreate: {
            try FileManager.default.removeItem(at: root)
            try Data().write(to: root)
        })
        let model = try await make(transport, root: root); let result = await create(model)
        XCTAssertFalse(result); XCTAssertTrue(model.recovery.failed); XCTAssertNil(model.lastCreatedMessage)
        let retry = await create(model); XCTAssertFalse(retry)
        let counts = await transport.counts(); XCTAssertEqual(counts.creates, 1)
    }

    func test创建迟到不能污染新账号且旧记录可以安全结束() async throws {
        let transport = MobileChatPollUITransport(state: "chat-poll-create-slow"); let model = try await make(transport)
        let work = Task { await create(model) }
        while await transport.counts().creates == 0 { await Task.yield() }
        model.invalidate(); let result = await work.value
        XCTAssertFalse(result); XCTAssertNil(model.lastCreatedMessage); XCTAssertTrue(model.pending.isEmpty)
    }

    func test其他账号不读取或解除原账号未结束操作() async throws {
        let root = try directory(); let transport = MobileChatPollUITransport(state: "chat-poll-create-read-failure")
        let model = try await make(transport, root: root); _ = await create(model); model.invalidate()
        let otherTransport = MobileChatPollUITransport(); let other = try await make(otherTransport, root: root, context: "other-context")
        await other.recover(); XCTAssertTrue(other.pending.isEmpty); XCTAssertEqual(other.recovery.entries.count, 1)
        let counts = await otherTransport.counts(); XCTAssertEqual(counts.reads, 0); XCTAssertTrue(other.canCreate(in: conversation))
    }

    func test只读详情从选项接口读取当前选择并提交单票() async throws {
        let transport = MobileChatPollUITransport(); let model = try await make(transport)
        await model.open(seed); let original = try XCTUnwrap(model.message)
        XCTAssertTrue(model.canVote(original, choices: ["choice-0"]))
        XCTAssertFalse(model.canVote(original, choices: ["choice-0", "choice-1"]))
        let result = await model.vote(original, choices: ["choice-0"]); XCTAssertTrue(result)
        XCTAssertEqual(model.message?.poll?.options.first?.voteCount, 1)
        XCTAssertEqual(model.message?.poll?.options.first?.isSelectedByCurrentUser, true)
        XCTAssertFalse(model.canVote(try XCTUnwrap(model.message), choices: ["choice-0"]))
        await model.open(seed)
        XCTAssertEqual(model.message?.poll?.options.first?.isSelectedByCurrentUser, true)
        let counts = await transport.counts(); XCTAssertEqual(counts.votes, 1); XCTAssertEqual(counts.creates, 0)
    }

    func test多选投票与匿名投票保留结果及当前选择() async throws {
        for state in ["chat-poll-multiple", "chat-poll-anonymous"] {
            let transport = MobileChatPollUITransport(state: state); let model = try await make(transport)
            await model.open(seed); let original = try XCTUnwrap(model.message)
            let choices: Set<String> = state == "chat-poll-multiple" ? ["choice-0", "choice-1"] : ["choice-1"]
            let result = await model.vote(original, choices: choices); XCTAssertTrue(result)
            XCTAssertEqual(Set(model.message?.poll?.options.filter(\.isSelectedByCurrentUser).map(\.id) ?? []), choices)
        }
    }

    func test投票结果中断跨重启只读恢复而不再提交() async throws {
        let root = try directory(); let transport = MobileChatPollUITransport(state: "chat-poll-vote-unknown")
        let model = try await make(transport, root: root); await model.open(seed)
        let original = try XCTUnwrap(model.message)
        let result = await model.vote(original, choices: ["choice-1"]); XCTAssertFalse(result)
        XCTAssertFalse(model.canVote(original, choices: ["choice-0"])); XCTAssertEqual(model.pending.count, 1)
        model.invalidate(); await transport.setReadFailures(false)
        let restored = try await make(transport, root: root); await restored.recover(); await restored.open(seed)
        XCTAssertTrue(restored.pending.isEmpty)
        XCTAssertEqual(restored.message?.poll?.options.last?.isSelectedByCurrentUser, true)
        let counts = await transport.counts(); XCTAssertEqual(counts.votes, 1)
    }

    func test投票重复点击和关闭后迟到不恢复旧详情() async throws {
        let transport = MobileChatPollUITransport(state: "chat-poll-vote-slow"); let model = try await make(transport)
        await model.open(seed); let original = try XCTUnwrap(model.message)
        let work = Task { await model.vote(original, choices: ["choice-0"]) }
        while await transport.counts().votes == 0 { await Task.yield() }
        let duplicate = await model.vote(original, choices: ["choice-1"]); XCTAssertFalse(duplicate)
        model.close(); let result = await work.value; XCTAssertTrue(result)
        XCTAssertNil(model.message); XCTAssertTrue(model.pending.isEmpty)
        let counts = await transport.counts(); XCTAssertEqual(counts.votes, 1)
    }

    func test已关闭投票及无效选项均为零写入() async throws {
        for state in ["chat-poll-closed", "chat-poll-content"] {
            let transport = MobileChatPollUITransport(state: state); let model = try await make(transport)
            await model.open(seed); let original = try XCTUnwrap(model.message)
            let result = await model.vote(original, choices: state == "chat-poll-closed" ? ["choice-0"] : ["not-an-option"])
            XCTAssertFalse(result); let counts = await transport.counts(); XCTAssertEqual(counts.votes, 0)
        }
    }

    func test投票明确拒绝保留原选择且允许刷新后重试() async throws {
        let transport = MobileChatPollUITransport(state: "chat-poll-vote-denied"); let model = try await make(transport)
        await model.open(seed); let original = try XCTUnwrap(model.message)
        let result = await model.vote(original, choices: ["choice-0"]); XCTAssertFalse(result)
        XCTAssertTrue(model.pending.isEmpty); XCTAssertEqual(model.message, original)
        XCTAssertTrue(model.canVote(original, choices: ["choice-1"]))
    }

    func test缺失与加载失败和重复选项响应分别处理() async throws {
        for state in ["chat-poll-load-error", "chat-poll-malformed"] {
            let model = try await make(MobileChatPollUITransport(state: state)); await model.open(seed)
            XCTAssertTrue(model.loadFailed); XCTAssertFalse(model.missing); XCTAssertNil(model.message)
        }
        let transport = MobileChatPollUITransport(); await transport.setMissing(true)
        let model = try await make(transport); await model.open(seed)
        XCTAssertTrue(model.missing); XCTAssertFalse(model.loadFailed); XCTAssertNil(model.message)
    }

    func test失去能力后旧模型和旧入口不能提交() async throws {
        let transport = MobileChatPollUITransport(); let model = try await make(transport)
        await model.open(seed); let original = try XCTUnwrap(model.message)
        model.updateAvailability(ChatAvailability(status: .unavailable))
        let created = await create(model), voted = await model.vote(original, choices: ["choice-0"])
        XCTAssertFalse(created); XCTAssertFalse(voted); XCTAssertNil(model.message)
        let counts = await transport.counts(); XCTAssertEqual(counts.creates, 0); XCTAssertEqual(counts.votes, 0)
    }
    func test同一会话恢复投票后可以主动修改选择而不被旧内存记录阻挡() async throws {
        let transport = MobileChatPollUITransport(state: "chat-poll-vote-unknown"); let model = try await make(transport)
        await model.open(seed); let original = try XCTUnwrap(model.message)
        let first = await model.vote(original, choices: ["choice-1"]); XCTAssertFalse(first)
        await transport.setReadFailures(false); await model.recover()
        XCTAssertTrue(model.pending.isEmpty)
        let recovered = try XCTUnwrap(model.message)
        XCTAssertEqual(recovered.poll?.options.last?.isSelectedByCurrentUser, true)
        let second = await model.vote(recovered, choices: ["choice-0"]); XCTAssertTrue(second)
        XCTAssertTrue(model.pending.isEmpty)
        let counts = await transport.counts(); XCTAssertEqual(counts.votes, 2)
    }

    func test已取消任务不提交创建() async throws {
        let transport = MobileChatPollUITransport(); let model = try await make(transport)
        let work = Task { await create(model) }; work.cancel()
        let result = await work.value; XCTAssertFalse(result); XCTAssertTrue(model.pending.isEmpty)
        let counts = await transport.counts(); XCTAssertEqual(counts.creates, 0)
    }

    func test提交后取消保留未知记录且不重新创建() async throws {
        let transport = MobileChatPollUITransport(state: "chat-poll-create-slow"); let model = try await make(transport)
        let work = Task { await create(model) }
        while await transport.counts().creates == 0 { await Task.yield() }
        work.cancel(); let result = await work.value; XCTAssertFalse(result)
        XCTAssertEqual(model.pending.count, 1)
        let retry = await create(model); XCTAssertFalse(retry)
        let counts = await transport.counts(); XCTAssertEqual(counts.creates, 1)
    }

    func test缺少消息读取能力不开放投票写入() async throws {
        let transport = MobileChatPollUITransport(); let repository = try repository(transport, postVersion: 4)
        let value = await repository.availability()
        XCTAssertFalse(value.supportedFeatures.contains(.poll)); XCTAssertFalse(value.supportedFeatures.contains(.pollVoting))
        let draft = try ChatPollDraft(conversationID: "27", question: "Lunch?", options: ["Pasta", "Soup"], allowsMultipleSelection: false, isAnonymous: false)
        do { _ = try await repository.createPoll(draft); XCTFail("缺少读取能力不得创建") }
        catch { XCTAssertEqual(error as? MobileReadOnlyChatRepositoryError, .operationUnavailable) }
        let counts = await transport.counts(); XCTAssertEqual(counts.creates, 0)
    }

}

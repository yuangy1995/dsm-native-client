import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatGroupCreationTests: XCTestCase {
    func test完整建群只提交三个步骤并在成功后清理恢复草稿() async throws {
        let root = try root(), transport = MobileChatGroupUITransport(), creator = try await creator(root, transport)
        let result = await creator.createGroup(title: " 合成群聊 ", memberIDs: ["3", "2", "2"])
        XCTAssertEqual(result?.result.status, .confirmedSuccess); XCTAssertEqual(result?.confirmedConversation?.id, "42")
        XCTAssertTrue(creator.groupEntries.isEmpty); XCTAssertFalse(creator.requiresReview)
        XCTAssertTrue(MobileChatGroupCreationStore(root: root).entries.isEmpty)
        let counts = await transport.counts(); XCTAssertEqual(counts.create, 1); XCTAssertEqual(counts.join, 1); XCTAssertEqual(counts.invite, 1)
    }

    func test创建丢回执重启只保留原草稿刷新不认领同名群() async throws {
        let root = try root(), transport = MobileChatGroupUITransport(state: "chat-group-create-lost"), first = try await creator(root, transport)
        let result = await first.createGroup(title: "合成群聊", memberIDs: ["2", "3"])
        XCTAssertEqual(result?.result.status, .submittedButUnverified)
        let entry = try XCTUnwrap(first.groupEntry)
        XCTAssertNil(entry.receipt?.candidateConversationID); XCTAssertFalse(first.canContinueGroup)
        let restoredTransport = MobileChatGroupUITransport(restored: first.groupEntries), restored = try await creator(root, restoredTransport)
        let refreshed = await restored.refreshGroup()
        XCTAssertEqual(refreshed?.result.status, .submittedButUnverified); XCTAssertEqual(restored.groupEntry?.id, entry.id)
        restored.cancelPreparedGroup(); XCTAssertEqual(restored.groupEntries.count, 1)
        let counts = await restoredTransport.counts(); XCTAssertEqual(counts.create + counts.join + counts.invite + counts.reads, 0)
    }

    func test加入丢回执重启刷新只读而继续按钮只补邀请() async throws {
        let root = try root(), firstTransport = MobileChatGroupUITransport(state: "chat-group-join-lost"), first = try await creator(root, firstTransport)
        _ = await first.createGroup(title: "合成群聊", memberIDs: ["2", "3"])
        XCTAssertEqual(first.groupEntry?.receipt?.join, .submitted); XCTAssertFalse(first.canContinueGroup)
        let transport = MobileChatGroupUITransport(restored: first.groupEntries), restored = try await creator(root, transport)
        _ = await restored.refreshGroup()
        XCTAssertEqual(restored.groupEntry?.receipt?.join, .completed); XCTAssertTrue(restored.canContinueGroup)
        let readCounts = await transport.counts(); XCTAssertEqual(readCounts.create + readCounts.join + readCounts.invite, 0)
        let complete = await restored.continueGroup()
        XCTAssertEqual(complete?.result.status, .confirmedSuccess); XCTAssertTrue(restored.groupEntries.isEmpty)
        let counts = await transport.counts(); XCTAssertEqual(counts.create, 0); XCTAssertEqual(counts.join, 0); XCTAssertEqual(counts.invite, 1)
    }

    func test邀请丢回执重启可读取完成且撤回创建能力不阻断恢复() async throws {
        let root = try root(), firstTransport = MobileChatGroupUITransport(state: "chat-group-invite-lost"), first = try await creator(root, firstTransport)
        _ = await first.createGroup(title: "合成群聊", memberIDs: ["2", "3"])
        let transport = MobileChatGroupUITransport(restored: first.groupEntries), restored = try await creator(root, transport)
        restored.updateAvailability(.init(status: .requiresValidation))
        let result = await restored.refreshGroup()
        XCTAssertEqual(result?.result.status, .confirmedSuccess); XCTAssertTrue(restored.groupEntries.isEmpty)
        let counts = await transport.counts(); XCTAssertEqual(counts.create + counts.join + counts.invite, 0)
    }

    func test邀请明确拒绝后不会重建群且用户可继续原请求() async throws {
        let root = try root(), transport = MobileChatGroupUITransport(state: "chat-group-invite-denied"), creator = try await creator(root, transport)
        let first = await creator.createGroup(title: "合成群聊", memberIDs: ["2", "3"])
        let id = try XCTUnwrap(creator.groupEntry?.id)
        XCTAssertEqual(first?.result.status, .submittedButUnverified); XCTAssertTrue(creator.canContinueGroup)
        XCTAssertEqual(creator.groupEntry?.receipt?.invite, .rejected)
        await transport.setState("chat-group-content")
        let complete = await creator.continueGroup()
        XCTAssertEqual(complete?.clientRequestID, id); XCTAssertEqual(complete?.result.status, .confirmedSuccess)
        let counts = await transport.counts(); XCTAssertEqual(counts.create, 1); XCTAssertEqual(counts.join, 1); XCTAssertEqual(counts.invite, 2)
    }

    func test创建明确拒绝释放未创建草稿允许新请求() async throws {
        let root = try root(), transport = MobileChatGroupUITransport(state: "chat-group-create-denied"), creator = try await creator(root, transport)
        let rejected = await creator.createGroup(title: "合成群聊", memberIDs: ["2", "3"])
        XCTAssertEqual(rejected?.result.status, .permissionDenied); XCTAssertTrue(creator.groupEntries.isEmpty)
        await transport.setState("chat-group-content")
        let complete = await creator.createGroup(title: "合成群聊", memberIDs: ["2", "3"])
        XCTAssertEqual(complete?.result.status, .confirmedSuccess); XCTAssertNotEqual(rejected?.clientRequestID, complete?.clientRequestID)
    }

    func test原未完成记录不挡其他草稿但相同内容不能绕过去重() async throws {
        let root = try root(), transport = MobileChatGroupUITransport(state: "chat-group-create-lost"), creator = try await creator(root, transport)
        _ = await creator.createGroup(title: "合成群聊", memberIDs: ["2", "3"])
        let firstID = try XCTUnwrap(creator.groupEntry?.id)
        creator.startAnotherConversation(); XCTAssertFalse(creator.requiresReview)
        _ = await creator.createGroup(title: "合成群聊", memberIDs: ["3", "2"])
        XCTAssertEqual(creator.groupEntry?.id, firstID)
        creator.startAnotherConversation()
        _ = await creator.createGroup(title: "另一个合成群", memberIDs: ["2", "3"])
        XCTAssertEqual(creator.groupEntries.count, 2); XCTAssertNotEqual(creator.groupEntry?.id, firstID)
        creator.selectGroupEntry(firstID); XCTAssertEqual(creator.pendingGroupTitle, "合成群聊")
        let counts = await transport.counts(); XCTAssertEqual(counts.create, 2)
    }

    func test准备记录重启不会自动创建必须主动继续且可在提交前取消() async throws {
        let root = try root(), store = MobileChatGroupCreationStore(root: root)
        let entry = MobileChatGroupCreationStore.Entry(id: UUID(), context: "account-a", title: "合成群聊", memberIDs: ["2", "3"], createdAt: Date())
        try store.reserve(entry)
        let transport = MobileChatGroupUITransport(), creator = try await creator(root, transport)
        let read = await creator.refreshGroup(); XCTAssertNil(read)
        let before = await transport.counts(); XCTAssertEqual(before.create, 0)
        XCTAssertTrue(creator.canContinueGroup)
        let complete = await creator.continueGroup(); XCTAssertEqual(complete?.result.status, .confirmedSuccess)
        let nextStore = MobileChatGroupCreationStore(root: root)
        try nextStore.reserve(entry)
        let cancelled = try await self.creator(root, MobileChatGroupUITransport())
        cancelled.cancelPreparedGroup(); XCTAssertTrue(cancelled.groupEntries.isEmpty)
    }

    func test执行锁跨同账号模型生效且切换账号后回执仍归原账号() async throws {
        let root = try root(), store = MobileChatGroupCreationStore(root: root), transport = MobileChatGroupUITransport(state: "chat-group-paused")
        let first = try await creator(root, transport, store: store)
        let task = Task { await first.createGroup(title: "合成群聊", memberIDs: ["2", "3"]) }
        await transport.waitUntilBlocked()
        let replacementTransport = MobileChatGroupUITransport(), replacement = try await creator(root, replacementTransport, store: store)
        XCTAssertTrue(replacement.isSubmitting)
        let duplicate = await replacement.refreshGroup(); XCTAssertNil(duplicate)
        let other = try await creator(root, replacementTransport, context: "account-b", store: store)
        XCTAssertTrue(other.groupEntries.isEmpty); XCTAssertFalse(other.isSubmitting)
        first.invalidate(); await transport.release()
        let oldResult = await task.value
        XCTAssertNil(oldResult); XCTAssertNil(first.errorCategory); XCTAssertFalse(replacement.isSubmitting)
        XCTAssertEqual(first.groupEntry?.receipt?.candidateConversationID, "42")
        XCTAssertEqual(first.groupEntry?.receipt?.join, .ready); XCTAssertTrue(other.groupEntries.isEmpty)
        let counts = await transport.counts(); XCTAssertEqual(counts.create, 1); XCTAssertEqual(counts.join + counts.invite, 0)
    }

    func test同账号重绑中途保留创建回执但不自动提交下一步() async throws {
        let root = try root(), transport = MobileChatGroupUITransport(state: "chat-group-paused"), creator = try await creator(root, transport)
        let task = Task { await creator.createGroup(title: "合成群聊", memberIDs: ["2", "3"]) }
        await transport.waitUntilBlocked()
        let bound = try repository(MobileChatGroupUITransport(restored: creator.groupEntries))
        creator.rebind(repository: bound, availability: await bound.availability())
        await transport.release(); let result = await task.value
        XCTAssertNil(result); XCTAssertEqual(creator.groupEntry?.receipt?.create, .completed)
        XCTAssertEqual(creator.groupEntry?.receipt?.join, .ready)
        let counts = await transport.counts(); XCTAssertEqual(counts.join + counts.invite, 0)
    }

    func test取消已提交创建保留已返回编号且零后续步骤() async throws {
        let root = try root(), transport = MobileChatGroupUITransport(state: "chat-group-paused"), creator = try await creator(root, transport)
        let task = Task { await creator.createGroup(title: "合成群聊", memberIDs: ["2", "3"]) }
        await transport.waitUntilBlocked(); task.cancel(); await transport.release()
        let result = await task.value
        XCTAssertEqual(result?.result.status, .cancellationRequestedAfterSubmission)
        XCTAssertEqual(creator.groupEntry?.receipt?.candidateConversationID, "42")
        creator.cancelPreparedGroup(); XCTAssertEqual(creator.groupEntries.count, 1)
        let counts = await transport.counts(); XCTAssertEqual(counts.join + counts.invite, 0)
    }

    func test恢复目录不可写时在创建前停止() async throws {
        let root = try root().appendingPathComponent("occupied")
        try Data("occupied".utf8).write(to: root)
        let transport = MobileChatGroupUITransport(), creator = try await creator(root, transport)
        XCTAssertTrue(creator.storageFailed)
        let result = await creator.createGroup(title: "合成群聊", memberIDs: ["2", "3"])
        XCTAssertNil(result)
        let counts = await transport.counts(); XCTAssertEqual(counts.create + counts.join + counts.invite, 0)
    }

    func test单聊恢复优先于其他未完成群聊且不丢群草稿() async throws {
        let root = try root(), groups = MobileChatGroupCreationStore(root: root)
        try groups.reserve(.init(id: UUID(), context: "account-a", title: "合成群聊", memberIDs: ["2", "3"], createdAt: Date()))
        let direct = MobileChatConversationCreationStore(root: root)
        let entry = MobileChatConversationCreationStore.Entry(id: UUID(), context: "account-a", userID: "2", phase: .prepared)
        XCTAssertTrue(direct.reserve(entry)); XCTAssertTrue(direct.beginExecution(entry)); try direct.markSubmitted(entry); direct.endExecution(entry)
        let transport = MobileChatGroupUITransport(), creator = try await creator(root, transport)
        XCTAssertTrue(creator.requiresReview); XCTAssertFalse(creator.pendingIsGroup); XCTAssertNil(creator.groupEntry)
        XCTAssertEqual(creator.pendingDirectUserID, "2"); XCTAssertEqual(creator.groupEntries.count, 1)
        let result = await creator.openDirectConversation(userID: "2")
        XCTAssertEqual(result?.result.status, .submittedButUnverified)
        XCTAssertEqual(creator.groupEntries.count, 1)
        let counts = await transport.counts(); XCTAssertEqual(counts.create + counts.join + counts.invite, 0)
    }

    private func creator(_ root: URL, _ transport: MobileChatGroupUITransport, context: String = "account-a", store: MobileChatGroupCreationStore? = nil) async throws -> MobileChatConversationCreator {
        let repository = try repository(transport)
        return MobileChatConversationCreator(repository: repository, availability: await repository.availability(), context: context,
            recovery: MobileChatConversationCreationStore(root: root), groupRecovery: store ?? MobileChatGroupCreationStore(root: root))
    }
    private func repository(_ transport: MobileChatGroupUITransport) throws -> MobileReadOnlyChatRepository {
        let profile = try NasProfile(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
        let versions = [DsmAPIName.chatChannel: 2, DsmAPIName.chatUser: 1, DsmAPIName.chatPost: 8,
            DsmAPIName.chatChannelNamed: 1, DsmAPIName.chatChannelMember: 1, DsmAPIName.chatChannelAnonymous: 2]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version))
        }))
        return MobileReadOnlyChatRepository(base: try DsmChatRepository(profile: profile, capabilities: capabilities,
            session: .init(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport))
    }
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("ChatGroupTests-\(UUID())")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }; return value
    }
}

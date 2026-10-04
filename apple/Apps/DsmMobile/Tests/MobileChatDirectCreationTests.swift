import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatDirectCreationTests: XCTestCase {
    func test完整单聊创建通过移动包装器并清除恢复记录() async throws {
        let root = try root(), transport = MobileChatUITransport(state: "chat-direct-content")
        let creator = try await make(transport, root: root)
        await creator.loadUsers()
        XCTAssertEqual(creator.users.map(\.id), ["2"])
        let result = await creator.openDirectConversation(userID: "2")
        XCTAssertEqual(result?.result.status, .confirmedSuccess)
        XCTAssertEqual(result?.confirmedConversation?.id, "29")
        XCTAssertEqual(result?.confirmedConversation?.memberIDs, ["1", "2"])
        XCTAssertFalse(creator.requiresReview)
        XCTAssertTrue(MobileChatConversationCreationStore(root: root).entries.isEmpty)
        let writes = await transport.directWrites(); XCTAssertEqual(writes, 1)
    }

    func test真实请求丢回执后重建移动模型仅查询且不重复发起单聊() async throws {
        let root = try root(), transport = MobileChatUITransport(state: "chat-direct-unknown")
        let creator = try await make(transport, root: root)
        let unknown = await creator.openDirectConversation(userID: "2")
        XCTAssertEqual(unknown?.result.status, .submittedButUnverified)
        XCTAssertEqual(MobileChatConversationCreationStore(root: root).pending(in: "account-a")?.phase, .submitted)
        let again = await creator.openDirectConversation(userID: "2")
        XCTAssertEqual(again?.result.status, .submittedButUnverified)
        let firstWrites = await transport.directWrites(); XCTAssertEqual(firstWrites, 1)
        let restored = MobileChatUITransport(state: "chat-direct-restored")
        let recovered = try await make(restored, root: root)
        let confirmed = await recovered.openDirectConversation(userID: "2")
        XCTAssertEqual(confirmed?.result.status, .confirmedSuccess)
        XCTAssertEqual(confirmed?.confirmedConversation?.id, "29")
        XCTAssertEqual(confirmed?.clientRequestID, unknown?.clientRequestID)
        let recoveryWrites = await restored.directWrites(); XCTAssertEqual(recoveryWrites, 0)
        XCTAssertFalse(recovered.requiresReview)
    }

    func test创建前读取失败保持零写入并允许更换联系人() async throws {
        let root = try root(), transport = MobileChatUITransport(state: "chat-direct-users-error")
        let creator = try await make(transport, root: root)
        let result = await creator.openDirectConversation(userID: "2")
        XCTAssertNil(result); XCTAssertFalse(creator.requiresReview)
        XCTAssertTrue(MobileChatConversationCreationStore(root: root).entries.isEmpty)
        let writes = await transport.directWrites(); XCTAssertEqual(writes, 0)
    }

    func test单聊明确拒绝解除待办且下一次用户操作采用新身份() async throws {
        let root = try root(), transport = MobileChatUITransport(state: "chat-direct-denied")
        let creator = try await make(transport, root: root)
        let first = await creator.openDirectConversation(userID: "2")
        XCTAssertEqual(first?.result.status, .permissionDenied)
        XCTAssertEqual(creator.errorCategory, .permissionDenied)
        XCTAssertFalse(creator.requiresReview)
        let second = await creator.openDirectConversation(userID: "2")
        XCTAssertEqual(second?.result.status, .permissionDenied)
        XCTAssertNotEqual(first?.clientRequestID, second?.clientRequestID)
        let writes = await transport.directWrites(); XCTAssertEqual(writes, 2)
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ChatDirectTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func make(_ transport: MobileChatUITransport, root: URL) async throws -> MobileChatConversationCreator {
        let profile = try NasProfile(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
        let versions = [DsmAPIName.chatChannel: 2, DsmAPIName.chatUser: 1, DsmAPIName.chatPost: 8, DsmAPIName.chatChannelAnonymous: 2]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version, verified: false))
        }))
        let repository = MobileReadOnlyChatRepository(base: try DsmChatRepository(profile: profile, capabilities: capabilities,
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport))
        return MobileChatConversationCreator(repository: repository, availability: await repository.availability(),
            context: "account-a", recovery: MobileChatConversationCreationStore(root: root))
    }
}

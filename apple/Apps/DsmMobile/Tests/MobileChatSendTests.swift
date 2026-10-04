import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatSendTests: XCTestCase {
    func test普通发送真实请求成功后只保留回执并允许新的同文消息() async throws {
        let root = try root(), transport = MobileChatSendUITransport(), model = try await model(root, transport)
        let sent = await model.send(conversationID: "27", text: "  Private draft  ")
        XCTAssertTrue(sent); XCTAssertEqual(model.entries[0].phase, .complete); XCTAssertNil(model.entries[0].payload)
        XCTAssertNotNil(model.entries[0].receipt?.candidateMessageID)
        let restored = MobileChatSendStore(root: root); XCTAssertEqual(restored.entries, model.entries)
        let sentAgain = await model.send(conversationID: "27", text: "Private draft")
        XCTAssertTrue(sentAgain); XCTAssertEqual(Set(model.entries.map(\.id)).count, 2)
        let counts = await transport.counts(); XCTAssertEqual(counts.writes, 2)
    }

    func test丢回执重启后不凭同文认领且刷新零创建() async throws {
        let root = try root(), transport = MobileChatSendUITransport(state: "chat-send-lost-ack"), model = try await model(root, transport)
        let sent = await model.send(conversationID: "27", text: "Private draft")
        XCTAssertFalse(sent); XCTAssertEqual(model.entries[0].phase, .submitted); XCTAssertNil(model.entries[0].receipt?.candidateMessageID)
        let another = MobileChatSendUITransport(), restored = try await self.model(root, another)
        let result = await restored.run(model.entries[0].id, sendPrepared: true)
        XCTAssertFalse(result); XCTAssertFalse(restored.canSend(conversationID: "27", text: " Private draft "))
        XCTAssertTrue(restored.canSend(conversationID: "27", text: "Different draft"))
        let counts = await another.counts(); XCTAssertEqual(counts.writes, 0); XCTAssertEqual(counts.reads, 0)
        XCTAssertEqual(restored.entries[0].phase, .submitted)
    }

    func test已保存返回身份重启后只读恢复且写能力撤回不影响读取() async throws {
        let root = try root(), firstTransport = MobileChatSendUITransport(state: "chat-send-read-unavailable")
        let first = try await model(root, firstTransport)
        let sent = await first.send(conversationID: "27", text: "Private draft")
        XCTAssertFalse(sent); XCTAssertEqual(first.entries[0].receipt?.candidateMessageID, "9301")
        XCTAssertTrue(first.protectsPendingMessage("9301", in: "27"))
        XCTAssertTrue(first.protectsRoot("9301", in: "27"))
        XCTAssertFalse(first.protectsPendingMessage("9301", in: "28"))
        let transport = MobileChatSendUITransport(restored: first.entries), restored = try await model(root, transport)
        restored.updateAvailability(.init(status: .requiresValidation))
        let recovered = await restored.run(first.entries[0].id, sendPrepared: true)
        XCTAssertTrue(recovered); XCTAssertEqual(restored.entries[0].phase, .complete)
        XCTAssertFalse(restored.protectsPendingMessage("9301", in: "27"))
        let counts = await transport.counts(); XCTAssertEqual(counts.writes, 0); XCTAssertEqual(counts.reads, 1)
    }

    func test未提交草稿重启后必须主动发送且只提交一次() async throws {
        let root = try root(), store = MobileChatSendStore(root: root), draft = try entry()
        try store.reserve(draft)
        let transport = MobileChatSendUITransport(), restored = try await model(root, transport)
        let onlyRead = await restored.run(draft.id, sendPrepared: false)
        XCTAssertFalse(onlyRead); XCTAssertEqual(restored.entries[0].phase, .prepared)
        let before = await transport.counts(); XCTAssertEqual(before.writes, 0)
        let sent = await restored.run(draft.id, sendPrepared: true)
        XCTAssertTrue(sent)
        let duplicate = await restored.run(draft.id, sendPrepared: true); XCTAssertFalse(duplicate)
        let after = await transport.counts(); XCTAssertEqual(after.writes, 1)
    }

    func test执行锁跨同账号模型重绑生效且迟到取消不污染其他账号() async throws {
        let root = try root(), store = MobileChatSendStore(root: root), transport = MobileChatSendUITransport(state: "chat-send-paused")
        let first = try await model(root, transport, store: store)
        let task = Task { await first.send(conversationID: "27", text: "Private draft") }
        await transport.waitUntilBlocked()
        let replacementTransport = MobileChatSendUITransport(), replacement = try await model(root, replacementTransport, store: store)
        XCTAssertTrue(replacement.isBusy); XCTAssertFalse(replacement.canSend(conversationID: "27", text: "New draft"))
        let other = try await model(root, replacementTransport, context: "account-b", store: store)
        XCTAssertTrue(other.entries.isEmpty); XCTAssertFalse(other.isBusy)
        first.invalidate(); await transport.release()
        let sent = await task.value; XCTAssertFalse(sent)
        XCTAssertEqual(first.entries[0].phase, .submitted); XCTAssertNil(first.errorKey); XCTAssertTrue(other.entries.isEmpty)
        XCTAssertFalse(replacement.isBusy)
        let counts = await replacementTransport.counts(); XCTAssertEqual(counts.writes, 0)
    }

    func test提交后取消保留记录且不能重新发送或移除() async throws {
        let root = try root(), transport = MobileChatSendUITransport(state: "chat-send-paused"), model = try await model(root, transport)
        let task = Task { await model.send(conversationID: "27", text: "Private draft") }
        await transport.waitUntilBlocked(); model.cancel(); await transport.release()
        let sent = await task.value; XCTAssertFalse(sent)
        let id = try XCTUnwrap(model.entries.first?.id)
        model.remove(id); model.cancelPrepared(id)
        XCTAssertEqual(model.entry(id)?.phase, .submitted)
        let duplicate = await model.retry(id); XCTAssertFalse(duplicate)
        let counts = await transport.counts(); XCTAssertEqual(counts.writes, 1)
    }

    func test明确拒绝重新发送换新编号并原子移除旧记录() async throws {
        let root = try root(), transport = MobileChatSendUITransport(state: "chat-send-denied"), model = try await model(root, transport)
        let sent = await model.send(conversationID: "27", text: "Private draft")
        XCTAssertFalse(sent); XCTAssertEqual(model.entries[0].phase, .failed); XCTAssertEqual(model.entries[0].failure, .denied)
        let old = model.entries[0].id
        let retried = await model.retry(old); XCTAssertFalse(retried)
        XCTAssertEqual(model.entries.count, 1); XCTAssertNotEqual(model.entries[0].id, old); XCTAssertNil(model.entry(old))
        let duplicate = await model.retry(old); XCTAssertFalse(duplicate)
        let counts = await transport.counts(); XCTAssertEqual(counts.writes, 2)
    }

    func test未提交取消可重试且准备保存失败时零网络写入() async throws {
        let root = try root(), store = MobileChatSendStore(root: root), entry = try entry()
        try store.reserve(entry); try store.cancelPrepared(entry.id, context: entry.context)
        let transport = MobileChatSendUITransport(), model = try await model(root, transport)
        let sent = await model.retry(entry.id)
        XCTAssertTrue(sent); XCTAssertEqual(model.entries.count, 1); XCTAssertEqual(model.entries[0].phase, .complete)
        let badRoot = root.appendingPathComponent("file"), failingTransport = MobileChatSendUITransport()
        try Data().write(to: badRoot)
        let failing = try await self.model(badRoot, failingTransport)
        let rejected = await failing.send(conversationID: "27", text: "Private draft")
        XCTAssertFalse(rejected); XCTAssertTrue(failing.recovery.failed)
        let counts = await failingTransport.counts(); XCTAssertEqual(counts.writes, 0)
    }

    func test返回身份保存失败保留提交记录不误报失败或成功() async throws {
        let root = try root(), transport = MobileChatSendUITransport(state: "chat-send-paused"), model = try await model(root, transport)
        let task = Task { await model.send(conversationID: "27", text: "Private draft") }
        await transport.waitUntilBlocked()
        let file = root.appendingPathComponent("message-sends-v1.json"), original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await transport.release(); let result = await task.value
        XCTAssertFalse(result); XCTAssertTrue(model.recovery.failed); XCTAssertEqual(model.entries[0].phase, .submitted)
        XCTAssertNil(model.entries[0].receipt?.candidateMessageID)
        try FileManager.default.removeItem(at: file); try original.write(to: file)
        let restored = try await self.model(root, transport)
        let recovered = await restored.run(model.entries[0].id, sendPrepared: false)
        XCTAssertFalse(recovered)
        let counts = await transport.counts(); XCTAssertEqual(counts.writes, 1); XCTAssertEqual(counts.reads, 0)
    }

    func test附件保存受保护副本且重启后不依赖原选择文件() async throws {
        let root = try root(), source = root.appendingPathComponent("private.txt")
        try Data("attachment".utf8).write(to: source)
        let transport = MobileChatSendUITransport(state: "chat-send-read-unavailable"), model = try await model(root, transport)
        let sent = await model.send(conversationID: "27", text: "Attachment draft", attachment: selection(source))
        XCTAssertFalse(sent); XCTAssertEqual(model.entries[0].phase, .submitted)
        let copied = try XCTUnwrap(model.recovery.attachmentURL(model.entries[0]))
        XCTAssertNotEqual(copied, source); XCTAssertEqual(try Data(contentsOf: copied), Data("attachment".utf8))
        XCTAssertEqual(try copied.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try FileManager.default.removeItem(at: source)
        let newTransport = MobileChatSendUITransport(restored: model.entries), restored = try await self.model(root, newTransport)
        let recovered = await restored.run(model.entries[0].id, sendPrepared: true)
        XCTAssertTrue(recovered); XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
        let counts = await newTransport.counts(); XCTAssertEqual(counts.writes, 0); XCTAssertEqual(counts.reads, 1)
    }

    func test未发送附件副本改变时零提交且重试不能发送变化内容() async throws {
        let root = try root(), store = MobileChatSendStore(root: root), source = root.appendingPathComponent("private.txt")
        try Data("attachment".utf8).write(to: source)
        let payload = MobileChatSendStore.Payload(text: nil, attachment: .init(fileName: "private.txt", kind: .file,
            byteCount: 10, contentDigest: try MobileChatSendStore.fileDigest(source)))
        let entry = MobileChatSendStore.Entry(id: UUID(), context: "account-a", conversationID: "27", threadID: nil,
            createdAt: Date(), kind: .attachment, inputDigest: try MobileChatSendStore.digest(payload), payload: payload)
        try store.reserve(entry); try MobileTransferRecoveryStore.prepareDirectory(store.directory(entry.id))
        try Data("different!".utf8).write(to: XCTUnwrap(store.attachmentURL(entry)))
        let transport = MobileChatSendUITransport(), model = try await model(root, transport)
        let sent = await model.run(entry.id, sendPrepared: true); XCTAssertFalse(sent)
        XCTAssertEqual(model.entries[0].failure, .attachmentChanged)
        let retry = await model.retry(entry.id); XCTAssertFalse(retry)
        let counts = await transport.counts(); XCTAssertEqual(counts.writes, 0)
    }

    func test同附件重复选择不生成第二次提交并保留第一份副本() async throws {
        let root = try root(), source = root.appendingPathComponent("private.txt")
        try Data("attachment".utf8).write(to: source)
        let transport = MobileChatSendUITransport(state: "chat-send-lost-ack"), model = try await model(root, transport)
        let first = await model.send(conversationID: "27", text: nil, attachment: selection(source))
        let second = await model.send(conversationID: "27", text: nil, attachment: selection(source))
        XCTAssertFalse(first); XCTAssertFalse(second); XCTAssertEqual(model.entries.count, 1); XCTAssertFalse(model.recovery.failed)
        let counts = await transport.counts(); XCTAssertEqual(counts.writes, 1)
        let directories = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("SendFiles").path)
        XCTAssertEqual(directories, [model.entries[0].id.uuidString])
    }

    func test线程与普通文字相同内容分别发送且恢复保持线程归属() async throws {
        let root = try root(), transport = MobileChatSendUITransport(), model = try await model(root, transport)
        let plain = await model.send(conversationID: "27", text: "Same text")
        let reply = await model.send(conversationID: "27", threadID: "9001", text: "Same text")
        XCTAssertTrue(plain); XCTAssertTrue(reply); XCTAssertEqual(model.entries.map(\.kind), [.text, .reply])
        XCTAssertEqual(model.entries[1].receipt?.threadID, "9001")
        XCTAssertEqual(model.confirmedMessage?.threadID, "9001")
    }

    func test附件复制中切换账号保留输入直到复制结束且零发送() async throws {
        let root = try root(), source = root.appendingPathComponent("private.txt")
        try Data("attachment".utf8).write(to: source)
        let copier = PausedChatSendCopier(), transport = MobileChatSendUITransport()
        let store = MobileChatSendStore(root: root), model = try await model(root, transport, store: store, copier: copier)
        let task = Task { await model.send(conversationID: "27", text: nil, attachment: selection(source)) }
        await copier.waitUntilBlocked()
        XCTAssertTrue(store.isBusy(in: "account-a")); XCTAssertTrue(model.entries.isEmpty)
        let other = try await self.model(root, transport, context: "account-b", store: store)
        model.invalidate()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        await copier.release(); let result = await task.value
        XCTAssertFalse(result); XCTAssertTrue(other.entries.isEmpty); XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.isBusy(in: "account-a")); XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let counts = await transport.counts(); XCTAssertEqual(counts.writes, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("SendFiles").path).isEmpty)
    }

    private func model(_ root: URL, _ transport: MobileChatSendUITransport, context: String = "account-a", store: MobileChatSendStore? = nil, copier: any MobileDocumentImportCopying = MobileSecurityScopedDocumentCopier()) async throws -> MobileChatSendModel {
        let profile = try NasProfile(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
        let versions = [DsmAPIName.chatChannel: 2, DsmAPIName.chatUser: 1, DsmAPIName.chatPost: 8, DsmAPIName.chatPostFile: 2]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version,
                requestFormat: .form, selectedVersion: version, verified: false))
        }))
        let repository = MobileReadOnlyChatRepository(base: try DsmChatRepository(profile: profile, capabilities: capabilities,
            session: .init(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport))
        let model = MobileChatSendModel(context: context, repository: repository, recovery: store ?? MobileChatSendStore(root: root), copier: copier)
        model.updateAvailability(await repository.availability()); return model
    }
    private func entry() throws -> MobileChatSendStore.Entry {
        let payload = MobileChatSendStore.Payload(text: "Private draft", attachment: nil)
        return .init(id: UUID(), context: "account-a", conversationID: "27", threadID: nil, createdAt: Date(),
            kind: .text, inputDigest: try MobileChatSendStore.digest(payload), payload: payload)
    }
    private func selection(_ url: URL) -> MobileChatAttachmentSelection {
        .init(id: UUID(), localURL: url, directoryURL: url.deletingLastPathComponent(), fileName: url.lastPathComponent, kind: .file, byteCount: 10)
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatSendTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
}

private actor PausedChatSendCopier: MobileDocumentImportCopying {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func copySecurityScopedFile(from sourceURL: URL, to destinationURL: URL, in directoryURL: URL) async throws {
        try await MobileSecurityScopedDocumentCopier().copySecurityScopedFile(from: sourceURL, to: destinationURL, in: directoryURL)
        await withCheckedContinuation { continuation = $0; waiters.forEach { $0.resume() }; waiters = [] }
    }
    func waitUntilBlocked() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

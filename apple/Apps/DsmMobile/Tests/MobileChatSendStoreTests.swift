import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatSendStoreTests: XCTestCase {
    func test重复草稿按账号会话线程隔离并可从磁盘重建() throws {
        let root = try root(), store = MobileChatSendStore(root: root), first = try entry()
        try store.reserve(first)
        XCTAssertThrowsError(try store.reserve(entry()))
        try store.reserve(entry(context: "account-b"))
        try store.reserve(entry(thread: "9001"))
        XCTAssertEqual(store.entries.count, 3); XCTAssertFalse(store.failed)
        XCTAssertEqual(MobileChatSendStore(root: root).entries, store.entries)
    }

    func test准备与执行锁互斥且不能跨账号修改() throws {
        let store = MobileChatSendStore(root: try root()), entry = try entry()
        try store.reserve(entry)
        XCTAssertTrue(store.beginPreparing(in: entry.context)); XCTAssertFalse(store.begin(entry.id, in: entry.context))
        store.endPreparing(in: entry.context)
        XCTAssertTrue(store.begin(entry.id, in: entry.context)); XCTAssertFalse(store.beginPreparing(in: entry.context))
        XCTAssertFalse(store.begin(entry.id, in: "account-b"))
        XCTAssertThrowsError(try store.record(receipt(entry), in: "account-b"))
        XCTAssertThrowsError(try store.cancelPrepared(entry.id, context: entry.context))
        store.end(entry.id); try store.cancelPrepared(entry.id, context: entry.context)
        XCTAssertEqual(store.entries[0].phase, .cancelled)
    }

    func test回执必须先保存无身份再追加原消息身份且不能倒退() throws {
        let store = MobileChatSendStore(root: try root()), entry = try entry()
        try store.reserve(entry); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        var receipt = try receipt(entry); receipt.candidateMessageID = "9201"
        XCTAssertThrowsError(try store.record(receipt, in: entry.context))
        receipt.candidateMessageID = nil; try store.record(receipt, in: entry.context)
        XCTAssertThrowsError(try store.finish(entry.id, context: entry.context, phase: .complete))
        receipt.candidateMessageID = "9201"; try store.record(receipt, in: entry.context)
        receipt.candidateMessageID = "9202"; XCTAssertThrowsError(try store.record(receipt, in: entry.context))
        receipt.candidateMessageID = nil; XCTAssertThrowsError(try store.record(receipt, in: entry.context))
        XCTAssertThrowsError(try store.finish(entry.id, context: entry.context, phase: .failed, failure: .invalid))
        XCTAssertEqual(store.entries[0].receipt?.candidateMessageID, "9201")
    }

    func test成功后删除正文附件副本但保留最小发送身份() throws {
        let root = try root(), store = MobileChatSendStore(root: root), entry = try entry(attachment: true)
        try store.reserve(entry); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        let file = try XCTUnwrap(store.attachmentURL(entry))
        try MobileTransferRecoveryStore.prepareDirectory(store.directory(entry.id))
        try Data("attachment".utf8).write(to: file)
        var receipt = try receipt(entry, size: 10); try store.record(receipt, in: entry.context)
        receipt.candidateMessageID = "9201"; try store.record(receipt, in: entry.context)
        try store.finish(entry.id, context: entry.context, phase: .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)); XCTAssertNil(store.entries[0].payload)
        let text = try String(contentsOf: root.appendingPathComponent("message-sends-v1.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("private-body")); XCTAssertFalse(text.contains("private-name.txt"))
        XCTAssertTrue(text.contains("9201")); XCTAssertEqual(MobileChatSendStore(root: root).entries, store.entries)
        store.end(entry.id); try store.remove(entry.id, context: entry.context); XCTAssertTrue(store.entries.isEmpty)
    }

    func test未知记录不能取消移除或用新编号覆盖() throws {
        let root = try root(), store = MobileChatSendStore(root: root), entry = try entry()
        try store.reserve(entry); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        try store.record(receipt(entry), in: entry.context); store.end(entry.id)
        XCTAssertThrowsError(try store.cancelPrepared(entry.id, context: entry.context))
        XCTAssertThrowsError(try store.remove(entry.id, context: entry.context))
        XCTAssertThrowsError(try store.reserve(self.entry(), replacing: entry.id))
        XCTAssertEqual(MobileChatSendStore(root: root).entries[0].phase, .submitted)
    }

    func test重新发送原子替换失败记录且不能更换草稿或再次使用旧编号() throws {
        let root = try root(), store = MobileChatSendStore(root: root), original = try entry()
        try store.reserve(original); XCTAssertTrue(store.begin(original.id, in: original.context))
        try store.finish(original.id, context: original.context, phase: .failed, failure: .denied); store.end(original.id)
        XCTAssertThrowsError(try store.reserve(entry(text: "changed"), replacing: original.id))
        let replacement = try entry(); try store.reserve(replacement, replacing: original.id)
        XCTAssertEqual(store.entries.map(\.id), [replacement.id])
        XCTAssertThrowsError(try store.reserve(entry(), replacing: original.id))
        XCTAssertEqual(MobileChatSendStore(root: root).entries, store.entries)
    }

    func test回执不能替换正文附件大小或原发送者() throws {
        let store = MobileChatSendStore(root: try root()), entry = try entry(attachment: true)
        try store.reserve(entry); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        XCTAssertThrowsError(try store.record(receipt(entry, size: 11), in: entry.context))
        let good = try receipt(entry, size: 10); try store.record(good, in: entry.context)
        XCTAssertThrowsError(try store.record(receipt(entry, size: 10, sender: "other"), in: entry.context))
        let wrongDraft = try ChatMessageDraft(clientRequestID: entry.id, conversationID: entry.conversationID, text: "wrong")
        XCTAssertThrowsError(try store.record(ChatMessageSendReceipt(draft: wrongDraft, currentUserID: "me"), in: entry.context))
        XCTAssertEqual(store.entries[0].receipt, good)
    }

    func test损坏数据保留原件并阻止覆盖而非当作空队列() throws {
        for data in [Data("broken".utf8), Data(#"{"version":0,"entries":[]}"#.utf8)] {
            let root = try root(), file = root.appendingPathComponent("message-sends-v1.json")
            try data.write(to: file); let store = MobileChatSendStore(root: root)
            XCTAssertTrue(store.failed); XCTAssertThrowsError(try store.reserve(entry()))
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
        let root = try root(), store = MobileChatSendStore(root: root)
        try store.reserve(entry())
        let file = root.appendingPathComponent("message-sends-v1.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        entries[0]["inputDigest"] = String(repeating: "a", count: 64); json["entries"] = entries
        let changed = try JSONSerialization.data(withJSONObject: json); try changed.write(to: file)
        XCTAssertTrue(MobileChatSendStore(root: root).failed); XCTAssertEqual(try Data(contentsOf: file), changed)
    }

    func test保存失败保留内存记录且不能继续提交() throws {
        let root = try root(), store = MobileChatSendStore(root: root), entry = try entry()
        try store.reserve(entry); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        let file = root.appendingPathComponent("message-sends-v1.json")
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.record(receipt(entry), in: entry.context))
        XCTAssertTrue(store.failed); XCTAssertEqual(store.entries[0].phase, .prepared)
        XCTAssertFalse(store.beginPreparing(in: "account-b"))
    }

    private func entry(context: String = "account-a", text: String = "private-body", thread: String? = nil, attachment: Bool = false) throws -> MobileChatSendStore.Entry {
        let payload = MobileChatSendStore.Payload(text: text, attachment: attachment ? .init(fileName: "private-name.txt", kind: .file,
            byteCount: 10, contentDigest: String(repeating: "a", count: 64)) : nil)
        return .init(id: UUID(), context: context, conversationID: "27", threadID: thread, createdAt: Date(),
            kind: attachment ? .attachment : (thread == nil ? .text : .reply), inputDigest: try MobileChatSendStore.digest(payload), payload: payload)
    }
    private func receipt(_ entry: MobileChatSendStore.Entry, size: Int64? = nil, sender: String = "me") throws -> ChatMessageSendReceipt {
        let draft = try ChatMessageDraft(clientRequestID: entry.id, conversationID: entry.conversationID, text: entry.payload?.text,
            localAttachmentURLs: entry.payload?.attachment.map { [URL(fileURLWithPath: "/" + $0.fileName)] } ?? [], threadID: entry.threadID)
        return try .init(draft: draft, currentUserID: sender, attachmentSize: size)
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatSendStoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
}

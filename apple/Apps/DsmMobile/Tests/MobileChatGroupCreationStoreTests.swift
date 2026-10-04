import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatGroupCreationStoreTests: XCTestCase {
    func test建群草稿回执跨重启保留且目录排除备份() throws {
        let root = try root(), store = MobileChatGroupCreationStore(root: root), entry = try entry()
        try store.reserve(entry)
        XCTAssertEqual(MobileChatGroupCreationStore(root: root).entries, [entry])
        XCTAssertTrue(store.begin(entry.id, in: entry.context))
        let receipt = try ChatGroupCreateReceipt(draft: entry.draft(), currentUserID: "1")
        try store.record(receipt, in: entry.context)
        let restored = MobileChatGroupCreationStore(root: root)
        XCTAssertEqual(restored.entries.first?.receipt, receipt); XCTAssertFalse(restored.isBusy(in: entry.context))
        let file = root.appendingPathComponent("group-creations-v1.json")
        XCTAssertTrue(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let rows = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(rows.first).keys), ["id", "context", "title", "memberIDs", "createdAt", "receipt"])
    }

    func test真机建群恢复文件使用完整保护级别() throws {
        let root = try root(), store = MobileChatGroupCreationStore(root: root)
        try store.reserve(entry())
        #if targetEnvironment(simulator)
        // 独立系统写入确认模拟器限制，不将产品记录缺失属性当作通过。
        let reference = root.appendingPathComponent("protection-reference")
        try Data([0]).write(to: reference, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: reference.path)
        if try FileManager.default.attributesOfItem(atPath: reference.path)[.protectionKey] == nil {
            throw XCTSkip("PENDING_USER_VALIDATION：此模拟器的独立系统写入不返回文件保护级别。保留给 iPhone/iPad 真机验证群聊恢复记录锁屏保护，不能计作通过。")
        }
        #endif
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("group-creations-v1.json").path)
        XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.complete.rawValue)
    }

    func test建群按账号隔离允许其他草稿但拒绝同一未结束草稿() throws {
        let store = MobileChatGroupCreationStore(root: try root()), first = try entry()
        try store.reserve(first)
        XCTAssertThrowsError(try store.reserve(entry()))
        try store.reserve(entry(title: "另一个合成群"))
        try store.reserve(entry(context: "account-b"))
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertTrue(store.begin(first.id, in: first.context))
        XCTAssertFalse(store.begin(store.entries[1].id, in: first.context))
        XCTAssertTrue(store.begin(store.entries[2].id, in: "account-b"))
        store.end(first.id); XCTAssertTrue(store.begin(store.entries[1].id, in: first.context))
    }

    func test建群回执要求原草稿执行锁且不能替换编号或倒退完成步骤() throws {
        let store = MobileChatGroupCreationStore(root: try root()), entry = try entry()
        try store.reserve(entry)
        var receipt = try ChatGroupCreateReceipt(draft: entry.draft(), currentUserID: "1")
        XCTAssertThrowsError(try store.record(receipt, in: entry.context))
        XCTAssertTrue(store.begin(entry.id, in: entry.context)); try store.record(receipt, in: entry.context)
        receipt.create = .completed; receipt.candidateConversationID = "42"; receipt.revision += 1
        try store.record(receipt, in: entry.context)
        var changed = receipt; changed.candidateConversationID = "43"; changed.revision += 1
        XCTAssertThrowsError(try store.record(changed, in: entry.context))
        changed = receipt; changed.join = .completed; changed.revision += 1
        try store.record(changed, in: entry.context)
        receipt.revision = changed.revision + 1
        XCTAssertThrowsError(try store.record(receipt, in: entry.context))
        let wrong = try ChatGroupCreateReceipt(draft: entry.draft(), currentUserID: "4")
        XCTAssertThrowsError(try store.record(wrong, in: entry.context))
        XCTAssertThrowsError(try store.record(changed, in: "account-b"))
    }

    func test建群首个回执不得跳过提交保存且已提交记录不可取消() throws {
        let store = MobileChatGroupCreationStore(root: try root()), entry = try entry()
        try store.reserve(entry); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        var receipt = try ChatGroupCreateReceipt(draft: entry.draft(), currentUserID: "1")
        receipt.create = .completed; receipt.candidateConversationID = "42"; receipt.revision = 1
        XCTAssertThrowsError(try store.record(receipt, in: entry.context))
        receipt = try ChatGroupCreateReceipt(draft: entry.draft(), currentUserID: "1")
        try store.record(receipt, in: entry.context); store.end(entry.id)
        XCTAssertThrowsError(try store.discardPrepared(entry)); XCTAssertEqual(store.entries.count, 1)
    }

    func test建群完成只接受原群与全部完成回执并清理草稿() throws {
        let root = try root(), store = MobileChatGroupCreationStore(root: root), entry = try entry()
        try store.reserve(entry); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        var receipt = try ChatGroupCreateReceipt(draft: entry.draft(), currentUserID: "1")
        try store.record(receipt, in: entry.context)
        XCTAssertThrowsError(try store.finish(entry, outcome: outcome(entry)))
        receipt.create = .completed; receipt.candidateConversationID = "42"; receipt.join = .completed; receipt.invite = .completed; receipt.revision = 1
        try store.record(receipt, in: entry.context)
        XCTAssertThrowsError(try store.finish(entry, outcome: outcome(entry, conversationID: "43")))
        try store.finish(entry, outcome: outcome(entry))
        XCTAssertTrue(store.entries.isEmpty); XCTAssertTrue(MobileChatGroupCreationStore(root: root).entries.isEmpty)
        let data = try Data(contentsOf: root.appendingPathComponent("group-creations-v1.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(entry.title))
    }

    func test建群已创建后错误终态不能释放原记录() throws {
        let store = MobileChatGroupCreationStore(root: try root()), entry = try entry()
        try store.reserve(entry); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        var receipt = try ChatGroupCreateReceipt(draft: entry.draft(), currentUserID: "1")
        try store.record(receipt, in: entry.context)
        receipt.create = .completed; receipt.candidateConversationID = "42"; receipt.revision += 1
        try store.record(receipt, in: entry.context)
        let failure = ChatConversationCreateOutcome(result: try MutationResult(status: .permissionDenied, operation: "chatGroupCreate",
            submitted: true, requiresRefresh: false, counts: .init(succeeded: 0, failed: 1, unknown: 0), errorCategory: .permission,
            diagnosticTag: "synthetic.failure"), clientRequestID: entry.id, confirmedConversation: nil)
        XCTAssertThrowsError(try store.finish(entry, outcome: failure)); XCTAssertEqual(store.entries.count, 1)
    }

    func test建群坏文件非当前开发格式和非目录都保留原件关闭写入() throws {
        for contents in ["broken", #"{"version":2,"entries":[]}"#] {
            let root = try root(), file = root.appendingPathComponent("group-creations-v1.json"), data = Data(contents.utf8)
            try data.write(to: file)
            let store = MobileChatGroupCreationStore(root: root)
            XCTAssertTrue(store.failed); XCTAssertThrowsError(try store.reserve(entry()))
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
        let file = try root().appendingPathComponent("occupied")
        try Data("occupied".utf8).write(to: file)
        XCTAssertTrue(MobileChatGroupCreationStore(root: file).failed)
    }

    func test建群保存失败不更新已提交内存且保留上一份记录() throws {
        let root = try root(), store = MobileChatGroupCreationStore(root: root), entry = try entry()
        try store.reserve(entry); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        try FileManager.default.removeItem(at: root)
        try Data("occupied".utf8).write(to: root)
        let receipt = try ChatGroupCreateReceipt(draft: entry.draft(), currentUserID: "1")
        XCTAssertThrowsError(try store.record(receipt, in: entry.context)); XCTAssertTrue(store.failed)
        XCTAssertNil(store.entries.first?.receipt)
    }

    private func entry(context: String = "account-a", title: String = "合成群聊") throws -> MobileChatGroupCreationStore.Entry {
        .init(id: UUID(), context: context, title: title, memberIDs: ["2", "3"], createdAt: Date())
    }
    private func outcome(_ entry: MobileChatGroupCreationStore.Entry, conversationID: String = "42") throws -> ChatConversationCreateOutcome {
        .init(result: try MutationResult(status: .confirmedSuccess, operation: "chatGroupCreate", submitted: true, requiresRefresh: false,
            counts: .init(succeeded: 1, failed: 0, unknown: 0), diagnosticTag: "synthetic.success"), clientRequestID: entry.id,
            confirmedConversation: .init(id: conversationID, kind: .group, title: entry.title, memberIDs: ["1", "2", "3"], unreadCount: 0, isEncrypted: false))
    }
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("ChatGroupStoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }; return value
    }
}

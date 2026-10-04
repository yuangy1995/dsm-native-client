import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatConversationCreationStoreTests: XCTestCase {
    func test单聊准备与提交阶段均跨重启保留且不保存草稿正文() throws {
        let root = rootURL(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileChatConversationCreationStore(root: root), entry = entry()
        XCTAssertTrue(store.reserve(entry))
        let prepared = MobileChatConversationCreationStore(root: root)
        XCTAssertEqual(prepared.pending(in: "account-a")?.phase, .prepared)
        XCTAssertTrue(store.beginExecution(entry)); try store.markSubmitted(entry)
        let submitted = MobileChatConversationCreationStore(root: root)
        XCTAssertEqual(submitted.pending(in: "account-a")?.phase, .submitted)
        XCTAssertFalse(submitted.isExecuting(entry))
        let data = try Data(contentsOf: root.appendingPathComponent("conversation-creation-v1.json"))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(envelope["entries"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(entries.first).keys), ["id", "context", "userID", "phase"])
        XCTAssertTrue(store.finish(entry)); XCTAssertNil(MobileChatConversationCreationStore(root: root).pending(in: "account-a"))
    }

    func test单聊存储按账号隔离并阻止未结束目标被新请求替换() throws {
        let root = rootURL(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileChatConversationCreationStore(root: root), first = entry()
        XCTAssertTrue(store.reserve(first))
        XCTAssertFalse(store.reserve(entry(userID: "other")))
        let second = entry(context: "account-b"); XCTAssertTrue(store.reserve(second))
        XCTAssertFalse(store.reserve(.init(id: first.id, context: "account-c", userID: "2", phase: .prepared)))
        XCTAssertEqual(store.pending(in: "account-a"), first); XCTAssertEqual(store.pending(in: "account-b"), second)
    }

    func test同一存储实例执行锁阻止旧请求运行时提前恢复() throws {
        let root = rootURL(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileChatConversationCreationStore(root: root), value = entry()
        XCTAssertTrue(store.reserve(value)); XCTAssertTrue(store.beginExecution(value))
        XCTAssertFalse(store.beginExecution(value)); XCTAssertTrue(store.isExecuting(value))
        store.endExecution(value); XCTAssertFalse(store.isExecuting(value)); XCTAssertTrue(store.beginExecution(value))
    }

    func test单聊提交阶段必须绑定原目标与执行锁且不得重复进入() throws {
        let root = rootURL(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileChatConversationCreationStore(root: root), value = entry()
        XCTAssertTrue(store.reserve(value)); XCTAssertThrowsError(try store.markSubmitted(value))
        XCTAssertTrue(store.beginExecution(value))
        let wrong = MobileChatConversationCreationStore.Entry(id: value.id, context: value.context, userID: "wrong", phase: .prepared)
        XCTAssertThrowsError(try store.markSubmitted(wrong)); XCTAssertFalse(store.finish(wrong))
        try store.markSubmitted(value); XCTAssertThrowsError(try store.markSubmitted(value))
        XCTAssertEqual(store.pending(in: "account-a")?.phase, .submitted)
    }

    func test单聊坏文件或非当前开发版本保留原件并拒绝新操作() throws {
        for contents in ["broken", #"{"version":2,"entries":[]}"#] {
            let root = rootURL(); defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("conversation-creation-v1.json"), data = Data(contents.utf8)
            try data.write(to: file)
            let store = MobileChatConversationCreationStore(root: root)
            XCTAssertTrue(store.failed); XCTAssertFalse(store.reserve(entry()))
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func test单聊落盘失败不更新内存为已提交() throws {
        let root = rootURL(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileChatConversationCreationStore(root: root), value = entry()
        XCTAssertTrue(store.reserve(value)); XCTAssertTrue(store.beginExecution(value))
        try FileManager.default.removeItem(at: root)
        try Data("occupied".utf8).write(to: root)
        XCTAssertThrowsError(try store.markSubmitted(value)); XCTAssertTrue(store.failed)
        XCTAssertEqual(store.pending(in: "account-a")?.phase, .prepared)
        XCTAssertFalse(store.finish(value))
    }

    private func rootURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ChatCreationStoreTests-\(UUID())") }
    private func entry(context: String = "account-a", userID: String = "2") -> MobileChatConversationCreationStore.Entry {
        .init(id: UUID(), context: context, userID: userID, phase: .prepared)
    }
}

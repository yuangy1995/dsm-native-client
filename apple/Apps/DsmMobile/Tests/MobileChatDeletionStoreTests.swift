import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatDeletionStoreTests: XCTestCase {
    func test同账号重复目标拒绝其他账号独立且原文件可恢复() throws {
        let root = try root(), store = MobileChatDeletionStore(root: root), entry = try entry()
        try store.reserve(entry)
        XCTAssertThrowsError(try store.reserve(self.entry()))
        try store.reserve(self.entry(context: "account-b"))
        XCTAssertEqual(store.entries.count, 2); XCTAssertFalse(store.failed)
        XCTAssertEqual(MobileChatDeletionStore(root: root).entries, store.entries)
    }

    func test执行锁跨模型共有错误账号不能更新或移除() throws {
        let store = MobileChatDeletionStore(root: try root()), entry = try entry()
        try store.reserve(entry)
        XCTAssertFalse(store.begin(entry.id, in: "account-b")); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        XCTAssertFalse(store.begin(entry.id, in: entry.context))
        XCTAssertThrowsError(try store.progress(entry.items[0].id, in: entry.id, context: "account-b", phase: .submitted))
        XCTAssertThrowsError(try store.cancelRemaining(entry.id, context: entry.context))
        store.end(entry.id)
        XCTAssertTrue(store.begin(entry.id, in: entry.context))
    }

    func test取消保留未开始项但提交项不能消失() throws {
        let root = try root(), store = MobileChatDeletionStore(root: root), entry = try entry(two: true)
        try store.reserve(entry); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        try store.progress(entry.items[0].id, in: entry.id, context: entry.context, phase: .submitted)
        store.end(entry.id); try store.cancelRemaining(entry.id, context: entry.context)
        XCTAssertEqual(store.entries[0].items.map(\.phase), [.submitted, .cancelled])
        XCTAssertThrowsError(try store.remove(entry.id, context: entry.context))
        XCTAssertEqual(MobileChatDeletionStore(root: root).entries, store.entries)
    }

    func test终态不能倒退或丢失失败原因且全部结束才能移除() throws {
        let store = MobileChatDeletionStore(root: try root()), entry = try entry(two: true)
        try store.reserve(entry); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        XCTAssertThrowsError(try store.progress(entry.items[0].id, in: entry.id, context: entry.context, phase: .failed))
        try store.progress(entry.items[0].id, in: entry.id, context: entry.context, phase: .complete)
        XCTAssertThrowsError(try store.progress(entry.items[0].id, in: entry.id, context: entry.context, phase: .submitted))
        try store.progress(entry.items[1].id, in: entry.id, context: entry.context, phase: .failed, failure: .changed)
        XCTAssertThrowsError(try store.remove(entry.id, context: entry.context))
        store.end(entry.id); try store.remove(entry.id, context: entry.context)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test损坏文件与不支持开发格式保留原件并阻止覆盖() throws {
        for data in [Data("broken".utf8), Data(#"{"version":0,"entries":[]}"#.utf8)] {
            let root = try root(), file = root.appendingPathComponent("message-deletions-v1.json")
            try data.write(to: file)
            let store = MobileChatDeletionStore(root: root)
            XCTAssertTrue(store.failed); XCTAssertThrowsError(try store.reserve(entry()))
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func test批次不能包含重复身份或他人来源() throws {
        let store = MobileChatDeletionStore(root: try root())
        var repeated = try entry(); repeated.items.append(repeated.items[0])
        XCTAssertThrowsError(try store.reserve(repeated))
        var mixed = try entry(); mixed.items.append(.init(id: UUID(), source: try snapshot(id: "9002", sender: "2")))
        XCTAssertThrowsError(try store.reserve(mixed)); XCTAssertTrue(store.entries.isEmpty)
    }

    private func snapshot(id: String = "9001", sender: String = "1") throws -> ChatMessageDeletionSnapshot {
        try .init(.init(id: id, conversationID: "27", senderID: sender, isFromCurrentUser: true,
                        sentAt: Date(timeIntervalSince1970: 1_790_000_000), text: "合成消息"))
    }
    private func entry(context: String = "account-a", two: Bool = false) throws -> MobileChatDeletionStore.Entry {
        let items = try (two ? ["9001", "9002"] : ["9001"]).map { MobileChatDeletionStore.Item(id: UUID(), source: try snapshot(id: $0)) }
        return .init(id: UUID(), context: context, createdAt: Date(), items: items)
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ChatDeletionStoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
}

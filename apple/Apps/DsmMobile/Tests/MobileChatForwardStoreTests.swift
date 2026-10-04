import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatForwardStoreTests: XCTestCase {
    func test重复来源在同账号未结束时拒绝但其他账号独立() throws {
        let store = MobileChatForwardStore(root: try root()), first = try entry()
        try store.reserve(first)
        XCTAssertThrowsError(try store.reserve(entry()))
        try store.reserve(entry(context: "account-b"))
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertFalse(store.failed)
    }

    func test执行锁跨模型共享且错误账号不能取得记录() throws {
        let store = MobileChatForwardStore(root: try root()), entry = try entry()
        try store.reserve(entry)
        XCTAssertFalse(store.begin(entry.id, in: "account-b"))
        XCTAssertTrue(store.begin(entry.id, in: entry.context))
        XCTAssertFalse(store.begin(entry.id, in: entry.context))
        XCTAssertThrowsError(try store.cancelRemaining(entry.id, context: entry.context))
        store.end(entry.id); XCTAssertTrue(store.begin(entry.id, in: entry.context))
    }

    func test不能篡改原消息目标或倒退成功回执() throws {
        let store = MobileChatForwardStore(root: try root()), entry = try entry()
        try store.reserve(entry); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        var receipt = try receipt(entry)
        var wrongTarget = receipt
        wrongTarget.targets = [.init(conversationID: "30", baseline: [])]
        XCTAssertThrowsError(try store.progress(wrongTarget, in: entry.id, context: entry.context))
        let wrongSource = try ChatForwardReceipt(original: message(id: "other"), currentUserID: "1",
            clientRequestID: entry.items[0].id, targets: receipt.targets)
        XCTAssertThrowsError(try store.progress(wrongSource, in: entry.id, context: entry.context))
        try store.progress(receipt, in: entry.id, context: entry.context)
        receipt.acknowledged = true; try store.progress(receipt, in: entry.id, context: entry.context)
        var regressed = receipt; regressed.acknowledged = false
        XCTAssertThrowsError(try store.progress(regressed, in: entry.id, context: entry.context))
        receipt.targets[0].confirmedMessageID = "sent-28"; try store.progress(receipt, in: entry.id, context: entry.context)
        regressed = receipt; regressed.targets[0].confirmedMessageID = nil
        XCTAssertThrowsError(try store.progress(regressed, in: entry.id, context: entry.context))
        XCTAssertThrowsError(try store.failItem(entry.items[0].id, in: entry.id, context: entry.context))
        XCTAssertEqual(store.entry(entry.id, in: entry.context)?.items[0].phase, .complete)
    }

    func test取消只取消未开始项而不能移除未知结果() throws {
        let root = try root(), store = MobileChatForwardStore(root: root)
        var entry = try entry(); entry.items.append(.init(id: UUID(), source: try .init(message(id: "9002"))))
        try store.reserve(entry); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        try store.progress(receipt(entry), in: entry.id, context: entry.context)
        store.end(entry.id); try store.cancelRemaining(entry.id, context: entry.context)
        XCTAssertEqual(store.entry(entry.id, in: entry.context)?.items.map(\.phase), [.submitted, .cancelled])
        XCTAssertThrowsError(try store.remove(entry.id, context: entry.context))
        XCTAssertEqual(MobileChatForwardStore(root: root).entries, store.entries)
    }

    func test新联系人提交状态在重启后保留且未结束不可移除() throws {
        let root = try root(), store = MobileChatForwardStore(root: root)
        var entry = try entry(); entry.destinations = [.contact("2")]
        try store.reserve(entry); XCTAssertTrue(store.begin(entry.id, in: entry.context))
        try store.destination(entry.destinations[0].id, in: entry.id, context: entry.context, phase: .submitted)
        store.end(entry.id); try store.cancelRemaining(entry.id, context: entry.context)
        let fresh = MobileChatForwardStore(root: root)
        XCTAssertEqual(fresh.entries[0].items[0].phase, .cancelled)
        XCTAssertEqual(fresh.entries[0].destinations[0].phase, .submitted)
        XCTAssertTrue(fresh.entries[0].hasUnfinished)
        XCTAssertThrowsError(try fresh.remove(entry.id, context: entry.context))
    }

    func test损坏文件保留原文件且不允许覆盖() throws {
        let root = try root(), file = root.appendingPathComponent("forwarding-v1.json"), data = Data("broken".utf8)
        try data.write(to: file)
        let store = MobileChatForwardStore(root: root)
        XCTAssertTrue(store.failed); XCTAssertThrowsError(try store.reserve(entry()))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func test读取不一致完成阶段拒绝并保留原文件() throws {
        let root = try root(), store = MobileChatForwardStore(root: root), entry = try entry()
        try store.reserve(entry)
        let file = root.appendingPathComponent("forwarding-v1.json")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var entries = try XCTUnwrap(envelope["entries"] as? [[String: Any]])
        var items = try XCTUnwrap(entries[0]["items"] as? [[String: Any]])
        items[0]["phase"] = "complete"; entries[0]["items"] = items; envelope["entries"] = entries
        let malformed = try JSONSerialization.data(withJSONObject: envelope); try malformed.write(to: file)
        XCTAssertTrue(MobileChatForwardStore(root: root).failed)
        XCTAssertEqual(try Data(contentsOf: file), malformed)
    }

    private func message(id: String = "9001") -> ChatMessage {
        .init(id: id, conversationID: "27", senderID: "2", sentAt: Date(timeIntervalSince1970: 1_790_000_000), text: "Private content", threadID: "0")
    }
    private func entry(context: String = "account-a") throws -> MobileChatForwardStore.Entry {
        .init(id: UUID(), context: context, createdAt: Date(), items: [.init(id: UUID(), source: try .init(message()))], destinations: [.conversation("28")])
    }
    private func receipt(_ entry: MobileChatForwardStore.Entry) throws -> ChatForwardReceipt {
        try .init(original: message(), currentUserID: "1", clientRequestID: entry.items[0].id, targets: [.init(conversationID: "28", baseline: [])])
    }
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("ChatForwardStoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }; return value
    }
}

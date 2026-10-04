@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

@MainActor
final class MobileDownloadControlStoreTests: XCTestCase {
    private let context = String(repeating: "a", count: 64)
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadControlStoreTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func entry(context: String? = nil, action: MobileDownloadControlStore.Action = .pause) -> MobileDownloadControlStore.Entry {
        .init(id: UUID(), context: context ?? self.context, createdAt: Date(), action: action, items: [
            .init(task: .init(id: "one", title: "Synthetic one", status: "downloading")),
            .init(task: .init(id: "two", title: "Synthetic two", status: "downloading"))
        ])
    }
    func test同任务跨动作保护而不同账号记录独立() throws {
        let root = root(), store = MobileDownloadControlStore(root: root), first = entry()
        try store.reserve(first)
        XCTAssertThrowsError(try store.reserve(entry(action: .resume)))
        try store.reserve(entry(context: String(repeating: "b", count: 64)))
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertFalse(store.failed)
        XCTAssertEqual(MobileDownloadControlStore(root: root).entries, store.entries)
    }
    func test执行中取消立即落盘但已提交项不能取消或删除() throws {
        let root = root(), store = MobileDownloadControlStore(root: root), first = entry()
        try store.reserve(first); XCTAssertTrue(store.begin(first.id, context: context))
        try store.progress(first.items[0].id, in: first.id, context: context, phase: .submitted)
        try store.cancelRemaining(first.id, context: context)
        XCTAssertEqual(MobileDownloadControlStore(root: root).entries[0].items.map(\.phase), [.submitted, .cancelled])
        XCTAssertThrowsError(try store.remove(first.id, context: context))
        try store.progress(first.items[0].id, in: first.id, context: context, phase: .complete)
        XCTAssertThrowsError(try store.remove(first.id, context: context))
        store.end(first.id); try store.remove(first.id, context: context)
        XCTAssertTrue(MobileDownloadControlStore(root: root).entries.isEmpty)
    }
    func test错误账号和执行锁外不能改进度完成不能回退() throws {
        let store = MobileDownloadControlStore(root: root()), first = entry()
        try store.reserve(first)
        XCTAssertThrowsError(try store.progress(first.items[0].id, in: first.id, context: context, phase: .submitted))
        XCTAssertFalse(store.begin(first.id, context: String(repeating: "b", count: 64)))
        XCTAssertTrue(store.begin(first.id, context: context)); XCTAssertFalse(store.begin(first.id, context: context))
        try store.progress(first.items[0].id, in: first.id, context: context, phase: .submitted)
        try store.progress(first.items[0].id, in: first.id, context: context, phase: .complete)
        XCTAssertThrowsError(try store.progress(first.items[0].id, in: first.id, context: context, phase: .submitted))
        XCTAssertThrowsError(try store.progress(first.items[1].id, in: first.id, context: context, phase: .complete))
    }
    func test磁盘记录畸形不能清空后重新提交() throws {
        for mutation in ["context", "version", "identityDigest", "phase"] {
            let root = root(), store = MobileDownloadControlStore(root: root)
            try store.reserve(entry())
            let url = root.appendingPathComponent("controls-v1.json")
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var entries = try XCTUnwrap(envelope["entries"] as? [[String: Any]])
            if mutation == "version" { envelope["version"] = 99 }
            else if mutation == "context" { entries[0]["context"] = "invalid" }
            else {
                var items = try XCTUnwrap(entries[0]["items"] as? [[String: Any]])
                items[0][mutation] = mutation == "phase" ? "failed" : "not-a-digest"
                entries[0]["items"] = items
            }
            envelope["entries"] = entries
            let corrupt = try JSONSerialization.data(withJSONObject: envelope); try corrupt.write(to: url)
            let restored = MobileDownloadControlStore(root: root)
            XCTAssertTrue(restored.failed)
            XCTAssertThrowsError(try restored.reserve(entry()))
            XCTAssertEqual(try Data(contentsOf: url), corrupt, "不能覆盖唯一恢复记录")
        }
    }
    func test身份摘要保留空值与边界区分而速度变化不影响匹配() {
        let task = DownloadStationTask(id: "one", title: "a:;\nb", status: "downloading", sizeBytes: 4096, downloadBytesPerSecond: 3)
        let item = MobileDownloadControlStore.Item(task: task)
        XCTAssertTrue(item.matches(.init(id: "one", title: task.title, status: "paused", sizeBytes: 4096, downloadBytesPerSecond: 0)))
        XCTAssertFalse(item.matches(.init(id: "one", title: task.title, status: "paused", sizeBytes: 4096, destination: "")))
        XCTAssertFalse(item.matches(.init(id: "one", title: "Changed", status: "paused", sizeBytes: 4096)))
    }
}

import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileFavoritesTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = []; try await super.tearDown() }

    func test文件收藏和移除回读后刷新列表且可连续操作() async throws {
        let service = FavoriteFixture(), model = try make(service)
        var refreshes = 0; model.onChanged = { _ in refreshes += 1 }
        let added = await model.setFavorite(path: service.path, name: "Sample.txt", removing: false)
        let removed = await model.setFavorite(path: service.path, name: "Sample.txt", removing: true)
        XCTAssertTrue(added); XCTAssertTrue(removed); XCTAssertEqual(refreshes, 2)
        let calls = await service.calls; XCTAssertEqual(calls, [false, true]); XCTAssertTrue(model.pending.isEmpty)
    }

    func test已有收藏不重加且截断清单不允许猜测缺失() async throws {
        let service = FavoriteFixture(), model = try make(service)
        await service.setExisting(true); await service.setTruncated(true)
        let existing = await model.setFavorite(path: service.path, name: "Sample.txt", removing: false)
        XCTAssertTrue(existing)
        await service.setExisting(false)
        let add = await model.setFavorite(path: service.path, name: "Sample.txt", removing: false)
        let remove = await model.setFavorite(path: service.path, name: "Sample.txt", removing: true)
        XCTAssertFalse(add); XCTAssertFalse(remove)
        let calls = await service.calls; XCTAssertTrue(calls.isEmpty)
    }

    func test未知写重启后禁止重放且读取原目标恢复() async throws {
        let service = FavoriteFixture(), root = newRoot(), model = try make(service, root: root)
        await service.setUnknown(true)
        let added = await model.setFavorite(path: service.path, name: "Sample.txt", removing: false)
        XCTAssertFalse(added); XCTAssertTrue(model.isBlocked(service.path))
        let restored = try make(service, root: root)
        _ = await restored.setFavorite(path: service.path, name: "Sample.txt", removing: false)
        await restored.refreshPending(); XCTAssertEqual(restored.pending.count, 1)
        await service.setExisting(true); await restored.refreshPending(); XCTAssertTrue(restored.pending.isEmpty)
        let calls = await service.calls; XCTAssertEqual(calls, [false])
        let saved = try String(contentsOf: root.appendingPathComponent("favorites-v1.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("synthetic-account")); XCTAssertFalse(saved.contains("nas.example.invalid"))
    }

    func test未知移除缺失只有完整清单才可结束() async throws {
        let service = FavoriteFixture(), model = try make(service)
        await service.setExisting(true); await service.setUnknown(true)
        _ = await model.setFavorite(path: service.path, name: "Sample.txt", removing: true)
        await service.setExisting(false); await service.setTruncated(true)
        await model.refreshPending(); XCTAssertTrue(model.isBlocked(service.path))
        await service.setTruncated(false); await model.refreshPending(); XCTAssertFalse(model.isBlocked(service.path))
        let calls = await service.calls; XCTAssertEqual(calls, [true])
    }

    func test损坏和无法保存的记录不触发写入且保留原件() async throws {
        for corrupt in [true, false] {
            let service = FavoriteFixture(), root = newRoot()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let target = root.appendingPathComponent(corrupt ? "favorites-v1.json" : "not-directory")
            let data = Data("synthetic-invalid".utf8); try data.write(to: target)
            let model = try make(service, root: corrupt ? root : target)
            _ = await model.setFavorite(path: service.path, name: "Sample.txt", removing: false)
            XCTAssertTrue(model.recoveryFailed); XCTAssertEqual(try Data(contentsOf: target), data)
            let calls = await service.calls; XCTAssertTrue(calls.isEmpty)
        }
    }

    func test重复点击不重复写且迟到回执不影响新账号() async throws {
        let service = FavoriteFixture(), next = FavoriteFixture(), model = try make(service)
        await service.setWaiting(true)
        let task = Task { await model.setFavorite(path: service.path, name: "Sample.txt", removing: false) }
        for _ in 0..<100 {
            if await service.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await service.started; XCTAssertTrue(started)
        _ = await model.setFavorite(path: service.path, name: "Sample.txt", removing: false)
        model.configure(profile: try profile(next.profileID), repository: next)
        await service.release()
        let result = await task.value; XCTAssertFalse(result); XCTAssertNil(model.feedback); XCTAssertFalse(model.busy)
        let calls = await service.calls; XCTAssertEqual(calls, [false])
    }

    func test旧账号记录和仓库身份不串到新会话() async throws {
        let service = FavoriteFixture(), model = try make(service)
        await service.setUnknown(true)
        _ = await model.setFavorite(path: service.path, name: "Sample.txt", removing: false)
        model.configure(profile: try profile(service.profileID, account: "other-account"), repository: service)
        XCTAssertTrue(model.pending.isEmpty)
        model.configure(profile: try profile(UUID()), repository: service)
        XCTAssertFalse(model.available)
    }

    func test拒绝无效位置和不可读取文件且明确权限失败释放目标() async throws {
        let service = FavoriteFixture(), model = try make(service)
        for path in ["/", "/fixture/#recycle/a", "/fixture/../a", "davs://remote", "/fixture//a"] {
            _ = await model.setFavorite(path: path, name: "Sample", removing: false)
        }
        await service.setReadable(false)
        _ = await model.setFavorite(path: service.path, name: "Sample.txt", removing: false)
        var calls = await service.calls; XCTAssertTrue(calls.isEmpty)
        await service.setReadable(true); await service.setDenied(true)
        let allowed = await model.setFavorite(path: service.path, name: "Sample.txt", removing: false)
        XCTAssertFalse(allowed); XCTAssertTrue(model.pending.isEmpty); XCTAssertNotNil(model.feedback)
        calls = await service.calls; XCTAssertEqual(calls.count, 1)
    }

    private func newRoot() -> URL { let root = FileManager.default.temporaryDirectory.appendingPathComponent("FavoriteTests-\(UUID())"); roots.append(root); return root }
    private func make(_ service: FavoriteFixture, root: URL? = nil) throws -> MobileFavoritesModel {
        let model = MobileFavoritesModel(rootURL: root ?? newRoot()); model.configure(profile: try profile(service.profileID), repository: service); return model
    }
    private func profile(_ id: UUID, account: String = "synthetic-account") throws -> NasProfile {
        try .init(id: id, displayName: "Synthetic", host: "nas.example.invalid", port: 5001, usernameHint: account)
    }
}

private actor FavoriteFixture: MobileFavoriteServing {
    nonisolated let profileID = UUID()
    nonisolated let path = "/fixture/Sample.txt"
    private var existing = false, truncated = false, unknown = false, readable = true, denied = false, waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls: [Bool] = []
    private(set) var started = false
    func setExisting(_ value: Bool) { existing = value }
    func setTruncated(_ value: Bool) { truncated = value }
    func setUnknown(_ value: Bool) { unknown = value }
    func setReadable(_ value: Bool) { readable = value }
    func setDenied(_ value: Bool) { denied = value }
    func setWaiting(_ value: Bool) { waiting = value }
    func release() { continuation?.resume(); continuation = nil }
    func listFavoritesPage(offset: Int, limit: Int) async throws -> FileFavoritePage {
        let rows: [FavoriteLocation] = existing ? [.init(name: "Sample.txt", path: path)] : []
        return .init(locations: rows, offset: 0, nextOffset: rows.count, total: rows.count,
                     sourceTotal: truncated ? 5_001 : rows.count, hasMore: false, isTruncated: truncated)
    }
    func getInfo(paths: [String]) async throws -> [FileItem] {
        readable ? [.init(profileID: profileID, name: "Sample.txt", path: path, kind: .file)] : []
    }
    func addFavoriteResult(path: String, name: String) async throws -> MutationResult { try await change(removing: false) }
    func removeFavoriteResult(path: String) async throws -> MutationResult { try await change(removing: true) }
    private func change(removing: Bool) async throws -> MutationResult {
        calls.append(removing); started = true
        if waiting { await withCheckedContinuation { continuation = $0 } }
        if !unknown && !denied { existing = !removing }
        return try .init(status: denied ? .permissionDenied : unknown ? .submittedButUnverified : .confirmedSuccess,
                         operation: "favorite", submitted: true, requiresRefresh: unknown,
                         counts: .init(succeeded: !unknown && !denied ? 1 : 0, failed: denied ? 1 : 0, unknown: unknown ? 1 : 0))
    }
}

import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobilePhotoTimelineModelTests: XCTestCase {
    func test首次进入扫描一次且同空间重入不重复扫描() async {
        let profileID = UUID()
        let item = Self.item(profileID: profileID, name: "夏日.jpg", path: "/photo/夏日.jpg", kind: .image)
        let repository = TimelineRepositoryStub(result: .init(
            items: [item], scannedFolderCount: 3, skippedFolderPaths: [], sourceItemCount: 8, completion: .complete
        ))
        let model = MobilePhotoTimelineModel()
        model.activate(profileID: profileID, repository: repository, repositoryProfileID: profileID)

        await model.show(space: .shared)
        await model.show(space: .shared)

        let scanCount = await repository.scanCount()
        XCTAssertEqual(scanCount, 1)
        XCTAssertEqual(model.state.phase, .content)
        XCTAssertEqual(model.state.items, [item])
    }

    func testRepository绑定Profile不一致时保持Inactive且零请求() async {
        let profileID = UUID()
        let repository = TimelineRepositoryStub(result: .init(
            items: [], scannedFolderCount: 0, skippedFolderPaths: [], sourceItemCount: 0, completion: .complete
        ))
        let model = MobilePhotoTimelineModel()

        model.activate(profileID: profileID, repository: repository, repositoryProfileID: UUID())
        await model.show(space: .shared)

        XCTAssertNil(model.activeProfileID)
        let scanCount = await repository.scanCount()
        XCTAssertEqual(scanCount, 0)
    }

    func test离页取消搜索防抖时同步查询与派生结果() async {
        let profileID = UUID()
        let cafe = Self.item(profileID: profileID, name: "Café.jpg", path: "/photo/cafe.jpg", kind: .image)
        let other = Self.item(profileID: profileID, name: "Other.jpg", path: "/photo/other.jpg", kind: .image)
        let repository = TimelineRepositoryStub(result: .init(
            items: [cafe, other], scannedFolderCount: 1, skippedFolderPaths: [], sourceItemCount: 2, completion: .complete
        ))
        let model = MobilePhotoTimelineModel()
        model.activate(profileID: profileID, repository: repository, repositoryProfileID: profileID)
        await model.show(space: .shared)

        model.setQuery("cafe")
        model.cancelAllWork()

        XCTAssertEqual(model.state.appliedQuery, "cafe")
        XCTAssertEqual(model.visibleItems, [cafe])
    }

    func test时间排序优先创建时间再回退修改时间且未知日期最后() {
        let profileID = UUID()
        let olderCreation = Self.item(
            profileID: profileID, name: "created.jpg", path: "/photo/created.jpg", kind: .image,
            createdAt: Date(timeIntervalSince1970: 100), modifiedAt: Date(timeIntervalSince1970: 900)
        )
        let modifiedOnly = Self.item(
            profileID: profileID, name: "modified.mov", path: "/photo/modified.mov", kind: .video,
            modifiedAt: Date(timeIntervalSince1970: 500)
        )
        let unknown = Self.item(profileID: profileID, name: "unknown.jpg", path: "/photo/unknown.jpg", kind: .image)

        XCTAssertEqual(
            MobilePhotoTimelineState.sorted([unknown, olderCreation, modifiedOnly]).map(\.name),
            ["modified.mov", "created.jpg", "unknown.jpg"]
        )
    }

    func test搜索忽略大小写与音调符号且本地媒体筛选包含视频() {
        let profileID = UUID()
        var state = MobilePhotoTimelineState(
            phase: .content,
            items: [
                Self.item(profileID: profileID, name: "Café.JPG", path: "/photo/cafe.jpg", kind: .image),
                Self.item(profileID: profileID, name: "CAFETERIA.mov", path: "/photo/cafeteria.mov", kind: .video)
            ],
            query: "cafe",
            appliedQuery: "cafe",
            filter: .all,
            hasCompletedScan: true
        )

        XCTAssertEqual(Set(state.filteredItems.map(\.name)), Set(["Café.JPG", "CAFETERIA.mov"]))
        state.filter = .videos
        XCTAssertEqual(state.filteredItems.map(\.name), ["CAFETERIA.mov"])
    }

    func test截断和跳过目录分别保留可见提示状态() async {
        let profileID = UUID()
        let repository = TimelineRepositoryStub(result: .init(
            items: [Self.item(profileID: profileID, name: "一.jpg", path: "/photo/一.jpg", kind: .image)],
            scannedFolderCount: 2,
            skippedFolderPaths: ["/photo/private"],
            sourceItemCount: 10,
            completion: .truncated
        ))
        let model = MobilePhotoTimelineModel()
        model.activate(profileID: profileID, repository: repository, repositoryProfileID: profileID)

        await model.show(space: .shared)

        XCTAssertTrue(model.state.isTruncated)
        XCTAssertTrue(model.state.isPartial)
        XCTAssertEqual(model.state.skippedFolderPaths.count, 1)
    }

    func test取消前台扫描回到未扫描状态且不会形成完成快照() async {
        let profileID = UUID()
        let repository = TimelineRepositoryStub(
            result: .init(items: [], scannedFolderCount: 0, skippedFolderPaths: [], sourceItemCount: 0, completion: .complete),
            blocksUntilCancelled: true
        )
        let model = MobilePhotoTimelineModel()
        model.activate(profileID: profileID, repository: repository, repositoryProfileID: profileID)
        let task = Task { await model.show(space: .shared) }
        while await repository.scanCount() == 0 { await Task.yield() }

        model.cancel()
        await task.value

        XCTAssertEqual(model.state.phase, .idle)
        XCTAssertFalse(model.state.hasCompletedScan)
    }

    func test已有快照刷新收到增量后取消仍精确保留旧项目() async {
        let profileID = UUID()
        let old = Self.item(profileID: profileID, name: "旧.jpg", path: "/photo/旧.jpg", kind: .image)
        let incoming = Self.item(profileID: profileID, name: "新.jpg", path: "/photo/新.jpg", kind: .image)
        let repository = TimelineRepositoryStub(
            results: [
                .init(items: [old], scannedFolderCount: 1, skippedFolderPaths: [], sourceItemCount: 1, completion: .complete),
                .init(items: [incoming], scannedFolderCount: 2, skippedFolderPaths: [], sourceItemCount: 2, completion: .complete)
            ],
            blocksOnScan: 2
        )
        let model = MobilePhotoTimelineModel()
        model.activate(profileID: profileID, repository: repository, repositoryProfileID: profileID)
        await model.show(space: .shared)

        let refresh = Task { await model.refresh() }
        while await repository.updateCount() < 2 { await Task.yield() }
        model.setQuery("新")
        model.setFilter(.videos)
        model.cancel()
        await refresh.value

        XCTAssertEqual(model.state.items, [old])
        XCTAssertEqual(model.state.phase, .content)
        XCTAssertEqual(model.state.query, "新")
        XCTAssertEqual(model.state.filter, .videos)
    }

    func test已有快照刷新收到增量后失败仍精确保留旧项目() async {
        let profileID = UUID()
        let old = Self.item(profileID: profileID, name: "旧.jpg", path: "/photo/旧.jpg", kind: .image)
        let incoming = Self.item(profileID: profileID, name: "新.jpg", path: "/photo/新.jpg", kind: .image)
        let repository = TimelineRepositoryStub(
            results: [
                .init(items: [old], scannedFolderCount: 1, skippedFolderPaths: [], sourceItemCount: 1, completion: .complete),
                .init(items: [incoming], scannedFolderCount: 2, skippedFolderPaths: [], sourceItemCount: 2, completion: .complete)
            ],
            failsOnScan: 2
        )
        let model = MobilePhotoTimelineModel()
        model.activate(profileID: profileID, repository: repository, repositoryProfileID: profileID)
        await model.show(space: .shared)

        await model.refresh()

        XCTAssertEqual(model.state.items, [old])
        XCTAssertEqual(model.state.phase, .content)
        XCTAssertTrue(model.state.refreshFailed)
    }

    func test扫描进行中重复刷新不会覆盖稳定基线或发起第二请求() async {
        let profileID = UUID()
        let old = Self.item(profileID: profileID, name: "旧.jpg", path: "/photo/旧.jpg", kind: .image)
        let incoming = Self.item(profileID: profileID, name: "新.jpg", path: "/photo/新.jpg", kind: .image)
        let repository = TimelineRepositoryStub(
            results: [
                .init(items: [old], scannedFolderCount: 1, skippedFolderPaths: [], sourceItemCount: 1, completion: .complete),
                .init(items: [incoming], scannedFolderCount: 2, skippedFolderPaths: [], sourceItemCount: 2, completion: .complete)
            ],
            blocksOnScan: 2
        )
        let model = MobilePhotoTimelineModel()
        model.activate(profileID: profileID, repository: repository, repositoryProfileID: profileID)
        await model.show(space: .shared)

        let firstRefresh = Task { await model.refresh() }
        while await repository.updateCount() < 2 { await Task.yield() }
        await model.refresh()
        let scanCount = await repository.scanCount()
        XCTAssertEqual(scanCount, 2)
        model.cancel()
        await firstRefresh.value

        XCTAssertEqual(model.state.items, [old])
        XCTAssertEqual(model.state.phase, .content)
    }

    func test缩略图只使用当前快照的Canonical项目和版本() async {
        let profileID = UUID()
        let canonical = Self.item(
            profileID: profileID,
            name: "新.jpg",
            path: "/photo/item.jpg",
            kind: .image,
            modifiedAt: Date(timeIntervalSince1970: 200),
            sizeBytes: 200
        )
        let stale = Self.item(
            profileID: profileID,
            name: "旧.jpg",
            path: canonical.path,
            kind: .image,
            modifiedAt: Date(timeIntervalSince1970: 100),
            sizeBytes: 100
        )
        let repository = TimelineRepositoryStub(result: .init(
            items: [canonical], scannedFolderCount: 1, skippedFolderPaths: [], sourceItemCount: 1, completion: .complete
        ))
        let model = MobilePhotoTimelineModel()
        model.activate(profileID: profileID, repository: repository, repositoryProfileID: profileID)
        await model.show(space: .shared)

        _ = await model.thumbnailData(for: stale)

        let requestedThumbnail = await repository.requestedThumbnailItem()
        XCTAssertEqual(requestedThumbnail, canonical)
    }

    func test切换Profile后不合作旧扫描结果不能回写() async {
        let profileA = UUID()
        let profileB = UUID()
        let oldItem = Self.item(profileID: profileA, name: "A.jpg", path: "/photo/A.jpg", kind: .image)
        let repositoryA = TimelineRepositoryStub(
            results: [.init(items: [oldItem], scannedFolderCount: 1, skippedFolderPaths: [], sourceItemCount: 1, completion: .complete)],
            blocksOnScan: 1,
            ignoresCancellation: true
        )
        let repositoryB = TimelineRepositoryStub(result: .init(
            items: [], scannedFolderCount: 0, skippedFolderPaths: [], sourceItemCount: 0, completion: .complete
        ))
        let model = MobilePhotoTimelineModel()
        model.activate(profileID: profileA, repository: repositoryA, repositoryProfileID: profileA)
        let oldScan = Task { await model.show(space: .shared) }
        while await repositoryA.updateCount() == 0 { await Task.yield() }

        model.activate(profileID: profileB, repository: repositoryB, repositoryProfileID: profileB)
        await oldScan.value

        XCTAssertEqual(model.activeProfileID, profileB)
        XCTAssertTrue(model.state.items.isEmpty)
        XCTAssertFalse(model.state.hasCompletedScan)
    }

    private static func item(
        profileID: UUID,
        name: String,
        path: String,
        kind: PhotoLibraryItemKind,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        sizeBytes: Int64? = nil
    ) -> PhotoLibraryItem {
        PhotoLibraryItem(
            id: path,
            profileID: profileID,
            name: name,
            path: path,
            kind: kind,
            sizeBytes: sizeBytes,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            fileExtension: URL(fileURLWithPath: path).pathExtension,
            thumbnailAvailable: kind == .image
        )
    }
}

private actor TimelineRepositoryStub: PhotoLibraryRepository {
    private let results: [PhotoTimelineScanResult]
    private let blocksOnScan: Int?
    private let failsOnScan: Int?
    private let ignoresCancellation: Bool
    private var scans = 0
    private var updates = 0
    private var thumbnailItem: PhotoLibraryItem?

    init(result: PhotoTimelineScanResult, blocksUntilCancelled: Bool = false) {
        self.results = [result]
        self.blocksOnScan = blocksUntilCancelled ? 1 : nil
        self.failsOnScan = nil
        self.ignoresCancellation = false
    }

    init(
        results: [PhotoTimelineScanResult],
        blocksOnScan: Int? = nil,
        failsOnScan: Int? = nil,
        ignoresCancellation: Bool = false
    ) {
        self.results = results
        self.blocksOnScan = blocksOnScan
        self.failsOnScan = failsOnScan
        self.ignoresCancellation = ignoresCancellation
    }

    func discoverSpaces() async throws -> [PhotoSpace] { [.shared] }

    func listFolder(in space: PhotoSpace, path: String, offset: Int, limit: Int) async throws -> PhotoLibraryPage {
        .init(folderPath: path, items: [], offset: offset, nextOffset: offset, sourceTotal: 0, hasMore: false)
    }

    func getThumbnail(for item: PhotoLibraryItem, size: ThumbnailSize) async throws -> Data {
        thumbnailItem = item
        return Data([1])
    }

    func scanTimeline(
        in space: PhotoSpace,
        startingAt folderPaths: [String],
        existingFolderItemPaths: [String: [String]],
        onUpdate: @escaping @Sendable (PhotoTimelineScanUpdate) async -> Void
    ) async throws {
        _ = try await scanTimeline(
            in: space,
            startingAt: folderPaths,
            existingFolderItemPaths: existingFolderItemPaths,
            limits: .mobileDefault,
            onUpdate: onUpdate
        )
    }

    func scanTimeline(
        in space: PhotoSpace,
        startingAt folderPaths: [String],
        existingFolderItemPaths: [String: [String]],
        limits: PhotoTimelineScanLimits,
        onUpdate: @escaping @Sendable (PhotoTimelineScanUpdate) async -> Void
    ) async throws -> PhotoTimelineScanResult {
        scans += 1
        let scanNumber = scans
        let result = results[min(scanNumber - 1, results.count - 1)]
        await onUpdate(.init(
            items: result.items,
            scannedFolderCount: result.scannedFolderCount,
            skippedFolderPaths: result.skippedFolderPaths
        ))
        updates += 1
        if failsOnScan == scanNumber {
            throw AppError(category: .networkUnavailable, isRetryable: true, safeUserMessage: "test")
        }
        if blocksOnScan == scanNumber {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch where !ignoresCancellation {
                throw error
            } catch {
                // 模拟底层请求不合作：仍返回结果，验证 generation/profile 门禁。
            }
        }
        return result
    }

    func scanCount() -> Int { scans }
    func updateCount() -> Int { updates }
    func requestedThumbnailItem() -> PhotoLibraryItem? { thumbnailItem }
}

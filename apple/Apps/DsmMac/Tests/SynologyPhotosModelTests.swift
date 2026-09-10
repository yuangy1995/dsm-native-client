import DsmCore
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class SynologyPhotosModelTests: XCTestCase {
    func test时间轴直接定位且可从较早月份返回较新月份() async {
        let repository = PhotoServiceStub(pages: [[Self.photo], [], []], days: [
            .init(year: 2026, month: 9, day: 1, itemCount: 1),
            .init(year: 2025, month: 10, day: 1, itemCount: 1)
        ])
        let model = SynologyPhotosModel(repository: repository)
        await model.refresh()
        XCTAssertEqual(model.timelineMonths.map(\.id), [202609, 202510])
        await model.jumpToMonth(.init(year: 2025, month: 10))
        await model.jumpToMonth(.init(year: 2026, month: 9))
        let queries = await repository.requestedQueries
        XCTAssertEqual(queries.count, 3)
        guard case .timeline(_, let older) = queries[1], case .timeline(_, let newer) = queries[2] else { return XCTFail("应直接按时间查询") }
        XCTAssertGreaterThan(newer, older)
        XCTAssertEqual(model.timelineMonths.count, 2)
    }
    func test筛选候选失败不污染照片列表的错误状态() async {
        let repository = PhotoServiceStub(pages: [[Self.photo]])
        let model = SynologyPhotosModel(repository: repository)
        await model.refresh()
        await model.loadFilterOptions()
        XCTAssertNotNil(model.filterOptionsErrorMessage)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoadingFilterOptions)
        XCTAssertEqual(model.items, [Self.photo])
    }
    func test自动分页每次只读取下一页且重复结果停住() async {
        let repository = PhotoServiceStub(pages: [[Self.photo], [Self.photo], []])
        let model = SynologyPhotosModel(repository: repository, pageSize: 1)
        await model.loadIfNeeded()
        let initialCount = await repository.pageRequestCount
        XCTAssertEqual(initialCount, 1)
        await model.loadNextPageAutomatically()
        XCTAssertNotNil(model.errorMessage)
        await model.loadNextPageAutomatically()
        let count = await repository.pageRequestCount
        XCTAssertEqual(count, 2)
    }

    func test时间线按日期分组且没有普通相册也显示系统分类() async {
        let repository = PhotoServiceStub(pages: [[Self.photo]])
        let model = SynologyPhotosModel(repository: repository)
        await model.refresh()
        XCTAssertEqual(model.datedGroups.count, 1)
        XCTAssertEqual(model.datedGroups.first?.photos, [Self.photo])
        await model.selectSection(.albums)
        XCTAssertTrue(model.collections.isEmpty)
        XCTAssertEqual(model.availableCategories.count, 6)
        XCTAssertTrue(model.showsCategories)
    }
    func test刷新清除已删除照片而不是按数量合并() async {
        let repository = PhotoServiceStub(pages: [[Self.photo], []])
        let model = SynologyPhotosModel(repository: repository)
        await model.refresh()
        XCTAssertEqual(model.items, [Self.photo])
        await model.refresh()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.errorMessage)
    }

    func test旧刷新迟到不能恢复已删除照片() async {
        let repository = PhotoServiceStub(pages: [[]], holdsFirstPage: true)
        let model = SynologyPhotosModel(repository: repository)
        let first = Task { await model.refresh() }
        await repository.waitForHeldPage()
        await model.refresh()
        XCTAssertTrue(model.items.isEmpty)
        await repository.releasePage([Self.photo])
        await first.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func test离开页面后旧请求不得写回() async {
        let repository = PhotoServiceStub(pages: [], holdsFirstPage: true)
        let model = SynologyPhotosModel(repository: repository)
        let request = Task { await model.refresh() }
        await repository.waitForHeldPage()
        model.cancel()
        await repository.releasePage([Self.photo])
        await request.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func test空时间线不额外扫描或读取媒体() async {
        let repository = PhotoServiceStub(pages: [], days: [])
        let model = SynologyPhotosModel(repository: repository)
        await model.refresh()
        let count = await repository.pageRequestCount
        XCTAssertEqual(count, 0)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertTrue(model.items.isEmpty)
    }

    func test翻页沿用套件偏移而不是去重后数量() async {
        let repository = PhotoServiceStub(pages: [[Self.photo], [Self.photo], []])
        let model = SynologyPhotosModel(repository: repository, pageSize: 1)
        await model.refresh()
        await model.loadMore()
        XCTAssertEqual(model.items.count, 1)
        await model.loadMore()
        let offsets = await repository.requestedOffsets
        XCTAssertEqual(offsets, [0, 1, 2])
        XCTAssertFalse(model.hasMore)
    }

    func test未加载失败可以重试() async {
        let repository = PhotoServiceStub(pages: [[Self.photo]], failsFirstAccess: true)
        let model = SynologyPhotosModel(repository: repository)
        await model.loadIfNeeded()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.hasLoaded)
        await model.loadIfNeeded()
        XCTAssertEqual(model.items, [Self.photo])
        XCTAssertNil(model.errorMessage)
    }

    func test重新进入页面重新核对而不永久保留旧照片() async {
        let repository = PhotoServiceStub(pages: [[Self.photo], []])
        let model = SynologyPhotosModel(repository: repository)
        await model.loadIfNeeded()
        XCTAssertEqual(model.items.count, 1)
        model.cancel()
        await model.loadIfNeeded()
        XCTAssertTrue(model.items.isEmpty)
        let count = await repository.pageRequestCount
        XCTAssertEqual(count, 2)
    }

    private static let photo = SynologyPhoto(
        id: SynologyPhotoID(profileID: UUID(), space: .personal, unitID: 7),
        filename: "sample.jpg", sizeBytes: 128,
        takenAt: Date(timeIntervalSince1970: 10), indexedAt: Date(timeIntervalSince1970: 20),
        folderID: 9, mediaType: "photo"
    )
}

private actor PhotoServiceStub: SynologyPhotosServing {
    var pageRequestCount = 0
    var requestedOffsets: [Int] = []
    var requestedQueries: [SynologyPhotoQuery] = []
    private var pages: [[SynologyPhoto]]
    private let days: [SynologyPhotoDay]
    private var holdsFirstPage: Bool
    private var failsFirstAccess: Bool
    private var held: CheckedContinuation<[SynologyPhoto], Never>?
    private var ready: CheckedContinuation<Void, Never>?

    init(
        pages: [[SynologyPhoto]], holdsFirstPage: Bool = false,
        days: [SynologyPhotoDay] = [SynologyPhotoDay(year: 2020, month: 1, day: 1, itemCount: 1)],
        failsFirstAccess: Bool = false
    ) {
        self.pages = pages
        self.holdsFirstPage = holdsFirstPage
        self.days = days
        self.failsFirstAccess = failsFirstAccess
    }

    func access() async throws -> SynologyPhotosAccess {
        if failsFirstAccess {
            failsFirstAccess = false
            throw URLError(.notConnectedToInternet)
        }
        return SynologyPhotosAccess(spaces: [.personal], packageVersion: "1.8.2-10090")
    }

    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { days }
    func categories() async throws -> Set<SynologyPhotoCategory> { Set(SynologyPhotoCategory.allCases) }
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { [] }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { days }

    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        pageRequestCount += 1
        requestedOffsets.append(offset)
        requestedQueries.append(query)
        let items: [SynologyPhoto]
        if holdsFirstPage {
            holdsFirstPage = false
            items = await withCheckedContinuation { continuation in
                held = continuation
                ready?.resume()
                ready = nil
            }
        } else {
            items = pages.isEmpty ? [] : pages.removeFirst()
        }
        return SynologyPhotoPage(items: items, offset: offset, nextOffset: offset + items.count, hasMore: items.count == limit)
    }

    func thumbnail(for photo: SynologyPhoto) async throws -> Data { Data() }

    func waitForHeldPage() async {
        if held != nil { return }
        await withCheckedContinuation { ready = $0 }
    }

    func releasePage(_ items: [SynologyPhoto]) {
        held?.resume(returning: items)
        held = nil
    }
}

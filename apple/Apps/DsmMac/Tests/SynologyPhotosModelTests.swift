import DsmCore
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class SynologyPhotosModelTests: XCTestCase {
    func test时间轴按日期定位且不依赖时间轴数量() async {
        let repository = DatePhotoServiceStub()
        let model = SynologyPhotosModel(repository: repository, pageSize: 2)
        await model.refresh()
        await model.jumpToMonth(.init(year: 2014, month: 8))
        XCTAssertEqual(model.items.map(\.id.unitID), [4, 5])
        await model.jumpToMonth(.init(year: 2026, month: 9))
        XCTAssertEqual(model.items.map(\.id.unitID), [1, 2])
        let requests = await repository.requests
        XCTAssertEqual(requests.map(\.offset), [0, 0, 0])
        XCTAssertEqual(requests[1].end, Self.timestamp(2014, 9, 1) - 1)
        XCTAssertFalse(model.hasPrevious)
    }

    func test向上按时间补齐同月多页且向下继续原来的分页() async {
        let repository = DatePhotoServiceStub()
        let model = SynologyPhotosModel(repository: repository, pageSize: 2)
        await model.refresh()
        await model.jumpToMonth(.init(year: 2014, month: 8))
        await model.loadPreviousPage()
        XCTAssertEqual(model.items.map(\.id.unitID), [1, 2, 3, 4, 5])
        XCTAssertFalse(model.hasPrevious)
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id.unitID), [1, 2, 3, 4, 5, 6])
        let requests = await repository.requests
        XCTAssertEqual(requests.map(\.offset), [0, 0, 0, 2, 2])
        XCTAssertEqual(requests[2].start, Self.timestamp(2014, 9, 1))
        XCTAssertEqual(requests[2].end, min(requests[0].end, Self.timestamp(2026, 10, 1) - 1))
        XCTAssertEqual(requests[4].end, requests[1].end)
    }

    func test搜索跳转与向上加载保留关键词() async {
        let repository = DatePhotoServiceStub()
        let model = SynologyPhotosModel(repository: repository, pageSize: 2)
        model.searchText = "sample"
        await model.refresh()
        await model.jumpToMonth(.init(year: 2014, month: 8))
        XCTAssertEqual(model.items.first?.id.unitID, 4)
        await model.loadPreviousPage()
        let requests = await repository.requests
        XCTAssertTrue(requests.allSatisfy { $0.keyword == "sample" })
        XCTAssertEqual(model.items.map(\.id.unitID), [1, 2, 3, 4, 5])
    }

    func test向前失败保留时间边界且重试不重复照片() async {
        let repository = DatePhotoServiceStub()
        let model = SynologyPhotosModel(repository: repository, pageSize: 2)
        await model.refresh()
        await model.jumpToMonth(.init(year: 2014, month: 8))
        await repository.failNextPage()
        await model.loadPreviousPage()
        XCTAssertNotNil(model.previousPageErrorMessage)
        XCTAssertEqual(model.previousMonthID, 201408)
        XCTAssertEqual(model.items.map(\.id.unitID), [4, 5])
        await model.loadPreviousPage()
        XCTAssertNil(model.previousPageErrorMessage)
        XCTAssertEqual(model.items.map(\.id.unitID), [1, 2, 3, 4, 5])
    }

    func test向前分页迟到不能覆盖刷新结果且并发触发只请求一次() async {
        let repository = PhotoServiceStub(pages: [[Self.photo], [], []], days: [
            .init(year: 2026, month: 9, day: 1, itemCount: 1),
            .init(year: 2013, month: 1, day: 1, itemCount: 1)
        ])
        let model = SynologyPhotosModel(repository: repository, pageSize: 1)
        await model.refresh()
        await model.jumpToMonth(.init(year: 2013, month: 1))
        await repository.holdNextPage()
        let request = Task { await model.loadPreviousPage() }
        await repository.waitForHeldPage()
        await model.loadPreviousPage()
        let count = await repository.pageRequestCount
        XCTAssertEqual(count, 3)
        await model.refresh()
        await repository.releasePage([Self.photo])
        await request.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.hasPrevious)
        XCTAssertFalse(model.isLoadingPrevious)
    }

    private static func timestamp(_ year: Int, _ month: Int, _ day: Int) -> Int {
        Int(Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!.timeIntervalSince1970)
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

/// 根据实际时间区间和页内偏移筛选，数量故意不等于列表条数，防止再次按数量定位。
private actor DatePhotoServiceStub: SynologyPhotosServing {
    struct Request {
        let start: Int
        let end: Int
        let offset: Int
        let keyword: String?
    }
    var requests: [Request] = []
    private var failsNext = false
    private let profileID = UUID()
    func failNextPage() { failsNext = true }
    func access() async throws -> SynologyPhotosAccess {
        .init(spaces: [.personal], packageVersion: "1.8.2-10090")
    }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] {
        [.init(year: 2026, month: 9, day: 1, itemCount: 9000),
         .init(year: 2014, month: 8, day: 1, itemCount: 8000)]
    }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] {
        try await timeline(in: space)
    }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        if failsNext { failsNext = false; throw URLError(.notConnectedToInternet) }
        let start: Int, end: Int, keyword: String?
        switch query {
        case .timeline(let lower, let upper): (start, end, keyword) = (lower, upper, nil)
        case .search(let text, let lower, let upper): (start, end, keyword) = (lower, upper, text)
        default: throw URLError(.badURL)
        }
        requests.append(.init(start: start, end: end, offset: offset, keyword: keyword))
        let calendar = Calendar(identifier: .gregorian)
        let all = (1...6).map { index in
            let date = calendar.date(from: DateComponents(year: index <= 3 ? 2026 : 2014, month: index <= 3 ? 9 : 8, day: 1, hour: 12))!
            return SynologyPhoto(id: .init(profileID: profileID, space: .personal, unitID: index),
                                 filename: "sample-\(index).jpg", sizeBytes: 128,
                                 takenAt: date, indexedAt: date, folderID: 9, mediaType: "photo")
        }
        let matches = all.filter { (start...end).contains(Int($0.takenAt.timeIntervalSince1970)) }
        let page = Array(matches.dropFirst(offset).prefix(limit))
        return .init(items: page, offset: offset, nextOffset: offset + page.count, hasMore: page.count == limit)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { Data() }
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

    func holdNextPage() { holdsFirstPage = true }

    func releasePage(_ items: [SynologyPhoto]) {
        held?.resume(returning: items)
        held = nil
    }
}

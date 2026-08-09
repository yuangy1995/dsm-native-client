@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

private actor FileBrowserRepositoryStub: MobileFileBrowsing {
    nonisolated let profileID: UUID
    private var pages: [FilePage]
    private var pageDelays: [UInt64]
    private var searchResults: [String: (UInt64, [FileItem])]
    private var optionPages: [FileListOptions: (UInt64, FilePage)]
    private(set) var pageCalls: [(String, Int, Int, FileListOptions)] = []

    init(
        profileID: UUID,
        pages: [FilePage] = [],
        pageDelays: [UInt64] = [],
        searchResults: [String: (UInt64, [FileItem])] = [:],
        optionPages: [FileListOptions: (UInt64, FilePage)] = [:]
    ) {
        self.profileID = profileID
        self.pages = pages
        self.pageDelays = pageDelays
        self.searchResults = searchResults
        self.optionPages = optionPages
    }

    func listShares(offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage {
        try await nextPage(path: "", offset: offset, limit: limit, options: options)
    }

    func listFolder(path: String, offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage {
        try await nextPage(path: path, offset: offset, limit: limit, options: options)
    }

    func search(folderPath: String, query: String) async throws -> [FileItem] {
        let response = searchResults[query] ?? (0, [])
        if response.0 > 0 {
            try? await Task.sleep(nanoseconds: response.0)
        }
        return response.1
    }

    func calls() -> [(String, Int, Int, FileListOptions)] { pageCalls }

    private func nextPage(
        path: String,
        offset: Int,
        limit: Int,
        options: FileListOptions
    ) async throws -> FilePage {
        pageCalls.append((path, offset, limit, options))
        if let response = optionPages[options] {
            if response.0 > 0 { try? await Task.sleep(nanoseconds: response.0) }
            return response.1
        }
        guard !pages.isEmpty else { throw StubError.noPage }
        if !pageDelays.isEmpty {
            let delay = pageDelays.removeFirst()
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        }
        return pages.removeFirst()
    }

    private enum StubError: Error { case noPage }
}

@MainActor
final class MobileFileBrowserModelTests: XCTestCase {
    func test分页使用服务端偏移并按完整路径去重() async {
        let profileID = UUID()
        let first = item(profileID, "a", "/share/a")
        let second = item(profileID, "b", "/share/b")
        let repository = FileBrowserRepositoryStub(profileID: profileID, pages: [
            page(path: "", items: [first], offset: 0, total: 3, hasMore: true),
            page(path: "", items: [first, second], offset: 1, total: 3, hasMore: false)
        ])
        let model = MobileFileBrowserModel()

        await model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)
        await model.loadMore(repository: repository)

        XCTAssertEqual(model.state.page.items.map(\.path), ["/share/a", "/share/b"])
        XCTAssertFalse(model.state.page.hasMore)
        let calls = await repository.calls()
        XCTAssertEqual(calls.map(\.1), [0, 1])
        XCTAssertEqual(calls.map(\.2), [MobileFileBrowserModel.pageSize, MobileFileBrowserModel.pageSize])
        XCTAssertEqual(calls.map(\.3), [.default, .default])
    }

    func test加载更多错位失败保留既有内容并允许重试() async {
        let profileID = UUID()
        let first = item(profileID, "a", "/share/a")
        let repository = FileBrowserRepositoryStub(profileID: profileID, pages: [
            page(path: "", items: [first], offset: 0, total: 2, hasMore: true),
            page(path: "", items: [], offset: 99, total: 2, hasMore: false)
        ])
        let model = MobileFileBrowserModel()

        await model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)
        await model.loadMore(repository: repository)

        XCTAssertEqual(model.state.page.items, [first])
        XCTAssertEqual(model.state.pageState, .content)
        XCTAssertTrue(model.state.loadMoreFailed)
    }

    func testHasMore却无新增路径视为零进展() async {
        let profileID = UUID()
        let first = item(profileID, "a", "/share/a")
        let repository = FileBrowserRepositoryStub(profileID: profileID, pages: [
            page(path: "", items: [first], offset: 0, total: 3, hasMore: true),
            page(path: "", items: [first], offset: 1, total: 3, hasMore: true)
        ])
        let model = MobileFileBrowserModel()

        await model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)
        await model.loadMore(repository: repository)

        XCTAssertTrue(model.state.loadMoreFailed)
        XCTAssertEqual(model.state.page.items, [first])
    }

    func test分页总数与HasMore不一致时拒绝结果() async {
        let profileID = UUID()
        let first = item(profileID, "a", "/share/a")
        let repository = FileBrowserRepositoryStub(profileID: profileID, pages: [
            page(path: "", items: [first], offset: 0, total: 2, hasMore: false)
        ])
        let model = MobileFileBrowserModel()

        await model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)

        XCTAssertEqual(model.state.pageState, .error)
        XCTAssertTrue(model.state.page.items.isEmpty)
    }

    func test刷新期间保留当前内容() async {
        let profileID = UUID()
        let first = item(profileID, "a", "/share/a")
        let updated = item(profileID, "b", "/share/b")
        let repository = FileBrowserRepositoryStub(
            profileID: profileID,
            pages: [
                page(path: "", items: [first], offset: 0, total: 1, hasMore: false),
                page(path: "", items: [updated], offset: 0, total: 1, hasMore: false)
            ],
            pageDelays: [0, 150_000_000]
        )
        let model = MobileFileBrowserModel()
        await model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)

        let refreshTask = Task { await model.refresh(repository: repository) }
        await Task.yield()
        XCTAssertEqual(model.state.page.items, [first])
        XCTAssertEqual(model.state.pageState, .content)
        XCTAssertTrue(model.state.isRefreshing)
        await refreshTask.value
        XCTAssertEqual(model.state.page.items, [updated])
    }

    func test迟到的旧搜索不能覆盖新查询() async {
        let profileID = UUID()
        let old = item(profileID, "old", "/share/old")
        let fresh = item(profileID, "fresh", "/share/fresh")
        let repository = FileBrowserRepositoryStub(
            profileID: profileID,
            searchResults: [
                "old": (150_000_000, [old]),
                "new": (0, [fresh])
            ]
        )
        let model = MobileFileBrowserModel()
        await model.activate(profileID: profileID, repository: repository)

        model.setQuery("old")
        let oldTask = Task { await model.submitSearch(repository: repository) }
        await Task.yield()
        model.setQuery("new")
        await model.submitSearch(repository: repository)
        await oldTask.value

        XCTAssertEqual(model.state.query, "new")
        XCTAssertEqual(model.state.page.items, [fresh])
        XCTAssertEqual(model.state.pageState, .content)
    }

    func test慢搜索返回前清空查询会恢复目录缓存() async {
        let profileID = UUID()
        let root = item(profileID, "root", "/root")
        let stale = item(profileID, "stale", "/stale")
        let repository = FileBrowserRepositoryStub(
            profileID: profileID,
            pages: [page(path: "", items: [root], offset: 0, total: 1, hasMore: false)],
            searchResults: ["slow": (150_000_000, [stale])]
        )
        let model = MobileFileBrowserModel()
        await model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)

        model.setQuery("slow")
        let searchTask = Task { await model.submitSearch(repository: repository) }
        await Task.yield()
        model.setQuery("")
        await model.submitSearch(repository: repository)
        await searchTask.value

        XCTAssertEqual(model.state.query, "")
        XCTAssertEqual(model.state.page.items, [root])
        XCTAssertEqual(model.state.pageState, .content)
    }

    func test按Profile恢复目录历史查询布局及缓存页() async {
        let firstID = UUID()
        let secondID = UUID()
        let folder = item(firstID, "docs", "/docs", kind: .directory)
        let child = item(firstID, "a", "/docs/a")
        let firstRepository = FileBrowserRepositoryStub(profileID: firstID, pages: [
            page(path: "", items: [folder], offset: 0, total: 1, hasMore: false),
            page(path: "/docs", items: [child], offset: 0, total: 1, hasMore: false),
            page(path: "/docs", items: [child], offset: 0, total: 1, hasMore: false)
        ])
        let secondRepository = FileBrowserRepositoryStub(profileID: secondID)
        let model = MobileFileBrowserModel()

        await model.activate(profileID: firstID, repository: firstRepository)
        await model.refresh(repository: firstRepository)
        await model.openDirectory(folder, repository: firstRepository)
        let options = FileListOptions(sortField: .modifiedTime, typeFilter: .files)
        await model.setOptions(options, repository: firstRepository)
        model.setQuery("report")
        model.setLayout(.grid)
        await model.activate(profileID: secondID, repository: secondRepository)
        await model.activate(profileID: firstID, repository: firstRepository)

        XCTAssertEqual(model.state.currentPath, "/docs")
        XCTAssertEqual(model.state.pathHistory, [""])
        XCTAssertEqual(model.state.query, "report")
        XCTAssertEqual(model.state.layout, .grid)
        XCTAssertEqual(model.state.options, options)
        XCTAssertEqual(model.state.page.items, [child])
    }

    func test搜索无结果进入筛选空而目录无内容进入普通空() async {
        let profileID = UUID()
        let repository = FileBrowserRepositoryStub(
            profileID: profileID,
            pages: [page(path: "", items: [], offset: 0, total: 0, hasMore: false)],
            searchResults: ["none": (0, [])]
        )
        let model = MobileFileBrowserModel()
        await model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)
        XCTAssertEqual(model.state.pageState, .empty)

        model.setQuery("none")
        await model.submitSearch(repository: repository)
        XCTAssertEqual(model.state.pageState, .filteredEmpty)
    }

    func test切换Profile后恢复已加载空目录不会再次请求() async {
        let firstID = UUID()
        let secondID = UUID()
        let firstRepository = FileBrowserRepositoryStub(
            profileID: firstID,
            pages: [page(path: "", items: [], offset: 0, total: 0, hasMore: false)]
        )
        let secondRepository = FileBrowserRepositoryStub(profileID: secondID)
        let model = MobileFileBrowserModel()

        await model.activate(profileID: firstID, repository: firstRepository)
        await model.refresh(repository: firstRepository)
        await model.activate(profileID: secondID, repository: secondRepository)
        await model.activate(profileID: firstID, repository: firstRepository)

        XCTAssertEqual(model.state.pageState, .empty)
        XCTAssertNotNil(model.state.visibleKey)
        let calls = await firstRepository.calls()
        XCTAssertEqual(calls.count, 1)
    }

    func test普通目录排序筛选贯通分页且切换选项从零开始() async {
        let profileID = UUID()
        let folder = item(profileID, "docs", "/docs", kind: .directory)
        let first = item(profileID, "first", "/docs/first", size: 2)
        let second = item(profileID, "second", "/docs/second", size: 1)
        let options = FileListOptions(
            sortField: .size,
            sortDirection: .descending,
            typeFilter: .files
        )
        let repository = FileBrowserRepositoryStub(profileID: profileID, pages: [
            page(path: "", items: [folder], offset: 0, total: 1, hasMore: false),
            page(path: "/docs", items: [], offset: 0, total: 0, hasMore: false),
            page(path: "/docs", items: [first], offset: 0, total: 2, hasMore: true),
            page(path: "/docs", items: [second], offset: 1, total: 2, hasMore: false)
        ])
        let model = MobileFileBrowserModel()

        await model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)
        await model.openDirectory(folder, repository: repository)
        await model.setOptions(options, repository: repository)
        await model.loadMore(repository: repository)

        let calls = await repository.calls()
        XCTAssertEqual(calls.map(\.1), [0, 0, 0, 1])
        XCTAssertEqual(Array(calls.suffix(2)).map(\.3), [options, options])
        XCTAssertEqual(model.state.page.items.map(\.path), ["/docs/first", "/docs/second"])
    }

    func test共享根强制名称排序与全部类型但保留方向() async {
        let profileID = UUID()
        let requested = FileListOptions(
            sortField: .modifiedTime,
            sortDirection: .descending,
            typeFilter: .folders
        )
        let repository = FileBrowserRepositoryStub(profileID: profileID, pages: [
            page(path: "", items: [], offset: 0, total: 0, hasMore: false)
        ])
        let model = MobileFileBrowserModel()

        await model.activate(profileID: profileID, repository: repository)
        await model.setOptions(requested, repository: repository)

        let expected = FileListOptions(
            sortField: .name,
            sortDirection: .descending,
            typeFilter: .all
        )
        XCTAssertEqual(model.state.options, expected)
        let calls = await repository.calls()
        XCTAssertEqual(calls.map(\.3), [expected])
    }

    func test返回共享根只规范化请求并在再次进入目录后恢复偏好() async {
        let profileID = UUID()
        let folder = item(profileID, "docs", "/docs", kind: .directory)
        let child = item(profileID, "a", "/docs/a", size: 10)
        let directoryOptions = FileListOptions(
            sortField: .size,
            sortDirection: .descending,
            typeFilter: .files
        )
        let rootOptions = FileListOptions(
            sortField: .name,
            sortDirection: .descending,
            typeFilter: .all
        )
        let repository = FileBrowserRepositoryStub(profileID: profileID, pages: [
            page(path: "", items: [folder], offset: 0, total: 1, hasMore: false),
            page(path: "/docs", items: [child], offset: 0, total: 1, hasMore: false),
            page(path: "/docs", items: [child], offset: 0, total: 1, hasMore: false),
            page(path: "", items: [folder], offset: 0, total: 1, hasMore: false),
            page(path: "/docs", items: [child], offset: 0, total: 1, hasMore: false)
        ])
        let model = MobileFileBrowserModel()

        await model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)
        await model.openDirectory(folder, repository: repository)
        await model.setOptions(directoryOptions, repository: repository)
        await model.goBack(repository: repository)

        XCTAssertEqual(model.state.options, rootOptions)
        XCTAssertEqual(model.state.directoryOptions, directoryOptions)

        await model.openDirectory(folder, repository: repository)
        XCTAssertEqual(model.state.options, directoryOptions)
        await model.refresh(repository: repository)

        let calls = await repository.calls()
        XCTAssertEqual(Array(calls.suffix(2)).map(\.3), [rootOptions, directoryOptions])
    }

    func test迟到的旧排序请求不能覆盖新选项() async {
        let profileID = UUID()
        let folder = item(profileID, "docs", "/docs", kind: .directory)
        let stale = item(profileID, "stale", "/docs/stale")
        let fresh = item(profileID, "fresh", "/docs/fresh")
        let repository = FileBrowserRepositoryStub(
            profileID: profileID,
            pages: [
                page(path: "", items: [folder], offset: 0, total: 1, hasMore: false),
                page(path: "/docs", items: [], offset: 0, total: 0, hasMore: false)
            ],
            optionPages: [
                FileListOptions(sortField: .size): (
                    150_000_000,
                    page(path: "/docs", items: [stale], offset: 0, total: 1, hasMore: false)
                ),
                FileListOptions(sortField: .modifiedTime): (
                    0,
                    page(path: "/docs", items: [fresh], offset: 0, total: 1, hasMore: false)
                )
            ]
        )
        let model = MobileFileBrowserModel()
        await model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)
        await model.openDirectory(folder, repository: repository)

        let oldOptions = FileListOptions(sortField: .size)
        let newOptions = FileListOptions(sortField: .modifiedTime)
        let oldTask = Task { await model.setOptions(oldOptions, repository: repository) }
        await Task.yield()
        await model.setOptions(newOptions, repository: repository)
        await oldTask.value

        XCTAssertEqual(model.state.options, newOptions)
        XCTAssertEqual(model.state.page.items, [fresh])
    }

    func test完整搜索快照按类型和大小全局筛选排序() async {
        let profileID = UUID()
        let folder = item(profileID, "docs", "/docs", kind: .directory)
        let small = item(profileID, "small", "/docs/small", size: 1)
        let large = item(profileID, "large", "/docs/large", size: 20)
        let nestedFolder = item(profileID, "nested", "/docs/nested", kind: .directory)
        let repository = FileBrowserRepositoryStub(
            profileID: profileID,
            pages: [
                page(path: "", items: [folder], offset: 0, total: 1, hasMore: false),
                page(path: "/docs", items: [], offset: 0, total: 0, hasMore: false)
            ],
            searchResults: ["report": (0, [small, nestedFolder, large])]
        )
        let model = MobileFileBrowserModel()
        await model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)
        await model.openDirectory(folder, repository: repository)
        model.setQuery("report")

        await model.setOptions(
            FileListOptions(sortField: .size, sortDirection: .descending, typeFilter: .files),
            repository: repository
        )

        XCTAssertEqual(model.state.page.items.map(\.name), ["large", "small"])
        XCTAssertFalse(model.state.page.hasMore)
    }

    func test类型筛选无结果与查询无结果可区分() async {
        let profileID = UUID()
        let folder = item(profileID, "docs", "/docs", kind: .directory)
        let repository = FileBrowserRepositoryStub(
            profileID: profileID,
            pages: [
                page(path: "", items: [folder], offset: 0, total: 1, hasMore: false),
                page(path: "/docs", items: [], offset: 0, total: 0, hasMore: false),
                page(path: "/docs", items: [], offset: 0, total: 0, hasMore: false)
            ],
            searchResults: ["none": (0, [])]
        )
        let model = MobileFileBrowserModel()
        await model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)
        await model.openDirectory(folder, repository: repository)
        await model.setOptions(FileListOptions(typeFilter: .folders), repository: repository)

        XCTAssertEqual(model.state.pageState, .filteredEmpty)
        XCTAssertEqual(model.state.filteredEmptyReason, .typeFilter)

        model.setQuery("none")
        await model.submitSearch(repository: repository)
        XCTAssertEqual(model.state.filteredEmptyReason, .query)
    }

    func test确认变更后只在同profileRepository父目录强制刷新并清除查询() async {
        let profileID = UUID()
        let folder = item(profileID, "docs", "/docs", kind: .directory)
        let old = item(profileID, "old", "/docs/old")
        let created = item(profileID, "new", "/docs/new", kind: .directory)
        let repository = FileBrowserRepositoryStub(profileID: profileID, pages: [
            page(path: "", items: [folder], offset: 0, total: 1, hasMore: false),
            page(path: "/docs", items: [old], offset: 0, total: 1, hasMore: false),
            page(path: "/docs", items: [old, created], offset: 0, total: 2, hasMore: false),
        ])
        let model = MobileFileBrowserModel()
        await model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)
        await model.openDirectory(folder, repository: repository)
        model.setQuery("stale-query")

        await model.refreshAfterConfirmedMutation(
            MobileFileItemMutationSuccess(
                profileID: profileID,
                parentPath: "/docs",
                item: created
            ),
            repository: repository
        )

        XCTAssertEqual(model.state.query, "")
        XCTAssertEqual(model.state.page.items, [old, created])
        let calls = await repository.calls()
        XCTAssertEqual(calls.map(\.0), ["", "/docs", "/docs"])
    }

    private func item(
        _ profileID: UUID,
        _ name: String,
        _ path: String,
        kind: FileKind = .file,
        size: Int64? = nil,
        modifiedAt: Date? = nil
    ) -> FileItem {
        FileItem(
            profileID: profileID,
            name: name,
            path: path,
            kind: kind,
            sizeBytes: size,
            times: modifiedAt.map { FileTimes(modifiedAt: $0, createdAt: nil, accessedAt: nil) }
        )
    }

    private func page(
        path: String,
        items: [FileItem],
        offset: Int,
        total: Int,
        hasMore: Bool
    ) -> FilePage {
        FilePage(folderPath: path, items: items, offset: offset, total: total, hasMore: hasMore)
    }
}

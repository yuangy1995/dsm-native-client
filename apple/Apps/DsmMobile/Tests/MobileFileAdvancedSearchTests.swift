@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

private actor AdvancedSearchRepository: MobileFileBrowsing {
    nonisolated let profileID = UUID()
    var requests: [FileSearchRequest] = []
    var listCount = 0
    var basicCount = 0

    func searchWithReport(_ request: FileSearchRequest) async throws -> FileSearchResult {
        requests.append(request)
        if request.owner == "slow" { try? await Task.sleep(for: .milliseconds(120)) }
        if request.owner == "unsupported" {
            throw AppError(category: .versionUnsupported, isRetryable: false, safeUserMessage: "Search unavailable")
        }
        let items = request.owner == "empty" ? [] : [FileItem(profileID: profileID,
            name: request.fileExtension, path: "/fixture/" + request.fileExtension, kind: .file)]
        return FileSearchResult(items: items, indexCoverage: request.searchesContents ? .incomplete : .notRequested)
    }
    func search(folderPath: String, query: String) async throws -> [FileItem] { basicCount += 1; return [] }
    func listShares(offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage {
        try await listFolder(path: "", offset: offset, limit: limit, options: options)
    }
    func listFolder(path: String, offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage {
        listCount += 1
        return FilePage(folderPath: path, items: [], offset: offset, total: 0, hasMore: false)
    }
}

@MainActor
final class MobileFileAdvancedSearchTests: XCTestCase {
    func test全部条件透传并保留正文覆盖不足() async {
        let repository = AdvancedSearchRepository()
        let browser = MobileFileBrowserModel()
        await browser.activate(profileID: repository.profileID, repository: repository)
        let request = FileSearchRequest(folders: ["/fixture", "/second"], recursive: false, name: "term",
            fileExtension: "txt,pdf", kind: .file, minimumBytes: 10, maximumBytes: 20,
            modified: .init(from: Date(timeIntervalSince1970: 123)), created: .init(to: Date(timeIntervalSince1970: 456)),
            accessed: .init(from: Date(timeIntervalSince1970: 42)), owner: "reader", group: "staff", searchesContents: true)
        await browser.applyAdvancedSearch(request, repository: repository)
        let requests = await repository.requests
        XCTAssertEqual(requests, [request])
        XCTAssertEqual(browser.state.page.indexCoverage, .incomplete)
        XCTAssertEqual(browser.state.pageState, .content)
        XCTAssertFalse(browser.state.page.hasMore)
        await browser.loadMore(repository: repository)
        let count = await repository.listCount
        XCTAssertEqual(count, 0)
    }

    func test缓存区分完整条件且清空名称仍保留筛选() async {
        let repository = AdvancedSearchRepository()
        let browser = MobileFileBrowserModel()
        await browser.activate(profileID: repository.profileID, repository: repository)
        let first = FileSearchRequest(folders: ["/fixture"], fileExtension: "txt")
        let second = FileSearchRequest(folders: ["/fixture"], fileExtension: "pdf")
        await browser.applyAdvancedSearch(first, repository: repository)
        await browser.applyAdvancedSearch(second, repository: repository)
        XCTAssertEqual(browser.state.page.items.first?.name, "pdf")
        await browser.applyAdvancedSearch(first, repository: repository)
        XCTAssertEqual(browser.state.page.items.first?.name, "txt")
        browser.setQuery("new")
        await browser.submitSearch(repository: repository)
        browser.setQuery("")
        await browser.submitSearch(repository: repository)
        let requests = await repository.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.last?.name, "new")
        XCTAssertEqual(browser.state.advancedSearch, first)
    }

    func test没有名称的高级空结果仍属于筛选空() async {
        let repository = AdvancedSearchRepository()
        let browser = MobileFileBrowserModel()
        await browser.activate(profileID: repository.profileID, repository: repository)
        await browser.applyAdvancedSearch(.init(folders: ["/fixture"], owner: "empty"), repository: repository)
        XCTAssertEqual(browser.state.pageState, .filteredEmpty)
        XCTAssertEqual(browser.state.filteredEmptyReason, .query)
        await browser.applyAdvancedSearch(nil, repository: repository)
        XCTAssertEqual(browser.state.pageState, .empty)
        XCTAssertNil(browser.state.advancedSearch)
    }

    func test正文不支持保留错误且不退回名称搜索() async {
        let repository = AdvancedSearchRepository()
        let browser = MobileFileBrowserModel()
        await browser.activate(profileID: repository.profileID, repository: repository)
        await browser.applyAdvancedSearch(.init(folders: ["/fixture"], name: "term", owner: "unsupported", searchesContents: true), repository: repository)
        XCTAssertEqual(browser.state.pageState, .error)
        XCTAssertEqual(browser.state.errorMessage, "Search unavailable")
        let count = await repository.basicCount
        XCTAssertEqual(count, 0)
    }

    func test新筛选和切换账号均丢弃旧结果() async {
        let repository = AdvancedSearchRepository()
        let browser = MobileFileBrowserModel()
        await browser.activate(profileID: repository.profileID, repository: repository)
        let old = Task { await browser.applyAdvancedSearch(.init(folders: ["/fixture"], fileExtension: "old", owner: "slow"), repository: repository) }
        await Task.yield()
        await browser.applyAdvancedSearch(.init(folders: ["/fixture"], fileExtension: "new"), repository: repository)
        await old.value
        XCTAssertEqual(browser.state.page.items.first?.name, "new")
        let delayed = Task { await browser.applyAdvancedSearch(.init(folders: ["/fixture"], fileExtension: "other", owner: "slow"), repository: repository) }
        await Task.yield()
        let next = AdvancedSearchRepository()
        await browser.activate(profileID: next.profileID, repository: next)
        await delayed.value
        XCTAssertTrue(browser.state.page.items.isEmpty)
        XCTAssertNil(browser.state.advancedSearch)
    }

    func test进入文件夹清除高级条件且返回不复用搜索页() async {
        let repository = AdvancedSearchRepository()
        let browser = MobileFileBrowserModel()
        await browser.activate(profileID: repository.profileID, repository: repository)
        await browser.applyAdvancedSearch(.init(folders: ["/fixture"], fileExtension: "txt"), repository: repository)
        await browser.openDirectory(.init(profileID: repository.profileID, name: "nested", path: "/fixture/nested", kind: .directory), repository: repository)
        XCTAssertNil(browser.state.advancedSearch)
        XCTAssertEqual(browser.state.currentPath, "/fixture/nested")
        XCTAssertTrue(browser.state.page.items.isEmpty)
        await browser.goBack(repository: repository)
        XCTAssertNil(browser.state.advancedSearch)
        XCTAssertEqual(browser.state.currentPath, "")
    }

    func test失败后回到成功缓存清除旧错误且正文空词不发送请求() async {
        let repository = AdvancedSearchRepository()
        let browser = MobileFileBrowserModel()
        await browser.activate(profileID: repository.profileID, repository: repository)
        let good = FileSearchRequest(folders: ["/fixture"], name: "term", searchesContents: true)
        await browser.applyAdvancedSearch(good, repository: repository)
        browser.setQuery("")
        await browser.submitSearch(repository: repository)
        XCTAssertEqual(browser.state.pageState, .error)
        XCTAssertNotNil(browser.state.errorMessage)
        let requests = await repository.requests
        XCTAssertEqual(requests, [good])
        await browser.applyAdvancedSearch(good, repository: repository)
        XCTAssertEqual(browser.state.pageState, .content)
        XCTAssertNil(browser.state.errorMessage)
    }

    func test文件变更使其他位置发起的多目录搜索缓存失效() async {
        let repository = AdvancedSearchRepository()
        let browser = MobileFileBrowserModel()
        await browser.activate(profileID: repository.profileID, repository: repository)
        let request = FileSearchRequest(folders: ["/fixture", "/other"], fileExtension: "txt")
        await browser.applyAdvancedSearch(request, repository: repository)
        let opened = await browser.openLocation(path: "/fixture/nested", source: .browser, repository: repository)
        XCTAssertTrue(opened)
        let item = FileItem(profileID: repository.profileID, name: "new", path: "/fixture/nested/new", kind: .directory)
        await browser.refreshAfterConfirmedMutation(.init(profileID: repository.profileID, parentPath: "/fixture/nested", item: item), repository: repository)
        _ = await browser.openLocation(path: "", source: .shares, repository: repository)
        await browser.applyAdvancedSearch(request, repository: repository)
        let requests = await repository.requests
        XCTAssertEqual(requests, [request, request])
    }

    func test大小换算边界和无效日期不会创建有效请求() {
        let request = FileSearchRequest(folders: ["/fixture"])
        let valid = MobileFileAdvancedSearchView.resolve(request, minimum: "1.5", maximum: "2", unit: 1_048_576)
        XCTAssertEqual(valid?.minimumBytes, 1_572_864)
        XCTAssertEqual(valid?.maximumBytes, 2_097_152)
        for value in ["-1", "nan", "1e9", "9223372036854775808", "text"] {
            XCTAssertNil(MobileFileAdvancedSearchView.resolve(request, minimum: value, maximum: "", unit: 1), value)
        }
        XCTAssertNil(MobileFileAdvancedSearchView.resolve(request, minimum: "2", maximum: "1", unit: 1))
        XCTAssertNil(MobileFileAdvancedSearchView.resolve(.init(folders: ["/"]), minimum: "", maximum: "", unit: 1))
        XCTAssertNil(MobileFileAdvancedSearchView.resolve(.init(folders: ["/fixture"], modified: .init(from: Date(timeIntervalSince1970: 2), to: Date(timeIntervalSince1970: 1))), minimum: "", maximum: "", unit: 1))
    }
}

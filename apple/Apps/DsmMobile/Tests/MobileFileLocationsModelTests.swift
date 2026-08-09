@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

private actor MobileFileLocationsRepositoryStub: MobileFileBrowsing, MobileFileLocationBrowsing {
    enum Reply<Value: Sendable>: Sendable {
        case value(Value, UInt64 = 0)
        case failure(UInt64 = 0)
        case cancellable(Value, UInt64)
    }

    nonisolated let profileID: UUID
    private var filePages: [Reply<FilePage>]
    private var favoritePages: [Reply<FileFavoritePage>]
    private var remotePages: [Reply<FileVirtualFolderPage>]
    private var recycleResults: [Reply<FileRecycleDiscoveryResult>]
    private var observedCancellation = false
    private var filePageCallCount = 0

    init(
        profileID: UUID,
        filePages: [Reply<FilePage>] = [],
        favoritePages: [Reply<FileFavoritePage>] = [],
        remotePages: [Reply<FileVirtualFolderPage>] = [],
        recycleResults: [Reply<FileRecycleDiscoveryResult>] = []
    ) {
        self.profileID = profileID
        self.filePages = filePages
        self.favoritePages = favoritePages
        self.remotePages = remotePages
        self.recycleResults = recycleResults
    }

    func listShares(offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage {
        filePageCallCount += 1
        guard !filePages.isEmpty else { throw StubError.noReply }
        return try await resolve(filePages.removeFirst())
    }

    func listFolder(path: String, offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage {
        filePageCallCount += 1
        guard !filePages.isEmpty else { throw StubError.noReply }
        return try await resolve(filePages.removeFirst())
    }

    func search(folderPath: String, query: String) async throws -> [FileItem] { [] }

    func listFavoritesPage(offset: Int, limit: Int) async throws -> FileFavoritePage {
        guard !favoritePages.isEmpty else { throw StubError.noReply }
        return try await resolve(favoritePages.removeFirst())
    }

    func listVirtualFolders(offset: Int, limit: Int) async throws -> FileVirtualFolderPage {
        guard !remotePages.isEmpty else { throw StubError.noReply }
        return try await resolve(remotePages.removeFirst())
    }

    func discoverRecycleLocations() async throws -> FileRecycleDiscoveryResult {
        guard !recycleResults.isEmpty else { throw StubError.noReply }
        return try await resolve(recycleResults.removeFirst())
    }

    func didObserveCancellation() -> Bool { observedCancellation }
    func fileCalls() -> Int { filePageCallCount }

    private func resolve<Value: Sendable>(_ reply: Reply<Value>) async throws -> Value {
        switch reply {
        case .value(let value, let delay):
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            return value
        case .failure(let delay):
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            throw StubError.failed
        case .cancellable(let value, let delay):
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                return value
            } catch is CancellationError {
                observedCancellation = true
                throw CancellationError()
            }
        }
    }

    private enum StubError: Error { case noReply, failed }
}

@MainActor
final class MobileFileLocationsModelTests: XCTestCase {
    func test事务位置导航失败不改变已提交路径也不写最近位置() async {
        let profileID = UUID()
        let rootItem = item(profileID: profileID, name: "share", path: "/share", kind: .directory)
        let repository = MobileFileLocationsRepositoryStub(
            profileID: profileID,
            filePages: [
                .value(page(path: "", items: [rootItem])),
                .failure()
            ]
        )
        let locations = MobileFileLocationsModel()
        let browser = MobileFileBrowserModel(locations: locations)
        locations.activate(profileID: profileID, repository: repository)
        await browser.activate(profileID: profileID, repository: repository)
        await browser.refresh(repository: repository)

        let opened = await browser.openLocation(
            path: "/missing",
            source: .favorite,
            repository: repository
        )

        XCTAssertFalse(opened)
        XCTAssertEqual(browser.state.currentPath, "")
        XCTAssertEqual(browser.state.page.items, [rootItem])
        XCTAssertTrue(locations.state.recent.isEmpty)
    }

    func test事务位置导航首屏成功后才提交路径和最近位置() async {
        let profileID = UUID()
        let child = item(profileID: profileID, name: "report", path: "/docs/report")
        let repository = MobileFileLocationsRepositoryStub(
            profileID: profileID,
            filePages: [.value(page(path: "/docs", items: [child]))]
        )
        let locations = MobileFileLocationsModel()
        let browser = MobileFileBrowserModel(locations: locations)
        locations.activate(profileID: profileID, repository: repository)
        await browser.activate(profileID: profileID, repository: repository)

        let opened = await browser.openLocation(
            path: "/docs",
            source: .favorite,
            repository: repository
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(browser.state.currentPath, "/docs")
        XCTAssertEqual(browser.state.pathHistory, [])
        XCTAssertEqual(locations.state.recent.map(\.path), ["/docs"])
    }

    func test取消事务位置导航会取消底层Repository请求并恢复基线() async {
        let profileID = UUID()
        let rootItem = item(profileID: profileID, name: "share", path: "/share", kind: .directory)
        let repository = MobileFileLocationsRepositoryStub(
            profileID: profileID,
            filePages: [
                .value(page(path: "", items: [rootItem])),
                .cancellable(page(path: "/slow", items: []), 5_000_000_000)
            ]
        )
        let locations = MobileFileLocationsModel()
        let browser = MobileFileBrowserModel(locations: locations)
        locations.activate(profileID: profileID, repository: repository)
        await browser.activate(profileID: profileID, repository: repository)
        await browser.refresh(repository: repository)
        let baseline = browser.state

        let openTask = Task {
            await browser.openLocation(path: "/slow", source: .favorite, repository: repository)
        }
        for _ in 0..<100 {
            if await repository.fileCalls() >= 2 { break }
            await Task.yield()
        }
        browser.cancelLocationRequest()
        let opened = await openTask.value
        let observedCancellation = await repository.didObserveCancellation()

        XCTAssertFalse(opened)
        XCTAssertEqual(browser.state, baseline)
        XCTAssertTrue(observedCancellation)
        XCTAssertTrue(locations.state.recent.isEmpty)
    }

    func test远程和回收站来源稳定标记为只读() {
        XCTAssertTrue(MobileFileLocationSource.remote.isReadOnlyLocation)
        XCTAssertTrue(MobileFileLocationSource.recycle.isReadOnlyLocation)
        XCTAssertFalse(MobileFileLocationSource.shares.isReadOnlyLocation)
        XCTAssertFalse(MobileFileLocationSource.favorite.isReadOnlyLocation)
        XCTAssertFalse(MobileFileLocationSource.recent.isReadOnlyLocation)
        XCTAssertFalse(MobileFileLocationSource.browser.isReadOnlyLocation)
    }

    func test最近位置去重置顶限制十二条并排除远程回收站和根() {
        let profileID = UUID()
        let model = MobileFileLocationsModel()
        let repository = MobileFileLocationsRepositoryStub(profileID: profileID)
        model.activate(profileID: profileID, repository: repository)

        for index in 0..<14 {
            model.recordSuccessfulDirectory(
                profileID: profileID,
                path: "/share/folder-\(index)",
                source: .browser
            )
        }
        model.recordSuccessfulDirectory(profileID: profileID, path: "/share/folder-5", source: .recent)
        model.recordSuccessfulDirectory(profileID: profileID, path: "/remote/folder", source: .remote)
        model.recordSuccessfulDirectory(profileID: profileID, path: "/share/#recycle/item", source: .browser)
        model.recordSuccessfulDirectory(profileID: profileID, path: "/", source: .browser)

        XCTAssertEqual(model.state.recent.count, 12)
        XCTAssertEqual(model.state.recent.first?.path, "/share/folder-5")
        XCTAssertEqual(Set(model.state.recent.map(\.path)).count, 12)
        XCTAssertFalse(model.state.recent.contains { $0.path.contains("remote") || $0.path.contains("#recycle") })
    }

    func test刷新失败保留各区已提交快照并显示非阻塞错误() async {
        let profileID = UUID()
        let favorite = FavoriteLocation(name: "Docs", path: "/docs")
        let remoteItem = item(profileID: profileID, name: "Remote", path: "/remote", kind: .directory)
        let remote = FileVirtualFolder(item: remoteItem, protocolType: .cifs)
        let recycle = FileRecycleLocation(
            shareName: "Share",
            sharePath: "/share",
            recyclePath: "/share/#recycle"
        )
        let repository = MobileFileLocationsRepositoryStub(
            profileID: profileID,
            favoritePages: [
                .value(favoritePage([favorite])),
                .failure()
            ],
            remotePages: [
                .value(remotePage([remote])),
                .failure()
            ],
            recycleResults: [
                .value(recycleResult(profileID: profileID, locations: [recycle])),
                .failure()
            ]
        )
        let model = MobileFileLocationsModel()
        model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)
        await model.refresh(repository: repository)

        XCTAssertEqual(model.state.favorites.locations, [favorite])
        XCTAssertEqual(model.state.favorites.pageState, .content)
        XCTAssertTrue(model.state.favorites.hasRefreshError)
        XCTAssertEqual(model.state.remote.folders, [remote])
        XCTAssertEqual(model.state.remote.pageState, .content)
        XCTAssertTrue(model.state.remote.hasRefreshError)
        XCTAssertEqual(model.state.recycle.locations, [recycle])
        XCTAssertEqual(model.state.recycle.pageState, .content)
        XCTAssertTrue(model.state.recycle.hasRefreshError)
    }

    func test同Profile更换Repository后迟到结果不能覆盖新快照() async {
        let profileID = UUID()
        let stale = FavoriteLocation(name: "Stale", path: "/stale")
        let fresh = FavoriteLocation(name: "Fresh", path: "/fresh")
        let oldRepository = MobileFileLocationsRepositoryStub(
            profileID: profileID,
            favoritePages: [.value(favoritePage([stale]), 150_000_000)],
            remotePages: [.value(remotePage([]), 150_000_000)]
        )
        let newRepository = MobileFileLocationsRepositoryStub(
            profileID: profileID,
            favoritePages: [.value(favoritePage([fresh]))],
            remotePages: [.value(remotePage([]))]
        )
        let model = MobileFileLocationsModel()
        model.activate(profileID: profileID, repository: oldRepository)
        let oldTask = Task { await model.refresh(repository: oldRepository) }
        await Task.yield()
        model.activate(profileID: profileID, repository: newRepository)
        await model.refresh(repository: newRepository)
        await oldTask.value

        XCTAssertEqual(model.state.favorites.locations, [fresh])
    }

    func test取消刷新精确恢复已提交位置快照() async {
        let profileID = UUID()
        let favorite = FavoriteLocation(name: "Docs", path: "/docs")
        let repository = MobileFileLocationsRepositoryStub(
            profileID: profileID,
            favoritePages: [
                .value(favoritePage([favorite])),
                .value(favoritePage([FavoriteLocation(name: "New", path: "/new")]), 150_000_000)
            ],
            remotePages: [
                .value(remotePage([])),
                .value(remotePage([]))
            ],
            recycleResults: [
                .value(recycleResult(profileID: profileID, locations: [])),
                .value(recycleResult(profileID: profileID, locations: []))
            ]
        )
        let model = MobileFileLocationsModel()
        model.activate(profileID: profileID, repository: repository)
        await model.refresh(repository: repository)
        let baseline = model.state

        let refreshTask = Task { await model.refresh(repository: repository) }
        await Task.yield()
        model.cancelRequest()
        await refreshTask.value

        XCTAssertEqual(model.state, baseline)
    }

    func test切换Profile后迟到位置结果不能回写当前Profile() async {
        let firstID = UUID()
        let secondID = UUID()
        let stale = FavoriteLocation(name: "Stale", path: "/stale")
        let fresh = FavoriteLocation(name: "Fresh", path: "/fresh")
        let firstRepository = MobileFileLocationsRepositoryStub(
            profileID: firstID,
            favoritePages: [.value(favoritePage([stale]), 150_000_000)],
            remotePages: [.value(remotePage([]))]
        )
        let secondRepository = MobileFileLocationsRepositoryStub(
            profileID: secondID,
            favoritePages: [.value(favoritePage([fresh]))],
            remotePages: [.value(remotePage([]))]
        )
        let model = MobileFileLocationsModel()
        model.activate(profileID: firstID, repository: firstRepository)
        let firstTask = Task { await model.refresh(repository: firstRepository) }
        await Task.yield()
        model.activate(profileID: secondID, repository: secondRepository)
        await model.refresh(repository: secondRepository)
        await firstTask.value

        XCTAssertEqual(model.activeProfileID, secondID)
        XCTAssertEqual(model.state.favorites.locations, [fresh])
    }

    func test远程位置后代导航仍不写最近位置() async {
        let profileID = UUID()
        let childFolder = item(profileID: profileID, name: "child", path: "/remote/child", kind: .directory)
        let repository = MobileFileLocationsRepositoryStub(
            profileID: profileID,
            filePages: [
                .value(page(path: "/remote", items: [childFolder])),
                .value(page(path: "/remote/child", items: []))
            ]
        )
        let locations = MobileFileLocationsModel()
        let browser = MobileFileBrowserModel(locations: locations)
        locations.activate(profileID: profileID, repository: repository)
        await browser.activate(profileID: profileID, repository: repository)

        let opened = await browser.openLocation(path: "/remote", source: .remote, repository: repository)
        XCTAssertTrue(opened)
        await browser.openDirectory(childFolder, repository: repository)

        XCTAssertEqual(browser.state.location.source, .remote)
        XCTAssertTrue(locations.state.recent.isEmpty)
    }

    func test回收站发现结果Profile不一致时拒绝展示() async {
        let profileID = UUID()
        let wrongProfileID = UUID()
        let repository = MobileFileLocationsRepositoryStub(
            profileID: profileID,
            favoritePages: [.value(favoritePage([]))],
            remotePages: [.value(remotePage([]))],
            recycleResults: [
                .value(recycleResult(
                    profileID: wrongProfileID,
                    locations: [FileRecycleLocation(
                        shareName: "Share",
                        sharePath: "/share",
                        recyclePath: "/share/#recycle"
                    )]
                ))
            ]
        )
        let model = MobileFileLocationsModel()
        model.activate(profileID: profileID, repository: repository)

        await model.refresh(repository: repository)

        XCTAssertTrue(model.state.recycle.locations.isEmpty)
        XCTAssertEqual(model.state.recycle.pageState, .error)
    }

    func testDeactivate移除Repository绑定但保留会话缓存而Purge彻底删除() {
        let profileID = UUID()
        let repository = MobileFileLocationsRepositoryStub(profileID: profileID)
        let model = MobileFileLocationsModel()
        model.activate(profileID: profileID, repository: repository)
        model.recordSuccessfulDirectory(
            profileID: profileID,
            path: "/docs",
            source: .browser
        )

        model.deactivate()

        XCTAssertNil(model.activeProfileID)
        XCTAssertFalse(model.canOpenLocations)
        XCTAssertEqual(model.profiles[profileID]?.recent.map(\.path), ["/docs"])

        model.purge(profileID: profileID)
        XCTAssertNil(model.profiles[profileID])
    }

    private func favoritePage(_ locations: [FavoriteLocation]) -> FileFavoritePage {
        FileFavoritePage(
            locations: locations,
            offset: 0,
            nextOffset: locations.count,
            total: locations.count,
            sourceTotal: locations.count,
            hasMore: false,
            isTruncated: false
        )
    }

    private func remotePage(_ folders: [FileVirtualFolder]) -> FileVirtualFolderPage {
        FileVirtualFolderPage(
            folders: folders,
            offset: 0,
            total: folders.count,
            hasMore: false
        )
    }

    private func recycleResult(
        profileID: UUID,
        locations: [FileRecycleLocation]
    ) -> FileRecycleDiscoveryResult {
        FileRecycleDiscoveryResult(
            profileID: profileID,
            locations: locations,
            scannedShareCount: locations.count,
            permissionDeniedShareCount: 0,
            isTruncated: false
        )
    }

    private func item(
        profileID: UUID,
        name: String,
        path: String,
        kind: FileKind = .file
    ) -> FileItem {
        FileItem(profileID: profileID, name: name, path: path, kind: kind)
    }

    private func page(path: String, items: [FileItem]) -> FilePage {
        FilePage(folderPath: path, items: items, offset: 0, total: items.count, hasMore: false)
    }
}

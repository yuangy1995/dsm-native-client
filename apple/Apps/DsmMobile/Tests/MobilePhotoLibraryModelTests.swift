import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobilePhotoLibraryModelTests: XCTestCase {
    func test发现个人和共享空间并加载首个空间() async {
        let profileID = UUID()
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.personal, .shared],
            pages: [
                .init(path: PhotoSpace.personal.rootPath, offset: 0): Self.page(
                    path: PhotoSpace.personal.rootPath,
                    items: [Self.folder(profileID: profileID, name: "旅行", path: "/home/Photos/旅行")]
                )
            ]
        )
        let model = MobilePhotoLibraryModel()

        await model.activate(profileID: profileID, repository: repository)

        XCTAssertEqual(model.state.spaces.map(\.kind), [.personal, .shared])
        XCTAssertEqual(model.state.selectedSpace?.kind, .personal)
        XCTAssertEqual(model.state.currentPath, PhotoSpace.personal.rootPath)
        XCTAssertEqual(model.state.page.items.map(\.name), ["旅行"])
        XCTAssertEqual(model.state.pageState, .content)
    }

    func test只有共享空间时直接加载共享空间() async {
        let profileID = UUID()
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                .init(path: PhotoSpace.shared.rootPath, offset: 0): Self.page(
                    path: PhotoSpace.shared.rootPath,
                    items: [Self.image(profileID: profileID, name: "海边.jpg", path: "/photo/海边.jpg")]
                )
            ]
        )
        let model = MobilePhotoLibraryModel()

        await model.activate(profileID: profileID, repository: repository)

        XCTAssertEqual(model.state.spaces.map(\.kind), [.shared])
        XCTAssertEqual(model.state.selectedSpace?.kind, .shared)
        XCTAssertEqual(model.state.page.items.map(\.name), ["海边.jpg"])
    }

    func test没有可用空间时显示普通空态且不读目录() async {
        let profileID = UUID()
        let repository = PhotoLibraryRepositoryStub(spaces: [], pages: [:])
        let model = MobilePhotoLibraryModel()

        await model.activate(profileID: profileID, repository: repository)

        XCTAssertTrue(model.state.spaces.isEmpty)
        XCTAssertNil(model.state.selectedSpace)
        XCTAssertEqual(model.state.pageState, .empty)
        let requests = await repository.folderRequests()
        XCTAssertEqual(requests, [])
    }

    func test原始Offset跨过非媒体和视频且视频永不进入可见列表() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                .init(path: root, offset: 0): Self.page(
                    path: root,
                    items: [Self.video(profileID: profileID, name: "片段.mov", path: "/photo/片段.mov")],
                    offset: 0,
                    nextOffset: 2,
                    total: 4,
                    hasMore: true
                ),
                .init(path: root, offset: 2): Self.page(
                    path: root,
                    items: [
                        Self.folder(profileID: profileID, name: "相册", path: "/photo/相册"),
                        Self.image(profileID: profileID, name: "照片.jpg", path: "/photo/照片.jpg")
                    ],
                    offset: 2,
                    nextOffset: 4,
                    total: 4,
                    hasMore: false
                )
            ]
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)

        XCTAssertTrue(model.state.page.items.isEmpty)
        XCTAssertEqual(model.state.page.nextOffset, 2)
        XCTAssertTrue(model.state.page.hasMore)

        await model.loadMore()

        XCTAssertEqual(model.state.page.items.map(\.name), ["相册", "照片.jpg"])
        XCTAssertEqual(model.state.page.sourceItems.map(\.name), ["片段.mov", "相册", "照片.jpg"])
        let offsets = await repository.requestedOffsets()
        XCTAssertEqual(offsets, [0, 2])
    }

    func test错位首屏进入错误态() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                .init(path: root, offset: 0): Self.page(
                    path: root,
                    items: [],
                    offset: 1,
                    nextOffset: 1,
                    total: 1,
                    hasMore: false
                )
            ]
        )
        let model = MobilePhotoLibraryModel()

        await model.activate(profileID: profileID, repository: repository)

        XCTAssertEqual(model.state.pageState, .error)
        XCTAssertEqual(model.state.errorCategory, .invalidResponse)
    }

    func test加载更多零进展保留已有内容并提供重试状态() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let existing = Self.image(profileID: profileID, name: "已有.jpg", path: "/photo/已有.jpg")
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                .init(path: root, offset: 0): Self.page(
                    path: root,
                    items: [existing],
                    offset: 0,
                    nextOffset: 1,
                    total: 2,
                    hasMore: true
                ),
                .init(path: root, offset: 1): Self.page(
                    path: root,
                    items: [],
                    offset: 1,
                    nextOffset: 1,
                    total: 2,
                    hasMore: true
                )
            ]
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)

        await model.loadMore()

        XCTAssertEqual(model.state.page.items, [existing])
        XCTAssertTrue(model.state.loadMoreFailed)
        XCTAssertEqual(model.state.errorCategory, .invalidResponse)
    }

    func test加载更多失败保留已有内容() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let existing = Self.image(profileID: profileID, name: "已有.jpg", path: "/photo/已有.jpg")
        let failedKey = PhotoRequestKey(path: root, offset: 1)
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                .init(path: root, offset: 0): Self.page(
                    path: root,
                    items: [existing],
                    offset: 0,
                    nextOffset: 1,
                    total: 2,
                    hasMore: true
                )
            ],
            failures: [failedKey: Self.networkError]
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)

        await model.loadMore()

        XCTAssertEqual(model.state.page.items, [existing])
        XCTAssertTrue(model.state.loadMoreFailed)
        XCTAssertEqual(model.state.errorCategory, .networkUnavailable)
    }

    func test切换Profile后旧空间结果不能覆盖当前状态() async {
        let profileA = UUID()
        let profileB = UUID()
        let repositoryA = PhotoLibraryRepositoryStub(spaces: [.personal], pages: [:], blocksDiscovery: true)
        let repositoryB = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                .init(path: PhotoSpace.shared.rootPath, offset: 0): Self.page(
                    path: PhotoSpace.shared.rootPath,
                    items: [Self.image(profileID: profileB, name: "B.jpg", path: "/photo/B.jpg")]
                )
            ]
        )
        let model = MobilePhotoLibraryModel()

        let oldTask = Task { await model.activate(profileID: profileA, repository: repositoryA) }
        await repositoryA.waitUntilDiscoveryIsBlocked()
        await model.activate(profileID: profileB, repository: repositoryB)
        await repositoryA.releaseDiscovery()
        await oldTask.value

        XCTAssertEqual(model.activeProfileID, profileB)
        XCTAssertEqual(model.state.selectedSpace?.kind, .shared)
        XCTAssertEqual(model.state.page.items.map(\.name), ["B.jpg"])
    }

    func test同Profile以NilRepository激活会清除旧绑定并保持未激活() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                .init(path: root, offset: 0): Self.page(
                    path: root,
                    items: [Self.image(profileID: profileID, name: "旧会话.jpg", path: "/photo/旧会话.jpg")]
                )
            ]
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)

        await model.activate(profileID: profileID, repository: nil)
        await model.reload()

        XCTAssertNil(model.activeProfileID)
        let requests = await repository.folderRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func test较晚返回的旧路径不能覆盖新路径() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let folderA = Self.folder(profileID: profileID, name: "A", path: "/photo/A")
        let folderB = Self.folder(profileID: profileID, name: "B", path: "/photo/B")
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                .init(path: root, offset: 0): Self.page(path: root, items: [folderA, folderB]),
                .init(path: folderA.path, offset: 0): Self.page(
                    path: folderA.path,
                    items: [Self.image(profileID: profileID, name: "A.jpg", path: "/photo/A/A.jpg")]
                ),
                .init(path: folderB.path, offset: 0): Self.page(
                    path: folderB.path,
                    items: [Self.image(profileID: profileID, name: "B.jpg", path: "/photo/B/B.jpg")]
                )
            ],
            blockedRequests: [.init(path: folderA.path, offset: 0)]
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)

        let oldTask = Task { await model.openFolder(folderA) }
        await repository.waitUntilBlocked(.init(path: folderA.path, offset: 0))
        await model.openFolder(folderB)
        await repository.release(.init(path: folderA.path, offset: 0))
        await oldTask.value

        XCTAssertEqual(model.state.currentPath, folderB.path)
        XCTAssertEqual(model.state.page.items.map(\.name), ["B.jpg"])
    }

    func test筛选切换使迟到刷新失效并立即过滤当前页面() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let folder = Self.folder(profileID: profileID, name: "相册", path: "/photo/相册")
        let image = Self.image(profileID: profileID, name: "照片.jpg", path: "/photo/照片.jpg")
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): Self.page(path: root, items: [folder, image])]
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)
        await repository.block(.init(path: root, offset: 0))

        let oldTask = Task { await model.reload() }
        await repository.waitUntilBlocked(.init(path: root, offset: 0))
        model.setFilter(.images)
        await repository.release(.init(path: root, offset: 0))
        await oldTask.value

        XCTAssertEqual(model.state.filter, .images)
        XCTAssertEqual(model.state.page.items.map(\.name), ["照片.jpg"])
    }

    func test离页会取消请求且迟到结果不会恢复活动Profile() async {
        let profileID = UUID()
        let repository = PhotoLibraryRepositoryStub(spaces: [.shared], pages: [:], blocksDiscovery: true)
        let model = MobilePhotoLibraryModel()

        let task = Task { await model.activate(profileID: profileID, repository: repository) }
        await repository.waitUntilDiscoveryIsBlocked()
        model.deactivate()
        await repository.releaseDiscovery()
        await task.value

        XCTAssertNil(model.activeProfileID)
        XCTAssertTrue(model.state.spaces.isEmpty)
    }

    func test返回上级优先恢复缓存且不重复请求() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let folder = Self.folder(profileID: profileID, name: "相册", path: "/photo/相册")
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                .init(path: root, offset: 0): Self.page(path: root, items: [folder]),
                .init(path: folder.path, offset: 0): Self.page(
                    path: folder.path,
                    items: [Self.image(profileID: profileID, name: "照片.jpg", path: "/photo/相册/照片.jpg")]
                )
            ]
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)

        await model.openFolder(folder)
        await model.goBack()

        XCTAssertEqual(model.state.currentPath, root)
        XCTAssertEqual(model.state.page.items, [folder])
        let requests = await repository.folderRequests()
        XCTAssertEqual(requests, [
            .init(path: root, offset: 0),
            .init(path: folder.path, offset: 0)
        ])
    }

    func test空间往返优先恢复缓存且不重复请求() async {
        let profileID = UUID()
        let personalImage = Self.image(profileID: profileID, name: "个人.jpg", path: "/home/Photos/个人.jpg")
        let sharedImage = Self.image(profileID: profileID, name: "共享.jpg", path: "/photo/共享.jpg")
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.personal, .shared],
            pages: [
                .init(path: PhotoSpace.personal.rootPath, offset: 0): Self.page(
                    path: PhotoSpace.personal.rootPath,
                    items: [personalImage]
                ),
                .init(path: PhotoSpace.shared.rootPath, offset: 0): Self.page(
                    path: PhotoSpace.shared.rootPath,
                    items: [sharedImage]
                )
            ]
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)

        await model.selectSpace(.shared)
        await model.selectSpace(.personal)

        XCTAssertEqual(model.state.page.items, [personalImage])
        let requests = await repository.folderRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func testProfile往返恢复各自缓存且不重复请求() async {
        let profileA = UUID()
        let profileB = UUID()
        let root = PhotoSpace.shared.rootPath
        let itemA = Self.image(profileID: profileA, name: "A.jpg", path: "/photo/same.jpg")
        let itemB = Self.image(profileID: profileB, name: "B.jpg", path: "/photo/same.jpg")
        let repositoryA = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): Self.page(path: root, items: [itemA])]
        )
        let repositoryB = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): Self.page(path: root, items: [itemB])]
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileA, repository: repositoryA)
        await model.activate(profileID: profileB, repository: repositoryB)

        await model.activate(profileID: profileA, repository: repositoryA)

        XCTAssertEqual(model.state.page.items, [itemA])
        let requestsA = await repositoryA.folderRequests()
        let requestsB = await repositoryB.folderRequests()
        XCTAssertEqual(requestsA.count, 1)
        XCTAssertEqual(requestsB.count, 1)
    }

    func test显式刷新失败保留已浏览内容() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let item = Self.image(profileID: profileID, name: "保留.jpg", path: "/photo/保留.jpg")
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): Self.page(path: root, items: [item])]
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)
        await repository.failNext(.init(path: root, offset: 0), with: Self.networkError)

        await model.reload()

        XCTAssertEqual(model.state.page.items, [item])
        XCTAssertEqual(model.state.pageState, .content)
        XCTAssertEqual(model.state.errorCategory, .networkUnavailable)
        let requests = await repository.folderRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func test图片筛选为空时刷新失败保留筛选空态和原始页面() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let folder = Self.folder(profileID: profileID, name: "只有文件夹", path: "/photo/只有文件夹")
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): Self.page(path: root, items: [folder])]
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)
        model.setFilter(.images)
        await repository.failNext(.init(path: root, offset: 0), with: Self.networkError)

        await model.reload()

        XCTAssertEqual(model.state.pageState, .filteredEmpty)
        XCTAssertEqual(model.state.page.sourceItems, [folder])
        XCTAssertTrue(model.state.page.items.isEmpty)
        XCTAssertEqual(model.state.errorCategory, .networkUnavailable)
    }

    func test打开文件夹拒绝不属于当前页面或伪造同ID路径的条目() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let canonical = Self.folder(profileID: profileID, name: "真实", path: "/photo/真实")
        let forged = PhotoLibraryItem(
            id: canonical.id,
            profileID: profileID,
            name: canonical.name,
            path: "/photo/伪造",
            kind: .folder,
            sizeBytes: nil,
            createdAt: nil,
            modifiedAt: nil,
            fileExtension: nil,
            thumbnailAvailable: nil
        )
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): Self.page(path: root, items: [canonical])]
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)

        await model.openFolder(forged)

        XCTAssertEqual(model.state.currentPath, root)
        let requests = await repository.folderRequests()
        XCTAssertEqual(requests, [.init(path: root, offset: 0)])
    }

    func test每个Profile的页面缓存保持有界() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let paths = (0...13).map { $0 == 0 ? root : "/photo/层级\($0)" }
        var pages: [PhotoRequestKey: PhotoLibraryPage] = [:]
        for index in paths.indices {
            let items: [PhotoLibraryItem]
            if index + 1 < paths.count {
                items = [Self.folder(profileID: profileID, name: "层级\(index + 1)", path: paths[index + 1])]
            } else {
                items = []
            }
            pages[.init(path: paths[index], offset: 0)] = Self.page(path: paths[index], items: items)
        }
        let repository = PhotoLibraryRepositoryStub(spaces: [.shared], pages: pages)
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)

        for _ in 1..<paths.count {
            guard let folder = model.state.page.items.first else {
                return XCTFail("测试层级缺失")
            }
            await model.openFolder(folder)
        }

        XCTAssertEqual(model.profiles[profileID]?.caches.count, MobilePhotoLibraryModel.pageCacheLimitPerProfile)
        XCTAssertEqual(model.profiles[profileID]?.cacheOrder.count, MobilePhotoLibraryModel.pageCacheLimitPerProfile)
    }

    func test同路径旧Repository迟到结果不能写入新Profile缓存() async {
        let profileA = UUID()
        let profileB = UUID()
        let root = PhotoSpace.shared.rootPath
        let repositoryA = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                .init(path: root, offset: 0): Self.page(
                    path: root,
                    items: [Self.image(profileID: profileA, name: "A.jpg", path: "/photo/same.jpg")]
                )
            ],
            blockedRequests: [.init(path: root, offset: 0)]
        )
        let itemB = Self.image(profileID: profileB, name: "B.jpg", path: "/photo/same.jpg")
        let repositoryB = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): Self.page(path: root, items: [itemB])]
        )
        let model = MobilePhotoLibraryModel()

        let oldTask = Task { await model.activate(profileID: profileA, repository: repositoryA) }
        await repositoryA.waitUntilBlocked(.init(path: root, offset: 0))
        await model.activate(profileID: profileB, repository: repositoryB)
        await repositoryA.release(.init(path: root, offset: 0))
        await oldTask.value

        XCTAssertEqual(model.activeProfileID, profileB)
        XCTAssertEqual(model.state.page.items, [itemB])
        XCTAssertNil(model.state.errorCategory)
        XCTAssertTrue(model.state.caches.values.flatMap(\.items).allSatisfy { $0.profileID == profileB })
    }

    func test跨Profile页面被拒绝且不写入缓存() async {
        let profileA = UUID()
        let profileB = UUID()
        let root = PhotoSpace.shared.rootPath
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                .init(path: root, offset: 0): Self.page(
                    path: root,
                    items: [Self.image(profileID: profileA, name: "错误.jpg", path: "/photo/错误.jpg")]
                )
            ]
        )
        let model = MobilePhotoLibraryModel()

        await model.activate(profileID: profileB, repository: repository)

        XCTAssertEqual(model.state.pageState, .error)
        XCTAssertEqual(model.state.errorCategory, .invalidResponse)
        XCTAssertTrue(model.state.page.items.isEmpty)
        XCTAssertTrue(model.state.caches.isEmpty)
    }

    func test跨Profile缩略图不调用当前Repository且不进入缓存() async {
        let profileA = UUID()
        let profileB = UUID()
        let root = PhotoSpace.shared.rootPath
        let itemB = Self.image(profileID: profileB, name: "B.jpg", path: "/photo/B.jpg")
        let wrongItem = Self.image(profileID: profileA, name: "A.jpg", path: "/photo/B.jpg")
        let probe = ThumbnailRepositoryProbe()
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): Self.page(path: root, items: [itemB])],
            thumbnailProbe: probe
        )
        let store = MobilePhotoThumbnailStore(totalCostLimit: 1_024, concurrencyLimit: 1)
        let model = MobilePhotoLibraryModel(thumbnailStore: store)
        await model.activate(profileID: profileB, repository: repository)

        let data = await model.thumbnailData(for: wrongItem)

        let paths = await probe.requestedPaths()
        let cachedCount = await store.cachedItemCount()
        XCTAssertNil(data)
        XCTAssertEqual(paths, [])
        XCTAssertEqual(cachedCount, 0)
    }

    func test缩略图拒绝伪造同ID路径且只使用当前页面Canonical条目() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let canonical = Self.image(profileID: profileID, name: "真实.jpg", path: "/photo/真实.jpg")
        let forged = PhotoLibraryItem(
            id: canonical.id,
            profileID: profileID,
            name: canonical.name,
            path: "/photo/伪造.jpg",
            kind: .image,
            sizeBytes: canonical.sizeBytes,
            createdAt: canonical.createdAt,
            modifiedAt: canonical.modifiedAt,
            fileExtension: canonical.fileExtension,
            thumbnailAvailable: canonical.thumbnailAvailable
        )
        let probe = ThumbnailRepositoryProbe()
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): Self.page(path: root, items: [canonical])],
            thumbnailProbe: probe
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)

        let data = await model.thumbnailData(for: forged)

        XCTAssertNil(data)
        let paths = await probe.requestedPaths()
        XCTAssertTrue(paths.isEmpty)
    }

    func test预取缩略图拒绝伪造和旧页面条目且观察窗口内零请求零缓存() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let canonical = Self.image(profileID: profileID, name: "真实.jpg", path: "/photo/真实.jpg")
        let forged = PhotoLibraryItem(
            id: canonical.id,
            profileID: profileID,
            name: canonical.name,
            path: "/photo/伪造.jpg",
            kind: .image,
            sizeBytes: canonical.sizeBytes,
            createdAt: canonical.createdAt,
            modifiedAt: canonical.modifiedAt,
            fileExtension: canonical.fileExtension,
            thumbnailAvailable: canonical.thumbnailAvailable
        )
        let oldItem = Self.image(profileID: profileID, name: "旧页面.jpg", path: "/photo/旧页面.jpg")
        let probe = ThumbnailRepositoryProbe()
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): Self.page(path: root, items: [canonical])],
            thumbnailProbe: probe
        )
        let store = MobilePhotoThumbnailStore(totalCostLimit: 1_024, concurrencyLimit: 1)
        let model = MobilePhotoLibraryModel(thumbnailStore: store)
        await model.activate(profileID: profileID, repository: repository)

        model.prefetchThumbnails([forged, oldItem])

        for _ in 0..<20 {
            if await probe.hasRequestedThumbnail() {
                XCTFail("无效预取条目不应在观察窗口内启动请求")
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let paths = await probe.requestedPaths()
        let cachedCount = await store.cachedItemCount()
        XCTAssertTrue(paths.isEmpty)
        XCTAssertEqual(cachedCount, 0)
    }

    func test缩略图仅修改时间变化后重新请求() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let firstVersion = Self.image(
            profileID: profileID,
            name: "照片.jpg",
            path: "/photo/照片.jpg",
            sizeBytes: 10,
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        let secondVersion = Self.image(
            profileID: profileID,
            name: "照片.jpg",
            path: "/photo/照片.jpg",
            sizeBytes: 10,
            modifiedAt: Date(timeIntervalSince1970: 200)
        )
        let key = PhotoRequestKey(path: root, offset: 0)
        let probe = ThumbnailRepositoryProbe()
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [key: Self.page(path: root, items: [firstVersion])],
            thumbnailProbe: probe
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)
        _ = await model.thumbnailData(for: firstVersion)
        await repository.replacePage(Self.page(path: root, items: [secondVersion]), for: key)

        await model.reload()
        _ = await model.thumbnailData(for: secondVersion)

        let paths = await probe.requestedPaths()
        XCTAssertEqual(paths, [firstVersion.path, secondVersion.path])
    }

    func test缩略图仅大小变化后重新请求() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let modifiedAt = Date(timeIntervalSince1970: 100)
        let firstVersion = Self.image(
            profileID: profileID,
            name: "照片.jpg",
            path: "/photo/照片.jpg",
            sizeBytes: 10,
            modifiedAt: modifiedAt
        )
        let secondVersion = Self.image(
            profileID: profileID,
            name: "照片.jpg",
            path: "/photo/照片.jpg",
            sizeBytes: 20,
            modifiedAt: modifiedAt
        )
        let key = PhotoRequestKey(path: root, offset: 0)
        let probe = ThumbnailRepositoryProbe()
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [key: Self.page(path: root, items: [firstVersion])],
            thumbnailProbe: probe
        )
        let model = MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)
        _ = await model.thumbnailData(for: firstVersion)
        await repository.replacePage(Self.page(path: root, items: [secondVersion]), for: key)

        await model.reload()
        _ = await model.thumbnailData(for: secondVersion)

        let paths = await probe.requestedPaths()
        XCTAssertEqual(paths, [firstVersion.path, secondVersion.path])
    }

    func test调用方取消缩略图会释放槽位且不缓存取消结果() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let first = Self.image(profileID: profileID, name: "first.jpg", path: "/photo/first.jpg")
        let second = Self.image(profileID: profileID, name: "second.jpg", path: "/photo/second.jpg")
        let probe = ThumbnailRepositoryProbe(blockedPath: first.path)
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): Self.page(path: root, items: [first, second])],
            thumbnailProbe: probe
        )
        let store = MobilePhotoThumbnailStore(totalCostLimit: 1_024, concurrencyLimit: 1)
        let model = MobilePhotoLibraryModel(thumbnailStore: store)
        await model.activate(profileID: profileID, repository: repository)

        let firstTask = Task { await model.thumbnailData(for: first) }
        await probe.waitUntilBlockedRequestStarts()
        firstTask.cancel()
        let firstData = await firstTask.value
        let secondData = await model.thumbnailData(for: second)
        let retriedFirstData = await model.thumbnailData(for: first)

        let cancelledCount = await probe.cancelledCount()
        let cachedCount = await store.cachedItemCount()
        let requestedPaths = await probe.requestedPaths()
        XCTAssertNil(firstData)
        XCTAssertEqual(secondData, Data(second.path.utf8))
        XCTAssertEqual(retriedFirstData, Data(first.path.utf8))
        XCTAssertEqual(cancelledCount, 1)
        XCTAssertEqual(cachedCount, 2)
        XCTAssertEqual(requestedPaths, [first.path, second.path, first.path])
    }

    func test缩略图并发峰值受限() async {
        let store = MobilePhotoThumbnailStore(totalCostLimit: 1_024, concurrencyLimit: 3)
        let probe = ThumbnailLoaderProbe(delayNanoseconds: 30_000_000)

        await withTaskGroup(of: Data?.self) { group in
            for index in 0..<12 {
                group.addTask {
                    await store.data(for: "item-\(index)", priority: .prefetch) {
                        try await probe.load(name: "item-\(index)")
                    }
                }
            }
            for await _ in group {}
        }

        let peak = await probe.peakActiveCount()
        XCTAssertEqual(peak, 3)
    }

    func test可见缩略图优先于已排队的预取() async {
        let store = MobilePhotoThumbnailStore(totalCostLimit: 1_024, concurrencyLimit: 1)
        let probe = ThumbnailLoaderProbe(delayNanoseconds: 0, blocksFirst: true)
        let first = Task {
            await store.data(for: "first", priority: .prefetch) { try await probe.load(name: "first") }
        }
        await probe.waitUntilFirstIsBlocked()
        let queuedPrefetch = Task {
            await store.data(for: "prefetch", priority: .prefetch) { try await probe.load(name: "prefetch") }
        }
        let visible = Task {
            await store.data(for: "visible", priority: .visible) { try await probe.load(name: "visible") }
        }
        for _ in 0..<100 {
            let pending = await store.pendingRequestCounts()
            if pending.visible == 1, pending.prefetch == 1 { break }
            await Task.yield()
        }
        let pending = await store.pendingRequestCounts()
        XCTAssertEqual(pending.visible, 1)
        XCTAssertEqual(pending.prefetch, 1)
        await probe.releaseFirst()
        _ = await (first.value, queuedPrefetch.value, visible.value)

        let names = await probe.startedNames()
        XCTAssertEqual(names, ["first", "visible", "prefetch"])
    }

    func test缩略图缓存遵守总成本并允许失败重试() async {
        let store = MobilePhotoThumbnailStore(totalCostLimit: 5, concurrencyLimit: 1)
        let retryProbe = FailingThumbnailProbe()

        let failed = await store.data(for: "retry", priority: .visible) {
            try await retryProbe.load()
        }
        let retried = await store.data(for: "retry", priority: .visible) {
            try await retryProbe.load()
        }
        _ = await store.data(for: "other", priority: .visible) { Data([1, 2, 3, 4]) }

        XCTAssertNil(failed)
        XCTAssertEqual(retried, Data([1, 2, 3, 4]))
        let calls = await retryProbe.callCount()
        let cost = await store.cachedCost()
        let count = await store.cachedItemCount()
        XCTAssertEqual(calls, 2)
        XCTAssertLessThanOrEqual(cost, 5)
        XCTAssertLessThanOrEqual(count, 1)
    }

    func test清理缓存后清理前的迟到加载不会回填() async {
        let store = MobilePhotoThumbnailStore(totalCostLimit: 1_024, concurrencyLimit: 1)
        let probe = ThumbnailLoaderProbe(delayNanoseconds: 0, blocksFirst: true)
        let loading = Task {
            await store.data(for: "late", priority: .visible) {
                try await probe.load(name: "late")
            }
        }
        await probe.waitUntilFirstIsBlocked()

        await store.removeAll()
        await probe.releaseFirst()

        let result = await loading.value
        let cost = await store.cachedCost()
        let count = await store.cachedItemCount()
        XCTAssertNil(result)
        XCTAssertEqual(cost, 0)
        XCTAssertEqual(count, 0)
    }

    func test显式Purge仅清除指定Profile状态和可再生缩略图() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let image = Self.image(profileID: profileID, name: "cached.jpg", path: "/photo/cached.jpg")
        let store = MobilePhotoThumbnailStore(totalCostLimit: 1_024, concurrencyLimit: 1)
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): Self.page(path: root, items: [image])]
        )
        let model = await MobilePhotoLibraryModel(thumbnailStore: store)
        await model.activate(profileID: profileID, repository: repository)
        _ = await model.thumbnailData(for: image)
        let cachedProfileBeforePurge = await model.profiles[profileID]
        let cachedCostBeforePurge = await store.cachedCost()
        XCTAssertNotNil(cachedProfileBeforePurge)
        XCTAssertGreaterThan(cachedCostBeforePurge, 0)

        await model.purge(profileID: profileID)

        let cachedProfileAfterPurge = await model.profiles[profileID]
        let activeProfileAfterPurge = await model.activeProfileID
        let cachedCostAfterPurge = await store.cachedCost()
        XCTAssertNil(cachedProfileAfterPurge)
        XCTAssertNil(activeProfileAfterPurge)
        XCTAssertEqual(cachedCostAfterPurge, 0)
    }

    func test普通Deactivate保留Profile页面缓存() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): Self.page(path: root, items: [])]
        )
        let model = await MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: repository)

        await model.deactivate()

        let cachedProfile = await model.profiles[profileID]
        let activeProfile = await model.activeProfileID
        XCTAssertNotNil(cachedProfile)
        XCTAssertNil(activeProfile)
    }

    func test普通Deactivate释放旧Repository且重新激活恢复缓存并只使用新Repository() async {
        let profileID = UUID()
        let root = PhotoSpace.shared.rootPath
        let page = Self.page(path: root, items: [])
        let oldRepository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): page]
        )
        let newRepository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [.init(path: root, offset: 0): page]
        )
        let model = await MobilePhotoLibraryModel()
        await model.activate(profileID: profileID, repository: oldRepository)
        let oldRequestsBeforeDeactivate = await oldRepository.folderRequests()
        XCTAssertEqual(oldRequestsBeforeDeactivate.count, 1)

        await model.deactivate()
        await model.reload()
        let oldRequestsAfterDeactivate = await oldRepository.folderRequests()
        XCTAssertEqual(oldRequestsAfterDeactivate, oldRequestsBeforeDeactivate)

        await model.activate(profileID: profileID, repository: newRepository)
        let newRequestsAfterActivation = await newRepository.folderRequests()
        let restoredPath = await model.state.currentPath
        XCTAssertEqual(newRequestsAfterActivation, [])
        XCTAssertEqual(restoredPath, root)

        await model.reload()
        let finalOldRequests = await oldRepository.folderRequests()
        let finalNewRequests = await newRepository.folderRequests()
        XCTAssertEqual(finalOldRequests, oldRequestsBeforeDeactivate)
        XCTAssertEqual(finalNewRequests.count, 1)
    }

    func test按Profile清理缩略图保留其他Profile且阻止目标Profile迟到回填() async {
        let store = MobilePhotoThumbnailStore(totalCostLimit: 1_024, concurrencyLimit: 2)
        let firstNamespace = UUID().uuidString
        let secondNamespace = UUID().uuidString
        let probe = ThumbnailLoaderProbe(delayNanoseconds: 0, blocksFirst: true)
        let lateFirst = Task {
            await store.data(
                for: "\(firstNamespace)|late",
                namespace: firstNamespace,
                priority: .visible
            ) {
                try await probe.load(name: "late")
            }
        }
        await probe.waitUntilFirstIsBlocked()
        let secondData = await store.data(
            for: "\(secondNamespace)|kept",
            namespace: secondNamespace,
            priority: .visible
        ) {
            Data("kept".utf8)
        }

        await store.removeAll(namespace: firstNamespace)
        await probe.releaseFirst()

        let lateFirstData = await lateFirst.value
        let cachedSecondData = await store.cachedData(for: "\(secondNamespace)|kept")
        let cachedItemCount = await store.cachedItemCount()
        XCTAssertNil(lateFirstData)
        XCTAssertEqual(secondData, Data("kept".utf8))
        XCTAssertEqual(cachedSecondData, Data("kept".utf8))
        XCTAssertEqual(cachedItemCount, 1)
    }

    func test生产模型不引用范围外读取或写操作() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Features/Photos/MobilePhotoLibraryModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for forbidden in ["scanTimeline(", ".search(", ".move(", ".delete(", ".restore("] {
            XCTAssertFalse(source.contains(forbidden), "A1 不得引用 \(forbidden)")
        }
    }

    private static let networkError = AppError(
        category: .networkUnavailable,
        isRetryable: true,
        safeUserMessage: "测试网络错误"
    )

    private static func page(
        path: String,
        items: [PhotoLibraryItem],
        offset: Int = 0,
        nextOffset: Int? = nil,
        total: Int? = nil,
        hasMore: Bool = false
    ) -> PhotoLibraryPage {
        let resolvedNextOffset = nextOffset ?? (offset + items.count)
        return PhotoLibraryPage(
            folderPath: path,
            items: items,
            offset: offset,
            nextOffset: resolvedNextOffset,
            sourceTotal: total ?? resolvedNextOffset,
            hasMore: hasMore
        )
    }

    private static func folder(profileID: UUID, name: String, path: String) -> PhotoLibraryItem {
        PhotoLibraryItem(
            id: path,
            profileID: profileID,
            name: name,
            path: path,
            kind: .folder,
            sizeBytes: nil,
            createdAt: nil,
            modifiedAt: nil,
            fileExtension: nil,
            thumbnailAvailable: nil
        )
    }

    private static func image(
        profileID: UUID,
        name: String,
        path: String,
        sizeBytes: Int64 = 10,
        modifiedAt: Date? = nil
    ) -> PhotoLibraryItem {
        PhotoLibraryItem(
            id: path,
            profileID: profileID,
            name: name,
            path: path,
            kind: .image,
            sizeBytes: sizeBytes,
            createdAt: nil,
            modifiedAt: modifiedAt,
            fileExtension: (name as NSString).pathExtension.lowercased(),
            thumbnailAvailable: true
        )
    }

    private static func video(profileID: UUID, name: String, path: String) -> PhotoLibraryItem {
        PhotoLibraryItem(
            id: path,
            profileID: profileID,
            name: name,
            path: path,
            kind: .video,
            sizeBytes: 10,
            createdAt: nil,
            modifiedAt: nil,
            fileExtension: (name as NSString).pathExtension.lowercased(),
            thumbnailAvailable: true
        )
    }
}

private struct PhotoRequestKey: Hashable, Sendable {
    let path: String
    let offset: Int
}

private actor PhotoLibraryRepositoryStub: PhotoLibraryRepository {
    private let spaces: [PhotoSpace]
    private var pages: [PhotoRequestKey: PhotoLibraryPage]
    private let failures: [PhotoRequestKey: AppError]
    private let thumbnailProbe: ThumbnailRepositoryProbe?
    private var nextFailures: [PhotoRequestKey: AppError] = [:]
    private var blockedRequests: Set<PhotoRequestKey>
    private var blockedContinuations: [PhotoRequestKey: [CheckedContinuation<Void, Never>]] = [:]
    private var blockedObservers: [PhotoRequestKey: [CheckedContinuation<Void, Never>]] = [:]
    private var discoveryBlocked: Bool
    private var discoveryContinuations: [CheckedContinuation<Void, Never>] = []
    private var discoveryObservers: [CheckedContinuation<Void, Never>] = []
    private var requests: [PhotoRequestKey] = []
    private var scanCalls = 0

    init(
        spaces: [PhotoSpace],
        pages: [PhotoRequestKey: PhotoLibraryPage],
        failures: [PhotoRequestKey: AppError] = [:],
        blockedRequests: Set<PhotoRequestKey> = [],
        blocksDiscovery: Bool = false,
        thumbnailProbe: ThumbnailRepositoryProbe? = nil
    ) {
        self.spaces = spaces
        self.pages = pages
        self.failures = failures
        self.blockedRequests = blockedRequests
        self.discoveryBlocked = blocksDiscovery
        self.thumbnailProbe = thumbnailProbe
    }

    func discoverSpaces() async throws -> [PhotoSpace] {
        if discoveryBlocked {
            let observers = discoveryObservers
            discoveryObservers.removeAll()
            observers.forEach { $0.resume() }
            await withCheckedContinuation { discoveryContinuations.append($0) }
        }
        return spaces
    }

    func listFolder(
        in space: PhotoSpace,
        path: String,
        offset: Int,
        limit: Int
    ) async throws -> PhotoLibraryPage {
        let key = PhotoRequestKey(path: path, offset: offset)
        requests.append(key)
        if blockedRequests.contains(key) {
            let observers = blockedObservers.removeValue(forKey: key) ?? []
            observers.forEach { $0.resume() }
            await withCheckedContinuation { blockedContinuations[key, default: []].append($0) }
        }
        if let failure = nextFailures.removeValue(forKey: key) { throw failure }
        if let failure = failures[key] { throw failure }
        guard let page = pages[key] else {
            throw AppError(category: .notFound, isRetryable: false, safeUserMessage: "测试页面不存在")
        }
        return page
    }

    func getThumbnail(for item: PhotoLibraryItem, size: ThumbnailSize) async throws -> Data {
        if let thumbnailProbe {
            return try await thumbnailProbe.load(item: item)
        }
        return Data(item.path.utf8)
    }

    func scanTimeline(
        in space: PhotoSpace,
        startingAt folderPaths: [String],
        existingFolderItemPaths: [String: [String]],
        onUpdate: @escaping @Sendable (PhotoTimelineScanUpdate) async -> Void
    ) async throws {
        scanCalls += 1
    }

    func block(_ key: PhotoRequestKey) {
        blockedRequests.insert(key)
    }

    func waitUntilBlocked(_ key: PhotoRequestKey) async {
        guard blockedContinuations[key]?.isEmpty != false else { return }
        await withCheckedContinuation { blockedObservers[key, default: []].append($0) }
    }

    func release(_ key: PhotoRequestKey) {
        blockedRequests.remove(key)
        let continuations = blockedContinuations.removeValue(forKey: key) ?? []
        continuations.forEach { $0.resume() }
    }

    func waitUntilDiscoveryIsBlocked() async {
        guard discoveryContinuations.isEmpty else { return }
        await withCheckedContinuation { discoveryObservers.append($0) }
    }

    func releaseDiscovery() {
        discoveryBlocked = false
        let continuations = discoveryContinuations
        discoveryContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func failNext(_ key: PhotoRequestKey, with error: AppError) {
        nextFailures[key] = error
    }

    func replacePage(_ page: PhotoLibraryPage, for key: PhotoRequestKey) {
        pages[key] = page
    }

    func folderRequests() -> [PhotoRequestKey] { requests }
    func requestedOffsets() -> [Int] { requests.map(\.offset) }
}

private actor ThumbnailRepositoryProbe {
    private let blockedPath: String?
    private var paths: [String] = []
    private var cancellations = 0
    private var blockedRequestStarted = false
    private var didBlockRequest = false
    private var startObservers: [CheckedContinuation<Void, Never>] = []

    init(blockedPath: String? = nil) {
        self.blockedPath = blockedPath
    }

    func load(item: PhotoLibraryItem) async throws -> Data {
        paths.append(item.path)
        if item.path == blockedPath, !didBlockRequest {
            didBlockRequest = true
            blockedRequestStarted = true
            let observers = startObservers
            startObservers.removeAll()
            observers.forEach { $0.resume() }
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                cancellations += 1
                throw error
            }
        }
        return Data(item.path.utf8)
    }

    func waitUntilBlockedRequestStarts() async {
        guard !blockedRequestStarted else { return }
        await withCheckedContinuation { startObservers.append($0) }
    }

    func requestedPaths() -> [String] { paths }
    func hasRequestedThumbnail() -> Bool { !paths.isEmpty }
    func cancelledCount() -> Int { cancellations }
}

private actor ThumbnailLoaderProbe {
    private let delayNanoseconds: UInt64
    private let blocksFirst: Bool
    private var active = 0
    private var peak = 0
    private var names: [String] = []
    private var firstBlocked = false
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var firstObservers: [CheckedContinuation<Void, Never>] = []

    init(delayNanoseconds: UInt64, blocksFirst: Bool = false) {
        self.delayNanoseconds = delayNanoseconds
        self.blocksFirst = blocksFirst
    }

    func load(name: String) async throws -> Data {
        active += 1
        peak = max(peak, active)
        names.append(name)
        defer { active -= 1 }
        if blocksFirst, names.count == 1 {
            firstBlocked = true
            let observers = firstObservers
            firstObservers.removeAll()
            observers.forEach { $0.resume() }
            await withCheckedContinuation { firstContinuation = $0 }
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return Data(name.utf8)
    }

    func waitUntilFirstIsBlocked() async {
        guard !firstBlocked else { return }
        await withCheckedContinuation { firstObservers.append($0) }
    }

    func releaseFirst() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    func peakActiveCount() -> Int { peak }
    func startedNames() -> [String] { names }
}

private actor FailingThumbnailProbe {
    private var calls = 0

    func load() async throws -> Data {
        calls += 1
        if calls == 1 {
            throw AppError(category: .networkUnavailable, isRetryable: true, safeUserMessage: "测试失败")
        }
        return Data([1, 2, 3, 4])
    }

    func callCount() -> Int { calls }
}

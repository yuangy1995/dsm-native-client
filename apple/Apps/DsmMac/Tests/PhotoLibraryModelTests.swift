import DsmCore
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class PhotoLibraryModelTests: XCTestCase {
    func test关闭照片模块后不发现空间且重新开启后可恢复() async {
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.personal],
            pages: [
                0: PhotoLibraryPage(
                    folderPath: "/home/Photos",
                    items: [],
                    offset: 0,
                    nextOffset: 0,
                    sourceTotal: 0,
                    hasMore: false
                )
            ]
        )
        let model = PhotoLibraryModel(repository: repository)

        model.setModuleEnabled(false)
        await model.loadIfNeeded()

        XCTAssertFalse(model.isModuleEnabled)
        XCTAssertTrue(model.spaces.isEmpty)

        model.setModuleEnabled(true)
        await model.loadIfNeeded()

        XCTAssertEqual(model.spaces.map(\.id), [.personal])
    }

    func test首次载入发现空间并显示照片项目() async throws {
        let item = try XCTUnwrap(photoItem(name: "海边.jpg", path: "/home/Photos/海边.jpg"))
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.personal],
            pages: [
                0: PhotoLibraryPage(
                    folderPath: "/home/Photos",
                    items: [item],
                    offset: 0,
                    nextOffset: 1,
                    sourceTotal: 1,
                    hasMore: false
                )
            ]
        )
        let model = PhotoLibraryModel(repository: repository)

        await model.loadIfNeeded()

        XCTAssertEqual(model.browseMode, .timeline)
        XCTAssertEqual(model.selectedSpaceID, .personal)
        XCTAssertEqual(model.currentPath, "/home/Photos")
        XCTAssertEqual(model.items.map(\.name), ["海边.jpg"])
        XCTAssertEqual(model.timelineItems.map(\.name), ["海边.jpg"])
        XCTAssertNil(model.errorMessage)
    }

    func test继续分页使用NAS原始偏移量() async throws {
        let first = try XCTUnwrap(photoItem(name: "一.jpg", path: "/photo/一.jpg"))
        let second = try XCTUnwrap(photoItem(name: "二.jpg", path: "/photo/二.jpg"))
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                0: PhotoLibraryPage(
                    folderPath: "/photo",
                    items: [first],
                    offset: 0,
                    nextOffset: 300,
                    sourceTotal: 301,
                    hasMore: true
                ),
                300: PhotoLibraryPage(
                    folderPath: "/photo",
                    items: [second],
                    offset: 300,
                    nextOffset: 301,
                    sourceTotal: 301,
                    hasMore: false
                )
            ]
        )
        let model = PhotoLibraryModel(repository: repository)

        await model.loadIfNeeded()
        await model.loadMore()

        XCTAssertEqual(model.items.map(\.name), ["一.jpg", "二.jpg"])
        XCTAssertFalse(model.hasMore)
        let requestedOffsets = await repository.requestedOffsets()
        XCTAssertEqual(requestedOffsets, [0, 300])
    }

    func test相册模式只显示文件夹() async throws {
        let folder = try XCTUnwrap(folderItem(name: "旅行", path: "/photo/旅行"))
        let image = try XCTUnwrap(photoItem(name: "海边.jpg", path: "/photo/海边.jpg"))
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                0: PhotoLibraryPage(
                    folderPath: "/photo",
                    items: [folder, image],
                    offset: 0,
                    nextOffset: 2,
                    sourceTotal: 2,
                    hasMore: false
                )
            ]
        )
        let model = PhotoLibraryModel(repository: repository)

        await model.loadIfNeeded()
        await model.setBrowseMode(.albums)

        XCTAssertEqual(model.displayedItems.map(\.name), ["旅行"])
        XCTAssertEqual(model.mediaStats.total, 1)

        let album = try XCTUnwrap(model.displayedItems.first)
        await model.open(album)

        XCTAssertEqual(model.browseMode, .albums)
    }

    func test时间线支持类型名称筛选和多选() async throws {
        let image = try XCTUnwrap(photoItem(name: "海边.jpg", path: "/photo/海边.jpg"))
        let video = try XCTUnwrap(photoItem(name: "旅行.mp4", path: "/photo/旅行.mp4"))
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                0: PhotoLibraryPage(
                    folderPath: "/photo",
                    items: [image, video],
                    offset: 0,
                    nextOffset: 2,
                    sourceTotal: 2,
                    hasMore: false
                )
            ]
        )
        let model = PhotoLibraryModel(repository: repository)

        await model.loadIfNeeded()
        await model.setBrowseMode(.timeline)
        model.mediaFilter = .videos
        model.searchText = "旅行"
        model.select(video, extending: false)

        XCTAssertEqual(model.displayedItems.map(\.name), ["旅行.mp4"])
        XCTAssertEqual(model.selectedItems.map(\.name), ["旅行.mp4"])
    }

    func test只重试时间线中未读取的文件夹() async throws {
        let visible = try XCTUnwrap(photoItem(name: "已有.jpg", path: "/photo/已有.jpg"))
        let recovered = try XCTUnwrap(photoItem(name: "找回.jpg", path: "/photo/异常目录/找回.jpg"))
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                0: PhotoLibraryPage(
                    folderPath: "/photo",
                    items: [visible],
                    offset: 0,
                    nextOffset: 1,
                    sourceTotal: 1,
                    hasMore: false
                )
            ],
            retryItem: recovered
        )
        let model = PhotoLibraryModel(repository: repository)

        await model.loadIfNeeded()
        XCTAssertEqual(model.timelineSkippedFolderCount, 1)

        await model.retrySkippedTimelineFolders()

        XCTAssertEqual(Set(model.timelineItems.map(\.name)), ["已有.jpg", "找回.jpg"])
        XCTAssertEqual(model.timelineSkippedFolderCount, 0)
        let scans = await repository.requestedTimelineRoots()
        XCTAssertEqual(scans, [["/photo"], ["/photo/异常目录"]])
    }

    func test缩略图请求限制并发数量() async throws {
        let thumbnails = try (0..<15).map { index in
            try XCTUnwrap(photoItem(name: "照片\(index).jpg", path: "/photo/照片\(index).jpg"))
        }
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [:],
            thumbnailDelayNanoseconds: 40_000_000
        )
        let model = PhotoLibraryModel(repository: repository)

        await withTaskGroup(of: Void.self) { group in
            for item in thumbnails {
                group.addTask {
                    _ = await model.thumbnailData(for: item)
                }
            }
        }

        let peak = await repository.peakThumbnailRequestCount()
        XCTAssertEqual(peak, 6)
    }

    func testHEIC和MOV缩略图不可读时使用本机兜底() async throws {
        let image = try XCTUnwrap(photoItem(name: "实况照片.HEIC", path: "/photo/实况照片.HEIC"))
        let video = try XCTUnwrap(photoItem(name: "实况照片.MOV", path: "/photo/实况照片.MOV"))
        let repository = PhotoLibraryRepositoryStub(spaces: [.shared], pages: [:])
        let fallback = PhotoThumbnailFallbackStub()
        let model = PhotoLibraryModel(repository: repository, thumbnailFallback: fallback)

        let imageData = await model.thumbnailData(for: image)
        let videoData = await model.thumbnailData(for: video)

        XCTAssertNotNil(imageData)
        XCTAssertNotNil(videoData)
        let requestedNames = await fallback.requestedNames()
        XCTAssertEqual(requestedNames, ["实况照片.HEIC", "实况照片.MOV"])
    }

    func test普通图片不可读时不进入HEIC和MOV兜底() async throws {
        let item = try XCTUnwrap(photoItem(name: "普通照片.jpg", path: "/photo/普通照片.jpg"))
        let repository = PhotoLibraryRepositoryStub(spaces: [.shared], pages: [:])
        let fallback = PhotoThumbnailFallbackStub()
        let model = PhotoLibraryModel(repository: repository, thumbnailFallback: fallback)

        let data = await model.thumbnailData(for: item)

        XCTAssertNil(data)
        let requestedNames = await fallback.requestedNames()
        XCTAssertTrue(requestedNames.isEmpty)
    }

    func test删除项目只更新本地时间线而不重新扫描() async throws {
        let kept = try XCTUnwrap(photoItem(name: "保留.jpg", path: "/photo/旅行/保留.jpg"))
        let deleted = try XCTUnwrap(photoItem(name: "删除.jpg", path: "/photo/旅行/删除.jpg"))
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                0: PhotoLibraryPage(
                    folderPath: "/photo",
                    items: [kept, deleted],
                    offset: 0,
                    nextOffset: 2,
                    sourceTotal: 2,
                    hasMore: false
                )
            ]
        )
        let model = PhotoLibraryModel(repository: repository)
        await model.loadIfNeeded()
        model.select(deleted, extending: false)
        let scansBeforeDeletion = await repository.requestedTimelineRoots()

        model.removeDeletedItems(at: [deleted.path])

        XCTAssertEqual(model.items.map(\.name), ["保留.jpg"])
        XCTAssertEqual(model.timelineItems.map(\.name), ["保留.jpg"])
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.sourceTotal, 1)
        let scansAfterDeletion = await repository.requestedTimelineRoots()
        XCTAssertEqual(scansAfterDeletion, scansBeforeDeletion)
    }

    func test视窗完成后按显示顺序预取后续缩略图() async throws {
        let photos = try (0..<5).map { index in
            try XCTUnwrap(photoItem(name: "照片\(index).jpg", path: "/photo/照片\(index).jpg"))
        }
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                0: PhotoLibraryPage(
                    folderPath: "/photo",
                    items: photos,
                    offset: 0,
                    nextOffset: photos.count,
                    sourceTotal: photos.count,
                    hasMore: false
                )
            ]
        )
        let model = PhotoLibraryModel(repository: repository)
        await model.loadIfNeeded()

        model.thumbnailBecameVisible(photos[1])
        _ = await model.thumbnailData(for: photos[1])
        model.thumbnailRequestDidFinish(for: photos[1])
        try await Task.sleep(nanoseconds: 30_000_000)

        let names = await repository.requestedThumbnailNames()
        XCTAssertEqual(names, ["照片1.jpg", "照片2.jpg", "照片3.jpg", "照片4.jpg"])
    }

    func test离开视窗会取消后台预取并让新视窗请求先执行() async throws {
        let photos = try (0..<5).map { index in
            try XCTUnwrap(photoItem(name: "照片\(index).jpg", path: "/photo/照片\(index).jpg"))
        }
        let repository = PhotoLibraryRepositoryStub(
            spaces: [.shared],
            pages: [
                0: PhotoLibraryPage(
                    folderPath: "/photo",
                    items: photos,
                    offset: 0,
                    nextOffset: photos.count,
                    sourceTotal: photos.count,
                    hasMore: false
                )
            ],
            thumbnailDelayNanoseconds: 60_000_000
        )
        let model = PhotoLibraryModel(repository: repository)
        await model.loadIfNeeded()

        model.thumbnailBecameVisible(photos[0])
        _ = await model.thumbnailData(for: photos[0])
        model.thumbnailRequestDidFinish(for: photos[0])
        try await Task.sleep(nanoseconds: 10_000_000)
        model.thumbnailBecameHidden(photos[0])
        model.thumbnailBecameVisible(photos[3])
        _ = await model.thumbnailData(for: photos[3])
        model.thumbnailRequestDidFinish(for: photos[3])

        let names = await repository.requestedThumbnailNames()
        XCTAssertEqual(names, ["照片0.jpg", "照片1.jpg", "照片3.jpg"])
    }

    @MainActor
    func testLoadTimelineLoadsFromCacheInstantly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoCacheTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cacheStore = PhotoLibraryCacheStore(baseURL: tempDir)
        let profileID = UUID()
        let cachedItem = try XCTUnwrap(
            PhotoLibraryItem(
                FileItem(
                    profileID: profileID,
                    name: "cached.jpg",
                    path: "/home/Photos/cached.jpg",
                    kind: .file
                )
            )
        )
        let spaceCache = PhotoSpaceCache(
            items: [cachedItem],
            folderItemPaths: ["/home/Photos": ["/home/Photos/cached.jpg"]],
            lastScannedAt: Date()
        )
        cacheStore.save(spaceCache, profileID: profileID, spaceKind: .personal)

        let repository = PhotoLibraryRepositoryStub(
            spaces: [.personal],
            pages: [0: PhotoLibraryPage(folderPath: "/home/Photos", items: [cachedItem], offset: 0, nextOffset: 0, sourceTotal: 1, hasMore: false)]
        )

        let model = PhotoLibraryModel(repository: repository, profileID: profileID, cacheStore: cacheStore)
        await model.reloadSpaces()

        XCTAssertFalse(model.timelineItems.isEmpty)
        XCTAssertEqual(model.timelineItems.first?.name, "cached.jpg")
    }

    private func photoItem(name: String, path: String) -> PhotoLibraryItem? {
        PhotoLibraryItem(
            FileItem(
                profileID: UUID(),
                name: name,
                path: path,
                kind: .file
            )
        )
    }

    private func folderItem(name: String, path: String) -> PhotoLibraryItem? {
        PhotoLibraryItem(
            FileItem(
                profileID: UUID(),
                name: name,
                path: path,
                kind: .directory
            )
        )
    }
}

private actor PhotoThumbnailFallbackStub: PhotoThumbnailFallbackProviding {
    private var names: [String] = []

    nonisolated func canGenerateThumbnail(for item: PhotoLibraryItem) -> Bool {
        ["heic", "heif", "mov"].contains(item.fileExtension?.lowercased() ?? "")
    }

    func thumbnailData(for item: PhotoLibraryItem) async -> Data? {
        names.append(item.name)
        return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
    }

    func requestedNames() -> [String] {
        names
    }
}

// 供模型回归与合成页面共用，所有内容均为测试数据。
actor PhotoLibraryRepositoryStub: PhotoLibraryRepository {
    let spaces: [PhotoSpace]
    let pages: [Int: PhotoLibraryPage]
    let retryItem: PhotoLibraryItem?
    let thumbnailDelayNanoseconds: UInt64
    let fixtureThumbnailData: Data?
    private var offsets: [Int] = []
    private var timelineRoots: [[String]] = []
    private var activeThumbnailRequests = 0
    private var peakThumbnailRequests = 0
    private var thumbnailNames: [String] = []
    private var cancelledThumbnailRequests = 0

    init(
        spaces: [PhotoSpace],
        pages: [Int: PhotoLibraryPage],
        retryItem: PhotoLibraryItem? = nil,
        thumbnailDelayNanoseconds: UInt64 = 0,
        fixtureThumbnailData: Data? = nil
    ) {
        self.spaces = spaces
        self.pages = pages
        self.retryItem = retryItem
        self.thumbnailDelayNanoseconds = thumbnailDelayNanoseconds
        self.fixtureThumbnailData = fixtureThumbnailData
    }

    func discoverSpaces() async throws -> [PhotoSpace] {
        spaces
    }

    func listFolder(
        in space: PhotoSpace,
        path: String,
        offset: Int,
        limit: Int
    ) async throws -> PhotoLibraryPage {
        offsets.append(offset)
        guard let page = pages[offset] else {
            throw AppError(
                category: .notFound,
                isRetryable: false,
                safeUserMessage: "测试分页不存在。"
            )
        }
        return page
    }

    func getThumbnail(for item: PhotoLibraryItem, size: ThumbnailSize) async throws -> Data {
        activeThumbnailRequests += 1
        peakThumbnailRequests = max(peakThumbnailRequests, activeThumbnailRequests)
        thumbnailNames.append(item.name)
        defer { activeThumbnailRequests -= 1 }
        if thumbnailDelayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: thumbnailDelayNanoseconds)
            } catch {
                cancelledThumbnailRequests += 1
                throw error
            }
        }
        return fixtureThumbnailData ?? Data(item.name.utf8)
    }

    func scanTimeline(
        in space: PhotoSpace,
        startingAt folderPaths: [String],
        existingFolderItemPaths: [String: [String]] = [:],
        onUpdate: @escaping @Sendable (PhotoTimelineScanUpdate) async -> Void
    ) async throws {
        timelineRoots.append(folderPaths)
        if let retryItem {
            if folderPaths == [space.rootPath] {
                let items = pages.keys.sorted().flatMap { pages[$0]?.items ?? [] }.filter { !$0.isFolder }
                await onUpdate(
                    PhotoTimelineScanUpdate(
                        items: items,
                        scannedFolderCount: 1,
                        skippedFolderPaths: [space.rootPath + "/异常目录"]
                    )
                )
            } else {
                await onUpdate(PhotoTimelineScanUpdate(items: [retryItem], scannedFolderCount: 1))
            }
            return
        }
        let items = pages.keys.sorted().flatMap { pages[$0]?.items ?? [] }.filter { !$0.isFolder }
        await onUpdate(PhotoTimelineScanUpdate(items: items, scannedFolderCount: 1))
    }

    func requestedOffsets() -> [Int] {
        offsets
    }

    func requestedTimelineRoots() -> [[String]] {
        timelineRoots
    }

    func peakThumbnailRequestCount() -> Int {
        peakThumbnailRequests
    }

    func requestedThumbnailNames() -> [String] {
        thumbnailNames
    }

    func cancelledThumbnailRequestCount() -> Int {
        cancelledThumbnailRequests
    }
}

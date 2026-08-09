import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class FileStationPhotoRepositoryTests: XCTestCase {
    func test移动时间线默认上限固定() {
        XCTAssertEqual(PhotoTimelineScanLimits.mobileDefault.maximumFolderCount, 2_000)
        XCTAssertEqual(PhotoTimelineScanLimits.mobileDefault.maximumSourceItemCount, 50_000)
        XCTAssertEqual(PhotoTimelineScanLimits.mobileDefault.maximumMediaItemCount, 10_000)
        XCTAssertEqual(PhotoTimelineScanLimits.mobileDefault.pageSize, 200)
        XCTAssertEqual(PhotoTimelineScanLimits.legacyDefault.maximumFolderCount, .max)
        XCTAssertEqual(PhotoTimelineScanLimits.legacyDefault.maximumSourceItemCount, .max)
        XCTAssertEqual(PhotoTimelineScanLimits.legacyDefault.maximumMediaItemCount, .max)
        XCTAssertEqual(PhotoTimelineScanLimits.legacyDefault.pageSize, 500)
    }

    func test发现个人和共享照片空间() async throws {
        let profileID = UUID()
        let files = PhotoFileServerStub(
            shares: Self.page(
                path: "/",
                items: [FileItem(profileID: profileID, name: "photo", path: "/photo", kind: .directory)]
            ),
            folders: [
                "/home/Photos": Self.page(path: "/home/Photos", items: [])
            ]
        )
        let repository = FileStationPhotoRepository(files: files)

        let spaces = try await repository.discoverSpaces()

        XCTAssertEqual(spaces.map(\.kind), [PhotoSpaceKind.personal, PhotoSpaceKind.shared])
    }

    func test个人空间不可用时仍发现共享空间() async throws {
        let profileID = UUID()
        let files = PhotoFileServerStub(
            shares: Self.page(
                path: "/",
                items: [FileItem(profileID: profileID, name: "photo", path: "/photo", kind: .directory)]
            ),
            folders: [:]
        )
        let repository = FileStationPhotoRepository(files: files)

        let spaces = try await repository.discoverSpaces()

        XCTAssertEqual(spaces.map(\.kind), [PhotoSpaceKind.shared])
    }

    func test照片目录过滤不支持的文件() async throws {
        let profileID = UUID()
        let sourceItems = [
            FileItem(profileID: profileID, name: "相册", path: "/photo/相册", kind: .directory),
            FileItem(profileID: profileID, name: "照片.jpg", path: "/photo/照片.jpg", kind: .file),
            FileItem(profileID: profileID, name: "视频.mp4", path: "/photo/视频.mp4", kind: .file),
            FileItem(profileID: profileID, name: "说明.md", path: "/photo/说明.md", kind: .file)
        ]
        let files = PhotoFileServerStub(
            shares: Self.page(path: "/", items: []),
            folders: ["/photo": Self.page(path: "/photo", items: sourceItems)]
        )
        let repository = FileStationPhotoRepository(files: files)

        let result = try await repository.listFolder(
            in: PhotoSpace.shared,
            path: "/photo",
            offset: 0,
            limit: 100
        )

        XCTAssertEqual(
            result.items.map(\.kind),
            [PhotoLibraryItemKind.folder, PhotoLibraryItemKind.image, PhotoLibraryItemKind.video]
        )
        XCTAssertEqual(result.nextOffset, 4)
        XCTAssertEqual(result.sourceTotal, 4)
    }

    func test拒绝访问照片空间之外的目录() async throws {
        let repository = FileStationPhotoRepository(
            files: PhotoFileServerStub(shares: Self.page(path: "/", items: []), folders: [:])
        )

        do {
            _ = try await repository.listFolder(
                in: PhotoSpace.shared,
                path: "/homes/other-user/Photos",
                offset: 0,
                limit: 100
            )
            XCTFail("应该拒绝照片空间之外的目录")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .permissionDenied)
        }
    }

    func test拒绝通过上级路径离开照片空间() async throws {
        let repository = FileStationPhotoRepository(
            files: PhotoFileServerStub(shares: Self.page(path: "/", items: []), folders: [:])
        )

        do {
            _ = try await repository.listFolder(
                in: PhotoSpace.shared,
                path: "/photo/../homes/other-user",
                offset: 0,
                limit: 100
            )
            XCTFail("应该拒绝包含上级跳转的路径")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .permissionDenied)
        }
    }

    func test时间线递归扫描文件夹并只返回媒体() async throws {
        let profileID = UUID()
        let early = FileItem(
            profileID: profileID,
            name: "早期.jpg",
            path: "/photo/早期.jpg",
            kind: .file,
            times: FileTimes(modifiedAt: Date(timeIntervalSince1970: 100), createdAt: nil, accessedAt: nil)
        )
        let recent = FileItem(
            profileID: profileID,
            name: "近期.mp4",
            path: "/photo/近期.mp4",
            kind: .file,
            times: FileTimes(modifiedAt: Date(timeIntervalSince1970: 200), createdAt: nil, accessedAt: nil)
        )
        let files = PhotoFileServerStub(
            shares: Self.page(path: "/", items: []),
            folders: [
                "/photo": Self.page(
                    path: "/photo",
                    items: [
                        early,
                        recent,
                        FileItem(profileID: profileID, name: "目录", path: "/photo/目录", kind: .directory)
                    ]
                ),
                "/photo/目录": Self.page(path: "/photo/目录", items: [])
            ]
        )

        let collector = PhotoTimelineCollector()
        try await FileStationPhotoRepository(files: files).scanTimeline(in: .shared) { update in
            await collector.append(update)
        }
        let items = await collector.items()

        XCTAssertEqual(items.map(\.name), ["近期.mp4", "早期.jpg"])
    }

    func test时间线跳过单个异常子目录并保留已有照片() async throws {
        let profileID = UUID()
        let rootItems = [
            FileItem(profileID: profileID, name: "可用.jpg", path: "/photo/可用.jpg", kind: .file),
            FileItem(profileID: profileID, name: "异常目录", path: "/photo/异常目录", kind: .directory)
        ]
        let files = PhotoFileServerStub(
            shares: Self.page(path: "/", items: []),
            folders: ["/photo": Self.page(path: "/photo", items: rootItems)],
            folderErrors: [
                "/photo/异常目录": AppError(
                    category: .invalidResponse,
                    isRetryable: false,
                    safeUserMessage: "测试异常。"
                )
            ]
        )
        let collector = PhotoTimelineCollector()

        try await FileStationPhotoRepository(files: files).scanTimeline(in: .shared) { update in
            await collector.append(update)
        }

        let names = await collector.items().map(\.name)
        let skippedFolders = await collector.skippedFolders()
        XCTAssertEqual(names, ["可用.jpg"])
        XCTAssertEqual(skippedFolders, 1)
    }

    func test时间线增量对比识别已在NAS中删除的照片() async throws {
        let profileID = UUID()
        let rootItems = [
            FileItem(profileID: profileID, name: "新图.jpg", path: "/photo/新图.jpg", kind: .file)
        ]
        let files = PhotoFileServerStub(
            shares: Self.page(path: "/", items: []),
            folders: ["/photo": Self.page(path: "/photo", items: rootItems)]
        )

        let existingPaths: [String: [String]] = [
            "/photo": ["/photo/旧图.jpg", "/photo/新图.jpg"]
        ]
        let collector = PhotoTimelineCollector()

        try await FileStationPhotoRepository(files: files).scanTimeline(
            in: .shared,
            existingFolderItemPaths: existingPaths
        ) { update in
            await collector.append(update)
        }

        let removed = await collector.removedPaths()
        XCTAssertEqual(removed, ["/photo/旧图.jpg"])
    }

    func test有界时间线按广度优先扫描并跳过系统目录() async throws {
        let profileID = UUID()
        let files = PhotoFileServerStub(
            shares: Self.page(path: "/", items: []),
            folders: [
                "/photo": Self.page(path: "/photo", items: [
                    FileItem(profileID: profileID, name: "B", path: "/photo/B", kind: .directory),
                    FileItem(profileID: profileID, name: "A", path: "/photo/A", kind: .directory),
                    FileItem(profileID: profileID, name: "@eaDir", path: "/photo/@eaDir", kind: .directory),
                    FileItem(profileID: profileID, name: "#recycle", path: "/photo/#recycle", kind: .directory),
                    FileItem(profileID: profileID, name: "根.jpg", path: "/photo/根.jpg", kind: .file)
                ]),
                "/photo/B": Self.page(path: "/photo/B", items: [
                    FileItem(profileID: profileID, name: "B.jpg", path: "/photo/B/B.jpg", kind: .file)
                ]),
                "/photo/A": Self.page(path: "/photo/A", items: [
                    FileItem(profileID: profileID, name: "A.jpg", path: "/photo/A/A.jpg", kind: .file)
                ])
            ]
        )

        let result = try await FileStationPhotoRepository(files: files).scanTimeline(
            in: .shared,
            startingAt: [PhotoSpace.shared.rootPath],
            limits: Self.limits()
        ) { _ in }

        XCTAssertEqual(result.items.map(\.path), ["/photo/根.jpg", "/photo/B/B.jpg", "/photo/A/A.jpg"])
        XCTAssertEqual(result.scannedFolderCount, 3)
        XCTAssertEqual(result.sourceItemCount, 7)
        XCTAssertEqual(result.completion, .complete)
        let requestedPaths = await files.requestedPaths()
        let requestedLimits = await files.requestedLimits()
        XCTAssertEqual(requestedPaths, ["/photo", "/photo/B", "/photo/A"])
        XCTAssertEqual(requestedLimits, [2, 2, 2])
    }

    func test文件夹上限返回截断且不扫描后续目录() async throws {
        let profileID = UUID()
        let files = PhotoFileServerStub(
            shares: Self.page(path: "/", items: []),
            folders: [
                "/photo": Self.page(path: "/photo", items: [
                    FileItem(profileID: profileID, name: "子目录", path: "/photo/子目录", kind: .directory)
                ]),
                "/photo/子目录": Self.page(path: "/photo/子目录", items: [])
            ]
        )

        let result = try await FileStationPhotoRepository(files: files).scanTimeline(
            in: .shared,
            startingAt: [PhotoSpace.shared.rootPath],
            limits: Self.limits(maximumFolderCount: 1)
        ) { _ in }

        XCTAssertEqual(result.completion, .truncated)
        XCTAssertEqual(result.scannedFolderCount, 1)
        let requestedPaths = await files.requestedPaths()
        XCTAssertEqual(requestedPaths, ["/photo"])
    }

    func test原始项目上限截断且旧更新收到已扫描媒体() async throws {
        let profileID = UUID()
        let files = PhotoFileServerStub(
            shares: Self.page(path: "/", items: []),
            folders: [
                "/photo": Self.page(path: "/photo", items: [
                    FileItem(profileID: profileID, name: "一.jpg", path: "/photo/一.jpg", kind: .file),
                    FileItem(profileID: profileID, name: "二.jpg", path: "/photo/二.jpg", kind: .file),
                    FileItem(profileID: profileID, name: "三.jpg", path: "/photo/三.jpg", kind: .file)
                ])
            ]
        )
        let collector = PhotoTimelineCollector()

        let result = try await FileStationPhotoRepository(files: files).scanTimeline(
            in: .shared,
            startingAt: [PhotoSpace.shared.rootPath],
            limits: Self.limits(maximumSourceItemCount: 2)
        ) { update in
            await collector.append(update)
        }

        XCTAssertEqual(result.completion, .truncated)
        XCTAssertEqual(result.sourceItemCount, 2)
        XCTAssertEqual(result.items.map(\.name), ["一.jpg", "二.jpg"])
        let collectedNames = await collector.items().map(\.name)
        XCTAssertEqual(collectedNames, ["一.jpg", "二.jpg"])
    }

    func test媒体项目上限严格截断() async throws {
        let profileID = UUID()
        let files = PhotoFileServerStub(
            shares: Self.page(path: "/", items: []),
            folders: [
                "/photo": Self.page(path: "/photo", items: [
                    FileItem(profileID: profileID, name: "一.jpg", path: "/photo/一.jpg", kind: .file),
                    FileItem(profileID: profileID, name: "二.jpg", path: "/photo/二.jpg", kind: .file)
                ])
            ]
        )

        let result = try await FileStationPhotoRepository(files: files).scanTimeline(
            in: .shared,
            startingAt: [PhotoSpace.shared.rootPath],
            limits: Self.limits(maximumMediaItemCount: 1)
        ) { _ in }

        XCTAssertEqual(result.completion, .truncated)
        XCTAssertEqual(result.items.map(\.name), ["一.jpg"])
        XCTAssertEqual(result.sourceItemCount, 1)
    }

    func test取消时间线扫描向调用方抛出() async throws {
        let files = PhotoFileServerStub(
            shares: Self.page(path: "/", items: []),
            folders: [:],
            cancellationPaths: [PhotoSpace.shared.rootPath]
        )

        do {
            _ = try await FileStationPhotoRepository(files: files).scanTimeline(
                in: .shared,
                startingAt: [PhotoSpace.shared.rootPath],
                limits: Self.limits()
            ) { _ in }
            XCTFail("取消必须抛给调用方")
        } catch is CancellationError {
            // 预期路径。
        }
    }

    func test时间线根目录失败向调用方抛出() async throws {
        let expected = AppError(
            category: .networkUnavailable,
            isRetryable: true,
            safeUserMessage: "测试网络错误"
        )
        let files = PhotoFileServerStub(
            shares: Self.page(path: "/", items: []),
            folders: [:],
            folderErrors: [PhotoSpace.shared.rootPath: expected]
        )

        do {
            _ = try await FileStationPhotoRepository(files: files).scanTimeline(
                in: .shared,
                startingAt: [PhotoSpace.shared.rootPath],
                limits: Self.limits()
            ) { _ in }
            XCTFail("根目录失败不得伪装为空结果")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .networkUnavailable)
        }
    }

    func test时间线拒绝零进展分页() async throws {
        let files = PhotoFileServerStub(
            shares: Self.page(path: "/", items: []),
            folders: [
                "/photo": FilePage(
                    folderPath: "/photo",
                    items: [],
                    offset: 0,
                    total: 2,
                    hasMore: true
                )
            ]
        )

        do {
            _ = try await FileStationPhotoRepository(files: files).scanTimeline(
                in: .shared,
                startingAt: [PhotoSpace.shared.rootPath],
                limits: Self.limits()
            ) { _ in }
            XCTFail("零进展分页必须失败")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .invalidResponse)
        }
    }

    func test时间线拒绝跨页总数漂移() async throws {
        let profileID = UUID()
        let files = PhotoFileServerStub(
            shares: Self.page(path: "/", items: []),
            folders: [:],
            folderPages: [
                "/photo": [
                    0: FilePage(
                        folderPath: "/photo",
                        items: [
                            FileItem(profileID: profileID, name: "一.jpg", path: "/photo/一.jpg", kind: .file)
                        ],
                        offset: 0,
                        total: 2,
                        hasMore: true
                    ),
                    1: FilePage(
                        folderPath: "/photo",
                        items: [
                            FileItem(profileID: profileID, name: "二.jpg", path: "/photo/二.jpg", kind: .file)
                        ],
                        offset: 1,
                        total: 3,
                        hasMore: false
                    )
                ]
            ]
        )

        do {
            _ = try await FileStationPhotoRepository(files: files).scanTimeline(
                in: .shared,
                startingAt: [PhotoSpace.shared.rootPath],
                limits: Self.limits(pageSize: 1)
            ) { _ in }
            XCTFail("跨页 total 漂移必须失败")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .invalidResponse)
        }
    }

    private static func limits(
        maximumFolderCount: Int = 10,
        maximumSourceItemCount: Int = 100,
        maximumMediaItemCount: Int = 100,
        pageSize: Int = 2
    ) -> PhotoTimelineScanLimits {
        PhotoTimelineScanLimits(
            maximumFolderCount: maximumFolderCount,
            maximumSourceItemCount: maximumSourceItemCount,
            maximumMediaItemCount: maximumMediaItemCount,
            pageSize: pageSize
        )
    }

    private static func page(path: String, items: [FileItem]) -> FilePage {
        FilePage(
            folderPath: path,
            items: items,
            offset: 0,
            total: items.count,
            hasMore: false
        )
    }
}

private actor PhotoTimelineCollector {
    private var collected: [PhotoLibraryItem] = []
    private var removed: [String] = []
    private var skipped = 0

    func append(_ update: PhotoTimelineScanUpdate) {
        collected.append(contentsOf: update.items)
        removed.append(contentsOf: update.removedPaths)
        skipped = update.skippedFolderCount
    }

    func items() -> [PhotoLibraryItem] {
        collected.sorted { lhs, rhs in
            let left = lhs.createdAt ?? lhs.modifiedAt ?? .distantPast
            let right = rhs.createdAt ?? rhs.modifiedAt ?? .distantPast
            return left > right
        }
    }

    func removedPaths() -> [String] { removed }

    func skippedFolders() -> Int { skipped }
}

private actor PhotoFileServerStub: PhotoFileServing {
    let shares: FilePage
    let folders: [String: FilePage]
    let searchItems: [FileItem]
    let folderErrors: [String: AppError]
    let cancellationPaths: Set<String>
    let folderPages: [String: [Int: FilePage]]
    private var requests: [(path: String, offset: Int, limit: Int)] = []

    init(
        shares: FilePage,
        folders: [String: FilePage],
        searchItems: [FileItem] = [],
        folderErrors: [String: AppError] = [:],
        cancellationPaths: Set<String> = [],
        folderPages: [String: [Int: FilePage]] = [:]
    ) {
        self.shares = shares
        self.folders = folders
        self.searchItems = searchItems
        self.folderErrors = folderErrors
        self.cancellationPaths = cancellationPaths
        self.folderPages = folderPages
    }

    func listShares(offset: Int, limit: Int) async throws -> FilePage {
        shares
    }

    func listFolder(path: String, offset: Int, limit: Int) async throws -> FilePage {
        requests.append((path, offset, limit))
        if cancellationPaths.contains(path) { throw CancellationError() }
        if let error = folderErrors[path] { throw error }
        if let page = folderPages[path]?[offset] { return page }
        guard let page = folders[path] else {
            throw AppError(
                category: .notFound,
                isRetryable: false,
                safeUserMessage: "照片空间不存在。"
            )
        }
        return page
    }

    func requestedPaths() -> [String] {
        requests.map(\.path)
    }

    func requestedLimits() -> [Int] {
        requests.map(\.limit)
    }

    func getThumbnail(path: String, size: ThumbnailSize) async throws -> Data {
        Data(path.utf8)
    }

    func search(folderPath: String, query: String) async throws -> [FileItem] {
        searchItems
    }
}

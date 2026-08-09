import DsmCore
import Foundation
import DsmLocalization

/// 只使用 Synology 官方登录和 File Station API 的基础照片库 Adapter。
public struct FileStationPhotoRepository: PhotoLibraryRepository, Sendable {
    private let files: any PhotoFileServing

    public init(files: any PhotoFileServing) {
        self.files = files
    }

    public func discoverSpaces() async throws -> [PhotoSpace] {
        let shares = try await files.listShares(offset: 0, limit: 500).items
        var result: [PhotoSpace] = []

        do {
            _ = try await files.listFolder(
                path: PhotoSpace.personal.rootPath,
                offset: 0,
                limit: 1
            )
            result.append(.personal)
        } catch let error as AppError where Self.spaceMayBeUnavailable(error) {
            // 个人空间可能未启用；这不应阻止共享空间继续使用。
        }

        if shares.contains(where: {
            $0.path.caseInsensitiveCompare(PhotoSpace.shared.rootPath) == .orderedSame
        }) {
            result.append(.shared)
        }

        return result
    }

    public func listFolder(
        in space: PhotoSpace,
        path: String,
        offset: Int,
        limit: Int
    ) async throws -> PhotoLibraryPage {
        guard Self.contains(path: path, in: space.rootPath) else {
            throw AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.5dcc7495647890e0")
            )
        }

        let page = try await files.listFolder(
            path: path,
            offset: max(0, offset),
            limit: max(1, limit)
        )
        return PhotoLibraryPage(
            folderPath: page.folderPath,
            items: page.items.compactMap { PhotoLibraryItem($0) },
            offset: page.offset,
            nextOffset: page.offset + page.items.count,
            sourceTotal: page.total,
            hasMore: page.hasMore
        )
    }

    public func getThumbnail(for item: PhotoLibraryItem, size: ThumbnailSize) async throws -> Data {
        guard !item.isFolder else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.7cd208674fa4ddd9")
            )
        }
        return try await files.getThumbnail(path: item.path, size: size)
    }

    public func scanTimeline(
        in space: PhotoSpace,
        startingAt folderPaths: [String],
        existingFolderItemPaths: [String: [String]] = [:],
        onUpdate: @escaping @Sendable (PhotoTimelineScanUpdate) async -> Void
    ) async throws {
        _ = try await scanTimeline(
            in: space,
            startingAt: folderPaths,
            existingFolderItemPaths: existingFolderItemPaths,
            limits: .legacyDefault,
            onUpdate: onUpdate
        )
    }

    public func scanTimeline(
        in space: PhotoSpace,
        startingAt folderPaths: [String],
        existingFolderItemPaths: [String: [String]] = [:],
        limits: PhotoTimelineScanLimits,
        onUpdate: @escaping @Sendable (PhotoTimelineScanUpdate) async -> Void
    ) async throws -> PhotoTimelineScanResult {
        guard !folderPaths.isEmpty,
              folderPaths.allSatisfy({ Self.contains(path: $0, in: space.rootPath) }) else {
            throw AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.7074fa008dad7ab4")
            )
        }
        guard limits.maximumFolderCount > 0,
              limits.maximumSourceItemCount > 0,
              limits.maximumMediaItemCount > 0,
              limits.pageSize > 0 else {
            throw Self.invalidTimelineResponse()
        }

        // 批量聚合，降低每次扫描后 UI 重算的频率。
        // 每累积超过 500 个项目时统一刷新一次。
        let itemBatchThreshold = 500
        var visitedFolders = Set<String>()
        var queuedFolders = Set<String>()
        var skippedFolderPaths = Set<String>()
        var batchedItems: [PhotoLibraryItem] = []
        var batchedRemoved: [String] = []
        var resultItems: [PhotoLibraryItem] = []
        var resultItemPaths = Set<String>()
        var sourceItemCount = 0
        var mediaItemCount = 0
        var completion = PhotoTimelineScanCompletion.complete

        func flushBatch(isFinal: Bool = false) async {
            if batchedItems.isEmpty && batchedRemoved.isEmpty && !isFinal { return }
            await onUpdate(
                PhotoTimelineScanUpdate(
                    items: batchedItems,
                    removedPaths: batchedRemoved,
                    scannedFolderCount: visitedFolders.count,
                    skippedFolderPaths: skippedFolderPaths.sorted()
                )
            )
            batchedItems.removeAll(keepingCapacity: true)
            batchedRemoved.removeAll(keepingCapacity: true)
        }

        // 队列顺序即广度优先顺序；入队时去重，避免交叉起点或异常响应重复扫描。
        var queue: [String] = []
        for path in folderPaths where queuedFolders.insert(path).inserted {
            queue.append(path)
        }
        var queueIndex = 0

        while queueIndex < queue.count {
            try Task.checkCancellation()
            guard visitedFolders.count < limits.maximumFolderCount,
                  sourceItemCount < limits.maximumSourceItemCount,
                  mediaItemCount < limits.maximumMediaItemCount else {
                completion = .truncated
                break
            }

            let folderPath = queue[queueIndex]
            queueIndex += 1
            guard visitedFolders.insert(folderPath).inserted else { continue }

            do {
                var offset = 0
                var expectedTotal: Int?
                var discovered: [PhotoLibraryItem] = []
                var discoveredPaths = Set<String>()
                var subfolders: [String] = []
                var completedFolder = false
                var reachedLimit = false

                while true {
                    try Task.checkCancellation()
                    guard sourceItemCount < limits.maximumSourceItemCount,
                          mediaItemCount < limits.maximumMediaItemCount else {
                        completion = .truncated
                        reachedLimit = true
                        break
                    }

                    let page = try await files.listFolder(
                        path: folderPath,
                        offset: offset,
                        limit: limits.pageSize
                    )
                    guard page.offset == offset,
                          page.folderPath == folderPath,
                          page.offset >= 0,
                          page.total >= 0,
                          page.items.count <= Int.max - page.offset,
                          page.total >= page.offset + page.items.count else {
                        throw Self.invalidTimelineResponse()
                    }
                    if let expectedTotal {
                        guard page.total == expectedTotal else {
                            throw Self.invalidTimelineResponse()
                        }
                    } else {
                        expectedTotal = page.total
                    }
                    if page.hasMore && page.items.isEmpty {
                        throw Self.invalidTimelineResponse()
                    }

                    for file in page.items {
                        guard sourceItemCount < limits.maximumSourceItemCount,
                              mediaItemCount < limits.maximumMediaItemCount else {
                            completion = .truncated
                            reachedLimit = true
                            break
                        }
                        sourceItemCount += 1

                        if file.isDirectory {
                            guard !file.name.hasPrefix("@"), file.name != "#recycle" else { continue }
                            if Self.contains(path: file.path, in: space.rootPath),
                               queuedFolders.insert(file.path).inserted {
                                subfolders.append(file.path)
                            }
                        } else if let item = PhotoLibraryItem(file) {
                            mediaItemCount += 1
                            if !resultItemPaths.contains(item.path),
                               discoveredPaths.insert(item.path).inserted {
                                discovered.append(item)
                            }
                        }
                    }

                    if reachedLimit { break }

                    let nextOffset = page.offset + page.items.count
                    if page.hasMore {
                        guard nextOffset > offset, nextOffset < page.total else {
                            throw Self.invalidTimelineResponse()
                        }
                        offset = nextOffset
                    } else {
                        completedFolder = true
                        break
                    }
                }

                if completedFolder {
                    let currentPaths = Set(discovered.map(\.path))
                    let previousPaths = Set(existingFolderItemPaths[folderPath] ?? [])
                    batchedRemoved.append(contentsOf: previousPaths.subtracting(currentPaths))
                    queue.append(contentsOf: subfolders)
                }
                for item in discovered where resultItemPaths.insert(item.path).inserted {
                    resultItems.append(item)
                }
                batchedItems.append(contentsOf: discovered)
                if reachedLimit {
                    await flushBatch()
                    break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard folderPath != space.rootPath else { throw error }
                skippedFolderPaths.insert(folderPath)
            }

            if batchedItems.count >= itemBatchThreshold {
                await flushBatch()
            }
        }

        await flushBatch(isFinal: true)
        return PhotoTimelineScanResult(
            items: resultItems,
            scannedFolderCount: visitedFolders.count,
            skippedFolderPaths: skippedFolderPaths.sorted(),
            sourceItemCount: sourceItemCount,
            completion: completion
        )
    }

    private static func contains(path: String, in rootPath: String) -> Bool {
        let candidate = path.split(separator: "/", omittingEmptySubsequences: true)
        let root = rootPath.split(separator: "/", omittingEmptySubsequences: true)
        guard candidate.count >= root.count,
              !candidate.contains("."),
              !candidate.contains("..") else {
            return false
        }
        return Array(candidate.prefix(root.count)) == root
    }

    private static func spaceMayBeUnavailable(_ error: AppError) -> Bool {
        error.category == .notFound || error.category == .permissionDenied
    }

    private static func invalidTimelineResponse() -> AppError {
        AppError(
            category: .invalidResponse,
            isRetryable: true,
            safeUserMessage: L10n.string("ui.615dbf7c58c2a074")
        )
    }
}

import DsmCore
import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoLibraryModel {
    static let pageSize = 300
    static let prefetchLimit = 12
    static let pageCacheLimitPerProfile = 12

    private(set) var activeProfileID: UUID?
    private(set) var profiles: [UUID: MobilePhotoLibraryProfileState] = [:]

    @ObservationIgnored private let thumbnailStore: MobilePhotoThumbnailStore
    @ObservationIgnored private var repositories: [UUID: any PhotoLibraryRepository] = [:]
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTasks: [UUID: Task<Data?, Never>] = [:]
    @ObservationIgnored private var generation = 0

    init(thumbnailStore: MobilePhotoThumbnailStore = MobilePhotoThumbnailStore()) {
        self.thumbnailStore = thumbnailStore
    }

    var state: MobilePhotoLibraryProfileState {
        guard let activeProfileID else { return MobilePhotoLibraryProfileState() }
        return profiles[activeProfileID] ?? MobilePhotoLibraryProfileState()
    }

    func activate(
        profileID: UUID?,
        repository: (any PhotoLibraryRepository)?
    ) async {
        cancelAllWork()
        guard let profileID else {
            activeProfileID = nil
            return
        }
        guard let repository else {
            repositories[profileID] = nil
            activeProfileID = nil
            return
        }
        activeProfileID = profileID
        repositories[profileID] = repository
        if profiles[profileID] == nil {
            profiles[profileID] = MobilePhotoLibraryProfileState()
            await reload()
        }
    }

    func deactivate() {
        let profileID = activeProfileID
        cancelAllWork()
        if let profileID {
            repositories[profileID] = nil
        }
        activeProfileID = nil
    }

    func reload() async {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID] else { return }
        if let space = state.selectedSpace, !state.currentPath.isEmpty {
            let preservesContent = hasLoadedCurrentPage()
            await replaceFolder(
                space: space,
                path: state.currentPath,
                history: state.pathHistory,
                profileID: profileID,
                repository: repository,
                preservesContent: preservesContent
            )
        } else {
            await discoverSpaces(profileID: profileID, repository: repository)
        }
    }

    func selectSpace(_ kind: PhotoSpaceKind) async {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID],
              let space = state.spaces.first(where: { $0.kind == kind }),
              state.selectedSpace?.kind != kind else { return }
        if restoreCachedPage(space: space, path: space.rootPath, history: []) { return }
        await replaceFolder(
            space: space,
            path: space.rootPath,
            history: [],
            profileID: profileID,
            repository: repository,
            preservesContent: false
        )
    }

    func openFolder(_ item: PhotoLibraryItem) async {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID],
              let space = state.selectedSpace,
              let canonicalItem = canonicalItem(matching: item),
              canonicalItem.profileID == profileID,
              canonicalItem.isFolder else { return }
        var history = state.pathHistory
        history.append(state.currentPath)
        if restoreCachedPage(space: space, path: canonicalItem.path, history: history) { return }
        await replaceFolder(
            space: space,
            path: canonicalItem.path,
            history: history,
            profileID: profileID,
            repository: repository,
            preservesContent: hasLoadedCurrentPage()
        )
    }

    func goBack() async {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID],
              let space = state.selectedSpace,
              let destination = state.pathHistory.last else { return }
        var history = state.pathHistory
        history.removeLast()
        if restoreCachedPage(space: space, path: destination, history: history) { return }
        await replaceFolder(
            space: space,
            path: destination,
            history: history,
            profileID: profileID,
            repository: repository,
            preservesContent: false
        )
    }

    func setFilter(_ filter: MobilePhotoFilter) {
        guard filter != state.filter else { return }
        cancelAllWork()
        updateActive {
            $0.filter = filter
            let path = $0.location.path
            let key = $0.selectedSpace.map { space in
                MobilePhotoPageCacheKey(spaceKind: space.kind, path: path, filter: filter)
            }
            if let key, let cached = $0.caches[key] {
                $0.page = cached
                Self.touchCache(key, profile: &$0)
            } else {
                $0.page.items = Self.visibleItems(from: $0.page.sourceItems, filter: filter)
                if let key { Self.storeCache($0.page, key: key, profile: &$0) }
            }
            $0.pageState = Self.pageState(items: $0.page.items, filter: filter)
            $0.errorCategory = nil
            $0.isRefreshing = false
            $0.isLoadingMore = false
            $0.loadMoreFailed = false
        }
    }

    func loadMore() async {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID],
              let space = state.selectedSpace,
              state.page.hasMore,
              !state.isLoadingMore else { return }
        let path = state.currentPath
        let filter = state.filter
        let requestedOffset = state.page.nextOffset
        let requestGeneration = beginRequest { profile in
            profile.isLoadingMore = true
            profile.loadMoreFailed = false
            profile.errorCategory = nil
        }

        let task = Task { [weak self] in
            do {
                let page = try await repository.listFolder(
                    in: space,
                    path: path,
                    offset: requestedOffset,
                    limit: Self.pageSize
                )
                try Task.checkCancellation()
                try self?.applyPage(
                    page,
                    requestedOffset: requestedOffset,
                    profileID: profileID,
                    generation: requestGeneration,
                    space: space,
                    path: path,
                    history: self?.state.pathHistory ?? [],
                    filter: filter,
                    appending: true
                )
            } catch is CancellationError {
                self?.finishCancellation(profileID: profileID, generation: requestGeneration)
            } catch {
                self?.finishLoadMoreFailure(
                    error,
                    profileID: profileID,
                    generation: requestGeneration
                )
            }
        }
        requestTask = task
        await task.value
    }

    func thumbnailData(
        for item: PhotoLibraryItem
    ) async -> Data? {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID],
              let canonicalItem = canonicalItem(matching: item),
              canonicalItem.profileID == profileID,
              canonicalItem.kind == .image else { return nil }

        let requestGeneration = generation
        let path = state.currentPath
        let filter = state.filter
        let token = UUID()
        let key = Self.thumbnailKey(profileID: profileID, item: canonicalItem)
        let store = thumbnailStore
        let task = Task<Data?, Never> {
            await store.data(
                for: key,
                namespace: profileID.uuidString,
                priority: .visible
            ) {
                try await repository.getThumbnail(for: canonicalItem, size: .small)
            }
        }
        thumbnailTasks[token] = task
        let data = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        thumbnailTasks[token] = nil

        guard isCurrent(profileID: profileID, generation: requestGeneration),
              state.currentPath == path,
              state.filter == filter,
              self.canonicalItem(matching: canonicalItem) != nil else { return nil }
        return data
    }

    func prefetchThumbnails(
        _ items: [PhotoLibraryItem]
    ) {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID] else { return }
        prefetchTask?.cancel()
        let requestGeneration = generation
        let path = state.currentPath
        let filter = state.filter
        let canonicalItems: [PhotoLibraryItem] = items.compactMap { item in
            guard let canonicalItem = canonicalItem(matching: item),
                  canonicalItem.profileID == profileID,
                  canonicalItem.kind == .image else { return nil }
            return canonicalItem
        }
        let candidates = Array(canonicalItems.prefix(Self.prefetchLimit))
        guard !candidates.isEmpty else { return }

        let store = thumbnailStore
        prefetchTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for item in candidates {
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        let key = Self.thumbnailKey(profileID: profileID, item: item)
                        _ = await store.data(
                            for: key,
                            namespace: profileID.uuidString,
                            priority: .prefetch
                        ) {
                            try await repository.getThumbnail(for: item, size: .small)
                        }
                    }
                }
            }
            guard !Task.isCancelled,
                  isCurrent(profileID: profileID, generation: requestGeneration),
                  state.currentPath == path,
                  state.filter == filter else { return }
            prefetchTask = nil
        }
    }

    func cancelAllWork() {
        requestTask?.cancel()
        requestTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        for task in thumbnailTasks.values { task.cancel() }
        thumbnailTasks.removeAll()
        generation &+= 1
        updateActive {
            $0.isDiscoveringSpaces = false
            $0.isRefreshing = false
            $0.isLoadingMore = false
        }
    }

    func thumbnailCacheCost() async -> Int {
        await thumbnailStore.cachedCost()
    }

    func clearThumbnailCache() async {
        prefetchTask?.cancel()
        prefetchTask = nil
        for task in thumbnailTasks.values { task.cancel() }
        thumbnailTasks.removeAll()
        await thumbnailStore.removeAll()
    }

    func purge(profileID: UUID) async {
        if activeProfileID == profileID {
            cancelAllWork()
            activeProfileID = nil
        }
        repositories[profileID] = nil
        profiles[profileID] = nil
        await thumbnailStore.removeAll(namespace: profileID.uuidString)
    }

    private func discoverSpaces(
        profileID: UUID,
        repository: any PhotoLibraryRepository
    ) async {
        let requestGeneration = beginRequest { profile in
            profile.isDiscoveringSpaces = true
            profile.isRefreshing = false
            profile.isLoadingMore = false
            profile.loadMoreFailed = false
            profile.errorCategory = nil
            if profile.spaces.isEmpty {
                profile.pageState = .loading
            }
        }
        let preferredKind = state.selectedSpace?.kind
        let task = Task { [weak self] in
            do {
                let spaces = try await repository.discoverSpaces()
                try Task.checkCancellation()
                guard let self,
                      self.isCurrent(profileID: profileID, generation: requestGeneration) else { return }
                guard let destination = spaces.first(where: { $0.kind == preferredKind }) ?? spaces.first else {
                    self.updateActive {
                        $0.spaces = []
                        $0.location = MobilePhotoLocation()
                        $0.page = MobilePhotoPage()
                        $0.pageState = .empty
                        $0.isDiscoveringSpaces = false
                    }
                    return
                }

                let page = try await repository.listFolder(
                    in: destination,
                    path: destination.rootPath,
                    offset: 0,
                    limit: Self.pageSize
                )
                try Task.checkCancellation()
                try self.applyPage(
                    page,
                    requestedOffset: 0,
                    profileID: profileID,
                    generation: requestGeneration,
                    space: destination,
                    path: destination.rootPath,
                    history: [],
                    filter: self.state.filter,
                    appending: false,
                    discoveredSpaces: spaces
                )
            } catch is CancellationError {
                self?.finishCancellation(profileID: profileID, generation: requestGeneration)
            } catch {
                self?.finishReplaceFailure(
                    error,
                    profileID: profileID,
                    generation: requestGeneration,
                    preservesContent: false
                )
            }
        }
        requestTask = task
        await task.value
    }

    private func replaceFolder(
        space: PhotoSpace,
        path: String,
        history: [String],
        profileID: UUID,
        repository: any PhotoLibraryRepository,
        preservesContent: Bool
    ) async {
        let filter = state.filter
        let requestGeneration = beginRequest { profile in
            profile.isDiscoveringSpaces = false
            profile.isRefreshing = preservesContent
            profile.isLoadingMore = false
            profile.loadMoreFailed = false
            profile.errorCategory = nil
            if !preservesContent {
                profile.page = MobilePhotoPage()
                profile.pageState = .loading
            }
        }
        let task = Task { [weak self] in
            do {
                let page = try await repository.listFolder(
                    in: space,
                    path: path,
                    offset: 0,
                    limit: Self.pageSize
                )
                try Task.checkCancellation()
                try self?.applyPage(
                    page,
                    requestedOffset: 0,
                    profileID: profileID,
                    generation: requestGeneration,
                    space: space,
                    path: path,
                    history: history,
                    filter: filter,
                    appending: false
                )
            } catch is CancellationError {
                self?.finishCancellation(profileID: profileID, generation: requestGeneration)
            } catch {
                self?.finishReplaceFailure(
                    error,
                    profileID: profileID,
                    generation: requestGeneration,
                    preservesContent: preservesContent
                )
            }
        }
        requestTask = task
        await task.value
    }

    private func beginRequest(
        _ update: (inout MobilePhotoLibraryProfileState) -> Void
    ) -> Int {
        requestTask?.cancel()
        prefetchTask?.cancel()
        for task in thumbnailTasks.values { task.cancel() }
        thumbnailTasks.removeAll()
        generation &+= 1
        updateActive(update)
        return generation
    }

    private func applyPage(
        _ page: PhotoLibraryPage,
        requestedOffset: Int,
        profileID: UUID,
        generation requestGeneration: Int,
        space: PhotoSpace,
        path: String,
        history: [String],
        filter: MobilePhotoFilter,
        appending: Bool,
        discoveredSpaces: [PhotoSpace]? = nil
    ) throws {
        guard isCurrent(profileID: profileID, generation: requestGeneration),
              state.filter == filter else { return }
        guard page.folderPath == path, page.offset == requestedOffset else {
            throw MobilePhotoLibraryError.misalignedPage
        }
        guard page.items.allSatisfy({ $0.profileID == profileID }) else {
            throw MobilePhotoLibraryError.crossProfileItem
        }
        guard !page.hasMore || page.nextOffset > requestedOffset else {
            throw MobilePhotoLibraryError.zeroProgress
        }
        guard page.nextOffset >= requestedOffset,
              page.sourceTotal >= page.nextOffset,
              page.hasMore == (page.nextOffset < page.sourceTotal) else {
            throw MobilePhotoLibraryError.inconsistentTotal
        }

        let existing = appending ? state.page.sourceItems : []
        let sourceItems = Self.deduplicated(existing + page.items)
        let visible = Self.visibleItems(from: sourceItems, filter: filter)
        updateActive {
            if let discoveredSpaces { $0.spaces = discoveredSpaces }
            $0.location = MobilePhotoLocation(space: space, path: path, history: history)
            $0.page = MobilePhotoPage(
                sourceItems: sourceItems,
                items: visible,
                nextOffset: page.nextOffset,
                sourceTotal: page.sourceTotal,
                hasMore: page.hasMore
            )
            $0.pageState = Self.pageState(items: visible, filter: filter)
            $0.isDiscoveringSpaces = false
            $0.isRefreshing = false
            $0.isLoadingMore = false
            $0.loadMoreFailed = false
            $0.errorCategory = nil
            let key = MobilePhotoPageCacheKey(
                spaceKind: space.kind,
                path: path,
                filter: filter
            )
            Self.storeCache($0.page, key: key, profile: &$0)
        }
    }

    private func restoreCachedPage(
        space: PhotoSpace,
        path: String,
        history: [String]
    ) -> Bool {
        let filter = state.filter
        let key = MobilePhotoPageCacheKey(
            spaceKind: space.kind,
            path: path,
            filter: filter
        )
        guard let cached = state.caches[key] else { return false }
        cancelAllWork()
        updateActive {
            $0.location = MobilePhotoLocation(space: space, path: path, history: history)
            $0.page = cached
            $0.pageState = Self.pageState(items: cached.items, filter: filter)
            $0.errorCategory = nil
            $0.loadMoreFailed = false
            Self.touchCache(key, profile: &$0)
        }
        return true
    }

    private func finishCancellation(profileID: UUID, generation requestGeneration: Int) {
        guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
        updateActive {
            $0.isDiscoveringSpaces = false
            $0.isRefreshing = false
            $0.isLoadingMore = false
        }
    }

    private func finishLoadMoreFailure(
        _ error: Error,
        profileID: UUID,
        generation requestGeneration: Int
    ) {
        guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
        updateActive {
            $0.isLoadingMore = false
            $0.loadMoreFailed = true
            $0.errorCategory = Self.errorCategory(error)
        }
    }

    private func finishReplaceFailure(
        _ error: Error,
        profileID: UUID,
        generation requestGeneration: Int,
        preservesContent: Bool
    ) {
        guard isCurrent(profileID: profileID, generation: requestGeneration) else { return }
        updateActive {
            $0.isDiscoveringSpaces = false
            $0.isRefreshing = false
            $0.isLoadingMore = false
            if !preservesContent {
                $0.pageState = .error
            }
            $0.errorCategory = Self.errorCategory(error)
        }
    }

    private func updateActive(
        _ update: (inout MobilePhotoLibraryProfileState) -> Void
    ) {
        guard let activeProfileID else { return }
        var profile = profiles[activeProfileID] ?? MobilePhotoLibraryProfileState()
        update(&profile)
        profiles[activeProfileID] = profile
    }

    private func isCurrent(profileID: UUID, generation requestGeneration: Int) -> Bool {
        activeProfileID == profileID && generation == requestGeneration
    }

    private func canonicalItem(matching item: PhotoLibraryItem) -> PhotoLibraryItem? {
        guard let canonicalItem = state.page.items.first(where: { $0.id == item.id }),
              canonicalItem.profileID == item.profileID,
              canonicalItem.path == item.path,
              canonicalItem.kind == item.kind else { return nil }
        return canonicalItem
    }

    private func hasLoadedCurrentPage() -> Bool {
        guard let space = state.selectedSpace, !state.currentPath.isEmpty else { return false }
        let key = MobilePhotoPageCacheKey(
            spaceKind: space.kind,
            path: state.currentPath,
            filter: state.filter
        )
        return !state.page.sourceItems.isEmpty || state.caches[key] != nil
    }

    private static func visibleItems(
        from sourceItems: [PhotoLibraryItem],
        filter: MobilePhotoFilter
    ) -> [PhotoLibraryItem] {
        sourceItems.filter { item in
            switch filter {
            case .all:
                item.kind == .folder || item.kind == .image
            case .images:
                item.kind == .image
            }
        }
    }

    private static func deduplicated(_ items: [PhotoLibraryItem]) -> [PhotoLibraryItem] {
        var paths = Set<String>()
        return items.filter { paths.insert($0.path).inserted }
    }

    private static func storeCache(
        _ page: MobilePhotoPage,
        key: MobilePhotoPageCacheKey,
        profile: inout MobilePhotoLibraryProfileState
    ) {
        profile.caches[key] = page
        touchCache(key, profile: &profile)
        while profile.cacheOrder.count > pageCacheLimitPerProfile {
            let evicted = profile.cacheOrder.removeFirst()
            profile.caches[evicted] = nil
        }
    }

    private static func touchCache(
        _ key: MobilePhotoPageCacheKey,
        profile: inout MobilePhotoLibraryProfileState
    ) {
        profile.cacheOrder.removeAll { $0 == key }
        profile.cacheOrder.append(key)
    }

    private static func pageState(
        items: [PhotoLibraryItem],
        filter: MobilePhotoFilter
    ) -> MobilePageState {
        if items.isEmpty {
            return filter == .all ? .empty : .filteredEmpty
        }
        return .content
    }

    private nonisolated static func thumbnailKey(profileID: UUID, item: PhotoLibraryItem) -> String {
        let modifiedVersion = item.modifiedAt.map {
            String($0.timeIntervalSince1970.bitPattern, radix: 16)
        } ?? "none"
        let sizeVersion = item.sizeBytes.map(String.init) ?? "none"
        return "\(profileID.uuidString)|\(item.path)|m:\(modifiedVersion)|s:\(sizeVersion)|small"
    }

    private static func errorCategory(_ error: Error) -> AppErrorCategory {
        if let error = error as? AppError { return error.category }
        if error is CancellationError { return .cancelled }
        if error is MobilePhotoLibraryError { return .invalidResponse }
        return .unknown
    }
}

import DsmCore
import DsmNetwork
import Foundation
import Observation

protocol MobileFileBrowsing: AnyObject, Sendable {
    var profileID: UUID { get }
    func listShares(offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage
    func listFolder(path: String, offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage
    func search(folderPath: String, query: String) async throws -> [FileItem]
}

extension DsmFileRepository: MobileFileBrowsing {}

@MainActor
@Observable
final class MobileFileBrowserModel {
    private struct PendingLocationNavigation {
        let profileID: UUID
        let generation: Int
        let baseline: MobileFileBrowserProfileState
    }

    static let pageSize = 200

    let locations: MobileFileLocationsModel
    let mutations: MobileFileItemMutationModel
    private(set) var activeProfileID: UUID?
    private(set) var profiles: [UUID: MobileFileBrowserProfileState] = [:]
    @ObservationIgnored private var repositoryIdentity: ObjectIdentifier?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var locationRequestTask: Task<Bool, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingLocationNavigation: PendingLocationNavigation?

    init(
        locations: MobileFileLocationsModel = MobileFileLocationsModel(),
        mutations: MobileFileItemMutationModel = MobileFileItemMutationModel()
    ) {
        self.locations = locations
        self.mutations = mutations
    }

    var state: MobileFileBrowserProfileState {
        guard let activeProfileID else { return MobileFileBrowserProfileState() }
        return profiles[activeProfileID] ?? MobileFileBrowserProfileState()
    }

    func activate(profileID: UUID?, repository: (any MobileFileBrowsing)?) async {
        cancelRequest()
        activeProfileID = profileID
        repositoryIdentity = repository.map { ObjectIdentifier($0) }
        guard let profileID, let repository, repository.profileID == profileID else {
            repositoryIdentity = nil
            return
        }
        if profiles[profileID] == nil {
            profiles[profileID] = MobileFileBrowserProfileState()
        }
    }

    func setQuery(_ query: String) {
        updateActive { $0.query = query }
    }

    func setLayout(_ layout: MobileFileBrowserLayout) {
        updateActive { $0.layout = layout }
    }

    func setOptions(_ options: FileListOptions, repository: any MobileFileBrowsing) async {
        guard isActive(repository) else { return }
        let effectiveOptions = Self.effectiveOptions(options, path: state.currentPath)
        guard effectiveOptions != state.options else { return }
        cancelRequest()
        updateActive {
            if $0.currentPath.isEmpty {
                $0.directoryOptions = FileListOptions(
                    sortField: $0.directoryOptions.sortField,
                    sortDirection: effectiveOptions.sortDirection,
                    typeFilter: $0.directoryOptions.typeFilter
                )
            } else {
                $0.directoryOptions = effectiveOptions
            }
            $0.options = effectiveOptions
        }
        restoreCachedPageIfPresent()
        await replaceContent(repository: repository, forceNetwork: true)
    }

    func submitSearch(repository: any MobileFileBrowsing) async {
        guard isActive(repository) else { return }
        await replaceContent(repository: repository, forceNetwork: false)
    }

    func refresh(repository: any MobileFileBrowsing) async {
        guard isActive(repository) else { return }
        await replaceContent(repository: repository, forceNetwork: true)
    }

    /// 只在原 profile、repository 与父目录仍然有效时刷新；该父目录的旧查询缓存一并失效。
    func refreshAfterConfirmedMutation(
        _ success: MobileFileItemMutationSuccess,
        repository: any MobileFileBrowsing
    ) async {
        guard isActive(repository),
              success.profileID == repository.profileID,
              state.currentPath == success.parentPath,
              MobileFileItemMutationModel.canMutate(
                  parentPath: state.currentPath,
                  source: state.location.source
              ) else { return }
        cancelRequest()
        updateActive { profile in
            profile.query = ""
            profile.caches = profile.caches.filter { $0.key.path != success.parentPath }
            profile.visibleKey = nil
            profile.options = Self.effectiveOptions(
                profile.directoryOptions,
                path: success.parentPath
            )
        }
        await replaceContent(repository: repository, forceNetwork: true)
    }

    func openDirectory(_ item: FileItem, repository: any MobileFileBrowsing) async {
        guard item.isDirectory, isActive(repository) else { return }
        let source: MobileFileLocationSource = item.isRecyclePath
            ? .recycle
            : (state.location.source == .remote || state.location.source == .recycle
                ? state.location.source
                : .browser)
        updateActive {
            $0.location.history.append($0.location.path)
            $0.location.path = item.path
            $0.location.source = source
            $0.query = ""
            $0.options = Self.effectiveOptions($0.directoryOptions, path: item.path)
        }
        restoreCachedPageIfPresent()
        await replaceContent(
            repository: repository,
            forceNetwork: false,
            committedLocationSource: source
        )
    }

    /// 从位置清单打开目录时，网络结果确认前不改变已提交浏览状态。
    @discardableResult
    func openLocation(
        path: String,
        source: MobileFileLocationSource,
        repository: any MobileFileBrowsing
    ) async -> Bool {
        guard isActive(repository),
              (source == .shares && path.isEmpty || Self.isCanonicalAbsoluteLocationPath(path)) else {
            return false
        }
        let profileID = repository.profileID
        let identity = ObjectIdentifier(repository)
        let baseline = state
        let options = Self.effectiveOptions(state.directoryOptions, path: path)
        let requestGeneration = beginRequest { profile in
            profile.isRefreshing = Self.hasCommittedBaseline(profile.pageState)
            if !profile.isRefreshing {
                profile.pageState = .loading
            }
        }
        pendingLocationNavigation = PendingLocationNavigation(
            profileID: profileID,
            generation: requestGeneration,
            baseline: baseline
        )
        let task = Task { [weak self] in
            do {
                let page = try await Self.fetchPage(
                    repository: repository,
                    path: path,
                    offset: 0,
                    options: options
                )
                try Task.checkCancellation()
                return try self?.commitLocationPage(
                    page,
                    path: path,
                    source: source,
                    options: options,
                    baseline: baseline,
                    profileID: profileID,
                    repositoryIdentity: identity,
                    generation: requestGeneration
                ) ?? false
            } catch {
                self?.restoreLocationBaseline(
                    baseline,
                    profileID: profileID,
                    repositoryIdentity: identity,
                    generation: requestGeneration
                )
                return false
            }
        }
        locationRequestTask = task
        let opened = await task.value
        if generation == requestGeneration {
            locationRequestTask = nil
        }
        return opened
    }

    func goBack(repository: any MobileFileBrowsing) async {
        guard isActive(repository),
              state.location.history.last != nil else { return }
        updateActive {
            $0.location.path = $0.location.history.removeLast()
            $0.query = ""
            $0.options = Self.effectiveOptions($0.directoryOptions, path: $0.location.path)
        }
        restoreCachedPageIfPresent()
        await replaceContent(repository: repository, forceNetwork: false)
    }

    func goUp(repository: any MobileFileBrowsing) async {
        guard isActive(repository), !state.currentPath.isEmpty else { return }
        let parent = parentPath(of: state.currentPath)
        updateActive {
            $0.location.history.append($0.location.path)
            $0.location.path = parent
            if parent.isEmpty { $0.location.source = .shares }
            $0.query = ""
            $0.options = Self.effectiveOptions($0.directoryOptions, path: parent)
        }
        restoreCachedPageIfPresent()
        await replaceContent(repository: repository, forceNetwork: false)
    }

    func loadMore(repository: any MobileFileBrowsing) async {
        guard isActive(repository),
              state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              state.page.hasMore,
              !state.isLoadingMore else { return }
        let profileID = repository.profileID
        let identity = ObjectIdentifier(repository)
        let requestedOffset = state.page.nextOffset
        let path = state.currentPath
        let options = Self.effectiveOptions(state.options, path: path)
        let requestGeneration = beginRequest { profile in
            profile.isLoadingMore = true
            profile.loadMoreFailed = false
        }
        let task = Task { [weak self] in
            do {
                let page = try await Self.fetchPage(
                    repository: repository,
                    path: path,
                    offset: requestedOffset,
                    options: options
                )
                try Task.checkCancellation()
                try self?.applyPage(
                    page,
                    requestedOffset: requestedOffset,
                    profileID: profileID,
                    repositoryIdentity: identity,
                    generation: requestGeneration,
                    appending: true,
                    path: path,
                    options: options
                )
            } catch is CancellationError {
                self?.finishCancelled(
                    profileID: profileID,
                    repositoryIdentity: identity,
                    generation: requestGeneration
                )
            } catch {
                self?.finishLoadMoreFailure(
                    profileID: profileID,
                    repositoryIdentity: identity,
                    generation: requestGeneration
                )
            }
        }
        requestTask = task
        await task.value
    }

    func cancelRequest() {
        restorePendingLocationNavigationIfCurrent()
        requestTask?.cancel()
        requestTask = nil
        locationRequestTask?.cancel()
        locationRequestTask = nil
        generation &+= 1
    }

    func cancelLocationRequest() {
        guard locationRequestTask != nil || pendingLocationNavigation != nil else { return }
        restorePendingLocationNavigationIfCurrent()
        locationRequestTask?.cancel()
        locationRequestTask = nil
        generation &+= 1
    }

    private func replaceContent(
        repository: any MobileFileBrowsing,
        forceNetwork: Bool,
        committedLocationSource: MobileFileLocationSource? = nil
    ) async {
        let profileID = repository.profileID
        let identity = ObjectIdentifier(repository)
        let path = state.currentPath
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = Self.effectiveOptions(state.options, path: path)
        let key = MobileFileBrowserCacheKey(path: path, query: query, options: options)

        if !forceNetwork, let cached = profiles[profileID]?.caches[key] {
            cancelRequest()
            updateActive {
                $0.page = cached
                $0.visibleKey = key
                $0.pageState = Self.pageState(items: cached.items, query: query, options: options)
                $0.isRefreshing = false
                $0.isLoadingMore = false
                $0.loadMoreFailed = false
            }
            if let committedLocationSource, !path.isEmpty {
                locations.recordSuccessfulDirectory(
                    profileID: profileID,
                    path: path,
                    source: committedLocationSource
                )
            }
            return
        }

        let preservesContent = state.visibleKey == key && !state.page.items.isEmpty
        let requestGeneration = beginRequest { profile in
            profile.isRefreshing = preservesContent
            profile.isLoadingMore = false
            profile.loadMoreFailed = false
            if !preservesContent {
                profile.page = MobileFileBrowserPageCache()
                profile.visibleKey = nil
                profile.pageState = .loading
            }
        }
        let task = Task { [weak self] in
            do {
                if query.isEmpty {
                    let page = try await Self.fetchPage(
                        repository: repository,
                        path: path,
                        offset: 0,
                        options: options
                    )
                    try Task.checkCancellation()
                    try self?.applyPage(
                        page,
                        requestedOffset: 0,
                        profileID: profileID,
                        repositoryIdentity: identity,
                        generation: requestGeneration,
                        appending: false,
                        path: path,
                        options: options
                    )
                    if let committedLocationSource,
                       !path.isEmpty,
                       self?.isCurrent(
                           profileID: profileID,
                           repositoryIdentity: identity,
                           generation: requestGeneration
                       ) == true,
                       self?.state.currentPath == path {
                        self?.locations.recordSuccessfulDirectory(
                            profileID: profileID,
                            path: path,
                            source: committedLocationSource
                        )
                    }
                } else {
                    let items = try await repository.search(
                        folderPath: path.isEmpty ? "/" : path,
                        query: query
                    )
                    try Task.checkCancellation()
                    self?.applySearch(
                        items,
                        path: path,
                        query: query,
                        options: options,
                        profileID: profileID,
                        repositoryIdentity: identity,
                        generation: requestGeneration
                    )
                }
            } catch is CancellationError {
                self?.finishCancelled(
                    profileID: profileID,
                    repositoryIdentity: identity,
                    generation: requestGeneration
                )
            } catch {
                self?.finishReplaceFailure(
                    profileID: profileID,
                    repositoryIdentity: identity,
                    generation: requestGeneration
                )
            }
        }
        requestTask = task
        await task.value
    }

    private func beginRequest(_ update: (inout MobileFileBrowserProfileState) -> Void) -> Int {
        restorePendingLocationNavigationIfCurrent()
        requestTask?.cancel()
        locationRequestTask?.cancel()
        locationRequestTask = nil
        generation &+= 1
        updateActive(update)
        return generation
    }

    private func commitLocationPage(
        _ page: FilePage,
        path: String,
        source: MobileFileLocationSource,
        options: FileListOptions,
        baseline: MobileFileBrowserProfileState,
        profileID: UUID,
        repositoryIdentity identity: ObjectIdentifier,
        generation requestGeneration: Int
    ) throws -> Bool {
        guard isCurrent(
            profileID: profileID,
            repositoryIdentity: identity,
            generation: requestGeneration
        ) else { return false }
        guard page.offset == 0 else { throw MobileFileBrowserError.misalignedPage }
        let items = Self.deduplicated(page.items)
        guard !page.hasMore || !items.isEmpty else { throw MobileFileBrowserError.zeroProgress }
        let nextOffset = page.items.count
        guard page.total >= nextOffset,
              page.hasMore == (nextOffset < page.total) else {
            throw MobileFileBrowserError.inconsistentTotal
        }
        let cache = MobileFileBrowserPageCache(
            items: items,
            nextOffset: nextOffset,
            hasMore: page.hasMore,
            filteredEmptyReason: items.isEmpty && options.typeFilter != .all ? .typeFilter : nil
        )
        let key = MobileFileBrowserCacheKey(path: path, query: "", options: options)
        var committed = baseline
        committed.location = MobileFileBrowserLocation(path: path, history: [], source: source)
        committed.query = ""
        committed.options = options
        committed.page = cache
        committed.caches[key] = cache
        committed.visibleKey = key
        committed.pageState = Self.pageState(items: items, query: "", options: options)
        committed.isRefreshing = false
        committed.isLoadingMore = false
        committed.loadMoreFailed = false
        profiles[profileID] = committed
        if pendingLocationNavigation?.generation == requestGeneration {
            pendingLocationNavigation = nil
        }
        locations.selectSource(source)
        locations.recordSuccessfulDirectory(profileID: profileID, path: path, source: source)
        return true
    }

    private func restoreLocationBaseline(
        _ baseline: MobileFileBrowserProfileState,
        profileID: UUID,
        repositoryIdentity identity: ObjectIdentifier,
        generation requestGeneration: Int
    ) {
        guard isCurrent(
            profileID: profileID,
            repositoryIdentity: identity,
            generation: requestGeneration
        ) else { return }
        profiles[profileID] = baseline
        pendingLocationNavigation = nil
    }

    private func restorePendingLocationNavigationIfCurrent() {
        guard let pendingLocationNavigation,
              activeProfileID == pendingLocationNavigation.profileID,
              generation == pendingLocationNavigation.generation else {
            self.pendingLocationNavigation = nil
            return
        }
        profiles[pendingLocationNavigation.profileID] = pendingLocationNavigation.baseline
        self.pendingLocationNavigation = nil
    }

    private func applyPage(
        _ page: FilePage,
        requestedOffset: Int,
        profileID: UUID,
        repositoryIdentity identity: ObjectIdentifier,
        generation requestGeneration: Int,
        appending: Bool,
        path: String,
        options: FileListOptions
    ) throws {
        guard isCurrent(
            profileID: profileID,
            repositoryIdentity: identity,
            generation: requestGeneration
        ),
              state.currentPath == path,
              state.options == options else { return }
        guard page.offset == requestedOffset else { throw MobileFileBrowserError.misalignedPage }

        let existing = appending ? state.page.items : []
        let merged = Self.deduplicated(existing + page.items)
        let addedCount = merged.count - existing.count
        guard !page.hasMore || addedCount > 0 else { throw MobileFileBrowserError.zeroProgress }

        let nextOffset = requestedOffset + page.items.count
        guard page.total >= nextOffset,
              page.hasMore == (nextOffset < page.total) else {
            throw MobileFileBrowserError.inconsistentTotal
        }
        let cache = MobileFileBrowserPageCache(
            items: merged,
            nextOffset: nextOffset,
            hasMore: page.hasMore,
            filteredEmptyReason: merged.isEmpty && options.typeFilter != .all ? .typeFilter : nil
        )
        let key = MobileFileBrowserCacheKey(path: path, query: "", options: options)
        updateActive {
            $0.page = cache
            $0.caches[key] = cache
            $0.visibleKey = key
            $0.pageState = Self.pageState(items: merged, query: "", options: options)
            $0.isRefreshing = false
            $0.isLoadingMore = false
            $0.loadMoreFailed = false
        }
    }

    private func applySearch(
        _ items: [FileItem],
        path: String,
        query: String,
        options: FileListOptions,
        profileID: UUID,
        repositoryIdentity identity: ObjectIdentifier,
        generation requestGeneration: Int
    ) {
        guard isCurrent(
            profileID: profileID,
            repositoryIdentity: identity,
            generation: requestGeneration
        ),
              state.currentPath == path,
              state.query.trimmingCharacters(in: .whitespacesAndNewlines) == query,
              state.options == options else { return }
        let visibleItems = Self.sortedAndFiltered(items, options: options)
        let cache = MobileFileBrowserPageCache(
            items: Self.deduplicated(visibleItems),
            nextOffset: visibleItems.count,
            hasMore: false,
            filteredEmptyReason: visibleItems.isEmpty
                ? (items.isEmpty ? .query : .typeFilter)
                : nil
        )
        let key = MobileFileBrowserCacheKey(path: path, query: query, options: options)
        updateActive {
            $0.page = cache
            $0.caches[key] = cache
            $0.visibleKey = key
            $0.pageState = Self.pageState(items: cache.items, query: query, options: options)
            $0.isRefreshing = false
            $0.isLoadingMore = false
            $0.loadMoreFailed = false
        }
    }

    private func finishCancelled(
        profileID: UUID,
        repositoryIdentity identity: ObjectIdentifier,
        generation requestGeneration: Int
    ) {
        guard isCurrent(
            profileID: profileID,
            repositoryIdentity: identity,
            generation: requestGeneration
        ) else { return }
        updateActive {
            $0.isRefreshing = false
            $0.isLoadingMore = false
        }
    }

    private func finishLoadMoreFailure(
        profileID: UUID,
        repositoryIdentity identity: ObjectIdentifier,
        generation requestGeneration: Int
    ) {
        guard isCurrent(
            profileID: profileID,
            repositoryIdentity: identity,
            generation: requestGeneration
        ) else { return }
        updateActive {
            $0.isLoadingMore = false
            $0.loadMoreFailed = true
        }
    }

    private func finishReplaceFailure(
        profileID: UUID,
        repositoryIdentity identity: ObjectIdentifier,
        generation requestGeneration: Int
    ) {
        guard isCurrent(
            profileID: profileID,
            repositoryIdentity: identity,
            generation: requestGeneration
        ) else { return }
        updateActive {
            $0.isRefreshing = false
            $0.isLoadingMore = false
            $0.pageState = $0.page.items.isEmpty ? .error : .content
        }
    }

    private func restoreCachedPageIfPresent() {
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = Self.effectiveOptions(state.options, path: state.currentPath)
        let key = MobileFileBrowserCacheKey(path: state.currentPath, query: query, options: options)
        updateActive {
            if let cached = $0.caches[key] {
                $0.page = cached
                $0.visibleKey = key
                $0.pageState = Self.pageState(items: cached.items, query: query, options: options)
            } else {
                $0.page = MobileFileBrowserPageCache()
                $0.visibleKey = nil
                $0.pageState = .loading
            }
            $0.loadMoreFailed = false
        }
    }

    private func updateActive(_ update: (inout MobileFileBrowserProfileState) -> Void) {
        guard let activeProfileID else { return }
        var profile = profiles[activeProfileID] ?? MobileFileBrowserProfileState()
        update(&profile)
        profiles[activeProfileID] = profile
    }

    private func isActive(_ repository: any MobileFileBrowsing) -> Bool {
        activeProfileID == repository.profileID && repositoryIdentity == ObjectIdentifier(repository)
    }

    private func isCurrent(
        profileID: UUID,
        repositoryIdentity identity: ObjectIdentifier,
        generation requestGeneration: Int
    ) -> Bool {
        activeProfileID == profileID
            && repositoryIdentity == identity
            && generation == requestGeneration
    }

    private func parentPath(of path: String) -> String {
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        let parent = URL(fileURLWithPath: normalized).deletingLastPathComponent().path
        return parent == "/" ? "" : parent
    }

    private static func fetchPage(
        repository: any MobileFileBrowsing,
        path: String,
        offset: Int,
        options: FileListOptions
    ) async throws -> FilePage {
        if path.isEmpty {
            return try await repository.listShares(offset: offset, limit: pageSize, options: options)
        }
        return try await repository.listFolder(path: path, offset: offset, limit: pageSize, options: options)
    }

    private static func deduplicated(_ items: [FileItem]) -> [FileItem] {
        var paths = Set<String>()
        return items.filter { paths.insert($0.path).inserted }
    }

    private static func pageState(
        items: [FileItem],
        query: String,
        options: FileListOptions = .default
    ) -> MobilePageState {
        if items.isEmpty {
            return query.isEmpty && options.typeFilter == .all ? .empty : .filteredEmpty
        }
        return .content
    }

    private static func effectiveOptions(_ options: FileListOptions, path: String) -> FileListOptions {
        guard !path.isEmpty else {
            return FileListOptions(
                sortField: .name,
                sortDirection: options.sortDirection,
                typeFilter: .all
            )
        }
        return options
    }

    private static func hasCommittedBaseline(_ state: MobilePageState) -> Bool {
        state == .empty || state == .filteredEmpty || state == .content
    }

    private static func isCanonicalAbsoluteLocationPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path != "/",
              !path.hasSuffix("/"),
              !path.contains("//"),
              !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func sortedAndFiltered(
        _ items: [FileItem],
        options: FileListOptions
    ) -> [FileItem] {
        let filtered = items.filter { item in
            switch options.typeFilter {
            case .all: true
            case .files: !item.isDirectory
            case .folders: item.isDirectory
            }
        }
        return filtered.sorted { lhs, rhs in
            let order: ComparisonResult
            switch options.sortField {
            case .name:
                order = lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                order = compare(lhs.sizeBytes ?? 0, rhs.sizeBytes ?? 0)
            case .modifiedTime:
                order = compare(lhs.times?.modifiedAt ?? .distantPast, rhs.times?.modifiedAt ?? .distantPast)
            }
            let resolvedOrder = order == .orderedSame
                ? lhs.path.localizedStandardCompare(rhs.path)
                : order
            return options.sortDirection == .ascending
                ? resolvedOrder == .orderedAscending
                : resolvedOrder == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

private enum MobileFileBrowserError: Error {
    case misalignedPage
    case zeroProgress
    case inconsistentTotal
}

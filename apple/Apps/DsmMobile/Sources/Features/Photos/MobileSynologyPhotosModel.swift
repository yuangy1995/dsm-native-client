import DsmCore
import DsmLocalization
import Foundation
import Observation

enum MobileSynologyPhotosSection: CaseIterable, Hashable {
    case timeline, folders, albums, sharing
    var title: String {
        switch self {
        case .timeline: L10n.string("photos.library.timeline")
        case .folders: L10n.string("photos.library.folders")
        case .albums: L10n.string("photos.library.albums")
        case .sharing: L10n.string("photos.sharing")
        }
    }
}

struct MobileSynologyPhotoMonth: Identifiable, Hashable {
    let year: Int
    let month: Int
    var id: Int { year * 100 + month }
    var date: Date? { Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: 1)) }
}

/// 移动端直接读取 Synology Photos；与 macOS 的查询和双向游标语义一致。
/// 模型实例绑定一个会话，空间、项目和临时导出均不得跨实例复用。
@MainActor
@Observable
final class MobileSynologyPhotosModel {
    private(set) var spaces: [SynologyPhotoSpace] = []
    private(set) var selectedSpace: SynologyPhotoSpace = .personal
    private(set) var days: [SynologyPhotoDay] = []
    private(set) var items: [SynologyPhoto] = [] { didSet { rebuildDatedGroups() } }
    private(set) var collections: [SynologyPhotoCollection] = []
    private(set) var section: MobileSynologyPhotosSection = .timeline
    private(set) var folderHistory: [SynologyPhotoCollection] = []
    private(set) var selectedAlbum: SynologyPhotoCollection?
    private(set) var availableCategories: Set<SynologyPhotoCategory> = []
    private(set) var selectedCategory: SynologyPhotoCategory?
    private(set) var selectedCategoryItem: SynologyPhotoCollection?
    private(set) var sharedEntries: [SynologyPhotoSharedEntry] = []
    private(set) var shareScope: SynologyPhotoShareScope = .withMe
    var filter = SynologyPhotoFilter()
    var showsFilters = false
    private(set) var options = SynologyPhotoFilterOptions(people: [], locations: [])
    private(set) var isLoadingFilterOptions = false
    private(set) var filterOptionsErrorMessage: String?
    @ObservationIgnored private var filterOptionsGeneration = 0
    private(set) var hasMoreCollections = false
    private(set) var isModuleEnabled = true
    var previewPhoto: SynologyPhoto?
    private(set) var previewData: Data?
    private(set) var previewSource: MediaStreamSource?
    private(set) var previewError: String?
    private(set) var isPreparingPreview = false
    private(set) var isSaving = false
    private(set) var saveProgress: Double?
    private(set) var saveMessage: String?
    var deletionCandidate: SynologyPhoto?
    var deletionError: String?
    private(set) var pendingDeletionPhoto: SynologyPhoto?
    private(set) var deletionMessage: String?
    private(set) var isDeleting = false
    private(set) var isCheckingDeletion = false
    @ObservationIgnored private var confirmedDeletedIDs: Set<SynologyPhotoID> = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false
    private(set) var isPlayingMotion = false
    private(set) var selectedTimelineMonthID: Int?
    private(set) var previousMonthID: Int?
    private(set) var previousPageErrorMessage: String?
    private(set) var isLoadingPrevious = false
    var hasPrevious: Bool { previousMonthID.map { current in timelineMonths.contains { $0.id > current } } ?? false }
    var previousPaginationIdentity: String { "\(generation):\(previousMonthID ?? 0)" }
    @ObservationIgnored private var timelineBaseQuery: SynologyPhotoQuery?
    var searchText = ""
    private(set) var isFiltering = false
    @ObservationIgnored private let repository: (any SynologyPhotosServing)?
    @ObservationIgnored private var collectionOffset = 0
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextOffset = 0
    @ObservationIgnored private var query: SynologyPhotoQuery = .recentlyAdded
    @ObservationIgnored private let pageSize: Int

    let canDeleteOriginals: Bool
    @ObservationIgnored private let thumbnails = MobilePhotoThumbnailStore()
    @ObservationIgnored private let thumbnailNamespace = UUID().uuidString
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var deletionTask: Task<Void, Never>?
    @ObservationIgnored private var exportGeneration = 0
    @ObservationIgnored private var exportDirectory: URL?
    private(set) var exportURL: URL?

    init(repository: (any SynologyPhotosServing)? = nil, pageSize: Int = 100, canDeleteOriginals: Bool = false) {
        self.repository = repository
        self.pageSize = min(500, max(1, pageSize))
        self.canDeleteOriginals = canDeleteOriginals
    }

    /// 用户快速切换页签或筛选时取消上一条导航链，而不是只丢弃最终结果。
    func navigate(_ action: @escaping @MainActor () async -> Void) {
        navigationTask?.cancel()
        navigationTask = Task { await action() }
    }

    func clearThumbnailCache() async { await thumbnails.removeAll() }
    func thumbnailCacheCost() async -> Int { await thumbnails.cachedCost() }

    func thumbnailData(for photo: SynologyPhoto) async -> Data? {
        guard isModuleEnabled, let repository else { return nil }
        let current = generation
        let key = "\(thumbnailNamespace)|\(photo.id.profileID)|\(photo.id.space.rawValue)|\(photo.id.unitID)|\(photo.thumbnail?.unitID ?? 0)|\(photo.thumbnail?.revision ?? "")"
        let data = await thumbnails.data(for: key, namespace: thumbnailNamespace, priority: .visible) {
            try await repository.thumbnail(for: photo)
        }
        guard current == generation, isModuleEnabled, !Task.isCancelled else { return nil }
        return data
    }

    func loadIfNeeded() async {
        guard isModuleEnabled, !hasLoaded, !isLoading else { return }
        await refresh()
    }

    var paginationIdentity: String { "\(generation):\(nextOffset):\(collectionOffset)" }
    var showsCategories: Bool { section == .albums && selectedAlbum == nil && selectedCategory == nil && !isFiltering && !availableCategories.isEmpty }
    var showsTimeline: Bool { section == .timeline || (selectedCategory != nil && !items.isEmpty) }
    var timelineMonths: [MobileSynologyPhotoMonth] {
        Set(days.filter { $0.itemCount > 0 }.map { MobileSynologyPhotoMonth(year: $0.year, month: $0.month) })
            .sorted { $0.id > $1.id }
    }

    func jumpToMonth(_ month: MobileSynologyPhotoMonth) async {
        guard isModuleEnabled, timelineMonths.contains(month), let base = timelineBaseQuery,
              let date = month.date,
              let nextMonth = Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: date) else { return }
        let ceiling = Int(nextMonth.timeIntervalSince1970) - 1
        let destination: SynologyPhotoQuery
        switch base {
        case .timeline(let start, let end):
            guard ceiling >= start else { return }
            destination = .timeline(startTime: start, endTime: min(end, ceiling))
        case .search(let keyword, let start, let end):
            guard ceiling >= start else { return }
            destination = .search(keyword: keyword, startTime: start, endTime: min(end, ceiling))
        case .filtered(var filter, let start, let end):
            guard ceiling >= start else { return }
            if let filterEnd = filter.endTime { filter.endTime = min(filterEnd, ceiling) }
            destination = .filtered(filter, startTime: start, endTime: min(end, ceiling))
        case .category(let category, let id, let start, let end):
            guard ceiling >= start else { return }
            destination = .category(category, id: id, startTime: start, endTime: min(end, ceiling))
        default: return
        }
        generation += 1
        let current = generation
        query = destination
        previousMonthID = month.id
        previousPageErrorMessage = nil
        isLoadingPrevious = false
        selectedTimelineMonthID = month.id
        items = []; nextOffset = 0; hasMore = false
        isLoading = true; isLoadingMore = false; errorMessage = nil
        defer { if current == generation { isLoading = false } }
        do {
            let page = try await service().photos(in: selectedSpace, query: destination, offset: 0, limit: pageSize)
            guard current == generation, !Task.isCancelled else { return }
            try accept(page, requestedOffset: 0)
            hasLoaded = true
        } catch { if current == generation { present(error) } }
    }

    /// 向较新月份读取完整时间区间，再整体补入，避免月内分页制造日期缺口。
    func loadPreviousPage() async {
        guard isModuleEnabled, !isDeleting, hasPrevious, !isLoading, !isLoadingPrevious,
              let monthID = previousMonthID,
              let month = timelineMonths.last(where: { $0.id > monthID }),
              let base = timelineBaseQuery,
              let lowerMonth = timelineMonths.first(where: { $0.id == monthID })?.date,
              let upperMonth = month.date,
              let startDate = Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: lowerMonth),
              let endDate = Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: upperMonth) else { return }
        let start = Int(startDate.timeIntervalSince1970)
        let end = Int(endDate.timeIntervalSince1970) - 1
        let previousQuery: SynologyPhotoQuery
        switch base {
        case .timeline(let lower, let upper):
            previousQuery = .timeline(startTime: max(lower, start), endTime: min(upper, end))
        case .search(let keyword, let lower, let upper):
            previousQuery = .search(keyword: keyword, startTime: max(lower, start), endTime: min(upper, end))
        case .filtered(var filter, let lower, let upper):
            if let filterStart = filter.startTime { filter.startTime = max(filterStart, start) }
            if let filterEnd = filter.endTime { filter.endTime = min(filterEnd, end) }
            previousQuery = .filtered(filter, startTime: max(lower, start), endTime: min(upper, end))
        case .category(let category, let id, let lower, let upper):
            previousQuery = .category(category, id: id, startTime: max(lower, start), endTime: min(upper, end))
        default: return
        }
        let current = generation
        isLoadingPrevious = true
        previousPageErrorMessage = nil
        defer { if current == generation { isLoadingPrevious = false } }
        do {
            var offset = 0
            var additions: [SynologyPhoto] = []
            var seen = Set(items.map(\.id))
            while true {
                let page = try await service().photos(in: selectedSpace, query: previousQuery, offset: offset, limit: pageSize)
                guard current == generation, !Task.isCancelled else { return }
                guard page.offset == offset, page.nextOffset == offset + page.items.count,
                      !page.hasMore || !page.items.isEmpty else {
                    throw AppError(category: .invalidResponse, isRetryable: true, safeUserMessage: L10n.string("photos.service.invalidResponse"))
                }
                let newItems = page.items.filter { seen.insert($0.id).inserted && !confirmedDeletedIDs.contains($0.id) }
                guard !page.hasMore || !newItems.isEmpty else {
                    throw AppError(category: .invalidResponse, isRetryable: true, safeUserMessage: L10n.string("photos.service.invalidResponse"))
                }
                additions.append(contentsOf: newItems)
                if !page.hasMore { break }
                offset = page.nextOffset
            }
            items.insert(contentsOf: additions, at: 0)
            previousMonthID = month.id
        } catch {
            guard current == generation, !(error is CancellationError) else { return }
            previousPageErrorMessage = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.service.invalidResponse")
        }
    }

    /// 仅在列表尾部进入预取区域时调用；失败停住，由明确重试恢复。
    func loadNextPageAutomatically() async {
        guard errorMessage == nil, !isDeleting else { return }
        let current = generation
        let oldCount = items.count + collections.count + sharedEntries.count
        let oldIdentity = paginationIdentity
        if hasMoreCollections { await loadMoreCollections() }
        else if hasMore { await loadMore() }
        if current == generation, oldIdentity != paginationIdentity, oldCount == items.count + collections.count + sharedEntries.count,
           hasMore || hasMoreCollections {
            errorMessage = L10n.string("photos.service.invalidResponse")
        }
    }

    /// 仅在照片集合改变时分组，预览/进度重绘不重复扫描全部已加载项目。
    private(set) var datedGroups: [MobileSynologyPhotoDayGroup] = []
    private func rebuildDatedGroups() {
        let calendar = Calendar(identifier: .gregorian)
        let grouped = Dictionary(grouping: items) {
            calendar.startOfDay(for: selectedCategory == .recentlyAdded ? $0.indexedAt : $0.takenAt)
        }
        datedGroups = grouped.keys.sorted(by: >).map {
            MobileSynologyPhotoDayGroup(date: $0, photos: grouped[$0] ?? [])
        }
    }

    func refresh(space: SynologyPhotoSpace? = nil) async {
        guard isModuleEnabled else { return }
        if let space, space != selectedSpace { folderHistory = []; selectedAlbum = nil }
        generation += 1
        let current = generation
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedTimelineMonthID = nil
        timelineBaseQuery = nil
        previousMonthID = nil
        previousPageErrorMessage = nil
        isLoadingPrevious = false
        isFiltering = !keyword.isEmpty || filter.isActive
        isLoading = true
        hasLoaded = false
        isLoadingMore = false
        errorMessage = nil
        items = []
        collections = []
        sharedEntries = []
        hasMoreCollections = false
        collectionOffset = 0
        days = []
        hasMore = false
        nextOffset = 0
        defer { if current == generation { isLoading = false } }
        do {
            let repository = try service()
            let access = try await repository.access()
            guard current == generation, !Task.isCancelled else { return }
            spaces = access.spaces
            guard let destination = spaces.first(where: { $0 == (space ?? selectedSpace) }) ?? spaces.first else {
                throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: L10n.string("photos.service.permission"))
            }
            selectedSpace = destination
            if section == .sharing, selectedAlbum == nil {
                let page = try await repository.sharedEntries(shareScope, offset: 0, limit: pageSize)
                guard current == generation, !Task.isCancelled else { return }
                sharedEntries = page
                collectionOffset = page.count
                hasMoreCollections = page.count == pageSize
                hasLoaded = true
                return
            }
            if keyword.isEmpty, section == .albums, selectedAlbum == nil, selectedCategory == nil {
                do {
                    let categories = try await repository.categories()
                    guard current == generation, !Task.isCancelled else { return }
                    availableCategories = categories
                } catch {
                    guard current == generation else { return }
                    errorMessage = L10n.string("photos.categories.failed")
                }
                let page = try await repository.albums(offset: 0, limit: pageSize)
                guard current == generation, !Task.isCancelled else { return }
                collections = page
                collectionOffset = page.count
                hasMoreCollections = page.count == pageSize
                hasLoaded = true
                return
            }
            if let category = selectedCategory, selectedCategoryItem == nil,
               category != .recentlyAdded, category != .videos {
                let page = try await repository.categoryItems(category, offset: 0, limit: pageSize)
                guard current == generation, !Task.isCancelled else { return }
                collections = page
                collectionOffset = page.count
                hasMoreCollections = page.count == pageSize
                hasLoaded = true
                return
            }
            if selectedCategory == .recentlyAdded {
                query = .recentlyAdded
            } else if let category = selectedCategory, let selected = selectedCategoryItem, category == .concept || category == .tags {
                let timeline = try await repository.categoryTimeline(category, id: selected.id)
                guard current == generation, !Task.isCancelled else { return }
                days = timeline
                guard let range = Self.timeRange(for: timeline) else { hasLoaded = true; return }
                query = .category(category, id: selected.id, startTime: range.lowerBound, endTime: range.upperBound)
            } else if filter.isActive {
                let timeline = try await repository.filteredTimeline(in: destination, filter: filter)
                guard current == generation, !Task.isCancelled else { return }
                days = timeline
                guard let range = Self.timeRange(for: timeline) else { hasLoaded = true; return }
                query = .filtered(filter, startTime: range.lowerBound, endTime: range.upperBound)
            } else if keyword.isEmpty, section == .folders {
                if folderHistory.isEmpty {
                    let root = try await repository.rootFolder(in: destination)
                    guard current == generation, !Task.isCancelled else { return }
                    folderHistory = [root]
                }
                let folderID = folderHistory.last!.id
                let page = try await repository.folders(in: destination, parentID: folderID, offset: 0, limit: pageSize)
                guard current == generation, !Task.isCancelled else { return }
                collections = page
                collectionOffset = page.count
                hasMoreCollections = page.count == pageSize
                query = .folder(id: folderID)
            } else if keyword.isEmpty, let album = selectedAlbum {
                query = .album(id: album.id)
            } else {
            let timeline = try await keyword.isEmpty
                ? repository.timeline(in: destination)
                : repository.searchTimeline(in: destination, keyword: keyword)
            guard current == generation, !Task.isCancelled else { return }
            days = timeline
            guard let range = Self.timeRange(for: timeline) else {
                hasLoaded = true
                return
            }
            query = keyword.isEmpty
                ? .timeline(startTime: range.lowerBound, endTime: range.upperBound)
                : .search(keyword: keyword, startTime: range.lowerBound, endTime: range.upperBound)
            }
            timelineBaseQuery = query
            let page = try await repository.photos(in: destination, query: query, offset: 0, limit: pageSize)
            guard current == generation, !Task.isCancelled else { return }
            try accept(page, requestedOffset: 0)
            hasLoaded = true
        } catch {
            guard current == generation else { return }
            present(error)
        }
    }

    func loadMore() async {
        guard isModuleEnabled, !isDeleting, hasMore, !isLoading, !isLoadingMore else { return }
        let current = generation
        let offset = nextOffset
        isLoadingMore = true
        errorMessage = nil
        defer { if current == generation { isLoadingMore = false } }
        do {
            let repository = try service()
            let page = try await repository.photos(in: selectedSpace, query: query, offset: offset, limit: pageSize)
            guard current == generation, !Task.isCancelled else { return }
            try accept(page, requestedOffset: offset)
        } catch {
            guard current == generation else { return }
            present(error)
        }
    }

    func thumbnail(for photo: SynologyPhoto) async throws -> Data {
        let current = generation
        let data = try await service().thumbnail(for: photo)
        guard current == generation, !Task.isCancelled else { throw CancellationError() }
        return data
    }

    func cancel() {
        generation += 1
        isLoadingPrevious = false
        hasLoaded = false
        isLoading = false
        isLoadingMore = false
        closePreview()
        navigationTask?.cancel()
        deletionTask?.cancel()
        isCheckingDeletion = false
        isDeleting = false
        deletionCandidate = nil
        cancelExport()
    }

    func deactivate() {
        setModuleEnabled(false)
        Task { await thumbnails.removeAll() }
    }

    func setModuleEnabled(_ enabled: Bool) {
        isModuleEnabled = enabled
        if !enabled {
            cancel(); items = []; collections = []; spaces = []; folderHistory = []; selectedAlbum = nil
            sharedEntries = []; availableCategories = []; selectedCategory = nil; selectedCategoryItem = nil
            options = SynologyPhotoFilterOptions(people: [], locations: [])
            filter = SynologyPhotoFilter()
            deletionCandidate = nil
            filterOptionsGeneration += 1
            isLoadingFilterOptions = false
            filterOptionsErrorMessage = nil
        }
    }

    func selectSection(_ section: MobileSynologyPhotosSection) async {
        guard section != self.section else { await loadIfNeeded(); return }
        self.section = section
        searchText = ""
        folderHistory = []
        selectedAlbum = nil
        selectedCategory = nil
        selectedCategoryItem = nil
        filter = SynologyPhotoFilter()
        showsFilters = false
        await refresh()
    }

    func open(_ collection: SynologyPhotoCollection) async {
        searchText = ""
        if section == .folders { folderHistory.append(collection) }
        else if let category = selectedCategory {
            selectedCategoryItem = collection
            if category == .person { filter.personID = collection.id }
            if category == .location { filter.locationID = collection.id }
        }
        else { selectedAlbum = collection }
        await refresh()
    }

    var canGoBack: Bool { folderHistory.count > 1 || selectedAlbum != nil || selectedCategory != nil }
    func goBack() async {
        if selectedCategoryItem != nil { selectedCategoryItem = nil; filter = SynologyPhotoFilter() }
        else if selectedCategory != nil { selectedCategory = nil; filter = SynologyPhotoFilter() }
        else if selectedAlbum != nil { selectedAlbum = nil }
        else if folderHistory.count > 1 { folderHistory.removeLast() }
        else { return }
        await refresh()
    }

    func loadMoreCollections() async {
        guard isModuleEnabled, hasMoreCollections, !isLoading, !isLoadingMore else { return }
        errorMessage = nil
        let current = generation
        isLoadingMore = true
        defer { if current == generation { isLoadingMore = false } }
        do {
            let repository = try service()
            if section == .sharing {
                let page = try await repository.sharedEntries(shareScope, offset: collectionOffset, limit: pageSize)
                guard current == generation, !Task.isCancelled else { return }
                let ids = Set(sharedEntries.map(\.id))
                sharedEntries.append(contentsOf: page.filter { !ids.contains($0.id) })
                collectionOffset += page.count
                hasMoreCollections = page.count == pageSize
                return
            }
            let page: [SynologyPhotoCollection]
            if let category = selectedCategory, selectedCategoryItem == nil {
                page = try await repository.categoryItems(category, offset: collectionOffset, limit: pageSize)
            } else if section == .albums {
                page = try await repository.albums(offset: collectionOffset, limit: pageSize)
            } else if let folder = folderHistory.last {
                page = try await repository.folders(in: selectedSpace, parentID: folder.id, offset: collectionOffset, limit: pageSize)
            } else { return }
            guard current == generation, !Task.isCancelled else { return }
            let ids = Set(collections.map(\.id))
            collections.append(contentsOf: page.filter { !ids.contains($0.id) })
            collectionOffset += page.count
            hasMoreCollections = page.count == pageSize
        } catch { if current == generation { present(error) } }
    }

    func openCategory(_ category: SynologyPhotoCategory) async {
        selectedCategory = category
        selectedCategoryItem = nil
        selectedAlbum = nil
        searchText = ""
        filter = SynologyPhotoFilter()
        if category == .videos { filter.mediaType = 1 }
        await refresh()
    }

    func selectShareScope(_ scope: SynologyPhotoShareScope) async {
        shareScope = scope
        selectedAlbum = nil
        await refresh()
    }

    func openSharedAlbum(_ entry: SynologyPhotoSharedEntry) async {
        guard let id = entry.albumID else { return }
        selectedAlbum = SynologyPhotoCollection(id: id, name: entry.title)
        await refresh()
    }

    func loadFilterOptions() async {
        let current = generation
        filterOptionsGeneration += 1
        let request = filterOptionsGeneration
        isLoadingFilterOptions = true
        filterOptionsErrorMessage = nil
        defer { if request == filterOptionsGeneration { isLoadingFilterOptions = false } }
        do {
            let result = try await service().filterOptions(in: selectedSpace)
            guard current == generation, request == filterOptionsGeneration, isModuleEnabled else { return }
            options = result
        } catch {
            if current == generation, request == filterOptionsGeneration, !Task.isCancelled {
                filterOptionsErrorMessage = L10n.string("photos.filters.failed")
            }
        }
    }

    func submitSearch() async {
        section = .timeline
        selectedAlbum = nil
        selectedCategory = nil
        selectedCategoryItem = nil
        folderHistory = []
        filter = SynologyPhotoFilter()
        await refresh()
    }

    func applyFilter(_ value: SynologyPhotoFilter) async {
        section = .timeline
        selectedAlbum = nil
        selectedCategory = nil
        selectedCategoryItem = nil
        folderHistory = []
        filter = value
        searchText = ""
        await refresh()
    }

    func showPreview(_ photo: SynologyPhoto, playMotion: Bool = false) {
        guard isModuleEnabled else { return }
        previewTask?.cancel()
        previewGeneration += 1
        let current = previewGeneration
        previewPhoto = photo
        isPlayingMotion = false
        previewData = nil
        previewSource = nil
        previewError = nil
        isPreparingPreview = true
        previewTask = Task { [weak self] in
            guard let self else { return }
            defer { if current == self.previewGeneration { self.isPreparingPreview = false } }
            do {
                let service = try self.service()
                let detail = try await service.details(for: photo)
                guard current == self.previewGeneration, !Task.isCancelled else { return }
                self.previewPhoto = detail
                if detail.mediaType == "video" || (detail.mediaType == "live" && playMotion) {
                    let source = try await service.videoSource(for: detail)
                    guard current == self.previewGeneration, !Task.isCancelled else { return }
                    self.previewSource = source
                } else {
                    let data = try await service.previewImage(for: detail)
                    guard current == self.previewGeneration, !Task.isCancelled else { return }
                    self.previewData = data
                }
            } catch {
                guard current == self.previewGeneration, !Task.isCancelled else { return }
                self.previewError = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.media.failed")
            }
        }
    }

    func closePreview() {
        previewGeneration += 1
        previewTask?.cancel()
        previewPhoto = nil
        previewData = nil
        previewSource = nil
        isPreparingPreview = false
        isPlayingMotion = false
    }

    func playMotion() {
        guard let photo = previewPhoto, photo.mediaType == "live", !isPlayingMotion else { return }
        previewTask?.cancel()
        let current = previewGeneration
        isPlayingMotion = true
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await self.service().videoSource(for: photo)
                guard current == self.previewGeneration, !Task.isCancelled else { return }
                self.previewSource = source
            } catch {
                guard current == self.previewGeneration, !Task.isCancelled else { return }
                self.isPlayingMotion = false
                self.previewError = L10n.string("photos.media.failed")
            }
        }
    }

    func finishMotion() {
        previewTask?.cancel()
        previewSource = nil
        isPlayingMotion = false
    }

    func adjacentPreview(_ direction: Int) {
        guard let id = previewPhoto?.id, let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + direction) else { return }
        showPreview(items[index + direction])
    }

    /// 原件流式保存至本次分享的独立目录；系统分享结束后清理，不持久保存照片副本。
    func prepareExport(_ photo: SynologyPhoto) {
        guard isModuleEnabled, !isSaving else { return }
        cancelExport()
        exportGeneration += 1
        let current = exportGeneration
        isSaving = true
        saveMessage = nil
        saveProgress = nil
        saveTask = Task { [weak self] in
            guard let self else { return }
            defer { if current == self.exportGeneration { self.isSaving = false } }
            var directory: URL?
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                directory = folder
                let name = (photo.filename as NSString).lastPathComponent
                guard !name.isEmpty, name != ".", name != "..", !name.contains("\0") else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                let destination = folder.appendingPathComponent(name, isDirectory: false)
                try await self.service().downloadOriginal(photo, to: destination) { [weak self] done, total in
                    Task { @MainActor in
                        guard let self, current == self.exportGeneration else { return }
                        self.saveProgress = total.flatMap { $0 > 0 ? min(1, Double(done) / Double($0)) : nil }
                    }
                }
                try Task.checkCancellation()
                guard current == self.exportGeneration, self.isModuleEnabled else {
                    try? FileManager.default.removeItem(at: folder)
                    return
                }
                self.exportDirectory = folder
                self.exportURL = destination
            } catch {
                if let directory { try? FileManager.default.removeItem(at: directory) }
                guard current == self.exportGeneration, !(error is CancellationError) else { return }
                self.saveMessage = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.media.saveFailed")
            }
        }
    }

    func cancelExport() {
        exportGeneration += 1
        saveTask?.cancel()
        saveTask = nil
        exportURL = nil
        if let directory = exportDirectory { try? FileManager.default.removeItem(at: directory) }
        exportDirectory = nil
        isSaving = false
        saveProgress = nil
    }

    private func service() throws -> any SynologyPhotosServing {
        guard isModuleEnabled, let repository else {
            throw AppError(category: .apiUnavailable, isRetryable: false, safeUserMessage: L10n.string("photos.service.unavailable"))
        }
        return repository
    }

    private func accept(_ page: SynologyPhotoPage, requestedOffset: Int) throws {
        guard page.offset == requestedOffset,
              page.nextOffset == requestedOffset + page.items.count,
              !page.hasMore || !page.items.isEmpty else {
            throw AppError(category: .invalidResponse, isRetryable: true, safeUserMessage: L10n.string("photos.service.invalidResponse"))
        }
        var existing = Set(items.map(\.id))
        let additions = page.items.filter { existing.insert($0.id).inserted && !confirmedDeletedIDs.contains($0.id) }
        guard !page.hasMore || !additions.isEmpty else {
            throw AppError(category: .invalidResponse, isRetryable: true, safeUserMessage: L10n.string("photos.service.invalidResponse"))
        }
        items.append(contentsOf: additions)
        nextOffset = page.nextOffset
        hasMore = page.hasMore
    }

    private func present(_ error: Error) {
        if error is CancellationError { return }
        errorMessage = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.service.invalidResponse")
    }

    func requestDeletion(_ photo: SynologyPhoto) {
        guard isModuleEnabled, !isDeleting, !isCheckingDeletion, pendingDeletionPhoto == nil else { return }
        guard canDeleteOriginals else { deletionError = L10n.string("photos.delete.unverified"); return }
        let current = generation
        isCheckingDeletion = true
        deletionError = nil
        deletionTask = Task {
            defer { if current == generation { isCheckingDeletion = false } }
            do {
                try await service().prepareDeletion(photo)
                guard isModuleEnabled, current == generation else { return }
                deletionCandidate = photo
            } catch {
                guard isModuleEnabled, current == generation else { return }
                deletionError = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.delete.unverified")
            }
        }
    }

    func confirmDeletion(_ photo: SynologyPhoto) {
        guard isModuleEnabled, canDeleteOriginals, !isDeleting, deletionCandidate?.id == photo.id else { return }
        deletionCandidate = nil
        isDeleting = true
        generation += 1
        isLoadingPrevious = false
        isLoading = false
        isLoadingMore = false
        let current = generation
        deletionTask = Task {
            defer { if current == generation { isDeleting = false } }
            do {
                let result = try await service().deletePhoto(photo, operationID: UUID())
                guard isModuleEnabled, current == generation else { return }
                await applyDeletionResult(result, photo: photo)
            } catch {
                guard isModuleEnabled, current == generation, !Task.isCancelled else { return }
                deletionError = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.delete.failed")
            }
        }
    }

    func reviewPendingDeletion() async {
        guard isModuleEnabled, !isDeleting, let photo = pendingDeletionPhoto else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            let result = try await service().reviewDeletion(photo)
            await applyDeletionResult(result, photo: photo)
        } catch { deletionError = L10n.string("photos.delete.reviewFailed") }
    }

    private func applyDeletionResult(_ result: SynologyPhotoDeletionResult, photo: SynologyPhoto) async {
        switch result {
        case .confirmed:
            confirmedDeletedIDs.insert(photo.id)
            items.removeAll { $0.id == photo.id }
            pendingDeletionPhoto = nil
            if previewPhoto?.id == photo.id { closePreview() }
            deletionMessage = L10n.string("photos.delete.done")
            await refresh()
        case .pendingReview:
            pendingDeletionPhoto = photo
            deletionMessage = L10n.string("photos.delete.pending")
        }
    }

    /// 套件返回日历日期；用覆盖全部时区的边界读取，避免本机与 NAS 时区不同漏掉边缘照片。
    /// 这不是客户端扫描时间线，日期范围来自套件的时间分组。
    private static func timeRange(for days: [SynologyPhotoDay]) -> ClosedRange<Int>? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = days.compactMap { calendar.date(from: DateComponents(year: $0.year, month: $0.month, day: $0.day)) }
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return max(0, Int(first.timeIntervalSince1970) - 86_400)...(Int(last.timeIntervalSince1970) + 172_800)
    }
}

struct MobileSynologyPhotoDayGroup: Identifiable {
    let date: Date
    let photos: [SynologyPhoto]
    var id: Date { date }
}

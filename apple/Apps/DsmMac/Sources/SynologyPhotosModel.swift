import DsmCore
import DsmLocalization
import DsmNetwork
import Foundation
import Observation
import UniformTypeIdentifiers

enum SynologyPhotosSection: CaseIterable, Hashable {
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

struct SynologyPhotoMonth: Identifiable, Hashable {
    let year: Int
    let month: Int
    var id: Int { year * 100 + month }
    var date: Date? { Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: 1)) }
}

struct PhotoUploadFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let size: Int64
    let modifiedAt: Date
    var sourceAccess: PhotoUploadSourceAccess? = nil
    var directoryComponents: [String] = []
}

/// 队列中的子文件共享原始选择的目录授权，确认窗口关闭后仍可读取。
final class PhotoUploadSourceAccess: @unchecked Sendable {
    let url: URL
    private let accessed: Bool
    init(url: URL) {
        self.url = url
        accessed = url.startAccessingSecurityScopedResource()
    }
    deinit { if accessed { url.stopAccessingSecurityScopedResource() } }
}

struct PhotoUploadPreparation: Sendable {
    var files: [PhotoUploadFile] = []
    var skippedCount = 0
    var includesDirectory = false

    static func prepare(_ sources: [URL]) throws -> Self {
        var result = Self()
        var seen: Set<URL> = []
        var skipped: Set<URL> = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .isPackageKey, .isHiddenKey, .contentTypeKey, .fileSizeKey, .contentModificationDateKey]
        func append(_ file: URL, access: PhotoUploadSourceAccess, directories: [String] = []) throws {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isHidden != true, values.isPackage != true,
                  values.isRegularFile == true,
                  let type = values.contentType ?? UTType(filenameExtension: file.pathExtension),
                  type.conforms(to: .image) || type.conforms(to: .movie),
                  let size = values.fileSize, size > 0, let modified = values.contentModificationDate else {
                if skipped.insert(file).inserted { result.skippedCount += 1 }
                return
            }
            guard seen.insert(file.resolvingSymlinksInPath()).inserted else { return }
            result.files.append(PhotoUploadFile(url: file, size: Int64(size), modifiedAt: modified,
                sourceAccess: access, directoryComponents: directories))
        }
        for source in sources {
            try Task.checkCancellation()
            guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            let access = PhotoUploadSourceAccess(url: source)
            let values = try source.resourceValues(forKeys: keys)
            if values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true, values.isHidden != true {
                result.includesDirectory = true
                var readError: Error?
                guard let entries = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                        readError = error
                        return false
                    }) else { throw CocoaError(.fileReadUnknown) }
                for case let file as URL in entries {
                    try Task.checkCancellation()
                    let entry = try file.resourceValues(forKeys: keys)
                    if entry.isSymbolicLink == true || entry.isPackage == true {
                        if skipped.insert(file).inserted { result.skippedCount += 1 }
                    } else if entry.isDirectory != true {
                        let base = source.resolvingSymlinksInPath().pathComponents
                        let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
                        guard parent.starts(with: base) else { throw CocoaError(.fileReadNoPermission) }
                        try append(file, access: access, directories: [source.lastPathComponent] + parent.dropFirst(base.count))
                    }
                }
                if let readError { throw readError }
            } else { try append(source, access: access) }
        }
        result.files.sort { $0.url.path < $1.url.path }
        return result
    }
}

struct PhotoUploadEntry: Identifiable {
    enum State: String { case queued, preparingFolders, uploading, addingToAlbum, completed, failed, pendingReview, cancelled }
    var id: UUID { file.id }
    let file: PhotoUploadFile
    let album: SynologyPhotoCollection?
    let folder: SynologyPhotoCollection?
    var state: State = .queued
    var progress: Double = 0
    var uploadedPhoto: SynologyPhoto?
    var error: String?
    var batchID = UUID()
}

private struct PhotoUploadDirectoryKey: Hashable {
    let batchID: UUID
    let parentID: Int
    let name: String
}

/// 单一图库的双向分页状态，每个方向禁止重复请求；刷新后迟到结果不得覆盖当前图库。
@MainActor
@Observable
final class SynologyPhotosModel {
    private(set) var spaces: [SynologyPhotoSpace] = []
    private(set) var selectedSpace: SynologyPhotoSpace = .personal
    private(set) var days: [SynologyPhotoDay] = []
    private(set) var items: [SynologyPhoto] = []
    private(set) var collections: [SynologyPhotoCollection] = []
    private(set) var section: SynologyPhotosSection = .timeline
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
    private(set) var managementFeatures: Set<SynologyPhotosManagementFeature> = []
    private(set) var isManaging = false
    private(set) var uploadQueue: [PhotoUploadEntry] = []
    private(set) var isUploading = false
    var isBrowsingBlocked: Bool { isManaging && !isUploading }
    private(set) var stopsAfterCurrentUpload = false
    @ObservationIgnored private var pendingUploadID: UUID?
    @ObservationIgnored private var uploadDirectories: [PhotoUploadDirectoryKey: SynologyPhotoCollection] = [:]
    @ObservationIgnored private var pendingUploadDirectory: PhotoUploadDirectoryKey?
    private(set) var managementMessage: String?
    private(set) var managementLink: URL?
    private(set) var pendingMutationID: UUID?
    @ObservationIgnored private var pendingMutation: SynologyPhotosMutation?
    private(set) var retryableManagementMutation: SynologyPhotosMutation?
    @ObservationIgnored private var managementTask: Task<Void, Never>?
    private(set) var isSaving = false
    private(set) var saveProgress: Double?
    private(set) var saveMessage: String?
    var deletionCandidates: [SynologyPhoto] = []
    // 移动端沿用单项确认；macOS 批量确认使用同一份目标快照。
    var deletionCandidate: SynologyPhoto? {
        get { deletionCandidates.first }
        set { deletionCandidates = newValue.map { [$0] } ?? [] }
    }
    private(set) var selectedPhotoIDs: Set<SynologyPhotoID> = []
    var isSelecting = false
    @ObservationIgnored private var selectionAnchorID: SynologyPhotoID?
    var deletionError: String?
    private(set) var pendingDeletionPhotos: [SynologyPhoto] = []
    var pendingDeletionPhoto: SynologyPhoto? { pendingDeletionPhotos.first }
    @ObservationIgnored private var deletionTask: Task<Void, Never>?
    @ObservationIgnored private var preparedDeletionPhotos: [SynologyPhoto] = []
    @ObservationIgnored private var pagedPhotoIDs: Set<SynologyPhotoID> = []
    @ObservationIgnored private let deletionReviewDelay: @Sendable (Double) async throws -> Void
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

    init(repository: (any SynologyPhotosServing)? = nil, pageSize: Int = 100,
         deletionReviewDelay: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.repository = repository
        self.pageSize = pageSize
        self.deletionReviewDelay = deletionReviewDelay
    }

    func loadIfNeeded() async {
        guard isModuleEnabled, !hasLoaded, !isLoading else { return }
        await refresh()
    }

    var paginationIdentity: String { "\(generation):\(nextOffset):\(collectionOffset)" }
    var showsCategories: Bool { section == .albums && selectedAlbum == nil && selectedCategory == nil && !isFiltering && !availableCategories.isEmpty }
    var showsTimeline: Bool { section == .timeline || (selectedCategory != nil && !items.isEmpty) }
    var timelineMonths: [SynologyPhotoMonth] {
        Set(days.filter { $0.itemCount > 0 }.map { SynologyPhotoMonth(year: $0.year, month: $0.month) })
            .sorted { $0.id > $1.id }
    }

    func jumpToMonth(_ month: SynologyPhotoMonth) async {
        guard isModuleEnabled, !isDeleting, !isBrowsingBlocked, timelineMonths.contains(month), let base = timelineBaseQuery,
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
        clearSelection(); deletionCandidates = []; preparedDeletionPhotos = []
        pagedPhotoIDs = []
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
        guard isModuleEnabled, !isDeleting, !isBrowsingBlocked, hasPrevious, !isLoading, !isLoadingPrevious,
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

    var datedGroups: [(date: Date, photos: [SynologyPhoto])] {
        let calendar = Calendar(identifier: .gregorian)
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: selectedCategory == .recentlyAdded ? $0.indexedAt : $0.takenAt) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    func refresh(space: SynologyPhotoSpace? = nil) async {
        guard isModuleEnabled, !isDeleting, !isBrowsingBlocked else { return }
        clearSelection(); deletionCandidates = []; preparedDeletionPhotos = []
        pagedPhotoIDs = []
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
            // 上传期间使用当前会话已确认的空间，避免权限刷新使在途写操作失效。
            if !isUploading && pendingUploadID == nil {
                let access = try await repository.access()
                guard current == generation, !Task.isCancelled else { return }
                managementFeatures = await repository.managementFeatures()
                guard current == generation, !Task.isCancelled else { return }
                spaces = access.spaces
            }
            guard let destination = spaces.first(where: { $0 == (space ?? selectedSpace) }) ?? spaces.first else {
                hasLoaded = true
                return
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
        guard isModuleEnabled, !isDeleting, !isBrowsingBlocked, hasMore, !isLoading, !isLoadingMore else { return }
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

    func thumbnail(for album: SynologyPhotoCollection) async throws -> Data {
        let current = generation
        let data = try await service().thumbnail(for: album)
        guard current == generation, !Task.isCancelled else { throw CancellationError() }
        return data
    }

    func leaveGallery() {
        generation += 1
        isLoadingPrevious = false
        hasLoaded = false
        isLoading = false
        isLoadingMore = false
        closePreview()
        clearSelection(); deletionCandidates = []; preparedDeletionPhotos = []
        deletionTask?.cancel()
        if !isUploading { managementTask?.cancel() }
        saveTask?.cancel()
    }

    func cancel() {
        leaveGallery()
        stopUploadQueue()
        managementTask?.cancel()
        saveTask?.cancel()
    }

    func setModuleEnabled(_ enabled: Bool) {
        isModuleEnabled = enabled
        if !enabled {
            cancel(); items = []; collections = []; spaces = []; folderHistory = []; selectedAlbum = nil
            managementFeatures = []
            sharedEntries = []; availableCategories = []; selectedCategory = nil; selectedCategoryItem = nil
            options = SynologyPhotoFilterOptions(people: [], locations: [])
            filter = SynologyPhotoFilter()
            deletionCandidate = nil
        }
    }

    func selectSection(_ section: SynologyPhotosSection) async {
        guard !isDeleting, !isBrowsingBlocked else { return }
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
        guard !isDeleting, !isBrowsingBlocked else { return }
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
        guard !isDeleting, !isBrowsingBlocked else { return }
        if selectedCategoryItem != nil { selectedCategoryItem = nil; filter = SynologyPhotoFilter() }
        else if selectedCategory != nil { selectedCategory = nil; filter = SynologyPhotoFilter() }
        else if selectedAlbum != nil { selectedAlbum = nil }
        else if folderHistory.count > 1 { folderHistory.removeLast() }
        else { return }
        await refresh()
    }

    func loadMoreCollections() async {
        guard isModuleEnabled, !isDeleting, !isBrowsingBlocked, hasMoreCollections, !isLoading, !isLoadingMore else { return }
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
        guard !isDeleting, !isBrowsingBlocked else { return }
        selectedCategory = category
        selectedCategoryItem = nil
        selectedAlbum = nil
        searchText = ""
        filter = SynologyPhotoFilter()
        if category == .videos { filter.mediaType = 1 }
        await refresh()
    }

    func selectShareScope(_ scope: SynologyPhotoShareScope) async {
        guard !isDeleting, !isBrowsingBlocked else { return }
        shareScope = scope
        selectedAlbum = nil
        await refresh()
    }

    func openSharedAlbum(_ entry: SynologyPhotoSharedEntry) async {
        guard !isDeleting, !isBrowsingBlocked else { return }
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

    func applyFilter(_ value: SynologyPhotoFilter) async {
        guard !isDeleting, !isBrowsingBlocked else { return }
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

    func save(_ photo: SynologyPhoto, to url: URL) {
        guard isModuleEnabled, !isSaving else { return }
        isSaving = true; saveProgress = nil; saveMessage = nil
        saveTask = Task { [weak self] in
            guard let self else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                self.isSaving = false
            }
            do {
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).photos-save")
                defer { try? FileManager.default.removeItem(at: staging) }
                try await self.service().downloadOriginal(photo, to: staging) { [weak self] done, total in
                    Task { @MainActor in self?.saveProgress = total.flatMap { $0 > 0 ? Double(done) / Double($0) : nil } }
                }
                try Task.checkCancellation()
                // 此入口仅来自 NSSavePanel 的保存/替换确认；Repository 默认的无覆盖契约不变。
                try await DownloadedFileExporter.export(from: staging, to: url, replaceExisting: true)
                self.saveMessage = L10n.string("photos.media.saved")
            } catch is CancellationError { self.saveMessage = nil }
            catch { self.saveMessage = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.media.saveFailed") }
        }
    }

    var canManageSelection: Bool { !selectedPhotos.isEmpty && selectedPhotos.count <= 100 && !isManaging && pendingMutationID == nil && !isDeleting && !isCheckingDeletion }

    func categoryThumbnail(for collection: SynologyPhotoCollection, category: SynologyPhotoCategory) async throws -> Data {
        try await service().thumbnail(for: collection, category: category)
    }
    func managementPeople() async throws -> [SynologyPhotoCollection] { try await service().managementPeople() }
    func albumSharing(id: Int) async throws -> SynologyPhotoSharingState { try await service().albumSharing(id: id) }
    func sharingRecipients() async throws -> [SynologyPhotoShareRecipient] { try await service().sharingRecipients() }
    func albumCondition(id: Int) async throws -> SynologyPhotoAlbumCondition { try await service().albumCondition(id: id) }
    func conditionSuggestions(keyword: String) async throws -> [String: [SynologyPhotoConditionOption]] { try await service().conditionSuggestions(keyword: keyword) }
    func conditionItemCount(_ condition: SynologyPhotoAlbumCondition) async throws -> Int { try await service().conditionItemCount(condition) }

    func managementAlbums() async throws -> [SynologyPhotoCollection] {
        var result: [SynologyPhotoCollection] = []
        var offset = 0
        while true {
            let page = try await service().albums(offset: offset, limit: 100)
            result.append(contentsOf: page)
            if page.count < 100 { return result }
            offset += page.count
            try Task.checkCancellation()
        }
    }

    func managementFolders(parentID: Int?) async throws -> (SynologyPhotoCollection, [SynologyPhotoCollection]) {
        let service = try service()
        let root = try await service.rootFolder(in: .personal)
        var children: [SynologyPhotoCollection] = []
        var offset = 0
        while true {
            let page = try await service.folders(in: .personal, parentID: parentID ?? root.id, offset: offset, limit: 100)
            children.append(contentsOf: page)
            if page.count < 100 { return (root, children) }
            offset += page.count
            try Task.checkCancellation()
        }
    }

    func submitMutation(_ mutation: SynologyPhotosMutation) {
        guard isModuleEnabled, !isManaging, !isDeleting, !isCheckingDeletion, pendingMutationID == nil,
              managementFeatures.contains(mutation.feature) else { return }
        let id = UUID()
        let isContinuation = retryableManagementMutation == mutation
        retryableManagementMutation = nil
        isManaging = true; managementMessage = L10n.string("photos.manage.working"); managementLink = nil
        managementTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isManaging = false }
            let file: URL?
            if case .upload(let url, _, _, _) = mutation { file = url } else { file = nil }
            let scoped = file?.startAccessingSecurityScopedResource() ?? false
            defer { if scoped { file?.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await self.executeMutation(mutation, id: id)
                if isContinuation, result?.state == .rejected { self.retryableManagementMutation = mutation }
            } catch is CancellationError {
                if isContinuation, self.pendingMutationID == nil { self.retryableManagementMutation = mutation }
                self.managementMessage = self.pendingMutationID == nil ? nil : L10n.string("photos.manage.pending")
            } catch {
                // 新操作只有提交前错误才会抛出；提交后的未知状态由结果返回。
                self.pendingMutationID = nil; self.pendingMutation = nil
                if isContinuation { self.retryableManagementMutation = mutation }
                self.managementMessage = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.failed")
            }
        }
    }

    func continuePartialManagement() {
        guard let command = retryableManagementMutation else { return }
        submitMutation(command)
    }

    private func executeMutation(_ mutation: SynologyPhotosMutation, id: UUID = UUID(),
                                 progress: @escaping FileTransferProgress = { _, _ in }) async throws -> SynologyPhotosMutationResult? {
        let service = try service()
        try await service.prepareMutation(mutation)
        try Task.checkCancellation()
        if !isUploading {
            generation += 1
            isLoadingMore = false; isLoadingPrevious = false
        }
        pendingMutationID = id; pendingMutation = mutation
        do {
            let first = try await service.performMutation(mutation, operationID: id, progress: progress)
            return await finishMutation(first, id: id, mutation: mutation, service: service)
        } catch {
            // Repository 只在提交前抛错；提交后的不确定结果由 pendingReview 返回。
            pendingMutationID = nil; pendingMutation = nil
            throw error
        }
    }

    func enqueueUploads(_ files: [PhotoUploadFile], album: SynologyPhotoCollection?, folder: SynologyPhotoCollection?, preserveDirectories: Bool = false) {
        guard isModuleEnabled, !isManaging, !isLoading, !isDeleting, !isCheckingDeletion, pendingMutationID == nil,
              managementFeatures.contains(.upload), !files.isEmpty,
              album == nil || (managementFeatures.contains(.albums) && album?.isConditional != true),
              !preserveDirectories || managementFeatures.contains(.folders) else { return }
        let batchID = UUID()
        clearSelection()
        uploadQueue.append(contentsOf: files.map {
            var file = $0
            if !preserveDirectories { file.directoryComponents = [] }
            return PhotoUploadEntry(file: file, album: album, folder: folder, batchID: batchID)
        })
        stopsAfterCurrentUpload = false
        startUploadQueue()
    }

    func stopUploadQueue() {
        stopsAfterCurrentUpload = true
        for index in uploadQueue.indices where uploadQueue[index].state == .queued {
            uploadQueue[index].state = .cancelled
        }
    }

    func retryUpload(_ id: UUID) {
        guard isModuleEnabled, !isManaging, !isDeleting, !isCheckingDeletion, pendingMutationID == nil,
              let index = uploadQueue.firstIndex(where: { $0.id == id }),
              [.failed, .cancelled].contains(uploadQueue[index].state) else { return }
        uploadQueue[index].state = .queued; uploadQueue[index].error = nil
        stopsAfterCurrentUpload = false
        startUploadQueue()
    }

    func clearFinishedUploads() {
        uploadQueue.removeAll { [.completed, .cancelled].contains($0.state) }
        let batches = Set(uploadQueue.map(\.batchID))
        uploadDirectories = uploadDirectories.filter { batches.contains($0.key.batchID) }
    }

    private func startUploadQueue() {
        guard isModuleEnabled, !isManaging, pendingMutationID == nil,
              uploadQueue.contains(where: { $0.state == .queued }) else { return }
        isManaging = true; isUploading = true; managementLink = nil
        managementTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isManaging = false; self.isUploading = false }
            while !Task.isCancelled, self.isModuleEnabled, !self.stopsAfterCurrentUpload,
                  let index = self.uploadQueue.firstIndex(where: { $0.state == .queued }) {
                let entry = self.uploadQueue[index]
                let scoped = entry.file.url.startAccessingSecurityScopedResource()
                defer { if scoped { entry.file.url.stopAccessingSecurityScopedResource() } }
                do {
                    if entry.uploadedPhoto == nil {
                        let destination: Int?
                        if entry.file.directoryComponents.isEmpty { destination = entry.folder?.id }
                        else {
                            self.uploadQueue[index].state = .preparingFolders
                            guard let folder = try await self.resolveUploadFolder(entry) else {
                                if self.pendingMutationID != nil { break }
                                continue
                            }
                            destination = folder
                        }
                        guard let uploadIndex = self.uploadQueue.firstIndex(where: { $0.id == entry.id }) else { break }
                        self.uploadQueue[uploadIndex].state = .uploading
                        self.uploadQueue[uploadIndex].progress = 0
                        self.pendingUploadID = entry.id
                        let result = try await self.executeMutation(.upload(file: entry.file.url, size: entry.file.size,
                            modifiedAt: entry.file.modifiedAt, folderID: destination)) { [weak self] done, total in
                            Task { @MainActor in
                                guard let self, let row = self.uploadQueue.firstIndex(where: { $0.id == entry.id }),
                                      self.uploadQueue[row].state == .uploading else { return }
                                self.uploadQueue[row].progress = total.flatMap { $0 > 0 ? min(1, Double(done) / Double($0)) : nil } ?? 0
                            }
                        }
                        guard self.acceptUploadResult(result, id: entry.id) else { break }
                    }
                    guard let current = self.uploadQueue.firstIndex(where: { $0.id == entry.id }),
                          self.uploadQueue[current].state == .queued,
                          let photo = self.uploadQueue[current].uploadedPhoto, let album = entry.album else { continue }
                    self.uploadQueue[current].state = .addingToAlbum
                    self.pendingUploadID = entry.id
                    let result = try await self.executeMutation(.addToAlbum(id: album.id, photos: [photo]))
                    guard self.acceptUploadResult(result, id: entry.id) else { break }
                } catch {
                    if let row = self.uploadQueue.firstIndex(where: { $0.id == entry.id }) {
                        if self.pendingMutationID != nil {
                            self.uploadQueue[row].state = .pendingReview
                            self.managementMessage = L10n.string("photos.manage.pending")
                            break
                        }
                        self.uploadQueue[row].state = Task.isCancelled ? .cancelled : .failed
                        self.uploadQueue[row].error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.failed")
                        self.pendingUploadID = nil
                        self.pendingUploadDirectory = nil
                    }
                }
            }
        }
    }

    /// 只在当前父目录中复用同名目录；创建回执未知时停止，不能靠名称猜测并重建。
    private func resolveUploadFolder(_ entry: PhotoUploadEntry) async throws -> Int? {
        let service = try service()
        var parent: SynologyPhotoCollection
        if let folder = entry.folder { parent = folder }
        else { parent = try await service.rootFolder(in: .personal) }
        for name in entry.file.directoryComponents {
            try Task.checkCancellation()
            let key = PhotoUploadDirectoryKey(batchID: entry.batchID, parentID: parent.id, name: name)
            if let cached = uploadDirectories[key] { parent = cached; continue }
            let (_, children) = try await managementFolders(parentID: parent.id)
            let matches = children.filter { $0.name == name && $0.parentID == parent.id }
            guard matches.count <= 1 else { throw CocoaError(.fileReadCorruptFile) }
            if let existing = matches.first { uploadDirectories[key] = existing; parent = existing; continue }
            pendingUploadID = entry.id
            pendingUploadDirectory = key
            let result = try await executeMutation(.createFolder(parentID: parent.id, name: name))
            guard acceptUploadResult(result, id: entry.id), let created = uploadDirectories[key] else { return nil }
            parent = created
        }
        return parent.id
    }

    /// 未知结果不重发；上传已确认时保留照片编号，加入相册失败只重试加入步骤。
    @discardableResult
    private func acceptUploadResult(_ result: SynologyPhotosMutationResult?, id: UUID) -> Bool {
        guard let index = uploadQueue.firstIndex(where: { $0.id == id }) else { return false }
        guard let result else { uploadQueue[index].state = .pendingReview; return false }
        pendingUploadID = nil
        guard result.state == .confirmed else {
            uploadQueue[index].state = .failed
            uploadQueue[index].error = L10n.string("photos.manage.failed")
            pendingUploadDirectory = nil
            return true
        }
        if let directory = pendingUploadDirectory {
            guard let folder = result.folder, folder.parentID == directory.parentID, folder.name == directory.name else {
                uploadQueue[index].state = .failed
                uploadQueue[index].error = L10n.string("photos.service.invalidResponse")
                pendingUploadDirectory = nil
                return true
            }
            uploadDirectories[directory] = folder
            pendingUploadDirectory = nil
            uploadQueue[index].state = isUploading ? .preparingFolders : .queued
            return true
        }
        if uploadQueue[index].uploadedPhoto == nil {
            guard result.photos.count == 1, let photo = result.photos.first else {
                uploadQueue[index].state = .failed
                uploadQueue[index].error = L10n.string("photos.service.invalidResponse")
                return true
            }
            uploadQueue[index].uploadedPhoto = photo
            uploadQueue[index].progress = 1
            uploadQueue[index].state = uploadQueue[index].album == nil ? .completed : .queued
        } else { uploadQueue[index].state = .completed }
        if uploadQueue[index].state == .completed, let photo = uploadQueue[index].uploadedPhoto,
           !isLoading, !hasMore, !isFiltering,
           (selectedAlbum?.id == uploadQueue[index].album?.id && selectedAlbum != nil ||
            section == .folders && selectedSpace == .personal && folderHistory.last != nil && folderHistory.last?.id == photo.folderID),
           !items.contains(where: { $0.id == photo.id }) {
            items.append(photo)
            items.sort { section == .folders ? $0.takenAt < $1.takenAt : $0.takenAt > $1.takenAt }
            pagedPhotoIDs.insert(photo.id); nextOffset += 1
        }
        return true
    }

    func reviewPendingMutation() {
        guard let id = pendingMutationID, let mutation = pendingMutation, !isManaging, isModuleEnabled else { return }
        isManaging = true
        managementMessage = L10n.string("photos.selection.verifying")
        managementTask = Task { [weak self] in
            guard let self else { return }
            do {
                let service = try self.service()
                let result = try await service.reviewMutation(operationID: id)
                let final = await self.finishMutation(result, id: id, mutation: mutation, service: service)
                if let uploadID = self.pendingUploadID { self.acceptUploadResult(final, id: uploadID) }
            } catch { self.managementMessage = L10n.string("photos.manage.pending") }
            self.isManaging = false
            if self.stopsAfterCurrentUpload { self.stopUploadQueue() }
            else { self.startUploadQueue() }
        }
    }

    private func finishMutation(_ initial: SynologyPhotosMutationResult, id: UUID, mutation: SynologyPhotosMutation, service: any SynologyPhotosServing) async -> SynologyPhotosMutationResult? {
        var result = initial
        for delay in [0.5, 1.0, 2.0, 3.0, 5.0, 8.0] where result.state == .pendingReview {
            do {
                try await deletionReviewDelay(delay)
                try Task.checkCancellation()
                result = try await service.reviewMutation(operationID: id)
            } catch is CancellationError { break }
            catch { continue }
        }
        guard pendingMutationID == id else { return nil }
        guard isModuleEnabled, !Task.isCancelled else { managementMessage = L10n.string("photos.manage.pending"); return nil }
        guard result.state != .pendingReview else { managementMessage = L10n.string("photos.manage.pending"); return nil }
        pendingMutationID = nil; pendingMutation = nil
        managementMessage = L10n.string(result.state == .confirmed ? "photos.manage.completed" : (result.state == .rejected ? "photos.manage.failed" : "photos.manage.partial"))
        managementLink = result.sharingURL
        for photo in result.photos {
            if let index = items.firstIndex(where: { $0.id == photo.id }) { items[index] = photo }
            if previewPhoto?.id == photo.id { previewPhoto = photo }
        }
        if let album = result.album {
            if let index = collections.firstIndex(where: { $0.id == album.id }) { collections[index] = album }
            else if section == .albums && selectedAlbum == nil { collections.insert(album, at: 0); collectionOffset += 1 }
            if selectedAlbum?.id == album.id { selectedAlbum = album }
        }
        if let person = result.person {
            let removed = Set(result.removedPersonIDs)
            if selectedCategory == .person {
                let oldCount = collections.count
                collections.removeAll { removed.contains($0.id) }
                collectionOffset = max(0, collectionOffset - (oldCount - collections.count))
                if let index = collections.firstIndex(where: { $0.id == person.id }) { collections[index] = person }
                if selectedCategoryItem?.id == person.id { selectedCategoryItem = person }
            }
            var people = options.people.filter { !removed.contains($0.id) && $0.id != person.id }
            if !removed.contains(person.id) { people.append(person) }
            options = .init(people: people.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, locations: options.locations,
                tags: options.tags, cameras: options.cameras, lenses: options.lenses, isoValues: options.isoValues,
                apertures: options.apertures, focalRanges: options.focalRanges, exposureRanges: options.exposureRanges)
        }
        if let tag = result.tag {
            var tags = options.tags.filter { $0.id != tag.id }
            tags.append(tag)
            options = .init(people: options.people, locations: options.locations,
                tags: tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                cameras: options.cameras, lenses: options.lenses, isoValues: options.isoValues,
                apertures: options.apertures, focalRanges: options.focalRanges, exposureRanges: options.exposureRanges)
            if selectedCategory == .tags, selectedCategoryItem == nil, !collections.contains(where: { $0.id == tag.id }) {
                collections.insert(.init(id: tag.id, name: tag.name), at: 0); collectionOffset += 1
            }
        }
        if result.state == .partial {
            let completed = Set(result.photos.map(\.id))
            let remaining = mutation.photos.filter { !completed.contains($0.id) }
            if !remaining.isEmpty {
                switch mutation {
                case .shiftDates(_, let seconds): retryableManagementMutation = .shiftDates(remaining, seconds: seconds)
                case .createTag:
                    if let tag = result.tag { retryableManagementMutation = .addTags(remaining, ids: [tag.id]) }
                default: break
                }
            }
        }
        guard result.state == .confirmed else { return result }
        switch mutation {
        case .deleteAlbum(let id):
            if collections.contains(where: { $0.id == id }) { collections.removeAll { $0.id == id }; collectionOffset = max(0, collectionOffset - 1) }
        case .removeFromAlbum(let id, let photos) where selectedAlbum?.id == id:
            removeManagedItems(Set(photos.map(\.id)))
        case .move(let photos, _) where section == .folders:
            removeManagedItems(Set(photos.map(\.id)))
        default: break
        }
        return result
    }

    private func removeManagedItems(_ ids: Set<SynologyPhotoID>) {
        nextOffset = max(0, nextOffset - pagedPhotoIDs.intersection(ids).count)
        pagedPhotoIDs.subtract(ids); selectedPhotoIDs.subtract(ids)
        items.removeAll { ids.contains($0.id) }
    }

    func saveSelection(to directory: URL) {
        let targets = selectedPhotos
        guard isModuleEnabled, !isSaving, !targets.isEmpty else { return }
        isSaving = true; saveMessage = nil; saveProgress = 0
        saveTask = Task { [weak self] in
            guard let self else { return }
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() }; self.isSaving = false }
            var count = 0
            do {
                for photo in targets {
                    try Task.checkCancellation()
                    let name = (photo.filename as NSString).lastPathComponent
                    guard !name.isEmpty, name != ".", name != ".." else { throw CocoaError(.fileWriteInvalidFileName) }
                    var destination = directory.appendingPathComponent(name)
                    var suffix = 1
                    while FileManager.default.fileExists(atPath: destination.path) {
                        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                        destination = directory.appendingPathComponent("\(base) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")); suffix += 1
                    }
                    let staging = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).photos-save")
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let completed = count
                    try await self.service().downloadOriginal(photo, to: staging) { [weak self] done, total in
                        Task { @MainActor in
                            self?.saveProgress = (Double(completed) + (total.flatMap { $0 > 0 ? Double(done) / Double($0) : nil } ?? 0)) / Double(targets.count)
                        }
                    }
                    try Task.checkCancellation()
                    try await DownloadedFileExporter.export(from: staging, to: destination, replaceExisting: false)
                    count += 1
                }
                self.saveMessage = L10n.string("photos.manage.savedCount", count)
            } catch {
                self.saveMessage = L10n.string("photos.manage.savePartial", count, targets.count)
            }
        }
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
        let existing = Set(items.map(\.id))
        items.append(contentsOf: page.items.filter { !existing.contains($0.id) && !confirmedDeletedIDs.contains($0.id) })
        pagedPhotoIDs.formUnion(page.items.map(\.id))
        nextOffset = page.nextOffset
        hasMore = page.hasMore
    }

    private func present(_ error: Error) {
        if error is CancellationError { return }
        errorMessage = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.service.invalidResponse")
    }

    var selectedPhotos: [SynologyPhoto] { items.filter { selectedPhotoIDs.contains($0.id) } }
    var canDeleteSelection: Bool {
        !selectedPhotoIDs.isEmpty && !isDeleting && !isCheckingDeletion && !isManaging && pendingMutationID == nil && pendingDeletionPhotos.isEmpty
    }

    func toggleSelection(_ photo: SynologyPhoto, extending: Bool = false) {
        guard !isDeleting, !isManaging, items.contains(where: { $0.id == photo.id }) else { return }
        isSelecting = true
        if extending, let anchor = selectionAnchorID,
           let first = items.firstIndex(where: { $0.id == anchor }),
           let last = items.firstIndex(where: { $0.id == photo.id }) {
            selectedPhotoIDs.formUnion(items[min(first, last)...max(first, last)].map(\.id))
        } else {
            if !selectedPhotoIDs.insert(photo.id).inserted { selectedPhotoIDs.remove(photo.id) }
            selectionAnchorID = photo.id
        }
    }

    func selectGroup(_ photos: [SynologyPhoto]) {
        guard !isDeleting, !isManaging else { return }
        let ids = Set(photos.map(\.id)).intersection(Set(items.map(\.id)))
        isSelecting = true
        if ids.isSubset(of: selectedPhotoIDs) { selectedPhotoIDs.subtract(ids) }
        else { selectedPhotoIDs.formUnion(ids) }
    }

    func clearSelection() {
        selectedPhotoIDs = []; selectionAnchorID = nil; isSelecting = false
    }

    func requestDeletion(_ photo: SynologyPhoto) { requestDeletion([photo]) }

    func requestDeletion(_ photos: [SynologyPhoto]) {
        guard isModuleEnabled, !photos.isEmpty, !isDeleting, !isManaging, !isCheckingDeletion,
              pendingMutationID == nil, pendingDeletionPhotos.isEmpty else { return }
        let targets = photos.reduce(into: [SynologyPhoto]()) { result, photo in
            if !result.contains(where: { $0.id == photo.id }) { result.append(photo) }
        }
        let current = generation
        isCheckingDeletion = true
        deletionError = nil
        Task {
            defer { isCheckingDeletion = false }
            do {
                for photo in targets {
                    try await service().prepareDeletion(photo)
                    guard isModuleEnabled, current == generation else { return }
                }
                preparedDeletionPhotos = targets
                deletionCandidates = targets
            } catch {
                guard isModuleEnabled, current == generation else { return }
                deletionError = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.delete.unverified")
            }
        }
    }

    func confirmDeletion(_ photo: SynologyPhoto) { beginDeletion([photo]) }

    func confirmDeletion(_ photos: [SynologyPhoto]) {
        guard !photos.isEmpty, photos == preparedDeletionPhotos else { return }
        beginDeletion(photos)
    }

    private func beginDeletion(_ photos: [SynologyPhoto]) {
        guard isModuleEnabled, !isDeleting, !isManaging, !isCheckingDeletion, pendingMutationID == nil, pendingDeletionPhotos.isEmpty else { return }
        deletionCandidates = []; preparedDeletionPhotos = []
        deletionError = nil; deletionMessage = nil
        isDeleting = true
        generation += 1
        isLoadingPrevious = false; isLoading = false; isLoadingMore = false
        deletionTask = Task {
            defer { isDeleting = false }
            var completed = 0
            for photo in photos {
                guard !Task.isCancelled, isModuleEnabled else { break }
                do {
                    // 每项仍由 Repository 重新核验身份和权限，只提交一次。
                    let result = try await service().deletePhoto(photo, operationID: UUID())
                    applyDeletionResult(result, photo: photo)
                    if result == .confirmed { completed += 1 }
                } catch {
                    deletionError = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.delete.failed")
                    break
                }
            }
            #if os(macOS)
            completed += await automaticallyReviewDeletions()
            #else
            // 本轮仅调整桌面自动核对，移动端保留既有单项核对时机。
            if !pendingDeletionPhotos.isEmpty { deletionMessage = L10n.string("photos.delete.pending") }
            #endif
            if pendingDeletionPhotos.isEmpty, completed > 0 {
                deletionMessage = L10n.string("photos.selection.deleted", completed)
            }
        }
    }

    /// 仅重试成功状态回读，绝不重放删除；后台删除尚未完成属于正常等待。
    private func automaticallyReviewDeletions() async -> Int {
        var completed = 0
        for delay in [0.5, 1, 2, 3, 5, 8] {
            guard !pendingDeletionPhotos.isEmpty, !Task.isCancelled, isModuleEnabled else { break }
            deletionMessage = L10n.string("photos.selection.verifying")
            do { try await deletionReviewDelay(delay) } catch { break }
            guard !Task.isCancelled, isModuleEnabled else { break }
            for photo in pendingDeletionPhotos {
                guard !Task.isCancelled, isModuleEnabled else { break }
                do {
                    let result = try await service().reviewDeletion(photo)
                    applyDeletionResult(result, photo: photo)
                    if result == .confirmed { completed += 1 }
                } catch { /* 暂时无法读取时保留目标，下一轮只读核对。 */ }
            }
        }
        if !pendingDeletionPhotos.isEmpty { deletionMessage = L10n.string("photos.selection.reviewDelayed") }
        return completed
    }

    func reviewPendingDeletion() async {
        guard isModuleEnabled, !isDeleting, !isManaging, !pendingDeletionPhotos.isEmpty else { return }
        isDeleting = true
        generation += 1
        isLoadingPrevious = false; isLoadingMore = false; isLoading = false
        defer { isDeleting = false }
        let completed = await automaticallyReviewDeletions()
        if pendingDeletionPhotos.isEmpty, completed > 0 {
            deletionMessage = L10n.string("photos.selection.deleted", completed)
        }
    }

    private func applyDeletionResult(_ result: SynologyPhotoDeletionResult, photo: SynologyPhoto) {
        switch result {
        case .confirmed:
            guard confirmedDeletedIDs.insert(photo.id).inserted else { return }
            // 只有属于向下分页窗口的项目才影响该窗口的 offset；向上补入项目另有时间区间。
            if pagedPhotoIDs.remove(photo.id) != nil { nextOffset = max(0, nextOffset - 1) }
            items.removeAll { $0.id == photo.id }
            selectedPhotoIDs.remove(photo.id)
            pendingDeletionPhotos.removeAll { $0.id == photo.id }
            if previewPhoto?.id == photo.id { closePreview() }
        case .pendingReview:
            if !pendingDeletionPhotos.contains(where: { $0.id == photo.id }) { pendingDeletionPhotos.append(photo) }
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

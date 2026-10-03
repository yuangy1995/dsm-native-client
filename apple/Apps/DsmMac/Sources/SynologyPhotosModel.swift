import AVFoundation
import ImageIO
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

enum PhotoThumbnailSize: Int, CaseIterable {
    case small, medium, comfortable, large, extraLarge
    var minimumWidth: Double { 110 + Double(rawValue) * 40 }
    var maximumWidth: Double { minimumWidth + 70 }
}

struct PhotoUploadFile: Identifiable, Sendable {
    var id = UUID()
    let url: URL
    let size: Int64
    let modifiedAt: Date
    var sourceAccess: PhotoUploadSourceAccess? = nil
    var directoryComponents: [String] = []
    var requiresSourceSelection = false
    var recoveryBookmark: Data? = nil
    var recoveryRelativeComponents: [String] = []
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
    enum State: String, Codable { case queued, preparingFolders, uploading, addingToAlbum, completed, skipped, failed, pendingReview, cancelled }
    var id: UUID { file.id }
    var file: PhotoUploadFile
    let album: SynologyPhotoCollection?
    let folder: SynologyPhotoCollection?
    var space: SynologyPhotoSpace = .personal
    var directAlbumUpload = false
    var duplicate: SynologyPhotoDuplicateSettings.Upload = .rename
    var ignoredDuplicate = false
    var state: State = .queued
    var progress: Double = 0
    var uploadedPhoto: SynologyPhoto?
    var error: String?
    var batchID = UUID()
}

struct PhotoDragSelection {
    let id = UUID()
    let photos: [SynologyPhoto]
    let folders: [SynologyPhotoCollection]
    let generation: Int
}

struct PhotoUploadDirectoryKey: Hashable, Codable {
    let batchID: UUID
    let parentID: Int
    let name: String
}

/// 单一图库的双向分页状态，每个方向禁止重复请求；刷新后迟到结果不得覆盖当前图库。
@MainActor
@Observable
final class SynologyPhotosModel {
    private(set) var spaces: [SynologyPhotoSpace] = []
    private(set) var canManageSharedSpace = false
    private(set) var automaticPreviewEnabled: Bool?
    private(set) var isGeneratingAutomaticPreview = false
    private(set) var automaticPreviewPaused = false
    private(set) var automaticPreviewFilename: String?
    private(set) var automaticPreviewError: String?
    private(set) var automaticPreviewCompleted = 0
    private var automaticPreviewRevisions: [SynologyPhotoSpace: [Int: Int]] = [:]
    @ObservationIgnored private var automaticPreviewSettingsVisible = false
    @ObservationIgnored private var automaticPreviewWorker: Task<Void, Never>?
    @ObservationIgnored private var automaticPreviewOperation: Task<Void, Never>?
    @ObservationIgnored private var automaticPreviewWake: Task<Void, Never>?
    @ObservationIgnored private var nextVisiblePreviewAt = Date.distantPast
    @ObservationIgnored private var automaticPreviewFinished: Set<SynologyPhotoAutomaticPreviewTask> = []
    @ObservationIgnored private var automaticPreviewFailed: Set<SynologyPhotoAutomaticPreviewTask> = []
    @ObservationIgnored private var visiblePreviewSources: [UUID: SynologyPhotoID] = [:]
    @ObservationIgnored private var nextAutomaticReviewAt = Date.distantPast
    @ObservationIgnored private var automaticReviewAttempts = 0
    @ObservationIgnored private let previewConversionSupport: SynologyPhotoPreviewConversionSupport
    private(set) var displayPreferences: SynologyPhotoDisplaySettings?
    private(set) var supportsOriginalSizeJPEG = false
    var defaultPhotoRequestSpace: SynologyPhotoSpace? { spaces.contains(.personal) ? .personal : spaces.first }
    func canUseDefaultRequestFolder(in space: SynologyPhotoSpace) -> Bool {
        spaces.contains(space) && (space == .personal || canManageSharedSpace)
    }
    private(set) var selectedSpace: SynologyPhotoSpace = .personal
    @ObservationIgnored private var preferredLibrarySpace: SynologyPhotoSpace = .personal
    private(set) var days: [SynologyPhotoDay] = []
    private(set) var items: [SynologyPhoto] = []
    private(set) var collections: [SynologyPhotoCollection] = []
    private(set) var section: SynologyPhotosSection = .timeline
    private(set) var folderHistory: [SynologyPhotoCollection] = []
    private(set) var dragSelection: PhotoDragSelection?
    private(set) var selectedAlbum: SynologyPhotoCollection?
    private(set) var selectedAlbumAccess: SynologyPhotoAlbumAccess?
    private(set) var availableCategories: Set<SynologyPhotoCategory> = []
    private(set) var selectedCategory: SynologyPhotoCategory?
    private(set) var selectedCategoryItem: SynologyPhotoCollection?
    private(set) var sharedEntries: [SynologyPhotoSharedEntry] = []
    private(set) var shareScope: SynologyPhotoShareScope = .withMe
    private(set) var needsSharedListRefresh = false
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
    private var similarUndoMutations: [SynologyPhotosMutation] = []
    var similarUndoMutation: SynologyPhotosMutation? { similarUndoMutations.last }
    @ObservationIgnored private var similarUndoPositions: [SynologyPhotoSimilarGroup: (index: Int, paged: Bool, query: SynologyPhotoQuery)] = [:]
    private var similarBatchQueue: [SynologyPhotosMutation] = []
    @ObservationIgnored private var similarBatchOperationIDs: Set<UUID> = []
    private(set) var isPreparingSimilarBatch = false
    var hasSimilarBatchToContinue: Bool { !similarBatchQueue.isEmpty && !isManaging && pendingMutationID == nil }

    var similarSelectedIDs: Set<SynologyPhotoID> = []
    private(set) var similarStatus: SynologyPhotoSimilarStatus?
    var similarStatusIdentity: String { "\(generation):\(selectedSpace.rawValue):\(selectedCategory?.rawValue ?? "")" }
    func refreshSimilarStatus() async {
        guard selectedCategory == .similar, isModuleEnabled else { similarStatus = nil; return }
        let current = generation, source = selectedSpace
        do {
            let value = try await service().similarStatus(in: source)
            guard current == generation, !Task.isCancelled, selectedCategory == .similar, source == selectedSpace else { return }
            similarStatus = value
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            similarStatus = nil
        }
    }
    private(set) var previewSimilarDetail: SynologyPhotoSimilarDetail?
    private(set) var isLoadingSimilarPreview = false
    private(set) var similarPreviewError: String?
    private(set) var managementFeatures: Set<SynologyPhotosManagementFeature> = []
    private(set) var isManaging = false
    private(set) var isManagingBackgroundTask = false
    private(set) var pendingBackgroundMutationID: UUID?
    private(set) var backgroundTaskMessage: String?
    private(set) var backgroundTaskRevision = 0
    @ObservationIgnored private var backgroundControlTask: Task<Void, Never>?
    private(set) var isOpeningBackgroundDestination = false
    private(set) var backgroundNavigationError: String?
    private(set) var uploadQueue: [PhotoUploadEntry] = []
    private(set) var uploadPersistenceError: String?
    #if os(macOS)
    @ObservationIgnored private var uploadRecoveryStore: PhotoUploadRecoveryStore?
    #endif
    @ObservationIgnored private var uploadRecoveryIdentity: String?
    @ObservationIgnored private var uploadRecoveryReady = true
    private(set) var isOpeningUploadDestination = false
    private(set) var uploadNavigationError: String?
    private(set) var isUploading = false
    var isBrowsingBlocked: Bool { (isManaging && !isUploading && !isGeneratingAutomaticPreview) || isPreparingSimilarBatch }
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
    @ObservationIgnored private var managementCompletion: (id: UUID, action: (SynologyPhotosMutationResult) -> Void)?
    private struct TemporarySharingCleanup {
        enum Phase { case copy, stop, delete }
        let album: SynologyPhotoCollection
        var phase: Phase
        var preservedCopy: SynologyPhotoCollection?
    }
    private var temporarySharingCleanup: TemporarySharingCleanup?
    private(set) var temporarySharingCleanupNeedsRetry = false
    var hasTemporarySharingCleanup: Bool { temporarySharingCleanup != nil }
    @ObservationIgnored private var temporaryCreationID: UUID?
    @ObservationIgnored private var cancelledTemporaryCreation = false

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
    var thumbnailSize: PhotoThumbnailSize = .medium
    @ObservationIgnored private var selectionAnchorID: SynologyPhotoID?
    var deletionError: String?
    private(set) var pendingDeletionPhotos: [SynologyPhoto] = []
    var pendingDeletionPhoto: SynologyPhoto? { pendingDeletionPhotos.first }
    @ObservationIgnored private var deletionTask: Task<Void, Never>?
    @ObservationIgnored private var deletionReviewEpoch = 0
    @ObservationIgnored private var isReadingDeletionResults = false
    var hasAutomaticDeletionReview: Bool { isModuleEnabled && !pendingDeletionPhotos.isEmpty }
    @ObservationIgnored private var preparedDeletionPhotos: [SynologyPhoto] = []
    @ObservationIgnored private var pagedPhotoIDs: Set<SynologyPhotoID> = []
    @ObservationIgnored private let deletionReviewDelay: @Sendable (Double) async throws -> Void
    private(set) var deletionMessage: String?
    private(set) var isDeleting = false
    private(set) var isCheckingDeletion = false
    var deletionKeptCount: Int?
    private(set) var similarRefreshError: String?
    @ObservationIgnored private var similarRefreshes: [SynologyPhotoSimilarGroup: (query: SynologyPhotoQuery, index: Int, paged: Bool)] = [:]

    @ObservationIgnored private var confirmedDeletedIDs: Set<SynologyPhotoID> = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?
    private(set) var needsAlbumRefresh = false
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
    var requestSearchText = ""
    var isRequestList: Bool { section == .sharing && shareScope == .requests && selectedAlbum == nil }
    var visibleSharedEntries: [SynologyPhotoSharedEntry] {
        let keyword = requestSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRequestList, !keyword.isEmpty else { return sharedEntries }
        return sharedEntries.filter { $0.title.localizedStandardContains(keyword) }
    }
    private(set) var isFiltering = false
    @ObservationIgnored private let repository: (any SynologyPhotosServing)?
    @ObservationIgnored private var collectionOffset = 0
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    private(set) var isSlideshowPresented = false
    private(set) var isSlideshowPlaying = false
    private(set) var isLoadingSlideshow = false
    private(set) var slideshowError: String?
    private(set) var slideshowMediaID = UUID()
    @ObservationIgnored private var slideshowTask: Task<Void, Never>?
    @ObservationIgnored private var slideshowPhotos: [SynologyPhoto] = []
    @ObservationIgnored private var slideshowQuery: SynologyPhotoQuery?
    @ObservationIgnored private var slideshowSpace: SynologyPhotoSpace = .personal
    @ObservationIgnored private var slideshowOffset = 0
    @ObservationIgnored private var slideshowHasMore = false
    @ObservationIgnored private var slideshowVideoFinished = false
    @ObservationIgnored private let slideshowDelay: @Sendable () async throws -> Void
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextOffset = 0
    @ObservationIgnored private var query: SynologyPhotoQuery = .recentlyAdded
    @ObservationIgnored private let pageSize: Int

    init(repository: (any SynologyPhotosServing)? = nil, pageSize: Int = 100,
         deletionReviewDelay: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         previewConversionSupport: SynologyPhotoPreviewConversionSupport? = nil,
         slideshowDelay: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }) {
        self.previewConversionSupport = previewConversionSupport ?? .init(
            hevc: (CGImageSourceCopyTypeIdentifiers() as? [String])?.contains(UTType.heic.identifier) == true,
            vc1: false, video: AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHighestQuality))
        self.repository = repository
        self.pageSize = pageSize
        self.deletionReviewDelay = deletionReviewDelay
        self.slideshowDelay = slideshowDelay
    }

    func loadIfNeeded() async {
        guard isModuleEnabled, !hasLoaded, !isLoading else { return }
        await refresh()
    }

    var automaticPreviewSupported: Bool { previewConversionSupport.hevc || previewConversionSupport.video }
    var hasPendingAutomaticPreview: Bool {
        if case .generateAutomaticPreview = pendingMutation { return true }
        return false
    }

    func automaticPreviewRevision(for photo: SynologyPhoto) -> Int {
        guard let unit = photo.thumbnail?.unitID else { return 0 }
        return automaticPreviewRevisions[photo.id.space]?[unit] ?? 0
    }

    func setAutomaticPreviewSettingsVisible(_ visible: Bool) { automaticPreviewSettingsVisible = visible }

    func setPreviewVisible(_ photo: SynologyPhoto, visible: Bool, source: UUID) {
        if visible { visiblePreviewSources[source] = photo.id } else { visiblePreviewSources.removeValue(forKey: source) }
        scheduleVisiblePreviews()
    }

    private func scheduleVisiblePreviews() {
        nextVisiblePreviewAt = Date().addingTimeInterval(2)
        automaticPreviewWake?.cancel()
        guard automaticPreviewWorker != nil else { return }
        automaticPreviewWake = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await self?.processAutomaticPreview()
        }
    }

    private var automaticPreviewNeighbors: [SynologyPhoto] {
        guard let photo = previewPhoto else { return [] }
        let neighbors = isSlideshowPresented ? slideshowPhotos : (previewSimilarDetail?.photos ?? items)
        guard let index = neighbors.firstIndex(where: { $0.id == photo.id }) else { return [] }
        let isTimeline = !isSlideshowPresented && previewSimilarDetail == nil && section == .timeline
        let isComplete = isSlideshowPresented ? !slideshowHasMore : (previewSimilarDetail != nil || (!hasMore && !hasPrevious))
        func neighbor(_ offset: Int, wraps: Bool) -> SynologyPhoto? {
            let position = index + offset
            if neighbors.indices.contains(position) { return neighbors[position] }
            guard wraps && isComplete else { return nil }
            return neighbors[(position % neighbors.count + neighbors.count) % neighbors.count]
        }
        var previous = [-2, -1].compactMap { neighbor($0, wraps: !isTimeline) }
        var next = [1, 2, 3].compactMap { neighbor($0, wraps: true) }
        let uniqueCount = Set((previous + [photo] + next).map(\.id)).count
        // 与网页相同：先按整个相邻集合缩减，再排除视频，不向范围外补找照片。
        if uniqueCount < 4 { next = Array(next.prefix(1)) }
        else if uniqueCount == 4, !next.isEmpty { next.removeLast() }
        if uniqueCount < 6 { previous = Array(previous.suffix(1)) }
        return (next + previous).filter { $0.id != photo.id && !["video", "video360"].contains($0.mediaType) }
    }

    private var automaticPreviewPhotos: [SynologyPhoto] {
        var photos: [SynologyPhoto] = []
        if let photo = previewPhoto {
            photos.append(photo)
            photos += automaticPreviewNeighbors
        }
        let visible = Set(visiblePreviewSources.values)
        photos += (items + (previewSimilarDetail?.photos ?? [])).filter { visible.contains($0.id) }
        var seen = Set<SynologyPhotoID>()
        return photos.filter { seen.insert($0.id).inserted }
    }

    private func isFinishedAutomaticPreview(_ task: SynologyPhotoAutomaticPreviewTask) -> Bool {
        // 同一单元可能同时来自可见项与后台列表，来源变化不能重复提交。
        (automaticPreviewFinished.union(automaticPreviewFailed)).contains {
            $0.profileID == task.profileID && $0.space == task.space && $0.unitID == task.unitID &&
            $0.filename == task.filename && ($0.typeCode == 0) == (task.typeCode == 0) &&
            $0.needsThumbnail == task.needsThumbnail && $0.needsVideo == task.needsVideo
        }
    }

    private func preferredAutomaticPreview(in candidates: [SynologyPhotoAutomaticPreviewTask]) -> SynologyPhotoAutomaticPreviewTask? {
        guard let priority = candidates.map(\.priority.rawValue).min() else { return nil }
        let tier = candidates.filter { $0.priority.rawValue == priority }
        func candidate(for photo: SynologyPhoto) -> SynologyPhotoAutomaticPreviewTask? {
            tier.first { $0.profileID == photo.id.profileID && $0.space == photo.id.space &&
                ($0.sourcePhoto?.id == photo.id || $0.unitID == photo.thumbnail?.unitID) }
        }
        if let photo = previewPhoto {
            if let task = candidate(for: photo) { return task }
            for neighbor in automaticPreviewNeighbors {
                if let task = candidate(for: neighbor) { return task }
            }
        }
        let visibleIDs = Set(visiblePreviewSources.values)
        return items.lazy.filter { visibleIDs.contains($0.id) }.compactMap { candidate(for: $0) }.first ?? tier.first
    }

    func startAutomaticPreviews() {
        guard automaticPreviewWorker == nil, isModuleEnabled else { return }
        automaticPreviewWorker = Task { [weak self] in
            var delay = 5.0
            while !Task.isCancelled {
                guard let self else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                let completed = self.automaticPreviewCompleted, failed = self.automaticPreviewFailed.count
                await self.processAutomaticPreview()
                delay = completed != self.automaticPreviewCompleted || failed != self.automaticPreviewFailed.count ? 0.1 : 5
            }
        }
    }

    func pauseAutomaticPreviews() {
        automaticPreviewPaused = true
        automaticPreviewOperation?.cancel()
    }

    func resumeAutomaticPreviews() {
        automaticPreviewFailed = []
        automaticPreviewError = nil
        automaticPreviewPaused = false
        startAutomaticPreviews()
    }

    /// 一个处理周期仅领取一项；直接复用Repository操作编号，不刷新图库和月份锚点。
    func processAutomaticPreview(now: Date = Date()) async {
        guard isModuleEnabled, hasLoaded, !isLoading, !isDeleting, !isCheckingDeletion, !isManaging,
              similarBatchQueue.isEmpty, !isUploading, pendingDeletionPhotos.isEmpty,
              pendingMutationID == nil || hasPendingAutomaticPreview else { return }
        guard hasPendingAutomaticPreview || (automaticPreviewEnabled == true && !automaticPreviewPaused && !automaticPreviewSettingsVisible && automaticPreviewSupported) else { return }
        guard !hasPendingAutomaticPreview || now >= nextAutomaticReviewAt else { return }
        isManaging = true; isGeneratingAutomaticPreview = true
        let operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isManaging = false; self.isGeneratingAutomaticPreview = false; self.automaticPreviewFilename = nil }
            var executingTask: SynologyPhotoAutomaticPreviewTask?
            do {
                let service = try self.service()
                if let id = self.pendingMutationID, case .generateAutomaticPreview(let task, _) = self.pendingMutation {
                    self.nextAutomaticReviewAt = now.addingTimeInterval(min(60, 5 * pow(2, Double(min(4, self.automaticReviewAttempts)))))
                    self.automaticReviewAttempts += 1
                    let result = try await service.reviewMutation(operationID: id)
                    await self.applyAutomaticPreviewResult(result, id: id, task: task, service: service)
                    return
                }
                // 网页或其他客户端可能修改开关；领取新任务前读取当前设置。
                self.automaticPreviewEnabled = try await service.automaticPreviewEnabled()
                guard self.automaticPreviewEnabled == true, !self.automaticPreviewPaused, !Task.isCancelled else { return }
                let scanSpaces = [self.selectedSpace] + self.spaces.filter { $0 != self.selectedSpace }
                var candidates: [SynologyPhotoAutomaticPreviewTask] = []
                if now >= self.nextVisiblePreviewAt {
                    for photo in self.automaticPreviewPhotos {
                        guard await service.managementFeatures(in: photo.id.space).contains(.automaticPreview) else { continue }
                        do {
                            let tasks = try await service.automaticPreviewTasks(for: photo, support: self.previewConversionSupport)
                            candidates += tasks.filter { ($0.needsThumbnail || $0.needsVideo) && !self.isFinishedAutomaticPreview($0) &&
                                (photo.mediaType != "live" || photo.id == self.previewPhoto?.id || $0.typeCode == 0) }
                        } catch is CancellationError { throw CancellationError() }
                        catch { self.automaticPreviewError = operationErrorMessage(error, fallback: "photos.automatic.failed") }
                        // 最优等级已找到时才提前结束；高成本格式不能挡住后面的普通照片。
                        if candidates.contains(where: { $0.priority == .standard }) { break }
                    }
                }
                for space in scanSpaces where candidates.isEmpty && self.spaces.contains(space) && (space != .shared || self.canManageSharedSpace) {
                    guard await service.managementFeatures(in: space).contains(.automaticPreview) else { continue }
                    do {
                        let tasks = try await service.automaticPreviewTasks(in: space, support: self.previewConversionSupport)
                        candidates += tasks.filter { ($0.needsThumbnail || $0.needsVideo) && !self.isFinishedAutomaticPreview($0) }
                    } catch is CancellationError { throw CancellationError() }
                    catch { self.automaticPreviewError = operationErrorMessage(error, fallback: "photos.automatic.failed") }
                }
                let priority = self.preferredAutomaticPreview(in: candidates)
                guard let task = priority, !Task.isCancelled, !self.automaticPreviewPaused else { return }
                executingTask = task
                self.automaticPreviewFilename = task.filename
                let command = SynologyPhotosMutation.generateAutomaticPreview(task, support: self.previewConversionSupport)
                let id = UUID()
                // 提交前异常没有未知写入；prepare与perform都核对目标，避免在选择变化后写错项。
                try await service.prepareMutation(command)
                try Task.checkCancellation()
                self.pendingMutationID = id; self.pendingMutation = command
                self.nextAutomaticReviewAt = now.addingTimeInterval(5); self.automaticReviewAttempts = 0
                do {
                    let result = try await service.performMutation(command, operationID: id) { _, _ in }
                    await self.applyAutomaticPreviewResult(result, id: id, task: task, service: service)
                } catch {
                    self.pendingMutationID = nil; self.pendingMutation = nil
                    throw error
                }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                if let executingTask { self.automaticPreviewFailed.insert(executingTask) }
                self.automaticPreviewError = operationErrorMessage(error, fallback: "photos.automatic.failed")
            }
        }
        automaticPreviewOperation = operation
        await operation.value
        automaticPreviewOperation = nil
    }

    private func applyAutomaticPreviewResult(_ result: SynologyPhotosMutationResult, id: UUID,
        task: SynologyPhotoAutomaticPreviewTask, service: any SynologyPhotosServing) async {
        guard pendingMutationID == id else { return }
        if result.state == .pendingReview { return }
        pendingMutationID = nil; pendingMutation = nil
        if result.state == .confirmed {
            automaticPreviewFinished.insert(task); automaticPreviewCompleted += 1
            automaticPreviewRevisions[task.space, default: [:]][task.unitID, default: 0] += 1
            automaticPreviewError = nil
            // 仅刷新已有照片的预览信息，不重新查询时间线或改变选择。
            let affected = items.filter { $0.id.space == task.space && $0.thumbnail?.unitID == task.unitID }
            for photo in affected {
                guard let updated = try? await service.details(for: photo), updated.id == photo.id else { continue }
                if let index = items.firstIndex(where: { $0.id == updated.id }) { items[index] = updated }
                if previewPhoto?.id == updated.id { showPreview(updated) }
            }
        } else {
            if !Task.isCancelled {
                automaticPreviewFailed.insert(task)
                automaticPreviewError = result.automaticPreviewFailureRecorded
                    ? L10n.string("photos.automatic.failureRecorded", task.filename)
                    : L10n.string("photos.automatic.failed")
            }
        }
    }

    var paginationIdentity: String { "\(generation):\(nextOffset):\(collectionOffset)" }
    var sharedCategoriesRequireManagement: Bool { section == .albums && selectedSpace == .shared && !canManageSharedSpace }
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
        case .similar(let start, let end):
            guard ceiling >= start else { return }
            destination = .similar(startTime: start, endTime: min(end, ceiling))
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
        if isSlideshowPresented { closePreview() }
        generation += 1
        let current = generation
        query = destination
        previousMonthID = month.id
        previousPageErrorMessage = nil
        isLoadingPrevious = false
        selectedTimelineMonthID = month.id
        clearSelection(); deletionCandidates = []; preparedDeletionPhotos = []
        selectedAlbumAccess = nil
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
        case .similar(let lower, let upper):
            previousQuery = .similar(startTime: max(lower, start), endTime: min(upper, end))
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
        let grouped = Dictionary(grouping: items) { photo in
            let date = selectedCategory == .recentlyAdded ? photo.indexedAt : photo.takenAt
            if displayPreferences?.grouping == .month { return calendar.dateInterval(of: .month, for: date)!.start }
            return calendar.startOfDay(for: date)
        }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    func refresh(space: SynologyPhotoSpace? = nil) async {
        await refresh(space: space, afterFolderMutation: false)
    }

    private func refresh(space: SynologyPhotoSpace? = nil, afterFolderMutation: Bool) async {
        guard isModuleEnabled, !isDeleting, !isPreparingSimilarBatch,
              !isBrowsingBlocked || afterFolderMutation else { return }
        if !afterFolderMutation {
            if !isSaving { saveMessage = nil }
            // 刷新可以清理已结束操作的提示，但待核对、分批继续和分享清理不能被隐藏。
            if (!isManaging || isGeneratingAutomaticPreview), (pendingMutationID == nil || hasPendingAutomaticPreview), retryableManagementMutation == nil,
               temporarySharingCleanup == nil, similarBatchQueue.isEmpty {
                managementMessage = nil
                managementLink = nil
            }
        }
        if isSlideshowPresented { closePreview() }
        clearSelection(); deletionCandidates = []; preparedDeletionPhotos = []
        pagedPhotoIDs = []
        generation += 1
        let current = generation
        var keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 顶部搜索检索整个空间，离开分组分类后再展示搜索结果。
        if selectedCategory == .similar, !keyword.isEmpty { selectedCategory = nil; selectedCategoryItem = nil }
        selectedAlbumAccess = nil
        albumListSort = nil; albumListDisplay = nil
        selectedTimelineMonthID = nil
        timelineBaseQuery = nil
        previousMonthID = nil
        previousPageErrorMessage = nil
        isLoadingPrevious = false
        isFiltering = !keyword.isEmpty || filter.isActive
        isLoading = true
        hasLoaded = false
        isLoadingMore = false
        errorMessage = nil; needsAlbumRefresh = false; needsSharedListRefresh = false
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
            if !isUploading && pendingUploadID == nil && !isGeneratingAutomaticPreview {
                canManageSharedSpace = false
                supportsOriginalSizeJPEG = false
                displayPreferences = nil
                automaticPreviewEnabled = nil
                let access = try await repository.access()
                guard current == generation, !Task.isCancelled else { return }
                spaces = access.spaces
                canManageSharedSpace = access.canManageSharedSpace
                supportsOriginalSizeJPEG = access.supportsOriginalSizeJPEG
                displayPreferences = access.displaySettings
                automaticPreviewEnabled = access.automaticPreviewEnabled
            }
            await restoreUploadQueueIfNeeded(repository: repository)
            let albumOnly = spaces.isEmpty && (section == .albums || (section == .sharing && shareScope != .requests))
            guard let destination = spaces.first(where: { $0 == (space ?? selectedSpace) }) ?? spaces.first ?? (albumOnly ? .personal : nil) else {
                resetSpaceNavigation()
                managementFeatures = await repository.managementFeatures(in: .personal).intersection([.globalSettings, .conversionCache, .sharedMembers, .sharedSpaceSettings, .automaticPreviewSettings, .recognitionSettings, .displaySettings, .duplicateSettings, .albumSorting, .albumListSorting, .albumListDisplay])
                hasLoaded = true
                return
            }
            if destination != selectedSpace && !albumOnly {
                // 包含权限变化后的自动回退；旧空间的目录、分类和筛选编号不能用于新空间。
                resetSpaceNavigation()
                keyword = ""
                isFiltering = false
            }
            selectedSpace = destination
            if albumOnly {
                selectedCategory = nil; selectedCategoryItem = nil
                filter = SynologyPhotoFilter(); searchText = ""; keyword = ""; isFiltering = false
            }
            if section == .albums, destination == .shared, !canManageSharedSpace, selectedCategory != nil {
                // 全局分类管理权限撤回时清理旧分类，统一相册仍可按自身权限浏览。
                resetSpaceNavigation()
                keyword = ""; isFiltering = false
            }
            managementFeatures = await repository.managementFeatures(in: destination)
            guard current == generation, !Task.isCancelled else { return }
            if let album = selectedAlbum {
                do {
                    let rights = try await repository.albumAccess(id: album.id)
                    guard current == generation, !Task.isCancelled else { return }
                    guard rights.albumID == album.id else { throw CapabilitySelectionError.unsupported(apiName: "Photos.AlbumIdentity") }
                    selectedAlbumAccess = rights
                } catch {
                    guard current == generation else { return }
                    managementMessage = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.unavailable")
                }
            }
            if let scope = albumListScope {
                if managementFeatures.contains(.albumListSorting) {
                    do {
                        let sort = try await repository.albumListSort(scope)
                        guard current == generation, !Task.isCancelled else { return }
                        albumListSort = sort
                    } catch {
                        guard current == generation, !Task.isCancelled else { return }
                        managementMessage = L10n.string("photos.albumList.readFailed")
                    }
                }
                if scope == .albums, managementFeatures.contains(.albumListDisplay) {
                    do {
                        let display = try await repository.albumListDisplay()
                        guard current == generation, !Task.isCancelled else { return }
                        albumListDisplay = display
                    } catch {
                        guard current == generation, !Task.isCancelled else { return }
                        managementMessage = L10n.string("photos.albumList.readFailed")
                    }
                }
            }
            if section == .sharing, selectedAlbum == nil {
                let page = try await repository.sharedEntries(shareScope, offset: 0, limit: pageSize, sort: albumListSort)
                guard current == generation, !Task.isCancelled else { return }
                sharedEntries = page
                collectionOffset = page.count
                hasMoreCollections = page.count == pageSize
                hasLoaded = true
                return
            }
            if keyword.isEmpty, section == .albums, selectedAlbum == nil, selectedCategory == nil {
                do {
                    availableCategories = []
                    if !albumOnly && (destination != .shared || canManageSharedSpace) {
                        let categories = try await repository.categories(in: destination)
                        guard current == generation, !Task.isCancelled else { return }
                        #if os(macOS)
                        availableCategories = categories
                        #else
                        // 移动端尚未迁移相似组交互，保持现有分类范围。
                        availableCategories = categories.subtracting([.similar])
                        #endif
                    }
                } catch {
                    guard current == generation else { return }
                    errorMessage = L10n.string("photos.categories.failed")
                }
                // 相册由统一Foto入口列出，照片来源独立于分类空间选择。
                let page = try await repository.albums(offset: 0, limit: pageSize, display: albumListDisplay, sort: albumListSort)
                guard current == generation, !Task.isCancelled else { return }
                collections = page
                collectionOffset = page.count
                hasMoreCollections = page.count == pageSize
                hasLoaded = true
                return
            }
            if let category = selectedCategory, selectedCategoryItem == nil,
               category != .recentlyAdded, category != .videos, category != .similar {
                let page = try await repository.categoryItems(category, in: destination, offset: 0, limit: pageSize)
                guard current == generation, !Task.isCancelled else { return }
                guard page.allSatisfy({ $0.space == destination }) else { throw CapabilitySelectionError.unsupported(apiName: "Photos.CategorySource") }
                collections = page
                collectionOffset = page.count
                hasMoreCollections = page.count == pageSize
                hasLoaded = true
                return
            }
            if selectedCategory == .recentlyAdded {
                query = .recentlyAdded
            } else if selectedCategory == .similar, keyword.isEmpty {
                let timeline = try await repository.similarTimeline(in: destination)
                guard current == generation, !Task.isCancelled else { return }
                days = timeline
                guard let range = Self.timeRange(for: timeline) else { hasLoaded = true; return }
                query = .similar(startTime: range.lowerBound, endTime: range.upperBound)
            } else if let category = selectedCategory, let selected = selectedCategoryItem, category == .concept || category == .tags || destination == .shared {
                let timeline = try await repository.categoryTimeline(category, id: selected.id, in: destination)
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
                let folder = folderHistory.last!, folderID = folder.id
                let sort = managementFeatures.contains(.folderSorting) ? try await repository.folderSort(folder) : (folder.sort ?? .init())
                guard current == generation, !Task.isCancelled else { return }
                let page = try await repository.folders(in: destination, parentID: folderID, offset: 0, limit: pageSize, direction: sort.direction)
                guard current == generation, !Task.isCancelled else { return }
                collections = page
                collectionOffset = page.count
                hasMoreCollections = page.count == pageSize
                query = .folder(id: folderID, sort: sort)
            } else if keyword.isEmpty, let album = selectedAlbum {
                var sort = SynologyPhotoSort(direction: .descending)
                if managementFeatures.contains(.albumSorting) {
                    do { sort = try await repository.albumSort(id: album.id) }
                    catch { managementMessage = operationErrorMessage(error, fallback: "photos.manage.failed") }
                    guard current == generation, !Task.isCancelled else { return }
                }
                query = .album(id: album.id, sort: sort)
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

    private func resetSpaceNavigation() {
        similarStatus = nil; similarRefreshError = nil
        folderHistory = []
        selectedAlbum = nil
        selectedAlbumAccess = nil
        selectedCategory = nil
        selectedCategoryItem = nil
        availableCategories = []
        searchText = ""
        filter = SynologyPhotoFilter()
        isFiltering = false
        showsFilters = false
        filterOptionsGeneration += 1
        options = SynologyPhotoFilterOptions(people: [], locations: [])
        filterOptionsErrorMessage = nil
        isLoadingFilterOptions = false
        closePreview()
    }

    func selectSpace(_ space: SynologyPhotoSpace) async {
        guard spaces.contains(space), section != .sharing,
              !isDeleting, !isCheckingDeletion, !isBrowsingBlocked else { return }
        preferredLibrarySpace = space
        if selectedSpace != space { await refresh(space: space) }
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

    private(set) var folderCoverRevision = 0
    var currentCreationFolder: SynologyPhotoCollection? {
        guard section == .folders, !isFiltering, managementFeatures.contains(.folders),
              let folder = folderHistory.last, folder.space == selectedSpace,
              case .folder(let id, _) = query, id == folder.id else { return nil }
        return folder
    }

    var currentSortFolder: (folder: SynologyPhotoCollection, sort: SynologyPhotoSort)? {
        guard section == .folders, managementFeatures.contains(.folderSorting),
              let folder = folderHistory.last, folder.space == selectedSpace,
              case .folder(let id, let sort) = query, id == folder.id else { return nil }
        return (folder, sort)
    }

    func changeCurrentFolderSort(_ sort: SynologyPhotoSort) {
        guard !isLoading, let current = currentSortFolder, current.sort != sort else { return }
        submitMutation(.setFolderSort(folder: current.folder, sort: sort))
    }

    private(set) var albumListSort: SynologyPhotoAlbumListSort?
    private(set) var albumListDisplay: SynologyPhotoAlbumDisplay?
    var albumListScope: SynologyPhotoAlbumListScope? {
        guard selectedAlbum == nil, selectedCategory == nil, !isFiltering else { return nil }
        if section == .albums { return .albums }
        if section == .sharing, shareScope != .requests { return shareScope == .withMe ? .withMe : .byMe }
        return nil
    }
    func changeAlbumListSort(_ sort: SynologyPhotoAlbumListSort) {
        guard !isLoading, let scope = albumListScope, let original = albumListSort, original != sort else { return }
        submitMutation(.setAlbumListSort(scope: scope, original: original, sort: sort))
    }
    func changeAlbumListDisplay(_ display: SynologyPhotoAlbumDisplay) {
        guard !isLoading, albumListScope == .albums, let original = albumListDisplay, original != display else { return }
        submitMutation(.setAlbumListDisplay(original: original, display: display))
    }

    var currentSortAlbum: (id: Int, sort: SynologyPhotoSort)? {
        guard managementFeatures.contains(.albumSorting), let album = selectedAlbum,
              selectedAlbumAccess?.albumID == album.id,
              case .album(let id, let sort) = query, id == album.id else { return nil }
        return (id, sort)
    }

    func changeCurrentAlbumSort(_ sort: SynologyPhotoSort) {
        guard !isLoading, let current = currentSortAlbum, current.sort != sort else { return }
        submitMutation(.setAlbumSort(id: current.id, original: current.sort, sort: sort))
    }

    var currentCoverFolder: SynologyPhotoCollection? {
        guard section == .folders, let folder = folderHistory.last, folder.path != "/",
              managementFeatures.contains(.folderCover) else { return nil }
        return folder
    }
    func folderCoverImages(_ folder: SynologyPhotoCollection) async throws -> [Data] {
        let current = generation
        let images = try await service().folderCoverImages(folder)
        guard current == generation, !Task.isCancelled else { throw CancellationError() }
        return images
    }
    func folderCoverSort(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoSort {
        try await service().folderSort(folder)
    }
    func folderCoverPage(_ folder: SynologyPhotoCollection, offset: Int, sort: SynologyPhotoSort = .init()) async throws -> SynologyPhotoPage {
        try await service().photos(in: folder.space, query: .folder(id: folder.id, sort: sort), offset: offset, limit: 100)
    }
    func folderCoverChildren(_ folder: SynologyPhotoCollection, direction: SynologyPhotoSort.Direction = .ascending) async throws -> [SynologyPhotoCollection] {
        var result: [SynologyPhotoCollection] = []
        while true {
            try Task.checkCancellation()
            let page = try await service().folders(in: folder.space, parentID: folder.id, offset: result.count, limit: 100, direction: direction)
            result.append(contentsOf: page)
            if page.count < 100 { return result }
        }
    }

    func thumbnail(for album: SynologyPhotoCollection) async throws -> Data {
        let current = generation
        let data = try await service().thumbnail(for: album)
        guard current == generation, !Task.isCancelled else { throw CancellationError() }
        return data
    }

    func leaveGallery() {
        deletionReviewEpoch += 1
        automaticPreviewWorker?.cancel(); automaticPreviewWorker = nil
        automaticPreviewWake?.cancel(); automaticPreviewWake = nil
        automaticPreviewOperation?.cancel()
        visiblePreviewSources = [:]
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
        backgroundControlTask?.cancel()
        stopUploadQueue()
        managementTask?.cancel()
        if temporarySharingCleanup != nil { temporarySharingCleanupNeedsRetry = true }
        saveTask?.cancel()
    }

    func setModuleEnabled(_ enabled: Bool) {
        isModuleEnabled = enabled
        if !enabled {
            managementCompletion = nil
            temporaryCreationID = nil; cancelledTemporaryCreation = false
            cancel(); items = []; collections = []; spaces = []; canManageSharedSpace = false; supportsOriginalSizeJPEG = false; folderHistory = []; selectedAlbum = nil
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
        await refresh(space: section == .sharing ? .personal : preferredLibrarySpace)
    }

    func open(_ collection: SynologyPhotoCollection) async {
        guard !isDeleting, !isBrowsingBlocked else { return }
        searchText = ""
        if section == .folders { folderHistory.append(collection) }
        else if let category = selectedCategory {
            guard collection.space == selectedSpace else { return }
            selectedCategoryItem = collection
            if category == .person { filter.personID = collection.id }
            if category == .location { filter.locationID = collection.id }
        }
        else { selectedAlbum = collection }
        await refresh()
    }

    var canGoBack: Bool { folderHistory.count > 1 || selectedAlbum != nil || selectedCategory != nil }
    func navigateToFolder(_ folder: SynologyPhotoCollection) async {
        guard section == .folders, !isDeleting, !isBrowsingBlocked,
              let index = folderHistory.firstIndex(of: folder), index < folderHistory.count - 1 else { return }
        folderHistory = Array(folderHistory.prefix(index + 1))
        await refresh()
    }

    /// 拖放仅携带本次图库内的随机标识；照片和路径始终保留在当前Model。
    func beginPhotoDrag(photo: SynologyPhoto? = nil, folder: SynologyPhotoCollection? = nil) -> UUID? {
        dragSelection = nil
        guard canHandlePhotoDrag else { return nil }
        let photos: [SynologyPhoto], folders: [SynologyPhotoCollection]
        if let photo, folder == nil, items.contains(photo) {
            let selected = selectedPhotoIDs.contains(photo.id)
            photos = selected ? selectedPhotos : [photo]; folders = selected ? selectedFolders : []
        } else if let folder, photo == nil, collections.contains(folder) {
            let selected = selectedFolderIDs.contains(folder.id)
            photos = selected ? selectedPhotos : []; folders = selected ? selectedFolders : [folder]
        } else { return nil }
        guard canTransfer(photos, copying: false, folders: folders) else { return nil }
        let snapshot = PhotoDragSelection(photos: photos, folders: folders, generation: generation)
        dragSelection = snapshot
        return snapshot.id
    }

    private var canHandlePhotoDrag: Bool {
        section == .folders && isModuleEnabled && managementFeatures.contains(.fileTransfer) &&
            !isLoading && !isManaging && !isDeleting && !isCheckingDeletion && !isBrowsingBlocked && pendingMutationID == nil
    }

    func photoDropPath(to target: SynologyPhotoCollection) -> [SynologyPhotoCollection]? {
        guard target.space == selectedSpace else { return nil }
        if let index = folderHistory.firstIndex(of: target) { return Array(folderHistory.prefix(index + 1)) }
        if collections.contains(target), target.parentID == folderHistory.last?.id { return folderHistory + [target] }
        return nil
    }

    func canDropPhotos(to target: SynologyPhotoCollection) -> Bool {
        guard canHandlePhotoDrag, let snapshot = dragSelection, snapshot.generation == generation,
              photoDropPath(to: target) != nil,
              canTransfer(snapshot.photos, copying: false, folders: snapshot.folders) else { return false }
        return SynologyPhotosMutation.move(snapshot.photos, folderID: target.id, destinationSpace: target.space, folders: snapshot.folders).acceptsTransferDestination(target)
    }

    func takePhotoDrop(token: UUID, to target: SynologyPhotoCollection) -> PhotoDragSelection? {
        guard dragSelection?.id == token, canDropPhotos(to: target) else { return nil }
        let snapshot = dragSelection
        dragSelection = nil
        return snapshot
    }

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
                let page = try await repository.sharedEntries(shareScope, offset: collectionOffset, limit: pageSize, sort: albumListSort)
                guard current == generation, !Task.isCancelled else { return }
                let ids = Set(sharedEntries.map(\.id))
                sharedEntries.append(contentsOf: page.filter { !ids.contains($0.id) })
                collectionOffset += page.count
                hasMoreCollections = page.count == pageSize
                return
            }
            let page: [SynologyPhotoCollection]
            if let category = selectedCategory, selectedCategoryItem == nil {
                page = try await repository.categoryItems(category, in: selectedSpace, offset: collectionOffset, limit: pageSize)
            } else if section == .albums {
                page = try await repository.albums(offset: collectionOffset, limit: pageSize, display: albumListDisplay, sort: albumListSort)
            } else if let folder = folderHistory.last {
                let direction: SynologyPhotoSort.Direction = if case .folder(_, let sort) = query { sort.direction } else { .ascending }
                page = try await repository.folders(in: selectedSpace, parentID: folder.id, offset: collectionOffset, limit: pageSize, direction: direction)
            } else { return }
            guard current == generation, !Task.isCancelled else { return }
            if selectedCategory != nil {
                guard page.allSatisfy({ $0.space == selectedSpace }) else { throw CapabilitySelectionError.unsupported(apiName: "Photos.CategorySource") }
            }
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

    func sharingManagementTarget(for entry: SynologyPhotoSharedEntry) -> SynologyPhotoCollection? {
        guard section == .sharing, shareScope == .withOthers, selectedAlbum == nil,
              managementFeatures.contains(.sharing), let id = entry.albumID, id > 0,
              sharedEntries.contains(where: { $0.id == entry.id && $0.albumID == id }) else { return nil }
        return .init(id: id, name: entry.title)
    }

    func retrySharedListRefresh() async {
        guard needsSharedListRefresh, !isManaging, !isLoadingMore, let service = try? service() else { return }
        await refreshManagedSharingList(service: service)
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

    func showPreview(_ photo: SynologyPhoto, playMotion: Bool = false, similarDetail: SynologyPhotoSimilarDetail? = nil) {
        guard isModuleEnabled else { return }
        previewTask?.cancel()
        previewGeneration += 1
        let current = previewGeneration
        previewPhoto = photo
        scheduleVisiblePreviews()
        if similarDetail == nil { similarSelectedIDs = [photo.id] }
        previewSimilarDetail = similarDetail
        similarPreviewError = nil
        isLoadingSimilarPreview = photo.similarGroup != nil && similarDetail == nil
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
                if detail.mediaType == "video" || (detail.canPlayMotion && playMotion) {
                    let source = try await service.videoSource(for: detail)
                    guard current == self.previewGeneration, !Task.isCancelled else { return }
                    self.previewSource = source
                } else {
                    let data = try await service.previewImage(for: detail)
                    guard current == self.previewGeneration, !Task.isCancelled else { return }
                    self.previewData = data
                }
                self.isPreparingPreview = false
                if photo.similarGroup != nil, similarDetail == nil { await self.loadSimilarPreview(for: detail, generation: current) }
            } catch {
                guard current == self.previewGeneration, !Task.isCancelled else { return }
                self.previewError = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.media.failed")
                self.isLoadingSimilarPreview = false
            }
        }
    }

    private func loadSimilarPreview(for photo: SynologyPhoto, generation: Int) async {
        isLoadingSimilarPreview = true; similarPreviewError = nil
        defer { if generation == previewGeneration { isLoadingSimilarPreview = false } }
        do {
            let detail = try await service().similarPhotos(for: photo)
            guard generation == previewGeneration, !Task.isCancelled else { return }
            guard detail.group.profileID == photo.id.profileID, detail.group.space == photo.id.space,
                  detail.group.id == photo.similarGroup?.id, detail.group.photoIDs.contains(photo.id.unitID),
                  detail.photos.count == detail.group.photoIDs.count,
                  Set(detail.photos.map(\.id.unitID)) == Set(detail.group.photoIDs),
                  detail.photos.allSatisfy({ $0.id.profileID == photo.id.profileID && $0.id.space == photo.id.space }) else {
                throw CapabilitySelectionError.unsupported(apiName: "Photos.SimilarIdentity")
            }
            previewSimilarDetail = detail
        } catch {
            guard generation == previewGeneration, !Task.isCancelled else { return }
            similarPreviewError = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.similar.failed")
        }
    }

    func retrySimilarPreview() async {
        guard let photo = previewPhoto, photo.similarGroup != nil, !isLoadingSimilarPreview else { return }
        await loadSimilarPreview(for: photo, generation: previewGeneration)
    }

    func showSimilarPreview(_ photo: SynologyPhoto) {
        guard let detail = previewSimilarDetail, detail.photos.contains(photo) else { return }
        showPreview(photo, similarDetail: detail)
    }

    func closePreview() {
        stopSlideshow()
        previewGeneration += 1
        previewTask?.cancel()
        previewPhoto = nil
        previewSimilarDetail = nil; similarPreviewError = nil; isLoadingSimilarPreview = false
        similarSelectedIDs = []
        previewData = nil
        previewSource = nil
        isPreparingPreview = false
        isPlayingMotion = false
    }

    func playMotion() {
        guard let photo = previewPhoto, photo.canPlayMotion, !isPlayingMotion else { return }
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
        let candidates = previewSimilarDetail?.photos ?? items
        guard let id = previewPhoto?.id, let index = candidates.firstIndex(where: { $0.id == id }), candidates.indices.contains(index + direction) else { return }
        if previewSimilarDetail != nil { showSimilarPreview(candidates[index + direction]) }
        else { showPreview(candidates[index + direction]) }
    }

    var canStartSlideshow: Bool { isModuleEnabled && !isLoading && !isDeleting && !isBrowsingBlocked && (previewPhoto != nil || !items.isEmpty) }

    func startSlideshow() {
        guard canStartSlideshow, !isSlideshowPresented, let photo = previewPhoto ?? items.first else { return }
        if isPlayingMotion { finishMotion() }
        slideshowSpace = selectedSpace
        // 独立游标按完整原查询翻页，不改变图库已加载范围、选择或月份锚点。
        slideshowQuery = timelineBaseQuery ?? query
        slideshowPhotos = previewSimilarDetail?.photos ?? []
        slideshowHasMore = previewSimilarDetail == nil
        if previewSimilarDetail != nil { slideshowQuery = nil }
        slideshowOffset = 0; slideshowVideoFinished = false; slideshowError = nil
        isSlideshowPresented = true; isSlideshowPlaying = true
        if previewPhoto == nil { showPreview(photo) }
        scheduleSlideshow()
    }

    func stopSlideshow() {
        isSlideshowPresented = false; isSlideshowPlaying = false; isLoadingSlideshow = false
        slideshowTask?.cancel(); slideshowTask = nil
        slideshowPhotos = []; slideshowQuery = nil; slideshowError = nil
    }

    func toggleSlideshowPlayback() {
        guard isSlideshowPresented else { return }
        let retryMedia = slideshowError != nil || previewError != nil
        isSlideshowPlaying.toggle(); slideshowError = nil
        if isSlideshowPlaying {
            if slideshowVideoFinished { advanceSlideshow(1) }
            else if retryMedia, let photo = previewPhoto { slideshowMediaID = UUID(); showPreview(photo); scheduleSlideshow() }
            else { scheduleSlideshow() }
        } else { slideshowTask?.cancel(); isLoadingSlideshow = false }
    }

    func slideshowVideoEnded() {
        guard isSlideshowPresented else { return }
        slideshowVideoFinished = true
        if isSlideshowPlaying { advanceSlideshow(1) }
    }

    func slideshowPlaybackFailed() {
        guard isSlideshowPresented else { return }
        isSlideshowPlaying = false; isLoadingSlideshow = false; slideshowTask?.cancel()
        slideshowError = L10n.string("photos.slideshow.failed")
    }

    private func scheduleSlideshow() {
        slideshowTask?.cancel()
        guard isSlideshowPresented, isSlideshowPlaying else { return }
        slideshowTask = Task { [weak self] in
            guard let self else { return }
            await self.previewTask?.value
            guard !Task.isCancelled, self.isSlideshowPresented, self.isSlideshowPlaying else { return }
            if self.previewError != nil { self.slideshowPlaybackFailed(); return }
            // 视频按播放结束推进，不能用照片的三秒计时截断视频。
            guard self.previewSource == nil else { return }
            do {
                try await self.slideshowDelay()
                try Task.checkCancellation()
                try await self.moveSlideshow(1)
                guard !Task.isCancelled else { return }
                self.scheduleSlideshow()
            } catch { if !Task.isCancelled { self.slideshowPlaybackFailed() } }
        }
    }

    func advanceSlideshow(_ direction: Int) {
        guard isSlideshowPresented, [-1, 1].contains(direction) else { return }
        slideshowTask?.cancel(); slideshowError = nil
        slideshowTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.moveSlideshow(direction)
                guard !Task.isCancelled else { return }
                self.scheduleSlideshow()
            } catch { if !Task.isCancelled { self.slideshowPlaybackFailed() } }
        }
    }

    private func moveSlideshow(_ direction: Int) async throws {
        guard let id = previewPhoto?.id else { return }
        isLoadingSlideshow = true
        defer { if !Task.isCancelled { isLoadingSlideshow = false } }
        while !slideshowPhotos.contains(where: { $0.id == id }), slideshowHasMore { try await readSlideshowPage() }
        guard let index = slideshowPhotos.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileReadNoSuchFile) }
        if direction > 0, index + 1 == slideshowPhotos.count, slideshowHasMore { try await readSlideshowPage() }
        if direction < 0, index == 0 {
            while slideshowHasMore { try await readSlideshowPage() }
        }
        try Task.checkCancellation()
        guard isSlideshowPresented, !slideshowPhotos.isEmpty else { return }
        let next = (index + direction + slideshowPhotos.count) % slideshowPhotos.count
        slideshowVideoFinished = false
        slideshowMediaID = UUID()
        showPreview(slideshowPhotos[next], similarDetail: slideshowQuery == nil ? previewSimilarDetail : nil)
    }

    private func readSlideshowPage() async throws {
        guard let slideshowQuery else { return }
        let offset = slideshowOffset
        let page = try await service().photos(in: slideshowSpace, query: slideshowQuery, offset: offset, limit: pageSize)
        try Task.checkCancellation()
        guard isSlideshowPresented, page.offset == offset, page.nextOffset == offset + page.items.count,
              page.items.count <= pageSize, !page.hasMore || !page.items.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let existing = Set(slideshowPhotos.map(\.id))
        guard Set(page.items.map(\.id)).count == page.items.count, page.items.allSatisfy({ !existing.contains($0.id) }) else { throw CocoaError(.fileReadCorruptFile) }
        slideshowPhotos.append(contentsOf: page.items)
        slideshowOffset = page.nextOffset; slideshowHasMore = page.hasMore
    }

    var currentArchive: (target: SynologyPhotoArchiveTarget, name: String)? {
        if let album = selectedAlbum { return (.album(id: album.id), album.name) }
        if section == .folders, let folder = folderHistory.last { return (.folder(id: folder.id, space: selectedSpace), folder.name) }
        return nil
    }

    var selectedArchive: SynologyPhotoArchiveTarget? {
        guard section == .folders, !selectedFolders.isEmpty else { return nil }
        return .selection(photos: selectedPhotos, folders: selectedFolders)
    }

    func canDownloadArchive(_ target: SynologyPhotoArchiveTarget) -> Bool {
        guard isModuleEnabled else { return false }
        switch target {
        case .album(let id):
            if selectedAlbum?.id == id { return selectedAlbumAccess?.canDownload == true }
            return true // 非当前相册在开始下载时由Repository重新读取实际权限。
        case .folder(_, let space): return spaces.contains(space)
        case .selection(let photos, let folders):
            guard let first = folders.first, spaces.contains(first.space) else { return false }
            return folders.allSatisfy { $0.space == first.space && $0.parentID == first.parentID } &&
                photos.allSatisfy { $0.albumContext == nil && $0.id.space == first.space && $0.folderID == first.parentID && canDownload($0) }
        }
    }

    func cancelSave() { saveTask?.cancel() }

    func saveArchive(_ target: SynologyPhotoArchiveTarget, format: SynologyPhotoDownloadFormat, to url: URL) {
        guard !isSaving, canDownloadArchive(target) else { return }
        isSaving = true; saveProgress = nil; saveMessage = nil
        saveTask = Task { [weak self] in
            guard let self else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() }; self.isSaving = false }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).photos-archive")
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try await self.service().downloadArchive(target, format: format, to: staging) { [weak self] done, total in
                    Task { @MainActor in self?.saveProgress = total.flatMap { $0 > 0 ? Double(done) / Double($0) : nil } }
                }
                try Task.checkCancellation()
                // 目标替换仅来自NSSavePanel的明确保存确认，失败下载不会碰用户原文件。
                try await DownloadedFileExporter.export(from: staging, to: url, replaceExisting: true)
                self.saveMessage = L10n.string("photos.media.saved")
            } catch is CancellationError { self.saveMessage = nil }
            catch { self.saveMessage = Task.isCancelled ? nil : self.operationErrorMessage(error, fallback: "photos.media.saveFailed") }
        }
    }

    func save(_ photo: SynologyPhoto, to url: URL) {
        guard isModuleEnabled, !isSaving, canDownload(photo) else { return }
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
            catch { self.saveMessage = self.operationErrorMessage(error, fallback: "photos.media.saveFailed") }
        }
    }

    var canManageSelection: Bool { selectedFolderIDs.isEmpty && !selectedPhotos.isEmpty && selectedPhotos.count <= 100 && !isManaging && pendingMutationID == nil && !isDeleting && !isCheckingDeletion }

    func categoryThumbnail(for collection: SynologyPhotoCollection, category: SynologyPhotoCategory) async throws -> Data {
        try await service().thumbnail(for: collection, category: category)
    }
    func categoryPreviewImages(_ category: SynologyPhotoCategory, in space: SynologyPhotoSpace) async throws -> [Data] {
        let current = generation
        guard showsCategories, selectedSpace == space, availableCategories.contains(category) else { throw CancellationError() }
        let images = try await service().categoryPreviewImages(category, in: space)
        try Task.checkCancellation()
        guard current == generation, selectedSpace == space, showsCategories else { throw CancellationError() }
        return images
    }
    func pendingPreviewRegenerations(in space: SynologyPhotoSpace) async throws -> [SynologyPhoto] { try await service().pendingPreviewRegenerations(in: space) }
    func photoFaces(for photo: SynologyPhoto) async throws -> [SynologyPhotoFaceRegion] { try await service().photoFaces(for: photo) }
    func personFaces(personID: Int, photos: [SynologyPhoto]) async throws -> [SynologyPhotoFace] { try await service().personFaces(personID: personID, photos: photos) }
    func faceThumbnail(_ face: SynologyPhotoFace) async throws -> Data { try await service().thumbnail(for: face) }
    func conceptState(_ concept: SynologyPhotoCollection) async throws -> SynologyPhotoConceptVisibility { try await service().conceptState(id: concept.id, in: concept.space) }
    func canManageConceptPhotos(_ photos: [SynologyPhoto], cover: Bool) -> Bool {
        selectedCategory == .concept && selectedCategoryItem != nil && !photos.isEmpty && (!cover || photos.count == 1) &&
            photos.allSatisfy(canModifyOriginal) && managementFeatures.contains(cover ? .conceptCover : .conceptItems) &&
            !isManaging && !isDeleting && !isCheckingDeletion && pendingMutationID == nil
    }
    func conceptVisibility(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoConceptVisibility] { try await service().conceptVisibility(in: space) }
    func peopleVisibility(in space: SynologyPhotoSpace = .personal) async throws -> [SynologyPhotoPersonVisibility] { try await service().peopleVisibility(in: space) }
    func managementPeople(in space: SynologyPhotoSpace = .personal) async throws -> [SynologyPhotoCollection] { try await service().managementPeople(in: space) }
    func albumSharing(id: Int) async throws -> SynologyPhotoSharingState { try await service().albumSharing(id: id) }
    func canInspectFolderSharing(_ folder: SynologyPhotoCollection) -> Bool {
        folder.space == .shared && canManageSharedSpace && (1...2).contains(folder.path?.split(separator: "/").count ?? 0)
    }
    func folderSharing(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoFolderSharingState { try await service().folderSharing(folder) }
    func folderSharingRecipients() async throws -> [SynologyPhotoShareRecipient] { try await service().folderSharingRecipients() }
    func sharingRecipients() async throws -> [SynologyPhotoShareRecipient] { try await service().sharingRecipients() }
    func frozenAlbum(id: Int) async throws -> SynologyPhotoFrozenAlbum { try await service().frozenAlbum(id: id) }
    func albumCondition(id: Int) async throws -> SynologyPhotoAlbumCondition { try await service().albumCondition(id: id) }
    func conditionSuggestions(keyword: String, in space: SynologyPhotoSpace = .personal) async throws -> [String: [SynologyPhotoConditionOption]] { try await service().conditionSuggestions(keyword: keyword, in: space) }
    var conditionSourceSpaces: [SynologyPhotoSpace] { spaces.filter { $0 == .personal || canManageSharedSpace } }
    func conditionItemCount(_ condition: SynologyPhotoAlbumCondition) async throws -> Int { try await service().conditionItemCount(condition) }

    func photoRequest(id: String) async throws -> SynologyPhotoRequest { try await service().photoRequest(id: id) }
    func photoRequestAlbums() async throws -> [SynologyPhotoRequestAlbum] { try await service().photoRequestAlbums() }
    func supportsManagement(_ feature: SynologyPhotosManagementFeature, in space: SynologyPhotoSpace) async -> Bool {
        guard let service = try? service() else { return false }
        return await service.managementFeatures(in: space).contains(feature)
    }

    func managementAlbums() async throws -> [SynologyPhotoCollection] {
        var result: [SynologyPhotoCollection] = []
        var offset = 0
        while true {
            let page = try await service().addableAlbums(offset: offset, limit: 100)
            result.append(contentsOf: page)
            if page.count < 100 { return result }
            offset += page.count
            try Task.checkCancellation()
        }
    }

    func managementFolders(parentID: Int?, in space: SynologyPhotoSpace? = nil) async throws -> (SynologyPhotoCollection, [SynologyPhotoCollection]) {
        let service = try service()
        let destination = space ?? selectedSpace
        let root = try await service.rootFolder(in: destination)
        var children: [SynologyPhotoCollection] = []
        var offset = 0
        while true {
            let page = try await service.folders(in: destination, parentID: parentID ?? root.id, offset: offset, limit: 100)
            children.append(contentsOf: page)
            if page.count < 100 { return (root, children) }
            offset += page.count
            try Task.checkCancellation()
        }
    }

    func prepareSelectedSimilarGroups() async -> [SynologyPhotoSimilarDetail]? {
        guard selectedCategory == .similar, !selectedPhotos.isEmpty, !isManaging, !isDeleting, !isCheckingDeletion, !isPreparingSimilarBatch,
              pendingMutationID == nil, similarBatchQueue.isEmpty, managementFeatures.contains(.similarGroups) else { return nil }
        let photos = selectedPhotos, current = generation
        isPreparingSimilarBatch = true
        defer { isPreparingSimilarBatch = false }
        do {
            var details: [SynologyPhotoSimilarDetail] = []
            for photo in photos {
                let detail = try await service().similarPhotos(for: photo)
                guard current == generation, !Task.isCancelled else { return nil }
                if !details.contains(where: { $0.group == detail.group }) { details.append(detail) }
            }
            return details
        } catch {
            guard current == generation else { return nil }
            managementMessage = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.similar.failed")
            return nil
        }
    }

    func ungroupSimilarSelection(_ details: [SynologyPhotoSimilarDetail]) {
        beginSimilarBatch(details.map { .editSimilarGroup($0, .ungroup) })
    }

    func undoSimilarChanges() { beginSimilarBatch(similarUndoMutations.reversed()) }

    private func beginSimilarBatch(_ commands: [SynologyPhotosMutation]) {
        guard isModuleEnabled, !commands.isEmpty, !isManaging, !isDeleting, !isCheckingDeletion,
              pendingMutationID == nil, similarBatchQueue.isEmpty, commands.allSatisfy(canSubmit) else { return }
        similarBatchOperationIDs = []
        if commands.contains(where: { if case .editSimilarGroup(_, .ungroup) = $0 { return true }; return false }) {
            similarUndoMutations = []; similarUndoPositions = [:]
        }
        similarBatchQueue = commands
        continueSimilarBatch()
    }

    func cancelRemainingSimilarGroups() {
        guard !isManaging else { return }
        similarBatchQueue = []
    }

    /// 一次确认固定所有分组，逐组复用现有操作编号及自动核对；未知项不能重放。
    func continueSimilarBatch() {
        guard isModuleEnabled, !isManaging, !isDeleting, !isCheckingDeletion, pendingMutationID == nil, !similarBatchQueue.isEmpty else { return }
        isManaging = true
        managementTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isManaging = false }
            while let command = self.similarBatchQueue.first, !Task.isCancelled, self.isModuleEnabled {
                let id = UUID()
                self.similarBatchOperationIDs.insert(id)
                self.managementMessage = L10n.string("photos.manage.working")
                do {
                    let result = try await self.executeMutation(command, id: id)
                    if result == nil {
                        // 当前项已由pendingMutation持有；剩余项在核对后继续。
                        self.similarBatchQueue.removeFirst()
                        break
                    }
                    guard result?.state == .confirmed else { break }
                    self.similarBatchQueue.removeFirst()
                } catch {
                    self.managementMessage = operationErrorMessage(error, fallback: "photos.manage.failed")
                    break
                }
            }
        }
    }

    var canRotatePreview: Bool {
        guard let photo = previewPhoto else { return false }
        return photo.supportsRotation && previewData != nil && !isPreparingPreview &&
            canEditPhoto(photo) && managementFeatures.contains(.rotation) &&
            !isManaging && pendingMutationID == nil && !isDeleting && !isCheckingDeletion
    }

    func rotatePreview() {
        guard canRotatePreview, let photo = previewPhoto else { return }
        finishMotion()
        submitMutation(.rotatePhoto(photo))
    }

    func submitMutation(_ mutation: SynologyPhotosMutation, onCompletion: ((SynologyPhotosMutationResult) -> Void)? = nil) {
        if mutation.feature == .backgroundTasks { submitBackgroundTaskMutation(mutation); return }
        guard isModuleEnabled, !isManaging, !isDeleting, !isCheckingDeletion, pendingMutationID == nil, similarBatchQueue.isEmpty,
              canSubmit(mutation) else { return }
        let id = UUID()
        managementCompletion = onCompletion.map { (id, $0) }
        if case .createTemporaryAlbum = mutation { temporaryCreationID = id; cancelledTemporaryCreation = false }
        let isContinuation = retryableManagementMutation == mutation
        retryableManagementMutation = nil
        isManaging = true; managementMessage = L10n.string("photos.manage.working"); managementLink = nil
        if case .regeneratePreviews = mutation { managementMessage = L10n.string("photos.preview.rebuilding") }
        managementTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isManaging = false
                if self.pendingMutationID != id, self.managementCompletion?.id == id { self.managementCompletion = nil }
                if self.pendingMutationID != id, self.temporaryCreationID == id { self.temporaryCreationID = nil; self.cancelledTemporaryCreation = false }
                self.continueTemporarySharingCleanup()
            }
            let file: URL?
            switch mutation {
            case .upload(let url, _, _, _, _, _), .uploadToAlbum(let url, _, _, _, _): file = url
            default: file = nil
            }
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
                self.managementMessage = self.operationErrorMessage(error, fallback: "photos.manage.failed")
            }
        }
    }

    /// 取消意图属于模型，创建窗口关闭后仍可沿原操作编号清理。
    func cancelTemporaryAlbumCreation() {
        guard temporaryCreationID != nil else { return }
        cancelledTemporaryCreation = true
    }

    @discardableResult
    func stopTemporarySharing(_ album: SynologyPhotoCollection, keepCopy: Bool) -> Bool {
        guard isModuleEnabled, temporarySharingCleanup == nil, !isDeleting, !isCheckingDeletion else { return false }
        temporarySharingCleanup = .init(album: album, phase: keepCopy ? .copy : .stop)
        temporarySharingCleanupNeedsRetry = false
        continueTemporarySharingCleanup()
        return true
    }

    func retryTemporarySharingCleanup() {
        temporarySharingCleanupNeedsRetry = false
        continueTemporarySharingCleanup()
    }

    func keepTemporarySharingAlbums() {
        guard temporarySharingCleanupNeedsRetry, !isManaging, pendingMutationID == nil else { return }
        temporarySharingCleanup = nil
        temporarySharingCleanupNeedsRetry = false
        managementMessage = L10n.string("photos.temporary.cleanupCancelled")
        startUploadQueue()
    }

    func continueTemporarySharingCleanup() {
        guard !Task.isCancelled, isModuleEnabled, temporarySharingCleanup != nil,
              !temporarySharingCleanupNeedsRetry, !isManaging, !isDeleting, !isCheckingDeletion,
              pendingMutationID == nil else { return }
        isManaging = true
        managementMessage = L10n.string("photos.temporary.stopping")
        managementTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isManaging = false
                if self.temporarySharingCleanup == nil, !Task.isCancelled { self.startUploadQueue() }
            }
            do {
                while let flow = self.temporarySharingCleanup, !self.temporarySharingCleanupNeedsRetry {
                    try Task.checkCancellation()
                    guard self.isModuleEnabled else { return }
                    let original = try await self.albumSharing(id: flow.album.id)
                    try Task.checkCancellation()
                    guard self.isModuleEnabled, original.isTemporary == true else { throw CocoaError(.fileReadUnknown) }
                    let command: SynologyPhotosMutation
                    switch flow.phase {
                    case .copy:
                        command = .copyTemporaryAlbum(id: flow.album.id, name: flow.album.name, original: original)
                    case .stop:
                        if original.access == .disabled { self.temporarySharingCleanup?.phase = .delete; continue }
                        command = .shareAlbum(id: flow.album.id, access: .disabled, original: original)
                    case .delete:
                        guard original.access == .disabled else { throw CocoaError(.fileReadUnknown) }
                        command = .deleteTemporaryAlbum(id: flow.album.id, original: original, preservedCopyID: flow.preservedCopy?.id)
                    }
                    let result = try await self.executeMutation(command)
                    guard result != nil else { return }
                }
            } catch is CancellationError {
                // 离开照片页暂停，保留阶段；回到页面再继续，已提交操作先核对。
            } catch {
                self.temporarySharingCleanupNeedsRetry = true
                self.managementMessage = operationErrorMessage(error, fallback: "photos.temporary.retryHint")
            }
        }
    }

    private func advanceTemporarySharing(_ mutation: SynologyPhotosMutation, result: SynologyPhotosMutationResult) {
        guard let flow = temporarySharingCleanup else { return }
        let matches: Bool
        switch (flow.phase, mutation) {
        case (.copy, .copyTemporaryAlbum(let id, _, _)): matches = id == flow.album.id
        case (.stop, .shareAlbum(let id, .disabled, _, _, _, _)): matches = id == flow.album.id
        case (.delete, .deleteTemporaryAlbum(let id, _, _)): matches = id == flow.album.id
        default: matches = false
        }
        guard matches else { return }
        guard result.state == .confirmed else {
            temporarySharingCleanupNeedsRetry = true
            managementMessage = L10n.string("photos.temporary.retryHint")
            return
        }
        switch flow.phase {
        case .copy:
            guard let copy = result.album else {
                temporarySharingCleanupNeedsRetry = true
                managementMessage = L10n.string("photos.temporary.retryHint")
                return
            }
            temporarySharingCleanup?.preservedCopy = copy
            temporarySharingCleanup?.phase = .stop
        case .stop: temporarySharingCleanup?.phase = .delete
        case .delete:
            temporarySharingCleanup = nil
            temporarySharingCleanupNeedsRetry = false
            managementMessage = L10n.string(flow.preservedCopy == nil ? "photos.temporary.stopped" : "photos.temporary.kept")
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
            let first: SynologyPhotosMutationResult
            #if os(macOS)
            if pendingUploadID != nil, let store = uploadRecoveryStore {
                try saveUploadQueue()
                first = try await service.performRecoverableUpload(mutation, operationID: id, progress: progress) { checkpoint in
                    try store.checkpoint(checkpoint)
                }
            } else { first = try await service.performMutation(mutation, operationID: id, progress: progress) }
            #else
            first = try await service.performMutation(mutation, operationID: id, progress: progress)
            #endif
            return await finishMutation(first, id: id, mutation: mutation, service: service)
        } catch {
            // Repository 只在提交前抛错；提交后的不确定结果由 pendingReview 返回。
            pendingMutationID = nil; pendingMutation = nil
            throw error
        }
    }

    var canUploadPhotos: Bool {
        if let album = selectedAlbum {
            return album.acceptsManualMembers && selectedAlbumAccess?.albumID == album.id && selectedAlbumAccess?.canContribute == true
        }
        return managementFeatures.contains(.upload)
    }

    func uploadsDirectlyToAlbum(_ album: SynologyPhotoCollection?, space: SynologyPhotoSpace) -> Bool {
        guard let album, selectedAlbumAccess?.albumID == album.id else { return false }
        return selectedAlbumAccess?.isOwner == false || !spaces.contains(space)
    }

    func canDownload(_ photo: SynologyPhoto) -> Bool {
        guard let context = photo.albumContext else { return true }
        guard let rights = selectedAlbumAccess, rights.albumID == context.albumID else { return false }
        return rights.canDownload || (context.providerUserID == rights.currentUserID && spaces.contains(photo.id.space))
    }

    func canModifyOriginal(_ photo: SynologyPhoto) -> Bool {
        guard spaces.contains(photo.id.space) else { return false }
        guard let context = photo.albumContext else { return true }
        guard let rights = selectedAlbumAccess, rights.albumID == context.albumID else { return false }
        if photo.id.space == .personal { return context.ownerUserID == rights.currentUserID }
        return canManageSharedSpace || context.providerUserID == rights.currentUserID
    }

    func canAddOriginalToAlbum(_ photo: SynologyPhoto) -> Bool {
        guard spaces.contains(photo.id.space), canDownload(photo) else { return false }
        if let context = photo.albumContext {
            guard let rights = selectedAlbumAccess, rights.albumID == context.albumID else { return false }
            return rights.currentUserID == context.providerUserID
        }
        return true
    }

    func canAddToAlbum(_ photos: [SynologyPhoto]) -> Bool {
        guard photos.allSatisfy(canAddOriginalToAlbum) else { return false }
        return !photos.contains(where: { $0.albumContext != nil }) || Set(photos.map { $0.id.space }).count < 2 || canManageSharedSpace
    }

    var canRemoveAlbumSelection: Bool {
        canRemoveAlbumPhotos(selectedPhotos)
    }

    func canRemoveAlbumPhotos(_ photos: [SynologyPhoto]) -> Bool {
        guard let rights = selectedAlbumAccess, rights.canContribute, !photos.isEmpty else { return false }
        return rights.isOwner || photos.allSatisfy { $0.albumContext?.albumID == rights.albumID && $0.albumContext?.providerUserID == rights.currentUserID }
    }

    func transferDestinationSpaces(for photos: [SynologyPhoto], copying: Bool, folders: [SynologyPhotoCollection] = []) -> [SynologyPhotoSpace] {
        guard let source = folders.first?.space ?? photos.first?.id.space, photos.allSatisfy({ $0.id.space == source }), folders.allSatisfy({ $0.space == source }), spaces.contains(source) else { return [] }
        return spaces.filter { copying || source == .personal || $0 == source }
    }

    func canTransfer(_ photos: [SynologyPhoto], copying: Bool, folders: [SynologyPhotoCollection] = []) -> Bool {
        guard !transferDestinationSpaces(for: photos, copying: copying, folders: folders).isEmpty else { return false }
        if let first = folders.first {
            guard let parent = first.parentID, parent > 0, Set(folders.map(\.id)).count == folders.count,
                  folders.allSatisfy({ $0.parentID == parent && $0.id != parent && $0.path != nil && $0.path != "/" }),
                  photos.allSatisfy({ $0.folderID == parent && $0.albumContext == nil }) else { return false }
        }
        return photos.allSatisfy { photo in
            if copying, photo.id.space == .shared { return canDownload(photo) }
            return canModifyOriginal(photo)
        }
    }

    func canRegeneratePreviews(_ photos: [SynologyPhoto], fromPreview: Bool = false) -> Bool {
        guard !photos.isEmpty, managementFeatures.contains(.previewRegeneration),
              Set(photos.map { $0.id.space }).count <= 1 || canManageSharedSpace else { return false }
        return photos.allSatisfy { photo in
            guard spaces.contains(photo.id.space) else { return false }
            guard let context = photo.albumContext else { return true }
            guard let rights = selectedAlbumAccess, rights.albumID == context.albumID,
                  selectedAlbum?.id == context.albumID else { return false }
            // 官方冻结相册仍支持多选重建，只在预览窗口省略这个入口。
            if fromPreview, selectedAlbum?.isFrozen == true { return false }
            if context.providerUserID == rights.currentUserID { return true }
            if selectedAlbum?.isConditional == true || selectedAlbum?.isFrozen == true { return canModifyOriginal(photo) }
            return photo.id.space == .shared && canManageSharedSpace
        }
    }

    func canEditSelection(_ photos: [SynologyPhoto], supportsMixedSpaces: Bool) -> Bool {
        guard !photos.isEmpty, photos.allSatisfy(canEditPhoto) else { return false }
        guard Set(photos.map { $0.id.space }).count > 1 else { return true }
        guard supportsMixedSpaces, canManageSharedSpace else { return false }
        if let rights = selectedAlbumAccess, !rights.isOwner {
            return photos.allSatisfy { $0.albumContext?.albumID == rights.albumID && $0.albumContext?.providerUserID == rights.currentUserID }
        }
        return true
    }

    /// 相册编辑按提供者和来源空间管理资格判断，不扩大原件删除或搬移权限。
    func canEditPhoto(_ photo: SynologyPhoto) -> Bool {
        guard spaces.contains(photo.id.space) else { return false }
        guard let context = photo.albumContext else { return canModifyOriginal(photo) }
        guard let rights = selectedAlbumAccess, rights.albumID == context.albumID,
              selectedAlbum?.id == context.albumID else { return false }
        if photo.id.space == .shared { return canManageSharedSpace }
        if context.providerUserID == rights.currentUserID { return true }
        return (selectedAlbum?.isConditional == true || selectedAlbum?.isFrozen == true) && context.ownerUserID == rights.currentUserID
    }

    private func applyRecognitionSettings(original: SynologyPhotoRecognitionSettings, enabled: Set<SynologyPhotoRecognitionSettings.Kind>, service: any SynologyPhotosServing, space: SynologyPhotoSpace = .personal) async {
        guard selectedSpace == space else { return }
        let current = generation
        let features = await service.managementFeatures(in: space)
        guard current == generation, selectedSpace == space else { return }
        managementFeatures = features
        let disabled = Set(original.enabled.subtracting(enabled).map(\.category))
        availableCategories.subtract(disabled)
        guard section == .albums, selectedAlbum == nil else { return }
        let leavesCategory = selectedCategory.map(disabled.contains) == true
        if leavesCategory {
            resetSpaceNavigation(); clearSelection()
            items = []; collections = []; pagedPhotoIDs = []; days = []
            nextOffset = 0; hasMore = false; collectionOffset = 0; hasMoreCollections = true
            timelineBaseQuery = nil; selectedTimelineMonthID = nil; previousMonthID = nil
            query = .recentlyAdded
        }
        do {
            let categories = try await service.categories(in: space)
            guard current == generation, selectedSpace == space, section == .albums else { return }
            availableCategories = categories
            if leavesCategory {
                let albums = try await service.albums(offset: 0, limit: pageSize, display: albumListDisplay, sort: albumListSort)
                guard current == generation, selectedSpace == space, section == .albums else { return }
                collections = albums; collectionOffset = albums.count; hasMoreCollections = albums.count == pageSize
            }
        } catch {
            guard current == generation, selectedSpace == space else { return }
            errorMessage = L10n.string("photos.categories.failed")
        }
    }

    func automaticPreviewSetting() async throws -> Bool { try await service().automaticPreviewEnabled() }
    private func submitBackgroundTaskMutation(_ mutation: SynologyPhotosMutation) {
        guard isModuleEnabled, canSubmit(mutation), !isManagingBackgroundTask, pendingBackgroundMutationID == nil,
              !isDeleting, !isCheckingDeletion else { return }
        let id = UUID()
        isManagingBackgroundTask = true; backgroundTaskMessage = L10n.string("photos.manage.working")
        backgroundControlTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isManagingBackgroundTask = false }
            do {
                let repository = try self.service()
                try await repository.prepareMutation(mutation)
                try Task.checkCancellation()
                guard self.isModuleEnabled else { return }
                self.pendingBackgroundMutationID = id
                let result = try await repository.performMutation(mutation, operationID: id, progress: { _, _ in })
                await self.finishBackgroundMutation(result, id: id, repository: repository)
            } catch {
                self.pendingBackgroundMutationID = nil
                if self.isModuleEnabled && !Task.isCancelled {
                    self.backgroundTaskMessage = operationErrorMessage(error, fallback: "photos.manage.failed")
                }
            }
        }
    }

    func reviewBackgroundMutation() {
        guard isModuleEnabled, !isManagingBackgroundTask, let id = pendingBackgroundMutationID else { return }
        isManagingBackgroundTask = true
        backgroundControlTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isManagingBackgroundTask = false }
            do {
                let repository = try self.service()
                let result = try await repository.reviewMutation(operationID: id)
                await self.finishBackgroundMutation(result, id: id, repository: repository)
            } catch {
                if self.isModuleEnabled { self.backgroundTaskMessage = L10n.string("photos.manage.pending") }
            }
        }
    }

    private func finishBackgroundMutation(_ initial: SynologyPhotosMutationResult, id: UUID, repository: any SynologyPhotosServing) async {
        var result = initial
        for delay in [0.5, 1.0, 2.0, 3.0, 5.0, 8.0] where result.state == .pendingReview {
            do {
                try await deletionReviewDelay(delay)
                try Task.checkCancellation()
                result = try await repository.reviewMutation(operationID: id)
            } catch is CancellationError { break }
            catch { continue }
        }
        guard pendingBackgroundMutationID == id else { return }
        guard isModuleEnabled, !Task.isCancelled, result.state != .pendingReview else {
            backgroundTaskMessage = L10n.string("photos.manage.pending"); return
        }
        pendingBackgroundMutationID = nil
        backgroundTaskRevision += 1
        backgroundTaskMessage = L10n.string(result.state == .confirmed ? "photos.manage.completed" : result.state == .partial ? "photos.manage.partial" : "photos.manage.failed")
        // 取消本App发起的搬移后，沿原操作编号读取终态，不重发搬移。
        if pendingMutation?.feature == .fileTransfer, !isManaging { reviewPendingMutation() }
    }

    func backgroundTasks() async throws -> [SynologyPhotoBackgroundTask] {
        guard isModuleEnabled else { throw CancellationError() }
        let result = try await service().backgroundTasks()
        guard isModuleEnabled, !Task.isCancelled else { throw CancellationError() }
        return result
    }

    func backgroundTaskErrors(_ task: SynologyPhotoBackgroundTask) async throws -> [SynologyPhotoBackgroundTaskError] {
        guard isModuleEnabled else { throw CancellationError() }
        let result = try await service().backgroundTaskErrors(task)
        guard isModuleEnabled, !Task.isCancelled else { throw CancellationError() }
        return result
    }

    @discardableResult
    func openBackgroundTask(_ task: SynologyPhotoBackgroundTask) async -> Bool {
        guard isModuleEnabled, !isLoading, !isDeleting, !isCheckingDeletion, !isBrowsingBlocked,
              !isOpeningBackgroundDestination, let space = task.targetSpace, spaces.contains(space),
              let id = task.targetFolderID, id > 0 else { return false }
        isOpeningBackgroundDestination = true; backgroundNavigationError = nil
        defer { isOpeningBackgroundDestination = false }
        let current = generation
        do {
            let repository = try service()
            guard let latest = try await repository.backgroundTasks().first(where: { $0.id == task.id }),
                  latest.hasSameIdentity(as: task) else { throw CocoaError(.fileReadCorruptFile) }
            let path = try await readableFolderPath(id: id, space: space, repository: repository, generation: current)
            guard current == generation, isModuleEnabled, !Task.isCancelled,
                  !isDeleting, !isCheckingDeletion, !isBrowsingBlocked else { return false }
            resetSpaceNavigation()
            section = .folders; selectedSpace = space; preferredLibrarySpace = space; folderHistory = path
            await refresh(space: space)
            guard generation == current + 1, isModuleEnabled, !Task.isCancelled else { return false }
            guard section == .folders, folderHistory.last == path.last, errorMessage == nil else {
                backgroundNavigationError = errorMessage ?? L10n.string("photos.upload.openFailed"); return false
            }
            return true
        } catch {
            guard current == generation, isModuleEnabled, !Task.isCancelled else { return false }
            backgroundNavigationError = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.upload.openFailed")
            return false
        }
    }

    private func readableFolderPath(id: Int, space: SynologyPhotoSpace, repository: any SynologyPhotosServing, generation current: Int) async throws -> [SynologyPhotoCollection] {
        var path: [SynologyPhotoCollection] = [], visited: Set<Int> = [], folderID = id
        while true {
            guard current == generation, isModuleEnabled, !Task.isCancelled else { throw CancellationError() }
            guard folderID > 0, visited.insert(folderID).inserted else { throw CocoaError(.fileReadCorruptFile) }
            let folder = try await repository.folder(id: folderID, in: space)
            guard folder.id == folderID, folder.space == space else { throw CocoaError(.fileReadCorruptFile) }
            path.insert(folder, at: 0)
            if folder.path == "/" { return path }
            guard let parent = folder.parentID, parent > 0 else { throw CocoaError(.fileReadCorruptFile) }
            folderID = parent
        }
    }

    func codecPrompt() async throws -> SynologyPhotoCodecPrompt { try await service().codecPrompt() }

    func libraryMaintenanceStatus(in space: SynologyPhotoSpace) async throws -> SynologyPhotoLibraryMaintenanceStatus {
        try await service().libraryMaintenanceStatus(in: space)
    }

    func globalSettings() async throws -> SynologyPhotoGlobalSettings { try await service().globalSettings() }
    func conversionCache() async throws -> SynologyPhotoConversionCache { try await service().conversionCache() }
    var automaticMutationReviewID: UUID? {
        guard let mutation = pendingMutation else { return nil }
        switch mutation {
        case .createAlbum, .shareAlbum, .createFolder, .createTemporaryAlbum, .copyTemporaryAlbum, .deleteTemporaryAlbum: return pendingMutationID
        default: break
        }
        guard [.backgroundTasks, .codecPrompt, .folderDeletion, .libraryMaintenance, .globalSettings, .conversionCache, .sharedMembers].contains(mutation.feature) else { return nil }
        return pendingMutationID
    }

    private var pendingManagementMessage: String {
        if case .createFolder = pendingMutation { return L10n.string("photos.folder.creating") }
        if case .createTemporaryAlbum = pendingMutation { return L10n.string("photos.selectionShare.preparing") }
        if temporarySharingCleanup != nil { return L10n.string("photos.temporary.reviewing") }
        if case .createAlbum = pendingMutation { return L10n.string("photos.selectionShare.preparing") }
        if pendingMutation?.feature == .codecPrompt { return L10n.string("photos.codec.pending") }
        if pendingMutation?.feature == .folderDeletion { return L10n.string("photos.selection.reviewContinuing") }
        if pendingMutation?.feature == .libraryMaintenance { return L10n.string("photos.maintenance.pending") }
        if pendingMutation?.feature == .sharedMembers { return L10n.string("photos.members.pending") }
        return L10n.string(automaticMutationReviewID == nil ? "photos.manage.pending" : "photos.global.pending")
    }

    func sharedSpaceMembers() async throws -> SynologyPhotoSharedMembers { try await service().sharedSpaceMembers() }
    func sharedSpaceMemberCandidates() async throws -> [SynologyPhotoShareRecipient] { try await service().sharedSpaceMemberCandidates() }
    func sharedSpaceMemberFolderSnapshot(for member: SynologyPhotoShareRecipient.ID) async throws -> [SynologyPhotoMemberFolder] {
        try await service().sharedSpaceMemberFolderSnapshot(for: member)
    }

    func sharedSpaceSettings() async throws -> SynologyPhotoSharedSpaceSettings { try await service().sharedSpaceSettings() }

    func recognitionSettings() async throws -> SynologyPhotoRecognitionSettings { try await service().recognitionSettings() }

    func displaySettings() async throws -> SynologyPhotoDisplaySettings { try await service().displaySettings() }

    func formattedPhotoDate(_ date: Date, includesTime: Bool = false, group: Bool = false) -> String {
        guard let preferences = displayPreferences else {
            return includesTime ? date.formatted(.dateTime.locale(L10n.locale)) : date.formatted(.dateTime.year().month().day().locale(L10n.locale))
        }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = group && preferences.grouping == .month ? preferences.dateFormat.monthPattern : preferences.dateFormat.pattern
        if includesTime { formatter.dateFormat += preferences.clock == .twelve ? " h:mm a" : " HH:mm" }
        return formatter.string(from: date)
    }

    func duplicateSettings() async throws -> SynologyPhotoDuplicateSettings { try await service().duplicateSettings() }

    private func canSubmit(_ mutation: SynologyPhotosMutation) -> Bool {
        switch mutation {
        case .unfreezeAlbum(let original): return managementFeatures.contains(.frozenAlbums) && original.album.isFrozen
        case .rebuildFrozenAlbum(let original, _, let condition):
            return managementFeatures.contains(.frozenAlbums) && original.album.isFrozen && original.canRebuild && conditionSourceSpaces.contains(condition.sourceSpace)
        case .cancelBackgroundTask(let task): return isModuleEnabled && managementFeatures.contains(.backgroundTasks) && task.canCancel
        case .clearBackgroundTasks(let tasks): return isModuleEnabled && managementFeatures.contains(.backgroundTasks) && !tasks.isEmpty && tasks.allSatisfy(\.canClear)
        case .respondToCodecPrompt(let original, let generate):
            return isModuleEnabled && managementFeatures.contains(.codecPrompt) && original.shouldShow && (!generate || original.canGenerate)
        case .maintainLibrary(let original, let action):
            return isModuleEnabled && selectedSpace == original.space && managementFeatures.contains(.libraryMaintenance) && original.canStart(action)
        case .setAlbumListSort(let scope, _, _): return albumListScope == scope && managementFeatures.contains(.albumListSorting)
        case .setAlbumListDisplay: return albumListScope == .albums && managementFeatures.contains(.albumListDisplay)
        case .setAlbumSort(let id, _, _): return selectedAlbumAccess?.albumID == id && managementFeatures.contains(.albumSorting)
        case .setConceptCover(_, let photo): return canModifyOriginal(photo) && managementFeatures.contains(.conceptCover)
        case .removeConceptItems(_, let photos): return !photos.isEmpty && photos.allSatisfy(canModifyOriginal) && managementFeatures.contains(.conceptItems)
        case .rotatePhoto(let photo): return photo.supportsRotation && canEditPhoto(photo) && managementFeatures.contains(.rotation)
        case .editPhotoFaces(let photo, _): return canEditPhoto(photo) && managementFeatures.contains(.manualFaces)
        case .setAutomaticPreview(let original, let enabled): return isModuleEnabled && original != enabled && managementFeatures.contains(.automaticPreviewSettings)
        case .setGlobalSettings(let original, let enabled, let extensions): return isModuleEnabled && managementFeatures.contains(.globalSettings) && original.canSave(enabled: enabled, excludedExtensions: extensions)
        case .clearConversionCache(let original): return isModuleEnabled && managementFeatures.contains(.conversionCache) && original.canClear
        case .setSharedMembers(let original, let members, let edits):
            return isModuleEnabled && managementFeatures.contains(.sharedMembers) &&
                original.canSave(members, candidates: members.map(\.recipient), allowsUnchanged: !edits.isEmpty) &&
                edits.allSatisfy(\.canSave)
        case .setSharedSpaceSettings(let original, let enabled): return isModuleEnabled && managementFeatures.contains(.sharedSpaceSettings) && original.canSave(enabled)
        case .setSharedSpaceEnabled(let original, let enabled): return isModuleEnabled && managementFeatures.contains(.sharedSpaceSettings) && original.canSetEnabled(enabled)
        case .setRecognitionSettings(let original, let enabled): return isModuleEnabled && managementFeatures.contains(.recognitionSettings) && original.canSave(enabled)
        case .setDisplaySettings: return isModuleEnabled && managementFeatures.contains(.displaySettings)
        case .setDuplicateSettings: return isModuleEnabled && managementFeatures.contains(.duplicateSettings)
        case .setFolderSharing(let original, _, _, _, _):
            return canInspectFolderSharing(original.folder) && !original.inheritsManagementOnly &&
                (selectedSpace != .shared || managementFeatures.contains(.folderSharing))
        case .createTag(_, let photos, _) where photos.isEmpty:
            return spaces.contains(mutation.space) && (mutation.space != selectedSpace || managementFeatures.contains(.tagCreation))
        case .regeneratePreviews(let photos, _): return canRegeneratePreviews(photos)
        case .edit(let photos, _), .shiftDates(let photos, _),
             .addTags(let photos, _), .removeTags(let photos, _), .createTag(_, let photos, _):
            return canEditSelection(photos, supportsMixedSpaces: mutation.supportsMixedPhotoSpaces) &&
                (mutation.space != selectedSpace || managementFeatures.contains(mutation.feature))
        case .addToAlbum(_, let photos), .createAlbum(_, let photos), .createTemporaryAlbum(_, let photos):
            return canAddToAlbum(photos) && spaces.contains(mutation.space) && (mutation.space != selectedSpace || managementFeatures.contains(.albums))
        case .removeFromAlbum(let id, let photos):
            guard let rights = selectedAlbumAccess, rights.albumID == id, rights.canContribute else { return false }
            return rights.isOwner || photos.allSatisfy { $0.albumContext?.albumID == id && $0.albumContext?.providerUserID == rights.currentUserID }
        case .uploadToAlbum(_, _, _, let id, _): return selectedAlbumAccess?.albumID == id && selectedAlbumAccess?.canContribute == true
        case .move(let photos, _, _, let folders, _), .copy(let photos, _, _, let folders, _):
            let copying = if case .copy = mutation { true } else { false }
            return canTransfer(photos, copying: copying, folders: folders) && transferDestinationSpaces(for: photos, copying: copying, folders: folders).contains(mutation.destinationSpace) &&
                (mutation.space != selectedSpace || managementFeatures.contains(.fileTransfer))
        default: return spaces.contains(mutation.space) && (mutation.space != selectedSpace || managementFeatures.contains(mutation.feature))
        }
    }

    #if os(macOS)
    func configureUploadRecovery(_ store: PhotoUploadRecoveryStore?) {
        precondition(!hasLoaded && uploadQueue.isEmpty)
        uploadRecoveryStore = store
        uploadRecoveryReady = store == nil
    }
    #endif

    private func restoreUploadQueueIfNeeded(repository: any SynologyPhotosServing) async {
        #if os(macOS)
        guard !uploadRecoveryReady, let store = uploadRecoveryStore else { return }
        do {
            let identity = try await repository.uploadRecoveryIdentity()
            if let saved = try store.load() {
                guard saved.identity == identity else { throw CocoaError(.fileReadNoPermission) }
                let entries = try saved.entries.map { try $0.restore() }
                if let checkpoint = saved.checkpoint { try await repository.restoreUploadMutation(checkpoint) }
                uploadQueue = entries
                uploadDirectories = Dictionary(uniqueKeysWithValues: saved.directories.map { ($0.key, $0.folder.collection) })
                if let checkpoint = saved.checkpoint, let entryID = saved.pendingEntryID,
                   let row = uploadQueue.firstIndex(where: { $0.id == entryID }) {
                    pendingMutationID = checkpoint.operationID; pendingMutation = try checkpoint.reviewMutation()
                    pendingUploadID = entryID; pendingUploadDirectory = saved.pendingDirectory
                    uploadQueue[row].state = .pendingReview
                    managementMessage = L10n.string("photos.manage.pending")
                }
                stopsAfterCurrentUpload = true
            }
            uploadRecoveryIdentity = identity; uploadRecoveryReady = true; uploadPersistenceError = nil
        } catch { uploadPersistenceError = L10n.string("photos.upload.recovery.readFailed") }
        #endif
    }

    private func saveUploadQueue() throws {
        #if os(macOS)
        guard let store = uploadRecoveryStore else { return }
        guard uploadRecoveryReady, let identity = uploadRecoveryIdentity else { throw CocoaError(.fileReadNoPermission) }
        try store.save(identity: identity, entries: uploadQueue,
            directories: uploadDirectories.map { .init(key: $0.key, folder: .init($0.value)) },
            pendingEntryID: pendingUploadID, pendingDirectory: pendingUploadDirectory,
            pendingOperationID: pendingUploadID == nil ? nil : pendingMutationID)
        #endif
    }

    @discardableResult
    private func persistUploadQueue() -> Bool {
        do { try saveUploadQueue(); uploadPersistenceError = nil; return true }
        catch {
            stopsAfterCurrentUpload = true
            uploadPersistenceError = L10n.string("photos.upload.recovery.saveFailed")
            return false
        }
    }

    var canResumeUploads: Bool {
        uploadRecoveryReady && uploadPersistenceError == nil && !isManaging && pendingMutationID == nil &&
        uploadQueue.contains { [.cancelled, .queued].contains($0.state) && ($0.uploadedPhoto != nil || !$0.file.requiresSourceSelection) }
    }

    func resumeUploads() {
        guard isModuleEnabled, canResumeUploads, !isDeleting, !isCheckingDeletion else { return }
        for row in uploadQueue.indices where [.cancelled, .queued].contains(uploadQueue[row].state) &&
            (uploadQueue[row].uploadedPhoto != nil || !uploadQueue[row].file.requiresSourceSelection) {
            uploadQueue[row].state = .queued; uploadQueue[row].error = nil
        }
        stopsAfterCurrentUpload = false
        if persistUploadQueue() { startUploadQueue() }
    }

    /// 用户在 NAS 核对后只移除本机记录，不把未知结果当成失败，也不重试上传。
    func clearUnresolvedUploadAfterChecking(_ id: UUID) async {
        guard isModuleEnabled, !isManaging, pendingUploadID == id, let operationID = pendingMutationID else { return }
        isManaging = true
        defer { isManaging = false }
        do {
            try await service().forgetUploadMutation(operationID: operationID)
            pendingMutationID = nil; pendingMutation = nil; pendingUploadID = nil; pendingUploadDirectory = nil
            uploadQueue.removeAll { $0.id == id }
            managementMessage = nil; stopsAfterCurrentUpload = true
            pruneUploadDirectories()
        } catch { managementMessage = L10n.string("photos.manage.pending") }
    }

    func retryUploadPersistence() async {
        guard !isManaging else { return }
        if !uploadRecoveryReady {
            if let repository = try? service() { await restoreUploadQueueIfNeeded(repository: repository) }
        } else { persistUploadQueue() }
    }

    func reselectUploadSource(_ id: UUID, url: URL) {
        guard !isManaging, pendingMutationID == nil, let row = uploadQueue.firstIndex(where: { $0.id == id }),
              [.failed, .cancelled].contains(uploadQueue[row].state), uploadQueue[row].uploadedPhoto == nil else { return }
        do {
            let prepared = try PhotoUploadPreparation.prepare([url])
            let old = uploadQueue[row].file
            guard prepared.files.count == 1, var file = prepared.files.first,
                  file.url.lastPathComponent == old.url.lastPathComponent,
                  file.size == old.size, file.modifiedAt == old.modifiedAt else { throw CocoaError(.fileReadCorruptFile) }
            file.id = old.id; file.directoryComponents = old.directoryComponents
            #if os(macOS)
            file.recoveryBookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            #endif
            uploadQueue[row].file = file; uploadQueue[row].error = nil
            persistUploadQueue()
        } catch { uploadQueue[row].error = L10n.string("photos.upload.recovery.sourceChanged") }
    }

    func enqueueUploads(_ files: [PhotoUploadFile], album: SynologyPhotoCollection?, folder: SynologyPhotoCollection?, preserveDirectories: Bool = false, space: SynologyPhotoSpace? = nil, duplicate: SynologyPhotoDuplicateSettings.Upload = .rename) {
        let destination = space ?? selectedSpace
        let direct = uploadsDirectlyToAlbum(album, space: destination)
        let albumAllowed = album.map { $0.acceptsManualMembers && (selectedAlbumAccess?.albumID == $0.id ? selectedAlbumAccess?.canContribute == true : selectedAlbum == nil && managementFeatures.contains(.albums)) } ?? true
        guard isModuleEnabled, uploadRecoveryReady, uploadPersistenceError == nil, !isManaging, !isLoading, !isDeleting, !isCheckingDeletion, pendingMutationID == nil,
              direct || managementFeatures.contains(.upload), !files.isEmpty, albumAllowed,
              !preserveDirectories || (!direct && managementFeatures.contains(.folders)) else { return }
        let batchID = UUID()
        clearSelection()
        uploadQueue.append(contentsOf: files.map {
            var file = $0
            if !preserveDirectories { file.directoryComponents = [] }
            return PhotoUploadEntry(file: file, album: album, folder: folder, space: destination, directAlbumUpload: direct, duplicate: duplicate, batchID: batchID)
        })
        stopsAfterCurrentUpload = false
        guard persistUploadQueue() else { return }
        startUploadQueue()
    }

    func stopUploadQueue() {
        stopsAfterCurrentUpload = true
        for index in uploadQueue.indices where uploadQueue[index].state == .queued {
            uploadQueue[index].state = .cancelled
        }
        persistUploadQueue()
    }

    func retryUpload(_ id: UUID) {
        guard isModuleEnabled, uploadRecoveryReady, uploadPersistenceError == nil, !isManaging, !isDeleting, !isCheckingDeletion, pendingMutationID == nil,
              let index = uploadQueue.firstIndex(where: { $0.id == id }),
              [.failed, .cancelled].contains(uploadQueue[index].state),
              uploadQueue[index].uploadedPhoto != nil || !uploadQueue[index].file.requiresSourceSelection else { return }
        uploadQueue[index].state = .queued; uploadQueue[index].error = nil
        stopsAfterCurrentUpload = false
        guard persistUploadQueue() else { return }
        startUploadQueue()
    }

    func canCancelUpload(_ id: UUID) -> Bool {
        uploadQueue.contains { $0.id == id && $0.state == .queued } && pendingUploadID != id
    }

    func cancelUpload(_ id: UUID) {
        guard canCancelUpload(id), let index = uploadQueue.firstIndex(where: { $0.id == id }) else { return }
        uploadQueue[index].state = .cancelled
        persistUploadQueue()
    }

    func canClearUpload(_ id: UUID) -> Bool {
        uploadQueue.contains { $0.id == id && [.completed, .skipped, .failed, .cancelled].contains($0.state) } && pendingUploadID != id
    }

    /// 仅移除本机任务记录；在途和结果未明的操作必须保留，以便继续核对。
    func clearUpload(_ id: UUID) {
        guard canClearUpload(id) else { return }
        uploadQueue.removeAll { $0.id == id }
        pruneUploadDirectories()
    }

    enum UploadDestination { case folder, album }

    func canOpenUpload(_ id: UUID, destination: UploadDestination) -> Bool {
        guard let entry = uploadQueue.first(where: { $0.id == id }), let photo = entry.uploadedPhoto,
              [.completed, .skipped, .failed, .cancelled].contains(entry.state) else { return false }
        switch destination {
        case .folder: return !entry.directAlbumUpload && photo.albumContext == nil && spaces.contains(photo.id.space)
        case .album: return entry.album != nil && [.completed, .skipped].contains(entry.state)
        }
    }

    @discardableResult
    func openUpload(_ id: UUID, destination: UploadDestination) async -> Bool {
        guard isModuleEnabled, !isLoading, !isDeleting, !isCheckingDeletion, !isBrowsingBlocked,
              !isOpeningUploadDestination, canOpenUpload(id, destination: destination),
              let entry = uploadQueue.first(where: { $0.id == id }) else { return false }
        isOpeningUploadDestination = true; uploadNavigationError = nil
        defer { isOpeningUploadDestination = false }
        let current = generation
        do {
            let repository = try service()
            var path: [SynologyPhotoCollection] = []
            switch destination {
            case .folder:
                guard let uploaded = entry.uploadedPhoto else { return false }
                let photo = try await repository.details(for: uploaded)
                guard photo.id == uploaded.id, photo.albumContext == nil else { throw CocoaError(.fileReadCorruptFile) }
                path = try await readableFolderPath(id: photo.folderID, space: photo.id.space, repository: repository, generation: current)
            case .album:
                guard let album = entry.album else { return false }
                let access = try await repository.albumAccess(id: album.id)
                guard access.albumID == album.id else { throw CocoaError(.fileReadCorruptFile) }
            }
            guard current == generation, isModuleEnabled, !Task.isCancelled,
                  canOpenUpload(id, destination: destination), !isDeleting, !isCheckingDeletion, !isBrowsingBlocked else { return false }
            resetSpaceNavigation()
            switch destination {
            case .folder:
                guard let folder = path.last else { return false }
                section = .folders; selectedSpace = folder.space; preferredLibrarySpace = folder.space
                folderHistory = path
                await refresh(space: folder.space)
            case .album:
                section = .albums; selectedAlbum = entry.album
                await refresh()
            }
            guard generation == current + 1, isModuleEnabled, !Task.isCancelled else { return false }
            let reached: Bool
            switch destination {
            case .folder: reached = section == .folders && folderHistory.last == path.last
            case .album: reached = section == .albums && selectedAlbum?.id == entry.album?.id && selectedAlbumAccess?.albumID == entry.album?.id
            }
            guard reached, errorMessage == nil else {
                uploadNavigationError = errorMessage ?? L10n.string("photos.upload.openFailed")
                return false
            }
            return true
        } catch {
            guard current == generation, isModuleEnabled, !Task.isCancelled else { return false }
            uploadNavigationError = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.upload.openFailed")
            return false
        }
    }

    func clearFinishedUploads() {
        uploadQueue.removeAll { [.completed, .skipped, .cancelled].contains($0.state) }
        pruneUploadDirectories()
    }

    private func pruneUploadDirectories() {
        let batches = Set(uploadQueue.map(\.batchID))
        uploadDirectories = uploadDirectories.filter { batches.contains($0.key.batchID) }
        persistUploadQueue()
    }

    private func startUploadQueue() {
        guard isModuleEnabled, uploadRecoveryReady, uploadPersistenceError == nil, !isManaging, pendingMutationID == nil,
              uploadQueue.contains(where: { $0.state == .queued }) else { return }
        isManaging = true; isUploading = true; managementLink = nil
        managementTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isManaging = false; self.isUploading = false; self.persistUploadQueue() }
            while !Task.isCancelled, self.isModuleEnabled, !self.stopsAfterCurrentUpload,
                  let index = self.uploadQueue.firstIndex(where: { $0.state == .queued }) {
                let entry = self.uploadQueue[index]
                let scoped = entry.file.url.startAccessingSecurityScopedResource()
                defer { if scoped { entry.file.url.stopAccessingSecurityScopedResource() } }
                do {
                    if entry.uploadedPhoto == nil {
                        guard !entry.file.requiresSourceSelection else { throw CocoaError(.fileReadNoPermission) }
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
                        let command: SynologyPhotosMutation
                        if entry.directAlbumUpload, let album = entry.album {
                            command = .uploadToAlbum(file: entry.file.url, size: entry.file.size, modifiedAt: entry.file.modifiedAt, albumID: album.id, duplicate: entry.duplicate)
                        } else { command = .upload(file: entry.file.url, size: entry.file.size, modifiedAt: entry.file.modifiedAt, folderID: destination, space: entry.space, duplicate: entry.duplicate) }
                        let result = try await self.executeMutation(command) { [weak self] done, total in
                            Task { @MainActor in
                                guard let self, let row = self.uploadQueue.firstIndex(where: { $0.id == entry.id }),
                                      self.uploadQueue[row].state == .uploading else { return }
                                self.uploadQueue[row].progress = total.flatMap { $0 > 0 ? min(1, Double(done) / Double($0)) : nil } ?? 0
                            }
                        }
                        guard await self.acceptUploadResult(result, id: entry.id) else { break }
                    }
                    guard let current = self.uploadQueue.firstIndex(where: { $0.id == entry.id }),
                          self.uploadQueue[current].state == .queued,
                          let photo = self.uploadQueue[current].uploadedPhoto, let album = entry.album else { continue }
                    self.uploadQueue[current].state = .addingToAlbum
                    self.pendingUploadID = entry.id
                    let result = try await self.executeMutation(.addToAlbum(id: album.id, photos: [photo]))
                    guard await self.acceptUploadResult(result, id: entry.id) else { break }
                } catch {
                    if let row = self.uploadQueue.firstIndex(where: { $0.id == entry.id }) {
                        if self.pendingMutationID != nil {
                            self.uploadQueue[row].state = .pendingReview
                            self.managementMessage = L10n.string("photos.manage.pending")
                            break
                        }
                        self.uploadQueue[row].state = Task.isCancelled ? .cancelled : .failed
                        self.uploadQueue[row].error = operationErrorMessage(error, fallback: "photos.manage.failed")
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
        else { parent = try await service.rootFolder(in: entry.space) }
        for name in entry.file.directoryComponents {
            try Task.checkCancellation()
            let key = PhotoUploadDirectoryKey(batchID: entry.batchID, parentID: parent.id, name: name)
            if let cached = uploadDirectories[key] { parent = cached; continue }
            let (_, children) = try await managementFolders(parentID: parent.id, in: entry.space)
            let matches = children.filter { $0.name == name && $0.parentID == parent.id }
            guard matches.count <= 1 else { throw CocoaError(.fileReadCorruptFile) }
            if let existing = matches.first { uploadDirectories[key] = existing; parent = existing; continue }
            pendingUploadID = entry.id
            pendingUploadDirectory = key
            let result = try await executeMutation(.createFolder(parentID: parent.id, name: name, space: entry.space))
            guard await acceptUploadResult(result, id: entry.id), let created = uploadDirectories[key] else { return nil }
            parent = created
        }
        return parent.id
    }

    /// 未知结果不重发；上传已确认时保留照片编号，加入相册失败只重试加入步骤。
    @discardableResult
    private func acceptUploadResult(_ result: SynologyPhotosMutationResult?, id: UUID) async -> Bool {
        guard let index = uploadQueue.firstIndex(where: { $0.id == id }) else { return false }
        defer { persistUploadQueue() }
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
            guard result.photos.count == 1, let photo = result.photos.first,
                  (uploadQueue[index].directAlbumUpload ? photo.albumContext?.albumID == uploadQueue[index].album?.id : photo.id.space == uploadQueue[index].space) else {
                uploadQueue[index].state = .failed
                uploadQueue[index].error = L10n.string("photos.service.invalidResponse")
                return true
            }
            uploadQueue[index].ignoredDuplicate = result.skippedCount == 1
            uploadQueue[index].uploadedPhoto = photo
            uploadQueue[index].progress = 1
            uploadQueue[index].state = uploadQueue[index].album == nil || uploadQueue[index].directAlbumUpload ? .completed : .queued
        } else { uploadQueue[index].state = .completed }
        if uploadQueue[index].state == .completed && uploadQueue[index].ignoredDuplicate { uploadQueue[index].state = .skipped }
        if [.completed, .skipped].contains(uploadQueue[index].state), let photo = uploadQueue[index].uploadedPhoto,
           !isLoading, !hasMore, !isFiltering, (photo.id.space == selectedSpace || photo.albumContext?.albumID == selectedAlbum?.id),
           (selectedAlbum?.id == uploadQueue[index].album?.id && selectedAlbum != nil ||
            section == .folders && folderHistory.last != nil && folderHistory.last?.id == photo.folderID),
           !items.contains(where: { $0.id == photo.id }) {
            items.append(photo)
            pagedPhotoIDs.insert(photo.id); nextOffset += 1
            if selectedAlbum != nil, let service = try? service() {
                // 沿当前相册顺序回读已加载范围，不按本地拍摄时间覆盖 NAS 排序。
                await reloadAlbumMembers(service: service)
            } else { items.sort { $0.takenAt < $1.takenAt } }
        }
        return true
    }

    func reviewPendingMutation() {
        if hasPendingAutomaticPreview { Task { await processAutomaticPreview(now: max(Date(), nextAutomaticReviewAt)) }; return }
        guard let id = pendingMutationID, let mutation = pendingMutation, !isManaging, isModuleEnabled else { return }
        isManaging = true
        managementMessage = L10n.string("photos.selection.verifying")
        managementTask = Task { [weak self] in
            guard let self else { return }
            var confirmed = false
            do {
                let service = try self.service()
                let result = try await service.reviewMutation(operationID: id)
                let final = await self.finishMutation(result, id: id, mutation: mutation, service: service)
                confirmed = final?.state == .confirmed
                if let uploadID = self.pendingUploadID { await self.acceptUploadResult(final, id: uploadID) }
            } catch { self.managementMessage = self.pendingManagementMessage }
            self.isManaging = false
            if self.temporarySharingCleanup != nil { self.continueTemporarySharingCleanup(); return }
            if confirmed, self.pendingMutationID == nil, !self.similarBatchQueue.isEmpty { self.continueSimilarBatch(); return }
            if self.stopsAfterCurrentUpload { self.stopUploadQueue() }
            else { self.startUploadQueue() }
        }
    }

    private func applySimilarEdit(_ original: SynologyPhotoSimilarDetail, edit: SynologyPhotoSimilarEdit, result: SynologyPhotosMutationResult, operationID: UUID) {
        let sameGallery = selectedCategory == .similar && selectedSpace == original.group.space
        let oldIndex = sameGallery ? items.firstIndex(where: { $0.id.profileID == original.group.profileID && $0.similarGroup?.id == original.group.id }) : nil
        let members = result.photos.filter { result.similarGroup?.photoIDs.contains($0.id.unitID) == true }
        switch edit {
        case .undo: break
        default:
            if !similarBatchOperationIDs.contains(operationID) { similarUndoMutations = []; similarUndoPositions = [:] }
            similarUndoPositions[original.group] = oldIndex.map { ($0, pagedPhotoIDs.contains(items[$0].id), query) }
        }
        if let index = oldIndex {
            let wasPaged = pagedPhotoIDs.remove(items[index].id) != nil
            if let representative = members.first(where: { $0.id.unitID == result.similarGroup?.topPickID }) {
                items[index] = representative
                if wasPaged { pagedPhotoIDs.insert(representative.id) }
            } else {
                items.remove(at: index)
                if wasPaged { nextOffset = max(0, nextOffset - 1) }
            }
        } else if sameGallery, case .undo = edit, let position = similarUndoPositions[original.group], position.query == query,
                  let representative = members.first(where: { $0.id.unitID == result.similarGroup?.topPickID }) {
            items.insert(representative, at: min(position.index, items.count))
            if position.paged { pagedPhotoIDs.insert(representative.id); nextOffset += 1 }
        }
        if let photo = previewPhoto, original.photos.contains(where: { $0.id == photo.id }) {
            if let group = result.similarGroup, members.count >= 2 {
                let detail = SynologyPhotoSimilarDetail(group: group, photos: members)
                previewSimilarDetail = detail
                similarSelectedIDs.formIntersection(Set(members.map { $0.id }))
                if !members.contains(where: { $0.id == photo.id }), let next = members.first { showPreview(next, similarDetail: detail) }
            } else { previewSimilarDetail = nil; similarSelectedIDs = [] }
        }
        switch edit {
        case .remove, .ungroup: similarUndoMutations.append(.editSimilarGroup(original, .undo(operationID)))
        case .undo(let id):
            similarUndoMutations.removeAll { if case .editSimilarGroup(_, .undo(let saved)) = $0 { return saved == id }; return false }
            similarUndoPositions.removeValue(forKey: original.group)
        case .topPick: similarUndoMutations = []; similarUndoPositions = [:]
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
        guard isModuleEnabled, !Task.isCancelled else { managementMessage = pendingManagementMessage; return nil }
        guard result.state != .pendingReview else { managementMessage = pendingManagementMessage; return nil }
        // 表单内新建相册沿同一操作编号等待核对，未知结果不得同名追认或重复创建。
        defer {
            advanceTemporarySharing(mutation, result: result)
            if let completion = managementCompletion, completion.id == id {
                managementCompletion = nil
                completion.action(result)
            }
        }
        pendingMutationID = nil; pendingMutation = nil
        if case .createTemporaryAlbum = mutation, temporaryCreationID == id {
            if cancelledTemporaryCreation, result.state == .confirmed, let album = result.album {
                temporarySharingCleanup = .init(album: album, phase: .stop)
                temporarySharingCleanupNeedsRetry = false
                managementCompletion = nil
            }
            temporaryCreationID = nil; cancelledTemporaryCreation = false
        }
        managementMessage = L10n.string(result.state == .confirmed ? "photos.manage.completed" : (result.state == .rejected ? "photos.manage.failed" : "photos.manage.partial"))
        managementLink = result.sharingURL
        if case .respondToCodecPrompt(let original, let generate) = mutation {
            if result.state == .confirmed {
                managementMessage = generate ? L10n.string("photos.codec.submitted") : nil
            } else if result.state == .partial, generate {
                managementMessage = L10n.string("photos.codec.partial")
                retryableManagementMutation = .respondToCodecPrompt(original, generate: false)
            }
        }
        if result.state == .partial, case .setFolderSharing = mutation {
            managementMessage = L10n.string("photos.folderSharing.partial")
        }
        if result.state == .confirmed, case .editSimilarGroup(let detail, let edit) = mutation {
            applySimilarEdit(detail, edit: edit, result: result, operationID: id)
        }
        if case .deleteFolderItems(let photos, let folders) = mutation, result.state == .confirmed || result.state == .partial {
            let deleted = Set(result.deletedFolders.filter { folders.contains($0) }.map(\.id))
            for photo in photos where result.deletedPhotoIDs.contains(photo.id) { applyDeletionResult(.confirmed, photo: photo) }
            if selectedSpace == mutation.space {
                selectedFolderIDs.subtract(deleted)
                if section == .folders {
                    if let index = folderHistory.firstIndex(where: { $0.space == mutation.space && deleted.contains($0.id) }) {
                        folderHistory = Array(folderHistory.prefix(index))
                        await refresh(afterFolderMutation: true)
                    } else {
                        let previousCount = collections.count
                        collections.removeAll { $0.space == mutation.space && deleted.contains($0.id) }
                        collectionOffset = max(0, collectionOffset - (previousCount - collections.count))
                    }
                }
            }
        }
        for photo in result.photos {
            if let index = items.firstIndex(where: { $0.id == photo.id }) { items[index] = photo }
            if previewPhoto?.id == photo.id { previewPhoto = photo }
        }
        let reloadsPreview: Bool = switch mutation { case .regeneratePreviews, .rotatePhoto: true; default: false }
        if reloadsPreview, let current = previewPhoto,
           let updated = result.photos.first(where: { $0.id == current.id }) {
            showPreview(updated)
        }
        if result.state == .confirmed, !isUploading,
           case .createFolder(let parentID, _, let space) = mutation,
           section == .folders, selectedSpace == space, !isFiltering,
           case .folder(let currentID, let sort) = query, currentID == parentID {
            // 新目录会改变分页偏移；只重读已展开的目录页，保留照片、选择与当前位置。
            let current = generation
            let limit = max(pageSize, collectionOffset)
            do {
                var children: [SynologyPhotoCollection] = []
                var more = true
                while children.count < limit && more {
                    let page = try await service.folders(in: space, parentID: parentID,
                        offset: children.count, limit: pageSize, direction: sort.direction)
                    guard current == generation, !Task.isCancelled else { return result }
                    children.append(contentsOf: page)
                    more = page.count == pageSize
                }
                collections = children; collectionOffset = children.count; hasMoreCollections = more
            } catch {
                if current == generation {
                    // 创建已确认，列表失败不能提示重新创建，也不能继续沿旧偏移分页。
                    collectionOffset = 0; hasMoreCollections = true
                    managementMessage = L10n.string("photos.folder.createdRefreshFailed")
                }
            }
        }
        if result.state == .confirmed, case .renameFolder(let target, _) = mutation,
           let folder = result.folder, folder.space == target.space, folder.id == target.id,
           selectedSpace == target.space {
            // 核对期间允许进入子目录；同步后代路径但不重新加载或改变所选照片。
            func updated(_ entry: SynologyPhotoCollection) -> SynologyPhotoCollection {
                guard entry.space == target.space else { return entry }
                if entry.id == target.id { return folder }
                guard let oldPath = target.path, let newPath = folder.path, let path = entry.path,
                      path.hasPrefix(oldPath + "/") else { return entry }
                return .init(id: entry.id, name: entry.name, parentID: entry.parentID, itemCount: entry.itemCount,
                    thumbnail: entry.thumbnail, isConditional: entry.isConditional, isFrozen: entry.isFrozen,
                    path: newPath + path.dropFirst(oldPath.count), space: entry.space, sort: entry.sort)
            }
            if section == .folders { collections = collections.map(updated) }
            folderHistory = folderHistory.map(updated)
        }
        if result.state == .confirmed {
            switch mutation {
            case .setAlbumListSort(let scope, _, let sort) where albumListScope == scope:
                albumListSort = sort; await reloadAlbumList(service: service)
            case .setAlbumListDisplay(_, let display) where albumListScope == .albums:
                albumListDisplay = display; await reloadAlbumList(service: service)
            default: break
            }
        }
        if result.state == .confirmed, case .setAlbumSort(let id, _, let sort) = mutation,
           selectedAlbum?.id == id, case .album(let currentID, _) = query, currentID == id {
            await reloadSortedAlbum(id, sort: sort, service: service)
        }
        if result.state == .confirmed, case .setFolderSort(let target, let sort) = mutation {
            if let folder = result.folder, selectedSpace == target.space {
                if section == .folders, let index = collections.firstIndex(where: { $0.id == folder.id && $0.space == folder.space }) { collections[index] = folder }
                if let index = folderHistory.firstIndex(where: { $0.id == folder.id && $0.space == folder.space }) { folderHistory[index] = folder }
            }
            if section == .folders, selectedSpace == target.space, case .folder(let id, _) = query, id == target.id {
                await reloadSortedFolder(target, sort: sort, service: service)
            }
        }
        if result.state == .confirmed, case .setFolderCover(let target, _) = mutation {
            folderCoverRevision += 1
            if let folder = result.folder, selectedSpace == target.space {
                if section == .folders, let index = collections.firstIndex(where: { $0.id == folder.id && $0.space == folder.space }) { collections[index] = folder }
                if let index = folderHistory.firstIndex(where: { $0.id == folder.id && $0.space == folder.space }) { folderHistory[index] = folder }
            }
        }
        if case .unfreezeAlbum(let original) = mutation, result.state == .confirmed,
           selectedAlbum?.id == original.album.id, let album = result.album {
            selectedAlbum = album
            let current = generation
            let rights = try? await service.albumAccess(id: album.id)
            if current == generation, selectedAlbum?.id == album.id { selectedAlbumAccess = rights }
        }
        if case .rebuildFrozenAlbum(let original, _, _) = mutation, let album = result.album {
            if result.state == .partial { managementMessage = L10n.string("photos.frozen.partial") }
            if result.state == .confirmed, section == .albums, selectedCategory == nil {
                let before = collections.count; collections.removeAll { $0.id == original.album.id }
                collectionOffset = max(0, collectionOffset - (before - collections.count))
            }
            if result.state == .confirmed, selectedAlbum?.id == original.album.id {
                selectedAlbum = album
                await refresh(afterFolderMutation: true)
            }
        }
        if let album = result.album {
            let temporary: Bool = switch mutation {
            case .createTemporaryAlbum: true
            case .shareAlbum(_, _, let original, _, _, _): original?.isTemporary == true
            default: false
            }
            if !temporary, section == .albums, selectedCategory == nil, selectedAlbum == nil {
                if let index = collections.firstIndex(where: { $0.id == album.id }) { collections[index] = album }
                else { collections.insert(album, at: 0); collectionOffset += 1 }
            }
            if selectedAlbum?.id == album.id { selectedAlbum = album }
        }
        if let person = result.person, person.space == mutation.space, person.space == selectedSpace {
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
        if selectedCategory == .concept, selectedSpace == mutation.space {
            let visibility = result.conceptVisibility.filter { $0.concept.space == selectedSpace }
            let changed = Set(visibility.map(\.id))
            if !changed.isEmpty {
                if selectedCategoryItem == nil {
                    let oldCount = collections.count
                    collections.removeAll { changed.contains($0.id) }
                    collections.insert(contentsOf: visibility.filter(\.appearsInList).map(\.concept), at: 0)
                    collectionOffset = max(0, collectionOffset + collections.count - oldCount)
                }
                if let updated = visibility.first(where: { $0.id == selectedCategoryItem?.id }) { selectedCategoryItem = updated.concept }
            }
        }
        if case .removeConceptItems(let concept, _) = mutation,
           selectedCategory == .concept, selectedCategoryItem?.id == concept.id, selectedSpace == concept.concept.space {
            let removed = Set(result.removedFromConceptPhotoIDs)
            removeManagedItems(removed)
        }
        let visibility = result.personVisibility.filter { $0.person.space == mutation.space && $0.person.space == selectedSpace }
        if !visibility.isEmpty {
            let changed = Set(visibility.map(\.id))
            let visible = visibility.filter(\.isVisible).map(\.person)
            if selectedCategory == .person {
                let oldCount = collections.count
                collections.removeAll { changed.contains($0.id) }
                collections.insert(contentsOf: visible, at: 0)
                collectionOffset = max(0, collectionOffset + collections.count - oldCount)
            }
            let people = options.people.filter { !changed.contains($0.id) } + visible
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
                case .edit(_, let edit): retryableManagementMutation = .edit(remaining, edit)
                case .regeneratePreviews: retryableManagementMutation = .regeneratePreviews(remaining)
                case .shiftDates(_, let seconds): retryableManagementMutation = .shiftDates(remaining, seconds: seconds)
                case .addToAlbum(let id, _): retryableManagementMutation = .addToAlbum(id: id, photos: remaining)
                case .removeFromAlbum(let id, _):
                    retryableManagementMutation = .removeFromAlbum(id: id, photos: remaining)
                    if selectedAlbum?.id == id { removeManagedItems(completed) }
                case .createTag:
                    if let tag = result.tag { retryableManagementMutation = .addTags(remaining, ids: [tag.id]) }
                default: break
                }
            }
        }
        if let updated = result.globalSettings, case .setGlobalSettings(let original, _, _) = mutation {
            supportsOriginalSizeJPEG = updated.supportsOriginalJPEG
            let space = selectedSpace, before = original.recognition(in: space), after = updated.recognition(in: space)
            await applyRecognitionSettings(original: before, enabled: after.enabled.intersection(after.globallyEnabled), service: service, space: space)
            if result.state == .partial { managementMessage = L10n.string("photos.global.partial") }
        }
        if let updated = result.sharedSpaceSettings, mutation.feature == .sharedMembers {
            await applySharedMemberAccess(updated, service: service)
            if result.state == .partial { managementMessage = L10n.string("photos.members.partial") }
        }
        if case .shareAlbum = mutation, temporarySharingCleanup == nil,
           result.state == .confirmed || result.state == .partial {
            await refreshManagedSharingList(service: service)
        }
        guard result.state == .confirmed else { return result }
        if case .setAutomaticPreview(_, let enabled) = mutation {
            automaticPreviewEnabled = enabled
            automaticPreviewPaused = false
            automaticPreviewError = nil
            if enabled { automaticPreviewFailed = [] }
        }
        if let updated = result.sharedSpaceSettings, mutation.feature == .sharedSpaceSettings {
            if updated.canAccess { if !spaces.contains(.shared) { spaces.append(.shared) } }
            else { spaces.removeAll { $0 == .shared } }
            canManageSharedSpace = updated.canAccess && updated.role == .management
            if selectedSpace == .shared, !updated.canAccess {
                resetSpaceNavigation()
                await refresh(afterFolderMutation: true)
            } else if selectedSpace == .shared {
                let prior: SynologyPhotoSharedSpaceSettings
                switch mutation {
                case .setSharedSpaceSettings(let original, _), .setSharedSpaceEnabled(let original, _): prior = original
                default: return result
                }
                let kinds = SynologyPhotoRecognitionSettings.Kind.allCases
                let previous = SynologyPhotoRecognitionSettings(values: Dictionary(uniqueKeysWithValues: kinds.compactMap { kind in
                    prior.values[.init(rawValue: kind.rawValue)!].map { (kind, $0) }
                }), globallyEnabled: Set(kinds), personalSpaceEnabled: true)
                let enabled = Set(kinds.filter { updated.enabled.contains(.init(rawValue: $0.rawValue)!) })
                await applyRecognitionSettings(original: previous, enabled: enabled, service: service, space: .shared)
            }
        }
        if case .setDisplaySettings(_, let updated) = mutation { displayPreferences = updated }
        if case .setRecognitionSettings(let original, let enabled) = mutation {
            await applyRecognitionSettings(original: original, enabled: enabled, service: service)
        }
        if let request = result.photoRequest, section == .sharing, shareScope == .requests {
            let entry = SynologyPhotoSharedEntry(id: request.id, title: request.settings.subject, url: request.url)
            if let index = sharedEntries.firstIndex(where: { $0.id == request.id }) { sharedEntries[index] = entry }
            else { sharedEntries.insert(entry, at: 0); collectionOffset += 1 }
        }
        switch mutation {
        case .removePersonFaces(let person, _), .reassignPersonFaces(let person, _, _, _):
            if selectedCategory == .person, selectedCategoryItem?.id == person.id, selectedCategoryItem?.space == person.space {
                removeManagedItems(Set(result.removedFromPersonPhotoIDs))
            }
        case .deletePhotoRequest(let request):
            if sharedEntries.contains(where: { $0.id == request.id }) {
                sharedEntries.removeAll { $0.id == request.id }; collectionOffset = max(0, collectionOffset - 1)
            }
        case .deleteTemporaryAlbum(let id, _, _) where result.state == .confirmed:
            if section == .albums, selectedCategory == nil {
                let before = collections.count; collections.removeAll { $0.id == id }
                collectionOffset = max(0, collectionOffset - (before - collections.count))
            }
            if section == .sharing {
                let before = sharedEntries.count; sharedEntries.removeAll { $0.albumID == id }
                collectionOffset = max(0, collectionOffset - (before - sharedEntries.count))
            }
            if selectedAlbum?.id == id { selectedAlbum = nil; await refresh(afterFolderMutation: true) }
            else { await refreshManagedSharingList(service: service) }
        case .deleteAlbum(let id):
            if collections.contains(where: { $0.id == id }) { collections.removeAll { $0.id == id }; collectionOffset = max(0, collectionOffset - 1) }
        case .removeFromAlbum(let id, let photos) where selectedAlbum?.id == id:
            removeManagedItems(Set(photos.map(\.id)))
        case .move(let photos, _, _, let folders, _):
            if !folders.isEmpty {
                // 目录选择只更新原列表；核对期间已进入被移动目录则回到原父目录。
                if selectedSpace == mutation.space, section == .folders {
                    let moved = Set(folders.map(\.id))
                    selectedFolderIDs.subtract(moved)
                    if let index = folderHistory.firstIndex(where: { $0.space == mutation.space && moved.contains($0.id) }) {
                        folderHistory = Array(folderHistory.prefix(index))
                        await refresh(afterFolderMutation: true)
                    } else if folderHistory.last?.id == folders.first?.parentID {
                        let previousCount = collections.count
                        collections.removeAll { $0.space == mutation.space && moved.contains($0.id) }
                        collectionOffset = max(0, collectionOffset - (previousCount - collections.count))
                        removeManagedItems(Set(photos.map(\.id)))
                    }
                }
            } else if mutation.destinationSpace != mutation.space, selectedAlbum != nil,
               items.contains(where: { item in photos.contains { $0.id == item.id } }) {
                // 相册关系可能保留，但原件空间/编号改变；只重读当前已加载成员窗口。
                await reloadAlbumMembers(service: service)
            } else if section == .folders || mutation.destinationSpace != mutation.space {
                removeManagedItems(Set(photos.map(\.id)))
            }
        default: break
        }
        return result
    }

    /// 成员保存返回本人实际权限；不能用被编辑成员的角色推断当前账号权限。
    private func applySharedMemberAccess(_ updated: SynologyPhotoSharedSpaceSettings, service: any SynologyPhotosServing) async {
        if updated.canAccess { if !spaces.contains(.shared) { spaces.append(.shared) } }
        else { spaces.removeAll { $0 == .shared } }
        canManageSharedSpace = updated.canAccess && updated.role == .management
        if selectedSpace == .shared, !canManageSharedSpace {
            // 让权限变化前仍在途的翻页/预加载失效，防止晚到响应重新显示已撤权照片。
            generation += 1
            isLoading = false; isLoadingMore = false; isLoadingPrevious = false
            closePreview()
        }
        let current = generation, space = selectedSpace
        let features = await service.managementFeatures(in: space)
        guard current == generation, selectedSpace == space, !Task.isCancelled else { return }
        managementFeatures = features
        guard space == .shared else { return }
        if !updated.canAccess || (!canManageSharedSpace && selectedCategory != nil) {
            resetSpaceNavigation()
            await refresh(afterFolderMutation: true)
        } else if !canManageSharedSpace {
            // 目录授权可能已经撤回。先清理旧预览，按原查询重读，不把历史月份改成最新。
            closePreview()
            if let album = selectedAlbum {
                items = []; pagedPhotoIDs = []; selectedAlbumAccess = nil
                do {
                    let access = try await service.albumAccess(id: album.id)
                    guard current == generation, selectedAlbum?.id == album.id, !Task.isCancelled else { return }
                    selectedAlbumAccess = access
                    await reloadAlbumMembers(service: service)
                } catch {
                    guard current == generation, !Task.isCancelled else { return }
                    clearSelection(); errorMessage = L10n.string("photos.members.refreshFailed")
                }
            } else if section == .timeline {
                await reloadSharedTimelineAccess(service: service)
            } else {
                await refresh(afterFolderMutation: true)
            }
        }
    }

    private func reloadSharedTimelineAccess(service: any SynologyPhotosServing) async {
        let current = generation, requestedQuery = query, loadedCount = max(nextOffset, pageSize)
        let selection = selectedPhotoIDs
        items = []; pagedPhotoIDs = []; selectedPhotoIDs = []; nextOffset = 0; hasMore = false
        do {
            var refreshed: [SynologyPhoto] = [], ids: Set<SynologyPhotoID> = []
            var offset = 0, more = true
            while more && offset < loadedCount {
                let page = try await service.photos(in: .shared, query: requestedQuery, offset: offset, limit: pageSize)
                guard current == generation, selectedSpace == .shared, query == requestedQuery, !Task.isCancelled else { return }
                guard page.offset == offset, page.nextOffset == offset + page.items.count,
                      page.items.count <= pageSize, !page.hasMore || !page.items.isEmpty,
                      page.items.allSatisfy({ $0.id.space == .shared && ids.insert($0.id).inserted }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                refreshed.append(contentsOf: page.items); offset = page.nextOffset; more = page.hasMore
            }
            items = refreshed; pagedPhotoIDs = ids; nextOffset = offset; hasMore = more
            selectedPhotoIDs = selection.intersection(ids); errorMessage = nil
        } catch {
            guard current == generation, selectedSpace == .shared, !Task.isCancelled else { return }
            errorMessage = L10n.string("photos.members.refreshFailed")
        }
    }

    func retryAlbumRefresh() async {
        guard needsAlbumRefresh, !isManaging, let service = try? service() else { return }
        isManaging = true
        defer { isManaging = false }
        await reloadAlbumMembers(service: service)
    }

    private func reloadAlbumMembers(service: any SynologyPhotosServing) async {
        guard let album = selectedAlbum, case .album(let id, _) = query, id == album.id else { return }
        let current = generation, space = selectedSpace, requestedQuery = query
        let loadedCount = max(nextOffset, pageSize)
        for attempt in 0..<3 {
            do {
                if attempt > 0 { try await deletionReviewDelay(Double(attempt)) }
                try Task.checkCancellation()
                guard current == generation, selectedAlbum?.id == album.id else { return }
                var refreshed: [SynologyPhoto] = [], ids: Set<SynologyPhotoID> = []
                var offset = 0, more = true
                while more && offset < loadedCount {
                    let page = try await service.photos(in: space, query: requestedQuery, offset: offset, limit: pageSize)
                    guard current == generation, selectedAlbum?.id == album.id, !Task.isCancelled else { return }
                    guard page.offset == offset, page.nextOffset == offset + page.items.count,
                          page.items.count <= pageSize, !page.hasMore || !page.items.isEmpty,
                          page.items.allSatisfy({ $0.albumContext?.albumID == album.id && ids.insert($0.id).inserted }) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    refreshed.append(contentsOf: page.items); offset = page.nextOffset; more = page.hasMore
                }
                items = refreshed; pagedPhotoIDs = ids; nextOffset = offset; hasMore = more
                selectedPhotoIDs.formIntersection(ids)
                if let photo = previewPhoto {
                    if let updated = refreshed.first(where: { $0.id == photo.id }) { previewPhoto = updated }
                    else { closePreview() }
                }
                errorMessage = nil; needsAlbumRefresh = false
                return
            } catch is CancellationError { return }
            catch {
                guard current == generation, selectedAlbum?.id == album.id else { return }
                if attempt == 2 {
                    needsAlbumRefresh = true
                    errorMessage = L10n.string("photos.manage.albumRefreshFailed")
                }
            }
        }
    }

    private func removeManagedItems(_ ids: Set<SynologyPhotoID>) {
        nextOffset = max(0, nextOffset - pagedPhotoIDs.intersection(ids).count)
        pagedPhotoIDs.subtract(ids); selectedPhotoIDs.subtract(ids)
        items.removeAll { ids.contains($0.id) }
        if let preview = previewPhoto, ids.contains(preview.id) { closePreview() }
    }

    func saveSelection(to directory: URL, format: SynologyPhotoDownloadFormat = .original) {
        savePhotos(selectedPhotos, to: directory, format: format, includingSimilarMembers: selectedCategory == .similar)
    }

    func canDownloadOriginalSizeJPEG(_ photo: SynologyPhoto) -> Bool {
        supportsOriginalSizeJPEG && photo.supportsOriginalSizeJPEG && canDownload(photo)
    }

    func savePhotos(_ requested: [SynologyPhoto], to directory: URL, format: SynologyPhotoDownloadFormat, includingSimilarMembers: Bool = false) {
        let targets = requested
        guard isModuleEnabled, !isSaving, !targets.isEmpty, targets.allSatisfy(canDownload) else { return }
        if format == .originalSizeJPEG {
            guard !includingSimilarMembers, targets.count == 1, targets.allSatisfy(canDownloadOriginalSizeJPEG) else { return }
        }
        isSaving = true; saveMessage = nil; saveProgress = 0
        saveTask = Task { [weak self] in
            guard let self else { return }
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() }; self.isSaving = false }
            var count = 0, originalCount = 0
            var targets = targets
            do {
                if includingSimilarMembers {
                    var expanded: [SynologyPhoto] = []
                    for representative in targets {
                        try Task.checkCancellation()
                        let detail = try await self.service().similarPhotos(for: representative)
                        for photo in detail.photos where !expanded.contains(where: { $0.id == photo.id }) { expanded.append(photo) }
                    }
                    targets = expanded
                }
                guard targets.allSatisfy(self.canDownload) else { throw CocoaError(.fileReadNoPermission) }
                for photo in targets {
                    try Task.checkCancellation()
                    var name = (photo.filename as NSString).lastPathComponent
                    guard !name.isEmpty, name != ".", name != ".." else { throw CocoaError(.fileWriteInvalidFileName) }
                    let staging = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).photos-save")
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let completed = count, totalCount = targets.count
                    let actualFormat = try await self.service().download(photo, format: format, to: staging) { [weak self] done, total in
                        Task { @MainActor in
                            self?.saveProgress = (Double(completed) + (total.flatMap { $0 > 0 ? Double(done) / Double($0) : nil } ?? 0)) / Double(totalCount)
                        }
                    }
                    try Task.checkCancellation()
                    if actualFormat != .original { name = (name as NSString).deletingPathExtension + ".jpg" }
                    var destination = directory.appendingPathComponent(name)
                    var suffix = 1
                    while FileManager.default.fileExists(atPath: destination.path) {
                        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                        destination = directory.appendingPathComponent("\(base) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")); suffix += 1
                    }
                    try await DownloadedFileExporter.export(from: staging, to: destination, replaceExisting: false)
                    count += 1
                    if format == .optimizedJPEG && actualFormat == .original { originalCount += 1 }
                }
                self.saveMessage = originalCount > 0 ? L10n.string("photos.download.savedWithOriginals", count, originalCount) : L10n.string("photos.manage.savedCount", count)
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

    /// 排序改变时重新分页当前目录，旧页响应不能混入新顺序；不跳回时间线。
    private func reloadSortedFolder(_ folder: SynologyPhotoCollection, sort: SynologyPhotoSort, service: any SynologyPhotosServing) async {
        generation += 1
        let current = generation
        query = .folder(id: folder.id, sort: sort); timelineBaseQuery = query
        items = []; collections = []; pagedPhotoIDs = []; nextOffset = 0; collectionOffset = 0
        hasMore = true; hasMoreCollections = true; isLoading = true; errorMessage = nil
        defer { if current == generation { isLoading = false } }
        do {
            let children = try await service.folders(in: folder.space, parentID: folder.id, offset: 0, limit: pageSize, direction: sort.direction)
            guard current == generation, !Task.isCancelled else { return }
            collections = children; collectionOffset = children.count; hasMoreCollections = children.count == pageSize
            let page = try await service.photos(in: folder.space, query: .folder(id: folder.id, sort: sort), offset: 0, limit: pageSize)
            guard current == generation, !Task.isCancelled else { return }
            try accept(page, requestedOffset: 0)
        } catch { if current == generation { present(error) } }
    }

    private func reloadAlbumList(service: any SynologyPhotosServing) async {
        guard let scope = albumListScope else { return }
        generation += 1
        let current = generation
        collections = []; sharedEntries = []; collectionOffset = 0
        hasMoreCollections = true; isLoading = true; isLoadingMore = false; errorMessage = nil
        defer { if current == generation { isLoading = false } }
        do {
            if scope == .albums {
                let page = try await service.albums(offset: 0, limit: pageSize, display: albumListDisplay, sort: albumListSort)
                guard current == generation, !Task.isCancelled else { return }
                collections = page; collectionOffset = page.count; hasMoreCollections = page.count == pageSize
            } else {
                let page = try await service.sharedEntries(shareScope, offset: 0, limit: pageSize, sort: albumListSort)
                guard current == generation, !Task.isCancelled else { return }
                sharedEntries = page; collectionOffset = page.count; hasMoreCollections = page.count == pageSize
            }
        } catch { if current == generation { present(error) } }
    }

    /// 保留已加载列表直到新分页完整返回；读取失败只能重读，不能再次提交分享修改。
    private func refreshManagedSharingList(service: any SynologyPhotosServing) async {
        guard isModuleEnabled, section == .sharing, shareScope == .withOthers, selectedAlbum == nil else { return }
        let current = generation, sort = albumListSort, count = max(pageSize, collectionOffset)
        isLoadingMore = true
        defer { if current == generation { isLoadingMore = false } }
        do {
            var entries: [SynologyPhotoSharedEntry] = []
            var more = true
            while entries.count < count && more {
                let page = try await service.sharedEntries(.withOthers, offset: entries.count, limit: pageSize, sort: sort)
                guard current == generation, !Task.isCancelled else { return }
                let seen = Set(entries.map(\.id))
                guard page.allSatisfy({ !seen.contains($0.id) }) else { throw CocoaError(.fileReadCorruptFile) }
                entries.append(contentsOf: page); more = page.count == pageSize
            }
            sharedEntries = entries; collectionOffset = entries.count; hasMoreCollections = more
            if needsSharedListRefresh { managementMessage = L10n.string("photos.sharing.listUpdated") }
            needsSharedListRefresh = false; errorMessage = nil
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            needsSharedListRefresh = true; hasMoreCollections = false
            managementMessage = L10n.string("photos.sharing.savedRefreshFailed")
        }
    }

    private func reloadSortedAlbum(_ id: Int, sort: SynologyPhotoSort, service: any SynologyPhotosServing) async {
        generation += 1
        let current = generation
        query = .album(id: id, sort: sort); timelineBaseQuery = query
        items = []; pagedPhotoIDs = []; nextOffset = 0
        hasMore = true; isLoading = true; errorMessage = nil
        defer { if current == generation { isLoading = false } }
        do {
            let page = try await service.photos(in: selectedSpace, query: query, offset: 0, limit: pageSize)
            guard current == generation, !Task.isCancelled else { return }
            try accept(page, requestedOffset: 0)
        } catch { if current == generation { present(error) } }
    }

    private func accept(_ page: SynologyPhotoPage, requestedOffset: Int) throws {
        let albumID: Int? = if case .album(let id, _) = query { id } else { nil }
        guard page.offset == requestedOffset,
              page.nextOffset == requestedOffset + page.items.count,
              page.items.allSatisfy({ photo in
                  if let context = photo.albumContext {
                      return context.albumID == albumID && context.ownerUserID >= 0 &&
                          photo.id.space == (context.ownerUserID == 0 ? .shared : .personal)
                  }
                  return albumID != nil ? spaces.contains(photo.id.space) : photo.id.space == selectedSpace
              }),
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

    /// 通用解析错误不能让保存或预览失败被误报为整个照片库无法加载。
    private func operationErrorMessage(_ error: Error, fallback: String) -> String {
        guard let error = error as? AppError, error.category != .invalidResponse else { return L10n.string(fallback) }
        return error.safeUserMessage
    }

    private(set) var selectedFolderIDs: Set<Int> = []
    var selectedFolders: [SynologyPhotoCollection] {
        section == .folders ? collections.filter { $0.space == selectedSpace && selectedFolderIDs.contains($0.id) } : []
    }
    var selectedItemCount: Int { selectedPhotoIDs.count + selectedFolderIDs.count }

    func toggleFolderSelection(_ folder: SynologyPhotoCollection) {
        guard section == .folders, !isDeleting, !isManaging, collections.contains(folder), folder.space == selectedSpace else { return }
        isSelecting = true
        if !selectedFolderIDs.insert(folder.id).inserted { selectedFolderIDs.remove(folder.id) }
    }

    func selectLoadedItems() {
        guard !isDeleting, !isManaging else { return }
        guard section == .folders else { selectGroup(items); return }
        let photoIDs = Set(items.map(\.id)), folderIDs = Set(collections.map(\.id))
        isSelecting = true
        if photoIDs.isSubset(of: selectedPhotoIDs), folderIDs.isSubset(of: selectedFolderIDs) {
            selectedPhotoIDs.subtract(photoIDs); selectedFolderIDs.subtract(folderIDs)
        } else {
            selectedPhotoIDs.formUnion(photoIDs); selectedFolderIDs.formUnion(folderIDs)
        }
    }

    var selectedPhotos: [SynologyPhoto] { items.filter { selectedPhotoIDs.contains($0.id) } }
    var canDeleteSelection: Bool {
        selectedItemCount > 0 && (selectedFolderIDs.isEmpty || managementFeatures.contains(.folderDeletion)) && selectedPhotos.allSatisfy(canModifyOriginal) && !isDeleting && !isCheckingDeletion && !isManaging && pendingMutationID == nil && pendingDeletionPhotos.isEmpty
    }

    func toggleSelection(_ photo: SynologyPhoto, extending: Bool = false) {
        guard !isDeleting, !isBrowsingBlocked, items.contains(where: { $0.id == photo.id }) else { return }
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
        guard !isDeleting, !isBrowsingBlocked else { return }
        let ids = Set(photos.map(\.id)).intersection(Set(items.map(\.id)))
        isSelecting = true
        if ids.isSubset(of: selectedPhotoIDs) { selectedPhotoIDs.subtract(ids) }
        else { selectedPhotoIDs.formUnion(ids) }
    }

    func clearSelection() {
        selectedPhotoIDs = []; selectedFolderIDs = []; selectionAnchorID = nil; isSelecting = false
    }

    func requestDeletion(_ photo: SynologyPhoto) { requestDeletion([photo]) }

    func requestSimilarCleanup(_ detail: SynologyPhotoSimilarDetail, keeping ids: Set<SynologyPhotoID>) {
        let members = Set(detail.photos.map { $0.id })
        guard !ids.isEmpty, ids.isSubset(of: members), ids.count < members.count else { return }
        requestDeletion(detail.photos.filter { !ids.contains($0.id) }, verifying: detail)
    }

    func requestDeletion(_ photos: [SynologyPhoto], verifying similar: SynologyPhotoSimilarDetail? = nil) {
        guard isModuleEnabled, !photos.isEmpty, photos.allSatisfy(canModifyOriginal), !isDeleting, !isManaging, !isCheckingDeletion,
              pendingMutationID == nil, pendingDeletionPhotos.isEmpty else { return }
        let targets = photos.reduce(into: [SynologyPhoto]()) { result, photo in
            if !result.contains(where: { $0.id == photo.id }) { result.append(photo) }
        }
        let current = generation
        isCheckingDeletion = true
        deletionError = nil; deletionKeptCount = nil
        Task {
            defer { isCheckingDeletion = false }
            do {
                if let similar {
                    guard let fresh = try await service().similarGroupDetails(similar.group), fresh.group == similar.group,
                          fresh.photos.count == similar.photos.count,
                          fresh.photos.allSatisfy({ current in similar.photos.contains { original in
                              current.id == original.id && current.filename == original.filename && current.sizeBytes == original.sizeBytes &&
                              current.folderID == original.folderID && current.indexedAt == original.indexedAt && current.mediaType == original.mediaType
                          } }) else { throw CapabilitySelectionError.unsupported(apiName: "Photos.SimilarChanged") }
                }
                for photo in targets {
                    try await service().prepareDeletion(photo)
                    guard isModuleEnabled, current == generation else { return }
                }
                preparedDeletionPhotos = targets
                deletionCandidates = targets
                deletionKeptCount = similar.map { $0.photos.count - targets.count }
                if similar != nil { closePreview() }
            } catch {
                guard isModuleEnabled, current == generation else { return }
                if similar != nil { similarPreviewError = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.similar.changed") }
                else { deletionError = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.delete.unverified") }
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
        if selectedCategory == .similar {
            for photo in photos {
                guard let group = photo.similarGroup,
                      let index = items.firstIndex(where: { $0.id.profileID == group.profileID && $0.id.space == group.space && $0.similarGroup?.id == group.id }) else { continue }
                similarRefreshes[group] = (query, index, pagedPhotoIDs.contains(items[index].id))
            }
        }
        deletionCandidates = []; preparedDeletionPhotos = []; deletionKeptCount = nil
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
            await refreshAffectedSimilarGroups()
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
            completed += await readPendingDeletionResults()
        }
        if !pendingDeletionPhotos.isEmpty {
            #if os(macOS)
            deletionMessage = L10n.string("photos.selection.reviewContinuing")
            #else
            deletionMessage = L10n.string("photos.selection.reviewDelayed")
            #endif
        }
        return completed
    }

    /// 由图库视图生命周期驱动；长断线后仍只回读结果，不重新提交删除。
    func continueAutomaticDeletionReview() async {
        let epoch = deletionReviewEpoch
        while hasAutomaticDeletionReview, !Task.isCancelled, epoch == deletionReviewEpoch {
            do { try await deletionReviewDelay(15) } catch { return }
            await Task.yield()
            guard hasAutomaticDeletionReview, !Task.isCancelled, epoch == deletionReviewEpoch else { return }
            guard !isDeleting, !isManaging, !isCheckingDeletion else { continue }
            let completed = await readPendingDeletionResults()
            guard isModuleEnabled, !Task.isCancelled, epoch == deletionReviewEpoch else { return }
            if pendingDeletionPhotos.isEmpty, completed > 0 {
                deletionMessage = L10n.string("photos.selection.deleted", completed)
            } else if !pendingDeletionPhotos.isEmpty {
                deletionMessage = L10n.string("photos.selection.reviewContinuing")
            }
            await refreshAffectedSimilarGroups()
        }
    }

    private func readPendingDeletionResults() async -> Int {
        guard !isReadingDeletionResults else { return 0 }
        isReadingDeletionResults = true
        defer { isReadingDeletionResults = false }
        let epoch = deletionReviewEpoch
        var completed = 0
        for photo in pendingDeletionPhotos {
            guard !Task.isCancelled, isModuleEnabled, epoch == deletionReviewEpoch else { break }
            do {
                let result = try await service().reviewDeletion(photo)
                guard !Task.isCancelled, isModuleEnabled, epoch == deletionReviewEpoch else { break }
                applyDeletionResult(result, photo: photo)
                if result == .confirmed { completed += 1 }
            } catch { /* 连接恢复后继续只读核对，保留原目标。 */ }
        }
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
        await refreshAffectedSimilarGroups()
    }

    /// 删除结果与分组刷新分开：这里只回读，失败不能重新删除或刷新整本图库。
    func refreshAffectedSimilarGroups() async {
        similarRefreshError = nil
        let current = generation
        for (group, position) in similarRefreshes.sorted(by: { $0.value.index < $1.value.index }) {
            guard !pendingDeletionPhotos.contains(where: { $0.id.profileID == group.profileID && $0.id.space == group.space && group.photoIDs.contains($0.id.unitID) }) else { continue }
            guard selectedCategory == .similar, selectedSpace == group.space, query == position.query else {
                similarRefreshes.removeValue(forKey: group); continue
            }
            for attempt in 0..<3 {
                do {
                    if attempt > 0 { try await deletionReviewDelay(Double(attempt)) }
                    let fresh = try await service().similarGroupDetails(group)
                    guard current == generation, !Task.isCancelled else { return }
                    if let fresh {
                        guard fresh.group.profileID == group.profileID, fresh.group.space == group.space, fresh.group.id == group.id,
                              fresh.photos.count == fresh.group.photoIDs.count,
                              Set(fresh.photos.map { $0.id.unitID }) == Set(fresh.group.photoIDs),
                              fresh.photos.allSatisfy({ $0.id.profileID == group.profileID && $0.id.space == group.space && !confirmedDeletedIDs.contains($0.id) }) else { throw CapabilitySelectionError.unsupported(apiName: "Photos.SimilarStale") }
                    }
                    let existing = items.firstIndex { $0.id.profileID == group.profileID && $0.id.space == group.space && $0.similarGroup?.id == group.id }
                    let replacement = fresh?.photos.first { $0.id.unitID == fresh?.group.topPickID }
                    if let index = existing {
                        let oldID = items[index].id
                        let wasPaged = pagedPhotoIDs.remove(oldID) != nil
                        selectedPhotoIDs.remove(oldID)
                        if let replacement {
                            items[index] = replacement
                            if wasPaged { pagedPhotoIDs.insert(replacement.id) }
                        } else {
                            items.remove(at: index)
                            if wasPaged { nextOffset = max(0, nextOffset - 1) }
                        }
                    } else if let replacement {
                        items.insert(replacement, at: min(position.index, items.count))
                        if position.paged { pagedPhotoIDs.insert(replacement.id); nextOffset += 1 }
                    }
                    similarUndoMutations = []; similarUndoPositions = [:]
                    similarRefreshes.removeValue(forKey: group)
                    break
                } catch is CancellationError { return }
                catch {
                    guard current == generation, !Task.isCancelled else { return }
                    if attempt == 2 { similarRefreshError = L10n.string("photos.similar.refreshFailed") }
                }
            }
        }
    }

    private func applyDeletionResult(_ result: SynologyPhotoDeletionResult, photo: SynologyPhoto) {
        switch result {
        case .confirmed:
            guard confirmedDeletedIDs.insert(photo.id).inserted else { return }
            // 只有属于向下分页窗口的项目才影响该窗口的 offset；向上补入项目另有时间区间。
            if pagedPhotoIDs.remove(photo.id) != nil {
                nextOffset = max(0, nextOffset - 1)
                // 删除确认可能晚于滚动分页发出；旧偏移响应不能覆盖已经修正的窗口。
                if isLoadingMore || isLoadingPrevious {
                    generation += 1
                    isLoadingMore = false; isLoadingPrevious = false
                }
            }
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

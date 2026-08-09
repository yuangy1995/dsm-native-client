import DsmCore
import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoTimelineModel {
    private(set) var activeProfileID: UUID?
    private(set) var profiles: [UUID: MobilePhotoTimelineState] = [:]
    private(set) var visibleItems: [PhotoLibraryItem] = []
    private(set) var visibleMonths: [MobilePhotoTimelineMonth] = []

    @ObservationIgnored private let thumbnailStore: MobilePhotoThumbnailStore
    @ObservationIgnored private var repository: (any PhotoLibraryRepository)?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTasks: [UUID: Task<Data?, Never>] = [:]
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var scanBaselines: [UUID: MobilePhotoTimelineState] = [:]
    @ObservationIgnored private var workingItems: [UUID: [String: PhotoLibraryItem]] = [:]
    @ObservationIgnored private var generation = 0

    init(thumbnailStore: MobilePhotoThumbnailStore = MobilePhotoThumbnailStore()) {
        self.thumbnailStore = thumbnailStore
    }

    deinit {
        scanTask?.cancel()
        queryTask?.cancel()
        thumbnailTasks.values.forEach { $0.cancel() }
    }

    var state: MobilePhotoTimelineState {
        guard let activeProfileID else { return MobilePhotoTimelineState() }
        return profiles[activeProfileID] ?? MobilePhotoTimelineState()
    }

    func activate(
        profileID: UUID?,
        repository: (any PhotoLibraryRepository)?,
        repositoryProfileID: UUID?
    ) {
        cancelAllWork()
        self.repository = repository
        activeProfileID = profileID
        guard let profileID,
              repository != nil,
              repositoryProfileID == profileID else {
            self.repository = nil
            activeProfileID = nil
            return
        }
        if profiles[profileID] == nil {
            profiles[profileID] = MobilePhotoTimelineState()
        }
        rebuildVisibleContent()
    }

    func show(space: PhotoSpace?) async {
        guard let profileID = activeProfileID else { return }
        if state.space?.kind != space?.kind {
            scanTask?.cancel()
            generation &+= 1
            profiles[profileID] = MobilePhotoTimelineState(space: space)
            rebuildVisibleContent()
        }
        guard space != nil, !state.hasCompletedScan, !state.isScanning else { return }
        await scan()
    }

    func refresh() async {
        await scan()
    }

    func cancel() {
        guard state.isScanning else { return }
        let profileID = activeProfileID
        scanTask?.cancel()
        scanTask = nil
        generation &+= 1
        if let profileID { restoreBaseline(profileID: profileID, failed: false) }
    }

    func setQuery(_ value: String) {
        updateActive { $0.query = value }
        queryTask?.cancel()
        guard let profileID = activeProfileID else { return }
        let requestedQuery = value
        queryTask = Task { @MainActor [unowned self] in
            if !requestedQuery.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled,
                  activeProfileID == profileID,
                  state.query == requestedQuery else { return }
            updateActive { $0.appliedQuery = requestedQuery }
            rebuildVisibleContent()
        }
    }

    func setFilter(_ value: PhotoMediaFilter) {
        updateActive { $0.filter = value }
        rebuildVisibleContent()
    }

    func thumbnailData(for item: PhotoLibraryItem) async -> Data? {
        guard item.kind == .image,
              let profileID = activeProfileID,
              item.profileID == profileID,
              let canonical = state.items.first(where: {
                  $0.id == item.id && $0.path == item.path && $0.kind == item.kind && $0.profileID == item.profileID
              }),
              let repository else { return nil }
        let requestGeneration = generation
        let token = UUID()
        let store = thumbnailStore
        let key = "\(profileID.uuidString)|\(canonical.path)|\(canonical.modifiedAt?.timeIntervalSince1970 ?? 0)|\(canonical.sizeBytes ?? -1)"
        let task = Task<Data?, Never> {
            await store.data(for: key, namespace: profileID.uuidString, priority: .visible) {
                try await repository.getThumbnail(for: canonical, size: .small)
            }
        }
        thumbnailTasks[token] = task
        let data = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        thumbnailTasks[token] = nil
        guard activeProfileID == profileID,
              generation == requestGeneration,
              state.items.contains(canonical) else { return nil }
        return data
    }

    func cancelAllWork() {
        let profileID = activeProfileID
        if profileID != nil, state.query != state.appliedQuery {
            updateActive { $0.appliedQuery = $0.query }
        }
        scanTask?.cancel()
        scanTask = nil
        queryTask?.cancel()
        queryTask = nil
        for task in thumbnailTasks.values { task.cancel() }
        thumbnailTasks.removeAll()
        generation &+= 1
        if let profileID, state.isScanning { restoreBaseline(profileID: profileID, failed: false) }
        rebuildVisibleContent()
    }

    private func scan() async {
        guard let profileID = activeProfileID,
              let repository,
              let space = state.space,
              !state.isScanning else { return }
        scanTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        scanBaselines[profileID] = state
        workingItems[profileID] = [:]
        updateActive { $0.phase = .scanning }
        updateActive { $0.refreshFailed = false }

        let reference = MobilePhotoTimelineModelReference(self)
        let task = Task { @MainActor in
            do {
                let result = try await repository.scanTimeline(
                    in: space,
                    startingAt: [space.rootPath],
                    existingFolderItemPaths: [:],
                    limits: .mobileDefault
                ) { update in
                    await reference.value?.apply(
                        update,
                        profileID: profileID,
                        space: space,
                        generation: requestGeneration
                    )
                }
                try Task.checkCancellation()
                reference.value?.apply(result, profileID: profileID, space: space, generation: requestGeneration)
            } catch is CancellationError {
                reference.value?.finishCancellation(profileID: profileID, generation: requestGeneration)
            } catch {
                reference.value?.finishFailure(profileID: profileID, generation: requestGeneration)
            }
        }
        scanTask = task
        await task.value
        if generation == requestGeneration { scanTask = nil }
    }

    private func apply(
        _ update: PhotoTimelineScanUpdate,
        profileID: UUID,
        space: PhotoSpace,
        generation requestGeneration: Int
    ) {
        guard isCurrent(profileID: profileID, space: space, generation: requestGeneration),
              update.items.allSatisfy({ $0.profileID == profileID && !$0.isFolder }) else { return }
        var byPath = workingItems[profileID] ?? [:]
        update.removedPaths.forEach { byPath[$0] = nil }
        update.items.forEach { byPath[$0.path] = $0 }
        workingItems[profileID] = byPath
        updateActive { profile in
            profile.items = MobilePhotoTimelineState.sorted(Array(byPath.values))
            profile.scannedFolderCount = update.scannedFolderCount
            profile.skippedFolderPaths = update.skippedFolderPaths
        }
        rebuildVisibleContent()
    }

    private func apply(
        _ result: PhotoTimelineScanResult,
        profileID: UUID,
        space: PhotoSpace,
        generation requestGeneration: Int
    ) {
        guard isCurrent(profileID: profileID, space: space, generation: requestGeneration),
              result.items.allSatisfy({ $0.profileID == profileID && !$0.isFolder }) else {
            finishFailure(profileID: profileID, generation: requestGeneration)
            return
        }
        updateActive { profile in
            profile.items = MobilePhotoTimelineState.sorted(result.items)
            profile.scannedFolderCount = result.scannedFolderCount
            profile.sourceItemCount = result.sourceItemCount
            profile.skippedFolderPaths = result.skippedFolderPaths
            profile.completion = result.completion
            profile.hasCompletedScan = true
            profile.phase = result.items.isEmpty ? .empty : .content
            profile.refreshFailed = false
        }
        rebuildVisibleContent()
        scanBaselines[profileID] = nil
        workingItems[profileID] = nil
    }

    private func finishCancellation(profileID: UUID, generation requestGeneration: Int) {
        guard activeProfileID == profileID, generation == requestGeneration else { return }
        restoreBaseline(profileID: profileID, failed: false)
    }

    private func finishFailure(profileID: UUID, generation requestGeneration: Int) {
        guard activeProfileID == profileID, generation == requestGeneration else { return }
        restoreBaseline(profileID: profileID, failed: true)
    }

    private func isCurrent(profileID: UUID, space: PhotoSpace, generation requestGeneration: Int) -> Bool {
        activeProfileID == profileID && state.space?.kind == space.kind && generation == requestGeneration
    }

    private func updateActive(_ body: (inout MobilePhotoTimelineState) -> Void) {
        guard let activeProfileID else { return }
        var profile = profiles[activeProfileID] ?? MobilePhotoTimelineState()
        body(&profile)
        profiles[activeProfileID] = profile
    }

    private func restoreBaseline(profileID: UUID, failed: Bool) {
        let current = profiles[profileID]
        var restored = scanBaselines.removeValue(forKey: profileID) ?? profiles[profileID] ?? MobilePhotoTimelineState()
        workingItems[profileID] = nil
        restored.query = current?.query ?? restored.query
        restored.appliedQuery = current?.appliedQuery ?? restored.appliedQuery
        restored.filter = current?.filter ?? restored.filter
        if restored.hasCompletedScan {
            restored.phase = restored.items.isEmpty ? .empty : .content
        } else {
            restored.phase = failed ? .error : .idle
        }
        profiles[profileID] = restored
        if failed, restored.hasCompletedScan {
            profiles[profileID]?.refreshFailed = true
        }
        rebuildVisibleContent()
    }

    private func rebuildVisibleContent() {
        visibleItems = state.filteredItems
        let calendar = Calendar.autoupdatingCurrent
        let grouped = Dictionary(grouping: visibleItems) { item -> Date? in
            guard let date = item.createdAt ?? item.modifiedAt else { return nil }
            return calendar.date(from: calendar.dateComponents([.year, .month], from: date))
        }
        visibleMonths = grouped.map {
            MobilePhotoTimelineMonth(monthStart: $0.key, items: MobilePhotoTimelineState.sorted($0.value))
        }
        .sorted { lhs, rhs in
            switch (lhs.monthStart, rhs.monthStart) {
            case let (left?, right?): left > right
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): false
            }
        }
    }
}

@MainActor
private final class MobilePhotoTimelineModelReference {
    weak var value: MobilePhotoTimelineModel?

    init(_ value: MobilePhotoTimelineModel) {
        self.value = value
    }
}

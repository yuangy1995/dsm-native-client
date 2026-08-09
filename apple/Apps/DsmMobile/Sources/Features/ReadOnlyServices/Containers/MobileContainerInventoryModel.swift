import Foundation
import Observation

@MainActor
@Observable
final class MobileContainerInventoryModel {
    static let defaultCacheLimit = 4

    private(set) var activeProfileID: UUID?
    private(set) var profiles: [UUID: MobileContainerInventoryState] = [:]

    @ObservationIgnored private var repository: (any MobileContainerInventoryReading)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cacheOrder: [UUID] = []
    @ObservationIgnored private let cacheLimit: Int

    init(cacheLimit: Int = defaultCacheLimit) {
        self.cacheLimit = max(1, cacheLimit)
    }

    var state: MobileContainerInventoryState {
        guard let activeProfileID else { return MobileContainerInventoryState() }
        return profiles[activeProfileID] ?? MobileContainerInventoryState()
    }

    func activate(
        profileID: UUID?,
        repository: (any MobileContainerInventoryReading)?
    ) async {
        cancelRefresh()
        guard let profileID, let repository, repository.profileID == profileID else {
            self.repository = nil
            activeProfileID = nil
            return
        }
        activeProfileID = profileID
        self.repository = repository
        if profiles[profileID] == nil {
            profiles[profileID] = MobileContainerInventoryState()
            touchCache(profileID)
            await refresh()
        } else {
            touchCache(profileID)
        }
    }

    func refresh() async {
        guard let profileID = activeProfileID,
              let repository,
              repository.profileID == profileID else { return }
        cancelRefresh()
        generation &+= 1
        let requestGeneration = generation
        let preservesContent = state.hasLoadedOnce
        update(profileID) {
            $0.isRefreshing = preservesContent
            $0.hasRefreshError = false
            if !preservesContent { $0.pageState = .loading }
        }

        let task = Task { [weak self, repository] in
            do {
                let snapshot = try await repository.loadInventory()
                try Task.checkCancellation()
                self?.finish(
                    snapshot.containers.map(MobileContainerItem.init),
                    profileID: profileID,
                    generation: requestGeneration
                )
            } catch is CancellationError {
                self?.finishCancellation(profileID: profileID, generation: requestGeneration)
            } catch {
                self?.finishFailure(
                    preservesContent: preservesContent,
                    profileID: profileID,
                    generation: requestGeneration
                )
            }
        }
        refreshTask = task
        await task.value
    }

    func setFilter(_ filter: MobileContainerFilter) {
        guard let profileID = activeProfileID else { return }
        update(profileID) {
            $0.filter = filter
            Self.applyFilter(to: &$0)
            if let selectedID = $0.selectedID,
               !$0.visibleItems.contains(where: { $0.id == selectedID }) {
                $0.selectedID = nil
            }
        }
    }

    func select(_ id: String?) {
        guard let profileID = activeProfileID else { return }
        update(profileID) {
            guard let id else {
                $0.selectedID = nil
                return
            }
            $0.selectedID = $0.visibleItems.contains(where: { $0.id == id }) ? id : nil
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        generation &+= 1
        guard let profileID = activeProfileID else { return }
        update(profileID) { $0.isRefreshing = false }
    }

    func deactivate() {
        cancelRefresh()
        repository = nil
        activeProfileID = nil
    }

    func purge(profileID: UUID) {
        if activeProfileID == profileID {
            cancelRefresh()
            repository = nil
            activeProfileID = nil
        }
        profiles[profileID] = nil
        cacheOrder.removeAll { $0 == profileID }
    }

    func purgeAll() {
        cancelRefresh()
        repository = nil
        activeProfileID = nil
        profiles.removeAll()
        cacheOrder.removeAll()
    }

    private func finish(_ items: [MobileContainerItem], profileID: UUID, generation: Int) {
        guard isCurrent(profileID, generation) else { return }
        refreshTask = nil
        update(profileID) {
            $0.items = items
            $0.hasLoadedOnce = true
            $0.isRefreshing = false
            $0.hasRefreshError = false
            Self.applyFilter(to: &$0)
            if let selectedID = $0.selectedID,
               !$0.visibleItems.contains(where: { $0.id == selectedID }) {
                $0.selectedID = nil
            }
        }
    }

    private func finishFailure(preservesContent: Bool, profileID: UUID, generation: Int) {
        guard isCurrent(profileID, generation) else { return }
        refreshTask = nil
        update(profileID) {
            $0.isRefreshing = false
            if preservesContent {
                $0.hasRefreshError = true
            } else {
                $0.pageState = .error
            }
        }
    }

    private func finishCancellation(profileID: UUID, generation: Int) {
        guard isCurrent(profileID, generation) else { return }
        refreshTask = nil
        update(profileID) { $0.isRefreshing = false }
    }

    private func isCurrent(_ profileID: UUID, _ generation: Int) -> Bool {
        activeProfileID == profileID && self.generation == generation
    }

    private func update(
        _ profileID: UUID,
        _ body: (inout MobileContainerInventoryState) -> Void
    ) {
        guard var profile = profiles[profileID] else { return }
        body(&profile)
        profiles[profileID] = profile
        touchCache(profileID)
    }

    private static func applyFilter(to state: inout MobileContainerInventoryState) {
        state.visibleItems = state.items.filter { item in
            switch state.filter {
            case .all: true
            case .running: item.status == .running
            case .stopped: item.status == .stopped
            case .attention: item.status == .attention || item.status == .unknown
            }
        }
        if state.items.isEmpty {
            state.pageState = .empty
        } else if state.visibleItems.isEmpty {
            state.pageState = .filteredEmpty
        } else {
            state.pageState = .content
        }
    }

    private func touchCache(_ profileID: UUID) {
        cacheOrder.removeAll { $0 == profileID }
        cacheOrder.append(profileID)
        while cacheOrder.count > cacheLimit, let evicted = cacheOrder.first {
            cacheOrder.removeFirst()
            profiles[evicted] = nil
        }
    }
}

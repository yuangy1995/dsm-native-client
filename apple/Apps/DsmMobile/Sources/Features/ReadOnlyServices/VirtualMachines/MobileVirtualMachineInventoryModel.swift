import DsmCore
import Foundation
import Observation

@MainActor
@Observable
final class MobileVirtualMachineInventoryModel {
    static let defaultCacheLimit = 4

    private(set) var activeProfileID: UUID?
    private(set) var profiles: [UUID: MobileVirtualMachineInventoryState] = [:]

    @ObservationIgnored private var repository: (any MobileVirtualMachineInventoryReading)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cacheOrder: [UUID] = []
    @ObservationIgnored private let cacheLimit: Int

    init(cacheLimit: Int = defaultCacheLimit) {
        self.cacheLimit = max(1, cacheLimit)
    }

    var state: MobileVirtualMachineInventoryState {
        guard let activeProfileID else { return MobileVirtualMachineInventoryState() }
        return profiles[activeProfileID] ?? MobileVirtualMachineInventoryState()
    }

    func activate(profileID: UUID?, repository: (any MobileVirtualMachineInventoryReading)?) async {
        cancelRefresh()
        guard let profileID, let repository, repository.profileID == profileID else {
            self.repository = nil
            activeProfileID = nil
            return
        }
        activeProfileID = profileID
        self.repository = repository
        if profiles[profileID] == nil {
            profiles[profileID] = MobileVirtualMachineInventoryState()
            touchCache(profileID)
        } else {
            touchCache(profileID)
        }
        if !state.hasSuccessfulLoad && !state.requiresReconnect { await refresh() }
    }

    func refresh() async {
        guard let profileID = activeProfileID,
              let repository,
              repository.profileID == profileID,
              !state.requiresReconnect else { return }
        cancelRefresh()
        generation &+= 1
        let requestGeneration = generation
        let preservesContent = state.hasSuccessfulLoad
        update(profileID) {
            $0.isRefreshing = preservesContent
            $0.hasRefreshError = false
            if !preservesContent { $0.pageState = .loading }
        }

        let task = Task { [weak self, repository] in
            do {
                let snapshot = try await repository.loadInventory()
                try Task.checkCancellation()
                self?.finish(snapshot, profileID: profileID, generation: requestGeneration)
            } catch is CancellationError {
                self?.finishCancellation(profileID: profileID, generation: requestGeneration)
            } catch let error as AppError where error.category == .cancelled {
                self?.finishCancellation(profileID: profileID, generation: requestGeneration)
            } catch {
                self?.finishFailure(
                    error,
                    preservesContent: preservesContent,
                    profileID: profileID,
                    generation: requestGeneration
                )
            }
        }
        refreshTask = task
        await task.value
    }

    func selectSection(_ section: MobileVirtualMachineSection) {
        guard let profileID = activeProfileID else { return }
        update(profileID) {
            $0.selectedSection = section
            $0.selectedItemID = nil
        }
    }

    func setFilter(_ filter: MobileVirtualMachineFilter) {
        guard let profileID = activeProfileID else { return }
        update(profileID) {
            $0.filter = filter
            Self.applyFilter(to: &$0)
            if let selectedItemID = $0.selectedItemID,
               !$0.visibleMachines.contains(where: { $0.id == selectedItemID }) {
                $0.selectedItemID = nil
            }
        }
    }

    func selectItem(_ id: String?) {
        guard let profileID = activeProfileID else { return }
        update(profileID) {
            guard let id else {
                $0.selectedItemID = nil
                return
            }
            if $0.selectedSection == .machines {
                $0.selectedItemID = $0.visibleMachines.contains(where: { $0.id == id }) ? id : nil
            } else {
                $0.selectedItemID = id
            }
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

    private func finish(_ snapshot: VirtualMachineManagerSnapshot, profileID: UUID, generation: Int) {
        guard isCurrent(profileID, generation) else { return }
        refreshTask = nil
        update(profileID) {
            let preservesSuccessfulSections = $0.hasSuccessfulLoad
            $0.machines = snapshot.machines.map(MobileVirtualMachineItem.init)
            $0.sectionStates[.machines] = $0.machines.isEmpty ? .empty : .content
            var hasPartialFailure = false
            Self.mergeSection(
                .hosts, managerSection: .hosts, snapshot: snapshot,
                preservesSuccessfulSections: preservesSuccessfulSections, state: &$0,
                values: snapshot.hosts.map(MobileVirtualizationResourceItem.init), keyPath: \.hosts,
                hasPartialFailure: &hasPartialFailure
            )
            Self.mergeSection(
                .storages, managerSection: .storages, snapshot: snapshot,
                preservesSuccessfulSections: preservesSuccessfulSections, state: &$0,
                values: snapshot.storages.map(MobileVirtualizationResourceItem.init), keyPath: \.storages,
                hasPartialFailure: &hasPartialFailure
            )
            Self.mergeSection(
                .networks, managerSection: .networks, snapshot: snapshot,
                preservesSuccessfulSections: preservesSuccessfulSections, state: &$0,
                values: snapshot.networks.map(MobileVirtualizationResourceItem.init), keyPath: \.networks,
                hasPartialFailure: &hasPartialFailure
            )
            Self.mergeSection(
                .images, managerSection: .images, snapshot: snapshot,
                preservesSuccessfulSections: preservesSuccessfulSections, state: &$0,
                values: snapshot.images.map(MobileVirtualizationResourceItem.init), keyPath: \.images,
                hasPartialFailure: &hasPartialFailure
            )
            let protection = snapshot.protectionPlans.map {
                MobileProtectionItem($0, kind: .plan)
            } + snapshot.protectionSchedulePolicies.map {
                MobileProtectionItem($0, kind: .schedule)
            } + snapshot.protectionRetentionPolicies.map {
                MobileProtectionItem($0, kind: .retention)
            }
            Self.mergeSection(
                .protection, managerSection: .protection, snapshot: snapshot,
                preservesSuccessfulSections: preservesSuccessfulSections, state: &$0,
                values: protection, keyPath: \.protection,
                hasPartialFailure: &hasPartialFailure
            )
            Self.mergeSection(
                .events, managerSection: .logs, snapshot: snapshot,
                preservesSuccessfulSections: preservesSuccessfulSections, state: &$0,
                values: snapshot.events.map(MobileVirtualMachineEventItem.init), keyPath: \.events,
                hasPartialFailure: &hasPartialFailure
            )
            $0.hasLoadedOnce = true
            $0.hasSuccessfulLoad = true
            $0.requiresReconnect = false
            $0.isRefreshing = false
            $0.hasRefreshError = hasPartialFailure
            Self.applyFilter(to: &$0)
            if let selectedItemID = $0.selectedItemID,
               $0.selectedSection == .machines,
               !$0.visibleMachines.contains(where: { $0.id == selectedItemID }) {
                $0.selectedItemID = nil
            }
        }
    }

    private func finishFailure(
        _ error: Error,
        preservesContent: Bool,
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrent(profileID, generation) else { return }
        refreshTask = nil
        update(profileID) {
            $0.isRefreshing = false
            if Self.requiresReconnect(error) {
                $0.requiresReconnect = true
                $0.hasRefreshError = false
                if !preservesContent {
                    for section in MobileVirtualMachineSection.allCases {
                        $0.sectionStates[section] = .failed
                    }
                    $0.hasLoadedOnce = true
                    $0.pageState = .content
                }
                return
            }
            $0.requiresReconnect = false
            if preservesContent {
                $0.hasRefreshError = true
            } else {
                let state: MobileReadOnlySectionState = (error as? AppError)?.category == .apiUnavailable
                    ? .unavailable
                    : .failed
                for section in MobileVirtualMachineSection.allCases { $0.sectionStates[section] = state }
                $0.hasLoadedOnce = true
                $0.pageState = .content
            }
        }
    }

    private func finishCancellation(profileID: UUID, generation: Int) {
        guard isCurrent(profileID, generation) else { return }
        refreshTask = nil
        update(profileID) {
            $0.isRefreshing = false
            if !$0.hasLoadedOnce { $0.pageState = .content }
        }
    }

    private func isCurrent(_ profileID: UUID, _ generation: Int) -> Bool {
        activeProfileID == profileID && self.generation == generation
    }

    private static func requiresReconnect(_ error: Error) -> Bool {
        guard let error = error as? AppError else { return false }
        return switch error.category {
        case .authenticationRequired, .otpRequired, .tlsUntrusted, .tlsCertificateChanged:
            true
        default:
            false
        }
    }

    private func update(_ profileID: UUID, _ body: (inout MobileVirtualMachineInventoryState) -> Void) {
        guard var profile = profiles[profileID] else { return }
        body(&profile)
        profiles[profileID] = profile
        touchCache(profileID)
    }

    private static func applyFilter(to state: inout MobileVirtualMachineInventoryState) {
        state.visibleMachines = state.machines.filter { item in
            switch state.filter {
            case .all: true
            case .running: item.status == .running
            case .stopped: item.status == .stopped
            case .attention: item.status == .attention || item.status == .unknown
            }
        }
        if state.sectionState(.machines) == .content && state.visibleMachines.isEmpty {
            state.pageState = .filteredEmpty
        } else {
            state.pageState = .content
        }
    }

    private static func mergeSection<Value>(
        _ section: MobileVirtualMachineSection,
        managerSection: VirtualMachineManagerSection,
        snapshot: VirtualMachineManagerSnapshot,
        preservesSuccessfulSections: Bool,
        state: inout MobileVirtualMachineInventoryState,
        values: [Value],
        keyPath: WritableKeyPath<MobileVirtualMachineInventoryState, [Value]>,
        hasPartialFailure: inout Bool
    ) {
        let resultState: MobileReadOnlySectionState?
        if snapshot.failedSections.contains(managerSection) {
            resultState = .failed
        } else if snapshot.unavailableSections.contains(managerSection) {
            resultState = .unavailable
        } else {
            resultState = nil
        }
        if let resultState {
            if preservesSuccessfulSections,
               state.sectionState(section) == .content || state.sectionState(section) == .empty {
                hasPartialFailure = true
            } else {
                state[keyPath: keyPath] = []
                state.sectionStates[section] = resultState
            }
            return
        }
        state[keyPath: keyPath] = values
        state.sectionStates[section] = values.isEmpty ? .empty : .content
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

private extension MobileVirtualMachineSection {
    var managerSection: VirtualMachineManagerSection? {
        switch self {
        case .machines: nil
        case .hosts: .hosts
        case .storages: .storages
        case .networks: .networks
        case .images: .images
        case .protection: .protection
        case .events: .logs
        }
    }
}

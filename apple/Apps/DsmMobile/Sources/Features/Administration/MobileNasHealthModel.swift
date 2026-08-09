import Foundation
import Observation

@MainActor
@Observable
final class MobileNasHealthModel {
    static let defaultCacheLimit = 4

    private(set) var activeProfileID: UUID?
    private(set) var state = MobileNasHealthState()

    @ObservationIgnored private var repository: (any MobileNasHealthReading)?
    @ObservationIgnored private var cachedStates: [UUID: MobileNasHealthState] = [:]
    @ObservationIgnored private var cacheOrder: [UUID] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let cacheLimit: Int

    init(cacheLimit: Int = 4) {
        self.cacheLimit = max(1, cacheLimit)
    }

    func activate(
        profileID: UUID?,
        repository: (any MobileNasHealthReading)?
    ) async {
        cancelRefresh()
        saveActiveState()
        guard let profileID, let repository, repository.profileID == profileID else {
            self.repository = nil
            activeProfileID = nil
            state = MobileNasHealthState()
            return
        }

        activeProfileID = profileID
        self.repository = repository
        if let cached = cachedStates[profileID] {
            state = cached
            touchCache(profileID)
        } else {
            state = MobileNasHealthState()
            await refresh()
        }
    }

    func refresh() async {
        guard let profileID = activeProfileID,
              let repository,
              repository.profileID == profileID else { return }

        cancelRefresh()
        generation &+= 1
        let requestGeneration = generation
        beginLoading()

        let task = Task { [weak self, repository] in
            await withTaskGroup(of: LoadOutcome.self) { group in
                group.addTask {
                    do { return .system(MobileNasSystemHealth(try await repository.loadSystemOverview())) }
                    catch is CancellationError { return .cancelled(.system) }
                    catch { return .failed(.system) }
                }
                group.addTask {
                    do { return .performance(MobileNasPerformanceHealth(try await repository.loadPerformanceSnapshot())) }
                    catch is CancellationError { return .cancelled(.performance) }
                    catch { return .failed(.performance) }
                }
                group.addTask {
                    do { return .storage(MobileNasStorageHealth(try await repository.loadStorage())) }
                    catch is CancellationError { return .cancelled(.storage) }
                    catch { return .failed(.storage) }
                }
                group.addTask {
                    do { return .update(MobileNasUpdateHealth(try await repository.checkSystemUpdate())) }
                    catch is CancellationError { return .cancelled(.update) }
                    catch { return .failed(.update) }
                }

                for await outcome in group {
                    guard !Task.isCancelled else { return }
                    self?.apply(outcome, profileID: profileID, generation: requestGeneration)
                }
            }
            self?.finishRefresh(profileID: profileID, generation: requestGeneration)
        }
        refreshTask = task
        await task.value
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        generation &+= 1
        state.system.cancelLoading()
        state.performance.cancelLoading()
        state.storage.cancelLoading()
        state.update.cancelLoading()
    }

    func deactivate() {
        cancelRefresh()
        saveActiveState()
        repository = nil
        activeProfileID = nil
        state = MobileNasHealthState()
    }

    /// 用户退出或删除配置档时清除当前进程中的健康信息缓存。
    func purge(profileID: UUID) {
        if activeProfileID == profileID {
            cancelRefresh()
            repository = nil
            activeProfileID = nil
            state = MobileNasHealthState()
        }
        cachedStates[profileID] = nil
        cacheOrder.removeAll { $0 == profileID }
    }

    func purgeAll() {
        cancelRefresh()
        repository = nil
        activeProfileID = nil
        state = MobileNasHealthState()
        cachedStates.removeAll()
        cacheOrder.removeAll()
    }

    private func beginLoading() {
        state.system.beginLoading()
        state.performance.beginLoading()
        state.storage.beginLoading()
        state.update.beginLoading()
    }

    private func apply(_ outcome: LoadOutcome, profileID: UUID, generation: Int) {
        guard isCurrent(profileID: profileID, generation: generation) else { return }
        switch outcome {
        case .system(let value): state.system.finish(value)
        case .performance(let value): state.performance.finish(value)
        case .storage(let value): state.storage.finish(value, isEmpty: value.isEmpty)
        case .update(let value): state.update.finish(value)
        case .failed(.system): state.system.fail()
        case .failed(.performance): state.performance.fail()
        case .failed(.storage): state.storage.fail()
        case .failed(.update): state.update.fail()
        case .cancelled(.system): state.system.cancelLoading()
        case .cancelled(.performance): state.performance.cancelLoading()
        case .cancelled(.storage): state.storage.cancelLoading()
        case .cancelled(.update): state.update.cancelLoading()
        }
        cacheCurrentState(profileID)
    }

    private func finishRefresh(profileID: UUID, generation: Int) {
        guard isCurrent(profileID: profileID, generation: generation) else { return }
        refreshTask = nil
        cacheCurrentState(profileID)
    }

    private func isCurrent(profileID: UUID, generation: Int) -> Bool {
        activeProfileID == profileID && self.generation == generation
    }

    private func saveActiveState() {
        guard let activeProfileID else { return }
        cacheCurrentState(activeProfileID)
    }

    private func cacheCurrentState(_ profileID: UUID) {
        cachedStates[profileID] = state
        touchCache(profileID)
        while cacheOrder.count > cacheLimit, let evicted = cacheOrder.first {
            cacheOrder.removeFirst()
            cachedStates[evicted] = nil
        }
    }

    private func touchCache(_ profileID: UUID) {
        cacheOrder.removeAll { $0 == profileID }
        cacheOrder.append(profileID)
    }
}

private extension MobileNasHealthModel {
    enum Section: Sendable {
        case system
        case performance
        case storage
        case update
    }

    enum LoadOutcome: Sendable {
        case system(MobileNasSystemHealth)
        case performance(MobileNasPerformanceHealth)
        case storage(MobileNasStorageHealth)
        case update(MobileNasUpdateHealth)
        case failed(Section)
        case cancelled(Section)
    }
}

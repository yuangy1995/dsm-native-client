import DsmCore
import Foundation
import Observation

@MainActor
@Observable
final class MobileNasDetailsModel {
    private(set) var activeProfileID: UUID?
    private(set) var activationID = UUID()
    static let logPageSizes = [50, 100, 200]
    private(set) var state = MobileNasDetailsState()

    @ObservationIgnored private var repository: (any MobileNasDetailsReading)?
    @ObservationIgnored private var requests: [MobileNasAdministrationDestination: Task<Void, Never>] = [:]
    @ObservationIgnored private var requestGenerations: [MobileNasAdministrationDestination: UInt64] = [:]
    @ObservationIgnored private var activationGeneration: UInt64 = 0

    func activate(
        profileID: UUID?,
        repository: (any MobileNasDetailsReading)?
    ) {
        deactivate()
        guard let profileID, let repository, repository.profileID == profileID else { return }
        activeProfileID = profileID
        self.repository = repository
    }

    func loadIfNeeded(_ destination: MobileNasAdministrationDestination) async {
        guard destination.isDetails, phase(for: destination) == .idle else { return }
        await refresh(destination)
    }

    func refresh(_ destination: MobileNasAdministrationDestination, logOffset: Int? = nil, logLimit: Int? = nil) async {
        guard destination.isDetails,
              let profileID = activeProfileID,
              let repository,
              repository.profileID == profileID else { return }

        cancel(destination)
        requestGenerations[destination, default: 0] &+= 1
        let requestGeneration = requestGenerations[destination, default: 0]
        let activationGeneration = activationGeneration
        let requestedLogOffset = max(0, logOffset ?? state.logs.value?.offset ?? 0)
        let requestedLogLimit = logLimit ?? state.logs.value?.limit ?? 50
        guard Self.logPageSizes.contains(requestedLogLimit) else { return }
        beginLoading(destination)

        let task = Task { [repository] in
            do {
                let outcome: LoadOutcome
                switch destination {
                case .packages:
                    outcome = .packages(try await repository.loadPackages())
                case .scheduledTasks:
                    outcome = .scheduledTasks(try await repository.loadScheduledTasks())
                case .logs:
                    outcome = .logs(try await repository.loadLogs(offset: requestedLogOffset, limit: requestedLogLimit))
                case .connections:
                    outcome = .connections(try await repository.loadConnections())
                case .externalStorage:
                    outcome = .externalStorage(try await repository.loadExternalStorage())
                case .processes:
                    outcome = .processes(try await repository.loadProcesses())
                case .shareAccess:
                    outcome = .shareAccess(try await repository.loadShareAccess())
                case .zram:
                    outcome = .zram(try await repository.loadZRAM())
                case .powerSchedule:
                    outcome = .powerSchedule(try await repository.loadPowerSchedule())
                case .system, .performance, .storage, .update, .ddns, .region, .accounts, .fileServices, .terminal, .proxy, .remoteAccess, .ethernet:
                    return
                }
                try Task.checkCancellation()
                await self.apply(
                    outcome,
                    destination: destination,
                    profileID: profileID,
                    activationGeneration: activationGeneration,
                    requestGeneration: requestGeneration
                )
            } catch is CancellationError {
                await self.applyCancellation(
                    destination: destination,
                    profileID: profileID,
                    activationGeneration: activationGeneration,
                    requestGeneration: requestGeneration
                )
            } catch {
                await self.applyFailure(
                    error,
                    destination: destination,
                    profileID: profileID,
                    activationGeneration: activationGeneration,
                    requestGeneration: requestGeneration
                )
            }
        }
        requests[destination] = task
        await task.value
    }

    func loadLogPage(_ page: Int, pageSize: Int? = nil) async {
        let limit = pageSize ?? state.logs.value?.limit ?? 50
        guard Self.logPageSizes.contains(limit) else { return }
        await refresh(.logs, logOffset: (max(1, page) - 1) * limit, logLimit: limit)
    }

    func refreshLoadedSections() async {
        let destinations = MobileNasAdministrationDestination.details.filter {
            hasAttemptedLoad($0)
        }
        await withTaskGroup(of: Void.self) { group in
            for destination in destinations {
                group.addTask { await self.refresh(destination) }
            }
            await group.waitForAll()
        }
    }

    func cancel(_ destination: MobileNasAdministrationDestination) {
        guard destination.isDetails else { return }
        requestGenerations[destination, default: 0] &+= 1
        requests.removeValue(forKey: destination)?.cancel()
        cancelLoading(destination)
    }

    func deactivate() {
        activationID = UUID()
        activationGeneration &+= 1
        for request in requests.values { request.cancel() }
        requests.removeAll()
        requestGenerations.removeAll()
        repository = nil
        activeProfileID = nil
        state = MobileNasDetailsState()
    }

    private func beginLoading(_ destination: MobileNasAdministrationDestination) {
        switch destination {
        case .packages: state.packages.beginLoading()
        case .scheduledTasks: state.scheduledTasks.beginLoading()
        case .logs: state.logs.beginLoading()
        case .connections: state.connections.beginLoading()
        case .externalStorage: state.externalStorage.beginLoading()
        case .processes: state.processes.beginLoading()
        case .shareAccess: state.shareAccess.beginLoading()
        case .zram: state.zram.beginLoading()
        case .powerSchedule: state.powerSchedule.beginLoading()
        case .system, .performance, .storage, .update, .ddns, .region, .accounts, .fileServices, .terminal, .proxy, .remoteAccess, .ethernet: break
        }
    }

    private func apply(
        _ outcome: LoadOutcome,
        destination: MobileNasAdministrationDestination,
        profileID: UUID,
        activationGeneration: UInt64,
        requestGeneration: UInt64
    ) {
        guard isCurrent(
            destination: destination,
            profileID: profileID,
            activationGeneration: activationGeneration,
            requestGeneration: requestGeneration
        ) else { return }
        requests[destination] = nil
        switch outcome {
        case .packages(let value): state.packages.finish(value, isEmpty: value.isEmpty)
        case .scheduledTasks(let value): state.scheduledTasks.finish(value, isEmpty: value.isEmpty)
        case .logs(let value): state.logs.finish(value, isEmpty: value.isEmpty)
        case .connections(let value): state.connections.finish(value, isEmpty: value.isEmpty)
        case .externalStorage(let value): state.externalStorage.finish(value, isEmpty: value.devices.isEmpty && value.unavailableConnections.isEmpty)
        case .processes(let value): state.processes.finish(value, isEmpty: value.processes.isEmpty && value.groups.isEmpty && !value.groupsAreUnavailable)
        case .shareAccess(let value): state.shareAccess.finish(value, isEmpty: value.shares.isEmpty)
        case .zram(let value): state.zram.finish(value, isEmpty: false)
        case .powerSchedule(let value): state.powerSchedule.finish(value, isEmpty: value.entries.isEmpty && !value.isTruncated)
        }
    }

    private func applyFailure(
        _ error: Error,
        destination: MobileNasAdministrationDestination,
        profileID: UUID,
        activationGeneration: UInt64,
        requestGeneration: UInt64
    ) {
        guard isCurrent(
            destination: destination,
            profileID: profileID,
            activationGeneration: activationGeneration,
            requestGeneration: requestGeneration
        ) else { return }
        requests[destination] = nil
        let isUnavailable = Self.isUnavailable(error)
        switch destination {
        case .packages: state.packages.fail(isUnavailable: isUnavailable)
        case .scheduledTasks: state.scheduledTasks.fail(isUnavailable: isUnavailable)
        case .logs: state.logs.fail(isUnavailable: isUnavailable)
        case .connections: state.connections.fail(isUnavailable: isUnavailable)
        case .externalStorage: state.externalStorage.fail(isUnavailable: isUnavailable)
        case .processes: state.processes.fail(isUnavailable: isUnavailable)
        case .shareAccess: state.shareAccess.fail(isUnavailable: isUnavailable)
        case .zram: state.zram.fail(isUnavailable: isUnavailable)
        case .powerSchedule: state.powerSchedule.fail(isUnavailable: isUnavailable)
        case .system, .performance, .storage, .update, .ddns, .region, .accounts, .fileServices, .terminal, .proxy, .remoteAccess, .ethernet: break
        }
    }

    private func applyCancellation(
        destination: MobileNasAdministrationDestination,
        profileID: UUID,
        activationGeneration: UInt64,
        requestGeneration: UInt64
    ) {
        guard isCurrent(
            destination: destination,
            profileID: profileID,
            activationGeneration: activationGeneration,
            requestGeneration: requestGeneration
        ) else { return }
        requests[destination] = nil
        cancelLoading(destination)
    }

    private func cancelLoading(_ destination: MobileNasAdministrationDestination) {
        switch destination {
        case .packages: state.packages.cancelLoading()
        case .scheduledTasks: state.scheduledTasks.cancelLoading()
        case .logs: state.logs.cancelLoading()
        case .connections: state.connections.cancelLoading()
        case .externalStorage: state.externalStorage.cancelLoading()
        case .processes: state.processes.cancelLoading()
        case .shareAccess: state.shareAccess.cancelLoading()
        case .zram: state.zram.cancelLoading()
        case .powerSchedule: state.powerSchedule.cancelLoading()
        case .system, .performance, .storage, .update, .ddns, .region, .accounts, .fileServices, .terminal, .proxy, .remoteAccess, .ethernet: break
        }
    }

    private func phase(for destination: MobileNasAdministrationDestination) -> MobileNasDetailsPhase {
        switch destination {
        case .packages: state.packages.phase
        case .scheduledTasks: state.scheduledTasks.phase
        case .logs: state.logs.phase
        case .connections: state.connections.phase
        case .externalStorage: state.externalStorage.phase
        case .processes: state.processes.phase
        case .shareAccess: state.shareAccess.phase
        case .zram: state.zram.phase
        case .powerSchedule: state.powerSchedule.phase
        case .system, .performance, .storage, .update, .ddns, .region, .accounts, .fileServices, .terminal, .proxy, .remoteAccess, .ethernet: .idle
        }
    }

    private func hasAttemptedLoad(_ destination: MobileNasAdministrationDestination) -> Bool {
        switch destination {
        case .packages: state.packages.phase != .idle
        case .scheduledTasks: state.scheduledTasks.phase != .idle
        case .logs: state.logs.phase != .idle
        case .connections: state.connections.phase != .idle
        case .externalStorage: state.externalStorage.phase != .idle
        case .processes: state.processes.phase != .idle
        case .shareAccess: state.shareAccess.phase != .idle
        case .zram: state.zram.phase != .idle
        case .powerSchedule: state.powerSchedule.phase != .idle
        case .system, .performance, .storage, .update, .ddns, .region, .accounts, .fileServices, .terminal, .proxy, .remoteAccess, .ethernet: false
        }
    }

    private func isCurrent(
        destination: MobileNasAdministrationDestination,
        profileID: UUID,
        activationGeneration: UInt64,
        requestGeneration: UInt64
    ) -> Bool {
        activeProfileID == profileID
            && repository?.profileID == profileID
            && self.activationGeneration == activationGeneration
            && requestGenerations[destination] == requestGeneration
    }

    private static func isUnavailable(_ error: Error) -> Bool {
        guard let error = error as? AppError else { return false }
        return error.category == .apiUnavailable || error.category == .versionUnsupported
    }
}

private extension MobileNasDetailsModel {
    enum LoadOutcome: Sendable {
        case packages(MobileNasBoundedPage<MobileNasPackageDetail>)
        case scheduledTasks(MobileNasBoundedPage<MobileNasScheduledTaskDetail>)
        case logs(MobileNasLogPage)
        case connections(MobileNasBoundedPage<MobileNasConnectionDetail>)
        case externalStorage(NasExternalStorageDirectory)
        case processes(NasProcessDirectory)
        case shareAccess(NasShareAccessDirectory)
        case zram(NasZRAMSnapshot)
        case powerSchedule(NasPowerScheduleSnapshot)
    }
}

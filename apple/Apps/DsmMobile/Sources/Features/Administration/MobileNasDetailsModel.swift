import DsmCore
import Foundation
import Observation

@MainActor
@Observable
final class MobileNasDetailsModel {
    private(set) var activeProfileID: UUID?
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

    func refresh(_ destination: MobileNasAdministrationDestination) async {
        guard destination.isDetails,
              let profileID = activeProfileID,
              let repository,
              repository.profileID == profileID else { return }

        cancel(destination)
        requestGenerations[destination, default: 0] &+= 1
        let requestGeneration = requestGenerations[destination, default: 0]
        let activationGeneration = activationGeneration
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
                    outcome = .logs(try await repository.loadLogs())
                case .connections:
                    outcome = .connections(try await repository.loadConnections())
                case .system, .performance, .storage, .update:
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
        case .system, .performance, .storage, .update: break
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
        case .system, .performance, .storage, .update: break
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
        case .system, .performance, .storage, .update: break
        }
    }

    private func phase(for destination: MobileNasAdministrationDestination) -> MobileNasDetailsPhase {
        switch destination {
        case .packages: state.packages.phase
        case .scheduledTasks: state.scheduledTasks.phase
        case .logs: state.logs.phase
        case .connections: state.connections.phase
        case .system, .performance, .storage, .update: .idle
        }
    }

    private func hasAttemptedLoad(_ destination: MobileNasAdministrationDestination) -> Bool {
        switch destination {
        case .packages: state.packages.phase != .idle
        case .scheduledTasks: state.scheduledTasks.phase != .idle
        case .logs: state.logs.phase != .idle
        case .connections: state.connections.phase != .idle
        case .system, .performance, .storage, .update: false
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
        case logs(MobileNasBoundedPage<MobileNasLogDetail>)
        case connections(MobileNasBoundedPage<MobileNasConnectionDetail>)
    }
}

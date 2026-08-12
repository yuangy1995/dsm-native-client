import DsmCore
import DsmNetwork
import Foundation
import Observation

protocol MobileFileActivityReading: AnyObject, Sendable {
    var profileID: UUID { get }
    func listFileActivityTasks(offset: Int, limit: Int) async throws -> FileBackgroundTaskPage
}

extension DsmFileRepository: MobileFileActivityReading {
    func listFileActivityTasks(offset: Int, limit: Int) async throws -> FileBackgroundTaskPage {
        try await listBackgroundTasks(offset: offset, limit: limit)
    }
}

@MainActor
@Observable
final class MobileFileActivityModel {
    static let pageLimit = 100

    private(set) var activeProfileID: UUID?
    private(set) var isLoading = false
    private(set) var error: AppErrorCategory?
    private(set) var isTruncated = false

    @ObservationIgnored private let coordinator: MobileTransferCoordinator
    @ObservationIgnored private var repository: (any MobileFileActivityReading)?
    @ObservationIgnored private var repositoryIdentity: ObjectIdentifier?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var observationToken: UUID?
    @ObservationIgnored private var generation = 0

    init(coordinator: MobileTransferCoordinator) {
        self.coordinator = coordinator
    }

    func activate(
        profileID: UUID?,
        repository: (any MobileFileActivityReading)?
    ) async {
        cancelRefresh()
        guard let profileID, let repository, repository.profileID == profileID else {
            reset()
            return
        }
        activeProfileID = profileID
        self.repository = repository
        repositoryIdentity = ObjectIdentifier(repository)
        error = nil
        isTruncated = false
        let token = UUID()
        observationToken = token
        await coordinator.beginFileStationObservation(profileID: profileID, token: token)
        guard observationToken == token else { return }
        await refresh()
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        guard let profileID = activeProfileID,
              let repository,
              let observationToken,
              repository.profileID == profileID,
              repositoryIdentity == ObjectIdentifier(repository) else { return }

        generation &+= 1
        let requestGeneration = generation
        let identity = ObjectIdentifier(repository)
        isLoading = true
        error = nil

        let task = Task { [weak self, repository] in
            do {
                let page = try await repository.listFileActivityTasks(
                    offset: 0,
                    limit: Self.pageLimit
                )
                try Task.checkCancellation()
                guard let self,
                      self.isCurrent(profileID, identity: identity, generation: requestGeneration) else {
                    return
                }
                await self.coordinator.syncFileStationTasks(
                    profileID: profileID,
                    observationToken: observationToken,
                    tasks: page.tasks
                )
                guard self.isCurrent(profileID, identity: identity, generation: requestGeneration) else {
                    return
                }
                self.isTruncated = page.hasMore || page.total > page.tasks.count
                self.error = nil
                self.isLoading = false
                self.refreshTask = nil
            } catch is CancellationError {
                guard let self,
                      self.isCurrent(profileID, identity: identity, generation: requestGeneration) else {
                    return
                }
                self.isLoading = false
                self.refreshTask = nil
            } catch {
                guard let self,
                      self.isCurrent(profileID, identity: identity, generation: requestGeneration) else {
                    return
                }
                self.error = (error as? AppError)?.category ?? .unknown
                self.isLoading = false
                self.refreshTask = nil
            }
        }
        refreshTask = task
        await task.value
    }

    func cancelRefresh() {
        let endingProfileID = activeProfileID
        let endingToken = observationToken
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        observationToken = nil
        isLoading = false
        if let endingProfileID, let endingToken {
            Task {
                await coordinator.endFileStationObservation(
                    profileID: endingProfileID,
                    token: endingToken
                )
            }
        }
    }

    func reset() {
        cancelRefresh()
        activeProfileID = nil
        repository = nil
        repositoryIdentity = nil
        error = nil
        isTruncated = false
    }

    private func isCurrent(
        _ profileID: UUID,
        identity: ObjectIdentifier,
        generation: Int
    ) -> Bool {
        activeProfileID == profileID &&
            repositoryIdentity == identity &&
            self.generation == generation
    }
}

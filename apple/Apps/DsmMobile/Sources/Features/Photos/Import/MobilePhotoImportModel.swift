import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoImportModel {
    private(set) var phase: MobilePhotoImportPhase = .idle

    @ObservationIgnored private var activeProfileID: UUID?
    @ObservationIgnored private var repositoryIdentity: ObjectIdentifier?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var isPreparing: Bool {
        phase == .preparing
    }

    func activate(profileID: UUID?, repositoryIdentity identity: ObjectIdentifier?) {
        guard profileID != activeProfileID || identity != repositoryIdentity else { return }
        cancelPreparation()
        activeProfileID = profileID
        repositoryIdentity = identity
        phase = .idle
    }

    func begin(
        item: any MobilePhotosPickerItemServing,
        destination: MobilePhotoImportDestination,
        repositoryProfileID: UUID,
        repositoryIdentity requestRepositoryIdentity: ObjectIdentifier,
        controller: MobileDocumentTransferController,
        service: any MobileTransferServing,
        coordinator: MobileTransferCoordinator,
        onConfirmedSuccess: @MainActor @escaping @Sendable () async -> Void
    ) {
        guard preparationTask == nil, phase != .preparing else { return }
        guard isCurrent(
            destination: destination,
            repositoryProfileID: repositoryProfileID,
            repositoryIdentity: requestRepositoryIdentity
        ),
              Self.isAllowed(destination) else {
            phase = .failed(.unavailable)
            return
        }

        generation &+= 1
        let requestGeneration = generation
        phase = .preparing
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let artifact = try await item.loadArtifact()
                defer { artifact.release() }
                try Task.checkCancellation()
                guard self.isCurrent(
                    destination: destination,
                    repositoryIdentity: requestRepositoryIdentity,
                    generation: requestGeneration
                ) else { return }
                let taskID = await controller.handlePickedFile(
                    artifact.url,
                    context: MobileDocumentPickerContext(
                        profileID: destination.profileID,
                        folderPath: destination.folderPath,
                        intent: .upload
                    ),
                    service: service
                )
                guard self.isCurrent(
                    destination: destination,
                    repositoryIdentity: requestRepositoryIdentity,
                    generation: requestGeneration
                ) else { return }
                if let taskID {
                    self.phase = .queued(taskID: taskID)
                    self.monitorCompletion(
                        taskID: taskID,
                        destination: destination,
                        repositoryIdentity: requestRepositoryIdentity,
                        generation: requestGeneration,
                        coordinator: coordinator,
                        onConfirmedSuccess: onConfirmedSuccess
                    )
                } else if controller.failure != nil {
                    self.phase = .failed(.preparationFailed)
                } else if !Task.isCancelled {
                    self.phase = .failed(.itemUnavailable)
                }
            } catch is CancellationError {
                // 系统选择取消或页面离开都保持原照片页面，不显示错误。
            } catch MobilePhotosPickerFailure.itemUnavailable {
                guard self.generation == requestGeneration else { return }
                self.phase = .failed(.itemUnavailable)
            } catch {
                guard self.generation == requestGeneration else { return }
                self.phase = .failed(.preparationFailed)
            }
            if self.generation == requestGeneration {
                self.preparationTask = nil
                if Task.isCancelled, self.phase == .preparing {
                    self.phase = .idle
                }
            }
        }
    }

    func cancelPreparation() {
        generation &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        completionTask?.cancel()
        completionTask = nil
        if phase == .preparing {
            phase = .idle
        }
    }

    func dismissFeedback() {
        switch phase {
        case .queued, .failed:
            phase = .idle
        case .idle, .preparing:
            break
        }
    }

    private func isCurrent(
        destination: MobilePhotoImportDestination,
        repositoryProfileID: UUID,
        repositoryIdentity requestRepositoryIdentity: ObjectIdentifier
    ) -> Bool {
        activeProfileID == destination.profileID &&
        repositoryProfileID == destination.profileID &&
        repositoryIdentity == requestRepositoryIdentity
    }

    private func monitorCompletion(
        taskID: UUID,
        destination: MobilePhotoImportDestination,
        repositoryIdentity requestRepositoryIdentity: ObjectIdentifier,
        generation requestGeneration: Int,
        coordinator: MobileTransferCoordinator,
        onConfirmedSuccess: @MainActor @escaping @Sendable () async -> Void
    ) {
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = await coordinator.task(id: taskID) else { return }
                if task.status.isTerminal {
                    guard task.status == .succeeded,
                          self.isCurrent(
                            destination: destination,
                            repositoryIdentity: requestRepositoryIdentity,
                            generation: requestGeneration
                          ) else { return }
                    await onConfirmedSuccess()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func isCurrent(
        destination: MobilePhotoImportDestination,
        repositoryIdentity requestRepositoryIdentity: ObjectIdentifier,
        generation requestGeneration: Int
    ) -> Bool {
        generation == requestGeneration &&
        activeProfileID == destination.profileID &&
        repositoryIdentity == requestRepositoryIdentity
    }

    nonisolated static func isAllowed(_ destination: MobilePhotoImportDestination) -> Bool {
        let root = destination.spaceRootPath
        let path = destination.folderPath
        guard isCanonicalAbsolute(root), isCanonicalAbsolute(path) else { return false }
        guard path == root || path.hasPrefix(root + "/") else { return false }
        return !path.split(separator: "/").contains { $0.caseInsensitiveCompare("#recycle") == .orderedSame }
    }

    nonisolated private static func isCanonicalAbsolute(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", !path.hasSuffix("/"),
              !path.contains("//"), !path.contains("\\"),
              !path.contains("?"), !path.contains("#") else { return false }
        return !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    deinit {
        preparationTask?.cancel()
        completionTask?.cancel()
    }
}

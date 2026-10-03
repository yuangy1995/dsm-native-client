import DsmCore
import DsmLocalization
import DsmNetwork
import Foundation
import Observation

protocol MobileFileActivityReading: AnyObject, Sendable {
    var profileID: UUID { get }
    func listFileActivityTasks(offset: Int, limit: Int) async throws -> FileBackgroundTaskPage
    func canStopBackgroundTask(_ task: FileBackgroundTaskSummary) -> Bool
    /// Repository 在写前读取失败时抛错；提交后的网络异常必须返回未知结果。
    func controlBackgroundTask(_ task: FileBackgroundTaskSummary, clearFinished: Bool) async throws -> MutationResult
}
extension MobileFileActivityReading {
    func canStopBackgroundTask(_ task: FileBackgroundTaskSummary) -> Bool { false }
    func controlBackgroundTask(_ task: FileBackgroundTaskSummary, clearFinished: Bool) async throws -> MutationResult {
        throw AppError(category: .versionUnsupported, isRetryable: false, safeUserMessage: L10n.string("files.tasks.unverified"))
    }
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
    private(set) var snapshots: [FileBackgroundTaskSummary] = []
    private(set) var controlMessage: String?
    private(set) var controlling: Set<String> = []
    private(set) var recoveryError: String?
    private struct PendingControl: Codable {
        let context: String
        let key: String
        let id: String
        let clear: Bool
    }
    private struct Envelope: Codable { let version: Int; let controls: [PendingControl] }
    private var pending: [PendingControl] = []
    private let rootURL: URL?
    private var context = ""
    private var loadFailed = false

    @ObservationIgnored private let coordinator: MobileTransferCoordinator
    @ObservationIgnored private var repository: (any MobileFileActivityReading)?
    @ObservationIgnored private var repositoryIdentity: ObjectIdentifier?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var observationToken: UUID?
    @ObservationIgnored private var generation = 0

    init(coordinator: MobileTransferCoordinator, rootURL: URL? = nil) {
        self.coordinator = coordinator; self.rootURL = rootURL
        if let file = rootURL?.appendingPathComponent("nas-controls-v1.json"), FileManager.default.fileExists(atPath: file.path) {
            do {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
                guard envelope.version == 1 else { throw MobileTransferRecoveryStore.StoreError.unsupportedVersion }
                pending = envelope.controls
            } catch { loadFailed = true; recoveryError = L10n.string("mobile.activity.recovery-error") }
        }
    }

    func activate(
        profileID: UUID?,
        repository: (any MobileFileActivityReading)?,
        context: String? = nil
    ) async {
        cancelRefresh()
        guard let profileID, let repository, repository.profileID == profileID else {
            reset()
            return
        }
        let nextContext = context ?? profileID.uuidString
        if self.context != nextContext { snapshots = []; controlMessage = nil }
        self.context = nextContext
        activeProfileID = profileID
        self.repository = repository
        repositoryIdentity = ObjectIdentifier(repository)
        error = nil
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
                var snapshots: [FileBackgroundTaskSummary] = []
                var offset = 0
                var ids = Set<String>()
                while true {
                    let page = try await repository.listFileActivityTasks(offset: offset, limit: Self.pageLimit)
                    try Task.checkCancellation()
                    guard page.offset == offset, page.nextOffset == offset + page.tasks.count,
                          page.total >= page.nextOffset, !page.tasks.isEmpty || offset == page.total,
                          page.tasks.allSatisfy({ ids.insert($0.id).inserted }) else { throw Self.invalidPage() }
                    snapshots += page.tasks
                    guard page.nextOffset < page.total || page.hasMore else { break }
                    guard page.hasMore, page.nextOffset > offset else { throw Self.invalidPage() }
                    offset = page.nextOffset
                }
                try Task.checkCancellation()
                guard let self,
                      self.isCurrent(profileID, identity: identity, generation: requestGeneration) else {
                    return
                }
                await self.coordinator.syncFileStationTasks(
                    profileID: profileID,
                    observationToken: observationToken,
                    tasks: snapshots
                )
                guard self.isCurrent(profileID, identity: identity, generation: requestGeneration) else {
                    return
                }
                self.snapshots = snapshots
                self.reconcileControls(snapshots)
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
        snapshots = []; controlMessage = nil; context = ""
    }

    func snapshot(for task: MobileActivityTask) -> FileBackgroundTaskSummary? {
        guard task.profileID == activeProfileID, task.source == .nas, task.operation.isFileStationTask,
              let identifier = task.sourceIdentifier, identifier.hasPrefix("file-background:") else { return nil }
        let id = String(identifier.dropFirst("file-background:".count))
        return snapshots.first { $0.id == id }
    }
    func canControl(_ task: FileBackgroundTaskSummary) -> Bool {
        guard !loadFailed, repository != nil, !controlling.contains(Self.key(task)),
              !pending.contains(where: { $0.context == context && $0.key == Self.key(task) }), snapshots.contains(task) else { return false }
        return task.state == .finished ? task.createdAt != nil && task.method == "start" : repository?.canStopBackgroundTask(task) == true
    }
    func control(_ task: FileBackgroundTaskSummary) async {
        guard canControl(task), let repository else { return }
        let key = Self.key(task), originalContext = context
        let identity = repositoryIdentity
        let record = PendingControl(context: context, key: key, id: task.id, clear: task.state == .finished)
        pending.append(record); controlling.insert(key); controlMessage = nil
        defer { controlling.remove(key) }
        do { try saveControls() } catch {
            pending.removeAll { $0.context == originalContext && $0.key == key }; return
        }
        let result: MutationResult
        do { result = try await repository.controlBackgroundTask(task, clearFinished: record.clear) }
        catch {
            // 生产 Repository 将提交后的异常转换为 MutationResult；抛错属于写前读取失败。
            pending.removeAll { $0.context == originalContext && $0.key == key }
            try? saveControls()
            if context == originalContext, repositoryIdentity == identity {
                controlMessage = L10n.string("mobile.activity.control-failed")
            }
            return
        }
        let uncertain = result.status == .submittedButUnverified || result.status == .cancellationRequestedAfterSubmission
        if !uncertain {
            pending.removeAll { $0.context == originalContext && $0.key == key }; try? saveControls()
        }
        guard context == originalContext, repositoryIdentity == identity else { return }
        controlMessage = L10n.string(result.status == .confirmedSuccess
            ? "mobile.activity.control-done" : uncertain ? "mobile.activity.control-unknown" : "mobile.activity.control-failed")
        await refresh()
    }

    private func reconcileControls(_ tasks: [FileBackgroundTaskSummary]) {
        pending.removeAll { record in
            guard record.context == context else { return false }
            if record.clear { return !tasks.contains { $0.id == record.id } }
            return tasks.contains { Self.key($0) == record.key && $0.state == .finished }
        }
        try? saveControls()
    }
    private func saveControls() throws {
        guard !loadFailed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        guard let rootURL else { return }
        do {
            try MobileTransferRecoveryStore.prepareDirectory(rootURL)
            try JSONEncoder().encode(Envelope(version: 1, controls: pending))
                .write(to: rootURL.appendingPathComponent("nas-controls-v1.json"), options: [.atomic, .completeFileProtection])
        } catch { recoveryError = L10n.string("mobile.activity.recovery-error"); throw error }
    }
    private static func key(_ task: FileBackgroundTaskSummary) -> String {
        [task.id, String(describing: task.kind), String(task.createdAt?.timeIntervalSince1970 ?? -1),
         String(task.apiVersion ?? -1), task.method ?? ""].joined(separator: "|")
    }
    private static func invalidPage() -> AppError {
        AppError(category: .invalidResponse, isRetryable: true, safeUserMessage: L10n.string("files.tasks.unverified"))
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

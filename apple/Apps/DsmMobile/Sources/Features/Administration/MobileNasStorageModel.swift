import DsmCore
import DsmFileFeature
import DsmNetwork
import Foundation
import Observation

/// 总览之外的存储操作上下文；写入始终绑定确认时的硬盘和当前账号。
@MainActor
@Observable
final class MobileNasStorageModel {
    enum Failure: Equatable { case read, denied, unavailable, changed, storage, pending }
    private(set) var context: String?
    private(set) var activation = UUID()
    private(set) var storage = MobileNasDetailsSection<NasStorageSnapshot>()
    private(set) var statuses: [String: MobileNasDetailsSection<NasDiskTestStatus>] = [:]
    private(set) var isAdministrator = false
    private(set) var permissionError: Failure?
    private(set) var error: Failure?
    private(set) var analysis: StorageAnalysisSnapshot?
    private(set) var analysisProgress: StorageAnalysisProgress?
    private(set) var analysisError: Failure?
    private(set) var isAnalyzing = false
    let recovery: MobileNasDiskTestStore

    @ObservationIgnored private var repository: DsmNasAdministrationRepository?
    @ObservationIgnored private var fileRepository: DsmFileRepository?
    @ObservationIgnored private var authorize: (@MainActor @Sendable () async throws -> Bool)?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var diskTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var diskGenerations: [String: UUID] = [:]
    @ObservationIgnored private var operationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var readGeneration = UUID()
    @ObservationIgnored private var analysisGeneration = UUID()

    init(root: URL? = nil) { recovery = MobileNasDiskTestStore(root: root) }

    func configure(profile: NasProfile?, repository: DsmNasAdministrationRepository?, fileRepository: DsmFileRepository?,
                   authorize: (@MainActor @Sendable () async throws -> Bool)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        guard context != next || self.repository.map(ObjectIdentifier.init) != repository.map(ObjectIdentifier.init) else {
            self.authorize = authorize; self.fileRepository = fileRepository; return
        }
        deactivate()
        context = next; self.repository = repository; self.fileRepository = fileRepository; self.authorize = authorize
        recovery.reload()
    }

    func deactivate() {
        activation = UUID(); cancelReads(); cancelAnalysis()
        for task in operationTasks.values { task.cancel() }
        context = nil; repository = nil; fileRepository = nil; authorize = nil
        storage = .init(); statuses = [:]; isAdministrator = false; permissionError = nil; error = nil
        analysis = nil; analysisError = nil
    }

    func cancelStorageRead() {
        readGeneration = UUID(); readTask?.cancel(); readTask = nil; storage.cancelLoading()
    }
    func cancelReads() {
        cancelStorageRead()
        for id in Array(diskTasks.keys) { cancelStatus(id) }
    }
    func cancelStatus(_ id: String) {
        diskGenerations[id] = UUID(); diskTasks.removeValue(forKey: id)?.cancel(); statuses[id]?.cancelLoading()
    }

    func loadIfNeeded() async { if storage.phase == .idle { await refresh() } }

    func refresh() async {
        guard let repository, context != nil else { return }
        cancelReads(); readGeneration = UUID()
        let token = activation, generation = readGeneration, authorize = authorize
        storage.beginLoading(); error = nil
        let task = Task { [weak self] in
            do {
                let value = try await repository.loadStorage()
                let allowed: Bool
                let permissionFailure: Failure?
                do {
                    try Task.checkCancellation()
                    allowed = try await authorize?() == true
                    permissionFailure = allowed ? nil : .denied
                } catch is CancellationError { throw CancellationError() }
                catch { allowed = false; permissionFailure = Self.failure(error) }
                guard let self, self.activation == token, self.readGeneration == generation, !Task.isCancelled else { return }
                let previous = self.storage.value
                self.statuses = self.statuses.filter { id, _ in
                    guard let before = previous?.disks.first(where: { $0.id == id }),
                          let after = value.disks.first(where: { $0.id == id }) else { return false }
                    return MobileNasDiskTestStore.identity(before) == MobileNasDiskTestStore.identity(after)
                }
                self.storage.finish(value, isEmpty: value.disks.isEmpty && value.pools.isEmpty && value.volumes.isEmpty)
                self.isAdministrator = allowed; self.permissionError = permissionFailure
                self.recovery.reload()
                if self.recovery.failed { self.error = .storage }
                for disk in value.disks where self.entries.contains(where: { $0.disk == MobileNasDiskTestStore.identity(disk) && $0.phase == .submitted }) {
                    guard self.activation == token, self.readGeneration == generation, !Task.isCancelled else { return }
                    await self.refreshStatus(disk.id)
                }
            } catch {
                guard let self, self.activation == token, self.readGeneration == generation else { return }
                if error is CancellationError { self.storage.cancelLoading() }
                else {
                    self.storage.fail(isUnavailable: Self.failure(error) == .unavailable)
                    self.statuses = [:]; self.isAdministrator = false; self.error = Self.failure(error)
                }
            }
        }
        readTask = task; await task.value
    }

    func refreshStatus(_ diskID: String) async {
        guard let repository, !storage.isRefreshing, !storage.hasRefreshError,
              let disk = storage.value?.disks.first(where: { $0.id == diskID }), disk.supportsSmartTest else { return }
        cancelStatus(diskID)
        let token = activation, generation = UUID(), fingerprint = MobileNasDiskTestStore.identity(disk)
        diskGenerations[diskID] = generation
        var section = statuses[diskID] ?? .init(); section.beginLoading(); statuses[diskID] = section
        let task = Task { [weak self] in
            do {
                let value = try await repository.loadDiskTestStatus(disk: disk)
                guard let self, self.isCurrent(diskID, fingerprint: fingerprint, activation: token, generation: generation),
                      !Task.isCancelled, value.diskID == diskID else { return }
                self.statuses[diskID]?.finish(value, isEmpty: false)
                self.resolveRecords(disk, status: value)
            } catch {
                guard let self, self.isCurrent(diskID, fingerprint: fingerprint, activation: token, generation: generation) else { return }
                if error is CancellationError { self.statuses[diskID]?.cancelLoading() }
                else {
                    self.statuses[diskID]?.fail(isUnavailable: Self.failure(error) == .unavailable)
                    let failure = Self.failure(error)
                    if self.recovery.failed { self.error = .storage }
                    else if failure == .read, self.entries.contains(where: { $0.disk == fingerprint && $0.phase == .submitted }) { self.error = .pending }
                    else { self.error = failure }
                }
            }
        }
        diskTasks[diskID] = task; await task.value
        if diskGenerations[diskID] == generation { diskTasks[diskID] = nil }
    }

    func request(_ action: NasDiskTestAction, diskID: String) -> NasDiskTestChange? {
        guard let context, isAdministrator, !storage.isRefreshing, !storage.hasRefreshError,
              let disk = storage.value?.disks.first(where: { $0.id == diskID }),
              let section = statuses[diskID], !section.isRefreshing, !section.hasRefreshError,
              let status = section.value,
              !recovery.protects(disk: MobileNasDiskTestStore.identity(disk), context: context) else { return nil }
        let change = NasDiskTestChange(disk: disk, baseline: status, action: action)
        return change.isValid ? change : nil
    }

    func perform(_ change: NasDiskTestChange, activation token: UUID) {
        guard activation == token else { return }
        if let context, recovery.protects(disk: MobileNasDiskTestStore.identity(change.disk), context: context) { return }
        guard let current = request(change.action, diskID: change.disk.id),
              change.matchesDisk(current.disk), change.matchesStatus(current.baseline),
              let repository, let authorize, let context else { error = .changed; return }
        let store = recovery, entry: MobileNasDiskTestStore.Entry
        do { entry = try store.reserve(context: context, disk: MobileNasDiskTestStore.identity(change.disk), action: change.action) }
        catch { self.error = .storage; return }
        error = nil
        operationTasks[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.operationTasks[entry.id] = nil }
            do {
                guard try await authorize() else {
                    try store.progress(entry.id, phase: .failed, failure: .denied)
                    if self?.activation == token { self?.isAdministrator = false; self?.permissionError = .denied; self?.error = .denied }
                    return
                }
                guard let self, self.activation == token, !Task.isCancelled else {
                    try store.progress(entry.id, phase: .cancelled); return
                }
                let result = try await repository.changeDiskTestResult(change) { [weak self] in
                    try await MainActor.run {
                        guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                        try store.progress(entry.id, phase: .submitted)
                        self.cancelStatus(change.disk.id)
                        self.statuses[change.disk.id] = .init()
                    }
                }
                switch result.status {
                case .confirmedSuccess: try store.progress(entry.id, phase: .succeeded)
                case .cancelledBeforeSubmission: try store.progress(entry.id, phase: .cancelled)
                case .permissionDenied: try store.progress(entry.id, phase: .failed, failure: .denied)
                case .unsupported: try store.progress(entry.id, phase: .failed, failure: .unavailable)
                case .confirmedFailure: try store.progress(entry.id, phase: .failed, failure: .changed)
                case .submittedButUnverified, .partialSuccess, .cancellationRequestedAfterSubmission: break
                }
                store.end(entry.id)
                if self.activation == token {
                    if store.entry(entry.id)?.phase == .submitted { self.error = .pending }
                    await self.refreshStatus(change.disk.id)
                }
            } catch {
                if store.entry(entry.id)?.phase == .planned, !store.failed {
                    if error is CancellationError { try? store.progress(entry.id, phase: .cancelled) }
                    else { try? store.progress(entry.id, phase: .failed, failure: Self.failure(error) == .denied ? .denied : .unavailable) }
                }
                if self?.activation == token { self?.error = store.failed ? .storage : Self.failure(error) }
            }
        }
    }

    var entries: [MobileNasDiskTestStore.Entry] { recovery.entries.filter { $0.context == context }.reversed() }
    func disk(for entry: MobileNasDiskTestStore.Entry) -> NasDisk? {
        storage.value?.disks.first { MobileNasDiskTestStore.identity($0) == entry.disk }
    }
    func removeRecord(_ id: UUID) {
        guard let context else { return }
        do { try recovery.remove(id, context: context) }
        catch { self.error = .storage }
    }
    func isOperating(_ disk: NasDisk) -> Bool {
        let key = MobileNasDiskTestStore.identity(disk)
        return entries.contains { $0.disk == key && recovery.isExecuting($0.id) }
    }

    var canAnalyze: Bool { fileRepository != nil && !isAnalyzing }
    func startAnalysis() {
        guard let fileRepository, context != nil, !isAnalyzing else { return }
        analysisGeneration = UUID()
        let token = activation, generation = analysisGeneration
        analysis = nil; analysisError = nil; analysisProgress = nil; isAnalyzing = true
        let engine = StorageAnalysisEngine(repository: fileRepository)
        analysisTask = Task { [weak self] in
            do {
                let value = try await engine.analyze { [weak self] progress in
                    guard let self, self.activation == token, self.analysisGeneration == generation else { return }
                    self.analysisProgress = progress
                }
                guard let self, self.activation == token, self.analysisGeneration == generation, !Task.isCancelled else { return }
                self.analysis = value; self.analysisProgress = nil; self.isAnalyzing = false
            } catch {
                guard let self, self.activation == token, self.analysisGeneration == generation else { return }
                self.analysisProgress = nil; self.isAnalyzing = false
                if !(error is CancellationError) { self.analysisError = Self.failure(error) }
            }
        }
    }
    func cancelAnalysis() {
        analysisGeneration = UUID(); analysisTask?.cancel(); analysisTask = nil
        analysisProgress = nil; isAnalyzing = false
    }

    private func resolveRecords(_ disk: NasDisk, status: NasDiskTestStatus) {
        for entry in entries where entry.disk == MobileNasDiskTestStore.identity(disk)
            && entry.phase == .submitted && !recovery.isExecuting(entry.id) {
            let confirmed = entry.action == .stop ? !status.isRunning : status.isRunning && status.runningType == entry.action.testType
            if confirmed {
                do { try recovery.progress(entry.id, phase: .succeeded) }
                catch { self.error = .storage; return }
            }
        }
        if !recovery.failed { error = entries.contains { $0.phase == .submitted } ? .pending : nil }
    }
    private func isCurrent(_ id: String, fingerprint: String, activation: UUID, generation: UUID) -> Bool {
        self.activation == activation && diskGenerations[id] == generation && !storage.hasRefreshError
            && storage.value?.disks.first(where: { $0.id == id }).map(MobileNasDiskTestStore.identity) == fingerprint
    }
    private static func failure(_ error: Error) -> Failure {
        guard let error = error as? AppError else { return .read }
        switch error.category {
        case .permissionDenied, .authenticationRequired: return .denied
        case .apiUnavailable, .versionUnsupported: return .unavailable
        case .conflict, .notFound: return .changed
        default: return .read
        }
    }
}

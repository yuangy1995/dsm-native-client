import DsmCore
import DsmNetwork
import Foundation
import Observation

@MainActor @Observable
final class MobileScheduledTasksModel {
    enum Failure: Equatable { case read, denied, unavailable, changed, storage, trust }
    private(set) var context: String?
    private(set) var activation = UUID()
    private(set) var tasks = MobileNasDetailsSection<[NasScheduledTask]>()
    private(set) var permission = false
    private(set) var supportsEditing = false
    private(set) var error: Failure?
    let recovery: MobileScheduledTaskStore
    private var activeIDs: Set<UUID> = []
    @ObservationIgnored private var repository: DsmNasAdministrationRepository?
    @ObservationIgnored private var authorize: (@MainActor @Sendable () async throws -> Bool)?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var readGeneration = UUID()
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]

    init(root: URL? = nil) { recovery = .init(root: root) }
    func configure(profile: NasProfile?, repository: DsmNasAdministrationRepository?, authorize: (@MainActor @Sendable () async throws -> Bool)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        guard next != context || self.repository.map(ObjectIdentifier.init) != repository.map(ObjectIdentifier.init) else { self.authorize = authorize; return }
        deactivate(); context = next; self.repository = repository; self.authorize = authorize; recovery.reload()
    }
    func deactivate() {
        activation = UUID(); cancelRead(); operations.values.forEach { $0.cancel() }
        context = nil; repository = nil; authorize = nil; tasks = .init(); permission = false; supportsEditing = false; error = nil
    }
    func cancelRead() { readGeneration = UUID(); readTask?.cancel(); readTask = nil; tasks.cancelLoading() }
    var isOperating: Bool { recovery.entries.contains { $0.context == context && activeIDs.contains($0.id) } }
    var entries: [MobileScheduledTaskStore.Entry] { recovery.entries.filter { $0.context == context }.reversed() }
    var canCreate: Bool { supportsEditing && canManage(nil) }
    func canManage(_ task: NasScheduledTask?) -> Bool {
        permission && !isOperating && !tasks.isRefreshing && !tasks.hasRefreshError && [.content, .empty].contains(tasks.phase)
            && context.map { !recovery.protects(task: task, context: $0) } == true
    }
    func canPerform(_ change: NasScheduledTaskChange) -> Bool {
        canManage(change.task) && tasks.value.map(change.matches) == true && (change.originalDraft == nil || supportsEditing)
    }
    func loadIfNeeded() async { if tasks.phase == .idle { await refresh() } }
    func refresh() async {
        guard let repository, context != nil else { return }
        cancelRead(); let generation = readGeneration, token = activation, authorize = authorize
        tasks.beginLoading(); error = nil
        let task = Task { [weak self] in
            do {
                let values = try await repository.loadScheduledTasks(), editing = await repository.supportsScheduledTaskEditing
                let allowed: Bool, failure: Failure?
                do { try Task.checkCancellation(); allowed = try await authorize?() == true; failure = allowed ? nil : .denied }
                catch is CancellationError { throw CancellationError() }
                catch { allowed = false; failure = Self.failure(error) }
                guard let self, self.activation == token, self.readGeneration == generation, !Task.isCancelled else { return }
                self.tasks.finish(values, isEmpty: values.isEmpty); self.permission = allowed; self.supportsEditing = editing; self.error = failure
                self.recovery.reload()
                if self.recovery.failed { self.error = .storage; return }
                for entry in self.entries where entry.phase == .submitted && !self.recovery.isExecuting(entry.id) {
                    try Task.checkCancellation()
                    let draft: NasScheduledTaskDraft?
                    if entry.expected != nil, entry.action != .disable, let candidate = self.recovery.candidate(for: entry, tasks: values), let id = Int(candidate.id) {
                        do { draft = try await repository.loadScheduledTaskDraft(id: id, realOwner: candidate.realOwner) }
                        catch {
                            if error is CancellationError || error is DsmCertificateTrustError { throw error }
                            if let value = error as? AppError, [.authenticationRequired, .permissionDenied, .tlsUntrusted, .tlsCertificateChanged, .cancelled].contains(value.category) { throw error }
                            continue
                        }
                    } else { draft = nil }
                    guard self.activation == token, self.readGeneration == generation, !Task.isCancelled else { return }
                    do { try self.recovery.resolve(entry.id, tasks: values, draft: draft) }
                    catch { self.error = .storage; return }
                }
            } catch {
                guard let self, self.activation == token, self.readGeneration == generation else { return }
                if error is CancellationError { self.tasks.cancelLoading() }
                else { self.permission = false; self.error = Self.failure(error); self.tasks.fail(isUnavailable: self.error == .unavailable) }
            }
        }
        readTask = task; await task.value
    }
    func newDraft() async throws -> NasScheduledTaskDraft {
        guard canCreate, let repository else { throw CancellationError() }
        let token = activation, value = try await repository.loadScheduledTaskDraft(id: nil, realOwner: nil)
        guard token == activation, !Task.isCancelled else { throw CancellationError() }
        return value
    }
    func inspect(_ task: NasScheduledTask) async throws -> NasScheduledTaskDraft? {
        guard let repository else { throw CancellationError() }
        let token = activation, value = try await repository.inspectScheduledTask(task)
        guard token == activation, !Task.isCancelled else { throw CancellationError() }
        return value
    }
    func results(_ task: NasScheduledTask) async throws -> [NasScheduledTaskResult] {
        guard let repository else { throw CancellationError() }
        let token = activation, value = try await repository.scheduledTaskResults(for: task)
        guard token == activation, !Task.isCancelled else { throw CancellationError() }
        return value
    }
    func output(_ task: NasScheduledTask, resultID: String) async throws -> NasScheduledTaskResultOutput {
        guard let repository else { throw CancellationError() }
        let token = activation, value = try await repository.scheduledTaskOutput(for: task, resultID: resultID)
        guard token == activation, !Task.isCancelled else { throw CancellationError() }
        return value
    }
    @discardableResult func perform(_ change: NasScheduledTaskChange, activation token: UUID) -> UUID? {
        guard token == activation else { return nil }
        guard canPerform(change), let repository, let authorize, let context else { error = .changed; return nil }
        let store = recovery, entry: MobileScheduledTaskStore.Entry
        do { entry = try store.reserve(change, context: context) } catch { self.error = .storage; return nil }
        activeIDs.insert(entry.id); error = nil
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.activeIDs.remove(entry.id); self?.operations[entry.id] = nil }
            do {
                let result = try await repository.changeScheduledTaskResult(change) { [weak self] checkpoint in
                    if case .willSubmit = checkpoint {
                        guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                    }
                    try await MainActor.run {
                        if case .willSubmit = checkpoint {
                            guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                            self.cancelRead()
                        }
                        try store.checkpoint(entry.id, checkpoint)
                    }
                }
                switch result.status {
                case .confirmedSuccess: try store.finish(entry.id, phase: change.action == .run ? .accepted : .succeeded)
                case .cancelledBeforeSubmission: try store.finish(entry.id, phase: .cancelled)
                case .permissionDenied: try store.finish(entry.id, phase: .failed, failure: .denied)
                case .unsupported: try store.finish(entry.id, phase: .failed, failure: .unavailable)
                case .confirmedFailure: try store.finish(entry.id, phase: .failed, failure: result.errorCategory == .conflict || result.errorCategory == .validation ? .changed : .failed)
                default: break
                }
            } catch {
                let failure = Self.failure(error)
                if !store.failed, store.entry(entry.id)?.phase == .prepared {
                    try? store.finish(entry.id, phase: error is CancellationError ? .cancelled : .failed,
                                      failure: error is CancellationError ? nil : (failure == .denied ? .denied : .failed))
                }
                if self?.activation == token { self?.error = store.failed ? .storage : failure }
                if failure == .trust { if self?.activation == token { self?.permission = false }; return }
            }
            store.end(entry.id)
            if self?.activation == token { await self?.refresh() }
        }
        return entry.id
    }
    func waitForOperation(_ id: UUID) async { await operations[id]?.value }
    func removeRecord(_ id: UUID) {
        guard let context else { return }
        do { try recovery.remove(id, context: context) } catch { self.error = .storage }
    }
    static func failure(_ error: Error) -> Failure {
        if error is DsmCertificateTrustError { return .trust }
        guard let value = error as? AppError else { return .read }
        switch value.category {
        case .authenticationRequired, .permissionDenied: return .denied
        case .apiUnavailable, .versionUnsupported: return .unavailable
        case .conflict, .notFound: return .changed
        case .tlsUntrusted, .tlsCertificateChanged: return .trust
        default: return .read
        }
    }
}

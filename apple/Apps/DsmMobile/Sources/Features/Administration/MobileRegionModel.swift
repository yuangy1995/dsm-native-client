import DsmCore
import DsmNetwork
import Foundation
import Observation

@MainActor @Observable
final class MobileRegionModel {
    enum Failure: Equatable { case read, denied, unavailable, changed, storage }
    private(set) var context: String?
    private(set) var activation = UUID()
    private(set) var settings = MobileNasDetailsSection<NasRegionSettings>()
    private(set) var isAdministrator = false
    private(set) var error: Failure?
    let recovery: MobileRegionOperationStore
    private var activeOperationIDs: Set<UUID> = []
    @ObservationIgnored private var repository: DsmNasAdministrationRepository?
    @ObservationIgnored private var authorize: (@MainActor @Sendable () async throws -> Bool)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]

    init(root: URL? = nil) { recovery = MobileRegionOperationStore(root: root) }
    func configure(profile: NasProfile?, repository: DsmNasAdministrationRepository?,
                   authorize: (@MainActor @Sendable () async throws -> Bool)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        guard context != next || self.repository.map(ObjectIdentifier.init) != repository.map(ObjectIdentifier.init) else {
            self.authorize = authorize; return
        }
        deactivate(); context = next; self.repository = repository; self.authorize = authorize; recovery.reload()
    }
    func deactivate() {
        activation = UUID(); cancelRead(); for task in operations.values { task.cancel() }
        context = nil; repository = nil; authorize = nil; settings = .init(); isAdministrator = false; error = nil
    }
    func cancelRead() { generation = UUID(); readTask?.cancel(); readTask = nil; settings.cancelLoading() }
    func loadIfNeeded() async { if settings.phase == .idle { await refresh() } }
    func refresh() async {
        guard let repository, let context else { return }
        cancelRead(); let generation = generation, token = activation, authorize = authorize
        settings.beginLoading(); error = nil
        let task = Task { [weak self] in
            do {
                let value = try await repository.loadRegionForManagement()
                let allowed: Bool, failure: Failure?
                do { allowed = try await authorize?() == true; failure = allowed ? nil : .denied }
                catch is CancellationError { throw CancellationError() }
                catch { allowed = false; failure = Self.failure(error) }
                guard let self, self.activation == token, self.generation == generation, !Task.isCancelled else { return }
                self.settings.finish(value, isEmpty: false); self.isAdministrator = allowed; self.error = failure
                self.recovery.reload()
                do { try self.recovery.resolve(value, context: context) } catch { self.error = .storage }
                if self.recovery.failed { self.error = .storage }
            } catch {
                guard let self, self.activation == token, self.generation == generation else { return }
                if error is CancellationError { self.settings.cancelLoading() }
                else { self.error = Self.failure(error); self.isAdministrator = false; self.settings.fail(isUnavailable: self.error == .unavailable) }
            }
        }
        readTask = task; await task.value
    }
    var entries: [MobileRegionOperationStore.Entry] { recovery.entries.filter { $0.context == context }.reversed() }
    var isOperating: Bool { entries.contains { activeOperationIDs.contains($0.id) } }
    var canEdit: Bool {
        isAdministrator && !settings.isRefreshing && !settings.hasRefreshError && !isOperating
            && context.map { !recovery.protects($0) } == true
    }
    func canPerform(_ change: NasRegionChange) -> Bool { canEdit && settings.value.map(change.matches) == true }

    @discardableResult
    func perform(_ change: NasRegionChange, activation token: UUID) -> UUID? {
        guard token == activation else { return nil }
        guard canPerform(change), let context, let repository, let authorize else { error = .changed; return nil }
        let store = recovery, entry: MobileRegionOperationStore.Entry
        do { entry = try store.reserve(change, context: context) } catch { self.error = .storage; return nil }
        activeOperationIDs.insert(entry.id); error = nil
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.operations[entry.id] = nil; self?.activeOperationIDs.remove(entry.id) }
            do {
                let result = try await repository.changeRegionResult(change) { [weak self] stage in
                    switch stage {
                    case .willSave, .willSynchronize:
                        guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                    default: break
                    }
                    try await MainActor.run {
                        switch stage {
                        case .willSave, .willSynchronize:
                            guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                            self.cancelRead()
                        default: break
                        }
                        // 成功回执即使迟到也归原账号；只保存原记录，不更新新账号页面。
                        try store.checkpoint(entry.id, stage: stage)
                    }
                }
                switch result.status {
                case .confirmedSuccess: try store.finish(entry.id, phase: .succeeded)
                case .cancelledBeforeSubmission: try store.finish(entry.id, phase: .cancelled)
                case .permissionDenied: try store.finish(entry.id, phase: .failed, failure: .denied)
                case .unsupported: try store.finish(entry.id, phase: .failed, failure: .unavailable)
                case .confirmedFailure: try store.finish(entry.id, phase: .failed, failure: result.submitted ? .failed : .changed)
                case .partialSuccess:
                    if result.counts.unknown == 0 {
                        try store.finish(entry.id, phase: .partial, failure: result.errorCategory == .permission ? .denied : nil)
                    }
                case .submittedButUnverified, .cancellationRequestedAfterSubmission: break
                }
            } catch {
                if store.entry(entry.id)?.phase == .prepared, !store.failed {
                    if error is CancellationError { try? store.finish(entry.id, phase: .cancelled) }
                    else { try? store.finish(entry.id, phase: .failed, failure: Self.failure(error) == .denied ? .denied : .changed) }
                }
                if self?.activation == token { self?.error = store.failed ? .storage : Self.failure(error) }
            }
            store.end(entry.id)
            if self?.activation == token { await self?.refresh() }
        }
        return entry.id
    }
    func removeRecord(_ id: UUID) {
        guard let context else { return }
        do { try recovery.remove(id, context: context) } catch { self.error = .storage }
    }
    private static func failure(_ error: Error) -> Failure {
        guard let value = error as? AppError else { return .read }
        switch value.category {
        case .permissionDenied, .authenticationRequired: return .denied
        case .apiUnavailable, .versionUnsupported: return .unavailable
        case .conflict, .notFound: return .changed
        default: return .read
        }
    }
}

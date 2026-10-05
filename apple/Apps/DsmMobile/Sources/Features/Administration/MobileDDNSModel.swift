import DsmCore
import DsmNetwork
import Foundation
import Observation

@MainActor @Observable
final class MobileDDNSModel {
    enum Failure: Equatable { case read, denied, unavailable, changed, storage }
    private(set) var context: String?
    private(set) var activation = UUID()
    private(set) var directory = MobileNasDetailsSection<NasDDNSDirectory>()
    private(set) var isAdministrator = false
    private(set) var permissionError: Failure?
    private(set) var error: Failure?
    private var activeOperationIDs: Set<UUID> = []
    let recovery: MobileDDNSOperationStore
    @ObservationIgnored private var repository: DsmNasAdministrationRepository?
    @ObservationIgnored private var authorize: (@MainActor @Sendable () async throws -> Bool)?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var readGeneration = UUID()
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]

    init(root: URL? = nil) { recovery = MobileDDNSOperationStore(root: root) }
    func configure(profile: NasProfile?, repository: DsmNasAdministrationRepository?,
                   authorize: (@MainActor @Sendable () async throws -> Bool)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        guard next != context || self.repository.map(ObjectIdentifier.init) != repository.map(ObjectIdentifier.init) else {
            self.authorize = authorize; return
        }
        deactivate(); context = next; self.repository = repository; self.authorize = authorize; recovery.reload()
    }
    func deactivate() {
        activation = UUID(); cancelRead()
        for task in operations.values { task.cancel() }
        context = nil; repository = nil; authorize = nil; directory = .init()
        isAdministrator = false; permissionError = nil; error = nil
    }
    func cancelRead() { readGeneration = UUID(); readTask?.cancel(); readTask = nil; directory.cancelLoading() }
    func loadIfNeeded() async { if directory.phase == .idle { await refresh() } }
    func refresh() async {
        guard let repository, let context else { return }
        cancelRead(); let generation = readGeneration, token = activation, authorize = authorize
        directory.beginLoading(); error = nil
        let task = Task { [weak self] in
            do {
                let value = try await repository.loadDDNSForManagement()
                let allowed: Bool, permission: Failure?
                do {
                    try Task.checkCancellation(); allowed = try await authorize?() == true
                    permission = allowed ? nil : .denied
                } catch is CancellationError { throw CancellationError() }
                catch { allowed = false; permission = Self.failure(error) }
                guard let self, self.activation == token, self.readGeneration == generation, !Task.isCancelled else { return }
                self.directory.finish(value, isEmpty: value.records.isEmpty)
                self.isAdministrator = allowed; self.permissionError = permission
                self.recovery.reload()
                do { try self.recovery.resolve(value, context: context) }
                catch { self.error = .storage }
                if self.recovery.failed { self.error = .storage }
            } catch {
                guard let self, self.activation == token, self.readGeneration == generation else { return }
                if error is CancellationError { self.directory.cancelLoading() }
                else {
                    self.directory.fail(isUnavailable: Self.failure(error) == .unavailable)
                    self.isAdministrator = false; self.permissionError = Self.failure(error); self.error = Self.failure(error)
                }
            }
        }
        readTask = task; await task.value
    }

    var availableProviders: [NasDDNSProvider] {
        guard let value = directory.value else { return [] }
        return value.providers.filter { provider in !value.records.contains { $0.providerID == provider.id } }
    }
    var entries: [MobileDDNSOperationStore.Entry] { recovery.entries.filter { $0.context == context }.reversed() }
    var isOperating: Bool { entries.contains { activeOperationIDs.contains($0.id) } }
    var canEdit: Bool { isAdministrator && !directory.isRefreshing && !directory.hasRefreshError && !recovery.failed }

    func canPerform(_ change: NasDDNSChange) -> Bool {
        guard canEdit, let context, let value = directory.value, change.matches(value),
              !recovery.protects(change, context: context) else { return false }
        if change.action == .save, let original = change.original, let draft = change.draft,
           draft.password.isEmpty, MobileDDNSOperationStore.signature(original) == MobileDDNSOperationStore.signature(draft) { return false }
        return true
    }

    @discardableResult
    func perform(_ change: NasDDNSChange, activation token: UUID) -> UUID? {
        guard token == activation else { return nil }
        guard canPerform(change), let repository, let authorize, let context else { error = .changed; return nil }
        let store = recovery, entry: MobileDDNSOperationStore.Entry
        do { entry = try store.reserve(change, context: context) }
        catch { self.error = .storage; return nil }
        error = nil
        activeOperationIDs.insert(entry.id)
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.operations[entry.id] = nil; self?.activeOperationIDs.remove(entry.id) }
            do {
                guard try await authorize() else {
                    try store.finish(entry.id, phase: .failed, failure: .denied)
                    if self?.activation == token { self?.isAdministrator = false; self?.permissionError = .denied }
                    return
                }
                guard let self, self.activation == token, !Task.isCancelled else {
                    try store.finish(entry.id, phase: .cancelled); return
                }
                let result = try await repository.changeDDNSResult(change) { [weak self] stage in
                    try await MainActor.run {
                        if case .willSubmit = stage {
                            guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                            self.cancelRead()
                        }
                        // 迟到的成功回执仍属于原账号，必须保存，不能更新新账号界面。
                        try store.checkpoint(entry.id, stage: stage)
                    }
                }
                switch result.status {
                case .confirmedSuccess: try store.finish(entry.id, phase: .succeeded)
                case .cancelledBeforeSubmission: try store.finish(entry.id, phase: .cancelled)
                case .permissionDenied: try store.finish(entry.id, phase: .failed, failure: .denied)
                case .unsupported: try store.finish(entry.id, phase: .failed, failure: .unavailable)
                case .confirmedFailure:
                    try store.finish(entry.id, phase: .failed, failure: result.submitted ? .failed : .changed)
                case .partialSuccess, .submittedButUnverified, .cancellationRequestedAfterSubmission: break
                }
                store.end(entry.id)
                if self.activation == token { await self.refresh() }
            } catch {
                if store.entry(entry.id)?.phase == .prepared, !store.failed {
                    if error is CancellationError { try? store.finish(entry.id, phase: .cancelled) }
                    else { try? store.finish(entry.id, phase: .failed, failure: Self.failure(error) == .denied ? .denied : .failed) }
                }
                if self?.activation == token { self?.error = store.failed ? .storage : Self.failure(error) }
            }
        }
        return entry.id
    }

    func removeRecord(_ id: UUID) {
        guard let context else { return }
        do { try recovery.remove(id, context: context) }
        catch { self.error = .storage }
    }
    func providerName(for entry: MobileDDNSOperationStore.Entry) -> String? {
        directory.value?.providers.first { MobileDDNSOperationStore.digest([$0.id]) == entry.provider }?.displayName
    }
    private static func failure(_ error: Error) -> Failure {
        guard let error = error as? AppError else { return .read }
        return switch error.category {
        case .permissionDenied, .authenticationRequired: .denied
        case .apiUnavailable, .versionUnsupported: .unavailable
        case .conflict, .notFound: .changed
        default: .read
        }
    }
}

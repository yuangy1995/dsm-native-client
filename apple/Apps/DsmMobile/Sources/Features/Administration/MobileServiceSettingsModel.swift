import DsmCore
import DsmNetwork
import Foundation
import Observation

@MainActor @Observable
final class MobileServiceSettingsModel {
    enum Failure: Equatable { case read, denied, unavailable, changed, storage }
    private(set) var context: String?
    private(set) var activation = UUID()
    private(set) var sections: [NasServiceKind: MobileNasDetailsSection<NasServiceSettings>] = [:]
    private(set) var permissions: [NasServiceKind: Bool] = [:]
    private(set) var errors: [NasServiceKind: Failure] = [:]
    private var activeOperationIDs: Set<UUID> = []
    let recovery: MobileServiceOperationStore
    @ObservationIgnored private var repository: DsmNasAdministrationRepository?
    @ObservationIgnored private var authorize: (@MainActor @Sendable () async throws -> Bool)?
    @ObservationIgnored private var readTasks: [NasServiceKind: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [NasServiceKind: UUID] = [:]
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]

    init(root: URL? = nil) { recovery = MobileServiceOperationStore(root: root) }
    func configure(profile: NasProfile?, repository: DsmNasAdministrationRepository?, authorize: (@MainActor @Sendable () async throws -> Bool)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        guard next != context || self.repository.map(ObjectIdentifier.init) != repository.map(ObjectIdentifier.init) else { self.authorize = authorize; return }
        deactivate(); context = next; self.repository = repository; self.authorize = authorize; recovery.reload()
    }
    func deactivate() {
        activation = UUID(); cancelReads(); for task in operations.values { task.cancel() }
        context = nil; repository = nil; authorize = nil; sections = [:]; permissions = [:]; errors = [:]
    }
    func cancelReads() { for kind in NasServiceKind.allCases { cancelRead(kind) } }
    func cancelRead(_ kind: NasServiceKind) {
        generations[kind] = UUID(); readTasks[kind]?.cancel(); readTasks[kind] = nil; sections[kind]?.cancelLoading()
    }
    func section(_ kind: NasServiceKind) -> MobileNasDetailsSection<NasServiceSettings> { sections[kind] ?? .init() }
    var isRefreshing: Bool { sections.values.contains { $0.isRefreshing || $0.phase == .loading } }
    func refreshLoaded() async { for kind in NasServiceKind.allCases where section(kind).phase != .idle { await refresh(kind) } }
    func loadIfNeeded(_ kind: NasServiceKind) async { if section(kind).phase == .idle { await refresh(kind) } }
    func refresh(_ kind: NasServiceKind) async {
        guard let repository, let context else { return }
        cancelRead(kind); let generation = generations[kind], token = activation, authorize = authorize
        sections[kind, default: .init()].beginLoading(); errors[kind] = nil
        let task = Task { [weak self] in
            do {
                let value = try await repository.loadServiceForManagement(kind)
                let allowed: Bool, failure: Failure?
                do { try Task.checkCancellation(); allowed = try await authorize?() == true; failure = allowed ? nil : .denied }
                catch is CancellationError { throw CancellationError() }
                catch { allowed = false; failure = Self.failure(error) }
                guard let self, self.activation == token, self.generations[kind] == generation, !Task.isCancelled else { return }
                self.sections[kind, default: .init()].finish(value, isEmpty: value.isEmpty)
                self.permissions[kind] = allowed; self.errors[kind] = failure; self.recovery.reload()
                do { try self.recovery.resolve(value, context: context) } catch { self.errors[kind] = .storage }
                if self.recovery.failed { self.errors[kind] = .storage }
            } catch {
                guard let self, self.activation == token, self.generations[kind] == generation else { return }
                if error is CancellationError { self.sections[kind]?.cancelLoading() }
                else {
                    self.permissions[kind] = false; self.errors[kind] = Self.failure(error)
                    self.sections[kind, default: .init()].fail(isUnavailable: self.errors[kind] == .unavailable)
                }
            }
        }
        readTasks[kind] = task; await task.value
    }
    func entries(_ kind: NasServiceKind) -> [MobileServiceOperationStore.Entry] { recovery.entries.filter { $0.context == context && $0.kind == kind }.reversed() }
    var isOperating: Bool { recovery.entries.contains { $0.context == context && activeOperationIDs.contains($0.id) } }
    func canEdit(_ kind: NasServiceKind) -> Bool {
        let section = section(kind)
        return permissions[kind] == true && !isOperating && !section.isRefreshing && !section.hasRefreshError
            && section.value?.isEmpty == false && context.map { !recovery.protects(kind, context: $0) } == true
    }
    func canPerform(_ change: NasServiceChange) -> Bool { canEdit(change.kind) && section(change.kind).value.map(change.matches) == true }
    @discardableResult
    func perform(_ change: NasServiceChange, activation token: UUID) -> UUID? {
        guard token == activation else { return nil }
        guard canPerform(change), let repository, let authorize, let context else { errors[change.kind] = .changed; return nil }
        let store = recovery, entry: MobileServiceOperationStore.Entry
        do { entry = try store.reserve(change, context: context) } catch { errors[change.kind] = .storage; return nil }
        activeOperationIDs.insert(entry.id); errors[change.kind] = nil
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.operations[entry.id] = nil; self?.activeOperationIDs.remove(entry.id) }
            do {
                let result = try await repository.changeServiceResult(change) { [weak self] stage in
                    if case .willSubmit = stage {
                        guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                    }
                    try await MainActor.run {
                        if case .willSubmit = stage {
                            guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                            self.cancelRead(change.kind)
                        }
                        // 迟到回执只更新原账号记录，不更新当前账号页面。
                        try store.checkpoint(entry.id, stage)
                    }
                }
                let failure: MobileServiceOperationStore.Failure?
                switch result.status {
                case .permissionDenied: failure = .denied
                case .unsupported: failure = .unavailable
                case .confirmedFailure: failure = result.errorCategory == .conflict || !result.submitted ? .changed : .failed
                case .partialSuccess: failure = result.errorCategory == .permission ? .denied : (result.errorCategory == .conflict ? .changed : nil)
                default: failure = nil
                }
                try store.stop(entry.id, failure: failure)
            } catch {
                let failure = Self.failure(error)
                if !store.failed { try? store.stop(entry.id, failure: error is CancellationError ? nil : (failure == .denied ? .denied : .failed)) }
                if self?.activation == token { self?.errors[change.kind] = store.failed ? .storage : failure }
            }
            store.end(entry.id)
            if self?.activation == token { await self?.refresh(change.kind) }
        }
        return entry.id
    }
    func waitForOperation(_ id: UUID) async { await operations[id]?.value }
    func removeRecord(_ id: UUID, kind: NasServiceKind) {
        guard let context else { return }
        do { try recovery.remove(id, context: context) } catch { errors[kind] = .storage }
    }
    private static func failure(_ error: Error) -> Failure {
        guard let value = error as? AppError else { return .read }
        switch value.category { case .permissionDenied, .authenticationRequired: return .denied
        case .apiUnavailable, .versionUnsupported: return .unavailable
        case .conflict, .notFound: return .changed
        default: return .read }
    }
}

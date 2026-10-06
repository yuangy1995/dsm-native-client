import DsmCore
import DsmNetwork
import Foundation
import Observation

@MainActor @Observable
final class MobileContainerControlModel {
    enum Failure: Equatable { case read, denied, unavailable, changed, storage, trust }
    struct Confirmation: Identifiable {
        let id = UUID()
        let activation: UUID
        let action: MobileContainerControlStore.Kind
        let targets: [ContainerControlState]
    }
    private(set) var context: String?
    private(set) var activation = UUID()
    private(set) var targets: [ContainerControlState] = []
    private var submittedNames: [String: String] = [:]
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    private(set) var allowed = false
    private(set) var error: Failure?
    let recovery: MobileContainerControlStore
    @ObservationIgnored private var repository: DsmServiceManagementRepository?
    @ObservationIgnored private var authorize: (@MainActor @Sendable () async throws -> Bool)?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]

    init(root: URL? = nil) { recovery = MobileContainerControlStore(root: root) }
    func configure(profile: NasProfile?, repository: DsmServiceManagementRepository?,
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
        context = nil; repository = nil; authorize = nil; targets = []; submittedNames = [:]; allowed = false; hasLoaded = false; error = nil
    }
    func cancelRead() {
        generation = UUID(); readTask?.cancel(); readTask = nil; isRefreshing = false
    }
    var entries: [MobileContainerControlStore.Entry] { recovery.entries.filter { $0.context == context }.reversed() }
    func name(for item: MobileContainerControlStore.Item) -> String? {
        submittedNames[item.identity + item.name] ?? targets.first(where: item.matches)?.name
    }
    var isOperating: Bool { entries.contains { recovery.isExecuting($0.id) } }
    func refresh() async {
        guard let repository, let context, let authorize else { return }
        cancelRead(); let generation = generation, token = activation
        isRefreshing = true; error = nil; allowed = false
        let task = Task { [weak self] in
            do {
                guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                let values = try await repository.loadContainerControlStates()
                try Task.checkCancellation()
                guard let self, self.activation == token, self.generation == generation else { return }
                self.targets = values; self.allowed = true; self.hasLoaded = true; self.isRefreshing = false
                self.recovery.reload()
                do { try self.recovery.resolve(values, context: context) } catch { self.error = .storage }
                if self.recovery.failed { self.error = .storage }
            } catch {
                guard let self, self.activation == token, self.generation == generation else { return }
                self.isRefreshing = false; self.hasLoaded = true; self.allowed = false
                if !(error is CancellationError) { self.error = Self.failure(error) }
            }
        }
        readTask = task; await task.value
    }
    func canPerform(ids: Set<String>, action: ContainerAction) -> Bool {
        canPerform(ids: ids, kind: .init(action))
    }
    func canPerform(ids: Set<String>, kind: MobileContainerControlStore.Kind) -> Bool {
        guard let context, allowed, error == nil, !isRefreshing, !isOperating, !ids.isEmpty else { return false }
        let selected = targets.filter { ids.contains($0.id) }
        return selected.count == ids.count && selected.allSatisfy(kind.supports)
            && !recovery.protects(selected, context: context)
    }
    func confirmation(ids: Set<String>, action: ContainerAction) -> Confirmation? {
        confirmation(ids: ids, kind: .init(action))
    }
    func confirmation(ids: Set<String>, kind: MobileContainerControlStore.Kind) -> Confirmation? {
        guard canPerform(ids: ids, kind: kind) else { return nil }
        return .init(activation: activation, action: kind, targets: targets.filter { ids.contains($0.id) })
    }
    @discardableResult func perform(_ confirmation: Confirmation) -> UUID? {
        guard confirmation.activation == activation else { return nil }
        let selected = confirmation.targets, ids = Set(selected.map(\.id)), action = confirmation.action
        guard canPerform(ids: ids, kind: action), selected.allSatisfy({ targets.contains($0) }),
              let repository, let context, let authorize else { error = .changed; return nil }
        let store = recovery, entry: MobileContainerControlStore.Entry, token = activation
        do { entry = try store.reserve(selected, action: action, context: context) }
        catch { self.error = .storage; return nil }
        // 已删除目标的名称只保留在当前账号内存中，便于对照逐项结果。
        for target in selected {
            submittedNames[MobileContainerControlStore.digest(target.id) + MobileContainerControlStore.digest(target.name)] = target.name
        }
        error = nil
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.operations[entry.id] = nil }
            var failedIndex: Int?, failure: Failure?
            for (index, target) in selected.enumerated() {
                do {
                    try Task.checkCancellation()
                    guard self?.activation == token else { throw CancellationError() }
                    let observer: ContainerControlObserver = { [weak self] stage in
                        if stage == .willSubmit {
                            guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                        }
                        try await MainActor.run {
                            if stage == .willSubmit {
                                guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                                self.cancelRead()
                            }
                            // 已提交旧账号的回执只写原记录，不更新当前页面。
                            try store.checkpoint(entry.id, index: index, stage: stage)
                        }
                    }
                    if let controlAction = action.controlAction {
                        try await repository.controlContainer(target, action: controlAction, observer: observer)
                    } else {
                        try await repository.deleteContainer(target, observer: observer)
                    }
                } catch {
                    if !(error is CancellationError) && (error as? AppError)?.category != .cancelled {
                        failedIndex = index; failure = Self.failure(error)
                    }
                    break
                }
            }
            if !store.failed {
                try? store.finish(entry.id, failedIndex: failedIndex, failure: failure.map(Self.storeFailure))
            }
            store.end(entry.id)
            guard let self, self.activation == token else { return }
            if store.failed { self.error = .storage; self.allowed = false; return }
            if let failure, [.trust, .denied].contains(failure) { self.error = failure; self.allowed = false; return }
            await self.refresh()
        }
        return entry.id
    }
    func waitForOperation(_ id: UUID) async { await operations[id]?.value }
    func removeRecord(_ id: UUID) {
        guard let context else { return }
        do { try recovery.remove(id, context: context) } catch { self.error = .storage }
    }
    private static func storeFailure(_ failure: Failure) -> MobileContainerControlStore.Failure {
        switch failure { case .denied: .denied; case .unavailable: .unavailable; case .changed: .changed; default: .failed }
    }
    private static func failure(_ error: Error) -> Failure {
        if error is DsmCertificateTrustError { return .trust }
        switch (error as? AppError)?.category {
        case .permissionDenied, .authenticationRequired, .otpRequired: return .denied
        case .apiUnavailable, .versionUnsupported: return .unavailable
        case .conflict, .notFound: return .changed
        case .tlsUntrusted, .tlsCertificateChanged: return .trust
        default: return .read
        }
    }
}

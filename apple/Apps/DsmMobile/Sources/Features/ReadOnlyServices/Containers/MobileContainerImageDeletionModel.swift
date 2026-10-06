import DsmCore
import DsmNetwork
import Foundation
import Observation

@MainActor @Observable
final class MobileContainerImageDeletionModel {
    enum Failure: Equatable { case read, denied, unavailable, changed, storage, trust }
    struct Confirmation: Identifiable {
        let id = UUID()
        let activation: UUID
        let request: ContainerImageDeletionRequest
    }
    private(set) var context: String?
    private(set) var activation = UUID()
    private(set) var targets: [ContainerImage] = []
    private(set) var names: [String: String] = [:]
    private(set) var hasLoaded = false
    private(set) var isRefreshing = false
    private(set) var allowed = false
    private(set) var error: Failure?
    let recovery: MobileContainerImageDeletionStore
    @ObservationIgnored private var repository: DsmServiceManagementRepository?
    @ObservationIgnored private var authorize: (@MainActor @Sendable () async throws -> Bool)?
    @ObservationIgnored private var pullRecovery: MobileContainerImagePullStore?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]

    init(root: URL? = nil) { recovery = MobileContainerImageDeletionStore(root: root) }
    func configure(profile: NasProfile?, repository: DsmServiceManagementRepository?,
                   pullRecovery: MobileContainerImagePullStore? = nil,
                   authorize: (@MainActor @Sendable () async throws -> Bool)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        guard next != context || self.repository.map(ObjectIdentifier.init) != repository.map(ObjectIdentifier.init) else {
            self.authorize = authorize; self.pullRecovery = pullRecovery; return
        }
        deactivate(); context = next; self.repository = repository; self.authorize = authorize
        self.pullRecovery = pullRecovery; recovery.reload()
    }
    func deactivate() {
        activation = UUID(); cancelRead()
        for task in operations.values { task.cancel() }
        context = nil; repository = nil; authorize = nil; pullRecovery = nil
        targets = []; names = [:]; hasLoaded = false; allowed = false; error = nil
    }
    func cancelRead() { generation = UUID(); readTask?.cancel(); readTask = nil; isRefreshing = false }
    var entries: [MobileContainerImageDeletionStore.Entry] { recovery.entries.filter { $0.context == context }.reversed() }
    var isOperating: Bool { entries.contains { recovery.isExecuting($0.id) } }
    var removedCount: Int { entries.reduce(0) { $0 + $1.removedTargetIDs.count } }
    func refresh() async {
        guard let repository, let authorize else { return }
        cancelRead(); let token = activation, generation = generation
        isRefreshing = true; allowed = false; error = nil
        let task = Task { [weak self] in
            do {
                guard try await authorize() else { throw Self.denied() }
                guard let self, self.activation == token, self.generation == generation, !Task.isCancelled else { return }
                self.recovery.reload()
                guard !self.recovery.failed else { self.error = .storage; self.isRefreshing = false; self.hasLoaded = true; return }
                // 原删除恢复仅需要映像清单，不依赖当前是否能再提交新删除。
                for entry in self.entries where entry.phase == .submitted && !self.recovery.isExecuting(entry.id) {
                    guard try await authorize() else { throw Self.denied() }
                    try Task.checkCancellation()
                    guard self.activation == token, self.generation == generation else { return }
                    let progress = try await repository.restoreContainerImageDeletion(entry.recovery)
                    try Task.checkCancellation()
                    guard self.activation == token, self.generation == generation else { return }
                    try self.recovery.update(progress)
                    if [.permission, .authentication].contains(progress.outcome.errorCategory) { throw Self.denied() }
                }
                let values = try await repository.loadContainerImageDeletionTargets()
                try Task.checkCancellation()
                guard self.activation == token, self.generation == generation else { return }
                self.targets = values
                for value in values {
                    if let target = ContainerImageDeletionTarget(value) { self.names[target.id] = Self.name(value) }
                }
                self.allowed = self.pullRecovery?.failed != true
                if !self.allowed { self.error = .storage }
                self.isRefreshing = false; self.hasLoaded = true
            } catch {
                guard let self, self.activation == token, self.generation == generation else { return }
                self.isRefreshing = false; self.hasLoaded = true; self.allowed = false
                if !(error is CancellationError) { self.error = self.recovery.failed ? .storage : Self.failure(error) }
            }
        }
        readTask = task; await task.value
    }
    func canDelete(ids: Set<String>) -> Bool {
        guard let context, allowed, error == nil, !recovery.failed, !isOperating, !isRefreshing, !ids.isEmpty else { return false }
        let selected = targets.filter { ids.contains($0.id) }, summaries = selected.compactMap(ContainerImageDeletionTarget.init)
        return selected.count == ids.count && summaries.count == selected.count && selected.allSatisfy { !$0.isInUse && !containsTaggedAliases($0) }
            && !recovery.protects(summaries, context: context) && !pullProtected(summaries, context: context)
    }
    func containsTaggedAliases(_ image: ContainerImage) -> Bool {
        image.tag == "<none>" && targets.contains { $0.sourceImageID == image.sourceImageID && $0.tag != "<none>" }
    }
    func confirmation(ids: Set<String>) -> Confirmation? {
        guard canDelete(ids: ids) else { return nil }
        return .init(activation: activation, request: .init(targets: targets.filter { ids.contains($0.id) }, isConfirmed: true))
    }
    @discardableResult func perform(_ confirmation: Confirmation) -> UUID? {
        let request = confirmation.request
        guard confirmation.activation == activation, canDelete(ids: Set(request.targets.map(\.id))),
              request.recovery.targets.allSatisfy({ original in targets.contains(where: original.matches) }),
              let repository, let context, let authorize else { return nil }
        let store = recovery, token = activation, entry: MobileContainerImageDeletionStore.Entry
        do { entry = try store.reserve(request, context: context) }
        catch { self.error = .storage; return nil }
        error = nil
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.operations[entry.id] = nil }
            do {
                guard try await authorize() else { throw Self.denied() }
                guard self?.activation == token, !Task.isCancelled else { throw CancellationError() }
                let progress = try await repository.deleteContainerImages(request) { [weak self] point in
                    if case .willSubmit = point { guard try await authorize() else { throw Self.denied() } }
                    try await MainActor.run {
                        if case .willSubmit(let recovery) = point {
                            guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                            guard !self.pullProtected(recovery.targets, context: context) else { throw Self.changed() }
                            self.cancelRead()
                        }
                        // 旧账号已经发出的结果只保存到原记录。
                        try store.checkpoint(entry.id, point)
                    }
                }
                try store.update(progress)
                guard let self, self.activation == token else { return }
                if [.permission, .authentication].contains(progress.outcome.errorCategory) { self.error = .denied; self.allowed = false; return }
                store.end(entry.id)
                await self.refresh()
            } catch {
                let failure = Self.failure(error)
                if !store.failed {
                    try? store.finish(entry.id, failure: error is CancellationError || (error as? AppError)?.category == .cancelled ? nil : Self.storeFailure(failure))
                }
                guard let self, self.activation == token else { return }
                if store.failed { self.error = .storage; self.allowed = false }
                else if !(error is CancellationError) { self.error = failure; self.allowed = false }
            }
        }
        return entry.id
    }
    func waitForOperation(_ id: UUID) async { await operations[id]?.value }
    func removeRecord(_ id: UUID) {
        guard let context else { return }
        do { try recovery.remove(id, context: context) } catch { self.error = .storage }
    }
    private func pullProtected(_ targets: [ContainerImageDeletionTarget], context: String) -> Bool {
        guard let pullRecovery else { return false }
        return pullRecovery.failed || pullRecovery.entries.contains { entry in
            entry.context == context && (entry.isProtected || pullRecovery.isExecuting(entry.id))
                && targets.contains { $0.overlaps(entry.recovery) }
        }
    }
    static func name(_ image: ContainerImage) -> String { "\(image.repository):\(image.tag)" }
    nonisolated private static func denied() -> AppError { .init(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
    nonisolated private static func changed() -> AppError { .init(category: .conflict, isRetryable: false, safeUserMessage: "") }
    private static func storeFailure(_ failure: Failure) -> MobileContainerImageDeletionStore.Failure {
        switch failure { case .denied: .denied; case .unavailable: .unavailable; case .changed: .changed; case .trust: .trust; default: .failed }
    }
    private static func failure(_ error: Error) -> Failure {
        if error is DsmCertificateTrustError { return .trust }
        if let error = error as? URLError, [.serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .secureConnectionFailed,
            .clientCertificateRejected, .clientCertificateRequired].contains(error.code) { return .trust }
        switch (error as? AppError)?.category {
        case .permissionDenied, .authenticationRequired, .otpRequired: return .denied
        case .apiUnavailable, .versionUnsupported: return .unavailable
        case .conflict, .notFound: return .changed
        case .tlsUntrusted, .tlsCertificateChanged: return .trust
        default: return .read
        }
    }
}

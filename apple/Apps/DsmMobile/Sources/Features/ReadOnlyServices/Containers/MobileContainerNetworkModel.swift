import DsmCore
import DsmNetwork
import Foundation
import Observation

@MainActor @Observable
final class MobileContainerNetworkModel {
    enum Failure: Equatable { case read, denied, unavailable, changed, storage, trust }
    struct Confirmation: Identifiable {
        let id = UUID()
        let activation: UUID
        let targets: [ContainerNetwork]
    }
    private(set) var context: String?
    private(set) var activation = UUID()
    private(set) var targets: [ContainerNetwork] = []
    private(set) var names: [String: String] = [:]
    private(set) var hasLoaded = false
    private(set) var isRefreshing = false
    private(set) var allowed = false
    private(set) var creationAllowed = false
    private(set) var error: Failure?
    let recovery: MobileContainerNetworkStore
    @ObservationIgnored private var repository: DsmServiceManagementRepository?
    @ObservationIgnored private var authorize: (@MainActor @Sendable () async throws -> Bool)?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var operation: Task<Void, Never>?
    init(root: URL? = nil) { recovery = .init(root: root) }
    func configure(profile: NasProfile?, repository: DsmServiceManagementRepository?, authorize: (@MainActor @Sendable () async throws -> Bool)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        guard next != context || self.repository.map(ObjectIdentifier.init) != repository.map(ObjectIdentifier.init) else { self.authorize = authorize; return }
        deactivate(); context = next; self.repository = repository; self.authorize = authorize; recovery.reload()
    }
    func deactivate() {
        activation = UUID(); cancelRead(); operation?.cancel()
        context = nil; repository = nil; authorize = nil; targets = []; names = [:]
        hasLoaded = false; allowed = false; creationAllowed = false; error = nil
    }
    func cancelRead() { generation = UUID(); readTask?.cancel(); readTask = nil; isRefreshing = false }
    var entries: [MobileContainerNetworkStore.Entry] { recovery.entries.filter { $0.context == context }.reversed() }
    var isOperating: Bool { entries.contains { recovery.isExecuting($0.id) } }
    var completedCount: Int { entries.filter { [.succeeded, .existing, .absent].contains($0.phase) }.count }
    func refresh() async {
        guard !isOperating, let repository, let authorize else { return }
        cancelRead(); let token = activation, generation = generation
        isRefreshing = true; allowed = false; creationAllowed = false; error = nil
        let task = Task { [weak self] in
            do {
                guard try await authorize() else { throw Self.denied() }
                guard let self, self.activation == token, self.generation == generation, !Task.isCancelled else { return }
                self.recovery.reload()
                guard !self.recovery.failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                for entry in self.entries where entry.phase == .submitted && !self.recovery.isExecuting(entry.id) {
                    guard try await authorize() else { throw Self.denied() }
                    try Task.checkCancellation()
                    guard self.activation == token, self.generation == generation else { return }
                    let phase: MobileContainerNetworkStore.Phase?
                    if let identity = entry.creation {
                        switch try await repository.reviewContainerNetworkCreation(identity, accepted: entry.accepted) {
                        case .created: phase = .succeeded
                        case .existing: phase = .existing
                        case .pending: phase = nil
                        }
                    } else { phase = try await repository.reviewContainerNetworkDeletion(entry.deletion!) ? (entry.accepted ? .succeeded : .absent) : nil }
                    try Task.checkCancellation()
                    guard self.activation == token, self.generation == generation else { return }
                    if let phase { try self.recovery.resolve(entry.id, phase: phase) }
                }
                let values = try await repository.loadContainerNetworks()
                let creationAllowed = await repository.canCreateContainerNetworks
                try Task.checkCancellation()
                guard self.activation == token, self.generation == generation else { return }
                self.targets = values
                for value in values { self.names[ContainerImagePullRecovery.digest(value.name)] = value.name }
                self.allowed = true; self.creationAllowed = creationAllowed; self.isRefreshing = false; self.hasLoaded = true
            } catch {
                guard let self, self.activation == token, self.generation == generation else { return }
                self.isRefreshing = false; self.hasLoaded = true; self.allowed = false; self.creationAllowed = false
                if !(error is CancellationError) { self.error = self.recovery.failed || error is MobileTransferRecoveryStore.StoreError ? .storage : Self.failure(error) }
            }
        }
        readTask = task; await task.value
    }
    var canOpenCreation: Bool { allowed && creationAllowed && !isRefreshing && !isOperating && !recovery.failed && error == nil }
    func canCreate(_ value: ContainerNetworkCreation) -> Bool {
        guard canOpenCreation, let context, value.validationIssue == nil else { return false }
        return !targets.contains { $0.name == value.name } && !recovery.protects(name: ContainerNetworkCreationIdentity(value).name, context: context)
    }
    func canDelete(ids: Set<String>) -> Bool {
        guard let context, allowed, !recovery.failed, error == nil, !isRefreshing, !isOperating, !ids.isEmpty else { return false }
        let values = targets.filter { ids.contains($0.id) }
        return values.count == ids.count && values.allSatisfy {
            $0.canDelete && !recovery.protects(name: ContainerImagePullRecovery.digest($0.name),
                identity: ContainerImagePullRecovery.digest($0.id), context: context)
        }
    }
    func confirmation(ids: Set<String>) -> Confirmation? {
        canDelete(ids: ids) ? .init(activation: activation, targets: targets.filter { ids.contains($0.id) }) : nil
    }
    @discardableResult func create(_ value: ContainerNetworkCreation, activation: UUID) -> Bool {
        guard activation == self.activation, canCreate(value) else { return false }
        return perform(creation: value, deletions: [])
    }
    @discardableResult func delete(_ value: Confirmation) -> Bool {
        guard value.activation == activation, canDelete(ids: Set(value.targets.map(\.id))),
              value.targets.allSatisfy({ targets.contains($0) }) else { return false }
        return perform(creation: nil, deletions: value.targets)
    }
    private func perform(creation: ContainerNetworkCreation?, deletions: [ContainerNetwork]) -> Bool {
        guard let context, let repository, let authorize else { return false }
        let store = recovery, token = activation, values: [MobileContainerNetworkStore.Entry]
        do { values = try store.reserve(context: context, creation: creation, deletions: deletions) }
        catch { self.error = .storage; return false }
        if let creation { names[ContainerImagePullRecovery.digest(creation.name)] = creation.name }
        let ids = values.map(\.id)
        cancelRead(); error = nil
        operation = Task { [weak self] in
            defer { store.end(ids) }
            do {
                for (index, entry) in values.enumerated() {
                    guard try await authorize() else { throw Self.denied() }
                    guard self?.activation == token, !Task.isCancelled else { throw CancellationError() }
                    let observer: ContainerNetworkMutationObserver = { [weak self] stage in
                        if case .willSubmit = stage { guard try await authorize() else { throw Self.denied() } }
                        try await MainActor.run {
                            if case .willSubmit = stage { guard self?.activation == token, !Task.isCancelled else { throw CancellationError() } }
                            // 迟到回执始终只落到原账号记录，不进入新账号界面。
                            try store.checkpoint(entry.id, stage)
                        }
                    }
                    if let creation { try await repository.createContainerNetwork(creation, observer: observer) }
                    else { try await repository.deleteContainerNetwork(deletions[index], observer: observer) }
                }
                store.end(ids)
                guard let self, self.activation == token else { return }
                await self.refresh()
            } catch {
                let failure = Self.failure(error)
                if !store.failed { try? store.finish(ids, denied: failure == .denied) }
                guard let self, self.activation == token else { return }
                if store.failed { self.error = .storage }
                else if !(error is CancellationError) { self.error = failure }
                self.allowed = false; self.creationAllowed = false
            }
        }
        return true
    }
    func waitForOperation() async { await operation?.value }
    func removeRecord(_ id: UUID) {
        guard let context else { return }
        do { try recovery.remove(id, context: context) } catch { self.error = .storage }
    }
    nonisolated private static func denied() -> AppError { .init(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
    private static func failure(_ error: Error) -> Failure {
        if error is DsmCertificateTrustError { return .trust }
        if let error = error as? URLError, [.serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .secureConnectionFailed].contains(error.code) { return .trust }
        switch (error as? AppError)?.category {
        case .permissionDenied, .authenticationRequired, .otpRequired: return .denied
        case .tlsUntrusted, .tlsCertificateChanged: return .trust
        case .apiUnavailable, .versionUnsupported: return .unavailable
        case .conflict: return .changed
        default: return .read
        }
    }
}

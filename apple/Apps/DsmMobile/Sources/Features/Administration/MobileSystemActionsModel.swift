import DsmCore
import DsmNetwork
import Foundation
import Observation

@MainActor @Observable
final class MobileSystemActionsModel {
    enum Failure: Equatable { case read, denied, unavailable, changed, storage, trust }
    private(set) var context: String?
    private(set) var activation = UUID()
    private(set) var connections = MobileNasDetailsSection<NasConnectionPage>()
    private(set) var power = MobileNasDetailsSection<Bool>()
    private(set) var connectionPermission = false
    private(set) var powerPermission = false
    private(set) var connectionError: Failure?
    private(set) var powerError: Failure?
    private(set) var isReleasingPower = false
    let recovery: MobileSystemActionStore
    private var activeIDs: Set<UUID> = []
    @ObservationIgnored private var repository: DsmNasAdministrationRepository?
    @ObservationIgnored private var session: String?
    @ObservationIgnored private var authorize: (@MainActor @Sendable () async throws -> Bool)?
    @ObservationIgnored private var connectionRead: Task<Void, Never>?
    @ObservationIgnored private var powerRead: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var powerGeneration = UUID()
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]

    init(root: URL? = nil) { recovery = .init(root: root) }
    func configure(profile: NasProfile?, repository: DsmNasAdministrationRepository?, session: AuthSession?, authorize: (@MainActor @Sendable () async throws -> Bool)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        let sessionID = session.flatMap { $0.sid.isEmpty ? nil : MobileSystemActionStore.digest([$0.sid]) }
        guard next != context || sessionID != self.session || self.repository.map(ObjectIdentifier.init) != repository.map(ObjectIdentifier.init) else { self.authorize = authorize; return }
        deactivate(); context = next; self.repository = repository; self.session = sessionID; self.authorize = authorize; recovery.reload()
    }
    func deactivate() {
        activation = UUID(); cancelReads(); operations.values.forEach { $0.cancel() }
        context = nil; repository = nil; session = nil; authorize = nil; connections = .init(); power = .init()
        connectionPermission = false; powerPermission = false; connectionError = nil; powerError = nil; isReleasingPower = false
    }
    func cancelReads() { cancelConnectionRead(); cancelPowerRead() }
    func cancelConnectionRead() { connectionGeneration = UUID(); connectionRead?.cancel(); connectionRead = nil; connections.cancelLoading() }
    func cancelPowerRead() { powerGeneration = UUID(); powerRead?.cancel(); powerRead = nil; power.cancelLoading() }
    var entries: [MobileSystemActionStore.Entry] { recovery.entries.filter { $0.context == context }.reversed() }
    var isOperating: Bool { entries.contains { activeIDs.contains($0.id) } }
    var isRefreshing: Bool { connections.isRefreshing || connections.phase == .loading || power.isRefreshing || power.phase == .loading }
    var hasPendingPower: Bool { entries.contains { $0.action != .disconnect && $0.isProtected } }
    var canReleasePower: Bool {
        guard let context, let session else { return false }
        return powerPermission && power.phase == .content && !power.isRefreshing && !power.hasRefreshError && !isOperating && !isReleasingPower && recovery.canReleasePower(context: context, session: session)
    }
    func canPerform(_ action: NasSystemAction) -> Bool {
        guard let context, !isOperating, !isReleasingPower, !recovery.protects(action, context: context) else { return false }
        if let target = action.connection {
            return connectionPermission && connections.phase == .content && !connections.isRefreshing && !connections.hasRefreshError
                && connections.value?.isCompleteForManagement == true && target.canDisconnect && target.hasDisconnectIdentity
                && connections.value?.connections.contains(where: { $0.canDisconnect && target.hasSameManagementTarget(as: $0) }) == true
        }
        return session != nil && powerPermission && power.phase == .content && power.value == true && !power.isRefreshing && !power.hasRefreshError
    }
    func loadConnectionsIfNeeded() async { if connections.phase == .idle { await refreshConnections() } }
    func loadPowerIfNeeded() async { if power.phase == .idle { await refreshPower() } }
    func refreshLoaded() async {
        if connections.phase != .idle { await refreshConnections() }
        if power.phase != .idle { await refreshPower() }
    }
    func refreshConnections() async {
        guard let repository, let context else { return }
        cancelConnectionRead(); let generation = connectionGeneration, token = activation, authorize = authorize
        connections.beginLoading(); connectionError = nil
        let task = Task { [weak self] in
            do {
                let page = try await repository.loadConnectionsForManagement()
                let allowed: Bool, permissionError: Failure?
                do { allowed = try await authorize?() == true; permissionError = allowed ? nil : .denied }
                catch {
                    if error is CancellationError || Self.failure(error) == .trust { throw error }
                    allowed = false; permissionError = Self.failure(error)
                }
                guard let self, self.activation == token, self.connectionGeneration == generation, !Task.isCancelled else { return }
                self.connections.finish(page, isEmpty: page.connections.isEmpty); self.connectionPermission = allowed
                self.connectionError = permissionError; self.recovery.reload()
                if allowed {
                    do { try self.recovery.resolveConnections(page, context: context) } catch { self.connectionError = .storage }
                }
                if self.recovery.failed { self.connectionError = .storage }
            } catch {
                guard let self, self.activation == token, self.connectionGeneration == generation else { return }
                if error is CancellationError { self.connections.cancelLoading() }
                else { self.connectionPermission = false; self.connectionError = Self.failure(error); self.connections.fail(isUnavailable: self.connectionError == .unavailable) }
            }
        }
        connectionRead = task; await task.value
    }
    func refreshPower() async {
        guard let repository, context != nil else { return }
        cancelPowerRead(); let generation = powerGeneration, token = activation, authorize = authorize
        power.beginLoading(); powerError = nil
        let task = Task { [weak self] in
            do {
                let supported = await repository.supportsSystemPowerActions
                guard supported else { throw AppError(category: .apiUnavailable, isRetryable: false, safeUserMessage: "") }
                let allowed = try await authorize?() == true
                if allowed { try await repository.verifyPowerConnection() }
                guard let self, self.activation == token, self.powerGeneration == generation, !Task.isCancelled else { return }
                self.power.finish(supported, isEmpty: false); self.powerPermission = allowed; self.powerError = allowed ? nil : .denied
                self.recovery.reload(); if self.recovery.failed { self.powerError = .storage }
            } catch {
                guard let self, self.activation == token, self.powerGeneration == generation else { return }
                if error is CancellationError { self.power.cancelLoading() }
                else { self.powerPermission = false; self.powerError = Self.failure(error); self.power.fail(isUnavailable: self.powerError == .unavailable) }
            }
        }
        powerRead = task; await task.value
    }
    @discardableResult func perform(_ action: NasSystemAction, activation token: UUID) -> UUID? {
        guard token == activation else { return nil }
        guard canPerform(action), let repository, let authorize, let context else { setError(.changed, for: action); return nil }
        let store = recovery, entry: MobileSystemActionStore.Entry
        do { entry = try store.reserve(action, context: context, session: session) } catch { setError(.storage, for: action); return nil }
        activeIDs.insert(entry.id); setError(nil, for: action)
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.activeIDs.remove(entry.id); self?.operations[entry.id] = nil }
            do {
                let result = try await repository.performSystemActionResult(action) { [weak self] checkpoint in
                    if checkpoint == .willSubmit {
                        guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                    }
                    try await MainActor.run {
                        if checkpoint == .willSubmit {
                            guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                            if action.connection != nil { self.cancelConnectionRead() } else { self.cancelPowerRead() }
                        }
                        try store.checkpoint(entry.id, checkpoint)
                    }
                }
                switch result.status {
                case .confirmedSuccess: try store.finish(entry.id, phase: action.connection == nil ? .accepted : .succeeded)
                case .cancelledBeforeSubmission: try store.finish(entry.id, phase: .cancelled)
                case .permissionDenied:
                    try store.finish(entry.id, phase: .failed, failure: .denied)
                    if self?.activation == token { self?.setError(.denied, for: action) }
                case .unsupported:
                    try store.finish(entry.id, phase: .failed, failure: .unavailable)
                    if self?.activation == token { self?.setError(.unavailable, for: action) }
                case .confirmedFailure: try store.finish(entry.id, phase: .failed, failure: result.errorCategory == .conflict ? .changed : .failed)
                default: break
                }
            } catch {
                let failure = Self.failure(error)
                if !store.failed, store.entry(entry.id)?.phase == .prepared {
                    try? store.finish(entry.id, phase: error is CancellationError ? .cancelled : .failed,
                                      failure: error is CancellationError ? nil : (failure == .denied ? .denied : .failed))
                }
                if self?.activation == token { self?.setError(store.failed ? .storage : failure, for: action) }
                if failure == .trust { if self?.activation == token { self?.connectionPermission = false; self?.powerPermission = false }; return }
            }
            store.end(entry.id)
            // 关机与重启不在提交后轮询；连接断开只读取当前目录。
            if action.connection != nil, self?.activation == token { await self?.refreshConnections() }
        }
        return entry.id
    }
    func waitForOperation(_ id: UUID) async { await operations[id]?.value }
    func releasePower(activation token: UUID) async {
        guard token == activation, canReleasePower, let repository, let context, let session, let authorize else { return }
        isReleasingPower = true; powerError = nil
        defer { if activation == token { isReleasingPower = false } }
        do {
            guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
            try await repository.verifyPowerConnection()
            guard activation == token, !Task.isCancelled else { return }
            try recovery.releasePower(context: context, session: session)
        } catch { if activation == token { setError(recovery.failed ? .storage : Self.failure(error), for: .power(.reboot)) } }
    }
    func removeRecord(_ id: UUID) {
        guard let context, let entry = recovery.entry(id), entry.context == context else { return }
        do { try recovery.remove(id, context: context) }
        catch { if entry.action == .disconnect { connectionError = .storage } else { powerError = .storage } }
    }
    private func setError(_ failure: Failure?, for action: NasSystemAction) {
        let deniesAction = failure == .denied || failure == .unavailable || failure == .trust
        if action.connection != nil { connectionError = failure; if deniesAction { connectionPermission = false } }
        else { powerError = failure; if deniesAction { powerPermission = false } }
    }
    static func failure(_ error: Error) -> Failure {
        if error is DsmCertificateTrustError { return .trust }
        guard let value = error as? AppError else { return .read }
        switch value.category {
        case .permissionDenied, .authenticationRequired: return .denied
        case .apiUnavailable, .versionUnsupported: return .unavailable
        case .conflict, .invalidResponse: return .changed
        case .tlsUntrusted, .tlsCertificateChanged: return .trust
        default: return .read
        }
    }
}

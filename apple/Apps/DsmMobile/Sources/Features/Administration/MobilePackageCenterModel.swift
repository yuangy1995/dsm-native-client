import DsmCore
import DsmNetwork
import Foundation
import Observation

@MainActor @Observable
final class MobilePackageCenterModel {
    enum Page: String, CaseIterable, Sendable { case installed, preferences, sources }
    enum Content: Equatable, Sendable {
        case installed([NasPackage]), preferences(NasPackagePreferencesSnapshot), sources([NasPackageSource])
        var isEmpty: Bool { switch self { case .installed(let values): values.isEmpty; case .sources(let values): values.isEmpty; case .preferences: false } }
    }
    enum Failure: Equatable { case read, denied, unavailable, changed, storage, trust }
    private(set) var context: String?
    private(set) var activation = UUID()
    private(set) var sections: [Page: MobileNasDetailsSection<Content>] = [:]
    private(set) var permissions: [Page: Bool] = [:]
    private(set) var errors: [Page: Failure] = [:]
    private(set) var supportedActions: [NasPackageAction] = []
    private var activeIDs: Set<UUID> = []
    let recovery: MobilePackageOperationStore
    let installation: MobilePackageInstallationModel
    @ObservationIgnored private var repository: DsmNasAdministrationRepository?
    @ObservationIgnored private var authorize: (@MainActor @Sendable () async throws -> Bool)?
    @ObservationIgnored private var reads: [Page: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [Page: UUID] = [:]
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]

    init(root: URL? = nil) { recovery = .init(root: root); installation = .init(root: root) }
    func configure(profile: NasProfile?, repository: DsmNasAdministrationRepository?, authorize: (@MainActor @Sendable () async throws -> Bool)?) {
        defer {
            installation.configure(profile: profile, repository: repository, authorize: authorize) { [weak self] in
                guard let self, let context = self.context else { return false }
                return !self.isOperating && !self.recovery.protects(context: context)
            }
        }
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        guard next != context || self.repository.map(ObjectIdentifier.init) != repository.map(ObjectIdentifier.init) else { self.authorize = authorize; return }
        deactivate(); context = next; self.repository = repository; self.authorize = authorize; recovery.reload()
    }
    func deactivate() {
        activation = UUID(); installation.deactivate(); cancelReads(); operations.values.forEach { $0.cancel() }
        context = nil; repository = nil; authorize = nil; sections = [:]; permissions = [:]; errors = [:]; supportedActions = []
    }
    func cancelReads() { Page.allCases.forEach(cancelRead); installation.cancelRead() }
    func cancelRead(_ page: Page) { generations[page] = UUID(); reads[page]?.cancel(); reads[page] = nil; sections[page]?.cancelLoading() }
    func section(_ page: Page) -> MobileNasDetailsSection<Content> { sections[page] ?? .init() }
    var installed: [NasPackage] { if case .installed(let value) = section(.installed).value { return value }; return [] }
    var preferences: NasPackagePreferencesSnapshot? { if case .preferences(let value) = section(.preferences).value { return value }; return nil }
    var sources: [NasPackageSource] { if case .sources(let value) = section(.sources).value { return value }; return [] }
    var entries: [MobilePackageOperationStore.Entry] { recovery.entries.filter { $0.context == context }.reversed() }
    var isOperating: Bool { entries.contains { activeIDs.contains($0.id) } }
    var isRefreshing: Bool { sections.values.contains { $0.isRefreshing || $0.phase == .loading } || installation.catalog.isRefreshing || installation.catalog.phase == .loading }
    func loadIfNeeded(_ page: Page) async { if section(page).phase == .idle { await refresh(page) } }
    func refreshLoaded() async {
        for page in Page.allCases where section(page).phase != .idle { await refresh(page) }
        if installation.catalog.phase != .idle { await installation.refresh() }
    }
    func refresh(_ page: Page) async {
        guard let repository, let context else { return }
        cancelRead(page); let generation = generations[page], token = activation, authorize = authorize
        sections[page, default: .init()].beginLoading(); errors[page] = nil
        let task = Task { [weak self] in
            do {
                let value: Content
                switch page {
                case .installed: value = .installed(try await repository.loadPackagesForManagement())
                case .preferences: value = .preferences(try await repository.loadPackagePreferencesForManagement())
                case .sources: value = .sources(try await repository.loadPackageSourcesForManagement())
                }
                let allowed: Bool, failure: Failure?
                do { allowed = try await authorize?() == true; failure = allowed ? nil : .denied }
                catch { if error is CancellationError || Self.failure(error) == .trust { throw error }; allowed = false; failure = Self.failure(error) }
                let actions = page == .installed ? await repository.availablePackageActions() : []
                guard let self, self.activation == token, self.generations[page] == generation, !Task.isCancelled else { return }
                self.sections[page, default: .init()].finish(value, isEmpty: value.isEmpty)
                if page == .installed { self.supportedActions = actions }
                self.permissions[page] = allowed; self.errors[page] = failure; self.recovery.reload()
                if allowed {
                    do {
                        switch value {
                        case .preferences(let value): try self.recovery.resolve(value, context: context)
                        case .sources(let value): try self.recovery.resolve(value, context: context)
                        case .installed(let value): try self.recovery.resolve(value, context: context)
                        }
                    } catch { self.errors[page] = .storage }
                }
                if self.recovery.failed { self.errors[page] = .storage }
            } catch {
                guard let self, self.activation == token, self.generations[page] == generation else { return }
                if error is CancellationError { self.sections[page]?.cancelLoading() }
                else {
                    self.permissions[page] = false; self.errors[page] = Self.failure(error)
                    self.sections[page, default: .init()].fail(isUnavailable: self.errors[page] == .unavailable)
                }
            }
        }
        reads[page] = task; await task.value
    }
    func canEdit(_ page: Page) -> Bool {
        guard let context else { return false }
        let value = section(page)
        return permissions[page] == true && [.content, .empty].contains(value.phase)
            && !value.isRefreshing && !value.hasRefreshError && !isOperating && !recovery.protects(context: context)
            && !installation.isBusy && !installation.blocksChanges
    }
    func canPerform(_ change: NasPackagePreferenceChange) -> Bool {
        guard change.isValid, canEdit(change.page) else { return false }
        switch change {
        case .settings(let original, _): return preferences == original
        case .saveSource(let source, let old):
            guard let target = source.normalizedForEditing, old.map(sources.contains) ?? true else { return false }
            return !sources.contains { ($0.name == target.name || $0.url == target.url) && $0.id != old?.id }
        case .removeSource(let value): return sources.contains(value)
        }
    }
    @discardableResult func perform(_ change: NasPackagePreferenceChange, activation token: UUID) -> UUID? {
        guard token == activation else { return nil }
        guard canPerform(change), let repository, let context, let authorize else { errors[change.page] = recovery.failed ? .storage : .changed; return nil }
        let store = recovery, entry: MobilePackageOperationStore.Entry
        do { entry = try store.reserve(change, context: context) } catch { errors[change.page] = .storage; return nil }
        activeIDs.insert(entry.id); errors[change.page] = nil
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.activeIDs.remove(entry.id); self?.operations[entry.id] = nil }
            do {
                let result = try await repository.changePackagePreferencesResult(change) { [weak self] stage in
                    if stage == .willSubmit {
                        guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                    }
                    try await MainActor.run {
                        if stage == .willSubmit {
                            guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                            self.cancelRead(change.page)
                        }
                        try store.checkpoint(entry.id, stage)
                    }
                }
                switch result.status {
                case .confirmedSuccess: try store.finish(entry.id, phase: .succeeded)
                case .cancelledBeforeSubmission: try store.finish(entry.id, phase: .cancelled)
                case .permissionDenied:
                    try store.finish(entry.id, phase: .failed, failure: .denied)
                    if self?.activation == token { self?.permissions[change.page] = false; self?.errors[change.page] = .denied }
                case .unsupported:
                    try store.finish(entry.id, phase: .failed, failure: .unavailable)
                    if self?.activation == token { self?.permissions[change.page] = false; self?.errors[change.page] = .unavailable }
                case .confirmedFailure: try store.finish(entry.id, phase: .failed, failure: result.errorCategory == .conflict || result.errorCategory == .validation ? .changed : .failed)
                default: break
                }
            } catch {
                let failure = Self.failure(error)
                if !store.failed, store.entry(entry.id)?.phase == .prepared {
                    try? store.finish(entry.id, phase: error is CancellationError ? .cancelled : .failed,
                                      failure: error is CancellationError ? nil : (failure == .denied ? .denied : .failed))
                }
                if self?.activation == token { self?.errors[change.page] = store.failed ? .storage : failure }
                if failure == .trust { if self?.activation == token { self?.permissions[change.page] = false }; return }
            }
            store.end(entry.id)
            if self?.activation == token { await self?.refresh(change.page) }
        }
        return entry.id
    }
    func waitForOperation(_ id: UUID) async { await operations[id]?.value }
    func canControl(_ package: NasPackage, action: NasPackageAction) -> Bool {
        canEdit(.installed) && supportedActions.contains(action) && package.allowsControl(action)
            && installed.first(where: { $0.id == package.id })?.matchesControlBaseline(package) == true
    }
    @discardableResult func performControl(_ package: NasPackage, action: NasPackageAction, activation token: UUID) -> UUID? {
        guard token == activation else { return nil }
        guard canControl(package, action: action), let repository, let context, let authorize else { errors[.installed] = recovery.failed ? .storage : .changed; return nil }
        let store = recovery, entry: MobilePackageOperationStore.Entry
        do { entry = try store.reserve(package, action: action, context: context) } catch { errors[.installed] = .storage; return nil }
        activeIDs.insert(entry.id); errors[.installed] = nil
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.activeIDs.remove(entry.id); self?.operations[entry.id] = nil }
            do {
                let result = try await repository.controlPackageResult(package, action: action) { [weak self] stage in
                    if stage == .willSubmit {
                        guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                    }
                    try await MainActor.run {
                        if stage == .willSubmit {
                            guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                            self.cancelRead(.installed)
                        }
                        try store.checkpoint(entry.id, stage)
                    }
                }
                switch result.status {
                case .confirmedSuccess: try store.finish(entry.id, phase: .succeeded)
                case .cancelledBeforeSubmission: try store.finish(entry.id, phase: .cancelled)
                case .permissionDenied:
                    try store.finish(entry.id, phase: .failed, failure: .denied)
                    if self?.activation == token { self?.permissions[.installed] = false; self?.errors[.installed] = .denied }
                case .unsupported:
                    try store.finish(entry.id, phase: .failed, failure: .unavailable)
                    if self?.activation == token { self?.permissions[.installed] = false; self?.errors[.installed] = .unavailable }
                case .confirmedFailure:
                    try store.finish(entry.id, phase: .failed, failure: result.errorCategory == .conflict || result.errorCategory == .validation ? .changed : .failed)
                default: break
                }
            } catch {
                let failure = Self.failure(error)
                if !store.failed, store.entry(entry.id)?.phase == .prepared {
                    try? store.finish(entry.id, phase: error is CancellationError ? .cancelled : .failed,
                                      failure: error is CancellationError ? nil : (failure == .denied ? .denied : .failed))
                }
                if self?.activation == token { self?.errors[.installed] = store.failed ? .storage : failure }
                if failure == .trust { if self?.activation == token { self?.permissions[.installed] = false }; return }
            }
            store.end(entry.id)
            if self?.activation == token { await self?.refresh(.installed) }
        }
        return entry.id
    }
    func removeRecord(_ id: UUID) {
        guard let context, let entry = recovery.entry(id), entry.context == context else { return }
        do { try recovery.remove(id, context: context) } catch { errors[entry.kind.page] = .storage }
    }
    static func failure(_ error: Error) -> Failure {
        if error is DsmCertificateTrustError { return .trust }
        switch (error as? AppError)?.category {
        case .permissionDenied, .authenticationRequired: return .denied
        case .apiUnavailable, .versionUnsupported: return .unavailable
        case .conflict, .invalidResponse: return .changed
        case .tlsUntrusted, .tlsCertificateChanged: return .trust
        default: return .read
        }
    }
}

extension NasPackagePreferenceChange {
    var page: MobilePackageCenterModel.Page { kind == .settings ? .preferences : .sources }
}

extension MobilePackageOperationStore.Kind {
    var page: MobilePackageCenterModel.Page {
        switch self { case .settings: .preferences; case .saveSource, .removeSource: .sources; case .start, .stop, .uninstall: .installed }
    }
}

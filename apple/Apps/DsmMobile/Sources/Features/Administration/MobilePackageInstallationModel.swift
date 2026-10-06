import DsmCore
import DsmLocalization
import DsmNetwork
import Foundation
import Observation

@MainActor @Observable
final class MobilePackageInstallationModel {
    typealias Failure = MobilePackageCenterModel.Failure
    private(set) var context: String?
    private(set) var activation = UUID()
    private(set) var catalog = MobileNasDetailsSection<NasPackageCatalog>()
    private(set) var plan: NasPackageInstallPlan?
    private(set) var progress: NasPackageInstallProgress?
    private(set) var error: Failure?
    private(set) var message: String?
    private(set) var allowed = false
    private(set) var isPreparing = false
    private(set) var activeIDs: Set<UUID> = []
    private(set) var currentEntryID: UUID?
    private(set) var cancellationRequested = false
    private(set) var isRecovering = false
    let recovery: MobilePackageInstallationStore
    @ObservationIgnored private var repository: DsmNasAdministrationRepository?
    @ObservationIgnored private var authorize: (@MainActor @Sendable () async throws -> Bool)?
    @ObservationIgnored private var otherOperationsAllowChanges: (@MainActor () -> Bool)?
    @ObservationIgnored private var read: Task<Void, Never>?
    @ObservationIgnored private var readID = UUID()
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var preparationID = UUID()
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isForeground = true

    init(root: URL? = nil) { recovery = .init(root: root) }
    var entries: [MobilePackageInstallationStore.Entry] { recovery.entries.filter { $0.context == context }.reversed() }
    var isBusy: Bool { isPreparing || isRecovering || entries.contains { activeIDs.contains($0.id) } }
    var blocksChanges: Bool { context.map(recovery.protects) ?? false }
    var canStart: Bool { context != nil && allowed && [.content, .empty].contains(catalog.phase) && !catalog.isRefreshing && !catalog.hasRefreshError
        && !isBusy && !blocksChanges && otherOperationsAllowChanges?() == true }
    var canUpload: Bool { context != nil && allowed && !isBusy && !blocksChanges && otherOperationsAllowChanges?() == true }
    var canConfigure: Bool { allowed && !isBusy && progress?.phase == .needsOptions && currentEntryID != nil && !recovery.failed }
    var canCancel: Bool { allowed && !cancellationRequested && progress?.canCancel == true && currentEntryID != nil && !recovery.failed }
    func configure(profile: NasProfile?, repository: DsmNasAdministrationRepository?,
        authorize: (@MainActor @Sendable () async throws -> Bool)?, otherOperationsAllowChanges: @escaping @MainActor () -> Bool) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        guard next != context || self.repository.map(ObjectIdentifier.init) != repository.map(ObjectIdentifier.init) else {
            self.authorize = authorize; self.otherOperationsAllowChanges = otherOperationsAllowChanges; return
        }
        deactivate(); context = next; self.repository = repository; self.authorize = authorize
        self.otherOperationsAllowChanges = otherOperationsAllowChanges; recovery.reload()
    }
    func deactivate() {
        activation = UUID(); cancelRead(); discardPlan(); operations.values.forEach { $0.cancel() }
        context = nil; repository = nil; authorize = nil; otherOperationsAllowChanges = nil
        currentEntryID = nil; progress = nil; cancellationRequested = false; isRecovering = false; catalog = .init(); allowed = false; error = nil; message = nil
    }
    func cancelRead() { readID = UUID(); read?.cancel(); read = nil; catalog.cancelLoading() }
    func loadIfNeeded() async { if catalog.phase == .idle { await refresh() } }
    func refresh() async {
        guard let repository, context != nil, let authorize else { return }
        cancelRead(); let generation = readID, token = activation
        catalog.beginLoading(); error = nil; message = nil
        let task = Task { [weak self] in
            var permitted = false
            do {
                permitted = try await authorize()
                let result = try await repository.loadPackageCatalogForManagement()
                guard let self, self.activation == token, self.readID == generation, !Task.isCancelled else { return }
                self.catalog.finish(result, isEmpty: result.entries.isEmpty); self.allowed = permitted
                if !permitted { self.error = .denied; return }
                if self.recovery.failed { self.error = .storage }
            } catch {
                guard let self, self.activation == token, self.readID == generation else { return }
                if error is CancellationError { self.catalog.cancelLoading() }
                else {
                    self.setError(error); self.catalog.fail(isUnavailable: self.error == .unavailable)
                    if permitted && self.error != .trust && self.error != .denied { self.allowed = true }
                }
            }
            if let self, self.activation == token, self.readID == generation, !Task.isCancelled,
               self.allowed, self.entries.contains(where: { $0.phase == .active && !self.recovery.isExecuting($0.id) && $0.id != self.currentEntryID }) {
                await self.recover()
            }
        }
        read = task; await task.value
    }
    func prepare(_ entries: [NasPackageCatalogEntry], activation token: UUID) async {
        guard token == activation, canStart, let repository, let authorize,
              !entries.isEmpty, entries.allSatisfy({ catalog.value?.entries.contains($0) == true && ($0.installedVersion == nil || $0.isUpdateAvailable) }) else { return }
        discardPlan(); let generation = preparationID; isPreparing = true; error = nil; message = nil
        progress = nil; currentEntryID = nil
        let task = Task { [weak self] in
            do {
                guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                let plan = try await repository.preparePackageInstallationForManagement(catalogIDs: entries.map(\.id))
                guard let self, self.activation == token, self.preparationID == generation, !Task.isCancelled else { return }
                self.plan = plan; self.progress = nil; self.currentEntryID = nil
            } catch {
                guard let self, self.activation == token, self.preparationID == generation, !(error is CancellationError) else { return }
                self.setError(error)
            }
            if let self, self.activation == token, self.preparationID == generation { self.isPreparing = false }
        }
        preparation = task; await task.value
    }
    func discardPlan() { preparationID = UUID(); preparation?.cancel(); preparation = nil; plan = nil; isPreparing = false }
    func start(planID: UUID, volumes: [String: String], startAfterInstall: Bool, activation token: UUID) {
        guard token == activation, canStart, let plan, plan.id == planID, let context, let repository else { return }
        do {
            let entry = try recovery.reserve(context: context, totalCount: plan.items.count, isUpload: false)
            self.plan = nil; currentEntryID = entry.id
            let checkpoint = observer(entryID: entry.id, activation: token)
            run(entry.id, token: token) { try await repository.startPackageInstallation(planID: planID, volumes: volumes, startAfterInstall: startAfterInstall, checkpoint: checkpoint) }
        } catch { setError(error) }
    }
    func upload(_ file: URL, activation token: UUID) {
        guard token == activation, canUpload, let context, let repository else { return }
        do {
            let entry = try recovery.reserve(context: context, totalCount: 1, isUpload: true)
            currentEntryID = entry.id; progress = nil; plan = nil
            let checkpoint = observer(entryID: entry.id, activation: token)
            run(entry.id, token: token) { try await repository.uploadPackageForInstallation(fileURL: file, checkpoint: checkpoint) }
        } catch { setError(error) }
    }
    @discardableResult func selectFile(_ result: Result<URL, Error>, activation token: UUID) -> Bool {
        guard token == activation else { return false }
        switch result {
        case .success(let file):
            guard canUpload else { error = .changed; message = nil; return true }
            upload(file, activation: token); return true
        case .failure(let failure):
            if failure is CancellationError || (failure as? CocoaError)?.code == .userCancelled { return false }
            if !isBusy { plan = nil; progress = nil; currentEntryID = nil }
            error = .read; message = L10n.string("mobile.package.install.fileReadError"); return true
        }
    }
    func configure(volume: String, startAfterInstall: Bool, licenseAccepted: Bool, values: [String: NasPackageOptionValue], activation token: UUID) {
        guard token == activation, canConfigure, let progress, let configuration = progress.configuration,
              configuration.accepts(values), configuration.license == nil || licenseAccepted,
              let id = currentEntryID, let context, let repository else { return }
        do {
            try recovery.begin(id, context: context)
            run(id, token: token) { try await repository.configurePackageInstallation(id: progress.id, volumeID: volume, startAfterInstall: startAfterInstall, licenseAccepted: licenseAccepted, values: values) }
        } catch { setError(error) }
    }
    func cancel(activation token: UUID) {
        guard token == activation, canCancel, let id = currentEntryID, let context, let repository, let progress else { return }
        if isBusy { cancellationRequested = true; return }
        do {
            try recovery.begin(id, context: context)
            run(id, token: token) { try await repository.cancelPackageInstallation(id: progress.id) }
        } catch { setError(error) }
    }
    func resume() async {
        guard !isBusy, !recovery.failed, let id = currentEntryID, let context, let repository,
              let entry = recovery.entry(id), entry.isProtected, let jobID = entry.operationID, let authorize else { await recover(); return }
        let token = activation
        do {
            guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
            guard token == activation else { return }
            allowed = true; try recovery.begin(id, context: context)
            run(id, token: token) { try await repository.advancePackageInstallation(id: jobID) }
            await operations[id]?.value
        } catch { if token == activation { setError(error) } }
    }
    func recover() async {
        guard !isRecovering, let context, let repository, let authorize else { return }
        let token = activation; isRecovering = true
        defer { if activation == token { isRecovering = false } }
        do {
            guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
            let installed = try await repository.loadPackagesForManagement()
            guard activation == token, !Task.isCancelled else { return }
            guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
            guard activation == token, !Task.isCancelled else { return }
            try recovery.resolve(installed, context: context); allowed = true; error = nil; message = nil
        } catch { if activation == token { setError(error) } }
    }
    func waitForOperation() async { if let id = currentEntryID { await operations[id]?.value } }
    func setForeground(_ value: Bool) {
        isForeground = value
        if value, !isBusy, progress?.phase.isActive == true { Task { await resume() } }
    }
    func remove(_ id: UUID) {
        guard let context, recovery.entry(id)?.context == context else { return }
        do { try recovery.remove(id, context: context) } catch { setError(error) }
    }
    private func observer(entryID: UUID, activation token: UUID) -> NasPackageInstallationObserver {
        let store = recovery, authorize = authorize
        return { [weak self] event in
            if event.stage == .willSubmit {
                guard try await authorize?() == true else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
            }
            try await MainActor.run {
                if event.stage == .willSubmit {
                    guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                }
                try store.checkpoint(entryID, event)
            }
        }
    }
    private func run(_ id: UUID, token: UUID, action: @escaping @MainActor @Sendable () async throws -> NasPackageInstallProgress) {
        guard let repository, let authorize else { recovery.end(id); return }
        let store = recovery
        activeIDs.insert(id); error = nil; message = nil
        operations[id] = Task { [weak self] in
            defer { store.end(id); self?.activeIDs.remove(id); self?.operations[id] = nil }
            do {
                var result = try await action()
                while true {
                    try store.finish(id, phase: result.phase)
                    guard let self, self.activation == token else { return }
                    self.progress = result
                    guard result.phase.isActive, self.isForeground, !Task.isCancelled else { return }
                    try await Task.sleep(for: .seconds(1))
                    guard self.activation == token, !Task.isCancelled, self.isForeground else { return }
                    guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                    guard self.activation == token, !Task.isCancelled else { return }
                    if self.cancellationRequested {
                        self.cancellationRequested = false
                        result = try await repository.cancelPackageInstallation(id: result.id)
                    } else { result = try await repository.advancePackageInstallation(id: result.id) }
                }
            } catch {
                // 已经进入正式安装的未知结果仍保护目标；纯准备中断不会认领安装成功。
                if !store.failed { try? store.finish(id, phase: nil) }
                if let self, self.activation == token { self.setError(error) }
            }
        }
    }
    private func setError(_ value: Error) {
        let safe = (value as? AppError)?.safeUserMessage
        message = safe?.isEmpty == false ? safe : nil
        error = recovery.failed || value is CocoaError ? .storage : MobilePackageCenterModel.failure(value)
        if error == .trust || error == .denied || error == .unavailable { allowed = false }
    }
}

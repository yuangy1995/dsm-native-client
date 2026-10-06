import DsmCore
import DsmNetwork
import Foundation
import Observation

@MainActor @Observable
final class MobileVirtualMachineControlModel {
    enum Failure: Equatable { case read, denied, unavailable, changed, storage, trust }
    struct Confirmation: Identifiable {
        let id = UUID()
        let activation: UUID
        let action: MobileVirtualMachineControlStore.Kind
        let targets: [VirtualMachineControlState]
    }
    private(set) var context: String?
    private(set) var activation = UUID()
    private(set) var targets: [VirtualMachineControlState] = []
    private var submittedNames: [String: String] = [:]
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    private(set) var allowed = false
    private(set) var supportsSettings = false
    private(set) var supportsCreation = false
    private(set) var error: Failure?
    let recovery: MobileVirtualMachineControlStore
    let creations: MobileVirtualMachineCreationStore
    private var creationNames: [UUID: String] = [:]
    @ObservationIgnored private var repository: DsmServiceManagementRepository?
    @ObservationIgnored private var authorize: (@MainActor @Sendable () async throws -> Bool)?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]

    init(root: URL? = nil) {
        recovery = MobileVirtualMachineControlStore(root: root)
        creations = MobileVirtualMachineCreationStore(root: root)
    }
    func configure(profile: NasProfile?, repository: DsmServiceManagementRepository?,
                   authorize: (@MainActor @Sendable () async throws -> Bool)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        guard next != context || self.repository.map(ObjectIdentifier.init) != repository.map(ObjectIdentifier.init) else {
            self.authorize = authorize; return
        }
        deactivate(); context = next; self.repository = repository; self.authorize = authorize; recovery.reload(); creations.reload()
    }
    func deactivate() {
        activation = UUID(); cancelRead()
        for task in operations.values { task.cancel() }
        context = nil; repository = nil; authorize = nil; targets = []; submittedNames = [:]; allowed = false; supportsSettings = false; hasLoaded = false; error = nil
        supportsCreation = false; creationNames = [:]
    }
    func cancelRead() {
        generation = UUID(); readTask?.cancel(); readTask = nil; isRefreshing = false
    }
    var entries: [MobileVirtualMachineControlStore.Entry] { recovery.entries.filter { $0.context == context }.reversed() }
    var creationEntries: [MobileVirtualMachineCreationStore.Entry] { creations.entries.filter { $0.context == context }.reversed() }
    func name(for entry: MobileVirtualMachineCreationStore.Entry) -> String? {
        creationNames[entry.id] ?? targets.first { MobileVirtualMachineCreationStore.nameDigest($0.name) == entry.nameDigest }?.name
    }
    func name(for item: MobileVirtualMachineControlStore.Item) -> String? {
        submittedNames[item.identity + item.name] ?? targets.first(where: item.matches)?.name
    }
    var isOperating: Bool { entries.contains { recovery.isExecuting($0.id) } || creationEntries.contains { creations.isExecuting($0.id) } }
    func refresh() async {
        guard let repository, let context, let authorize else { return }
        cancelRead(); let generation = generation, token = activation
        isRefreshing = true; error = nil; allowed = false
        let task = Task { [weak self] in
            do {
                guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                let values = try await repository.loadVirtualMachineControlStates()
                let supportsSettings = await repository.supportsVirtualMachineSettings
                let supportsCreation = await repository.supportsVirtualMachineCreation
                try Task.checkCancellation()
                guard let self, self.activation == token, self.generation == generation else { return }
                self.targets = values; self.hasLoaded = true
                self.supportsSettings = supportsSettings
                self.supportsCreation = supportsCreation
                self.recovery.reload(); self.creations.reload()
                do { try self.recovery.resolve(values, context: context) } catch { self.error = .storage }
                if self.recovery.failed || self.creations.failed { self.error = .storage }
                if !self.recovery.failed && !self.creations.failed {
                    for target in values where self.recovery.needsSettings(target, context: context) {
                        let settings = try await repository.loadVirtualMachineSettings(id: target.id)
                        try Task.checkCancellation()
                        guard self.activation == token, self.generation == generation else { return }
                        do { try self.recovery.resolveSettings(settings, context: context) } catch { self.error = .storage }
                    }
                    for entry in self.creationEntries where entry.phase == .submitted && !self.creations.isExecuting(entry.id) {
                        guard let tracking = entry.tracking else { continue }
                        _ = try await repository.reviewVirtualMachineCreation(tracking) { [weak self] stage in
                            try await MainActor.run {
                                guard let self, self.activation == token, self.generation == generation, !Task.isCancelled else { throw CancellationError() }
                                try self.creations.checkpoint(entry.id, stage: stage)
                            }
                        }
                        try Task.checkCancellation()
                        guard self.activation == token, self.generation == generation else { return }
                    }
                }
                self.isRefreshing = false; self.allowed = self.error == nil
            } catch {
                guard let self, self.activation == token, self.generation == generation else { return }
                self.isRefreshing = false; self.hasLoaded = true; self.allowed = false
                if !(error is CancellationError) { self.error = Self.failure(error) }
            }
        }
        readTask = task; await task.value
    }
    func canPerform(ids: Set<String>, action: VirtualMachinePowerAction) -> Bool {
        canPerform(ids: ids, kind: .init(action))
    }
    func canPerform(ids: Set<String>, kind: MobileVirtualMachineControlStore.Kind) -> Bool {
        guard kind != .edit, let context, allowed, error == nil, !isRefreshing, !isOperating, !ids.isEmpty else { return false }
        let selected = targets.filter { ids.contains($0.id) }
        return selected.count == ids.count && selected.allSatisfy(kind.supports)
            && !recovery.protects(selected, context: context)
            && !selected.contains { creations.protects(name: $0.name, id: $0.id, context: context) }
    }
    func confirmation(ids: Set<String>, action: VirtualMachinePowerAction) -> Confirmation? {
        confirmation(ids: ids, kind: .init(action))
    }
    func confirmation(ids: Set<String>, kind: MobileVirtualMachineControlStore.Kind) -> Confirmation? {
        guard canPerform(ids: ids, kind: kind) else { return nil }
        return .init(activation: activation, action: kind, targets: targets.filter { ids.contains($0.id) })
    }
    @discardableResult func perform(_ confirmation: Confirmation) -> UUID? {
        guard confirmation.activation == activation else { return nil }
        let selected = confirmation.targets, ids = Set(selected.map(\.id)), action = confirmation.action
        guard canPerform(ids: ids, kind: action), selected.allSatisfy({ targets.contains($0) }),
              let repository, let context, let authorize else { error = .changed; return nil }
        let store = recovery, entry: MobileVirtualMachineControlStore.Entry, token = activation
        do { entry = try store.reserve(selected, action: action, context: context) }
        catch { self.error = .storage; return nil }
        // 已删除目标的名称只保留在当前账号内存中，便于对照逐项结果。
        for target in selected {
            submittedNames[MobileVirtualMachineControlStore.digest(target.id) + MobileVirtualMachineControlStore.digest(target.name)] = target.name
        }
        error = nil
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.operations[entry.id] = nil }
            var failedIndex: Int?, failure: Failure?
            var canSubmit = false
            do {
                guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                let current = try await repository.loadVirtualMachineControlStates()
                try Task.checkCancellation()
                guard self?.activation == token else { throw CancellationError() }
                guard selected.allSatisfy({ current.contains($0) }) else {
                    throw AppError(category: .conflict, isRetryable: false, safeUserMessage: "")
                }
                canSubmit = true
            } catch {
                if !(error is CancellationError) && (error as? AppError)?.category != .cancelled {
                    failedIndex = 0; failure = Self.failure(error)
                }
            }
            for (index, target) in selected.enumerated() where canSubmit && failure == nil {
                do {
                    try Task.checkCancellation()
                    guard self?.activation == token else { throw CancellationError() }
                    let observer: VirtualMachineControlObserver = { [weak self] stage in
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
                        try await repository.controlVirtualMachine(target, action: controlAction, observer: observer)
                    } else if action == .delete {
                        try await repository.deleteVirtualMachine(target, observer: observer)
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
    func canEdit(id: String) -> Bool {
        guard let context, supportsSettings, allowed, error == nil, !isRefreshing, !isOperating,
              let target = targets.first(where: { $0.id == id }), ["shutdown", "running"].contains(target.status) else { return false }
        return !recovery.protects([target], context: context) && !creations.protects(name: target.name, id: target.id, context: context)
    }
    func loadSettings(id: String, activation token: UUID) async throws -> VirtualMachineSettingsState {
        guard token == activation, canEdit(id: id), let repository, let authorize,
              let target = targets.first(where: { $0.id == id }) else {
            throw AppError(category: .conflict, isRetryable: false, safeUserMessage: "")
        }
        guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
        let settings = try await repository.loadVirtualMachineSettings(id: id)
        try Task.checkCancellation()
        guard token == activation, canEdit(id: id), settings.name == target.name, settings.status == target.status else {
            throw AppError(category: .conflict, isRetryable: false, safeUserMessage: "")
        }
        return settings
    }
    @discardableResult func saveSettings(_ target: VirtualMachineSettingsState, configuration: VirtualMachineUpdate,
                                         activation token: UUID) -> UUID? {
        guard token == activation else { return nil }
        guard canEdit(id: target.id), let repository, let context, let authorize,
              targets.contains(where: { $0.id == target.id && $0.name == target.name && $0.status == target.status }),
              !creations.protects(name: configuration.name ?? target.name, context: context) else { error = .changed; return nil }
        let store = recovery, entry: MobileVirtualMachineControlStore.Entry
        do { entry = try store.reserveEdit(target, update: configuration, context: context) }
        catch { self.error = .storage; return nil }
        submittedNames[MobileVirtualMachineControlStore.digest(target.id) + MobileVirtualMachineControlStore.digest(target.name)] = target.name
        error = nil
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.operations[entry.id] = nil }
            var failure: Failure?
            do {
                guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                try Task.checkCancellation()
                guard self?.activation == token else { throw CancellationError() }
                try await repository.updateVirtualMachine(target, configuration: configuration) { [weak self] stage in
                    if stage == .willSubmit {
                        guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                    }
                    try await MainActor.run {
                        if stage == .willSubmit {
                            guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                            self.cancelRead()
                        }
                        try store.checkpoint(entry.id, index: 0, stage: stage)
                    }
                }
            } catch {
                if !(error is CancellationError) && (error as? AppError)?.category != .cancelled { failure = Self.failure(error) }
            }
            if !store.failed { try? store.finish(entry.id, failedIndex: failure == nil ? nil : 0, failure: failure.map(Self.storeFailure)) }
            store.end(entry.id)
            guard let self, self.activation == token else { return }
            if store.failed { self.error = .storage; self.allowed = false; return }
            if let failure, [.trust, .denied].contains(failure) { self.error = failure; self.allowed = false; return }
            await self.refresh()
        }
        return entry.id
    }
    func removeRecord(_ id: UUID) {
        guard let context else { return }
        do { try recovery.remove(id, context: context) } catch { self.error = .storage }
    }
    var canOpenCreation: Bool { supportsCreation && allowed && error == nil && !isRefreshing && !isOperating }
    func canCreate(name: String) -> Bool {
        guard canOpenCreation, let context else { return false }
        return !targets.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            && !creations.protects(name: name, context: context) && !recovery.protectsCreation(name: name, context: context)
    }
    func loadCreationResources(activation token: UUID) async throws -> VirtualMachineCreationResources {
        guard token == activation, canOpenCreation, let repository, let authorize else {
            throw AppError(category: .conflict, isRetryable: false, safeUserMessage: "")
        }
        guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
        let resources = try await repository.loadVirtualMachineCreationResources()
        try Task.checkCancellation()
        guard token == activation else { throw CancellationError() }; return resources
    }
    @discardableResult func create(_ configuration: VirtualMachineCreation, resources: VirtualMachineCreationResources,
                                   activation token: UUID) -> UUID? {
        guard token == activation else { return nil }
        guard canCreate(name: configuration.name), let context, let repository, let authorize else { error = .changed; return nil }
        let store = creations, entry: MobileVirtualMachineCreationStore.Entry
        do { entry = try store.reserve(name: configuration.name, context: context) }
        catch { self.error = .storage; return nil }
        creationNames[entry.id] = configuration.name; error = nil
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.operations[entry.id] = nil }
            var failure: Failure?
            do {
                guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                try Task.checkCancellation()
                guard self?.activation == token else { throw CancellationError() }
                _ = try await repository.createVirtualMachine(configuration, expectedResources: resources) { [weak self] stage in
                    if case .willSubmit = stage {
                        guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                    }
                    try await MainActor.run {
                        if case .willSubmit = stage {
                            guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                            self.cancelRead()
                        }
                        try store.checkpoint(entry.id, stage: stage)
                    }
                }
            } catch {
                if !(error is CancellationError) && (error as? AppError)?.category != .cancelled { failure = Self.failure(error) }
            }
            if !store.failed { try? store.finish(entry.id, failed: failure != nil) }
            store.end(entry.id)
            guard let self, self.activation == token else { return }
            if store.failed { self.error = .storage; self.allowed = false; return }
            if let failure, [.trust, .denied].contains(failure) { self.error = failure; self.allowed = false; return }
            await self.refresh()
        }
        return entry.id
    }
    func removeCreationRecord(_ id: UUID) {
        guard let context else { return }
        do { try creations.remove(id, context: context); creationNames[id] = nil } catch { self.error = .storage }
    }
    private static func storeFailure(_ failure: Failure) -> MobileVirtualMachineControlStore.Failure {
        switch failure { case .denied: .denied; case .unavailable: .unavailable; case .changed: .changed; default: .failed }
    }
    static func failure(_ error: Error) -> Failure {
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

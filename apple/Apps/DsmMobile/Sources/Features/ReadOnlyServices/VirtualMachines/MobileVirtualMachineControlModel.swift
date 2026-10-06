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
    struct NetworkConfirmation: Identifiable {
        let id = UUID()
        let activation: UUID
        let targets: [VirtualMachineNetworkState]
    }
    struct ImageConfirmation: Identifiable {
        let id = UUID()
        let activation: UUID
        let targets: [VirtualMachineImageState]
    }
    private(set) var imageInventory = VirtualMachineImageInventory(source: .official, isFrozen: false, images: [])
    private(set) var imageHasLoaded = false
    private(set) var imageIsRefreshing = false
    private(set) var imageAllowed = false
    private(set) var imageError: Failure?
    let imageRecovery: MobileVirtualMachineImageStore
    private var imageNames: [String: String] = [:]
    @ObservationIgnored private var imageReadTask: Task<Void, Never>?
    @ObservationIgnored private var imageGeneration = UUID()
    private(set) var networkInventory = VirtualMachineNetworkInventory(isFrozen: false, networks: [])
    private(set) var networkHasLoaded = false
    private(set) var networkIsRefreshing = false
    private(set) var networkAllowed = false
    private(set) var networkError: Failure?
    let networkRecovery: MobileVirtualMachineNetworkStore
    private var networkNames: [String: String] = [:]
    @ObservationIgnored private var networkReadTask: Task<Void, Never>?
    @ObservationIgnored private var networkGeneration = UUID()
    private(set) var context: String?
    private(set) var activation = UUID()
    private(set) var targets: [VirtualMachineControlState] = []
    private var submittedNames: [String: String] = [:]
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    private(set) var allowed = false
    private(set) var supportsSettings = false
    private(set) var supportsConsole = false
    private(set) var consoleSession: VirtualMachineConsoleSession?
    private var consolePreparation = UUID()
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
        imageRecovery = MobileVirtualMachineImageStore(root: root)
        networkRecovery = MobileVirtualMachineNetworkStore(root: root)
        recovery = MobileVirtualMachineControlStore(root: root)
        creations = MobileVirtualMachineCreationStore(root: root)
    }
    func configure(profile: NasProfile?, repository: DsmServiceManagementRepository?,
                   authorize: (@MainActor @Sendable () async throws -> Bool)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        guard next != context || self.repository.map(ObjectIdentifier.init) != repository.map(ObjectIdentifier.init) else {
            self.authorize = authorize; return
        }
        deactivate(); context = next; self.repository = repository; self.authorize = authorize
        recovery.reload(); creations.reload(); networkRecovery.reload(); imageRecovery.reload()
    }
    func deactivate() {
        closeConsole(); supportsConsole = false
        activation = UUID(); cancelRead(); cancelNetworkRead()
        cancelImageRead(); imageInventory = .init(source: .official, isFrozen: false, images: []); imageNames = [:]
        imageHasLoaded = false; imageAllowed = false; imageError = nil
        networkInventory = .init(isFrozen: false, networks: []); networkNames = [:]
        networkHasLoaded = false; networkAllowed = false; networkError = nil
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
    var isOperating: Bool { imageEntries.contains { imageRecovery.isExecuting($0.id) } || networkEntries.contains { networkRecovery.isExecuting($0.id) } || entries.contains { recovery.isExecuting($0.id) } || creationEntries.contains { creations.isExecuting($0.id) } }
    func refresh() async {
        guard let repository, let context, let authorize else { return }
        cancelRead(); let generation = generation, token = activation
        isRefreshing = true; error = nil; allowed = false
        let task = Task { [weak self] in
            do {
                guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                let values = try await repository.loadVirtualMachineControlStates()
                let supportsSettings = await repository.supportsVirtualMachineSettings
                let supportsConsole = await repository.supportsVirtualMachineConsole
                let supportsCreation = await repository.supportsVirtualMachineCreation
                try Task.checkCancellation()
                guard let self, self.activation == token, self.generation == generation else { return }
                self.targets = values; self.hasLoaded = true
                self.supportsSettings = supportsSettings
                self.supportsConsole = supportsConsole
                self.supportsCreation = supportsCreation
                self.recovery.reload(); self.creations.reload(); self.networkRecovery.reload(); self.imageRecovery.reload()
                do { try self.recovery.resolve(values, context: context) } catch { self.error = .storage }
                if self.recovery.failed || self.creations.failed || self.networkRecovery.failed { self.error = .storage }
                if !self.recovery.failed && !self.creations.failed && !self.networkRecovery.failed {
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
                self.closeConsole()
                if !(error is CancellationError) { self.error = Self.failure(error) }
            }
        }
        readTask = task; await task.value
    }
    func canOpenConsole(id: String) -> Bool {
        guard supportsConsole, allowed, error == nil, !isRefreshing, !isOperating, let context,
              let target = targets.first(where: { $0.id == id }), target.status == "running" else { return false }
        return !recovery.protects([target], context: context) && !creations.protects(name: target.name, id: target.id, context: context)
            && !networkRecovery.protects(guestID: id, context: context)
    }
    func openConsole(_ target: VirtualMachineControlState, activation token: UUID) async throws -> VirtualMachineConsoleSession {
        guard token == activation, canOpenConsole(id: target.id), targets.contains(target), let repository, let authorize else {
            throw AppError(category: .conflict, isRetryable: false, safeUserMessage: "")
        }
        closeConsole(); let preparation = consolePreparation
        guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
        try Task.checkCancellation()
        guard token == activation, preparation == consolePreparation, canOpenConsole(id: target.id) else { throw CancellationError() }
        let session = try await repository.openVirtualMachineConsole(target)
        guard !Task.isCancelled, token == activation, preparation == consolePreparation, canOpenConsole(id: target.id) else {
            await session.transport.close(); throw CancellationError()
        }
        consoleSession = session
        return session
    }
    func closeConsole() {
        consolePreparation = UUID()
        let old = consoleSession; consoleSession = nil
        if let old { Task { await old.transport.close() } }
    }

    func canPerform(ids: Set<String>, action: VirtualMachinePowerAction) -> Bool {
        canPerform(ids: ids, kind: .init(action))
    }
    func canPerform(ids: Set<String>, kind: MobileVirtualMachineControlStore.Kind) -> Bool {
        guard kind != .edit, let context, allowed, error == nil, !isRefreshing, !isOperating, !ids.isEmpty else { return false }
        let selected = targets.filter { ids.contains($0.id) }
        return selected.count == ids.count && selected.allSatisfy(kind.supports)
            && !recovery.protects(selected, context: context)
            && !selected.contains { creations.protects(name: $0.name, id: $0.id, context: context) || networkRecovery.protects(guestID: $0.id, context: context) }
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
            && !networkRecovery.protects(guestID: target.id, context: context)
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
    var canOpenCreation: Bool { supportsCreation && allowed && error == nil && !isRefreshing && !isOperating && !networkRecovery.failed && !imageRecovery.failed }
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
        guard token == activation, let context else { throw CancellationError() }
        return .init(storages: resources.storages,
                     networks: resources.networks.filter { !networkRecovery.protects(networkID: $0.id, context: context) },
                     images: resources.images.filter { !imageRecovery.protects(imageID: $0.id, context: context) },
                     imagesAvailable: resources.imagesAvailable, networksAvailable: resources.networksAvailable)
    }
    @discardableResult func create(_ configuration: VirtualMachineCreation, resources: VirtualMachineCreationResources,
                                   activation token: UUID) -> UUID? {
        guard token == activation else { return nil }
        guard canCreate(name: configuration.name), let context, let repository, let authorize,
              configuration.bootImageID.map({ !imageRecovery.protects(imageID: $0, context: context) }) ?? true,
              configuration.networkID.isEmpty || !networkRecovery.protects(networkID: configuration.networkID, context: context) else { error = .changed; return nil }
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
    var networkEntries: [MobileVirtualMachineNetworkStore.Entry] { networkRecovery.entries.filter { $0.context == context }.reversed() }
    func name(for item: MobileVirtualMachineNetworkStore.Item) -> String? {
        networkNames[item.identity + item.name] ?? networkInventory.networks.first(where: item.matches)?.name
    }
    func cancelNetworkRead() {
        networkGeneration = UUID(); networkReadTask?.cancel(); networkReadTask = nil; networkIsRefreshing = false
    }
    func refreshNetworks() async {
        guard let repository, let context, let authorize else { return }
        cancelNetworkRead(); let generation = networkGeneration, token = activation
        networkIsRefreshing = true; networkAllowed = false; networkError = nil
        let task = Task { [weak self] in
            do {
                guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                let inventory = try await repository.loadVirtualMachineNetworks()
                let supported = await repository.supportsVirtualMachineNetworks
                try Task.checkCancellation()
                guard let self, self.activation == token, self.networkGeneration == generation else { return }
                self.networkInventory = inventory; self.networkHasLoaded = true
                self.networkRecovery.reload(); self.recovery.reload(); self.creations.reload()
                try self.networkRecovery.resolve(inventory, context: context)
                if self.networkRecovery.failed || self.recovery.failed || self.creations.failed { self.networkError = .storage }
                self.networkAllowed = supported && self.networkError == nil && !inventory.isFrozen
                self.networkIsRefreshing = false
            } catch {
                guard let self, self.activation == token, self.networkGeneration == generation else { return }
                self.networkIsRefreshing = false; self.networkHasLoaded = true; self.networkAllowed = false
                if !(error is CancellationError) { self.networkError = Self.failure(error) }
                if self.networkRecovery.failed { self.networkError = .storage }
            }
        }
        networkReadTask = task; await task.value
    }
    func canManageNetworks(ids: Set<String>) -> Bool {
        guard let context, networkAllowed, networkError == nil, !networkIsRefreshing, !isOperating,
              !ids.isEmpty, !recovery.failed, !creations.failed else { return false }
        let selected = networkInventory.networks.filter { ids.contains($0.id) }
        return selected.count == ids.count && selected.allSatisfy { network in
            !networkRecovery.protects(networkID: network.id, context: context)
                && !creations.protectsResource(kind: "network", id: network.id, context: context)
                && !network.guests.contains { guest in
                    let target = VirtualMachineControlState(id: guest.id, name: guest.name, status: guest.isRunning ? "running" : "shutdown",
                        availableActions: [], allowsDeletion: false)
                    return recovery.protects([target], context: context) || creations.protects(name: guest.name, id: guest.id, context: context)
                        || networkRecovery.protects(guestID: guest.id, context: context)
                }
        }
    }
    func canRenameNetwork(_ target: VirtualMachineNetworkState, name: String) -> Bool {
        guard let context, VirtualMachineNetworkState.isValidName(name), target.name != name,
              canManageNetworks(ids: [target.id]), networkInventory.networks.contains(target) else { return false }
        return !networkInventory.networks.contains { $0.id != target.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
            && !networkRecovery.protects(name: name, context: context)
    }
    func networkConfirmation(ids: Set<String>) -> NetworkConfirmation? {
        guard canManageNetworks(ids: ids) else { return nil }
        return .init(activation: activation, targets: networkInventory.networks.filter { ids.contains($0.id) })
    }
    @discardableResult func deleteNetworks(_ confirmation: NetworkConfirmation) -> UUID? {
        performNetworks(confirmation.targets, newName: nil, activation: confirmation.activation)
    }
    @discardableResult func renameNetwork(_ target: VirtualMachineNetworkState, name: String, activation: UUID) -> UUID? {
        guard canRenameNetwork(target, name: name) else { return nil }
        return performNetworks([target], newName: name, activation: activation)
    }
    private func performNetworks(_ selected: [VirtualMachineNetworkState], newName: String?, activation token: UUID) -> UUID? {
        guard token == activation else { return nil }
        guard canManageNetworks(ids: Set(selected.map(\.id))), selected.allSatisfy({ networkInventory.networks.contains($0) }),
              let repository, let context, let authorize else { networkError = .changed; return nil }
        let store = networkRecovery, entry: MobileVirtualMachineNetworkStore.Entry
        do { entry = try store.reserve(selected, newName: newName, context: context) }
        catch { networkError = .storage; return nil }
        for target in selected { networkNames[MobileVirtualMachineNetworkStore.digest(target.id) + MobileVirtualMachineNetworkStore.digest(target.name)] = target.name }
        networkError = nil
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.operations[entry.id] = nil }
            var failedIndex: Int?, failure: Failure?, canSubmit = false
            do {
                guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                let current = try await repository.loadVirtualMachineNetworks()
                try Task.checkCancellation()
                guard self?.activation == token else { throw CancellationError() }
                guard !current.isFrozen, selected.allSatisfy({ current.networks.contains($0) }) else {
                    throw AppError(category: .conflict, isRetryable: false, safeUserMessage: "")
                }
                canSubmit = true
            } catch {
                if !(error is CancellationError) && (error as? AppError)?.category != .cancelled { failedIndex = 0; failure = Self.failure(error) }
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
                                self.cancelNetworkRead()
                            }
                            try store.checkpoint(entry.id, index: index, stage: stage)
                        }
                    }
                    if let newName { try await repository.updateVirtualMachineNetwork(target, configuration: .init(name: newName), observer: observer) }
                    else { try await repository.deleteVirtualMachineNetwork(target, observer: observer) }
                } catch {
                    if !(error is CancellationError) && (error as? AppError)?.category != .cancelled { failedIndex = index; failure = Self.failure(error) }
                    break
                }
            }
            if !store.failed { try? store.finish(entry.id, failedIndex: failedIndex, failure: failure.map(Self.storeFailure)) }
            store.end(entry.id)
            guard let self, self.activation == token else { return }
            if store.failed { self.networkError = .storage; self.networkAllowed = false; return }
            if let failure, [.trust, .denied].contains(failure) { self.networkError = failure; self.networkAllowed = false; return }
            await self.refreshNetworks()
        }
        return entry.id
    }
    func removeNetworkRecord(_ id: UUID) {
        guard let context else { return }
        do { try networkRecovery.remove(id, context: context) } catch { networkError = .storage }
    }
    var imageEntries: [MobileVirtualMachineImageStore.Entry] { imageRecovery.entries.filter { $0.context == context }.reversed() }
    func name(for item: MobileVirtualMachineImageStore.Item) -> String? {
        imageNames[item.identity + item.snapshot] ?? imageInventory.images.first(where: item.matches)?.name
    }
    func cancelImageRead() {
        imageGeneration = UUID(); imageReadTask?.cancel(); imageReadTask = nil; imageIsRefreshing = false
    }
    func refreshImages() async {
        guard let repository, let context, let authorize else { return }
        cancelImageRead(); let generation = imageGeneration, token = activation
        imageIsRefreshing = true; imageAllowed = false; imageError = nil
        let task = Task { [weak self] in
            do {
                guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                let inventory = try await repository.loadVirtualMachineImages()
                try Task.checkCancellation()
                guard let self, self.activation == token, self.imageGeneration == generation else { return }
                self.imageInventory = inventory; self.imageHasLoaded = true
                self.imageRecovery.reload(); self.creations.reload()
                try self.imageRecovery.resolve(inventory, context: context)
                if self.imageRecovery.failed || self.creations.failed { self.imageError = .storage }
                self.imageAllowed = self.imageError == nil && !inventory.isFrozen
                self.imageIsRefreshing = false
            } catch {
                guard let self, self.activation == token, self.imageGeneration == generation else { return }
                self.imageIsRefreshing = false; self.imageHasLoaded = true; self.imageAllowed = false
                if !(error is CancellationError) { self.imageError = Self.failure(error) }
                if self.imageRecovery.failed { self.imageError = .storage }
            }
        }
        imageReadTask = task; await task.value
    }
    func canDeleteImages(ids: Set<String>) -> Bool {
        guard let context, imageAllowed, imageError == nil, !imageIsRefreshing, !isOperating,
              !ids.isEmpty, !creations.failed, !imageRecovery.failed else { return false }
        let selected = imageInventory.images.filter { ids.contains($0.id) }
        return selected.count == ids.count && selected.allSatisfy { image in
            image.name != nil && image.canDelete && !imageRecovery.protects(imageID: image.id, context: context)
                && !creations.protectsResource(kind: "image", id: image.id, context: context)
        }
    }
    func imageConfirmation(ids: Set<String>) -> ImageConfirmation? {
        guard canDeleteImages(ids: ids) else { return nil }
        return .init(activation: activation, targets: imageInventory.images.filter { ids.contains($0.id) })
    }
    @discardableResult func deleteImages(_ confirmation: ImageConfirmation) -> UUID? {
        guard confirmation.activation == activation else { return nil }
        let selected = confirmation.targets, token = activation
        guard canDeleteImages(ids: Set(selected.map(\.id))), selected.allSatisfy({ imageInventory.images.contains($0) }),
              let repository, let context, let authorize else { imageError = .changed; return nil }
        let store = imageRecovery, entry: MobileVirtualMachineImageStore.Entry
        do { entry = try store.reserve(selected, context: context) }
        catch { imageError = .storage; return nil }
        for (target, item) in zip(selected, entry.items) { imageNames[item.identity + item.snapshot] = target.name }
        imageError = nil
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.operations[entry.id] = nil }
            var failedIndex: Int?, failure: Failure?, canSubmit = false
            do {
                guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                let current = try await repository.loadVirtualMachineImages()
                try Task.checkCancellation()
                guard self?.activation == token else { throw CancellationError() }
                guard !current.isFrozen, selected.allSatisfy({ current.images.contains($0) }) else {
                    throw AppError(category: .conflict, isRetryable: false, safeUserMessage: "")
                }
                canSubmit = true
            } catch {
                if !(error is CancellationError) && (error as? AppError)?.category != .cancelled { failedIndex = 0; failure = Self.failure(error) }
            }
            for (index, target) in selected.enumerated() where canSubmit && failure == nil {
                do {
                    try Task.checkCancellation()
                    guard self?.activation == token else { throw CancellationError() }
                    try await repository.deleteVirtualMachineImage(target) { [weak self] stage in
                        if stage == .willSubmit {
                            guard try await authorize() else { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                        }
                        try await MainActor.run {
                            if stage == .willSubmit {
                                guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                                self.cancelImageRead()
                            }
                            try store.checkpoint(entry.id, index: index, stage: stage)
                        }
                    }
                } catch {
                    if !(error is CancellationError) && (error as? AppError)?.category != .cancelled { failedIndex = index; failure = Self.failure(error) }
                    break
                }
            }
            if !store.failed { try? store.finish(entry.id, failedIndex: failedIndex, failure: failure.map(Self.storeFailure)) }
            store.end(entry.id)
            guard let self, self.activation == token else { return }
            if store.failed { self.imageError = .storage; self.imageAllowed = false; return }
            if let failure, [.trust, .denied].contains(failure) { self.imageError = failure; self.imageAllowed = false; return }
            await self.refreshImages()
        }
        return entry.id
    }
    func removeImageRecord(_ id: UUID) {
        guard let context else { return }
        do { try imageRecovery.remove(id, context: context) } catch { imageError = .storage }
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

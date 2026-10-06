import DsmCore
import DsmNetwork
import Foundation
import Observation

@MainActor @Observable
final class MobileContainerImagePullModel {
    enum Failure: Equatable { case read, denied, unavailable, changed, storage, trust }
    struct Confirmation: Identifiable {
        let id = UUID()
        let activation: UUID
        let request: ContainerImagePullRequest
    }
    private(set) var context: String?
    private(set) var activation = UUID()
    private(set) var available = false
    private(set) var allowed = false
    private(set) var isRefreshing = false
    private(set) var error: Failure?
    private(set) var results: [ContainerRegistryImage] = []
    private(set) var hasSearched = false
    private(set) var isSearching = false
    private(set) var searchError: Failure?
    private(set) var selectedImage: ContainerRegistryImage?
    private(set) var tags: [String] = []
    private(set) var isLoadingTags = false
    private(set) var tagsError: Failure?
    private(set) var names: [UUID: String] = [:]
    let recovery: MobileContainerImagePullStore
    @ObservationIgnored private var repository: DsmServiceManagementRepository?
    @ObservationIgnored private var authorize: (@MainActor @Sendable () async throws -> Bool)?
    @ObservationIgnored private var deletionRecovery: MobileContainerImageDeletionStore?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var tagTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var searchGeneration = UUID()
    @ObservationIgnored private var tagGeneration = UUID()
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]

    init(root: URL? = nil) { recovery = MobileContainerImagePullStore(root: root) }
    func configure(profile: NasProfile?, repository: DsmServiceManagementRepository?,
                   deletionRecovery: MobileContainerImageDeletionStore? = nil,
                   authorize: (@MainActor @Sendable () async throws -> Bool)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        guard next != context || self.repository.map(ObjectIdentifier.init) != repository.map(ObjectIdentifier.init) else {
            self.authorize = authorize; self.deletionRecovery = deletionRecovery; return
        }
        deactivate(); context = next; self.repository = repository; self.authorize = authorize; recovery.reload()
        self.deletionRecovery = deletionRecovery
    }
    func deactivate() {
        activation = UUID(); cancelRead(); searchTask?.cancel(); tagTask?.cancel()
        searchGeneration = UUID(); tagGeneration = UUID()
        for task in operations.values { task.cancel() }
        context = nil; repository = nil; authorize = nil; deletionRecovery = nil; available = false; allowed = false; error = nil
        results = []; hasSearched = false; isSearching = false; searchError = nil
        selectedImage = nil; tags = []; isLoadingTags = false; tagsError = nil; names = [:]
    }
    func cancelRead() { generation = UUID(); readTask?.cancel(); readTask = nil; isRefreshing = false }
    func cancelVisibleReads() {
        cancelRead(); searchTask?.cancel(); tagTask?.cancel(); searchGeneration = UUID(); tagGeneration = UUID()
        isSearching = false; isLoadingTags = false
    }
    var entries: [MobileContainerImagePullStore.Entry] { recovery.entries.filter { $0.context == context }.reversed() }
    var isOperating: Bool { entries.contains { recovery.isExecuting($0.id) } }
    var readyCount: Int { entries.filter { $0.phase == .ready }.count }
    var hasPollableTasks: Bool {
        allowed && !recovery.failed && error != .trust && error != .denied && entries.contains {
            $0.isProtected && $0.phase != .prepared && $0.recovery.taskID != nil
        }
    }
    func refresh() async {
        guard let repository, let authorize else { return }
        cancelRead(); let token = activation, generation = generation
        isRefreshing = true; error = nil
        let task = Task { [weak self] in
            do {
                guard try await authorize() else { throw Self.denied() }
                let available = await repository.canStartContainerImagePull()
                try Task.checkCancellation()
                guard let self, self.activation == token, self.generation == generation else { return }
                self.available = available; self.allowed = true; self.recovery.reload()
                guard !self.recovery.failed, self.deletionRecovery?.failed != true else {
                    self.error = .storage; self.allowed = false; self.isRefreshing = false; return
                }
                for entry in self.entries where entry.isProtected && entry.phase != .prepared && !self.recovery.isExecuting(entry.id) {
                    guard try await authorize() else { throw Self.denied() }
                    try Task.checkCancellation()
                    guard self.activation == token, self.generation == generation else { return }
                    let progress = try await repository.restoreContainerImagePull(entry.recovery)
                    try Task.checkCancellation()
                    guard self.activation == token, self.generation == generation else { return }
                    try self.recovery.update(progress); self.remember(progress)
                    if [.permission, .authentication].contains(progress.outcome.errorCategory) { throw Self.denied() }
                }
                self.isRefreshing = false
            } catch {
                guard let self, self.activation == token, self.generation == generation else { return }
                self.isRefreshing = false
                if !(error is CancellationError) { self.error = self.recovery.failed ? .storage : Self.failure(error) }
                if self.error == .denied || self.error == .trust || self.error == .storage { self.allowed = false }
            }
        }
        readTask = task; await task.value
    }
    func search(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let repository, let authorize else { return }
        searchTask?.cancel(); searchGeneration = UUID()
        let token = activation, generation = searchGeneration
        results = []; hasSearched = true; isSearching = true; searchError = nil
        let task = Task { [weak self] in
            do {
                guard try await authorize() else { throw Self.denied() }
                let values = try await repository.searchContainerImages(query: query)
                try Task.checkCancellation()
                guard let self, self.activation == token, self.searchGeneration == generation else { return }
                self.results = values; self.isSearching = false
            } catch {
                guard let self, self.activation == token, self.searchGeneration == generation else { return }
                self.isSearching = false
                if !(error is CancellationError) { self.searchError = Self.failure(error) }
            }
        }
        searchTask = task; await task.value
    }
    func select(_ image: ContainerRegistryImage) async {
        guard let repository, let authorize else { return }
        tagTask?.cancel(); tagGeneration = UUID()
        let token = activation, generation = tagGeneration
        selectedImage = image; tags = []; isLoadingTags = true; tagsError = nil
        let task = Task { [weak self] in
            do {
                guard try await authorize() else { throw Self.denied() }
                let values = try await repository.loadContainerImageTags(repository: image.name)
                try Task.checkCancellation()
                guard let self, self.activation == token, self.tagGeneration == generation else { return }
                self.tags = values; self.isLoadingTags = false
            } catch {
                guard let self, self.activation == token, self.tagGeneration == generation else { return }
                self.isLoadingTags = false
                if !(error is CancellationError) { self.tagsError = Self.failure(error) }
            }
        }
        tagTask = task; await task.value
    }
    func canDownload(repository: String, tag: String) -> Bool {
        guard let context, allowed, available, !isOperating, !isRefreshing, !recovery.failed,
              error != .trust, error != .denied, error != .storage,
              selectedImage?.name == repository, !isLoadingTags, tagsError == nil, tags.contains(tag),
              ContainerImagePullRequest.isValidTarget(repository: repository, tag: tag) else { return false }
        return !recovery.protects(repository: repository, tag: tag, context: context)
            && deletionRecovery?.protectsPull(repository: repository, tag: tag, context: context) != true
    }
    func hasPendingDeletion(repository: String, tag: String) -> Bool {
        guard let context, deletionRecovery?.failed != true else { return false }
        return deletionRecovery?.protectsPull(repository: repository, tag: tag, context: context) == true
    }
    func confirmation(repository: String, tag: String) -> Confirmation? {
        guard canDownload(repository: repository, tag: tag) else { return nil }
        return .init(activation: activation, request: .init(repository: repository, tag: tag, isConfirmed: true))
    }
    @discardableResult func perform(_ confirmation: Confirmation) -> UUID? {
        let request = confirmation.request
        guard confirmation.activation == activation, canDownload(repository: request.repository, tag: request.tag),
              let repository, let context, let authorize else { return nil }
        let token = activation, store = recovery, entry: MobileContainerImagePullStore.Entry
        do { entry = try store.reserve(request, context: context) }
        catch { self.error = .storage; return nil }
        names[entry.id] = request.referenceKey; error = nil
        operations[entry.id] = Task { [weak self] in
            defer { store.end(entry.id); self?.operations[entry.id] = nil }
            do {
                guard try await authorize() else { throw Self.denied() }
                guard self?.activation == token, !Task.isCancelled else { throw CancellationError() }
                let result = try await repository.startContainerImagePull(request) { [weak self] checkpoint in
                    if case .willSubmit = checkpoint {
                        guard try await authorize() else { throw Self.denied() }
                    }
                    try await MainActor.run {
                        if case .willSubmit(let recovery) = checkpoint {
                            guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                            guard self.deletionRecovery?.protectsPull(recovery, context: context) != true else {
                                throw AppError(category: .conflict, isRetryable: false, safeUserMessage: "")
                            }
                            self.cancelRead()
                        }
                        // 已发出的旧账号回执只能落在原记录中。
                        try store.checkpoint(entry.id, checkpoint)
                    }
                }
                try store.update(result)
                guard let self, self.activation == token else { return }
                self.remember(result)
                if [.permission, .authentication].contains(result.outcome.errorCategory) { self.error = .denied; self.allowed = false }
            } catch {
                let failure = Self.failure(error)
                if !store.failed {
                    try? store.finish(entry.id, failure: error is CancellationError || (error as? AppError)?.category == .cancelled ? nil : Self.storeFailure(failure))
                }
                guard let self, self.activation == token else { return }
                if store.failed { self.error = .storage; self.allowed = false }
                else if !(error is CancellationError) {
                    self.error = failure
                    if failure == .denied || failure == .trust { self.allowed = false }
                }
            }
        }
        return entry.id
    }
    func waitForOperation(_ id: UUID) async { await operations[id]?.value }
    func removeRecord(_ id: UUID) {
        guard let context else { return }
        do { try recovery.remove(id, context: context); names[id] = nil } catch { self.error = .storage }
    }
    private func remember(_ progress: ContainerImagePullProgress) {
        if !progress.repository.isEmpty { names[progress.id] = progress.referenceKey }
    }
    nonisolated private static func denied() -> AppError { .init(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
    private static func storeFailure(_ failure: Failure) -> MobileContainerImagePullStore.Failure {
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

import DsmCore
import DsmNetwork
import Foundation
import Observation

@MainActor
@Observable
final class MobileDownloadRSSModel {
    let recovery: MobileDownloadRSSStore
    private(set) var context = ""
    private(set) var activation = UUID()
    private(set) var sites: [DownloadRSSSite]?
    private(set) var feeds: [DownloadRSSFeed]?
    private(set) var feedSiteID: Int?
    private(set) var supported: Bool?
    private(set) var isLoading = false
    private(set) var isLoadingFeeds = false
    private(set) var isUpdating = false
    var errorKey: String?
    var feedErrorKey: String?
    @ObservationIgnored private var repository: DsmServiceManagementRepository?
    @ObservationIgnored private var readGeneration: UInt64 = 0
    @ObservationIgnored private var feedGeneration: UInt64 = 0
    @ObservationIgnored private(set) var operation: Task<Void, Never>?

    init(root: URL?) { recovery = MobileDownloadRSSStore(root: root) }
    var entries: [MobileDownloadRSSStore.Entry] { recovery.entries.filter { $0.context == context } }
    func entry(for site: DownloadRSSSite) -> MobileDownloadRSSStore.Entry? { entries.last { $0.siteID == site.id } }
    func canUpdate(_ site: DownloadRSSSite) -> Bool {
        repository != nil && supported == true && !isLoading && !isUpdating && !recovery.failed && !site.isUpdating
            && entry(for: site)?.unfinished != true && sites?.contains(site) == true
    }

    func configure(profile: NasProfile?, repository: DsmServiceManagementRepository?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier } ?? ""
        guard next != context || repository.map(ObjectIdentifier.init) != self.repository.map(ObjectIdentifier.init) else { return }
        activation = UUID(); readGeneration &+= 1; feedGeneration &+= 1; operation?.cancel(); operation = nil
        context = next; self.repository = repository; sites = nil; feeds = nil; feedSiteID = nil; supported = nil
        isLoading = false; isLoadingFeeds = false; isUpdating = false; errorKey = nil; feedErrorKey = nil
    }

    func load() async {
        guard !isUpdating, let repository, !context.isEmpty else { return }
        readGeneration &+= 1
        let generation = readGeneration, token = activation
        isLoading = true; errorKey = nil
        defer { if token == activation, generation == readGeneration { isLoading = false } }
        do {
            let supported = await repository.supportsDownloadRSS
            guard token == activation, generation == readGeneration, !Task.isCancelled else { return }
            self.supported = supported
            guard supported else { errorKey = "download.rss.unsupported"; return }
            let current = try await repository.loadDownloadRSSSites()
            guard token == activation, generation == readGeneration, !Task.isCancelled else { return }
            sites = current; try reconcile(current)
        } catch {
            guard token == activation, generation == readGeneration, !(error is CancellationError) else { return }
            errorKey = recovery.failed ? "download.rss.storage-error" : Self.errorKey(error)
        }
    }

    func loadFeeds(_ site: DownloadRSSSite) async {
        guard let repository, !context.isEmpty else { return }
        feedGeneration &+= 1
        let generation = feedGeneration, token = activation
        if feedSiteID != site.id { feeds = nil }
        feedSiteID = site.id; isLoadingFeeds = true; feedErrorKey = nil
        defer { if token == activation, generation == feedGeneration { isLoadingFeeds = false } }
        do {
            let current = try await repository.loadDownloadRSSSites()
            guard let original = current.first(where: { $0.id == site.id }), original.identityDigest == site.identityDigest else {
                throw AppError(category: .conflict, isRetryable: true, safeUserMessage: "")
            }
            let result = try await repository.loadDownloadRSSFeeds(siteID: site.id)
            guard token == activation, generation == feedGeneration, !Task.isCancelled else { return }
            sites = current; feeds = result; try reconcile(current)
        } catch {
            guard token == activation, generation == feedGeneration, !(error is CancellationError) else { return }
            feedErrorKey = recovery.failed ? "download.rss.storage-error" : Self.errorKey(error)
            if (error as? AppError)?.category == .conflict { feeds = nil }
        }
    }

    func update(_ site: DownloadRSSSite, activation expected: UUID) {
        guard expected == activation, canUpdate(site), let repository else { return }
        let token = activation, store = recovery
        let entry = MobileDownloadRSSStore.Entry(id: UUID(), context: context, siteID: site.id,
            identityDigest: site.identityDigest, baseline: site.lastUpdate, createdAt: Date())
        isUpdating = true; errorKey = nil; feedErrorKey = nil; readGeneration &+= 1; isLoading = false
        operation = Task { [weak self] in
            defer { if let self, self.activation == token { self.isUpdating = false; self.operation = nil } }
            do {
                let receipt = try await repository.refreshDownloadRSSSite(site) { [weak self] in
                    try await MainActor.run {
                        guard let self, self.activation == token, !Task.isCancelled else { throw CancellationError() }
                        try store.reserve(entry)
                    }
                }
                let phase: MobileDownloadRSSStore.Phase?
                switch receipt {
                case .accepted: phase = .accepted
                case .unknown: phase = nil
                case .denied: phase = .denied
                case .rejected: phase = .rejected
                case .cancelledBeforeSubmission: phase = .cancelled
                }
                if let phase { try store.progress(entry.id, phase: phase) }
                guard let self, self.activation == token, !Task.isCancelled else { return }
                let current = try await repository.loadDownloadRSSSites()
                guard self.activation == token, !Task.isCancelled else { return }
                self.sites = current; try self.reconcile(current)
                if let currentSite = current.first(where: { $0.id == site.id && $0.identityDigest == site.identityDigest }), self.feedSiteID == site.id {
                    await self.loadFeeds(currentSite)
                }
            } catch {
                guard let self, self.activation == token, !(error is CancellationError) else { return }
                self.errorKey = store.failed ? "download.rss.storage-error" : Self.errorKey(error, updating: true)
            }
        }
    }

    private func reconcile(_ current: [DownloadRSSSite]) throws {
        for entry in entries where entry.unfinished {
            if let site = current.first(where: { $0.id == entry.siteID }), site.identityDigest == entry.identityDigest,
               site.lastUpdate > entry.baseline, !site.isUpdating { try recovery.progress(entry.id, phase: .updated) }
        }
    }

    static func errorKey(_ error: Error, updating: Bool = false) -> String {
        switch (error as? AppError)?.category {
        case .permissionDenied: updating ? "download.rss.permission" : "download.rss.read-permission"
        case .conflict: "download.rss.changed"
        case .apiUnavailable: "download.rss.unsupported"
        default: "download.rss.load-error"
        }
    }
}

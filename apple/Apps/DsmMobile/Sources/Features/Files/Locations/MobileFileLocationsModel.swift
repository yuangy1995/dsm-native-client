import DsmCore
import DsmNetwork
import Foundation
import Observation

protocol MobileFileLocationBrowsing: AnyObject, Sendable {
    var profileID: UUID { get }
    func listFavoritesPage(offset: Int, limit: Int) async throws -> FileFavoritePage
    func listVirtualFolders(offset: Int, limit: Int) async throws -> FileVirtualFolderPage
    func discoverRecycleLocations() async throws -> FileRecycleDiscoveryResult
}

extension DsmFileRepository: MobileFileLocationBrowsing {}

@MainActor
@Observable
final class MobileFileLocationsModel {
    private struct PendingRefresh {
        let profileID: UUID
        let generation: Int
        let baseline: MobileFileLocationsProfileState
    }

    private enum SnapshotResult<Value: Sendable>: Sendable {
        case success(Value)
        case failure
    }

    static let pageSize = 200
    static let maximumRecentLocationCount = 12

    private(set) var activeProfileID: UUID?
    private(set) var profiles: [UUID: MobileFileLocationsProfileState] = [:]
    @ObservationIgnored private var repositoryIdentity: ObjectIdentifier?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingRefresh: PendingRefresh?

    var state: MobileFileLocationsProfileState {
        guard let activeProfileID else { return MobileFileLocationsProfileState() }
        return profiles[activeProfileID] ?? MobileFileLocationsProfileState()
    }

    var canOpenLocations: Bool { activeProfileID != nil && repositoryIdentity != nil }

    func activate(profileID: UUID?, repository: (any MobileFileLocationBrowsing)?) {
        cancelRequest()
        activeProfileID = profileID
        repositoryIdentity = repository.map { ObjectIdentifier($0) }
        guard let profileID,
              let repository,
              repository.profileID == profileID else {
            repositoryIdentity = nil
            return
        }
        if profiles[profileID] == nil {
            profiles[profileID] = MobileFileLocationsProfileState()
        }
    }

    func loadIfNeeded(repository: any MobileFileLocationBrowsing) async {
        guard !state.hasLoadedSnapshot else { return }
        await refresh(repository: repository)
    }

    func deactivate() {
        cancelRequest()
        repositoryIdentity = nil
        activeProfileID = nil
    }

    func purge(profileID: UUID) {
        if activeProfileID == profileID {
            deactivate()
        }
        profiles.removeValue(forKey: profileID)
    }

    func refresh(repository: any MobileFileLocationBrowsing) async {
        guard isActive(repository) else { return }
        let profileID = repository.profileID
        let identity = ObjectIdentifier(repository)
        let baseline = state
        let requestGeneration = beginRequest { profile in
            profile.favorites.isRefreshing = Self.hasBaseline(profile.favorites.pageState)
            profile.remote.isRefreshing = Self.hasBaseline(profile.remote.pageState)
            profile.recycle.isRefreshing = Self.hasBaseline(profile.recycle.pageState)
            profile.favorites.hasRefreshError = false
            profile.remote.hasRefreshError = false
            profile.recycle.hasRefreshError = false
            if !profile.favorites.isRefreshing { profile.favorites.pageState = .loading }
            if !profile.remote.isRefreshing { profile.remote.pageState = .loading }
            if !profile.recycle.isRefreshing { profile.recycle.pageState = .loading }
        }
        pendingRefresh = PendingRefresh(
            profileID: profileID,
            generation: requestGeneration,
            baseline: baseline
        )
        let task = Task { [weak self] in
            let favorites = await Self.favoriteResult(repository: repository)
            guard !Task.isCancelled else { return }
            let remote = await Self.remoteResult(repository: repository)
            guard !Task.isCancelled else { return }
            let recycle = await Self.recycleResult(repository: repository)
            guard !Task.isCancelled else { return }
            self?.applyRefresh(
                favorites: favorites,
                remote: remote,
                recycle: recycle,
                baseline: baseline,
                profileID: profileID,
                repositoryIdentity: identity,
                generation: requestGeneration
            )
        }
        requestTask = task
        await task.value
    }

    func recordSuccessfulDirectory(
        profileID: UUID,
        path: String,
        source: MobileFileLocationSource
    ) {
        guard activeProfileID == profileID,
              source.recordsRecentLocation,
              Self.isCanonicalDirectoryPath(path),
              !Self.containsRecycleSegment(path) else { return }
        var profile = profiles[profileID] ?? MobileFileLocationsProfileState()
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard !name.isEmpty else { return }
        profile.recent.removeAll { $0.path == path }
        profile.recent.insert(MobileRecentFileLocation(name: name, path: path), at: 0)
        if profile.recent.count > Self.maximumRecentLocationCount {
            profile.recent.removeLast(profile.recent.count - Self.maximumRecentLocationCount)
        }
        profiles[profileID] = profile
    }

    func selectSource(_ source: MobileFileLocationSource) {
        updateActive { $0.selectedSource = source }
    }

    func cancelRequest() {
        restorePendingRefreshIfCurrent()
        requestTask?.cancel()
        requestTask = nil
        generation &+= 1
        updateActive {
            $0.favorites.isRefreshing = false
            $0.remote.isRefreshing = false
            $0.recycle.isRefreshing = false
        }
    }

    private func applyRefresh(
        favorites: SnapshotResult<FileFavoritePage>,
        remote: SnapshotResult<FileVirtualFolderPage>,
        recycle: SnapshotResult<FileRecycleDiscoveryResult>,
        baseline: MobileFileLocationsProfileState,
        profileID: UUID,
        repositoryIdentity identity: ObjectIdentifier,
        generation requestGeneration: Int
    ) {
        guard isCurrent(
            profileID: profileID,
            repositoryIdentity: identity,
            generation: requestGeneration
        ) else { return }
        pendingRefresh = nil
        updateActive { profile in
            switch favorites {
            case .success(let page):
                profile.favorites = MobileFileFavoriteSnapshot(
                    locations: page.locations,
                    pageState: page.locations.isEmpty ? .empty : .content,
                    isRefreshing: false,
                    isTruncated: page.isTruncated || page.hasMore,
                    hasRefreshError: false
                )
            case .failure:
                profile.favorites = baseline.favorites
                profile.favorites.isRefreshing = false
                if !Self.hasBaseline(profile.favorites.pageState) {
                    profile.favorites.pageState = .error
                } else {
                    profile.favorites.hasRefreshError = true
                }
            }

            switch remote {
            case .success(let page):
                profile.remote = MobileFileRemoteSnapshot(
                    folders: page.folders,
                    pageState: page.folders.isEmpty ? .empty : .content,
                    isRefreshing: false,
                    isTruncated: page.isTruncated || page.hasMore,
                    unavailableProtocols: page.unavailableProtocols,
                    hasRefreshError: false
                )
            case .failure:
                profile.remote = baseline.remote
                profile.remote.isRefreshing = false
                if !Self.hasBaseline(profile.remote.pageState) {
                    profile.remote.pageState = .error
                } else {
                    profile.remote.hasRefreshError = true
                }
            }

            switch recycle {
            case .success(let result) where result.profileID == profileID:
                profile.recycle = MobileFileRecycleSnapshot(
                    locations: result.locations,
                    pageState: result.locations.isEmpty ? .empty : .content,
                    isRefreshing: false,
                    isTruncated: result.isTruncated,
                    permissionDeniedShareCount: result.permissionDeniedShareCount,
                    hasRefreshError: false
                )
            case .success, .failure:
                profile.recycle = baseline.recycle
                profile.recycle.isRefreshing = false
                if !Self.hasBaseline(profile.recycle.pageState) {
                    profile.recycle.pageState = .error
                } else {
                    profile.recycle.hasRefreshError = true
                }
            }
            profile.hasLoadedSnapshot = true
        }
    }

    private func beginRequest(
        _ update: (inout MobileFileLocationsProfileState) -> Void
    ) -> Int {
        restorePendingRefreshIfCurrent()
        requestTask?.cancel()
        generation &+= 1
        updateActive(update)
        return generation
    }

    private func restorePendingRefreshIfCurrent() {
        guard let pendingRefresh,
              activeProfileID == pendingRefresh.profileID,
              generation == pendingRefresh.generation else {
            self.pendingRefresh = nil
            return
        }
        profiles[pendingRefresh.profileID] = pendingRefresh.baseline
        self.pendingRefresh = nil
    }

    private func isActive(_ repository: any MobileFileLocationBrowsing) -> Bool {
        activeProfileID == repository.profileID && repositoryIdentity == ObjectIdentifier(repository)
    }

    private func isCurrent(
        profileID: UUID,
        repositoryIdentity identity: ObjectIdentifier,
        generation requestGeneration: Int
    ) -> Bool {
        activeProfileID == profileID
            && repositoryIdentity == identity
            && generation == requestGeneration
    }

    private func updateActive(_ update: (inout MobileFileLocationsProfileState) -> Void) {
        guard let activeProfileID else { return }
        var profile = profiles[activeProfileID] ?? MobileFileLocationsProfileState()
        update(&profile)
        profiles[activeProfileID] = profile
    }

    private static func favoriteResult(
        repository: any MobileFileLocationBrowsing
    ) async -> SnapshotResult<FileFavoritePage> {
        do {
            return .success(try await repository.listFavoritesPage(offset: 0, limit: pageSize))
        } catch {
            return .failure
        }
    }

    private static func remoteResult(
        repository: any MobileFileLocationBrowsing
    ) async -> SnapshotResult<FileVirtualFolderPage> {
        do {
            return .success(try await repository.listVirtualFolders(offset: 0, limit: pageSize))
        } catch {
            return .failure
        }
    }

    private static func recycleResult(
        repository: any MobileFileLocationBrowsing
    ) async -> SnapshotResult<FileRecycleDiscoveryResult> {
        do {
            return .success(try await repository.discoverRecycleLocations())
        } catch {
            return .failure
        }
    }

    private static func hasBaseline(_ state: MobilePageState) -> Bool {
        state == .empty || state == .filteredEmpty || state == .content
    }

    private static func isCanonicalDirectoryPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path != "/",
              !path.hasSuffix("/"),
              !path.contains("//"),
              !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func containsRecycleSegment(_ path: String) -> Bool {
        path.split(separator: "/").contains {
            $0.caseInsensitiveCompare("#recycle") == .orderedSame
        }
    }
}

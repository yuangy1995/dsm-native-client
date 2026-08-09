import DsmCore
import Foundation

enum MobileFileLocationSource: String, Equatable, Sendable {
    case shares
    case favorite
    case recent
    case remote
    case recycle
    case browser

    var recordsRecentLocation: Bool {
        switch self {
        case .favorite, .recent, .browser:
            true
        case .shares, .remote, .recycle:
            false
        }
    }

    var isReadOnlyLocation: Bool {
        self == .remote || self == .recycle
    }
}

struct MobileFileFavoriteSnapshot: Equatable, Sendable {
    var locations: [FavoriteLocation] = []
    var pageState: MobilePageState = .loading
    var isRefreshing = false
    var isTruncated = false
    var hasRefreshError = false
}

struct MobileFileRemoteSnapshot: Equatable, Sendable {
    var folders: [FileVirtualFolder] = []
    var pageState: MobilePageState = .loading
    var isRefreshing = false
    var isTruncated = false
    var unavailableProtocols: [FileVirtualProtocol] = []
    var hasRefreshError = false

    var isPartial: Bool { !unavailableProtocols.isEmpty }
}

struct MobileFileRecycleSnapshot: Equatable, Sendable {
    var locations: [FileRecycleLocation] = []
    var pageState: MobilePageState = .loading
    var isRefreshing = false
    var isTruncated = false
    var permissionDeniedShareCount = 0
    var hasRefreshError = false

    var isPartial: Bool { permissionDeniedShareCount > 0 }
}

struct MobileRecentFileLocation: Identifiable, Equatable, Sendable {
    var id: String { path }
    let name: String
    let path: String
}

struct MobileFileLocationsProfileState: Equatable, Sendable {
    var favorites = MobileFileFavoriteSnapshot()
    var remote = MobileFileRemoteSnapshot()
    var recycle = MobileFileRecycleSnapshot()
    var recent: [MobileRecentFileLocation] = []
    var selectedSource: MobileFileLocationSource = .shares
    var hasLoadedSnapshot = false
}

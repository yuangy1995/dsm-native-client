import DsmCore
import Foundation

enum MobileFileBrowserLayout: String, Equatable, Sendable {
    case list
    case grid
}

struct MobileFileBrowserLocation: Equatable, Sendable {
    var path = ""
    var history: [String] = []
    var source: MobileFileLocationSource = .shares
}

struct MobileFileBrowserCacheKey: Hashable, Sendable {
    let path: String
    let query: String
    let options: FileListOptions
}

enum MobileFileBrowserFilteredEmptyReason: Equatable, Sendable {
    case query
    case typeFilter
}

struct MobileFileBrowserPageCache: Equatable, Sendable {
    var items: [FileItem] = []
    var nextOffset = 0
    var hasMore = false
    var filteredEmptyReason: MobileFileBrowserFilteredEmptyReason? = nil
}

struct MobileFileBrowserProfileState: Equatable, Sendable {
    var location = MobileFileBrowserLocation()
    var query = ""
    var layout: MobileFileBrowserLayout = .list
    var directoryOptions: FileListOptions = .default
    var options: FileListOptions = .default
    var page = MobileFileBrowserPageCache()
    var pageState: MobilePageState = .loading
    var isRefreshing = false
    var isLoadingMore = false
    var loadMoreFailed = false
    var visibleKey: MobileFileBrowserCacheKey?
    var caches: [MobileFileBrowserCacheKey: MobileFileBrowserPageCache] = [:]

    var currentPath: String { location.path }
    var pathHistory: [String] { location.history }

    var filteredEmptyReason: MobileFileBrowserFilteredEmptyReason? { page.filteredEmptyReason }
}

import DsmCore
import Foundation

enum MobilePhotoFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case images
}

struct MobilePhotoLocation: Equatable, Sendable {
    var space: PhotoSpace?
    var path = ""
    var history: [String] = []
}

struct MobilePhotoPage: Equatable, Sendable {
    var sourceItems: [PhotoLibraryItem] = []
    var items: [PhotoLibraryItem] = []
    var nextOffset = 0
    var sourceTotal = 0
    var hasMore = false
}

struct MobilePhotoPageCacheKey: Hashable, Sendable {
    let spaceKind: PhotoSpaceKind
    let path: String
    let filter: MobilePhotoFilter
}

struct MobilePhotoLibraryProfileState: Equatable, Sendable {
    var spaces: [PhotoSpace] = []
    var location = MobilePhotoLocation()
    var filter: MobilePhotoFilter = .all
    var page = MobilePhotoPage()
    var pageState: MobilePageState = .loading
    var isDiscoveringSpaces = false
    var isRefreshing = false
    var isLoadingMore = false
    var loadMoreFailed = false
    var errorCategory: AppErrorCategory?
    var caches: [MobilePhotoPageCacheKey: MobilePhotoPage] = [:]
    var cacheOrder: [MobilePhotoPageCacheKey] = []

    var selectedSpace: PhotoSpace? { location.space }
    var currentPath: String { location.path }
    var pathHistory: [String] { location.history }
}

enum MobilePhotoLibraryError: Error, Equatable {
    case misalignedPage
    case zeroProgress
    case inconsistentTotal
    case crossProfileItem
}

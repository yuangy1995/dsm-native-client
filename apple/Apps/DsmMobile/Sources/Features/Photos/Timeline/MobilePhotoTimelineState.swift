import DsmCore
import Foundation

enum MobilePhotoTimelinePhase: Equatable, Sendable {
    case idle
    case scanning
    case content
    case empty
    case error
}

struct MobilePhotoTimelineMonth: Identifiable, Equatable, Sendable {
    let monthStart: Date?
    let items: [PhotoLibraryItem]

    var id: String {
        monthStart.map { String($0.timeIntervalSinceReferenceDate) } ?? "unknown"
    }
}

struct MobilePhotoTimelineState: Equatable, Sendable {
    var phase: MobilePhotoTimelinePhase = .idle
    var space: PhotoSpace?
    var items: [PhotoLibraryItem] = []
    var query = ""
    var appliedQuery = ""
    var filter: PhotoMediaFilter = .all
    var scannedFolderCount = 0
    var sourceItemCount = 0
    var skippedFolderPaths: [String] = []
    var completion: PhotoTimelineScanCompletion = .complete
    var hasCompletedScan = false
    var refreshFailed = false

    var isScanning: Bool { phase == .scanning }
    var isPartial: Bool { !skippedFolderPaths.isEmpty }
    var isTruncated: Bool { completion == .truncated }

    var filteredItems: [PhotoLibraryItem] {
        let foldedQuery = Self.fold(appliedQuery)
        return items.filter { item in
            let matchesKind: Bool
            switch filter {
            case .all:
                matchesKind = true
            case .images:
                matchesKind = item.kind == .image
            case .videos:
                matchesKind = item.kind == .video
            }
            guard matchesKind else { return false }
            return foldedQuery.isEmpty || Self.fold(item.name).contains(foldedQuery)
        }
    }

    var months: [MobilePhotoTimelineMonth] {
        let calendar = Calendar.autoupdatingCurrent
        let grouped = Dictionary(grouping: filteredItems) { item -> Date? in
            guard let date = item.createdAt ?? item.modifiedAt else { return nil }
            return calendar.date(from: calendar.dateComponents([.year, .month], from: date))
        }
        return grouped.map { MobilePhotoTimelineMonth(monthStart: $0.key, items: Self.sorted($0.value)) }
            .sorted { lhs, rhs in
                switch (lhs.monthStart, rhs.monthStart) {
                case let (left?, right?): left > right
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): false
                }
            }
    }

    static func sorted(_ items: [PhotoLibraryItem]) -> [PhotoLibraryItem] {
        items.sorted { lhs, rhs in
            let left = lhs.createdAt ?? lhs.modifiedAt
            let right = rhs.createdAt ?? rhs.modifiedAt
            if left != right {
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .autoupdatingCurrent)
    }
}

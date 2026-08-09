import DsmCore
import Foundation

enum MobileContainerFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case running
    case stopped
    case attention
}

enum MobileContainerStatus: String, CaseIterable, Equatable, Sendable {
    case running
    case stopped
    case attention
    case unknown

    init(serverValue: String) {
        switch serverValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "running", "up": self = .running
        case "stopped", "exited", "created": self = .stopped
        case "paused", "restarting", "removing", "dead", "error", "failed": self = .attention
        default: self = .unknown
        }
    }
}

struct MobileContainerItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: MobileContainerStatus
    let image: String?

    init(_ container: ContainerInventoryItem) {
        id = container.id
        name = container.name
        status = MobileContainerStatus(serverValue: container.status)
        image = container.image
    }
}

struct MobileContainerInventoryState: Equatable, Sendable {
    var items: [MobileContainerItem] = []
    var visibleItems: [MobileContainerItem] = []
    var filter: MobileContainerFilter = .all
    var selectedID: String?
    var pageState: MobilePageState = .loading
    var isRefreshing = false
    var hasRefreshError = false
    var hasLoadedOnce = false

    var selectedItem: MobileContainerItem? {
        guard let selectedID else { return nil }
        return visibleItems.first { $0.id == selectedID }
    }
}

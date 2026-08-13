import DsmCore
import Foundation

enum MobileReadOnlySectionState: Equatable, Sendable {
    case unavailable
    case failed
    case empty
    case content
}

enum MobileContainerSection: String, CaseIterable, Identifiable, Equatable, Sendable {
    case containers
    case images
    case networks
    case projects
    case events

    var id: Self { self }
}

enum MobileContainerFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case running
    case stopped
    case attention
}

enum MobileContainerStatus: String, Equatable, Sendable {
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
    let image: String

    init(_ value: ContainerInstance) {
        id = value.id
        name = value.name
        status = MobileContainerStatus(serverValue: value.status)
        image = value.image
    }
}

struct MobileContainerImageItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let sizeBytes: Int64?
    let isInUse: Bool

    init(_ value: ContainerImage) {
        id = value.id
        name = value.tag.isEmpty ? value.repository : "\(value.repository):\(value.tag)"
        sizeBytes = value.sizeBytes
        isInUse = value.isInUse
    }
}

struct MobileContainerNetworkItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let driver: String
    let connectedContainerCount: Int

    init(_ value: ContainerNetwork) {
        id = value.id
        name = value.name
        driver = value.driver
        connectedContainerCount = value.connectedContainerCount
    }
}

struct MobileContainerProjectItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: MobileContainerStatus
    let containerCount: Int

    init(_ value: ContainerProject) {
        id = value.id
        name = value.name
        status = MobileContainerStatus(serverValue: value.status)
        containerCount = value.containerCount
    }
}

struct MobileContainerEventItem: Identifiable, Equatable, Sendable {
    let id: String
    let timestamp: Date?
    let level: String

    init(_ value: ServiceEvent) {
        id = value.id
        timestamp = value.timestamp
        level = value.level
    }
}

struct MobileContainerInventoryState: Equatable, Sendable {
    var containers: [MobileContainerItem] = []
    var images: [MobileContainerImageItem] = []
    var networks: [MobileContainerNetworkItem] = []
    var projects: [MobileContainerProjectItem] = []
    var events: [MobileContainerEventItem] = []
    var sectionStates: [MobileContainerSection: MobileReadOnlySectionState] = Dictionary(
        uniqueKeysWithValues: MobileContainerSection.allCases.map { ($0, MobileReadOnlySectionState.empty) }
    )
    var selectedSection: MobileContainerSection = .containers
    var selectedItemID: String?
    var filter: MobileContainerFilter = .all
    var visibleContainers: [MobileContainerItem] = []
    var pageState: MobilePageState = .loading
    var isRefreshing = false
    var hasRefreshError = false
    var hasLoadedOnce = false
    var hasSuccessfulLoad = false
    var requiresReconnect = false

    func sectionState(_ section: MobileContainerSection) -> MobileReadOnlySectionState {
        sectionStates[section] ?? .empty
    }

    func itemCount(_ section: MobileContainerSection) -> Int {
        switch section {
        case .containers: containers.count
        case .images: images.count
        case .networks: networks.count
        case .projects: projects.count
        case .events: events.count
        }
    }


    var selectedContainer: MobileContainerItem? {
        guard let selectedItemID else { return nil }
        return visibleContainers.first { $0.id == selectedItemID }
    }
}

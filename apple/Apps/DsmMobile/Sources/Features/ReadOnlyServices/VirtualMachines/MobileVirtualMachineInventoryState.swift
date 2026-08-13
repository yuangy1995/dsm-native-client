import DsmCore
import Foundation

enum MobileVirtualMachineSection: String, CaseIterable, Identifiable, Equatable, Sendable {
    case machines
    case hosts
    case storages
    case networks
    case images
    case protection
    case events

    var id: Self { self }
}

enum MobileVirtualMachineFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case running
    case stopped
    case attention
}

enum MobileVirtualMachineStatus: String, Equatable, Sendable {
    case running
    case stopped
    case attention
    case unknown

    init(serverValue: String?) {
        switch serverValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "running", "powered_on", "poweron", "on", "online", "healthy": self = .running
        case "stopped", "powered_off", "poweroff", "shutdown", "shutoff", "off", "offline": self = .stopped
        case "paused", "suspended", "error", "failed", "warning", "degraded": self = .attention
        default: self = .unknown
        }
    }
}

struct MobileVirtualMachineItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: MobileVirtualMachineStatus
    let cpuCount: Int?
    let memoryBytes: Int64?
    let storageBytes: Int64?
    let autoStart: Bool

    init(_ value: VirtualMachine) {
        id = value.id
        name = value.name
        status = MobileVirtualMachineStatus(serverValue: value.status)
        cpuCount = value.cpuCount
        memoryBytes = value.memoryBytes
        storageBytes = value.storageBytes
        autoStart = value.autoStart
    }
}

struct MobileVirtualizationResourceItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: MobileVirtualMachineStatus
    let allocatedBytes: Int64?
    let capacityBytes: Int64?

    init(_ value: VirtualizationResource) {
        id = value.id
        name = value.name
        status = MobileVirtualMachineStatus(serverValue: value.status)
        allocatedBytes = value.allocatedBytes
        capacityBytes = value.capacityBytes
    }
}

enum MobileProtectionKind: String, Equatable, Sendable {
    case plan
    case schedule
    case retention
}

struct MobileProtectionItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: MobileVirtualMachineStatus
    let kind: MobileProtectionKind

    init(_ value: VirtualizationResource, kind: MobileProtectionKind) {
        id = "\(kind.rawValue):\(value.id)"
        name = value.name
        status = MobileVirtualMachineStatus(serverValue: value.status)
        self.kind = kind
    }
}

struct MobileVirtualMachineEventItem: Identifiable, Equatable, Sendable {
    let id: String
    let timestamp: Date?
    let level: String

    init(_ value: ServiceEvent) {
        id = value.id
        timestamp = value.timestamp
        level = value.level
    }
}

struct MobileVirtualMachineInventoryState: Equatable, Sendable {
    var machines: [MobileVirtualMachineItem] = []
    var hosts: [MobileVirtualizationResourceItem] = []
    var storages: [MobileVirtualizationResourceItem] = []
    var networks: [MobileVirtualizationResourceItem] = []
    var images: [MobileVirtualizationResourceItem] = []
    var protection: [MobileProtectionItem] = []
    var events: [MobileVirtualMachineEventItem] = []
    var sectionStates: [MobileVirtualMachineSection: MobileReadOnlySectionState] = Dictionary(
        uniqueKeysWithValues: MobileVirtualMachineSection.allCases.map {
            ($0, MobileReadOnlySectionState.empty)
        }
    )
    var selectedSection: MobileVirtualMachineSection = .machines
    var selectedItemID: String?
    var filter: MobileVirtualMachineFilter = .all
    var visibleMachines: [MobileVirtualMachineItem] = []
    var pageState: MobilePageState = .loading
    var isRefreshing = false
    var hasRefreshError = false
    var hasLoadedOnce = false
    var hasSuccessfulLoad = false
    var requiresReconnect = false

    func sectionState(_ section: MobileVirtualMachineSection) -> MobileReadOnlySectionState {
        sectionStates[section] ?? .empty
    }

    func itemCount(_ section: MobileVirtualMachineSection) -> Int {
        switch section {
        case .machines: machines.count
        case .hosts: hosts.count
        case .storages: storages.count
        case .networks: networks.count
        case .images: images.count
        case .protection: protection.count
        case .events: events.count
        }
    }


    var selectedMachine: MobileVirtualMachineItem? {
        guard let selectedItemID else { return nil }
        return visibleMachines.first { $0.id == selectedItemID }
    }
}

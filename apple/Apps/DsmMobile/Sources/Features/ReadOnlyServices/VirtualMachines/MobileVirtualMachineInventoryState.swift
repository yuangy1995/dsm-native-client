import DsmCore
import Foundation

enum MobileVirtualMachineFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case running
    case stopped
    case attention
}

enum MobileVirtualMachineStatus: String, CaseIterable, Equatable, Sendable {
    case running
    case stopped
    case attention
    case unknown

    init(serverValue: String) {
        switch serverValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "running", "powered_on", "poweron", "on": self = .running
        case "shutdown", "shutoff", "stopped", "powered_off", "poweroff", "off": self = .stopped
        case "paused", "suspended", "warning", "error", "failed", "degraded": self = .attention
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

    init(_ machine: VirtualMachineInventoryItem) {
        id = machine.id
        name = machine.name
        status = MobileVirtualMachineStatus(serverValue: machine.status)
        cpuCount = machine.cpuCount
        memoryBytes = machine.memoryBytes
        storageBytes = machine.storageBytes
        autoStart = machine.autoStart
    }
}

struct MobileVirtualMachineInventoryState: Equatable, Sendable {
    var items: [MobileVirtualMachineItem] = []
    var visibleItems: [MobileVirtualMachineItem] = []
    var filter: MobileVirtualMachineFilter = .all
    var selectedID: String?
    var pageState: MobilePageState = .loading
    var isRefreshing = false
    var hasRefreshError = false
    var hasLoadedOnce = false

    var selectedItem: MobileVirtualMachineItem? {
        guard let selectedID else { return nil }
        return visibleItems.first { $0.id == selectedID }
    }
}

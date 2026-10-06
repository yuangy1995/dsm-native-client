import Foundation

/// 内部网络清单与详情的原始身份；速率等瞬时指标不参与改名或删除确认。
public struct VirtualMachineNetworkState: Equatable, Codable, Sendable, Identifiable {
    public struct Interface: Equatable, Hashable, Codable, Sendable {
        public let hostID: String
        public let id: String
        public init(hostID: String, id: String) { self.hostID = hostID; self.id = id }
    }
    public struct Guest: Equatable, Codable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let isRunning: Bool
        public let prefersSriov: Bool
        public let usesVirtualFunction: Bool
        public let macAddress: String
        public let interfaceNames: String
        public init(id: String, name: String, isRunning: Bool, prefersSriov: Bool, usesVirtualFunction: Bool,
                    macAddress: String, interfaceNames: String) {
            self.id = id; self.name = name; self.isRunning = isRunning; self.prefersSriov = prefersSriov
            self.usesVirtualFunction = usesVirtualFunction; self.macAddress = macAddress; self.interfaceNames = interfaceNames
        }
    }
    public let id: String
    public let name: String
    public let type: String
    public let hostID: String
    public let vlanID: Int
    public let interfaces: [Interface]
    public let guests: [Guest]
    public init(id: String, name: String, type: String, hostID: String, vlanID: Int, interfaces: [Interface], guests: [Guest]) {
        self.id = id; self.name = name; self.type = type; self.hostID = hostID; self.vlanID = vlanID
        self.interfaces = interfaces.sorted { $0.hostID == $1.hostID ? $0.id < $1.id : $0.hostID < $1.hostID }
        self.guests = guests.sorted { $0.id < $1.id }
    }
    public static func isValidName(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && value.utf16.count <= 127
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    public func hasSameTopology(as other: Self) -> Bool {
        id == other.id && type == other.type && hostID == other.hostID && vlanID == other.vlanID
            && interfaces == other.interfaces && guests == other.guests
    }
}

public struct VirtualMachineNetworkInventory: Equatable, Sendable {
    public let isFrozen: Bool
    public let networks: [VirtualMachineNetworkState]
    public init(isFrozen: Bool, networks: [VirtualMachineNetworkState]) { self.isFrozen = isFrozen; self.networks = networks }
}

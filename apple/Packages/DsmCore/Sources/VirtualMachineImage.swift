import Foundation

/// 删除绑定原始来源、映像身份和全部副本；公开摘要未提供的属性保持未知。
public struct VirtualMachineImageState: Equatable, Codable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable { case official, internalAPI }
    public struct Copy: Equatable, Hashable, Codable, Sendable {
        public let storageID: String
        public let hostID: String
        public let status: String
        public let statusType: String
        public init(storageID: String, hostID: String, status: String, statusType: String) {
            self.storageID = storageID; self.hostID = hostID; self.status = status; self.statusType = statusType
        }
    }
    public let id: String
    public let name: String?
    public let type: String?
    public let source: Source
    public let copies: [Copy]
    public let isInUse: Bool?
    public init(id: String, name: String?, type: String?, source: Source, copies: [Copy] = [], isInUse: Bool? = nil) {
        self.id = id; self.name = name; self.type = type; self.source = source
        self.copies = copies.sorted { $0.storageID == $1.storageID ? $0.hostID < $1.hostID : $0.storageID < $1.storageID }
        self.isInUse = isInUse
    }
    public var canDelete: Bool {
        if source == .official { return isInUse != true }
        return !copies.isEmpty && copies.allSatisfy { $0.status == "online" && $0.statusType == "healthy" }
            && (type != "iso" || isInUse == false)
    }
}

public struct VirtualMachineImageInventory: Equatable, Sendable {
    public let source: VirtualMachineImageState.Source
    public let isFrozen: Bool
    public let images: [VirtualMachineImageState]
    public init(source: VirtualMachineImageState.Source, isFrozen: Bool, images: [VirtualMachineImageState]) {
        self.source = source; self.isFrozen = isFrozen; self.images = images
    }
}

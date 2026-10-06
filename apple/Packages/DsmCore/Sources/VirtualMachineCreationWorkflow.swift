import Foundation

/// 创建使用内部资源原值，不能用公开摘要或展示默认值替代。
public struct VirtualMachineCreationStorage: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let hostID: String
    public let hostName: String
    public let allocatedBytes: Int
    public let capacityBytes: String
    public let status: String
    public let statusType: String
    public var isAvailable: Bool { status == "online" && statusType == "healthy" }
    public init(id: String, name: String, hostID: String, hostName: String, allocatedBytes: Int,
                capacityBytes: String, status: String, statusType: String) {
        self.id = id; self.name = name; self.hostID = hostID; self.hostName = hostName
        self.allocatedBytes = allocatedBytes; self.capacityBytes = capacityBytes
        self.status = status; self.statusType = statusType
    }
}

public struct VirtualMachineCreationImage: Equatable, Sendable {
    public let id: String
    public let name: String
    public let storageID: String
    public let hostID: String
    public init(id: String, name: String, storageID: String, hostID: String) {
        self.id = id; self.name = name; self.storageID = storageID; self.hostID = hostID
    }
}

public struct VirtualMachineCreationResources: Equatable, Sendable {
    public let storages: [VirtualMachineCreationStorage]
    public let networks: [VirtualizationResource]
    public let images: [VirtualMachineCreationImage]
    public let imagesAvailable: Bool
    public let networksAvailable: Bool
    public init(storages: [VirtualMachineCreationStorage], networks: [VirtualizationResource],
                images: [VirtualMachineCreationImage], imagesAvailable: Bool, networksAvailable: Bool) {
        self.storages = storages; self.networks = networks; self.images = images
        self.imagesAvailable = imagesAvailable; self.networksAvailable = networksAvailable
    }
}

/// 可落盘的最小任务关联证据，不含名称、说明、资源身份明文或任何会话凭据。
public struct VirtualMachineCreationTracking: Codable, Equatable, Sendable {
    public static let parameterKeys: Set<String> = ["guest_privilege", "iso_images", "autorun", "boot_from", "bios",
        "kb_layout", "usb_version", "usbs", "is_windows_vm", "use_ovmf", "vnics", "is_general_vm", "increaseAllocatedSize",
        "vdisks", "auto_switch", "vdisk_struct", "name", "vcpu_num", "vram_size", "video_card", "cpu_weight", "desc",
        "cpu_passthru", "hyperv_enlighten", "cpu_pin_num", "repo_id", "repo_name", "host_id", "repo_host_name",
        "poweron_after_create", "synovmm_ui_id", "allocated_size", "size"]
    public let requestID: UUID
    public let nameDigest: String
    public let parameterDigests: [String: String]
    public let configurationDigest: String
    public let existingIdentityDigests: Set<String>
    public let resourceIdentityDigests: [String: String]
    public var taskIdentityDigest: String?
    public var guestIdentityDigest: String?
    public init(requestID: UUID, nameDigest: String, parameterDigests: [String: String], configurationDigest: String,
                existingIdentityDigests: Set<String>, resourceIdentityDigests: [String: String],
                taskIdentityDigest: String? = nil, guestIdentityDigest: String? = nil) {
        self.requestID = requestID; self.nameDigest = nameDigest; self.parameterDigests = parameterDigests
        self.configurationDigest = configurationDigest; self.existingIdentityDigests = existingIdentityDigests
        self.resourceIdentityDigests = resourceIdentityDigests
        self.taskIdentityDigest = taskIdentityDigest; self.guestIdentityDigest = guestIdentityDigest
    }
    public var isValid: Bool {
        func digest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        return digest(nameDigest) && digest(configurationDigest) && Set(parameterDigests.keys) == Self.parameterKeys
            && parameterDigests.values.allSatisfy(digest) && parameterDigests["synovmm_ui_id"] != nil
            && existingIdentityDigests.allSatisfy(digest) && taskIdentityDigest.map(digest) != false
            && resourceIdentityDigests["storage"] != nil && Set(resourceIdentityDigests.keys).isSubset(of: ["storage", "network", "image"])
            && resourceIdentityDigests.values.allSatisfy(digest)
            && guestIdentityDigest.map(digest) != false && (guestIdentityDigest == nil || taskIdentityDigest != nil)
    }
}

public enum VirtualMachineCreationStage: Equatable, Sendable {
    case willSubmit(VirtualMachineCreationTracking)
    case accepted(VirtualMachineCreationTracking)
    case taskSucceeded(VirtualMachineCreationTracking)
    case succeeded(guestID: String)
    case rejected
}
public typealias VirtualMachineCreationObserver = @Sendable (VirtualMachineCreationStage) async throws -> Void

public enum VirtualMachineCreationReview: Equatable, Sendable {
    case pending
    case failed
    case succeeded(guestID: String)
}

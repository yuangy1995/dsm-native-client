import Foundation

public enum FileACLRight: String, CaseIterable, Codable, Sendable {
    case readData = "read_data", writeData = "write_data", execute = "exe_file", append = "append_data"
    case delete, deleteChildren = "delete_sub", readAttributes = "read_attr", writeAttributes = "write_attr"
    case readExtendedAttributes = "read_ext_attr", writeExtendedAttributes = "write_ext_attr"
    case readPermissions = "read_perm", changePermissions = "change_perm", takeOwnership = "take_ownership"
}

public enum FileACLInheritance: String, CaseIterable, Codable, Sendable {
    case childFiles = "child_files", childFolders = "child_folders", thisFolder = "this_folder", allDescendants = "all_descendants"
}

public struct FileACLRule: Equatable, Sendable {
    public enum Effect: String, CaseIterable, Codable, Sendable { case allow, deny }
    public let ownerType: String
    public let ownerName: String
    public let ownerID: Int?
    public let isInternal: Bool?
    public var effect: Effect
    public var rights: Set<FileACLRight>
    public var inheritance: Set<FileACLInheritance>
    public let level: Int
    public init(ownerType: String, ownerName: String, ownerID: Int? = nil, isInternal: Bool? = nil,
                effect: Effect, rights: Set<FileACLRight>, inheritance: Set<FileACLInheritance>, level: Int = 0) {
        self.ownerType = ownerType; self.ownerName = ownerName; self.ownerID = ownerID; self.isInternal = isInternal
        self.effect = effect; self.rights = rights; self.inheritance = inheritance; self.level = level
    }
}

public struct FilePermissionOwner: Equatable, Sendable {
    public let name: String
    public let type: String
    public let value: String
    public let canChange: Bool
    public init(name: String, type: String, value: String, canChange: Bool) {
        self.name = name; self.type = type; self.value = value; self.canChange = canChange
    }
}

/// 仅当前会话持有真实路径映射和权限基线，不进入任务存储或诊断。
public struct FilePermissionSnapshot: Equatable, Sendable {
    public let target: FileItem
    public let resolvedPath: String
    public let isACL: Bool
    public let canChangePermissions: Bool
    public let isInherited: Bool
    public let rules: [FileACLRule]
    public let owner: FilePermissionOwner?
    public let posixMode: String?
    public init(target: FileItem, resolvedPath: String, isACL: Bool, canChangePermissions: Bool,
                isInherited: Bool, rules: [FileACLRule], owner: FilePermissionOwner?, posixMode: String?) {
        self.target = target; self.resolvedPath = resolvedPath; self.isACL = isACL
        self.canChangePermissions = canChangePermissions; self.isInherited = isInherited
        self.rules = rules; self.owner = owner; self.posixMode = posixMode
    }
}

public struct FilePermissionChange: Equatable, Sendable {
    public let baseline: FilePermissionSnapshot
    public let explicitRules: [FileACLRule]?
    public let posixMode: String?
    public let owner: FileStationPrincipal?
    public let group: FileStationPrincipal?
    public let recursive: Bool
    public let confirmedScope: Bool
    public let confirmedOwner: Bool
    public let confirmedAccessRemoval: Bool
    public init(baseline: FilePermissionSnapshot, explicitRules: [FileACLRule]? = nil, posixMode: String? = nil,
                owner: FileStationPrincipal? = nil, group: FileStationPrincipal? = nil, recursive: Bool = false,
                confirmedScope: Bool, confirmedOwner: Bool, confirmedAccessRemoval: Bool) {
        self.baseline = baseline; self.explicitRules = explicitRules; self.posixMode = posixMode
        self.owner = owner; self.group = group; self.recursive = recursive
        self.confirmedScope = confirmedScope; self.confirmedOwner = confirmedOwner
        self.confirmedAccessRemoval = confirmedAccessRemoval
    }
}

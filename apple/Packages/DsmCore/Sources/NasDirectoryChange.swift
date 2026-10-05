import Foundation

public enum NasDirectoryAction: String, Codable, Sendable { case saveUser, saveGroup, deleteUser, deleteGroup }
public enum NasDirectoryCheckpoint: Sendable { case willSubmit, accepted }

/// 确认携带完整原对象；密码仅存在于当次草稿，不进入恢复记录。
public enum NasDirectoryChange: Equatable, Sendable {
    case saveUser(original: NasAccount?, draft: NasAccountDraft, groups: [NasAccount]?)
    case saveGroup(original: NasAccount?, draft: NasGroupDraft)
    case delete(NasAccount)

    public var original: NasAccount? {
        switch self { case .saveUser(let value, _, _), .saveGroup(let value, _): value; case .delete(let value): value }
    }
    public var action: NasDirectoryAction {
        switch self { case .saveUser: .saveUser; case .saveGroup: .saveGroup; case .delete(let value): value.kind == .user ? .deleteUser : .deleteGroup }
    }
    public var kind: NasAccount.Kind { action == .saveUser || action == .deleteUser ? .user : .group }
    public var name: String {
        switch self {
        case .saveUser(let original, let draft, _): original?.name ?? draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        case .saveGroup(let original, let draft): original?.name ?? draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        case .delete(let value): value.name
        }
    }
    public var isDeletion: Bool { action == .deleteUser || action == .deleteGroup }
    public var requiresAcknowledgement: Bool {
        switch self {
        case .saveUser(let original, let draft, _): original == nil || !draft.password.isEmpty
        case .saveGroup(let original, _): original == nil
        case .delete: false
        }
    }
    public func matches(_ directory: NasAccountDirectory, currentUsername: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !currentUsername.isEmpty else { return false }
        let entries = kind == .user ? directory.users : directory.groups
        let current = entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if let original {
            guard original.kind == kind, original.numericID != nil, let current,
                  original.hasSameDirectorySnapshot(as: current) else { return false }
        } else if current != nil { return false }
        let isCurrent = kind == .user && name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(currentUsername) == .orderedSame
        switch self {
        case .delete(let original):
            let protected = kind == .user ? ["admin", "guest"] : ["administrators", "users", "http"]
            return original.canDelete && !isCurrent && !protected.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        case .saveGroup(let original, let draft):
            return draft.originalName == original?.name && (original == nil || (draft.name == name && original?.canEdit == true))
                && (original == nil || original?.description != draft.description)
        case .saveUser(let original, let draft, let groups):
            guard draft.originalName == original?.name,
                  original == nil || (draft.name == name && original?.canEdit == true),
                  original != nil || !draft.password.isEmpty,
                  draft.password == draft.passwordConfirmation,
                  !isCurrent || !draft.isExpired else { return false }
            if let selected = draft.groups {
                guard original == nil || original?.groups != nil, let groups,
                      groups.count == directory.groups.count,
                      groups.allSatisfy({ expected in directory.groups.contains { expected.hasSameDirectorySnapshot(as: $0) } }),
                      Set(selected.map { $0.lowercased() }).count == selected.count,
                      selected.allSatisfy({ name in groups.contains { $0.name == name && $0.numericID != nil } }),
                      !isCurrent || original?.groups?.sorted() == selected.sorted() else { return false }
            } else if groups != nil { return false }
            return original == nil || !draft.password.isEmpty || !savedFieldsMatch(original!)
        }
    }
    public func savedFieldsMatch(_ account: NasAccount) -> Bool {
        guard account.kind == kind, account.name == name, account.numericID != nil,
              original == nil || original?.numericID == account.numericID else { return false }
        switch self {
        case .saveUser(let original, let draft, _):
            let expectedGroups = draft.groups ?? original?.groups
            return account.canEdit && account.description == draft.description && account.email == draft.email
                && account.isExpired == draft.isExpired
                && (expectedGroups == nil || account.groups?.sorted() == expectedGroups?.sorted())
        case .saveGroup(_, let draft): return account.description == draft.description
        case .delete: return false
        }
    }
}

public extension NasAccount {
    func hasSameDirectorySnapshot(as other: NasAccount) -> Bool {
        id == other.id && name == other.name && kind == other.kind && numericID == other.numericID
            && description == other.description && email == other.email && isExpired == other.isExpired
            && canEdit == other.canEdit && canDelete == other.canDelete && groups?.sorted() == other.groups?.sorted()
    }
}

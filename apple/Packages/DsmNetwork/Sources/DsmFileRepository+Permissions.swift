import DsmCore
import DsmLocalization
import Foundation

struct PendingFilePermissionChange: Sendable {
    let change: FilePermissionChange
    let api: String
    var taskID: String?
    var acknowledged = false
    var finished = false
    var failed = false
}

extension DsmFileRepository {
    public func loadFilePermissions(_ item: FileItem) async throws -> FilePermissionSnapshot {
        guard item.profileID == profileID else { throw Self.advancedFileError() }
        let (target, resolved, isACL) = try await permissionTarget(path: item.path)
        let editableTarget = Self.permissionTargetAllowsEditing(target)
        if isACL {
            let acl: PermissionACLPayload = try await advancedFileCall(DsmAPIName.coreACL, method: "get",
                parameters: ["type": .string("all"), "file_path": .string(resolved), "include_noname_rules": .boolean(true)])
            guard acl.is_acl else { throw Self.advancedFileError(.conflict, "files.permissions.changed") }
            let owner: PermissionOwnerPayload = try await advancedFileCall(DsmAPIName.fileStationACLOwner, method: "get",
                parameters: ["file": .string(resolved)])
            let rules = try acl.acl.map { row -> FileACLRule in
                guard row.level >= 0, Set(row.permission.keys) == Set(FileACLRight.allCases.map(\.rawValue)),
                      Set(row.inherit.keys) == Set(FileACLInheritance.allCases.map(\.rawValue)) else { throw Self.advancedFileError() }
                return .init(ownerType: row.owner_type, ownerName: row.owner_name, ownerID: row.owner_id,
                    isInternal: row.owner_is_internal, effect: row.permission_type,
                    rights: Set(FileACLRight.allCases.filter { row.permission[$0.rawValue] == true }),
                    inheritance: Set(FileACLInheritance.allCases.filter { row.inherit[$0.rawValue] == true }), level: row.level)
            }
            return .init(target: target, resolvedPath: resolved, isACL: true, canChangePermissions: editableTarget && acl.change_permission,
                isInherited: acl.is_inherited, rules: rules,
                owner: .init(name: owner.name, type: owner.type, value: owner.value, canChange: editableTarget && owner.hasPrivilege), posixMode: nil)
        }
        guard let mode = target.permissions?.posixMode, Self.validPOSIXMode(String(format: "%03d", mode)) else {
            throw Self.advancedFileError()
        }
        // POSIX 所有者授权尚无完整会话身份契约，首轮仅管理员可修改。
        let access = try await loadFileStationAdvancedAccess()
        return .init(target: target, resolvedPath: resolved, isACL: false, canChangePermissions: editableTarget && access.isAdministrator,
            isInherited: false, rules: [], owner: nil, posixMode: String(format: "%03d", mode))
    }

    public func changeFilePermissions(_ change: FilePermissionChange) async throws -> MutationResult {
        let baseline = change.baseline
        let key = "permissions:" + baseline.target.path
        guard !activeAdvancedFileChanges.contains(key), pendingFilePermissions[key] == nil else {
            throw Self.advancedFileError(.conflict, "files.advanced.pendingChange")
        }
        try reserveRemoteMountPaths([baseline.target.path])
        defer { activeRemoteMountPaths.remove(baseline.target.path) }
        activeAdvancedFileChanges.insert(key)
        defer { activeAdvancedFileChanges.remove(key) }
        try await requireAdvancedFileWrite(administrator: !baseline.isACL || change.owner != nil || change.group != nil)
        guard baseline.target.profileID == profileID, Self.permissionTargetAllowsEditing(baseline.target),
              !change.recursive || (baseline.target.isDirectory && change.confirmedScope),
              (change.owner == nil && change.group == nil) || change.confirmedOwner,
              change.confirmedAccessRemoval else { throw Self.advancedFileError(.permissionDenied, "files.permissions.confirmRequired") }
        guard try await loadFilePermissions(baseline.target) == baseline else {
            throw Self.advancedFileError(.conflict, "files.permissions.changed")
        }
        for principal in [change.owner, change.group].compactMap({ $0 }) {
            try await requireFilePrincipal(principal)
        }
        var parameters: [String: DsmParameterValue]
        let api: String
        if baseline.isACL {
            guard change.posixMode == nil, change.group == nil,
                  change.owner == nil || baseline.owner?.canChange == true,
                  change.explicitRules == nil || baseline.canChangePermissions else {
                throw Self.advancedFileError(.permissionDenied, "files.permissions.cannotEdit")
            }
            let rules = change.explicitRules ?? baseline.rules.filter { $0.level == 0 }
            guard rules.count <= 200, rules.allSatisfy({ $0.level == 0 }),
                  change.explicitRules != nil || change.owner != nil else { throw Self.advancedFileError() }
            for rule in rules where !baseline.rules.contains(where: {
                $0.ownerType == rule.ownerType && $0.ownerName == rule.ownerName && $0.ownerID == rule.ownerID
            }) {
                guard let kind = FileStationPrincipal.Kind(rawValue: rule.ownerType), rule.ownerID == nil else { throw Self.advancedFileError() }
                try await requireFilePrincipal(.init(name: rule.ownerName, kind: kind))
            }
            parameters = ["file_path": .string(baseline.resolvedPath), "change_acl": .boolean(change.explicitRules != nil),
                "rules": .objectArray(rules.map(Self.permissionRuleParameters)), "inherited": .boolean(baseline.isInherited),
                "acl_recur": .boolean(change.recursive && change.explicitRules != nil)]
            if let owner = change.owner {
                parameters["change_acl_owner"] = .boolean(true); parameters["acl_owner_type"] = .string(owner.kind.rawValue)
                parameters["acl_owner"] = .string(owner.name); parameters["acl_owner_recur"] = .boolean(change.recursive)
            }
            let check: PermissionSelfDenied = try await advancedFileCall(DsmAPIName.coreACL, method: "check_self_denied", parameters: parameters)
            guard !check.is_denied else { throw Self.advancedFileError(.permissionDenied, "files.permissions.selfDenied") }
            api = DsmAPIName.coreACL
        } else {
            guard baseline.canChangePermissions, change.explicitRules == nil,
                  change.owner?.kind != .group, change.group?.kind != .user,
                  change.posixMode == nil || Self.validPOSIXMode(change.posixMode!),
                  change.posixMode != nil || change.owner != nil || change.group != nil else { throw Self.advancedFileError() }
            let parent = baseline.target.isDirectory ? baseline.target.path : (baseline.target.path as NSString).deletingLastPathComponent
            parameters = ["files": .stringArray([baseline.resolvedPath]), "dir_paths": .stringArray([parent]),
                "mode": .string(change.posixMode ?? "-1"), "posix_mode_recur": .boolean(change.recursive && change.posixMode != nil),
                "posix_owner_recur": .boolean(change.recursive && (change.owner != nil || change.group != nil))]
            if let owner = change.owner { parameters["owner"] = .string(owner.name) }
            if let group = change.group { parameters["group"] = .string(group.name) }
            api = DsmAPIName.fileStationProperty
        }
        // 成员查询和自锁检查期间权限可能变化，提交前再核对一次完整快照。
        guard try await loadFilePermissions(baseline.target) == baseline else {
            throw Self.advancedFileError(.conflict, "files.permissions.changed")
        }
        guard let capability = capabilities[api], capability.selectedVersion == 1 else { throw Self.advancedFileError(.apiUnavailable) }
        try Task.checkCancellation()
        var pending = PendingFilePermissionChange(change: change, api: api)
        pendingFilePermissions[key] = pending
        do {
            let response = try await client.call(path: capability.path, api: api, version: 1, method: "set",
                requestFormat: capability.requestFormat, parameters: parameters, credential: credential, as: PermissionTaskPayload.self)
            pending.acknowledged = true
            pending.taskID = baseline.isACL ? response.task_id : response.taskid
            pending.finished = pending.taskID == nil && !change.recursive && response.running != true
            pending.failed = response.hasFailure
            pendingFilePermissions[key] = pending
        } catch let error as DsmNetworkError {
            if case .api = error, DsmErrorMapper.map(error).category == .permissionDenied {
                pendingFilePermissions.removeValue(forKey: key)
                return try Self.permissionResult(.permissionDenied)
            }
            if case .invalidRequest = error { pendingFilePermissions.removeValue(forKey: key); throw DsmErrorMapper.map(error) }
        } catch { /* 已提交后不重放；由独立只读核查恢复。 */ }
        return try await reviewFilePermissionsCore(change)
    }

    public func reviewFilePermissions(_ change: FilePermissionChange) async throws -> MutationResult {
        let key = "permissions:" + change.baseline.target.path
        guard !activeAdvancedFileChanges.contains(key) else { throw Self.advancedFileError(.conflict, "files.advanced.pendingChange") }
        activeAdvancedFileChanges.insert(key)
        defer { activeAdvancedFileChanges.remove(key) }
        return try await reviewFilePermissionsCore(change)
    }

    private func reviewFilePermissionsCore(_ change: FilePermissionChange) async throws -> MutationResult {
        let key = "permissions:" + change.baseline.target.path
        guard var pending = pendingFilePermissions[key], pending.change == change else {
            throw Self.advancedFileError(.conflict, "files.permissions.changed")
        }
        do {
            if let taskID = pending.taskID, !pending.finished, !pending.failed {
                let idKey = change.baseline.isACL ? "task_id" : "taskid"
                let status: PermissionTaskPayload = try await advancedFileCall(pending.api, method: "status", parameters: [idKey: .string(taskID)])
                pending.finished = status.finished == true
                pending.failed = status.hasFailure
                pendingFilePermissions[key] = pending
            }
            if pending.failed { return try Self.permissionResult(.submittedButUnverified, partialFailure: true) }
            let updated = try await loadFilePermissions(change.baseline.target)
            guard Self.permissionChangeMatches(change, updated: updated),
                  !change.recursive || (pending.acknowledged && pending.finished),
                  pending.taskID == nil || pending.finished else { return try Self.permissionResult(.submittedButUnverified) }
            pendingFilePermissions.removeValue(forKey: key)
            return try Self.permissionResult(.confirmedSuccess)
        } catch { return try Self.permissionResult(.submittedButUnverified) }
    }

    func requireFilePrincipal(_ principal: FileStationPrincipal) async throws {
        var offset = 0
        repeat {
            let page = try await listFileStationPrincipals(prefix: principal.name, offset: offset, limit: 200)
            if page.items.contains(principal) { return }
            offset = page.nextOffset
            if offset == page.total { break }
            try Task.checkCancellation()
        } while true
        throw Self.advancedFileError(.conflict, "files.sharing.audienceChanged")
    }

    /// 读取可展示共享根等受保护位置，编辑范围与实际提交使用同一限制。
    private static func permissionTargetAllowsEditing(_ target: FileItem) -> Bool {
        target.path.split(separator: "/").count >= 2
            && (target.kind == .file || target.isDirectory)
            && target.mountPointType == "normal" && !target.isRecyclePath
    }

    private static func validPOSIXMode(_ mode: String) -> Bool {
        mode.utf8.count == 3 && mode.utf8.allSatisfy { (48...55).contains($0) }
    }
    private static func permissionRuleParameters(_ rule: FileACLRule) -> [String: DsmJSONValue] {
        var result: [String: DsmJSONValue] = ["owner_type": .string(rule.ownerType), "owner_name": .string(rule.ownerName),
            "permission_type": .string(rule.effect.rawValue),
            "permission": .object(Dictionary(uniqueKeysWithValues: FileACLRight.allCases.map { ($0.rawValue, .boolean(rule.rights.contains($0))) })),
            "inherit": .object(Dictionary(uniqueKeysWithValues: FileACLInheritance.allCases.map { ($0.rawValue, .boolean(rule.inheritance.contains($0))) }))]
        if let id = rule.ownerID { result["owner_id"] = .integer(id) }
        return result
    }
    private static func permissionChangeMatches(_ change: FilePermissionChange, updated: FilePermissionSnapshot) -> Bool {
        let old = change.baseline
        guard old.target.path == updated.target.path, old.target.kind == updated.target.kind,
              old.resolvedPath == updated.resolvedPath, old.isACL == updated.isACL else { return false }
        if old.isACL {
            let expected = change.explicitRules ?? old.rules.filter { $0.level == 0 }
            let actual = updated.rules.filter { $0.level == 0 }
            // DSM 可能重新排序或补上新账号编号，比较完整业务字段并保留已有账号编号核对。
            guard expected.count == actual.count, expected.allSatisfy({ rule in actual.contains {
                $0.ownerType == rule.ownerType && $0.ownerName == rule.ownerName && (rule.ownerID == nil || $0.ownerID == rule.ownerID)
                && $0.effect == rule.effect && $0.rights == rule.rights && $0.inheritance == rule.inheritance
            }}), old.isInherited == updated.isInherited,
                  old.rules.filter({ $0.level > 0 }) == updated.rules.filter({ $0.level > 0 }) else { return false }
            if let owner = change.owner { return updated.owner?.name == owner.name && updated.owner?.type == owner.kind.rawValue }
            return old.owner?.name == updated.owner?.name && old.owner?.type == updated.owner?.type
        }
        return updated.posixMode == (change.posixMode ?? old.posixMode)
            && updated.target.owner == (change.owner?.name ?? old.target.owner)
            && updated.target.group == (change.group?.name ?? old.target.group)
    }
    private static func permissionResult(_ status: MutationResultStatus, partialFailure: Bool = false) throws -> MutationResult {
        let success = status == .confirmedSuccess
        let unknown = status == .submittedButUnverified || status == .partialSuccess
        return try MutationResult(status: status, operation: "filePermissions", submitted: true, requiresRefresh: unknown,
            counts: .init(succeeded: success ? 1 : 0, failed: success || unknown ? 0 : 1, unknown: unknown ? 1 : 0),
            localizationKey: partialFailure ? "files.permissions.partial-failure" : nil, diagnosticTag: "file-station.permissions")
    }
}

private struct PermissionACLPayload: Decodable, Sendable {
    struct Rule: Decodable, Sendable {
        let owner_type: String; let owner_name: String; let owner_id: Int?; let owner_is_internal: Bool?
        let permission_type: FileACLRule.Effect; let permission: [String: Bool]; let inherit: [String: Bool]; let level: Int
    }
    let is_acl: Bool; let change_permission: Bool; let is_inherited: Bool; let acl: [Rule]
}
private struct PermissionOwnerPayload: Decodable, Sendable { let name: String; let type: String; let value: String; let hasPrivilege: Bool }
private struct PermissionSelfDenied: Decodable, Sendable { let is_denied: Bool }
private struct PermissionTaskPayload: Decodable, Sendable {
    let task_id: String?; let taskid: String?; let running: Bool?; let finished: Bool?; let result: String?; let errno: Int?
    let errItems: [PermissionErrorItem]?
    var hasFailure: Bool { result == "fail" || (errno != nil && errno != 0) || errItems?.isEmpty == false }
}
private struct PermissionErrorItem: Decodable, Sendable { /* 不解码或保留失败路径与服务端正文。 */ }

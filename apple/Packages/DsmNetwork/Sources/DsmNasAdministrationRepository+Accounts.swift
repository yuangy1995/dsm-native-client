import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public func changeDirectoryResult(_ change: NasDirectoryChange,
        checkpoint: @escaping @Sendable (NasDirectoryCheckpoint) async throws -> Void) async throws -> MutationResult {
        func result(_ status: MutationResultStatus, submitted: Bool, category: MutationErrorCategory? = nil) throws -> MutationResult {
            let unknown = status == .submittedButUnverified || status == .cancellationRequestedAfterSubmission
            return try MutationResult(status: status, operation: change.action.rawValue, submitted: submitted,
                requiresRefresh: unknown, counts: .init(succeeded: status == .confirmedSuccess ? 1 : 0,
                    failed: unknown || status == .confirmedSuccess || status == .cancelledBeforeSubmission ? 0 : 1, unknown: unknown ? 1 : 0),
                errorCategory: category, diagnosticTag: "directory.change.\(status.rawValue.lowercased())")
        }
        if Task.isCancelled { return try result(.cancelledBeforeSubmission, submitted: false) }
        let key = "\(change.kind.rawValue):\(change.name.lowercased())"
        guard activeDirectoryChangeKeys.insert(key).inserted else { return try result(.confirmedFailure, submitted: false, category: .conflict) }
        defer { activeDirectoryChangeKeys.remove(key) }
        do {
            let directory = try await loadAccountDirectoryForManagement()
            guard change.matches(directory, currentUsername: currentUsername ?? "") else {
                return try result(.confirmedFailure, submitted: false, category: .conflict)
            }
        } catch {
            switch (error as? AppError)?.category {
            case .authenticationRequired, .permissionDenied: return try result(.permissionDenied, submitted: false, category: .permission)
            case .apiUnavailable, .versionUnsupported: return try result(.unsupported, submitted: false, category: .unsupported)
            case .cancelled: return try result(.cancelledBeforeSubmission, submitted: false)
            default:
                if error is CancellationError { return try result(.cancelledBeforeSubmission, submitted: false) }
                return try result(.confirmedFailure, submitted: false, category: .unknown)
            }
        }
        if Task.isCancelled { return try result(.cancelledBeforeSubmission, submitted: false) }
        // 记录失败向上传递，绝不进入写请求；成功回执也必须在最终读取前落盘。
        try await checkpoint(.willSubmit)
        var accepted = false
        do {
            let parameters: [String: DsmParameterValue]
            switch change {
            case .saveUser(_, let draft, _): parameters = Self.accountParameters(draft)
            case .saveGroup(_, let draft): parameters = Self.groupParameters(draft)
            case .delete: parameters = ["name": .stringArray([change.name])]
            }
            try await callVoid(change.kind == .user ? DsmAPIName.coreUser : DsmAPIName.coreGroup,
                method: change.isDeletion ? "delete" : (change.original == nil ? "create" : "set"), version: 1, parameters: parameters)
            accepted = true
        } catch {
            // 明确拒绝不以目录的偶合变化覆盖；模糊结果只读恢复，不重发。
            switch (error as? AppError)?.category {
            case .permissionDenied, .authenticationRequired: return try result(.permissionDenied, submitted: true, category: .permission)
            case .apiUnavailable, .versionUnsupported: return try result(.unsupported, submitted: true, category: .unsupported)
            case .cancelled, .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown, nil: break
            default: return try result(.confirmedFailure, submitted: true, category: .unknown)
            }
        }
        if accepted { try await checkpoint(.accepted) }
        if Task.isCancelled { return try result(.cancellationRequestedAfterSubmission, submitted: true) }
        do {
            let directory = try await loadAccountDirectoryForManagement()
            let current = (change.kind == .user ? directory.users : directory.groups).first { $0.name.caseInsensitiveCompare(change.name) == .orderedSame }
            if change.isDeletion ? current == nil : (current.map(change.savedFieldsMatch) == true && (accepted || !change.requiresAcknowledgement)) {
                return try result(.confirmedSuccess, submitted: true)
            }
        } catch { /* 原目录读失败不能证明写结果，保留提交保护。 */ }
        return try result(.submittedButUnverified, submitted: true)
    }

    public func loadAccountsAndGroups() async throws -> NasAccountDirectory {
        try await loadAccountsAndGroups(version: nil)
    }

    public func loadAccountDirectoryForManagement() async throws -> NasAccountDirectory {
        guard [DsmAPIName.coreUser, DsmAPIName.coreGroup].allSatisfy({ name in
            guard let value = capabilities[name], value.selectedVersion != nil else { return false }
            return value.minVersion <= 1 && value.maxVersion >= 1
        }) else { throw unavailableError() }
        return try await loadAccountsAndGroups(version: 1)
    }

    private func loadAccountsAndGroups(version: Int?) async throws -> NasAccountDirectory {
        async let usersValue = call(
            DsmAPIName.coreUser,
            method: "list",
            version: version,
            parameters: [
                "offset": .integer(0),
                "limit": .integer(1_000),
                "additional": .stringArray([
                    "uid",
                    "description",
                    "email",
                    "expired",
                    "groups",
                    "can_edit",
                    "can_delete"
                ])
            ]
        )
        async let groupsValue = call(
            DsmAPIName.coreGroup,
            method: "list",
            version: version,
            parameters: [
                "offset": .integer(0),
                "limit": .integer(1_000),
                "additional": .stringArray([
                    "gid",
                    "description",
                    "can_edit",
                    "can_delete"
                ])
            ]
        )

        let usersPayload = try await usersValue
        let groupsPayload = try await groupsValue
        return NasAccountDirectory(
            users: try decodeDirectoryRows(usersPayload, key: "users", kind: .user),
            groups: try decodeDirectoryRows(groupsPayload, key: "groups", kind: .group)
        )
    }

    // 删除回读也走同一解析器，畸形/截断/重复身份不能被当作目标已消失。
    private func decodeDirectoryRows(_ payload: DsmDynamicJSON, key: String, kind: NasAccount.Kind) throws -> [NasAccount] {
        guard let rows = payload[key]?.array, rows.count < 1_000 else {
            throw verificationError(L10n.string("nas.accounts.response-incomplete"))
        }
        var seen: Set<String> = []
        return try rows.map { item in
            guard let row = item.object, case .string(let name)? = row["name"],
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(name.lowercased()).inserted else {
                throw verificationError(L10n.string("nas.accounts.response-incomplete"))
            }
            let extra: [String: DsmDynamicJSON]
            if let value = row["additional"], value != .null {
                guard let object = value.object else { throw verificationError(L10n.string("nas.accounts.response-incomplete")) }
                extra = object
            } else { extra = [:] }
            func field(_ name: String) throws -> DsmDynamicJSON? {
                let direct = row[name] == .null ? nil : row[name]
                let nested = extra[name] == .null ? nil : extra[name]
                if let direct, let nested, direct != nested { throw verificationError(L10n.string("nas.accounts.response-incomplete")) }
                return nested ?? direct
            }
            func text(_ name: String) throws -> String? {
                guard let value = try field(name) else { return nil }
                guard case .string(let result) = value else { throw verificationError(L10n.string("nas.accounts.response-incomplete")) }
                return result
            }
            func flag(_ name: String) throws -> Bool? {
                guard let value = try field(name) else { return nil }
                guard case .boolean(let result) = value else { throw verificationError(L10n.string("nas.accounts.response-incomplete")) }
                return result
            }
            let numericID: Int64?
            if let value = try field(kind == .user ? "uid" : "gid") {
                guard case .number(let number) = value, let identifier = Int64(exactly: number), identifier >= 0 else {
                    throw verificationError(L10n.string("nas.accounts.response-incomplete"))
                }
                numericID = identifier
            } else { numericID = nil }
            let description = try text("description")
            let email: String?
            let expired: Bool?
            if kind == .user {
                email = try text("email")
                // 官方用户列表使用 normal / now 表示启用 / 停用；旧布尔响应仍兼容。
                switch try field("expired") {
                case .string("normal"): expired = false
                case .string("now"): expired = true
                default: expired = try flag("expired")
                }
            } else { email = nil; expired = nil }
            var groups: [String]?
            if kind == .user, let value = try field("groups") {
                guard let array = value.array else { throw verificationError(L10n.string("nas.accounts.response-incomplete")) }
                var identities: Set<String> = []
                groups = try array.map { value in
                    guard case .string(let name) = value, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                          identities.insert(name.lowercased()).inserted else {
                        throw verificationError(L10n.string("nas.accounts.response-incomplete"))
                    }
                    return name
                }
            }
            let reserved = kind == .user ? ["admin", "guest"] : ["administrators", "users", "http"]
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isCurrent = kind == .user && currentUsername?.caseInsensitiveCompare(normalizedName) == .orderedSame
            // 旧领域的停用字段是非可空布尔；缺失时禁止进入会提交该默认值的编辑器。
            let editableFieldsKnown = description != nil && (kind == .group || (email != nil && expired != nil))
            return NasAccount(id: "\(kind == .user ? "user" : "group"):\(name)", name: name, kind: kind,
                numericID: numericID, description: description, email: email, groups: groups, isExpired: expired ?? false,
                // 官方列表可不返回 can_edit；字段完整即可打开编辑，明确拒绝仍生效。
                canEdit: try flag("can_edit") != false && editableFieldsKnown,
                canDelete: try flag("can_delete") == true && !reserved.contains(normalizedName) && !isCurrent)
        }
    }

    public func saveAccount(_ draft: NasAccountDraft) async throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.f4697c2ce8685eba")
            )
        }
        if draft.originalName == nil {
            guard !draft.password.isEmpty,
                  draft.password == draft.passwordConfirmation else {
                throw AppError(
                    category: .invalidResponse,
                    isRetryable: false,
                    safeUserMessage: L10n.string("shared.9c544f72c057fa2f")
                )
            }
        } else if !draft.password.isEmpty,
                  draft.password != draft.passwordConfirmation {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.e4a4a3382011b139")
            )
        }

        let targetName = draft.originalName ?? name
        if currentUsername?.caseInsensitiveCompare(targetName) == .orderedSame {
            guard !draft.isExpired else {
                throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: L10n.string("account.save.conflict"))
            }
            if let groups = draft.groups {
                let directory = try await loadAccountsAndGroups()
                guard let current = directory.users.first(where: { $0.name == targetName }),
                      current.groups?.sorted() == groups.sorted() else {
                    throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: L10n.string("account.save.conflict"))
                }
            }
        }
        try await callVoid(DsmAPIName.coreUser, method: draft.originalName == nil ? "create" : "set",
                           parameters: Self.accountParameters(draft))
    }

    private static func accountParameters(_ draft: NasAccountDraft) -> [String: DsmParameterValue] {
        var parameters: [String: DsmParameterValue] = [
            "name": .string(draft.originalName ?? draft.name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "description": .string(draft.description), "email": .string(draft.email), "expired": .boolean(draft.isExpired)
        ]
        if let groups = draft.groups { parameters["groups"] = .stringArray(groups) }
        if draft.originalName == nil || !draft.password.isEmpty {
            parameters["password"] = .string(draft.password)
            parameters["password_confirm"] = .string(draft.passwordConfirmation)
        }
        return parameters
    }

    public func deleteAccount(name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !["admin", "guest"].contains(trimmed.lowercased()),
              currentUsername?.caseInsensitiveCompare(trimmed) != .orderedSame else {
            throw AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.917cb22bc73cc211")
            )
        }
        try await callVoid(
            DsmAPIName.coreUser,
            method: "delete",
            parameters: ["name": .stringArray([trimmed])]
        )
    }

    /// 账号删除必须回读账号目录确认；请求提交后的未知结果不得自动重放。
    public func deleteAccountResult(name: String) async throws -> MutationResult {
        try await deleteDirectoryEntryResult(
            name: name,
            kind: .user,
            protectedNames: ["admin", "guest"]
        )
    }

    public func saveGroup(_ draft: NasGroupDraft) async throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.56a567d51676e519")
            )
        }
        try await callVoid(
            DsmAPIName.coreGroup,
            method: draft.originalName == nil ? "create" : "set",
            parameters: Self.groupParameters(draft)
        )
    }

    private static func groupParameters(_ draft: NasGroupDraft) -> [String: DsmParameterValue] {
        ["name": .string(draft.originalName ?? draft.name.trimmingCharacters(in: .whitespacesAndNewlines)),
         "description": .string(draft.description)]
    }

    public func deleteGroup(name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !["administrators", "users", "http"].contains(trimmed.lowercased()) else {
            throw AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.966bbfaa2a0d098a")
            )
        }
        try await callVoid(
            DsmAPIName.coreGroup,
            method: "delete",
            parameters: ["name": .stringArray([trimmed])]
        )
    }

    /// 群组删除必须回读群组目录确认；请求提交后的未知结果不得自动重放。
    public func deleteGroupResult(name: String) async throws -> MutationResult {
        try await deleteDirectoryEntryResult(
            name: name,
            kind: .group,
            protectedNames: ["administrators", "users", "http"]
        )
    }
}

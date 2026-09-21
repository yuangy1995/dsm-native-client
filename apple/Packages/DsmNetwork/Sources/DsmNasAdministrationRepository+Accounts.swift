import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public func loadAccountsAndGroups() async throws -> NasAccountDirectory {
        async let usersValue = call(
            DsmAPIName.coreUser,
            method: "list",
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
            throw verificationError(L10n.string("shared.db6b9590023d51f5"))
        }
        var seen: Set<String> = []
        return try rows.map { item in
            guard let row = item.object, case .string(let name)? = row["name"],
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(name.lowercased()).inserted else {
                throw verificationError(L10n.string("shared.db6b9590023d51f5"))
            }
            let extra: [String: DsmDynamicJSON]
            if let value = row["additional"], value != .null {
                guard let object = value.object else { throw verificationError(L10n.string("shared.db6b9590023d51f5")) }
                extra = object
            } else { extra = [:] }
            func field(_ name: String) throws -> DsmDynamicJSON? {
                let direct = row[name] == .null ? nil : row[name]
                let nested = extra[name] == .null ? nil : extra[name]
                if let direct, let nested, direct != nested { throw verificationError(L10n.string("shared.db6b9590023d51f5")) }
                return nested ?? direct
            }
            func text(_ name: String) throws -> String? {
                guard let value = try field(name) else { return nil }
                guard case .string(let result) = value else { throw verificationError(L10n.string("shared.db6b9590023d51f5")) }
                return result
            }
            func flag(_ name: String) throws -> Bool? {
                guard let value = try field(name) else { return nil }
                guard case .boolean(let result) = value else { throw verificationError(L10n.string("shared.db6b9590023d51f5")) }
                return result
            }
            let numericID: Int64?
            if let value = try field(kind == .user ? "uid" : "gid") {
                guard case .number(let number) = value, let identifier = Int64(exactly: number), identifier >= 0 else {
                    throw verificationError(L10n.string("shared.db6b9590023d51f5"))
                }
                numericID = identifier
            } else { numericID = nil }
            let description = try text("description")
            let email: String?
            let expired: Bool?
            if kind == .user { email = try text("email"); expired = try flag("expired") }
            else { email = nil; expired = nil }
            var groups: [String]?
            if kind == .user, let value = try field("groups") {
                guard let array = value.array else { throw verificationError(L10n.string("shared.db6b9590023d51f5")) }
                var identities: Set<String> = []
                groups = try array.map { value in
                    guard case .string(let name) = value, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                          identities.insert(name.lowercased()).inserted else {
                        throw verificationError(L10n.string("shared.db6b9590023d51f5"))
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
                canEdit: try flag("can_edit") == true && editableFieldsKnown,
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
        var parameters: [String: DsmParameterValue] = [
            "name": .string(draft.originalName ?? name),
            "description": .string(draft.description),
            "email": .string(draft.email),
            "expired": .boolean(draft.isExpired)
        ]
        if let groups = draft.groups {
            parameters["groups"] = .stringArray(groups)
        }
        if draft.originalName == nil {
            parameters["password"] = .string(draft.password)
            parameters["password_confirm"] = .string(draft.passwordConfirmation)
        } else if !draft.password.isEmpty {
            parameters["password"] = .string(draft.password)
            parameters["password_confirm"] = .string(draft.passwordConfirmation)
        }
        try await callVoid(
            DsmAPIName.coreUser,
            method: draft.originalName == nil ? "create" : "set",
            parameters: parameters
        )
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
            parameters: [
                "name": .string(draft.originalName ?? name),
                "description": .string(draft.description)
            ]
        )
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

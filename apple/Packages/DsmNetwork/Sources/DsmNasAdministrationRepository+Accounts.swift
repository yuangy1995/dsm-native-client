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
        let users = usersPayload.objects("users").compactMap { raw -> NasAccount? in
            let item = DsmDynamicJSON.object(raw)
            guard let name = item.string(["name"]) else { return nil }
            return NasAccount(
                id: "user:\(name)",
                name: name,
                kind: .user,
                numericID: item.integer(["uid"]),
                description: item.string(["description"]),
                email: item.string(["email"]),
                groups: item["groups"] == nil ? nil : item.strings(["groups"]),
                isExpired: item.boolean(["expired"]) ?? false,
                canEdit: item.boolean(["can_edit"]) ?? true,
                canDelete: item.boolean(["can_delete"])
                    ?? !["admin", "guest"].contains(name.lowercased())
            )
        }
        let groups = groupsPayload.objects("groups").compactMap { raw -> NasAccount? in
            let item = DsmDynamicJSON.object(raw)
            guard let name = item.string(["name"]) else { return nil }
            return NasAccount(
                id: "group:\(name)",
                name: name,
                kind: .group,
                numericID: item.integer(["gid"]),
                description: item.string(["description"]),
                canEdit: item.boolean(["can_edit"]) ?? true,
                canDelete: item.boolean(["can_delete"])
                    ?? !["administrators", "users", "http"].contains(name.lowercased())
            )
        }
        return NasAccountDirectory(users: users, groups: groups)
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
              !["admin", "guest"].contains(trimmed.lowercased()) else {
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

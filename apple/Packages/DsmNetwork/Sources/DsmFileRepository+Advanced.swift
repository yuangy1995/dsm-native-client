import DsmCore
import DsmLocalization
import Foundation

extension DsmFileRepository {
    /// 根据绑定会话的真实文件服务权限开放操作；测试证据等级不作为功能开关。
    public func loadFileStationAdvancedAccess() async throws -> FileStationAdvancedAccess {
        let privileges: DsmDesktopAppPrivileges = try await advancedFileCall(
            DsmAPIName.desktopInitData, method: "get_user_service", version: 1,
            parameters: ["launch_app": .string("null")], httpMethod: "GET")
        return .init(isAdministrator: privileges.isAdministrator,
                     writesEnabled: privileges.applications[.files] == true)
    }

    func requireAdvancedFileWrite(administrator: Bool = false) async throws {
        let access = try await loadFileStationAdvancedAccess()
        guard access.writesEnabled else { throw Self.advancedFileError(.permissionDenied, "files.advanced.permissionUnavailable") }
        guard !administrator || access.isAdministrator else { throw Self.advancedFileError(.permissionDenied, "files.advanced.adminRequired") }
    }

    func advancedFileCall<T: Decodable & Sendable>(
        _ name: String, method: String, version: Int = 1,
        parameters: [String: DsmParameterValue] = [:], httpMethod: String = "POST"
    ) async throws -> T {
        guard let capability = capabilities[name], let selected = capability.selectedVersion, selected >= version,
              capability.minVersion <= version, capability.maxVersion >= version else {
            throw Self.advancedFileError(.apiUnavailable, "files.advanced.unavailable")
        }
        do {
            return try await client.call(path: capability.path, api: name, version: version, method: method,
                requestFormat: capability.requestFormat, parameters: parameters, credential: credential,
                httpMethod: httpMethod, as: T.self)
        } catch let error as DsmNetworkError { throw DsmErrorMapper.map(error) }
    }

    static func advancedFileError(_ category: AppErrorCategory = .invalidResponse, _ key: String = "files.advanced.readFailed") -> AppError {
        AppError(category: category, isRetryable: false, safeUserMessage: L10n.string(key))
    }

    public func listFileStationPrincipals(prefix: String, offset: Int, limit: Int) async throws -> FileStationPrincipalPage {
        guard offset >= 0, (1...200).contains(limit) else { throw Self.advancedFileError() }
        let page: FileStationPrincipalPayload = try await advancedFileCall(DsmAPIName.fileStationUserGroup, method: "list_all",
            parameters: ["type": .string("all"), "prefix": .string(prefix), "offset": .integer(offset), "limit": .integer(limit)])
        guard page.total >= offset, page.owners.count <= limit, offset + page.owners.count <= page.total,
              !page.owners.isEmpty || offset == page.total else { throw Self.advancedFileError() }
        let items = try page.owners.map { row -> FileStationPrincipal in
            guard !row.name.isEmpty, let kind = FileStationPrincipal.Kind(rawValue: row.type) else { throw Self.advancedFileError() }
            return .init(name: row.name, kind: kind)
        }
        guard Set(items.map(\.id)).count == items.count else { throw Self.advancedFileError() }
        return .init(items: items, total: page.total, nextOffset: offset + items.count)
    }

    static func shareDateMatches(_ value: String?, _ expected: FileShareLinkCalendarDate?) -> Bool {
        guard let expected else { return value == nil }
        return value == expected.iso8601 || value == expected.iso8601 + " 00:00:00"
    }

    static func fileRequestMatches(_ link: FileShareLink, _ configuration: FileRequestConfiguration?) -> Bool {
        guard let configuration else { return link.advanced?.isFileRequest != true }
        return link.advanced?.isFileRequest == true && link.advanced?.allowsUpload == true
            && link.advanced?.requestName == configuration.name && link.advanced?.requestMessage == configuration.message
    }

    func advancedShareParameters(_ change: FileShareAdvancedChange, baseline: FileShareLink) async throws -> [String: DsmParameterValue] {
        guard let original = baseline.advanced else { throw Self.advancedFileError(.versionUnsupported, "files.advanced.unavailable") }
        var result: [String: DsmParameterValue] = [:]
        switch change.audience {
        case .keep: break
        case .anyone: result["protect_type"] = .string("none")
        case .principals(let principals):
            guard !original.isFileRequest, !principals.isEmpty, Set(principals).count == principals.count else {
                throw Self.advancedFileError(.invalidResponse, "files.sharing.chooseAudience")
            }
            for principal in principals {
                var offset = 0
                var found = false
                repeat {
                    let page = try await listFileStationPrincipals(prefix: principal.name, offset: offset, limit: 200)
                    found = page.items.contains(principal)
                    offset = page.nextOffset
                    if found || offset == page.total { break }
                    try Task.checkCancellation()
                } while true
                guard found else { throw Self.advancedFileError(.conflict, "files.sharing.audienceChanged") }
            }
            let users = principals.filter { $0.kind == .user }.map(\.name).sorted()
            let groups = principals.filter { $0.kind == .group }.map(\.name).sorted()
            result["protect_type"] = .string("user")
            result["protect_users"] = .stringArray(users)
            result["protect_groups"] = .stringArray(groups)
            result["new_protect_users"] = .stringArray(users.filter { !original.users.contains($0) })
            result["new_protect_groups"] = .stringArray(groups.filter { !original.groups.contains($0) })
        }
        if let count = change.maximumAccesses {
            guard (0...9_999).contains(count) else { throw Self.advancedFileError(.invalidResponse, "files.sharing.invalidAccessLimit") }
            result["expire_times"] = .integer(count)
        }
        if let name = change.requestName {
            guard original.isFileRequest else { throw Self.advancedFileError() }
            result["request_name"] = .string(name)
        }
        if let message = change.requestMessage {
            guard original.isFileRequest else { throw Self.advancedFileError() }
            result["request_info"] = .string(message)
        }
        return result
    }

    static func advancedShareMatches(_ change: FileShareAdvancedChange?, baseline: FileShareLink, updated: FileShareLink) -> Bool {
        guard let old = baseline.advanced else { return change == nil }
        guard let new = updated.advanced, old.isFileRequest == new.isFileRequest,
              old.allowsUpload == new.allowsUpload,
              new.maximumAccesses == (change?.maximumAccesses ?? old.maximumAccesses),
              new.requestName == (change?.requestName ?? old.requestName),
              new.requestMessage == (change?.requestMessage ?? old.requestMessage) else { return false }
        guard let change else { return old.users == new.users && old.groups == new.groups }
        switch change.audience {
        case .keep: return old.protection == new.protection && Set(old.users) == Set(new.users) && Set(old.groups) == Set(new.groups)
        case .anyone: return new.protection == .none
        case .principals(let principals):
            return new.protection == .users && Set(new.users) == Set(principals.filter { $0.kind == .user }.map(\.name))
                && Set(new.groups) == Set(principals.filter { $0.kind == .group }.map(\.name))
        }
    }
}

private struct FileStationPrincipalPayload: Decodable, Sendable {
    struct Principal: Decodable, Sendable { let name: String; let type: String }
    let owners: [Principal]
    let total: Int
}

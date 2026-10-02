import DsmCore
import DsmLocalization
import Foundation

extension DsmFileRepository {
    public func loadFileStationSettings() async throws -> FileStationSettings {
        let data: FileSettingsPayload = try await advancedFileCall(DsmAPIName.fileStationSettings, method: "get")
        guard data.rf_allow != .selected, data.vd_allow != .selected,
              let limit = Int(data.sharing_default_limit), (0...999_999_999).contains(limit),
              data.schedule_plan.isEmpty || FileStationWeeklySchedule.isValid(data.schedule_plan, perAccount: false),
              let policy = FileStationBandwidthPolicy(rawValue: ["bandwidth_disable": "disabled", "bandwidth_enable": "enabled",
                "bandwidth_schedule": "scheduled"][data.bandwidth_enable] ?? "") else { throw Self.advancedFileError() }
        return .init(profileID: profileID, recordsTransfers: data.transfer_log_enable, usesDefaultPermissions: data.use_unix_default_perm,
            showsAccounts: data.enable_list_usergrp, sharing: data.sharing_allow, fileRequests: data.file_request_allow,
            remoteMounts: data.rf_allow, isoMounts: data.vd_allow,
            sharingAccounts: try Self.policyMembers(users: data.sharing_privilege.items, groups: data.sharing_group_privilege.items),
            requestAccounts: try Self.policyMembers(users: data.file_request_privilege.items, groups: data.file_request_group_privilege.items),
            defaultLinkLimit: limit, bandwidth: policy, schedule: data.schedule_plan,
            usesCustomSharingPage: ["true": true, "false": false][data.enable_sharing_custom_setting ?? ""])
    }

    public func loadFileStationMountAccess() async throws -> FileStationMountAccessScope {
        let data: FileMountAccessPayload = try await advancedFileCall(DsmAPIName.fileStationVFSUser, method: "get",
            parameters: ["content": .string("user_enabled_type")])
        return data.user_enabled_type
    }

    public func loadFileStationMountDirectories() async throws -> FileStationMountDirectories {
        var items: [FileStationMountDirectory] = [.init(source: .local, name: "")]
        var unavailable = false
        do {
            let ldap: FileMountLDAPPayload = try await advancedFileCall(DsmAPIName.coreDirectoryLDAP, method: "get")
            if ldap.enable_client { items.append(.init(source: .ldap, name: "")) }
        } catch { try Task.checkCancellation(); unavailable = true }
        do {
            let domain: FileMountDomainPayload = try await advancedFileCall(DsmAPIName.coreDirectoryDomain, method: "get")
            if domain.enable_domain {
                let joined: FileMountDomainJoinPayload = try await advancedFileCall(DsmAPIName.coreDirectoryDomain, method: "test_dc")
                if joined.test_join_success {
                    let data: FileMountDomainListPayload = try await advancedFileCall(DsmAPIName.coreDirectoryDomain, method: "get_domain_list", version: 2)
                    let directories = try data.domain_list.map { row -> FileStationMountDirectory in
                        guard !row.name.isEmpty, !row.value.isEmpty else { throw Self.advancedFileError() }
                        return .init(source: .domain(row.value), name: row.name)
                    }
                    guard !directories.isEmpty, Set(directories.map(\.id)).count == directories.count else { throw Self.advancedFileError() }
                    items += directories
                } else { unavailable = true }
            }
        } catch { try Task.checkCancellation(); unavailable = true }
        return .init(items: items, hasUnavailableSources: unavailable)
    }

    public func listFileStationMountAccounts(kind: FileStationPrincipal.Kind, query: String, offset: Int, limit: Int) async throws -> FileStationMountAccountPage {
        try await listFileStationMountAccounts(source: .local, kind: kind, query: query, offset: offset, limit: limit)
    }

    public func listFileStationMountAccounts(source: FileStationMountAccountSource, kind: FileStationPrincipal.Kind, query: String, offset: Int, limit: Int) async throws -> FileStationMountAccountPage {
        guard offset >= 0, (1...200).contains(limit) else { throw Self.advancedFileError() }
        var parameters: [String: DsmParameterValue] = [
            "content": .string(kind == .user ? "user_settings" : "group_settings"),
            "type": .string(source.type), "usergroup": .string(kind.rawValue), "substr": .string(query),
            "offset": .integer(offset), "limit": .integer(limit)]
        if case .domain(let name) = source {
            guard !name.isEmpty else { throw Self.advancedFileError() }
            parameters["domain"] = .string(name)
        }
        let data: FileMountAccountPayload = try await advancedFileCall(DsmAPIName.fileStationVFSUser, method: "get", parameters: parameters)
        guard data.total >= offset, data.usergrp_settings.count <= limit, offset + data.usergrp_settings.count <= data.total,
              !data.usergrp_settings.isEmpty || offset == data.total else { throw Self.advancedFileError() }
        let items = try data.usergrp_settings.map { row -> FileStationMountAccount in
            guard let id = kind == .user ? row.uid : row.gid, id >= 0, !row.name.isEmpty else { throw Self.advancedFileError() }
            return .init(profileID: profileID, id: .init(kind: kind, value: id), name: row.name, enabled: row.enabled, canModify: row.is_modifiable, source: source)
        }
        guard Set(items.map(\.id)).count == items.count else { throw Self.advancedFileError() }
        return .init(items: items, total: data.total, nextOffset: offset + items.count)
    }

    public func listFileStationPolicyAccounts(kind: FileStationPrincipal.Kind, query: String, offset: Int, limit: Int) async throws -> FileStationPolicyAccountPage {
        guard offset >= 0, (1...200).contains(limit) else { throw Self.advancedFileError() }
        let data: FilePolicyAccountsPayload = try await advancedFileCall(DsmAPIName.fileStationUserGroup,
            method: kind == .user ? "list_user" : "list_group",
            parameters: ["type": .string("all"), "query": .string(query), "offset": .integer(offset), "limit": .integer(limit)])
        guard let rows = kind == .user ? data.users : data.groups,
              data.total >= offset, rows.count <= limit, offset + rows.count <= data.total,
              !rows.isEmpty || offset == data.total else { throw Self.advancedFileError() }
        let items = try rows.map { row -> FileStationPolicyAccount in
            guard let id = kind == .user ? row.uid : row.gid, id >= 0, !row.name.isEmpty,
                  kind != .user || row.is_admin != nil else { throw Self.advancedFileError() }
            return .init(id: .init(kind: kind, value: id), name: row.name, isAdministrator: row.is_admin == true)
        }
        guard Set(items.map(\.id)).count == items.count else { throw Self.advancedFileError() }
        return .init(items: items, total: data.total, nextOffset: offset + items.count)
    }

    public func listFileStationBandwidth(ownerType: FileStationBandwidthEntry.OwnerType, offset: Int, limit: Int) async throws -> FileStationBandwidthPage {
        guard offset >= 0, (1...200).contains(limit) else { throw Self.advancedFileError() }
        let data: FileBandwidthPayload = try await advancedFileCall(DsmAPIName.coreBandwidthControl, method: "list",
            parameters: ["protocol": .string("FileStation"), "owner_type": .string(ownerType.rawValue),
                "offset": .integer(offset), "limit": .integer(limit)])
        guard data.total >= offset, data.bandwidths.count <= limit, offset + data.bandwidths.count <= data.total,
              !data.bandwidths.isEmpty || offset == data.total else { throw Self.advancedFileError() }
        let items = try data.bandwidths.map { row -> FileStationBandwidthEntry in
            guard row.protocol == "FileStation", row.owner_type == ownerType, !row.name.isEmpty,
                  row.schedule_plan.isEmpty || FileStationWeeklySchedule.isValid(row.schedule_plan, perAccount: true) else { throw Self.advancedFileError() }
            return .init(profileID: profileID, name: row.name, ownerType: ownerType, policy: row.policy, schedule: row.schedule_plan,
                uploadLimit: row.upload_limit_1, downloadLimit: row.download_limit_1,
                alternateUploadLimit: row.upload_limit_2, alternateDownloadLimit: row.download_limit_2)
        }
        guard Set(items.map(\.id)).count == items.count else { throw Self.advancedFileError() }
        return .init(items: items, total: data.total, nextOffset: offset + items.count)
    }

    public func loadFileStationSharingTheme() async throws -> FileStationSharingTheme {
        let data: FileSharingThemePayload = try await advancedFileCall(DsmAPIName.coreFileSharingTheme, method: "get")
        return .init(profileID: profileID, customLogo: data.enable_logo_customize, customBackground: data.enable_background_customize,
            logoPosition: data.logo_position, backgroundPosition: data.background_position, backgroundColor: data.background_color,
            footer: data.footer_msg, footerUsesHTML: data.enable_footer_html,
            logoSequence: data.logo_seq?.value, backgroundSequence: data.background_seq?.value)
    }

    public func changeFileStationSettings(_ change: FileStationSettingsChange, confirmed: Bool) async throws -> MutationResult {
        let key = Self.settingsKey(change)
        guard confirmed, !activeAdvancedFileChanges.contains(key), pendingFileStationSettings[key] == nil else {
            throw Self.advancedFileError(.conflict, "files.settings.confirmRequired")
        }
        activeAdvancedFileChanges.insert(key)
        defer { activeAdvancedFileChanges.remove(key) }
        try await requireAdvancedFileWrite(administrator: true)
        guard try await fileSettingsMatch(change, updated: false) else { throw Self.advancedFileError(.conflict, "files.settings.changed") }
        let (api, parameters) = try await fileSettingsParameters(change)
        guard !parameters.isEmpty, let capability = capabilities[api], capability.selectedVersion == 1 else { throw Self.advancedFileError() }
        // 账号列表核对可能跨多页，最后再读取设置，避免覆盖其他管理员的新修改。
        guard try await fileSettingsMatch(change, updated: false) else { throw Self.advancedFileError(.conflict, "files.settings.changed") }
        try Task.checkCancellation()
        pendingFileStationSettings[key] = change
        acknowledgedFileStationSettings.remove(key)
        do {
            try await client.callVoid(path: capability.path, api: api, version: 1, method: "set", requestFormat: capability.requestFormat,
                parameters: parameters, credential: credential)
            acknowledgedFileStationSettings.insert(key)
        } catch let error as DsmNetworkError {
            if case .invalidRequest = error { pendingFileStationSettings.removeValue(forKey: key); throw DsmErrorMapper.map(error) }
            if case .api = error, DsmErrorMapper.map(error).category == .permissionDenied {
                pendingFileStationSettings.removeValue(forKey: key)
                return try Self.settingsResult(.permissionDenied)
            }
        } catch { /* 结果未知时只回读，不再次保存。 */ }
        return try await reviewFileStationSettingsCore(change)
    }

    public func reviewFileStationSettings(_ change: FileStationSettingsChange) async throws -> MutationResult {
        let key = Self.settingsKey(change)
        guard !activeAdvancedFileChanges.contains(key) else { throw Self.advancedFileError(.conflict, "files.advanced.pendingChange") }
        activeAdvancedFileChanges.insert(key)
        defer { activeAdvancedFileChanges.remove(key) }
        return try await reviewFileStationSettingsCore(change)
    }

    private func reviewFileStationSettingsCore(_ change: FileStationSettingsChange) async throws -> MutationResult {
        let key = Self.settingsKey(change)
        guard pendingFileStationSettings[key] == change else { throw Self.advancedFileError(.conflict, "files.settings.changed") }
        if (try? await fileSettingsMatch(change, updated: true)) == true {
            pendingFileStationSettings.removeValue(forKey: key)
            acknowledgedFileStationSettings.remove(key)
            return try Self.settingsResult(.confirmedSuccess)
        }
        return try Self.settingsResult(.submittedButUnverified)
    }

    private func fileSettingsMatch(_ change: FileStationSettingsChange, updated: Bool) async throws -> Bool {
        switch change {
        case .general(let old, let new):
            guard old.profileID == profileID, new.profileID == profileID else { return false }
            return try await loadFileStationSettings() == (updated ? new : old)
        case .mountAccess(let old, let new, let id):
            guard id == profileID else { return false }
            return try await loadFileStationMountAccess() == (updated ? new : old)
        case .mountAccount(let baseline, let enabled):
            guard baseline.profileID == profileID else { return false }
            var offset = 0
            repeat {
                let page = try await listFileStationMountAccounts(source: baseline.source, kind: baseline.id.kind, query: baseline.name, offset: offset, limit: 200)
                if let item = page.items.first(where: { $0.id == baseline.id }) {
                    return item.source == baseline.source && item.name == baseline.name && item.canModify == baseline.canModify
                        && item.enabled == (updated ? enabled : baseline.enabled)
                }
                offset = page.nextOffset
                if offset == page.total { return false }
                try Task.checkCancellation()
            } while true
        case .bandwidth(let old, let new):
            guard old.profileID == profileID, new.profileID == profileID, old.id == new.id else { return false }
            var offset = 0
            repeat {
                let page = try await listFileStationBandwidth(ownerType: old.ownerType, offset: offset, limit: 200)
                if let item = page.items.first(where: { $0.id == old.id }) { return item == (updated ? new : old) }
                offset = page.nextOffset
                if offset == page.total { return false }
                try Task.checkCancellation()
            } while true
        case .theme(let old, let new):
            guard old.profileID == profileID, new.profileID == profileID else { return false }
            let current = try await loadFileStationSharingTheme()
            if !updated { return current == old }
            guard current.customLogo == new.customLogo, current.customBackground == new.customBackground,
                  current.logoPosition == new.logoPosition, current.backgroundPosition == new.backgroundPosition,
                  current.backgroundColor == new.backgroundColor, current.footer == new.footer,
                  current.footerUsesHTML == new.footerUsesHTML else { return false }
            // 回执说明选定来源已被接受，序列变化说明新图片已生效；回执丢失时不能只凭序列变化推断是本次写入。
            if new.logoImage != nil {
                guard acknowledgedFileStationSettings.contains(Self.settingsKey(change)), let sequence = current.logoSequence,
                      sequence != old.logoSequence else { return false }
            }
            if new.backgroundImage != nil {
                guard acknowledgedFileStationSettings.contains(Self.settingsKey(change)), let sequence = current.backgroundSequence,
                      sequence != old.backgroundSequence else { return false }
            }
            return true
        }
    }

    private func fileSettingsParameters(_ change: FileStationSettingsChange) async throws -> (String, [String: DsmParameterValue]) {
        switch change {
        case .general(let old, let new):
            guard new.remoteMounts != .selected, new.isoMounts != .selected, (0...999_999_999).contains(new.defaultLinkLimit),
                  new.schedule.isEmpty || FileStationWeeklySchedule.isValid(new.schedule, perAccount: false),
                  new.bandwidth != .scheduled || FileStationWeeklySchedule.isValid(new.schedule, perAccount: false) else { throw Self.advancedFileError() }
            var result: [String: DsmParameterValue] = [:]
            if old.recordsTransfers != new.recordsTransfers { result["transfer_log_enable"] = .boolean(new.recordsTransfers) }
            if old.usesDefaultPermissions != new.usesDefaultPermissions { result["use_unix_default_perm"] = .boolean(new.usesDefaultPermissions) }
            if old.showsAccounts != new.showsAccounts { result["enable_list_usergrp"] = .boolean(new.showsAccounts) }
            if old.sharing != new.sharing { result["sharing_allow"] = .string(new.sharing.rawValue) }
            if old.fileRequests != new.fileRequests { result["file_request_allow"] = .string(new.fileRequests.rawValue) }
            if old.remoteMounts != new.remoteMounts { result["rf_allow"] = .string(new.remoteMounts.rawValue) }
            if old.isoMounts != new.isoMounts { result["vd_allow"] = .string(new.isoMounts.rawValue) }
            if old.defaultLinkLimit != new.defaultLinkLimit { result["sharing_default_limit"] = .integer(new.defaultLinkLimit) }
            if old.bandwidth != new.bandwidth {
                result["bandwidth_enable"] = .string(new.bandwidth == .disabled ? "bandwidth_disable" : new.bandwidth == .enabled ? "bandwidth_enable" : "bandwidth_schedule")
            }
            if old.schedule != new.schedule { result["schedule_plan"] = .string(new.schedule) }
            if old.usesCustomSharingPage != new.usesCustomSharingPage {
                guard old.usesCustomSharingPage != nil, let enabled = new.usesCustomSharingPage else { throw Self.advancedFileError() }
                result["enable_sharing_custom_setting"] = .boolean(enabled)
            }
            for (prefix, previous, desired) in [("sharing", old.sharingAccounts, new.sharingAccounts), ("file_request", old.requestAccounts, new.requestAccounts)] {
                for kind in FileStationPrincipal.Kind.allCases {
                    let added = desired.subtracting(previous).filter { $0.kind == kind }
                    let removed = previous.subtracting(desired).filter { $0.kind == kind }
                    let affected = added.union(removed)
                    if !affected.isEmpty { try await requirePolicyAccounts(affected) }
                    let field = prefix + (kind == .group ? "_group_privilege" : "_privilege")
                    if !added.isEmpty { result["enabled_" + field] = .string(added.sorted().map { String($0.value) }.joined(separator: ",")) }
                    if !removed.isEmpty { result["disabled_" + field] = .string(removed.sorted().map { String($0.value) }.joined(separator: ",")) }
                }
            }
            return (DsmAPIName.fileStationSettings, result)
        case .mountAccess(let old, let new, _):
            guard old != new else { throw Self.advancedFileError() }
            return (DsmAPIName.fileStationVFSUser, ["settings": .object(["user_enabled_type": .string(new.rawValue)])])
        case .mountAccount(let baseline, let enabled):
            guard baseline.canModify, baseline.enabled != enabled else { throw Self.advancedFileError(.permissionDenied, "files.settings.accountLocked") }
            let kind = baseline.id.kind
            return (DsmAPIName.fileStationVFSUser, ["settings": .object([
                kind == .user ? "user_settings" : "group_settings": .array([.object([
                    kind == .user ? "uid" : "gid": .integer(baseline.id.value), "enabled": .boolean(enabled)])])])])
        case .bandwidth(let old, let new):
            guard old != new, [new.uploadLimit, new.downloadLimit, new.alternateUploadLimit, new.alternateDownloadLimit].allSatisfy({
                $0 == 0 || (10...999_999_999).contains($0)
            }), new.schedule.isEmpty || FileStationWeeklySchedule.isValid(new.schedule, perAccount: true),
                new.policy != .scheduled || FileStationWeeklySchedule.isValid(new.schedule, perAccount: true) else { throw Self.advancedFileError(.invalidResponse, "files.settings.invalidRate") }
            return (DsmAPIName.coreBandwidthControl, ["bandwidths": .objectArray([["name": .string(old.name), "protocol": .string("FileStation"),
                "owner_type": .string(old.ownerType.rawValue), "policy": .string(new.policy.rawValue), "schedule_plan": .string(new.schedule),
                "upload_limit_1": .integer(new.uploadLimit), "download_limit_1": .integer(new.downloadLimit),
                "upload_limit_2": .integer(new.alternateUploadLimit), "download_limit_2": .integer(new.alternateDownloadLimit)]])])
        case .theme(let old, let new):
            guard old != new, new.footer.count <= 512, !new.footer.contains(where: { $0 == "\n" || $0 == "\r" }),
                  new.backgroundColor.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
                  (old.customLogo || !new.customLogo || new.logoImage != nil), (old.customBackground || !new.customBackground || new.backgroundImage != nil) else { throw Self.advancedFileError(.invalidResponse, "files.settings.invalidTheme") }
            // 官方主题表单提交完整布局；仅明确选择新图片时才加入其来源与路径。
            var fields: [String: DsmParameterValue] = ["enable_logo_customize": .boolean(new.customLogo),
                "enable_background_customize": .boolean(new.customBackground), "logo_position": .string(new.logoPosition.rawValue),
                "background_position": .string(new.backgroundPosition.rawValue), "background_color": .string(new.backgroundColor),
                "footer_msg": .string(new.footer), "enable_footer_html": .boolean(new.footerUsesHTML)]
            for (kind, image, enabled) in [(FileStationThemeImage.Kind.logo, new.logoImage, new.customLogo), (.background, new.backgroundImage, new.customBackground)] {
                if let image {
                    guard image.kind == kind, enabled else { throw Self.advancedFileError() }
                    try await validateThemeImage(image)
                    fields[kind.rawValue + "_type"] = .string(image.source.rawValue)
                    fields[kind.rawValue + "_path"] = .string(image.source == .nas ? image.path : (image.path as NSString).lastPathComponent)
                }
            }
            return (DsmAPIName.coreFileSharingTheme, fields)
        }
    }

    private func requirePolicyAccounts(_ accounts: Set<FileStationPolicyAccountID>) async throws {
        for kind in FileStationPrincipal.Kind.allCases {
            var remaining = accounts.filter { $0.kind == kind }
            var offset = 0
            while !remaining.isEmpty {
                let page = try await listFileStationPolicyAccounts(kind: kind, query: "", offset: offset, limit: 200)
                for item in page.items where remaining.contains(item.id) {
                    guard !item.isAdministrator else { throw Self.advancedFileError(.permissionDenied, "files.settings.adminAccess") }
                    remaining.remove(item.id)
                }
                offset = page.nextOffset
                if offset == page.total { break }
                try Task.checkCancellation()
            }
            guard remaining.isEmpty else { throw Self.advancedFileError(.conflict, "files.sharing.audienceChanged") }
        }
    }

    private static func policyMembers(users: [FileSettingsPayload.Privilege], groups: [FileSettingsPayload.Privilege]) throws -> Set<FileStationPolicyAccountID> {
        var ids = Set<FileStationPolicyAccountID>(), result = Set<FileStationPolicyAccountID>()
        for (kind, rows) in [(FileStationPrincipal.Kind.user, users), (.group, groups)] {
            for row in rows {
                guard let value = kind == .user ? row.uid : row.gid, value >= 0 else { throw advancedFileError() }
                let id = FileStationPolicyAccountID(kind: kind, value: value)
                guard ids.insert(id).inserted else { throw advancedFileError() }
                if row.enabled { result.insert(id) }
            }
        }
        return result
    }
    private static func settingsKey(_ change: FileStationSettingsChange) -> String {
        switch change {
        case .general: "settings:general"
        case .mountAccess: "settings:mount-access"
        case .mountAccount(let baseline, _): "settings:mount-account:" + baseline.source.id + ":" + baseline.id.kind.rawValue + ":" + String(baseline.id.value)
        case .bandwidth(let old, _): "settings:bandwidth:" + old.id
        case .theme: "settings:theme"
        }
    }
    private static func settingsResult(_ status: MutationResultStatus) throws -> MutationResult {
        let success = status == .confirmedSuccess, unknown = status == .submittedButUnverified
        return try MutationResult(status: status, operation: "fileStationSettings", submitted: true, requiresRefresh: unknown,
            counts: .init(succeeded: success ? 1 : 0, failed: success || unknown ? 0 : 1, unknown: unknown ? 1 : 0), diagnosticTag: "file-station.settings")
    }
}

private struct FileSettingsPayload: Decodable, Sendable {
    struct Privilege: Decodable, Sendable { let uid: Int?; let gid: Int?; let enabled: Bool }
    struct Privileges: Decodable, Sendable { let items: [Privilege] }
    let transfer_log_enable: Bool; let use_unix_default_perm: Bool; let enable_list_usergrp: Bool
    let sharing_allow: FileStationAccessScope; let file_request_allow: FileStationAccessScope
    let rf_allow: FileStationAccessScope; let vd_allow: FileStationAccessScope
    let sharing_privilege: Privileges; let sharing_group_privilege: Privileges
    let file_request_privilege: Privileges; let file_request_group_privilege: Privileges
    let sharing_default_limit: String; let bandwidth_enable: String; let schedule_plan: String
    let enable_sharing_custom_setting: String?
}
private struct FileMountAccessPayload: Decodable, Sendable { let user_enabled_type: FileStationMountAccessScope }
private struct FileMountAccountPayload: Decodable, Sendable {
    struct Row: Decodable, Sendable { let name: String; let uid: Int?; let gid: Int?; let enabled: Bool; let is_modifiable: Bool }
    let total: Int; let usergrp_settings: [Row]
}
private struct FilePolicyAccountsPayload: Decodable, Sendable {
    struct Row: Decodable, Sendable { let name: String; let uid: Int?; let gid: Int?; let is_admin: Bool? }
    let users: [Row]?; let groups: [Row]?; let total: Int
}
private struct FileBandwidthPayload: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        let name: String; let `protocol`: String; let owner_type: FileStationBandwidthEntry.OwnerType
        let policy: FileStationBandwidthPolicy; let schedule_plan: String
        let upload_limit_1: Int; let upload_limit_2: Int; let download_limit_1: Int; let download_limit_2: Int
    }
    let bandwidths: [Row]; let total: Int
}
private struct FileSharingThemePayload: Decodable, Sendable {
    let enable_logo_customize: Bool; let enable_background_customize: Bool
    let logo_position: FileStationSharingTheme.LogoPosition; let background_position: FileStationSharingTheme.BackgroundPosition
    let background_color: String; let footer_msg: String; let enable_footer_html: Bool
    let logo_seq: FileThemeSequence?; let background_seq: FileThemeSequence?
}

private struct FileMountLDAPPayload: Decodable, Sendable { let enable_client: Bool }
private struct FileMountDomainPayload: Decodable, Sendable { let enable_domain: Bool }
private struct FileMountDomainJoinPayload: Decodable, Sendable { let test_join_success: Bool }
private struct FileMountDomainListPayload: Decodable, Sendable {
    let domain_list: [Directory]
    struct Directory: Decodable, Sendable {
        let name: String
        let value: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) { name = text; value = text }
            else {
                let fields = try container.decode([String].self)
                guard fields.count >= 2 else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Directory entry is missing its identity") }
                name = fields[0]; value = fields[1]
            }
        }
    }
}

private struct FileThemeSequence: Decodable, Sendable {
    let value: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { value = text }
        else { value = String(try container.decode(Int64.self)) }
    }
}

#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 设置页面只使用显式测试模式的内存数据，保存后回读同一份合成状态。
struct MobileFileSettingsUIFixture {
    private var settings: [String: Any] = ["transfer_log_enable": false, "use_unix_default_perm": false, "enable_list_usergrp": false,
        "sharing_allow": "admin", "file_request_allow": "admin", "rf_allow": "admin", "vd_allow": "admin",
        "sharing_privilege": ["items": [["uid": 1001, "enabled": false]]], "sharing_group_privilege": ["items": [["gid": 100, "enabled": false]]],
        "file_request_privilege": ["items": [["uid": 1001, "enabled": false]]], "file_request_group_privilege": ["items": [["gid": 100, "enabled": false]]],
        "sharing_default_limit": "10", "bandwidth_enable": "bandwidth_disable", "schedule_plan": "", "enable_sharing_custom_setting": "false"]
    private var scope = "admin"
    private var allowed = false
    private var bandwidth: [String: Any] = ["name": "Sample member", "protocol": "FileStation", "owner_type": "local_user", "policy": "notexist", "schedule_plan": "",
        "upload_limit_1": 0, "download_limit_1": 0, "upload_limit_2": 0, "download_limit_2": 0]
    private var theme: [String: Any] = ["enable_logo_customize": false, "enable_background_customize": false, "logo_position": "leftup",
        "background_position": "fill", "background_color": "#FFFFFF", "footer_msg": "", "enable_footer_html": false, "logo_seq": "1", "background_seq": "1"]
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=")!

    mutating func response(api: String, method: String, fields: [URLQueryItem], state: String) throws -> [String: Any]? {
        func field(_ key: String) -> String { fields.first { $0.name == key }?.value ?? "" }
        func object(_ key: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(field(key).utf8)) as? [String: Any] ?? [:] }
        if state == "file-settings-error", [DsmAPIName.fileStationSettings, DsmAPIName.fileStationVFSUser, DsmAPIName.coreBandwidthControl, DsmAPIName.coreFileSharingTheme].contains(api) { throw URLError(.notConnectedToInternet) }
        switch (api, method) {
        case (DsmAPIName.desktopInitData, "get_user_service"):
            return ["AppPrivilege": ["SYNO.SDS.App.FileStation3.Instance": true], "Session": ["is_admin": state != "file-settings-readonly"]]
        case (DsmAPIName.fileStationSettings, "get"): return settings
        case (DsmAPIName.fileStationSettings, "set"):
            for key in ["transfer_log_enable", "use_unix_default_perm", "enable_list_usergrp"] where fields.contains(where: { $0.name == key }) { settings[key] = field(key) == "true" }
            for key in ["sharing_allow", "file_request_allow", "rf_allow", "vd_allow", "sharing_default_limit", "bandwidth_enable", "schedule_plan", "enable_sharing_custom_setting"] where fields.contains(where: { $0.name == key }) { settings[key] = field(key) }
            for prefix in ["sharing", "file_request"] {
                for group in [false, true] {
                    let name = prefix + (group ? "_group_privilege" : "_privilege"), key = group ? "gid" : "uid"
                    for enabled in [true, false] where !field((enabled ? "enabled_" : "disabled_") + name).isEmpty {
                        let ids = field((enabled ? "enabled_" : "disabled_") + name).split(separator: ",").compactMap { Int($0) }
                        settings[name] = ["items": ids.map { [key: $0, "enabled": enabled] as [String: Any] }]
                    }
                }
            }
            return [:]
        case (DsmAPIName.fileStationUserGroup, "list_user"), (DsmAPIName.fileStationUserGroup, "list_group"):
            let group = method == "list_group", name = group ? "Sample group" : "Sample member", query = field("query")
            let rows: [[String: Any]] = query.isEmpty || name.localizedCaseInsensitiveContains(query) ? [[group ? "gid" : "uid": group ? 100 : 1001, "name": name, "is_admin": false]] : []
            return [group ? "groups" : "users": rows, "total": rows.count]
        case (DsmAPIName.fileStationVFSUser, "get"):
            if field("content") == "user_enabled_type" { return ["user_enabled_type": scope] }
            let group = field("usergroup") == "group", name = group ? "Sample group" : "Sample member", query = field("substr")
            let rows: [[String: Any]] = query.isEmpty || name.localizedCaseInsensitiveContains(query) ? [[group ? "gid" : "uid": group ? "100" : "1001", "name": name, "enabled": allowed, "is_modifiable": true]] : []
            return ["usergrp_settings": rows, "total": rows.count]
        case (DsmAPIName.fileStationVFSUser, "set"):
            let values = try object("settings")
            if let value = values["user_enabled_type"] as? String { scope = value }
            if let value = (values["user_settings"] ?? values["group_settings"]) as? [[String: Any]], let enabled = value.first?["enabled"] as? Bool { allowed = enabled }
            return [:]
        case (DsmAPIName.coreDirectoryLDAP, "get"): return ["enable_client": false]
        case (DsmAPIName.coreDirectoryDomain, "get"): return ["enable_domain": false]
        case (DsmAPIName.coreBandwidthControl, "list"):
            if field("owner_type") == "local_user" { return ["bandwidths": [bandwidth], "total": 1] }
            return ["bandwidths": [], "total": 0]
        case (DsmAPIName.coreBandwidthControl, "set"):
            if let rows = try JSONSerialization.jsonObject(with: Data(field("bandwidths").utf8)) as? [[String: Any]], let value = rows.first { bandwidth = value }
            return [:]
        case (DsmAPIName.coreFileSharingTheme, "get"): return theme
        case (DsmAPIName.coreFileSharingTheme, "set"):
            for key in ["enable_logo_customize", "enable_background_customize", "enable_footer_html"] { theme[key] = field(key) == "true" }
            for key in ["logo_position", "background_position", "background_color", "footer_msg"] { theme[key] = field(key) }
            if !field("background_path").isEmpty { theme["background_seq"] = "2" }
            if !field("logo_path").isEmpty { theme["logo_seq"] = "2" }
            return [:]
        case (DsmAPIName.coreThemeImage, "list"): return ["list": []]
        default: return nil
        }
    }
}
#endif

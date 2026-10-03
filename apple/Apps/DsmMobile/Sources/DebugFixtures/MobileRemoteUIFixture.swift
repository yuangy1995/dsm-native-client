#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 远程管理的完整合成回读；只在既有显式 UI 样例模式使用。
struct MobileRemoteUIFixture {
    private var mounts: [[String: Any]] = []
    private var images: [[String: Any]] = []
    private var profiles: [[String: Any]] = [["id": "fixture-remote", "protocol": "davs", "protocol_name": "WebDAV",
        "uri": "davs://fixture-remote", "hostname": "remote.example.invalid", "port": 443, "alias": "Sample WebDAV",
        "account": "fixture", "codepage": "UTF-8", "connect_status": 1]]
    private var details: [String: [String: Any]] = ["fixture-remote": ["hostname": "remote.example.invalid", "port": 443,
        "alias": "Sample WebDAV", "account": "fixture", "codepage": "UTF-8", "uri_path": "", "max_connection": 0]]

    mutating func response(api: String, method: String, fields: [URLQueryItem]) throws -> [String: Any]? {
        func field(_ key: String) -> String { fields.first { $0.name == key }?.value ?? "" }
        func paths(_ key: String) throws -> [String] { try JSONDecoder().decode([String].self, from: Data(field(key).utf8)) }
        switch (api, method) {
        case (DsmAPIName.desktopInitData, "get_user_service"):
            return ["AppPrivilege": ["SYNO.SDS.App.FileStation3.Instance": true], "Session": ["is_admin": true]]
        case (DsmAPIName.coreSystem, "info"): return ["firmware_ver": "7.2.1"]
        case (DsmAPIName.fileStationVFSProtocol, "list"):
            return ["protocols": [["protocol": "davs", "name": "WebDAV HTTPS", "default_port": 443, "has_server": true],
                ["protocol": "sftp", "name": "SFTP", "default_port": 22, "has_server": false],
                ["protocol": "ftp", "name": "FTP", "default_port": 21, "has_server": false],
                ["protocol": "google", "name": "Google Drive", "has_server": false]]]
        case (DsmAPIName.fileStationVFSProfile, "list"): return ["profiles": profiles, "total": profiles.count]
        case (DsmAPIName.fileStationVFSProfile, "get"): return details[field("id")] ?? [:]
        case (DsmAPIName.fileStationVFSConnection, "create") where !field("profile_id").isEmpty:
            for index in profiles.indices where profiles[index]["id"] as? String == field("profile_id") { profiles[index]["connect_status"] = 1 }
            return [:]
        case (DsmAPIName.fileStationVFSConnection, "create"), (DsmAPIName.fileStationVFSConnection, "set"): return [:]
        case (DsmAPIName.fileStationVFSProfile, "create"), (DsmAPIName.fileStationVFSProfile, "set"):
            let id = method == "create" ? "fixture-created" : field("id")
            let previous = profiles.first { $0["id"] as? String == id }
            let proto = method == "create" ? field("protocol") : previous?["protocol"] as? String ?? "davs"
            let detail: [String: Any] = ["hostname": field("hostname"), "port": Int(field("port")) ?? 443, "alias": field("alias"),
                "account": field("account"), "codepage": field("codepage"), "uri_path": field("uri_path"), "max_connection": Int(field("max_connection")) ?? 0]
            details[id] = detail
            var profile = detail; profile["id"] = id; profile["protocol"] = proto
            profile["protocol_name"] = proto.uppercased(); profile["uri"] = proto + "://" + id; profile["connect_status"] = 1
            profiles.removeAll { $0["id"] as? String == id }; profiles.append(profile); return [:]
        case (DsmAPIName.fileStationVFSConnection, "delete"):
            for index in profiles.indices where profiles[index]["id"] as? String == field("id") { profiles[index]["connect_status"] = 0 }; return [:]
        case (DsmAPIName.fileStationVFSProfile, "delete"):
            profiles.removeAll { $0["id"] as? String == field("id") }; details[field("id")] = nil; return [:]
        case (DsmAPIName.fileStationMountList, "get"):
            return ["mountConfig": ["enable_remote_mount": true, "enable_iso_mount": true], "remoteList": mounts, "isoList": images]
        case (DsmAPIName.fileStationMount, "mount_remote"):
            mounts.append(["mount_point": field("mount_point"), "source": field("server_ip"), "type": field("mount_type").lowercased(), "auto_mount": field("auto_mount") == "true"])
            return [:]
        case (DsmAPIName.fileStationMount, "mount_iso"):
            images.append(["mount_point": field("mount_point"), "source": field("source"), "type": "iso", "auto_mount": field("auto_mount") == "true"])
            return [:]
        case (DsmAPIName.fileStationMountList, "unmount"):
            let selected = try paths("mount_point")
            mounts.removeAll { selected.contains($0["mount_point"] as? String ?? "") }
            images.removeAll { selected.contains($0["mount_point"] as? String ?? "") }; return [:]
        case (DsmAPIName.fileStationList, "getinfo"):
            return ["files": try paths("path").map { item($0, directory: !$0.hasSuffix(".iso")) }]
        case (DsmAPIName.fileStationList, "list"):
            let path = field("folder_path")
            let files: [[String: Any]]
            if path == "/fixture" {
                files = [item("/fixture/Sample image.iso", directory: false), item("/fixture/Inbox", directory: true)]
            } else if path.contains("://") {
                files = [item(path + "/Remote sample.txt", directory: false)]
            } else { files = [] }
            return ["files": files, "offset": 0, "total": files.count]
        default: return nil
        }
    }
    private func item(_ path: String, directory: Bool) -> [String: Any] {
        let mount = mounts.first { $0["mount_point"] as? String == path }
        let type = mount?["type"] as? String ?? (images.contains { $0["mount_point"] as? String == path } ? "iso" : "normal")
        return ["name": (path as NSString).lastPathComponent, "path": path, "isdir": directory,
            "additional": ["size": 0, "mount_point_type": type, "perm": ["adv_right": ["read": true, "write": true]]]]
    }
}
#endif

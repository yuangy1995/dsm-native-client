#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 走真实 Repository 的确定性目录与复制/移动响应，仅供无网络的 UI 回归。
struct MobileCopyMoveUIFixture {
    private var items: [String: Bool] = ["/fixture": true, "/output": true,
        "/fixture/Sample document.txt": false, "/fixture/Inbox": true, "/fixture/Inbox/Nested.txt": false]
    private var initialized = false

    mutating func response(api: String, method: String, fields: [URLQueryItem], state: String) throws -> [String: Any]? {
        if !initialized {
            initialized = true
            if state.hasPrefix("recycle-restore") || state == "recycle-permanent" {
                items = ["/fixture": true, "/fixture/#recycle": true,
                    "/fixture/#recycle/Inbox": true, "/fixture/#recycle/Inbox/Nested.txt": false,
                    "/fixture/#recycle/Sample document.txt": false]
                if state == "recycle-restore-conflict" { items["/fixture/Sample document.txt"] = false }
            }
            if state == "copy-conflict" { items["/output/Sample document.txt"] = false }
        }
        func field(_ name: String) -> String { fields.first { $0.name == name }?.value ?? "" }
        func row(_ path: String, _ directory: Bool) -> [String: Any] {
            ["name": path == "/fixture" && method == "list_share" ? "Sample folder" : (path as NSString).lastPathComponent,
             "path": path, "isdir": directory, "additional": ["size": 10,
                "perm": ["adv_right": ["read": true, "write": state != "copy-readonly", "delete": state != "recycle-readonly"]], "time": ["mtime": 1000]]]
        }
        switch (api, method) {
        case (DsmAPIName.fileStationList, "list_share"):
            return ["shares": [row("/fixture", true), row("/output", true)], "offset": 0, "total": 2]
        case (DsmAPIName.fileStationList, "list"):
            let path = field("folder_path"), offset = Int(field("offset")) ?? 0
            let children = items.keys.filter { ($0 as NSString).deletingLastPathComponent == path }.sorted()
            return ["files": children.dropFirst(offset).map { row($0, items[$0]!) }, "offset": offset, "total": children.count]
        case (DsmAPIName.fileStationList, "getinfo"):
            let paths = try JSONDecoder().decode([String].self, from: Data(field("path").utf8))
            return ["files": paths.compactMap { path in items[path].map { row(path, $0) } }]
        case (DsmAPIName.fileStationDelete, "start"):
            if state == "recycle-unknown" { throw URLError(.networkConnectionLost) }
            let paths = try JSONDecoder().decode([String].self, from: Data(field("path").utf8))
            for source in paths {
                items = items.filter { $0.key != source && !$0.key.hasPrefix(source + "/") }
            }
            return ["taskid": "fixture-delete-task"]
        case (DsmAPIName.fileStationDelete, "status"):
            return ["finished": true]
        case (DsmAPIName.fileStationCopyMove, "start"):
            if state == "copy-unknown" { throw URLError(.networkConnectionLost) }
            let paths = try JSONDecoder().decode([String].self, from: Data(field("path").utf8))
            let destination = field("dest_folder_path"), move = field("remove_src") == "true"
            for source in paths {
                let affected = items.filter { $0.key == source || $0.key.hasPrefix(source + "/") }
                for (path, directory) in affected {
                    items[destination + "/" + (source as NSString).lastPathComponent + String(path.dropFirst(source.count))] = directory
                    if move { items.removeValue(forKey: path) }
                }
            }
            return ["taskid": "fixture-copy-task"]
        case (DsmAPIName.fileStationCopyMove, "status"):
            return ["finished": true, "progress": 1]
        case (DsmAPIName.fileStationCopyMove, "stop"):
            return [:]
        default: return nil
        }
    }
}
#endif

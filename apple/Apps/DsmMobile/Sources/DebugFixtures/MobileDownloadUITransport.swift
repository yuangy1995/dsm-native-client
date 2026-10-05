#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 下载页面只使用合成任务与内存请求，UI 测试不访问 NAS 或外部下载来源。
actor MobileDownloadUITransport: DsmHTTPTransport {
    let state: String
    private var detailAttempts = 0
    private var statuses: [String: String]
    private var hasUnknownWrite = false
    private var settings: [DownloadSettingsField: DownloadSettingsValue]
    private var hasUnknownSettingsWrite = false
    private var destinations: [String: String]
    private var createdDownload: Bool
    init(state: String, statuses: [String: String] = [:], settings: [DownloadSettingsField: DownloadSettingsValue] = [:], destinations: [String: String] = [:]) {
        self.state = state; self.statuses = statuses
        self.createdDownload = state == "downloads-create-recover" || state == "downloads-create-saved"
        self.destinations = destinations
        self.settings = [.destination: .text("Sample folder"), .emule: .flag(false), .autoExtract: .flag(false),
            .btDownload: .number(0), .btUpload: .number(0), .httpDownload: .number(0), .ftpDownload: .number(0),
            .nzbDownload: .number(0), .emuleDownload: .number(0), .emuleUpload: .number(0),
            .schedule: .flag(false), .emuleSchedule: .flag(false)]
        self.settings.merge(settings) { _, new in new }
    }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let parameters = URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems ?? []
        func value(_ name: String) -> String? { parameters.first { $0.name == name }?.value }
        let data: Any
        switch (value("api"), value("method")) {
        case (DsmAPIName.downloadStationTask, "create"):
            guard value("version") == "3" else { throw URLError(.badServerResponse) }
            if state == "downloads-create-denied" {
                return .init(data: Data(#"{"success":false,"error":{"code":402}}"#.utf8), statusCode: 200)
            }
            createdDownload = true
            if state == "downloads-create-unknown" || state == "downloads-create-recover" { throw URLError(.timedOut) }
            // 官方创建允许无 data；不能靠 UI fixture 额外返回编号掩盖契约缺口。
            return .init(data: Data(#"{"success":true}"#.utf8), statusCode: 200)
        case (DsmAPIName.downloadStationInfo, "getinfo"):
            data = ["is_manager": state != "downloads-settings-readonly"]
        case (DsmAPIName.downloadStationInfo, "getconfig"), (DsmAPIName.downloadStationSchedule, "getconfig"):
            if state == "downloads-settings-loading" { try await Task.sleep(for: .seconds(30)) }
            if state == "downloads-settings-error" || hasUnknownSettingsWrite { throw URLError(.notConnectedToInternet) }
            let group: DownloadSettingsField.Group = value("api") == DsmAPIName.downloadStationInfo ? .general : .schedule
            var config: [String: Any] = [:]
            if state != "downloads-settings-empty" {
                for (field, setting) in settings where field.group == group {
                    switch setting {
                    case .text(let text): config[field.parameter] = text
                    case .flag(let flag): config[field.parameter] = flag
                    case .number(let number): config[field.parameter] = number
                    }
                }
            }
            data = config
        case (DsmAPIName.downloadStationInfo, "setserverconfig"), (DsmAPIName.downloadStationSchedule, "setconfig"):
            let group: DownloadSettingsField.Group = value("api") == DsmAPIName.downloadStationInfo ? .general : .schedule
            for (field, setting) in settings where field.group == group {
                guard let parameter = value(field.parameter) else { continue }
                switch setting {
                case .text: settings[field] = .text(parameter)
                case .flag: settings[field] = .flag(parameter == "true")
                case .number: settings[field] = .number(Int(parameter)!)
                }
            }
            if state == "downloads-settings-unknown" { hasUnknownSettingsWrite = true; throw URLError(.timedOut) }
            data = [:]
        case (DsmAPIName.downloadStationTask, "list"):
            if state == "downloads-loading" { try await Task.sleep(for: .seconds(30)) }
            if state == "downloads-error" { throw URLError(.notConnectedToInternet) }
            if hasUnknownWrite { throw URLError(.notConnectedToInternet) }
            var tasks = state == "downloads-empty" || state == "downloads-controls-empty" ? [] : [task("sample-1", "Sample archive.zip", "downloading"),
                task("sample-2", "Paused document.pdf", "paused"), task("sample-3", "Finished video.mp4", "finished")]
            if state.hasPrefix("downloads-controls-"), state != "downloads-controls-empty" {
                tasks.append(task("sample-4", "Second archive.zip", "seeding"))
            }
            if createdDownload { tasks.append(task("sample-created", "Added download.zip", "waiting")) }
            data = ["tasks": tasks, "offset": 0, "total": tasks.count]
        case (DsmAPIName.downloadStationTask, "pause"), (DsmAPIName.downloadStationTask, "resume"):
            guard let id = value("id"), ["sample-1", "sample-2", "sample-4"].contains(id) else { throw URLError(.badServerResponse) }
            statuses[id] = value("method") == "pause" ? "paused" : "downloading"
            if state == "downloads-controls-unknown" { hasUnknownWrite = true }
            data = [:]
        case (DsmAPIName.downloadStationTask, "edit"):
            guard let id = value("id"), let destination = value("destination"), value("version") == "2" else { throw URLError(.badServerResponse) }
            let code = state == "downloads-edit-partial" && id == "sample-2" ? 402 : 0
            if code == 0 { destinations[id] = destination }
            if state == "downloads-edit-unknown" { hasUnknownWrite = true; throw URLError(.timedOut) }
            data = [["id": id, "error": code]]
        case (DsmAPIName.downloadStationStatistic, "getinfo"):
            data = ["speed_download": 0]
        case (DsmAPIName.downloadStationTask, "getinfo"):
            detailAttempts += 1
            if state == "downloads-details-error", detailAttempts == 1 { throw URLError(.timedOut) }
            var item = task("sample-1", "Sample archive.zip", "downloading")
            item["type"] = "bt"; item["username"] = "Sample user"
            item["additional"] = [
                "detail": ["destination": destinations["sample-1"] ?? "Sample Downloads", "create_time": 1_750_000_000,
                    "priority": "normal", "connected_seeders": 4, "total_peers": 8],
                "transfer": ["size_downloaded": "2048", "size_uploaded": "1024", "speed_download": 0],
                "file": [["filename": "Sample document.txt", "size": "4096", "size_downloaded": "2048", "priority": "normal"]],
                "tracker": [["url": "https://tracker.example.invalid/private-key/announce?token=fixture-secret", "status": "working", "seeds": 4]],
                "peer": [["address": "192.0.2.5", "agent": "Sample Client", "progress": 0.5, "speed_download": 0]]
            ] as [String: Any]
            data = ["tasks": [item]]
        default:
            return DsmHTTPResponse(data: Data(#"{"success":false,"error":{"code":102}}"#.utf8), statusCode: 200)
        }
        return DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }

    private func task(_ id: String, _ title: String, _ status: String) -> [String: Any] {
        ["id": id, "title": title, "status": statuses[id] ?? status, "size": "4096",
         "additional": ["detail": ["destination": destinations[id] ?? "Sample Downloads"], "transfer": ["size_downloaded": "2048", "speed_download": 0]]]
    }
}
#endif

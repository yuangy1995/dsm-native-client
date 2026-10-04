#if DEBUG
import DsmNetwork
import Foundation

/// 下载页面只使用合成任务与内存请求，UI 测试不访问 NAS 或外部下载来源。
actor MobileDownloadUITransport: DsmHTTPTransport {
    let state: String
    private var detailAttempts = 0
    private var statuses: [String: String]
    private var hasUnknownWrite = false
    init(state: String, statuses: [String: String] = [:]) { self.state = state; self.statuses = statuses }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let parameters = URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems ?? []
        func value(_ name: String) -> String? { parameters.first { $0.name == name }?.value }
        let data: [String: Any]
        switch (value("api"), value("method")) {
        case (DsmAPIName.downloadStationTask, "list"):
            if state == "downloads-loading" { try await Task.sleep(for: .seconds(30)) }
            if state == "downloads-error" { throw URLError(.notConnectedToInternet) }
            if hasUnknownWrite { throw URLError(.notConnectedToInternet) }
            var tasks = state == "downloads-empty" || state == "downloads-controls-empty" ? [] : [task("sample-1", "Sample archive.zip", "downloading"),
                task("sample-2", "Paused document.pdf", "paused"), task("sample-3", "Finished video.mp4", "finished")]
            if state.hasPrefix("downloads-controls-"), state != "downloads-controls-empty" {
                tasks.append(task("sample-4", "Second archive.zip", "seeding"))
            }
            data = ["tasks": tasks, "offset": 0, "total": tasks.count]
        case (DsmAPIName.downloadStationTask, "pause"), (DsmAPIName.downloadStationTask, "resume"):
            guard let id = value("id"), ["sample-1", "sample-2", "sample-4"].contains(id) else { throw URLError(.badServerResponse) }
            statuses[id] = value("method") == "pause" ? "paused" : "downloading"
            if state == "downloads-controls-unknown" { hasUnknownWrite = true }
            data = [:]
        case (DsmAPIName.downloadStationStatistic, "getinfo"):
            data = ["speed_download": 0]
        case (DsmAPIName.downloadStationTask, "getinfo"):
            detailAttempts += 1
            if state == "downloads-details-error", detailAttempts == 1 { throw URLError(.timedOut) }
            var item = task("sample-1", "Sample archive.zip", "downloading")
            item["type"] = "bt"; item["username"] = "Sample user"
            item["additional"] = [
                "detail": ["destination": "Sample Downloads", "create_time": 1_750_000_000,
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
         "additional": ["detail": ["destination": "Sample Downloads"], "transfer": ["size_downloaded": "2048", "speed_download": 0]]]
    }
}
#endif

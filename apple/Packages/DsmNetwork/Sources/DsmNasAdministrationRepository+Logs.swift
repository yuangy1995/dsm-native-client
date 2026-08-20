import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public func loadLogs(offset: Int, limit: Int) async throws -> NasLogPage {
        // Log Center 可能已安装但没有历史记录；系统日志是 DSM 默认页面的数据源。
        let value = try await call(
            DsmAPIName.coreSystemLog,
            method: "list",
            parameters: [
                "offset": .integer(max(0, offset)),
                "limit": .integer(min(500, max(1, limit)))
            ]
        )
        let entries = value.objects("items").enumerated().compactMap { index, raw -> NasLogEntry? in
            let item = DsmDynamicJSON.object(raw)
            guard let message = item.string(["descr", "message", "msg"]) else { return nil }
            let rawTime = item.string(["time"])
            return NasLogEntry(
                id: "log:\(offset + index):\(rawTime ?? "")",
                date: Self.date(from: rawTime),
                source: item.string(["logtype", "orginalLogType"]),
                level: item.string(["level"]),
                account: item.string(["who"]),
                message: message
            )
        }
        return NasLogPage(
            entries: entries,
            total: Int(value.number(["total"]) ?? Double(entries.count)),
            infoCount: value.number(["infoCount"]).map(Int.init),
            warningCount: value.number(["warnCount"]).map(Int.init),
            errorCount: value.number(["errorCount"]).map(Int.init)
        )
    }

    public func loadConnections(offset: Int, limit: Int) async throws -> NasConnectionPage {
        let value = try await call(
            DsmAPIName.coreCurrentConnection,
            method: "list",
            parameters: [
                "start": .integer(max(0, offset)),
                "limit": .integer(min(500, max(1, limit))),
                "sort": .string("time"),
                "sort_by": .string("time"),
                "sort_direction": .string("DESC")
            ]
        )
        let connections = value.objects("items").enumerated().compactMap {
            index, raw -> NasConnection? in
            let item = DsmDynamicJSON.object(raw)
            guard let account = item.string(["who"]) else { return nil }
            let pid = item.string(["pid"]) ?? "\(index)"
            let time = item.string(["time"])
            return NasConnection(
                id: "connection:\(pid):\(account):\(time ?? "")",
                processID: item.string(["pid"]),
                deviceID: item.string(["did"]),
                account: account,
                source: item.string(["from"]),
                location: item.string(["location"]),
                protocolName: item.string(["protocol"]),
                type: item.string(["type"]),
                connectedAt: Self.date(from: time),
                description: item.string(["descr"]),
                isCurrentConnection: item.boolean(["is_current_connected"])
                    ?? (item.string(["who"]) == currentUsername),
                canDisconnect: item.boolean(["can_be_kicked"]) ?? false
            )
        }
        return NasConnectionPage(
            connections: connections,
            total: Int(value.number(["total"]) ?? Double(connections.count))
        )
    }

    public func disconnectConnection(_ connection: NasConnection) async throws {
        guard connection.canDisconnect else {
            throw AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.59ee3335304d8042")
            )
        }

        let common: [String: DsmJSONValue] = [
            "who": .string(connection.account),
            "from": .string(connection.source ?? "")
        ]
        let serviceConnections: [[String: DsmJSONValue]]
        let httpConnections: [[String: DsmJSONValue]]
        if connection.type?.uppercased() == "HTTP/HTTPS" {
            guard let deviceID = connection.deviceID, !deviceID.isEmpty else {
                throw unavailableError()
            }
            serviceConnections = []
            httpConnections = [
                common.merging([
                    "did": .string(deviceID),
                    "descr": .string(connection.description ?? "")
                ]) { _, new in new }
            ]
        } else {
            guard let processID = connection.processID, !processID.isEmpty else {
                throw unavailableError()
            }
            serviceConnections = [
                common.merging([
                    "pid": .string(processID),
                    "type": .string(connection.type ?? "")
                ]) { _, new in new }
            ]
            httpConnections = []
        }

        try await callVoid(
            DsmAPIName.coreCurrentConnection,
            method: "kick_connection",
            parameters: [
                "service_conn": .objectArray(serviceConnections),
                "http_conn": .objectArray(httpConnections)
            ]
        )
    }
}

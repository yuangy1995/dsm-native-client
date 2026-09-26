import DsmCore
import DsmLocalization
import Foundation
import CryptoKit

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
        guard let rows = value["items"]?.array, rows.count <= min(500, max(1, limit)) else { throw verificationError(L10n.string("nas.connections.response-incomplete")) }
        let total: Int
        if let raw = value["total"] {
            guard case .number(let number) = raw, let count = Int(exactly: number), count >= rows.count else {
                throw verificationError(L10n.string("nas.connections.response-incomplete"))
            }
            total = count
        } else { total = rows.count }
        var seen: Set<String> = []
        let connections = try rows.enumerated().map { index, entry -> NasConnection in
            guard let raw = entry.object else { throw verificationError(L10n.string("nas.connections.response-incomplete")) }
            let item = DsmDynamicJSON.object(raw)
            func text(_ key: String) throws -> String? {
                guard let value = item[key], value != .null else { return nil }
                guard case .string(let text) = value else { throw verificationError(L10n.string("nas.connections.response-incomplete")) }
                return text
            }
            func flag(_ key: String) throws -> Bool? {
                guard let value = item[key], value != .null else { return nil }
                guard case .boolean(let flag) = value else { throw verificationError(L10n.string("nas.connections.response-incomplete")) }
                return flag
            }
            guard let account = try text("who") else { throw verificationError(L10n.string("nas.connections.response-incomplete")) }
            // DSM 的进程编号可为 JSON 整数；只对编号兼容两种表示，不放宽其他文本字段。
            let pid: String?
            if case .number(let number)? = item["pid"] {
                guard let identifier = Int64(exactly: number), identifier >= 0 else {
                    throw verificationError(L10n.string("nas.connections.response-incomplete"))
                }
                pid = String(identifier)
            } else {
                pid = try text("pid")
            }
            let did = try text("did"), type = try text("type"), source = try text("from"), description = try text("descr")
            let time = try text("time")
            let web = type?.uppercased() == "HTTP/HTTPS"
            let identity = web ? did : pid
            let identityKnown = identity?.isEmpty == false && type?.isEmpty == false
            let key = identityKnown ? (web ? "web:" : "service:") + identity! : "readonly:\(offset + index)"
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            guard seen.insert(digest).inserted || !identityKnown else {
                // 同一原始目标出现多次时，不能猜测应该断开哪一项。
                throw verificationError(L10n.string("nas.connections.response-incomplete"))
            }
            return NasConnection(
                id: "connection:\(digest)",
                processID: pid,
                deviceID: did,
                account: account,
                source: source,
                location: try text("location"),
                protocolName: try text("protocol"),
                type: type,
                connectedAt: Self.date(from: time),
                description: description,
                isCurrentConnection: try flag("is_current_connected") ?? false,
                canDisconnect: try flag("can_be_kicked") == true && identityKnown && source != nil && (!web || description != nil)
            )
        }
        return NasConnectionPage(
            connections: connections,
            total: total
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

        let directory = try await loadConnections(offset: 0, limit: 500)
        let matches = directory.connections.filter { current in
            connection.type?.uppercased() == "HTTP/HTTPS" ? current.deviceID == connection.deviceID : current.processID == connection.processID
        }
        guard directory.connections.count < 500, directory.total <= directory.connections.count, matches.count == 1,
              let current = matches.first, current.canDisconnect,
              current.processID == connection.processID, current.deviceID == connection.deviceID,
              current.account == connection.account, current.source == connection.source, current.type == connection.type,
              current.description == connection.description, current.connectedAt == connection.connectedAt,
              current.protocolName == connection.protocolName, current.location == connection.location,
              current.isCurrentConnection == connection.isCurrentConnection else {
            throw verificationError(L10n.string("nas.connections.response-incomplete"))
        }

        let common: [String: DsmJSONValue] = [
            "who": .string(connection.account),
            "from": .string(connection.source!)
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
                    "descr": .string(connection.description!)
                ]) { _, new in new }
            ]
        } else {
            guard let processID = connection.processID, !processID.isEmpty else {
                throw unavailableError()
            }
            serviceConnections = [
                common.merging([
                    "pid": .string(processID),
                    "type": .string(connection.type!)
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

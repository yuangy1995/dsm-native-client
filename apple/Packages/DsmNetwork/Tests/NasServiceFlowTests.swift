import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class NasServiceFlowTests: XCTestCase {
    func test六组服务只写变化组并持久保存独立边界() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let original = try await repository.loadServiceForManagement(.fileServices)
        guard case .fileServices(var value) = original else { return XCTFail() }
        value.isSMBEnabled = true; value.isNFSEnabled = true; value.isFTPSEnabled = true; value.ftpPort = 2121
        value.isSFTPEnabled = true; value.sftpPort = 2222; value.isBonjourEnabled = true; value.isSMBTimeMachineEnabled = true
        let result = try await repository.changeServiceResult(.init(original: original, desired: .fileServices(value))) { await log.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess); XCTAssertEqual(result.counts.succeeded, 6)
        let writes = await transport.writes
        XCTAssertEqual(writes.map { $0["api"] }, ServiceFlowTransport.apis.prefix(6).map(Optional.some))
        XCTAssertEqual(writes.map { $0["version"] }, ["3", "3", "1", "1", "2", "1"])
        XCTAssertEqual(writes[2]["enable_ftp"], "false"); XCTAssertEqual(writes[2]["enable_ftps"], "true"); XCTAssertEqual(writes[2]["portnum"], "2121")
        XCTAssertEqual(writes[3]["portnum"], "2222"); XCTAssertNil(writes[3]["enable_ssh"])
        let checkpoints = await log.values
        XCTAssertEqual(checkpoints.count, 18)
        XCTAssertEqual(Array(checkpoints.prefix(3)), [.willSubmit(.smb), .accepted(.smb), .verified(.smb)])
    }

    func test原值变化包含同组未编辑字段阻止覆盖() async throws {
        for kind in NasServiceKind.allCases {
            let transport = ServiceFlowTransport(), repository = try repository(transport)
            let original = try await repository.loadServiceForManagement(kind), change = change(original)
            await transport.changeUneditedField(kind)
            let result = try await repository.changeServiceResult(change) { _ in XCTFail("陈旧确认不能进入写边界") }
            XCTAssertEqual(result.status, .confirmedFailure); XCTAssertFalse(result.submitted)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }

    func test缺失端口与开关不猜测且不能通过草稿填充() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        await transport.removeOptionalFields()
        let original = try await repository.loadServiceForManagement(.terminal)
        guard case .terminal(var value) = original else { return XCTFail() }
        XCTAssertNil(value.sshPort); value.isSSHEnabled = true
        let result = try await repository.changeServiceResult(.init(original: original, desired: .terminal(value))) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        var writes = await transport.writes; XCTAssertNil(writes[0]["ssh_port"])
        let next = try await repository.loadServiceForManagement(.fileServices)
        guard case .fileServices(var files) = next else { return XCTFail() }
        XCTAssertNil(files.isFTPSEnabled); files.isFTPSEnabled = true
        let invalid = try await repository.changeServiceResult(.init(original: next, desired: .fileServices(files))) { _ in XCTFail() }
        XCTAssertFalse(invalid.submitted); writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }

    func test畸形开关小数端口与错误主机类型不能成为可编辑原值() async throws {
        for (kind, api, key, value) in [(NasServiceKind.terminal, DsmAPIName.coreTerminal, "enable_ssh", "unknown" as any Sendable),
                                      (.terminal, DsmAPIName.coreTerminal, "ssh_port", 22.5),
                                      (.proxy, DsmAPIName.coreNetworkProxy, "http_host", 18)] {
            let transport = ServiceFlowTransport(), repository = try repository(transport)
            await transport.set(api, key: key, value: value)
            do { _ = try await repository.loadServiceForManagement(kind); XCTFail("畸形字段不能作为配置") } catch {}
        }
    }

    func test能力与版本不满足零写并保留其他文件服务() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport, missing: [DsmAPIName.coreFileServiceNFS], minimum: [DsmAPIName.coreNetworkProxy: 2])
        let value = try await repository.loadServiceForManagement(.fileServices)
        guard case .fileServices(let settings) = value else { return XCTFail() }; XCTAssertNil(settings.isNFSEnabled)
        do { _ = try await repository.loadServiceForManagement(.proxy); XCTFail() } catch { XCTAssertEqual((error as? AppError)?.category, .apiUnavailable) }
        let calls = await transport.calls; XCTAssertFalse(calls.contains { $0["api"] == DsmAPIName.coreNetworkProxy })
        let fake = NasServiceSettings.proxy(.init(isEnabled: false, host: "proxy.example.invalid", port: 3128))
        let result = try await repository.changeServiceResult(change(fake)) { _ in XCTFail() }
        XCTAssertEqual(result.status, .unsupported); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }

    func test关闭代理只发送开关且不比较保留地址() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        await transport.set(DsmAPIName.coreNetworkProxy, key: "enable", value: true)
        let original = try await repository.loadServiceForManagement(.proxy)
        let result = try await repository.changeServiceResult(.init(original: original, desired: .proxy(.init(isEnabled: false, host: "", port: nil)))) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes[0]["enable"], "false"); XCTAssertNil(writes[0]["http_host"]); XCTAssertNil(writes[0]["http_port"])
        let disabled = NasServiceChange(original: original, desired: .proxy(.init(isEnabled: false, host: "", port: nil)))
        XCTAssertFalse(disabled.hasPartialResult(.proxy(.init(isEnabled: true, host: "", port: nil)), step: .proxy), "未提交的地址变化不能被认领为部分停用成功")
    }

    func test明确拒绝不被随后相同配置覆盖() async throws {
        for kind in NasServiceKind.allCases {
            let transport = ServiceFlowTransport(), repository = try repository(transport)
            let original = try await repository.loadServiceForManagement(kind)
            await transport.setMode("denied")
            let result = try await repository.changeServiceResult(change(original)) { _ in }
            XCTAssertEqual(result.status, .permissionDenied)
            let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "set")
        }
    }

    func test丢失回执只读匹配可以恢复但断线不重放() async throws {
        for mode in ["lost-ack", "offline"] {
            let transport = ServiceFlowTransport(), repository = try repository(transport)
            let original = try await repository.loadServiceForManagement(.terminal)
            await transport.setMode(mode)
            let result = try await repository.changeServiceResult(change(original)) { _ in }
            XCTAssertEqual(result.status, mode == "lost-ack" ? .confirmedSuccess : .submittedButUnverified)
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        }
    }

    func test同次终端写只生效部分字段记录部分但不冒报整组成功() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let original = try await repository.loadServiceForManagement(.terminal)
        await transport.setMode("partial")
        let result = try await repository.changeServiceResult(.init(original: original, desired: .terminal(.init(isSSHEnabled: true, isTelnetEnabled: true, sshPort: 2222)))) { await log.append($0) }
        XCTAssertEqual(result.status, .submittedButUnverified); XCTAssertEqual(result.counts.unknown, 1)
        let stages = await log.values; XCTAssertTrue(stages.contains(.partial(.terminal))); XCTAssertFalse(stages.contains(.verified(.terminal)))
    }

    func test已完成首组后权限拒绝保留部分结果不继续后续组() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let original = try await repository.loadServiceForManagement(.fileServices)
        guard case .fileServices(var value) = original else { return XCTFail() }; value.isSMBEnabled = true; value.isNFSEnabled = true; value.isSFTPEnabled = true
        await transport.setMode("second-denied")
        let result = try await repository.changeServiceResult(.init(original: original, desired: .fileServices(value))) { await log.append($0) }
        XCTAssertEqual(result.status, .partialSuccess); XCTAssertEqual(result.counts.succeeded, 1); XCTAssertEqual(result.counts.failed, 2); XCTAssertEqual(result.errorCategory, .permission)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
        let stages = await log.values; XCTAssertTrue(stages.contains(.verified(.smb))); XCTAssertTrue(stages.contains(.rejected(.nfs)))
    }

    func test记录失败在写前回执和已完成边界停止所有后续副作用() async throws {
        for target in [NasServiceCheckpoint.willSubmit(.smb), .accepted(.smb), .verified(.smb), .willSubmit(.nfs)] {
            let transport = ServiceFlowTransport(), repository = try repository(transport)
            let original = try await repository.loadServiceForManagement(.fileServices)
            guard case .fileServices(var value) = original else { return XCTFail() }; value.isSMBEnabled = true; value.isNFSEnabled = true
            do {
                _ = try await repository.changeServiceResult(.init(original: original, desired: .fileServices(value))) { if $0 == target { throw ServiceJournalFailure.failed } }
                XCTFail("记录失败必须传给持久层")
            } catch { XCTAssertTrue(error is ServiceJournalFailure) }
            let writes = await transport.writes; XCTAssertEqual(writes.count, target == .willSubmit(.smb) ? 0 : 1)
        }
    }

    func test组间外部变化停止后续写且不认领未提交组成功() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadServiceForManagement(.fileServices)
        guard case .fileServices(var value) = original else { return XCTFail() }; value.isSMBEnabled = true; value.isNFSEnabled = true
        let result = try await repository.changeServiceResult(.init(original: original, desired: .fileServices(value))) { stage in
            if stage == .verified(.smb) { await transport.set(DsmAPIName.coreFileServiceNFS, key: "enable_nfs", value: true) }
        }
        XCTAssertEqual(result.status, .partialSuccess); XCTAssertEqual(result.counts.succeeded, 1)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }

    func test最后一次回读必须包含前面已完成的组() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadServiceForManagement(.fileServices)
        guard case .fileServices(var value) = original else { return XCTFail() }; value.isSMBEnabled = true; value.isNFSEnabled = true
        await transport.setMode("revert-first")
        let result = try await repository.changeServiceResult(.init(original: original, desired: .fileServices(value))) { _ in }
        XCTAssertEqual(result.status, .partialSuccess); XCTAssertEqual(result.counts.succeeded, 1); XCTAssertEqual(result.counts.failed, 1); XCTAssertEqual(result.errorCategory, .conflict)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
    }

    func test同一服务新旧入口不能在检查点期间并发写入() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadServiceForManagement(.terminal)
        let result = try await repository.changeServiceResult(change(original)) { stage in
            if stage == .willSubmit(.terminal) {
                let duplicate = try await repository.saveTerminalSettingsResult(.init(isSSHEnabled: true, isTelnetEnabled: true, sshPort: 2222))
                XCTAssertEqual(duplicate.status, .confirmedFailure); XCTAssertFalse(duplicate.submitted); XCTAssertEqual(duplicate.errorCategory, .conflict)
            }
        }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }

    func testTimeMachine关闭在SMB之前且端口交换不自动停用服务() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        await transport.set(DsmAPIName.coreFileServiceSMB, key: "enable_samba", value: true)
        await transport.set(DsmAPIName.coreFileServiceDiscovery, key: "enable_smb_time_machine", value: true)
        let original = try await repository.loadServiceForManagement(.fileServices)
        guard case .fileServices(var value) = original else { return XCTFail() }; value.isSMBEnabled = false; value.isSMBTimeMachineEnabled = false
        let change = NasServiceChange(original: original, desired: .fileServices(value))
        XCTAssertEqual(change.orderedSteps, [.fileDiscovery, .smb])
        let result = try await repository.changeServiceResult(change) { _ in }; XCTAssertEqual(result.status, .confirmedSuccess)
        value.isFTPEnabled = true; value.isSFTPEnabled = true; value.ftpPort = 21; value.sftpPort = 22
        var swap = value; swap.ftpPort = 22; swap.sftpPort = 21
        XCTAssertNil(NasServiceChange(original: .fileServices(value), desired: .fileServices(swap)).orderedSteps)
    }

    func test端口代理无变化与未知字段输入零写() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadServiceForManagement(.terminal)
        for desired in [original, .terminal(.init(isSSHEnabled: true, isTelnetEnabled: false, sshPort: 0)), .proxy(.init(isEnabled: true, host: "https://proxy.example.invalid", port: 3128))] {
            let result = try await repository.changeServiceResult(.init(original: original, desired: desired)) { _ in XCTFail() }; XCTAssertFalse(result.submitted)
        }
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }

    private func change(_ original: NasServiceSettings) -> NasServiceChange {
        let desired: NasServiceSettings
        switch original {
        case .fileServices(var value): value.isSMBEnabled?.toggle(); desired = .fileServices(value)
        case .terminal(var value): value.isSSHEnabled.toggle(); desired = .terminal(value)
        case .proxy(var value): value.isEnabled.toggle(); desired = .proxy(value)
        }
        return .init(original: original, desired: desired)
    }
    private func repository(_ transport: ServiceFlowTransport, missing: [String] = [], minimum: [String: Int] = [:]) throws -> DsmNasAdministrationRepository {
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: ServiceFlowTransport.apis.filter { !missing.contains($0) }.map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: minimum[$0] ?? 1, maxVersion: 3, requestFormat: .form, selectedVersion: 3)) }))
        return try .init(profile: NasProfile(displayName: "Synthetic", host: "nas.example.invalid", port: 5001, usernameHint: "operator"), capabilities: capabilities,
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
}
private enum ServiceJournalFailure: Error { case failed }
private actor ServiceCheckpointLog {
    private(set) var values: [NasServiceCheckpoint] = []
    func append(_ value: NasServiceCheckpoint) { values.append(value) }
}
private actor ServiceFlowTransport: DsmHTTPTransport {
    static let apis = [DsmAPIName.coreFileServiceSMB, DsmAPIName.coreFileServiceNFS, DsmAPIName.coreFileServiceFTP,
        DsmAPIName.coreFileServiceSFTP, DsmAPIName.coreWebDSM, DsmAPIName.coreFileServiceDiscovery, DsmAPIName.coreTerminal, DsmAPIName.coreNetworkProxy]
    private(set) var calls: [[String: String]] = []
    var writes: [[String: String]] { calls.filter { $0["method"] == "set" } }
    private var mode = "normal"
    private var payloads: [String: [String: Any]] = [
        DsmAPIName.coreFileServiceSMB: ["enable_samba": false], DsmAPIName.coreFileServiceNFS: ["enable_nfs": false],
        DsmAPIName.coreFileServiceFTP: ["enable_ftp": false, "enable_ftps": false, "portnum": 21],
        DsmAPIName.coreFileServiceSFTP: ["enable": false, "portnum": 22], DsmAPIName.coreWebDSM: ["enable_ssdp": false, "enable_avahi": false],
        DsmAPIName.coreFileServiceDiscovery: ["enable_smb_time_machine": false],
        DsmAPIName.coreTerminal: ["enable_ssh": false, "enable_telnet": false, "ssh_port": 22],
        DsmAPIName.coreNetworkProxy: ["enable": false, "http_host": "proxy.example.invalid", "http_port": 3128]]
    func setMode(_ value: String) { mode = value }
    func set(_ api: String, key: String, value: any Sendable) { payloads[api]?[key] = value }
    func removeOptionalFields() { payloads[DsmAPIName.coreTerminal]?.removeValue(forKey: "ssh_port"); payloads[DsmAPIName.coreFileServiceFTP]?.removeValue(forKey: "enable_ftps") }
    func changeUneditedField(_ kind: NasServiceKind) {
        switch kind { case .fileServices: payloads[DsmAPIName.coreFileServiceNFS]?["enable_nfs"] = true
        case .terminal: payloads[DsmAPIName.coreTerminal]?["enable_telnet"] = true
        case .proxy: payloads[DsmAPIName.coreNetworkProxy]?["http_port"] = 8080 }
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        calls.append(fields); let api = fields["api"] ?? ""
        if fields["method"] == "get" {
            if mode == "offline" && !writes.isEmpty { throw URLError(.notConnectedToInternet) }
            return response(payloads[api] ?? [:])
        }
        if mode == "denied" || mode == "second-denied" && writes.count == 2 { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
        for (key, value) in fields where payloads[api]?[key] != nil {
            if mode != "partial" || key == "enable_ssh" {
                if value == "true" || value == "false" { payloads[api]?[key] = value == "true" }
                else if let port = Int(value) { payloads[api]?[key] = port }
                else { payloads[api]?[key] = value }
            }
        }
        if mode == "revert-first" && writes.count == 2 { payloads[DsmAPIName.coreFileServiceSMB]?["enable_samba"] = false }
        if mode == "lost-ack" || mode == "offline" { throw URLError(.networkConnectionLost) }
        return response([:])
    }
    private func response(_ payload: [String: Any]) -> DsmHTTPResponse { .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": payload]), statusCode: 200) }
}

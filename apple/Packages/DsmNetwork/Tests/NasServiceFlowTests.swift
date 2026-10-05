import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class NasServiceFlowTests: XCTestCase {
    func test压缩保存两个边界分别确认且不包含重启请求() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let original = try await repository.loadServiceForManagement(.zram)
        let result = try await repository.changeServiceResult(change(original)) { await log.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess); XCTAssertEqual(result.counts.succeeded, 2)
        let writes = await transport.writes
        XCTAssertEqual(writes.map { $0["api"] }, [DsmAPIName.coreHardwareZRAM, DsmAPIName.coreHardwareNeedReboot])
        XCTAssertEqual(writes.map { $0["version"] }, ["1", "1"])
        XCTAssertEqual(writes[0]["enable_zram"], "true"); XCTAssertNil(writes[1]["enable_zram"])
        XCTAssertTrue(writes.allSatisfy { $0["method"] == "set" })
        let stages = await log.values
        XCTAssertEqual(stages, [.willSubmit(.zram), .accepted(.zram), .verified(.zram), .willSubmit(.rebootRequired), .accepted(.rebootRequired), .verified(.rebootRequired)])
    }

    func test已有重启要求仍执行本次压缩保存的两个边界() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        await transport.set(DsmAPIName.coreHardwareNeedReboot, key: "need_reboot", value: true)
        let original = try await repository.loadServiceForManagement(.zram)
        let result = try await repository.changeServiceResult(change(original)) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
    }

    func test压缩缺少标记能力或字段不可确定时不可写入() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport, missing: [DsmAPIName.coreHardwareNeedReboot])
        let value = try await repository.loadServiceForManagement(.zram)
        XCTAssertFalse(value.supportsEditing); XCTAssertFalse(value.isEmpty)
        let invalid = try await repository.changeServiceResult(change(value)) { _ in XCTFail() }
        XCTAssertFalse(invalid.submitted)
        let complete = NasServiceSettings.zram(.init(isEnabled: false, configuredBytes: nil, algorithm: .unknown), needsReboot: false)
        let unsupported = try await repository.changeServiceResult(change(complete)) { _ in XCTFail() }
        XCTAssertEqual(unsupported.status, .unsupported)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }

    func test重启要求畸形不猜为布尔值也不能据此保存() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        await transport.set(DsmAPIName.coreHardwareNeedReboot, key: "need_reboot", value: "true")
        let value = try await repository.loadServiceForManagement(.zram)
        XCTAssertFalse(value.supportsEditing)
        let result = try await repository.changeServiceResult(change(value)) { _ in XCTFail() }
        XCTAssertFalse(result.submitted); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }

    func test压缩首步成功第二步拒绝保留部分结果且不自动重发() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let original = try await repository.loadServiceForManagement(.zram)
        await transport.setMode("second-denied")
        let result = try await repository.changeServiceResult(change(original)) { await log.append($0) }
        XCTAssertEqual(result.status, .partialSuccess); XCTAssertEqual(result.errorCategory, .permission)
        XCTAssertEqual(result.counts.succeeded, 1); XCTAssertEqual(result.counts.failed, 1)
        _ = try await repository.loadServiceForManagement(.zram)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
        let stages = await log.values; XCTAssertEqual(stages.last, .rejected(.rebootRequired))
    }

    func test继续重启要求只提交标记而不重复保存压缩开关() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        await transport.set(DsmAPIName.coreHardwareZRAM, key: "enable_zram", value: true)
        let original = try await repository.loadServiceForManagement(.zram)
        guard case .zram(let snapshot, _) = original else { return XCTFail() }
        let result = try await repository.changeServiceResult(.init(original: original, desired: .zram(snapshot, needsReboot: true))) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess); XCTAssertEqual(result.counts.succeeded, 1)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["api"], DsmAPIName.coreHardwareNeedReboot)
    }

    func test压缩第二步前权限撤回不能进入写请求() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadServiceForManagement(.zram)
        do {
            _ = try await repository.changeServiceResult(change(original)) { stage in
                if stage == .willSubmit(.rebootRequired) { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
            }; XCTFail()
        } catch { XCTAssertEqual((error as? AppError)?.category, .permissionDenied) }
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["api"], DsmAPIName.coreHardwareZRAM)
    }

    func test压缩首步回执保存失败不开始后一步() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadServiceForManagement(.zram)
        do {
            _ = try await repository.changeServiceResult(change(original)) { if $0 == .accepted(.zram) { throw ServiceJournalFailure.failed } }; XCTFail()
        } catch { XCTAssertTrue(error is ServiceJournalFailure) }
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }

    func test压缩写后断线只保留未知且不会调用后一步() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadServiceForManagement(.zram)
        await transport.setMode("offline")
        let result = try await repository.changeServiceResult(change(original)) { _ in }
        XCTAssertEqual(result.status, .submittedButUnverified); XCTAssertEqual(result.counts.unknown, 1)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }

    func test电源计划完整保存两个数组和周日编码() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let original = try await repository.loadServiceForManagement(.powerSchedule)
        XCTAssertTrue(original.isEmpty); XCTAssertTrue(original.supportsEditing)
        let result = try await repository.changeServiceResult(change(original)) { await log.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0]["method"], "save"); XCTAssertEqual(writes[0]["version"], "1"); XCTAssertEqual(writes[0]["poweron_tasks"], "[]")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(writes[0]["poweroff_tasks"]).utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0]["weekdays"] as? String, "0,1,2,3,4,5,6")
        XCTAssertEqual(rows[0]["enabled"] as? Bool, false); XCTAssertEqual(rows[0]["hour"] as? Int, 8); XCTAssertEqual(rows[0]["min"] as? Int, 15)
        let stages = await log.values; XCTAssertEqual(stages, [.willSubmit(.powerSchedule), .accepted(.powerSchedule), .verified(.powerSchedule)])
    }

    func test计划顺序与临时身份变化不会误判原清单变化() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let rows = [["enabled": false, "hour": 8, "min": 0, "weekdays": "1,2"] as [String: any Sendable],
                    ["enabled": true, "hour": 9, "min": 15, "weekdays": "0,6"]]
        await transport.set(DsmAPIName.coreHardwarePowerSchedule, key: "poweron_tasks", value: rows)
        let original = try await repository.loadServiceForManagement(.powerSchedule)
        await transport.set(DsmAPIName.coreHardwarePowerSchedule, key: "poweron_tasks", value: Array(rows.reversed()))
        let result = try await repository.changeServiceResult(change(original)) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }

    func test清空电源计划仍提交两个明确空数组() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let start = try await repository.loadServiceForManagement(.powerSchedule)
        _ = try await repository.changeServiceResult(change(start)) { _ in }
        let original = try await repository.loadServiceForManagement(.powerSchedule)
        let result = try await repository.changeServiceResult(.init(original: original, desired: start)) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[1]["poweron_tasks"], "[]"); XCTAssertEqual(writes[1]["poweroff_tasks"], "[]")
    }

    func test不完整清单时间重叠和超量计划全部零写入() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadServiceForManagement(.powerSchedule)
        let entry = NasPowerScheduleEntry(id: "sample", action: .startup, isEnabled: false, hour: 8, minute: 0, recurrence: .daily)
        for (entries, total, complete) in [([entry, entry], 2, true), (Array(repeating: entry, count: 201), 201, true), ([entry], 2, false)] {
            let desired = NasServiceSettings.powerSchedule(.init(entries: entries, timeZoneIdentifier: "Asia/Shanghai", total: total, isTruncated: !complete, supportsEditing: complete))
            let result = try await repository.changeServiceResult(.init(original: original, desired: desired)) { _ in XCTFail() }
            XCTAssertFalse(result.submitted)
        }
        await transport.set(DsmAPIName.coreHardwarePowerSchedule, key: "poweron_tasks", value: [["enabled": false, "hour": 8, "min": 0, "weekdays": "1"] as [String: any Sendable]])
        await transport.set(DsmAPIName.coreHardwarePowerSchedule, key: "total", value: 2)
        let incomplete = try await repository.loadServiceForManagement(.powerSchedule)
        XCTAssertFalse(incomplete.supportsEditing)
        let result = try await repository.changeServiceResult(change(incomplete)) { _ in XCTFail() }
        XCTAssertFalse(result.submitted); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }

    func test电源计划未知结果只读恢复不重放保存() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadServiceForManagement(.powerSchedule), change = change(original)
        await transport.setMode("offline")
        let result = try await repository.changeServiceResult(change) { _ in }
        XCTAssertEqual(result.status, .submittedButUnverified)
        await transport.setMode("normal")
        let actual = try await repository.loadServiceForManagement(.powerSchedule)
        XCTAssertTrue(change.savedFieldsMatch(actual, step: .powerSchedule))
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }

    func test电源计划保存后NAS时区改变不能仅凭时分相同报告成功() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadServiceForManagement(.powerSchedule)
        await transport.setMode("power-timezone-changed-after-save")
        let result = try await repository.changeServiceResult(change(original)) { _ in }
        XCTAssertEqual(result.status, .submittedButUnverified); XCTAssertEqual(result.counts.unknown, 1)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }

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
            let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], kind == .remoteAccess ? "set_misc_config" : (kind == .powerSchedule ? "save" : "set"))
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

    func test远程访问两个固定接口各自提交并保存回执() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let original = try await repository.loadServiceForManagement(.remoteAccess)
        let desired = NasRemoteAccessSettings(isRelayEnabled: false, isRouterConfigurationEnabled: true, canDisableRelay: true)
        let result = try await repository.changeServiceResult(.init(original: original, desired: .remoteAccess(desired))) { await log.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess); XCTAssertEqual(result.counts.succeeded, 2)
        let writes = await transport.writes
        XCTAssertEqual(writes.map { $0["api"] }, [DsmAPIName.coreQuickConnect, DsmAPIName.coreQuickConnectUPnP])
        XCTAssertEqual(writes.map { $0["method"] }, ["set_misc_config", "set"]); XCTAssertEqual(writes.map { $0["version"] }, ["3", "1"])
        XCTAssertEqual(writes[0]["relay_enabled"], "false"); XCTAssertNil(writes[0]["enabled"])
        XCTAssertEqual(writes[1]["enabled"], "true"); XCTAssertNil(writes[1]["relay_enabled"])
        let stages = await log.values
        XCTAssertEqual(stages, [.willSubmit(.relay), .accepted(.relay), .verified(.relay), .willSubmit(.routerConfiguration), .accepted(.routerConfiguration), .verified(.routerConfiguration)])
    }

    func test可信中继连接不能通过伪造草稿或原值关闭但可设置路由器() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport, host: "alpha.beta.quickconnect.to")
        let original = try await repository.loadServiceForManagement(.remoteAccess)
        guard case .remoteAccess(let settings) = original else { return XCTFail() }; XCTAssertFalse(settings.canDisableRelay)
        let forged = NasServiceSettings.remoteAccess(.init(isRelayEnabled: true, isRouterConfigurationEnabled: false, canDisableRelay: true))
        for baseline in [original, forged] {
            let result = try await repository.changeServiceResult(.init(original: baseline, desired: .remoteAccess(.init(isRelayEnabled: false, isRouterConfigurationEnabled: false, canDisableRelay: true)))) { _ in XCTFail("不能关闭当前中继") }
            XCTAssertFalse(result.submitted)
        }
        var desired = settings; desired.isRouterConfigurationEnabled = true
        let result = try await repository.changeServiceResult(.init(original: original, desired: .remoteAccess(desired))) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["api"], DsmAPIName.coreQuickConnectUPnP)
    }

    func test直连类别可以关闭中继并保留严格布尔字段() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport, host: "alpha.direct.quickconnect.to")
        let original = try await repository.loadServiceForManagement(.remoteAccess)
        let result = try await repository.changeServiceResult(change(original)) { _ in }; XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["relay_enabled"], "false")
    }

    func test远程单项读取失败与字段未提供分开且保留另一项() async throws {
        for malformed in [false, true] {
            let transport = ServiceFlowTransport(), repository = try repository(transport)
            if malformed { await transport.set(DsmAPIName.coreQuickConnect, key: "relay_enabled", value: "true") }
            else { await transport.setMode("relay-read-error") }
            let original = try await repository.loadServiceForManagement(.remoteAccess)
            guard case .remoteAccess(var value) = original else { return XCTFail() }
            XCTAssertNil(value.isRelayEnabled); XCTAssertTrue(value.relayReadFailed); XCTAssertEqual(value.isRouterConfigurationEnabled, false); XCTAssertFalse(value.routerConfigurationReadFailed)
            value.isRouterConfigurationEnabled = true
            let result = try await repository.changeServiceResult(.init(original: original, desired: .remoteAccess(value))) { _ in }
            XCTAssertEqual(result.status, .confirmedSuccess)
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["api"], DsmAPIName.coreQuickConnectUPnP)
        }
    }

    func test两项远程读取都失败不能显示为空而旧读取语义保持() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        await transport.setMode("remote-read-error")
        do { _ = try await repository.loadServiceForManagement(.remoteAccess); XCTFail("两项读取失败不能成为空设置") } catch {}
        let old = try await repository.loadRemoteAccessSettings()
        XCTAssertNil(old.isRelayEnabled); XCTAssertNil(old.isRouterConfigurationEnabled); XCTAssertFalse(old.relayReadFailed); XCTAssertFalse(old.routerConfigurationReadFailed)
    }

    func test远程读取认证与证书失败必须传播不读取下一项() async throws {
        for category in [AppErrorCategory.authenticationRequired, .tlsUntrusted, .tlsCertificateChanged] {
            let transport = ServiceFlowTransport(), repository = try repository(transport)
            await transport.setReadFailure(category)
            do { _ = try await repository.loadServiceForManagement(.remoteAccess); XCTFail("不能吞掉认证或证书失败") }
            catch {
                if category == .tlsCertificateChanged { XCTAssertTrue(error is DsmCertificateTrustError) }
                else { XCTAssertEqual((error as? AppError)?.category, category) }
            }
            let calls = await transport.calls; XCTAssertEqual(calls.count, 1)
        }
    }

    func test远程第二项断线只保留已确认第一项而不重发() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let original = try await repository.loadServiceForManagement(.remoteAccess)
        await transport.setMode("remote-second-offline")
        let desired = NasServiceSettings.remoteAccess(.init(isRelayEnabled: false, isRouterConfigurationEnabled: true, canDisableRelay: true))
        let result = try await repository.changeServiceResult(.init(original: original, desired: desired)) { await log.append($0) }
        XCTAssertEqual(result.status, .partialSuccess); XCTAssertEqual(result.counts.succeeded, 1); XCTAssertEqual(result.counts.unknown, 1)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
        let stages = await log.values; XCTAssertTrue(stages.contains(.verified(.relay))); XCTAssertFalse(stages.contains(.verified(.routerConfiguration)))
    }

    func test远程缺少后项所需版本在第一项之前拒绝全部写入() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport, minimum: [DsmAPIName.coreQuickConnectUPnP: 2])
        let original = NasServiceSettings.remoteAccess(.init(isRelayEnabled: true, isRouterConfigurationEnabled: false, canDisableRelay: true))
        let desired = NasServiceSettings.remoteAccess(.init(isRelayEnabled: false, isRouterConfigurationEnabled: true, canDisableRelay: true))
        let result = try await repository.changeServiceResult(.init(original: original, desired: desired)) { _ in XCTFail() }
        XCTAssertEqual(result.status, .unsupported); XCTAssertFalse(result.submitted)
        let calls = await transport.calls; XCTAssertTrue(calls.isEmpty)
    }

    private func change(_ original: NasServiceSettings) -> NasServiceChange {
        let desired: NasServiceSettings
        switch original {
        case .fileServices(var value): value.isSMBEnabled?.toggle(); desired = .fileServices(value)
        case .terminal(var value): value.isSSHEnabled.toggle(); desired = .terminal(value)
        case .proxy(var value): value.isEnabled.toggle(); desired = .proxy(value)
        case .remoteAccess(var value): value.isRelayEnabled?.toggle(); desired = .remoteAccess(value)
        case .zram(let value, _): desired = .zram(.init(isEnabled: value.isEnabled.map { !$0 }, configuredBytes: value.configuredBytes, algorithm: value.algorithm), needsReboot: true)
        case .powerSchedule(let value): desired = .powerSchedule(.init(entries: [.init(id: "draft", action: .shutdown, isEnabled: false, hour: 8, minute: 15, recurrence: .daily)], timeZoneIdentifier: value.timeZoneIdentifier, total: 1, isTruncated: false, supportsEditing: true))
        }
        return .init(original: original, desired: desired)
    }
    private func repository(_ transport: ServiceFlowTransport, missing: [String] = [], minimum: [String: Int] = [:], host: String = "nas.example.invalid") throws -> DsmNasAdministrationRepository {
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: ServiceFlowTransport.apis.filter { !missing.contains($0) }.map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: minimum[$0] ?? 1, maxVersion: 3, requestFormat: .form, selectedVersion: 3)) }))
        return try .init(profile: NasProfile(displayName: "Synthetic", host: host, port: 5001, usernameHint: "operator"), capabilities: capabilities,
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
        DsmAPIName.coreFileServiceSFTP, DsmAPIName.coreWebDSM, DsmAPIName.coreFileServiceDiscovery, DsmAPIName.coreTerminal, DsmAPIName.coreNetworkProxy, DsmAPIName.coreQuickConnect, DsmAPIName.coreQuickConnectUPnP,
        DsmAPIName.coreHardwareZRAM, DsmAPIName.coreHardwareNeedReboot, DsmAPIName.coreHardwarePowerSchedule]
    private(set) var calls: [[String: String]] = []
    var writes: [[String: String]] { calls.filter { ["set", "set_misc_config", "save"].contains($0["method"] ?? "") } }
    private var mode = "normal"
    private var readFailure: AppErrorCategory?
    func setReadFailure(_ value: AppErrorCategory) { readFailure = value }
    private var payloads: [String: [String: Any]] = [
        DsmAPIName.coreFileServiceSMB: ["enable_samba": false], DsmAPIName.coreFileServiceNFS: ["enable_nfs": false],
        DsmAPIName.coreFileServiceFTP: ["enable_ftp": false, "enable_ftps": false, "portnum": 21],
        DsmAPIName.coreFileServiceSFTP: ["enable": false, "portnum": 22], DsmAPIName.coreWebDSM: ["enable_ssdp": false, "enable_avahi": false],
        DsmAPIName.coreFileServiceDiscovery: ["enable_smb_time_machine": false],
        DsmAPIName.coreTerminal: ["enable_ssh": false, "enable_telnet": false, "ssh_port": 22],
        DsmAPIName.coreNetworkProxy: ["enable": false, "http_host": "proxy.example.invalid", "http_port": 3128],
        DsmAPIName.coreQuickConnect: ["relay_enabled": true], DsmAPIName.coreQuickConnectUPnP: ["enabled": false],
        DsmAPIName.coreHardwareZRAM: ["enable_zram": false], DsmAPIName.coreHardwareNeedReboot: ["need_reboot": false],
        DsmAPIName.coreHardwarePowerSchedule: ["poweron_tasks": [], "poweroff_tasks": [], "timezone": "Asia/Shanghai"]]
    func setMode(_ value: String) { mode = value }
    func set(_ api: String, key: String, value: any Sendable) { payloads[api]?[key] = value }
    func removeOptionalFields() { payloads[DsmAPIName.coreTerminal]?.removeValue(forKey: "ssh_port"); payloads[DsmAPIName.coreFileServiceFTP]?.removeValue(forKey: "enable_ftps") }
    func changeUneditedField(_ kind: NasServiceKind) {
        switch kind { case .fileServices: payloads[DsmAPIName.coreFileServiceNFS]?["enable_nfs"] = true
        case .terminal: payloads[DsmAPIName.coreTerminal]?["enable_telnet"] = true
        case .proxy: payloads[DsmAPIName.coreNetworkProxy]?["http_port"] = 8080
        case .remoteAccess: payloads[DsmAPIName.coreQuickConnectUPnP]?["enabled"] = true
        case .zram: payloads[DsmAPIName.coreHardwareZRAM]?["enable_zram"] = true
        case .powerSchedule: payloads[DsmAPIName.coreHardwarePowerSchedule]?["timezone"] = "Europe/London" }
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        calls.append(fields); let api = fields["api"] ?? ""
        if ["get", "get_misc_config", "load"].contains(fields["method"] ?? "") {
            if let readFailure {
                if readFailure == .authenticationRequired { return .init(data: Data(#"{"success":false,"error":{"code":106}}"#.utf8), statusCode: 200) }
                if readFailure == .tlsUntrusted { throw URLError(.serverCertificateUntrusted) }
                throw DsmCertificateTrustError.changed(.init(host: "fixture.example.invalid", subjectSummary: "Synthetic", sha256Fingerprint: String(repeating: "a", count: 64), canBePinned: true))
            }
            if mode == "remote-read-error" || mode == "relay-read-error" && api == DsmAPIName.coreQuickConnect || mode == "remote-second-offline" && writes.count == 2 { throw URLError(.notConnectedToInternet) }
            if mode == "offline" && !writes.isEmpty { throw URLError(.notConnectedToInternet) }
            return response(payloads[api] ?? [:])
        }
        if mode == "denied" || mode == "second-denied" && writes.count == 2 { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
        for (key, value) in fields where payloads[api]?[key] != nil {
            if mode != "partial" || key == "enable_ssh" {
                if value == "true" || value == "false" { payloads[api]?[key] = value == "true" }
                else if let port = Int(value) { payloads[api]?[key] = port }
                else if ["poweron_tasks", "poweroff_tasks"].contains(key) { payloads[api]?[key] = try JSONSerialization.jsonObject(with: Data(value.utf8)) }
                else { payloads[api]?[key] = value }
            }
        }
        if api == DsmAPIName.coreHardwareNeedReboot { payloads[api]?["need_reboot"] = true }
        if mode == "power-timezone-changed-after-save" && api == DsmAPIName.coreHardwarePowerSchedule { payloads[api]?["timezone"] = "Europe/London" }
        if mode == "revert-first" && writes.count == 2 { payloads[DsmAPIName.coreFileServiceSMB]?["enable_samba"] = false }
        if mode == "lost-ack" || mode == "offline" { throw URLError(.networkConnectionLost) }
        return response([:])
    }
    private func response(_ payload: [String: Any]) -> DsmHTTPResponse { .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": payload]), statusCode: 200) }
}

import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class NasServiceFlowTests: XCTestCase {
    func test硬件管理六组使用v1和七个独立写边界() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let original = try await repository.loadServiceForManagement(.hardware)
        guard case .hardware(var value) = original else { return XCTFail() }
        value.restartsAfterPowerFailure = true; value.ledBrightness = 5; value.fanMode = "coolfan"
        value.isVolumeFailureAlertEnabled = false; value.isWakeUpLogEnabled = true
        value.ups?.isEnabled = true; value.ups?.mode = "SLAVE"; value.ups?.networkServerAddress = "192.0.2.20"
        let result = try await repository.changeServiceResult(.init(original: original, desired: .hardware(value))) { await log.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess); XCTAssertEqual(result.counts.succeeded, 7)
        let writes = await transport.writes, calls = await transport.calls, checkpoints = await log.values
        XCTAssertEqual(writes.map { $0["api"] }, [DsmAPIName.coreHardwarePowerRecovery, DsmAPIName.coreHardwareLEDBrightness,
            DsmAPIName.coreHardwareLEDBrightness, DsmAPIName.coreHardwareFanSpeed, DsmAPIName.coreHardwareBeepControl,
            DsmAPIName.coreHardwareHibernation, DsmAPIName.coreExternalDeviceUPS])
        XCTAssertEqual(writes.map { $0["method"] }, ["set", "set_current_brightness", "update", "set", "set", "set", "set"])
        XCTAssertTrue(calls.allSatisfy { $0["version"] == "1" }); XCTAssertEqual(checkpoints.count, 21)
        XCTAssertEqual(writes[4]["volume_or_cache_crash"], "false"); XCTAssertNil(writes[4]["volume_crash"]); XCTAssertNil(writes[4]["fan_fail"])
        XCTAssertEqual(writes[5]["enable_log"], "true"); XCTAssertNil(writes[5]["auto_poweroff_enable"])
        XCTAssertEqual(writes[6]["net_server_ip"], "192.0.2.20"); XCTAssertEqual(writes[6]["snmp_server_ip"], "")
    }

    func test硬件管理严格类型整数和范围错误不能作为可写快照() async throws {
        let cases: [(String, String, any Sendable)] = [
            (DsmAPIName.coreHardwarePowerRecovery, "rc_power_config", "perhaps"),
            (DsmAPIName.coreHardwareLEDBrightness, "led_brightness", 3.5),
            (DsmAPIName.coreHardwareLEDBrightness, "max", 1),
            (DsmAPIName.coreHardwareBeepControl, "support_reset_beep", "unknown"),
            (DsmAPIName.coreHardwareHibernation, "enable_log", 2),
            (DsmAPIName.coreExternalDeviceUPS, "delay_time", 604801),
            (DsmAPIName.coreExternalDeviceUPS, "delay_time", 1.25),
            (DsmAPIName.coreExternalDeviceUPS, "net_server_ip", false)]
        for (api, key, value) in cases {
            let transport = ServiceFlowTransport(), repository = try repository(transport)
            await transport.set(api, key: key, value: value)
            do { _ = try await repository.loadServiceForManagement(.hardware); XCTFail("畸形字段：\(key)") } catch { XCTAssertTrue(error is AppError) }
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }

    func test硬件管理只使用实际支持档位和原有可选字段() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        await transport.set(DsmAPIName.coreHardwareBeepControl, key: "support_reset_beep", value: false)
        await transport.remove(DsmAPIName.coreExternalDeviceUPS, key: "net_server_ip")
        let original = try await repository.loadServiceForManagement(.hardware)
        guard case .hardware(let value) = original else { return XCTFail() }
        XCTAssertNil(value.isResetSoundEnabled); XCTAssertNil(value.ups?.networkServerAddress); XCTAssertEqual(value.ups?.snmpServerAddress, "")
        var badFan = value; badFan.fanMode = "quietstopfan"
        var missingSound = value; missingSound.isResetSoundEnabled = true
        var missingAddress = value; missingAddress.ups?.networkServerAddress = "192.0.2.20"
        var missingDelay = value; missingDelay.ups?.safeModeDelaySeconds = nil
        for next in [badFan, missingSound, missingAddress, missingDelay] {
            let change = NasServiceChange(original: original, desired: .hardware(next))
            XCTAssertNil(change.orderedSteps)
            let result = try await repository.changeServiceResult(change) { _ in XCTFail() }
            XCTAssertFalse(result.submitted)
        }
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }

    func test硬件管理缺亮度范围与风扇范围时仍可编辑其他可信设置() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        await transport.remove(DsmAPIName.coreHardwareLEDBrightness, key: "min")
        await transport.remove(DsmAPIName.coreHardwareFanSpeed, key: "cool_fan")
        let original = try await repository.loadServiceForManagement(.hardware)
        guard case .hardware(let value) = original else { return XCTFail() }
        XCTAssertTrue(original.supportsEditing)
        var led = value; led.ledBrightness = 5
        var fan = value; fan.fanMode = "coolfan"
        XCTAssertNil(NasServiceChange(original: original, desired: .hardware(led)).orderedSteps)
        XCTAssertNil(NasServiceChange(original: original, desired: .hardware(fan)).orderedSteps)
        let result = try await repository.changeServiceResult(change(original)) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["api"] }, [DsmAPIName.coreHardwarePowerRecovery])
    }

    func test硬件管理UPS可信空地址可编辑但启用网络模式必须有地址() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadServiceForManagement(.hardware)
        guard case .hardware(var value) = original else { return XCTFail() }
        XCTAssertEqual(value.ups?.networkServerAddress, "")
        value.ups?.isEnabled = true; value.ups?.mode = "SLAVE"
        XCTAssertNil(NasServiceChange(original: original, desired: .hardware(value)).orderedSteps)
        value.ups?.networkServerAddress = " 192.0.2.20 "
        let result = try await repository.changeServiceResult(.init(original: original, desired: .hardware(value))) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["net_server_ip"], "192.0.2.20")
    }

    func test硬件管理蜂鸣使用当前真实字段且能力没有v1时零写() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        await transport.remove(DsmAPIName.coreHardwareBeepControl, key: "volume_or_cache_crash")
        await transport.set(DsmAPIName.coreHardwareBeepControl, key: "volume_crash", value: true)
        let original = try await repository.loadServiceForManagement(.hardware)
        guard case .hardware(var value) = original else { return XCTFail() }; value.isVolumeFailureAlertEnabled = false
        let change = NasServiceChange(original: original, desired: .hardware(value))
        let noVersion = try self.repository(transport, minimum: [DsmAPIName.coreHardwareBeepControl: 2])
        let refused = try await noVersion.changeServiceResult(change) { _ in XCTFail() }
        XCTAssertEqual(refused.status, .unsupported); XCTAssertFalse(refused.submitted)
        let result = try await repository.changeServiceResult(change) { _ in }; XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["volume_crash"], "false"); XCTAssertNil(writes[0]["volume_or_cache_crash"])
    }

    func test硬件管理LED首步丢回执不调用应用且不能凭亮度认领() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let change = try await ledChange(repository); await transport.setMode("lost-ack")
        let result = try await repository.changeServiceResult(change) { await log.append($0) }
        XCTAssertEqual(result.status, .submittedButUnverified); XCTAssertEqual(result.counts.unknown, 1)
        let stages = await log.values, writes = await transport.writes
        XCTAssertEqual(stages, [.willSubmit(.ledBrightness)]); XCTAssertEqual(writes.map { $0["method"] }, ["set_current_brightness"])
    }

    func test硬件管理LED第二步丢回执保留第一步且不误报全部成功() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let change = try await ledChange(repository); await transport.setMode("led-update-lost-ack")
        let result = try await repository.changeServiceResult(change) { await log.append($0) }
        XCTAssertEqual(result.status, .partialSuccess); XCTAssertEqual(result.counts, try .init(succeeded: 1, failed: 0, unknown: 1))
        let stages = await log.values, writes = await transport.writes
        XCTAssertEqual(stages, [.willSubmit(.ledBrightness), .accepted(.ledBrightness), .verified(.ledBrightness), .willSubmit(.ledUpdate)])
        XCTAssertEqual(writes.map { $0["method"] }, ["set_current_brightness", "update"])
    }

    func test硬件管理LED应用被拒绝后显式继续只应用不重写亮度() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let change = try await ledChange(repository); await transport.setMode("led-update-denied")
        let result = try await repository.changeServiceResult(change) { _ in }
        XCTAssertEqual(result.status, .partialSuccess); XCTAssertEqual(result.errorCategory, .permission)
        await transport.setMode("normal")
        let original = try await repository.loadServiceForManagement(.hardware)
        let continued = try await repository.changeServiceResult(.init(original: original, desired: original, appliesSavedLEDBrightness: true)) { _ in }
        XCTAssertEqual(continued.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["set_current_brightness", "update", "update"])
    }

    func test硬件管理LED应用前撤权或回执无法保存时不继续写入() async throws {
        for stop: NasServiceCheckpoint in [.accepted(.ledBrightness), .willSubmit(.ledUpdate)] {
            let transport = ServiceFlowTransport(), repository = try repository(transport), change = try await ledChange(repository)
            do {
                _ = try await repository.changeServiceResult(change) { if $0 == stop { throw ServiceJournalFailure.failed } }; XCTFail()
            } catch { XCTAssertTrue(error is ServiceJournalFailure) }
            let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["set_current_brightness"])
        }
    }

    func test硬件管理LED应用前范围变化必须停止() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), change = try await ledChange(repository)
        let result = try await repository.changeServiceResult(change) {
            if $0 == .verified(.ledBrightness) { await transport.set(DsmAPIName.coreHardwareLEDBrightness, key: "max", value: 6) }
        }
        XCTAssertEqual(result.status, .partialSuccess); XCTAssertEqual(result.errorCategory, .conflict)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }

    private func ledChange(_ repository: DsmNasAdministrationRepository) async throws -> NasServiceChange {
        let original = try await repository.loadServiceForManagement(.hardware)
        guard case .hardware(var value) = original else { throw ServiceJournalFailure.failed }
        value.ledBrightness = 5; return .init(original: original, desired: .hardware(value))
    }

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

    func test网卡DHCP只提交目标且忽略动态租约状态变化() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let original = try await repository.loadServiceForManagement(.ethernet)
        await transport.set(DsmAPIName.coreNetworkEthernet, key: "ip", value: "192.0.2.55")
        await transport.set(DsmAPIName.coreNetworkEthernet, key: "status", value: "disconnected")
        let result = try await repository.changeServiceResult(change(original)) { await log.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["version"], "1")
        let configs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(writes[0]["configs"]).utf8)) as? [[String: Any]])
        XCTAssertEqual(configs.count, 1); XCTAssertEqual(configs[0]["ifname"] as? String, "eth0")
        XCTAssertEqual(configs[0]["mtu"] as? Int, 1400); XCTAssertNil(configs[0]["ip"]); XCTAssertNil(configs[0]["vlan_id"])
        let stages = await log.values; XCTAssertEqual(stages, [.willSubmit(.ethernet), .accepted(.ethernet), .verified(.ethernet)])
        let reads = await transport.calls.filter { $0["method"] != "set" }
        XCTAssertTrue(reads.filter { $0["method"] == "list" }.allSatisfy { $0["version"] == "2" })
        XCTAssertTrue(reads.filter { $0["method"] == "get" }.allSatisfy { $0["version"] == "1" })
    }
    func test网卡静态地址与VLAN保存所有原生字段() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadServiceForManagement(.ethernet)
        guard case .ethernet(var values) = original else { return XCTFail() }
        values[0].usesDHCP = false; values[0].address = "192.0.2.42"; values[0].subnetMask = "255.255.255.0"
        values[0].gateway = "192.0.2.1"; values[0].dnsServers = "192.0.2.53"; values[0].isVLANEnabled = true; values[0].vlanID = 12
        let result = try await repository.changeServiceResult(.init(original: original, desired: .ethernet(values))) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes
        let configs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(writes.first?["configs"]).utf8)) as? [[String: Any]])
        XCTAssertEqual(configs[0]["ip"] as? String, "192.0.2.42"); XCTAssertEqual(configs[0]["mask"] as? String, "255.255.255.0")
        XCTAssertEqual(configs[0]["gateway"] as? String, "192.0.2.1"); XCTAssertEqual(configs[0]["dns"] as? String, "192.0.2.53")
        XCTAssertEqual(configs[0]["vlan_id"] as? Int, 12)
    }
    func test网卡所需版本不足时零请求() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport, minimum: [DsmAPIName.coreNetworkEthernet: 2])
        do { _ = try await repository.loadServiceForManagement(.ethernet); XCTFail() } catch { XCTAssertEqual((error as? AppError)?.category, .apiUnavailable) }
        let requests = await transport.calls; XCTAssertTrue(requests.isEmpty)
    }
    func test网卡畸形和缺失字段不能用默认值编辑() async throws {
        for (key, value): (String, any Sendable) in [("use_dhcp", "unknown"), ("is_default_gateway", 3), ("enable_vlan", "unknown"), ("mtu", 1e30), ("mtu", 1500.5), ("mtu", true)] {
            let transport = ServiceFlowTransport(), repository = try repository(transport)
            await transport.set(DsmAPIName.coreNetworkEthernet, key: key, value: value)
            do { _ = try await repository.loadServiceForManagement(.ethernet); XCTFail(key) } catch { XCTAssertEqual((error as? AppError)?.category, .invalidResponse) }
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test网卡非法输入新增删除和多目标更改全部零写() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadServiceForManagement(.ethernet)
        guard case .ethernet(let base) = original else { return XCTFail() }
        var invalid = base; invalid[0].mtu = 9001
        var address = base; address[0].usesDHCP = false; address[0].address = "999.0.0.1"
        var vlan = base; vlan[0].isVLANEnabled = true; vlan[0].vlanID = 4095
        for next in [invalid, address, vlan, [], base + base] {
            let result = try await repository.changeServiceResult(.init(original: original, desired: .ethernet(next))) { _ in XCTFail() }
            XCTAssertFalse(result.submitted)
        }
        let first = base[0], second = NasEthernetInterface(id: "eth1", displayName: "LAN 2", status: nil, usesDHCP: true, address: "", subnetMask: "", gateway: "", dnsServers: "", isDefaultGateway: false, mtu: 1500, isVLANEnabled: false, vlanID: nil)
        var next = [first, second]; next[0].mtu = 1400; next[1].mtu = 1400
        let result = try await repository.changeServiceResult(.init(original: .ethernet([first, second]), desired: .ethernet(next))) { _ in XCTFail() }
        XCTAssertFalse(result.submitted); let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test网卡只比较原目标的保存结果不认领其他网卡() throws {
        let first = NasEthernetInterface(id: "eth0", displayName: "LAN 1", status: nil, usesDHCP: true, address: "", subnetMask: "", gateway: "", dnsServers: "", isDefaultGateway: false, mtu: 1500, isVLANEnabled: false, vlanID: nil)
        var next = first; next.mtu = 1400
        let change = NasServiceChange(original: .ethernet([first]), desired: .ethernet([next]))
        let other = NasEthernetInterface(id: "eth1", displayName: "LAN 2", status: nil, usesDHCP: true, address: "", subnetMask: "", gateway: "", dnsServers: "", isDefaultGateway: false, mtu: 1400, isVLANEnabled: false, vlanID: nil)
        XCTAssertFalse(change.savedFieldsMatch(.ethernet([other]), step: .ethernet))
        XCTAssertTrue(change.savedFieldsMatch(.ethernet([next, other]), step: .ethernet))
    }
    func test网卡未知结果保留提交检查点且只读不重发() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let original = try await repository.loadServiceForManagement(.ethernet), change = change(original)
        await transport.setMode("offline")
        let result = try await repository.changeServiceResult(change) { await log.append($0) }
        XCTAssertEqual(result.status, .submittedButUnverified)
        let stages = await log.values; XCTAssertEqual(stages, [.willSubmit(.ethernet)])
        await transport.setMode("normal")
        let current = try await repository.loadServiceForManagement(.ethernet)
        XCTAssertTrue(change.savedFieldsMatch(current, step: .ethernet))
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }

    func test安全四组逐步保存版本参数与原配置档一致() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let original = try await repository.loadServiceForManagement(.security)
        guard case .security(var value) = original else { return XCTFail() }
        value.isAutoBlockEnabled = true; value.expirationDays = 7; value.dosProtection[0].isEnabled = true
        value.isPortScanProtectionEnabled = true; value.isFirewallEnabled = true
        let result = try await repository.changeServiceResult(.init(original: original, desired: .security(value))) { await log.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess); XCTAssertEqual(result.counts.succeeded, 4)
        let writes = await transport.writes
        XCTAssertEqual(writes.map { $0["api"] }, [DsmAPIName.coreSecurityAutoBlock, DsmAPIName.coreSecurityDoS, DsmAPIName.coreSecurityFirewallConf, DsmAPIName.coreSecurityFirewallProfileApply, DsmAPIName.coreSecurityFirewallProfileApply])
        XCTAssertEqual(writes.map { $0["version"] }, ["1", "2", "1", "1", "1"])
        guard writes.count == 5 else { return }
        XCTAssertEqual(writes[0]["expire_day"], "7"); XCTAssertEqual(writes[2]["enable_port_check"], "true")
        XCTAssertEqual(writes[3]["name"], "synthetic-profile"); XCTAssertEqual(writes[3]["profile_applying"], "false")
        XCTAssertEqual(writes[4]["method"], "stop")
        let stages = await log.values
        XCTAssertEqual(Array(stages.suffix(6)), [.willSubmit(.firewall), .firewallTaskStarted("synthetic-task"), .accepted(.firewall), .firewallTaskFinished(true), .willCleanFirewallTask, .verified(.firewall)])
    }
    func test安全缺失期限小数越界和DoS不完整不能猜测保存() async throws {
        for (api, key, value) in [(DsmAPIName.coreSecurityAutoBlock, "expire_day", NSNull() as any Sendable),
                                  (DsmAPIName.coreSecurityAutoBlock, "attempts", 2.5),
                                  (DsmAPIName.coreSecurityAutoBlock, "within_mins", 10000000),
                                  (DsmAPIName.coreSecurityDoS, "configs", [["adapter": "eth0"]]),
                                  (DsmAPIName.coreSecurityFirewall, "enable_firewall", "unknown")] {
            let transport = ServiceFlowTransport(), repository = try repository(transport)
            await transport.set(api, key: key, value: value)
            do { _ = try await repository.loadServiceForManagement(.security); XCTFail("不完整设置不能作为写入基线") } catch {}
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func testDoS重复状态使用末值且比较不依赖显示名称和顺序() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        await transport.set(DsmAPIName.coreSecurityDoS, key: "configs", value: [["adapter": "eth0", "dos_protect_enable": false], ["adapter": "eth0", "dos_protect_enable": true]] as [[String: any Sendable]])
        let original = try await repository.loadServiceForManagement(.security)
        guard case .security(var value) = original else { return XCTFail() }
        XCTAssertEqual(value.dosProtection.map(\.isEnabled), [true])
        value.dosProtection = [.init(id: "eth0", displayName: "Another label", isEnabled: true)]
        XCTAssertTrue(original.hasSameConfiguration(as: .security(value)))
    }
    func test安全变更不能更换配置档新增网卡或填充未知开关() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadServiceForManagement(.security)
        guard case .security(let base) = original else { return XCTFail() }
        var profile = base; profile.firewallProfileName = "different"; profile.isFirewallEnabled = true
        var adapter = base; adapter.dosProtection.append(.init(id: "eth-new", displayName: "New", isEnabled: true))
        var invalid = base; invalid.failedAttempts = 0
        for value in [profile, adapter, invalid] {
            let result = try await repository.changeServiceResult(.init(original: original, desired: .security(value))) { _ in XCTFail() }
            XCTAssertFalse(result.submitted)
        }
        var missing = base; missing.isFirewallEnabled = nil
        XCTAssertNil(NasServiceChange(original: .security(missing), desired: .security(base)).orderedSteps)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test缺少防火墙任务版本在所有安全写入之前拒绝() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport, minimum: [DsmAPIName.coreSecurityFirewallProfileApply: 2])
        let original = try await repository.loadServiceForManagement(.security)
        guard case .security(var value) = original else { return XCTFail() }
        value.isAutoBlockEnabled = true; value.isFirewallEnabled = true
        let result = try await repository.changeServiceResult(.init(original: original, desired: .security(value))) { _ in XCTFail() }
        XCTAssertEqual(result.status, .unsupported); XCTAssertFalse(result.submitted)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test安全后组拒绝保留已保存组且停止防火墙任务() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let original = try await repository.loadServiceForManagement(.security)
        guard case .security(var value) = original else { return XCTFail() }
        value.isAutoBlockEnabled = true; value.dosProtection[0].isEnabled = true; value.isFirewallEnabled = true
        await transport.setMode("second-denied")
        let result = try await repository.changeServiceResult(.init(original: original, desired: .security(value))) { await log.append($0) }
        XCTAssertEqual(result.status, .partialSuccess); XCTAssertEqual(result.counts.succeeded, 1); XCTAssertEqual(result.errorCategory, .permission)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2); XCTAssertFalse(writes.contains { $0["method"] == "start" })
        let stages = await log.values; XCTAssertEqual(stages.last, .rejected(.denialOfService))
    }
    func test防火墙缺回执即使开关开启也保持未知并不重放() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let change = try await firewallChange(repository)
        await transport.setMode("firewall-lost-receipt")
        let result = try await repository.changeServiceResult(change) { await log.append($0) }
        XCTAssertEqual(result.status, .submittedButUnverified); XCTAssertEqual(result.counts.unknown, 1)
        let actual = try await repository.loadServiceForManagement(.security)
        XCTAssertTrue(change.savedFieldsMatch(actual, step: .firewall), "配置吻合仍不能替代原任务回执")
        let stages = await log.values; XCTAssertEqual(stages, [.willSubmit(.firewall)])
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["start"])
    }
    func test防火墙轮询断线保留原回执且不清理未知任务() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let change = try await firewallChange(repository)
        await transport.setMode("firewall-poll-offline")
        let result = try await repository.changeServiceResult(change) { await log.append($0) }
        XCTAssertEqual(result.status, .submittedButUnverified)
        let stages = await log.values; XCTAssertEqual(stages, [.willSubmit(.firewall), .firewallTaskStarted("synthetic-task"), .accepted(.firewall)])
        await transport.setMode("normal")
        let outcome = try await repository.readFirewallApplication("synthetic-task"); XCTAssertEqual(outcome, true)
        let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["start"])
    }
    func test防火墙明确任务失败不被当前开关认领为成功() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport), log = ServiceCheckpointLog()
        let change = try await firewallChange(repository)
        await transport.setMode("firewall-failed")
        let result = try await repository.changeServiceResult(change) { await log.append($0) }
        XCTAssertEqual(result.status, .confirmedFailure); XCTAssertEqual(result.counts.failed, 1)
        let stages = await log.values; XCTAssertEqual(Array(stages.suffix(3)), [.firewallTaskFinished(false), .willCleanFirewallTask, .rejected(.firewall)])
    }
    func test防火墙回执或完成记录失败均不能继续任务流程() async throws {
        for failed in [NasServiceCheckpoint.firewallTaskStarted("synthetic-task"), .firewallTaskFinished(true), .willCleanFirewallTask] {
            let transport = ServiceFlowTransport(), repository = try repository(transport)
            let change = try await firewallChange(repository)
            do { _ = try await repository.changeServiceResult(change) { if $0 == failed { throw ServiceJournalFailure.failed } }; XCTFail() }
            catch { XCTAssertTrue(error is ServiceJournalFailure) }
            let writes = await transport.writes; XCTAssertEqual(writes.map { $0["method"] }, ["start"])
            let calls = await transport.calls
            if case .firewallTaskStarted = failed { XCTAssertFalse(calls.contains { $0["method"] == "status" }) }
        }
    }
    func test防火墙任务与清理撤权立即停止且不吞权限错误() async throws {
        for mode in ["firewall-poll-denied", "firewall-clean-denied"] {
            let transport = ServiceFlowTransport(), repository = try repository(transport)
            let change = try await firewallChange(repository)
            await transport.setMode(mode)
            do { _ = try await repository.changeServiceResult(change) { _ in }; XCTFail() }
            catch { XCTAssertEqual((error as? AppError)?.category, .permissionDenied) }
            let writes = await transport.writes; XCTAssertEqual(writes.count, mode == "firewall-poll-denied" ? 1 : 2)
            let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], mode == "firewall-poll-denied" ? "status" : "stop")
        }
    }
    func test关闭防火墙只用停用动作且不需要任务能力() async throws {
        let transport = ServiceFlowTransport(), repository = try repository(transport, missing: [DsmAPIName.coreSecurityFirewallProfileApply])
        await transport.set(DsmAPIName.coreSecurityFirewall, key: "enable_firewall", value: true)
        let original = try await repository.loadServiceForManagement(.security)
        guard case .security(var value) = original else { return XCTFail() }; value.isFirewallEnabled = false
        let result = try await repository.changeServiceResult(.init(original: original, desired: .security(value))) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["set_type"], "disable"); XCTAssertEqual(writes[0]["version"], "1")
    }
    private func firewallChange(_ repository: DsmNasAdministrationRepository) async throws -> NasServiceChange {
        let original = try await repository.loadServiceForManagement(.security)
        guard case .security(var value) = original else { throw ServiceJournalFailure.failed }
        value.isFirewallEnabled = true; return .init(original: original, desired: .security(value))
    }

    private func change(_ original: NasServiceSettings) -> NasServiceChange {
        let desired: NasServiceSettings
        switch original {
        case .fileServices(var value): value.isSMBEnabled?.toggle(); desired = .fileServices(value)
        case .terminal(var value): value.isSSHEnabled.toggle(); desired = .terminal(value)
        case .ethernet(var values): values[0].mtu = 1400; desired = .ethernet(values)
        case .security(var value): value.isAutoBlockEnabled.toggle(); desired = .security(value)
        case .hardware(var value): value.restartsAfterPowerFailure?.toggle(); desired = .hardware(value)
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
        DsmAPIName.coreHardwareZRAM, DsmAPIName.coreHardwareNeedReboot, DsmAPIName.coreHardwarePowerSchedule, DsmAPIName.coreNetworkEthernet,
        DsmAPIName.coreSecurityAutoBlock, DsmAPIName.coreSecurityDoS, DsmAPIName.coreSecurityFirewall, DsmAPIName.coreSecurityFirewallConf, DsmAPIName.coreSecurityFirewallProfileApply,
        DsmAPIName.coreHardwarePowerRecovery, DsmAPIName.coreHardwareLEDBrightness, DsmAPIName.coreHardwareFanSpeed,
        DsmAPIName.coreHardwareBeepControl, DsmAPIName.coreHardwareHibernation, DsmAPIName.coreExternalDeviceUPS]
    private(set) var calls: [[String: String]] = []
    var writes: [[String: String]] { calls.filter { ["set", "set_misc_config", "save", "start", "stop", "set_current_brightness", "update"].contains($0["method"] ?? "") } }
    private var mode = "normal"
    private var readFailure: AppErrorCategory?
    func setReadFailure(_ value: AppErrorCategory) { readFailure = value }
    private var payloads: [String: [String: Any]] = [
        DsmAPIName.coreHardwarePowerRecovery: ["rc_power_config": false],
        DsmAPIName.coreHardwareLEDBrightness: ["led_brightness": 3, "min": 0, "max": 7],
        DsmAPIName.coreHardwareFanSpeed: ["dual_fan_speed": "quietfan", "cool_fan": "yes", "fan_type": 11],
        DsmAPIName.coreHardwareBeepControl: ["fan_fail": true, "volume_or_cache_crash": true, "poweron_beep": false, "poweroff_beep": false, "reset_beep": true],
        DsmAPIName.coreHardwareHibernation: ["eunit_deep_sleep": false, "enable_log": false, "sata_deep_sleep": false, "ignore_netbios_broadcast": false, "auto_poweroff_enable": false],
        DsmAPIName.coreExternalDeviceUPS: ["enable": false, "mode": "USB", "delay_time": 120, "ups_set_safemode_until_lowbatt": false, "shutdown_device": false, "net_server_ip": "", "snmp_server_ip": ""],
        DsmAPIName.coreSecurityAutoBlock: ["enable": false, "attempts": 5, "within_mins": 10, "expire_day": 0],
        DsmAPIName.coreSecurityFirewall: ["enable_firewall": false, "profile_name": "synthetic-profile"],
        DsmAPIName.coreSecurityFirewallConf: ["enable_port_check": false],
        DsmAPIName.coreSecurityDoS: ["configs": [["adapter": "eth0", "dos_protect_enable": false]]],
        DsmAPIName.coreNetworkEthernet: ["ifname": "eth0", "use_dhcp": true, "is_default_gateway": true, "mtu": 1500, "enable_vlan": false],
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
    func remove(_ api: String, key: String) { payloads[api]?.removeValue(forKey: key) }
    func removeOptionalFields() { payloads[DsmAPIName.coreTerminal]?.removeValue(forKey: "ssh_port"); payloads[DsmAPIName.coreFileServiceFTP]?.removeValue(forKey: "enable_ftps") }
    func changeUneditedField(_ kind: NasServiceKind) {
        switch kind { case .fileServices: payloads[DsmAPIName.coreFileServiceNFS]?["enable_nfs"] = true
        case .terminal: payloads[DsmAPIName.coreTerminal]?["enable_telnet"] = true
        case .proxy: payloads[DsmAPIName.coreNetworkProxy]?["http_port"] = 8080
        case .remoteAccess: payloads[DsmAPIName.coreQuickConnectUPnP]?["enabled"] = true
        case .zram: payloads[DsmAPIName.coreHardwareZRAM]?["enable_zram"] = true
        case .powerSchedule: payloads[DsmAPIName.coreHardwarePowerSchedule]?["timezone"] = "Europe/London"
        case .security: payloads[DsmAPIName.coreSecurityAutoBlock]?["attempts"] = 8
        case .hardware: payloads[DsmAPIName.coreHardwareLEDBrightness]?["led_brightness"] = 4
        case .ethernet: payloads[DsmAPIName.coreNetworkEthernet]?["enable_vlan"] = true; payloads[DsmAPIName.coreNetworkEthernet]?["vlan_id"] = 10 }
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        calls.append(fields); let api = fields["api"] ?? ""
        if api == DsmAPIName.coreSecurityFirewallProfileApply {
            if mode == "denied" { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
            switch fields["method"] {
            case "start":
                if mode == "firewall-lost-receipt" { payloads[DsmAPIName.coreSecurityFirewall]?["enable_firewall"] = true; throw URLError(.networkConnectionLost) }
                return response(["task_id": "synthetic-task"])
            case "status":
                if mode == "firewall-poll-offline" { throw URLError(.notConnectedToInternet) }
                if mode == "firewall-poll-denied" { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
                if mode == "firewall-failed" { return response(["success": false]) }
                payloads[DsmAPIName.coreSecurityFirewall]?["enable_firewall"] = true
                return response(["success": true])
            case "stop":
                if mode == "firewall-clean-denied" { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
                return response([:])
            default: break
            }
        }
        if ["list", "get", "get_misc_config", "load", "get_static_data"].contains(fields["method"] ?? "") {
            if let readFailure {
                if readFailure == .authenticationRequired { return .init(data: Data(#"{"success":false,"error":{"code":106}}"#.utf8), statusCode: 200) }
                if readFailure == .tlsUntrusted { throw URLError(.serverCertificateUntrusted) }
                throw DsmCertificateTrustError.changed(.init(host: "fixture.example.invalid", subjectSummary: "Synthetic", sha256Fingerprint: String(repeating: "a", count: 64), canBePinned: true))
            }
            if mode == "remote-read-error" || mode == "relay-read-error" && api == DsmAPIName.coreQuickConnect || mode == "remote-second-offline" && writes.count == 2 { throw URLError(.notConnectedToInternet) }
            if mode == "offline" && !writes.isEmpty { throw URLError(.notConnectedToInternet) }
            if api == DsmAPIName.coreNetworkEthernet && fields["method"] == "list" { return response(["interfaces": [["ifname": "eth0"]]]) }
            return response(payloads[api] ?? [:])
        }
        if mode == "denied" || mode == "second-denied" && writes.count == 2 || mode == "led-update-denied" && fields["method"] == "update" { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
        if api == DsmAPIName.coreNetworkEthernet, let data = fields["configs"], let values = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [[String: Any]], let value = values.first { payloads[api] = value }
        if api == DsmAPIName.coreSecurityDoS, let data = fields["configs"] { payloads[api]?["configs"] = try JSONSerialization.jsonObject(with: Data(data.utf8)) }
        if api == DsmAPIName.coreSecurityFirewall, fields["set_type"] == "disable" { payloads[api]?["enable_firewall"] = false }
        for (key, value) in fields where payloads[api]?[key] != nil {
            if mode != "partial" || key == "enable_ssh" {
                if value == "true" || value == "false" { payloads[api]?[key] = value == "true" }
                else if let port = Int(value) { payloads[api]?[key] = port }
                else if ["poweron_tasks", "poweroff_tasks", "configs"].contains(key) { payloads[api]?[key] = try JSONSerialization.jsonObject(with: Data(value.utf8)) }
                else { payloads[api]?[key] = value }
            }
        }
        if api == DsmAPIName.coreHardwareNeedReboot { payloads[api]?["need_reboot"] = true }
        if mode == "power-timezone-changed-after-save" && api == DsmAPIName.coreHardwarePowerSchedule { payloads[api]?["timezone"] = "Europe/London" }
        if mode == "revert-first" && writes.count == 2 { payloads[DsmAPIName.coreFileServiceSMB]?["enable_samba"] = false }
        if mode == "lost-ack" || mode == "offline" { throw URLError(.networkConnectionLost) }
        if mode == "led-update-lost-ack" && fields["method"] == "update" { throw URLError(.networkConnectionLost) }
        return response([:])
    }
    private func response(_ payload: [String: Any]) -> DsmHTTPResponse { .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": payload]), statusCode: 200) }
}

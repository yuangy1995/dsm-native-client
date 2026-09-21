import DsmCore
import DsmLocalization
import Foundation
import XCTest
@testable import DsmNetwork

final class DsmNasAdministrationRepositoryTests: XCTestCase {
    func test缓存过的硬盘启动前仍重新核对设备() async throws {
        let transport = MockHTTPTransport(responses: [response(syntheticStorageDisk), response(syntheticStorageDisk),
            response(syntheticDiskTestStatus(running: false)), response(#"{"success":true}"#),
            response(syntheticDiskTestStatus(running: true, type: "quick"))])
        let repository = try makeRepository(apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk], transport: transport)
        _ = try await repository.loadStorage()
        let status = try await repository.startDiskTest(diskID: "synthetic-disk", type: .quick)
        XCTAssertTrue(status.isRunning)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests.prefix(2).map { requestValue("method", in: $0) }, ["load_info", "load_info"])
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "do_smart_test" }.count, 1)
    }

    func test同ID换盘后旧操作零写入() async throws {
        let replacement = syntheticStorageDisk.replacingOccurrences(of: "synthetic-device", with: "replacement-device")
        let transport = MockHTTPTransport(responses: [response(syntheticStorageDisk), response(replacement)])
        let repository = try makeRepository(apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk], transport: transport)
        _ = try await repository.loadStorage()
        do { _ = try await repository.startDiskTest(diskID: "synthetic-disk", type: .quick); XCTFail("换盘后不能沿用旧操作") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains { requestValue("method", in: $0) == "do_smart_test" })
    }

    func test历史缓存不跨同ID设备复用() async throws {
        let replacement = syntheticStorageDisk.replacingOccurrences(of: "synthetic-device", with: "replacement-device")
        let idle = syntheticDiskTestStatus(running: false).replacingOccurrences(of: "synthetic-device", with: "replacement-device")
        let running = syntheticDiskTestStatus(running: true, type: "quick").replacingOccurrences(of: "synthetic-device", with: "replacement-device")
        let transport = MockHTTPTransport(responses: [response(syntheticStorageDisk), response(syntheticDiskTestStatus(running: false)),
            response(#"{"success":true,"data":{"testLog":[{"test_type":"quick","time":"old-device-time","result":"completed"}]}}"#),
            response(replacement), response(replacement), response(idle), response(#"{"success":true}"#), response(running)])
        let repository = try makeRepository(apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk], transport: transport)
        let previous = try await repository.loadDiskTestStatus(diskID: "synthetic-disk")
        XCTAssertEqual(previous.lastQuickTest, "old-device-time")
        _ = try await repository.loadStorage()
        let current = try await repository.startDiskTest(diskID: "synthetic-disk", type: .quick)
        XCTAssertNil(current.lastQuickTest); XCTAssertFalse(current.isHistoryAvailable)
    }

    func test存储刷新失败清除旧设备缓存() async throws {
        let transport = MockHTTPTransport(responses: [response(syntheticStorageDisk), response(#"{"success":true,"data":{}}"#)])
        let repository = try makeRepository(apiNames: [DsmAPIName.storageOverview], transport: transport)
        _ = try await repository.loadStorage()
        do { _ = try await repository.loadStorage(); XCTFail("畸形清单应失败") } catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        let cached = await repository.storageDisks; XCTAssertTrue(cached.isEmpty)
    }

    func test迟到存储清单不会覆盖新设备() async throws {
        let replacement = syntheticStorageDisk.replacingOccurrences(of: "synthetic-device", with: "replacement-device")
        let transport = DiskReadGateTransport(responses: [response(syntheticStorageDisk), response(replacement)], pausedCall: 1)
        let repository = try makeRepository(apiNames: [DsmAPIName.storageOverview], transport: transport)
        let old = Task { try await repository.loadStorage() }
        while !(await transport.isSuspended()) { await Task.yield() }
        _ = try await repository.loadStorage(); await transport.resume()
        do { _ = try await old.value; XCTFail("旧清单应失效") } catch is CancellationError { }
        let cached = await repository.storageDisks; XCTAssertEqual(cached["synthetic-disk"]?.deviceID, "replacement-device")
    }

    func test迟到历史不能挂到新设备() async throws {
        let replacement = syntheticStorageDisk.replacingOccurrences(of: "synthetic-device", with: "replacement-device")
        let transport = DiskReadGateTransport(responses: [response(syntheticStorageDisk), response(syntheticDiskTestStatus(running: false)),
            response(#"{"success":true,"data":{"testLog":[{"test_type":"quick","time":"old-time"}]}}"#), response(replacement)], pausedCall: 3)
        let repository = try makeRepository(apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk], transport: transport)
        let old = Task { try await repository.loadDiskTestStatus(diskID: "synthetic-disk") }
        while !(await transport.isSuspended()) { await Task.yield() }
        _ = try await repository.loadStorage(); await transport.resume()
        do { _ = try await old.value; XCTFail("旧历史应失效") } catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
    }

    func test同设备迟到历史不能覆盖较新读取() async throws {
        let transport = DiskReadGateTransport(responses: [response(syntheticStorageDisk), response(syntheticDiskTestStatus(running: false)),
            response(#"{"success":true,"data":{"testLog":[{"test_type":"quick","time":"old-time"}]}}"#),
            response(syntheticStorageDisk), response(syntheticDiskTestStatus(running: false)),
            response(#"{"success":true,"data":{"testLog":[{"test_type":"quick","time":"new-time"}]}}"#)], pausedCall: 3)
        let repository = try makeRepository(apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk], transport: transport)
        let old = Task { try await repository.loadDiskTestStatus(diskID: "synthetic-disk") }
        while !(await transport.isSuspended()) { await Task.yield() }
        let latest = try await repository.loadDiskTestStatus(diskID: "synthetic-disk")
        XCTAssertEqual(latest.lastQuickTest, "new-time"); await transport.resume()
        do { _ = try await old.value; XCTFail("旧历史应失效") } catch is CancellationError { }
    }

    func test硬盘缺失许可不会从健康状态推断可检测() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"disks":[{"id":"disk","device":"device","smart_status":"normal"}]}}"#)])
        let repository = try makeRepository(apiNames: [DsmAPIName.storageOverview], transport: transport)
        let storage = try await repository.loadStorage()
        XCTAssertFalse(try XCTUnwrap(storage.disks.first).supportsSmartTest)
    }

    func test硬盘缺失或重复设备身份拒绝伪造目标() async throws {
        for data in [#"{}"#, #"{"disks":[{"id":"disk"}]}"#,
                     #"{"disks":[{"id":"a","device":"same"},{"id":"b","device":"same"}]}"#] {
            let transport = MockHTTPTransport(responses: [response("{\"success\":true,\"data\":\(data)}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.storageOverview], transport: transport)
            do { _ = try await repository.loadStorage(); XCTFail("畸形硬盘目标不应成功") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test硬盘缺失冲突或异盘状态不当作空闲() async throws {
        for data in [#"{}"#, #"{"testInfo":[]}"#, #"{"testInfo":[{}]}"#,
                     #"{"testInfo":[{"testing":false,"is_testing":true}]}"#,
                     #"{"testInfo":[{"testing":true,"test_type":"unknown"}]}"#,
                     #"{"testInfo":[{"device":"other","testing":false}]}"#,
                     #"{"testInfo":[{"testing":false}]}"#] {
            let transport = MockHTTPTransport(responses: [response(syntheticStorageDisk), response("{\"success\":true,\"data\":\(data)}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk], transport: transport)
            do { _ = try await repository.loadDiskTestStatus(diskID: "synthetic-disk"); XCTFail("畸形状态不应成为未运行") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
        }
    }

    func test硬盘畸形历史保留不可用状态() async throws {
        let transport = MockHTTPTransport(responses: [response(syntheticStorageDisk), response(syntheticDiskTestStatus(running: false)), response(#"{"success":true,"data":{}}"#)])
        let repository = try makeRepository(apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk], transport: transport)
        let state = try await repository.loadDiskTestStatus(diskID: "synthetic-disk")
        XCTAssertFalse(state.isHistoryAvailable)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.allSatisfy { requestValue("version", in: $0) == "1" })
    }

    func test读取系统总览并把会话凭据留在请求正文() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"model":"DS923+","firmware_ver":"DSM 7.2","up_time":"3600","cpu_series":"AMD Ryzen","cpu_cores":"4","cpu_clock_speed":2200,"ram_size":4096,"sys_temp":42}}"#)
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreSystem], transport: transport)

        let overview = try await repository.loadSystemOverview()

        XCTAssertEqual(overview.serverName, "测试设备")
        XCTAssertEqual(overview.model, "DS923+")
        XCTAssertEqual(overview.cpuCoreCount, 4)
        XCTAssertEqual(overview.memoryBytes, 4_294_967_296)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests.contains { $0.url?.absoluteString.contains("REDACTED_SESSION") == true })
    }

    func test按实际嵌套结构读取性能数据() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"time":100,"cpu":{"user_load":12,"system_load":5,"other_load":3},"memory":{"real_usage":46,"swap_usage":2},"network":[{"device":"eth0","rx":1,"tx":2},{"device":"total","rx":1024,"tx":2048}],"disk":{"total":{"read_byte":4096,"write_byte":8192,"utilization":15}},"space":{"total":{"read_byte":3000,"write_byte":4000}},"nfs":[{"read_OPS":4,"write_OPS":5}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreSystemUtilization],
            transport: transport
        )

        let snapshot = try await repository.loadPerformanceSnapshot()

        XCTAssertEqual(snapshot.cpuUsage, 20)
        XCTAssertEqual(snapshot.memoryUsage, 46)
        XCTAssertEqual(snapshot.networkReceivedBytesPerSecond, 1_024)
        XCTAssertEqual(snapshot.diskWriteBytesPerSecond, 8_192)
        XCTAssertEqual(snapshot.nfsReadOperationsPerSecond, 4)
    }

    func test读取真实存储池空间和硬盘结构() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"overview_data":{"status_level":"normal"},"disks":[{"id":"disk1","device":"sata1","longName":"硬盘 1","vendor":"VENDOR","model":"MODEL","size_total":1000,"summary_status_key":"normal","smart_status":"normal","smart_test_support":true,"temp":35,"serial":"SERIAL-REDACTED","firm":"FW1","container":{"str":"测试机箱"},"is4Kn":true,"remain_life":98,"unc":0}],"storagePools":[{"id":"pool1","desc":"存储池 1","raidType":"raid_1","summary_status":"normal","size":{"used":400,"total":1000},"is_writable":true,"disks":["disk1"],"spares":[]}],"volumes":[{"id":"volume1","vol_desc":"存储空间 1","fs_type":"btrfs","summary_status":"normal","size":{"used":300,"total":800},"is_writable":true,"pool_path":"pool1","vol_path":"/volume1"}]}}"#)
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.storageOverview], transport: transport)

        let storage = try await repository.loadStorage()

        XCTAssertEqual(storage.disks.first?.smartStatus, "normal")
        XCTAssertEqual(storage.disks.first?.deviceID, "sata1")
        XCTAssertEqual(storage.disks.first?.supportsSmartTest, true)
        XCTAssertEqual(storage.disks.first?.serialNumber, "SERIAL-REDACTED")
        XCTAssertEqual(storage.disks.first?.estimatedLifePercent, 98)
        XCTAssertEqual(storage.pools.first?.usedBytes, 400)
        XCTAssertEqual(storage.pools.first?.diskIDs, ["disk1"])
        XCTAssertEqual(storage.volumes.first?.fileSystem, "btrfs")
        XCTAssertEqual(storage.volumes.first?.poolID, "pool1")
    }

    func test读取硬盘当前检测状态和真实历史记录() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"disks":[{"id":"disk1","device":"sata1","longName":"硬盘 1","smart_status":"normal","smart_test_support":true}],"storagePools":[],"volumes":[]}}"#),
            response(#"{"success":true,"data":{"latest_test_time":"2026-07-25T10:20:30+08:00","testInfo":[{"device":"sata1","testing":false,"ihm_testing":false,"perf_testing":false,"quickTime":"2","extendTime":"500","latest_test_result":"completed"}]}}"#),
            response(#"{"success":true,"data":{"total":3,"testLog":[{"type":"smart","test_type":"extend","result":"completed","time":"2026-07-25T10:20:30+08:00"},{"type":"smart","test_type":"quick","result":"completed","time":"2026-07-24T09:10:20+08:00"},{"type":"ihm","result":"ihm_000","time":"2026-07-23T08:00:00+08:00"}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk],
            transport: transport
        )

        let status = try await repository.loadDiskTestStatus(diskID: "disk1")

        XCTAssertFalse(status.isRunning)
        XCTAssertFalse(status.isBusyWithOtherTest)
        XCTAssertTrue(status.isHistoryAvailable)
        XCTAssertEqual(status.lastQuickTest, "2026-07-24T09:10:20+08:00")
        XCTAssertEqual(status.lastExtendedTest, "2026-07-25T10:20:30+08:00")
        XCTAssertEqual(status.lastResult, "completed")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("device", in: requests[1]), "sata1")
        XCTAssertEqual(requestValue("method", in: requests[2]), "disk_test_log_get")
        XCTAssertEqual(requestValue("type", in: requests[2]), "smart")
    }

    func test硬盘检测先检查状态再启动并复查运行状态() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"disks":[{"id":"disk1","device":"sata1","longName":"硬盘 1","model":"MODEL","size_total":1000,"summary_status_key":"normal","smart_status":"normal","smart_test_support":true}],"storagePools":[],"volumes":[]}}"#),
            response(#"{"success":true,"data":{"latest_test_time":"2026-01-01 10:00:00","testInfo":[{"device":"sata1","testing":false,"ihm_testing":false,"perf_testing":false,"latest_test_result":"completed"}]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"testInfo":[{"device":"sata1","testing":true,"test_type":"quick","remain":"约 2 分钟"}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk],
            transport: transport
        )

        let status = try await repository.startDiskTest(diskID: "disk1", type: .quick)

        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(status.runningType, .quick)
        XCTAssertEqual(status.progressDescription, "约 2 分钟")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requestValue("method", in: requests[1]), "get_smart_test_log")
        XCTAssertEqual(requestValue("device", in: requests[1]), "sata1")
        XCTAssertEqual(requestValue("method", in: requests[2]), "do_smart_test")
        XCTAssertEqual(requestValue("device", in: requests[2]), "sata1")
        XCTAssertEqual(requestValue("type", in: requests[2]), "quick")
        XCTAssertEqual(requestValue("method", in: requests[3]), "get_smart_test_log")
    }

    func test其他硬盘检测占用时不提交SMART写操作() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"disks":[{"id":"disk1","device":"sata1","longName":"硬盘 1","smart_status":"normal","smart_test_support":true}],"storagePools":[],"volumes":[]}}"#),
            response(#"{"success":true,"data":{"testInfo":[{"device":"sata1","testing":false,"ihm_testing":true,"perf_testing":false}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk],
            transport: transport
        )

        do {
            _ = try await repository.startDiskTest(diskID: "disk1", type: .quick)
            XCTFail("其他检测占用时不应启动 S.M.A.R.T. 检测")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .conflict)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("shared.b8c5b11d9fc2c1f5")
            )
        }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains { requestValue("method", in: $0) == "do_smart_test" })
    }

    func test停止硬盘检测先确认正在运行并复查停止状态() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"disks":[{"id":"disk1","device":"sata1","longName":"硬盘 1","smart_status":"normal","smart_test_support":true}],"storagePools":[],"volumes":[]}}"#),
            response(#"{"success":true,"data":{"testInfo":[{"testing":true,"test_type":"extend","remain":"约 1 小时"}]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"testInfo":[{"testing":false,"ihm_testing":false,"perf_testing":false,"test_type":"extend","result":"stopped"}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk],
            transport: transport
        )

        let status = try await repository.stopDiskTest(diskID: "disk1")

        XCTAssertFalse(status.isRunning)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[1]), "get_smart_test_log")
        XCTAssertEqual(requestValue("method", in: requests[2]), "do_smart_test")
        XCTAssertEqual(requestValue("device", in: requests[2]), "sata1")
        XCTAssertEqual(requestValue("type", in: requests[2]), "stop")
        XCTAssertEqual(requestValue("method", in: requests[3]), "get_smart_test_log")
    }

    func test硬盘检测启动统一结果回读确认运行状态() async throws {
        let transport = MockHTTPTransport(responses: [
            response(syntheticStorageDisk),
            response(syntheticDiskTestStatus(running: false)),
            response(#"{"success":true}"#),
            response(syntheticDiskTestStatus(running: true, type: "quick"))
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk],
            transport: transport
        )

        let result = try await repository.startDiskTestResult(
            diskID: "synthetic-disk",
            type: .quick
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.counts, try MutationResultCounts(
            succeeded: 1,
            failed: 0,
            unknown: 0
        ))
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[2]), "do_smart_test")
        XCTAssertEqual(requestValue("type", in: requests[2]), "quick")
    }

    func test硬盘检测停止统一结果回读确认停止状态() async throws {
        let transport = MockHTTPTransport(responses: [
            response(syntheticStorageDisk),
            response(syntheticDiskTestStatus(running: true, type: "extend")),
            response(#"{"success":true}"#),
            response(syntheticDiskTestStatus(running: false))
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk],
            transport: transport
        )

        let result = try await repository.stopDiskTestResult(
            diskID: "synthetic-disk"
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[2]), "do_smart_test")
        XCTAssertEqual(requestValue("type", in: requests[2]), "stop")
    }

    func test硬盘检测提交断网且状态未变化时不自动重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(syntheticStorageDisk)),
            .response(response(syntheticDiskTestStatus(running: false))),
            .urlError(.networkConnectionLost),
            .response(response(syntheticDiskTestStatus(running: false)))
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk],
            transport: transport
        )

        let result = try await repository.startDiskTestResult(
            diskID: "synthetic-disk",
            type: .extended
        )

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.requiresRefresh)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "do_smart_test" }.count,
            1
        )
    }

    func test硬盘检测提交超时但回读目标状态时确认成功() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(syntheticStorageDisk)),
            .response(response(syntheticDiskTestStatus(running: false))),
            .urlError(.timedOut),
            .response(response(syntheticDiskTestStatus(running: true, type: "quick")))
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk],
            transport: transport
        )

        let result = try await repository.startDiskTestResult(
            diskID: "synthetic-disk",
            type: .quick
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.diagnosticTag, "storage.disk-test.start.confirmed-after-submit-error")
    }

    func test硬盘检测拒绝同硬盘重复提交并区分提交后取消() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(syntheticStorageDisk)),
            .response(response(syntheticDiskTestStatus(running: false))),
            .waitUntilCancelled
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.storageOverview, DsmAPIName.coreStorageDisk],
            transport: transport
        )
        let firstTask = Task {
            try await repository.startDiskTestResult(
                diskID: "synthetic-disk",
                type: .quick
            )
        }
        while await transport.recordedRequests().count < 3 {
            await Task.yield()
        }

        let duplicate = try await repository.stopDiskTestResult(
            diskID: "synthetic-disk"
        )
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.requiresRefresh)
    }

    func test系统进程只保留白名单字段并限制单次读取数量() async throws {
        let transport = MockHTTPTransport(responses: [
            response(
                #"{"success":true,"data":{"processes":[{"pid":42,"name":"/volume1/private/bin/worker","status":"running","service":"backup","cmdline":"worker --token synthetic-secret","user":"administrator","path":"/volume1/private","remote":"192.0.2.8"},{"pid":42,"name":"duplicate"},{"pid":"invalid/path","name":"ignored"}],"total":800}}"#
            ),
            response(
                #"{"success":true,"data":{"groups":[{"id":"backup","display_name":"Backup Service","status":"running","process_count":2,"account":"administrator","path":"/volume1/private"}]}}"#
            )
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreSystemProcess,
                DsmAPIName.coreSystemProcessGroup
            ],
            transport: transport
        )

        let directory = try await repository.loadSystemProcesses(
            start: -20,
            limit: 5_000
        )

        XCTAssertEqual(directory.processes.count, 1)
        XCTAssertEqual(directory.processes.first?.processID, "42")
        XCTAssertEqual(directory.processes.first?.name, "worker")
        XCTAssertEqual(directory.processes.first?.groupID, "backup")
        XCTAssertEqual(directory.groups.map(\.name), ["Backup Service"])
        XCTAssertEqual(directory.groups.first?.processCount, 2)
        XCTAssertEqual(directory.total, 800)
        XCTAssertTrue(directory.isTruncated)
        XCTAssertFalse(directory.groupsAreUnavailable)
        let description = String(describing: directory)
        XCTAssertFalse(description.contains("/volume1"))
        XCTAssertFalse(description.contains("administrator"))
        XCTAssertFalse(description.contains("synthetic-secret"))
        XCTAssertFalse(description.contains("192.0.2.8"))

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requestValue("api", in: requests[0]), DsmAPIName.coreSystemProcess)
        XCTAssertEqual(requestValue("method", in: requests[0]), "list")
        XCTAssertEqual(requestValue("start", in: requests[0]), "0")
        XCTAssertEqual(requestValue("limit", in: requests[0]), "500")
        XCTAssertEqual(requestValue("api", in: requests[1]), DsmAPIName.coreSystemProcessGroup)
        XCTAssertEqual(requestValue("method", in: requests[1]), "list")
    }

    func test服务进程组读取失败时保留进程列表() async throws {
        let transport = MockHTTPTransport(responses: [
            response(
                #"{"success":true,"data":{"items":[{"process_id":"7","process_name":"service-worker","status":"sleeping"}],"total_count":1}}"#
            ),
            response(#"{"success":false,"error":{"code":105}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreSystemProcess,
                DsmAPIName.coreSystemProcessGroup
            ],
            transport: transport
        )

        let directory = try await repository.loadSystemProcesses(
            start: 0,
            limit: 100
        )

        XCTAssertEqual(directory.processes.map(\.name), ["service-worker"])
        XCTAssertTrue(directory.groups.isEmpty)
        XCTAssertTrue(directory.groupsAreUnavailable)
        XCTAssertFalse(directory.isTruncated)
    }

    func test缺少系统进程能力时不发送猜测请求() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreSystemProcessGroup],
            transport: transport
        )

        do {
            _ = try await repository.loadSystemProcesses(start: 0, limit: 100)
            XCTFail("缺少运行时能力时不应尝试进程接口")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .apiUnavailable)
        }

        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test套件列表读取附加状态和说明() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"packages":[{"id":"HyperBackup","name":"Hyper Backup","version":"4.1","timestamp":100,"additional":{"status":"running","status_description":"运行中","description":"备份服务","install_type":"system"}}]}}"#)
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.corePackage], transport: transport)

        let packages = try await repository.loadPackages()

        XCTAssertEqual(packages.map(\.name), ["Hyper Backup"])
        XCTAssertEqual(packages.first?.status, "running")
        XCTAssertEqual(packages.first?.packageDescription, "备份服务")
        XCTAssertFalse(packages.first?.isUpgradeAvailable ?? true)
        XCTAssertFalse(packages.first?.canUpgrade ?? true)
    }

    func test套件缺少权限或未知状态不推断允许操作() async throws {
        for additional in [
            #"{"status":"running"}"#,
            #"{"status":"stopped","startable":true}"#,
            #"{"status":"unknown","status_origin":"inactive","startable":true,"available_operation":["start","stop","uninstall"]}"#,
            #"{"status":"stopped","install_type":"user","ctl_uninstall":false,"available_operation":["uninstall"]}"#
        ] {
            let transport = MockHTTPTransport(responses: [response(
                "{\"success\":true,\"data\":{\"packages\":[{\"id\":\"Example\",\"additional\":\(additional)}]}}"
            )])
            let repository = try makeRepository(apiNames: [DsmAPIName.corePackage], transport: transport)
            let packages = try await repository.loadPackages()
            let package = try XCTUnwrap(packages.first)
            XCTAssertFalse(package.canStart)
            XCTAssertFalse(package.canStop)
            XCTAssertFalse(package.canUninstall)
        }
    }

    func test套件畸形目录不当作空列表或猜测身份() async throws {
        for data in [#"{}"#, #"{"packages":[null]}"#,
                     #"{"packages":[{"name":"not-an-id"}]}"#,
                     #"{"packages":[{"id":"Example"},{"id":"Example"}]}"#] {
            let transport = MockHTTPTransport(responses: [response("{\"success\":true,\"data\":\(data)}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.corePackage], transport: transport)
            do {
                _ = try await repository.loadPackages()
                XCTFail("畸形目录不能参与卸载回读确认")
            } catch let error as AppError {
                XCTAssertEqual(error.category, .invalidResponse)
            }
        }
    }

    func test套件列表将明确升级操作解释为只读提示() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"packages":[{"id":"Example","name":"示例套件","version":"1.0","additional":{"status":"running","install_type":"user","available_operation":["stop","upgrade"]}}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.corePackage],
            transport: transport
        )

        let packages = try await repository.loadPackages()

        let package = try XCTUnwrap(packages.first)
        XCTAssertTrue(package.isUpgradeAvailable)
        XCTAssertFalse(package.canUpgrade)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requestValue("method", in: requests[0]), "list")
    }

    func test套件图标通过认证请求头读取且凭据不进入地址() async throws {
        let icon = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"packages":[{"id":"Example","name":"示例套件","version":"1.0","additional":{"status":"stopped","startable":true,"install_type":"user","ctl_uninstall":true,"available_operation":["start","uninstall","upgrade"]}}]}}"#),
            DsmHTTPResponse(
                data: icon,
                statusCode: 200,
                headers: ["Content-Type": "image/png"]
            )
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.corePackage, DsmAPIName.corePackageThumb],
            transport: transport
        )

        let packages = try await repository.loadPackages()

        XCTAssertEqual(packages.first?.iconData, icon)
        XCTAssertEqual(packages.first?.canStart, true)
        XCTAssertEqual(packages.first?.canStop, false)
        XCTAssertEqual(packages.first?.canUninstall, true)
        XCTAssertEqual(packages.first?.isUpgradeAvailable, true)
        XCTAssertEqual(packages.first?.canUpgrade, false)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requestValue("api", in: requests[1]), DsmAPIName.corePackageThumb)
        XCTAssertEqual(requestValue("method", in: requests[1]), "get")
        XCTAssertEqual(requestValue("name", in: requests[1]), "Example")
        XCTAssertNotNil(requests[1].value(forHTTPHeaderField: "Cookie"))
        XCTAssertNotNil(requests[1].value(forHTTPHeaderField: "X-SYNO-TOKEN"))
        XCTAssertFalse(requests[1].url?.absoluteString.contains("REDACTED_SESSION") == true)
    }

    func test暂停套件先检查可行性再调用专用控制接口() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"packages":[{"id":"Example","name":"示例套件","version":"1.0","additional":{"status":"running","startable":true,"dsm_apps":"App.One App.Two","install_type":"user","available_operation":["stop","uninstall"]}}]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"packages":[{"id":"Example","name":"示例套件","version":"1.0","additional":{"status":"stopped","startable":true,"dsm_apps":"App.One App.Two","install_type":"user","available_operation":["start","uninstall"]}}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageControl
            ],
            transport: transport
        )
        try await repository.controlPackage(id: "Example", action: .stop)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requestValue("api", in: requests[1]), DsmAPIName.corePackage)
        XCTAssertEqual(requestValue("method", in: requests[1]), "feasibility_check")
        XCTAssertEqual(requestValue("type", in: requests[1]), "stop_check")
        XCTAssertEqual(requestValue("api", in: requests[2]), DsmAPIName.corePackageControl)
        XCTAssertEqual(requestValue("method", in: requests[2]), "stop")
        XCTAssertEqual(requestValue("id", in: requests[2]), "Example")
    }

    func test启动套件写后回读确认并传递桌面应用标识() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"packages":[{"id":"Example","name":"示例套件","version":"1.0","additional":{"status":"stopped","startable":true,"dsm_apps":"App.One App.Two","install_type":"user","available_operation":["start"]}}]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"packages":[{"id":"Example","name":"示例套件","version":"1.0","additional":{"status":"running","startable":true,"dsm_apps":"App.One App.Two","install_type":"user","available_operation":["stop"]}}]}}"#),
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageControl,
                DsmAPIName.corePackageThumb,
            ],
            transport: transport
        )

        let result = try await repository.controlPackageResult(
            id: "Example",
            action: .start
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.operation, "packageStart")
        XCTAssertFalse(result.requiresRefresh)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.compactMap { requestValue("method", in: $0) },
            ["list", "feasibility_check", "start", "list"]
        )
        XCTAssertEqual(
            requestValue("dsm_apps", in: requests[2]),
            #"["App.One","App.Two"]"#
        )
    }

    func test套件启动停止预检拒绝过期状态和缺失能力且不写入() async throws {
        let staleTransport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"packages":[{"id":"Example","name":"示例套件","version":"1.0","additional":{"status":"running","startable":true,"available_operation":["stop"]}}]}}"#),
        ])
        let staleRepository = try makeRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageControl,
            ],
            transport: staleTransport
        )

        let stale = try await staleRepository.controlPackageResult(
            id: "Example",
            action: .start
        )

        XCTAssertEqual(stale.status, .confirmedFailure)
        XCTAssertFalse(stale.submitted)
        XCTAssertEqual(stale.localizationKey, "package.start.unavailable")
        let staleRequests = await staleTransport.recordedRequests()
        XCTAssertEqual(
            staleRequests.compactMap { requestValue("method", in: $0) },
            ["list"]
        )

        let unsupportedTransport = MockHTTPTransport(responses: [])
        let unsupportedRepository = try makeRepository(
            apiNames: [DsmAPIName.corePackage],
            transport: unsupportedTransport
        )
        let unsupported = try await unsupportedRepository.controlPackageResult(
            id: "Example",
            action: .stop
        )

        XCTAssertEqual(unsupported.status, .unsupported)
        XCTAssertFalse(unsupported.submitted)
        let unsupportedRequests = await unsupportedTransport.recordedRequests()
        XCTAssertTrue(unsupportedRequests.isEmpty)

        let cancelledTransport = MockHTTPTransport(responses: [])
        let cancelledRepository = try makeRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageControl,
            ],
            transport: cancelledTransport
        )
        let cancelled = try await Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try await cancelledRepository.controlPackageResult(
                id: "Example",
                action: .start
            )
        }.value

        XCTAssertEqual(cancelled.status, .cancelledBeforeSubmission)
        XCTAssertFalse(cancelled.submitted)
        let cancelledRequests = await cancelledTransport.recordedRequests()
        XCTAssertTrue(cancelledRequests.isEmpty)
    }

    func test套件控制提交超时后只回读且不会重放写请求() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"packages":[{"id":"Example","name":"示例套件","version":"1.0","additional":{"status":"stopped","startable":true,"available_operation":["start"]}}]}}"#)),
            .response(response(#"{"success":true}"#)),
            .urlError(.timedOut),
            .response(response(#"{"success":true,"data":{"packages":[{"id":"Example","name":"示例套件","version":"1.0","additional":{"status":"running","startable":true,"available_operation":["stop"]}}]}}"#)),
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageControl,
            ],
            transport: transport
        )

        let result = try await repository.controlPackageResult(
            id: "Example",
            action: .start
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(
            result.diagnosticTag,
            "package.start.confirmed"
        )
        let methods = await transport.recordedRequests().compactMap {
            requestValue("method", in: $0)
        }
        XCTAssertEqual(methods, ["list", "feasibility_check", "start", "list"])
        XCTAssertEqual(methods.filter { $0 == "start" }.count, 1)
    }

    func test套件控制明确权限拒绝不进入未知结果() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"packages":[{"id":"Example","name":"示例套件","version":"1.0","additional":{"status":"running","startable":true,"available_operation":["stop"]}}]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":false,"error":{"code":105}}"#),
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageControl,
            ],
            transport: transport
        )

        let result = try await repository.controlPackageResult(
            id: "Example",
            action: .stop
        )

        XCTAssertEqual(result.status, .permissionDenied)
        XCTAssertTrue(result.submitted)
        XCTAssertFalse(result.requiresRefresh)
        XCTAssertEqual(result.counts.failed, 1)
        let methods = await transport.recordedRequests().compactMap {
            requestValue("method", in: $0)
        }
        XCTAssertEqual(methods, ["list", "feasibility_check", "stop"])
    }

    func test套件控制按稳定ID去重并区分提交后取消() async throws {
        let running = #"{"success":true,"data":{"packages":[{"id":"Example","name":"示例套件","version":"1.0","additional":{"status":"running","startable":true,"available_operation":["stop"]}}]}}"#
        let transport = MockHTTPTransport(steps: [
            .response(response(running)),
            .response(response(#"{"success":true}"#)),
            .waitUntilCancelled,
            .response(response(running)),
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageControl,
            ],
            transport: transport
        )
        let firstTask = Task {
            try await repository.controlPackageResult(
                id: "Example",
                action: .stop
            )
        }
        while await transport.recordedRequests().count < 3 {
            await Task.yield()
        }

        let duplicate = try await repository.controlPackageResult(
            id: "Example",
            action: .start
        )
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.requiresRefresh)
        let methods = await transport.recordedRequests().compactMap {
            requestValue("method", in: $0)
        }
        XCTAssertEqual(methods.filter { $0 == "stop" }.count, 1)
        XCTAssertEqual(methods.filter { $0 == "start" }.count, 0)
    }

    func test卸载套件使用专用接口并传递桌面应用标识() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"packages":[{"id":"Example","name":"示例套件","version":"1.0","additional":{"status":"stopped","startable":true,"dsm_apps":"App.One App.Two","install_type":"user","ctl_uninstall":true,"available_operation":["uninstall"]}}]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"packages":[]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageUninstallation
            ],
            transport: transport
        )
        _ = try await repository.loadPackages()

        try await repository.controlPackage(id: "Example", action: .uninstall)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("type", in: requests[1]), "uninstall_check")
        XCTAssertEqual(
            requestValue("api", in: requests[2]),
            DsmAPIName.corePackageUninstallation
        )
        XCTAssertEqual(requestValue("method", in: requests[2]), "uninstall")
        XCTAssertEqual(
            requestValue("dsm_apps", in: requests[2]),
            #"["App.One","App.Two"]"#
        )
    }

    func test套件卸载回读确认目标消失时返回确认成功() async throws {
        let transport = MockHTTPTransport(responses: [
            response(packageListResponse),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"packages":[]}}"#),
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageUninstallation,
            ],
            transport: transport
        )
        _ = try await repository.loadPackages()

        let result = try await repository.uninstallPackageResult(id: "Example")

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.counts.succeeded, 1)
        XCTAssertFalse(result.requiresRefresh)
        let methods = await transport.recordedRequests().compactMap {
            requestValue("method", in: $0)
        }
        XCTAssertEqual(methods, ["list", "feasibility_check", "uninstall", "list"])
    }

    func test套件卸载提交时断网保留未确认语义() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(packageListResponse)),
            .response(response(#"{"success":true}"#)),
            .urlError(.networkConnectionLost),
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageUninstallation,
            ],
            transport: transport
        )
        _ = try await repository.loadPackages()

        let result = try await repository.uninstallPackageResult(id: "Example")

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.submitted)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.counts.unknown, 1)
        XCTAssertEqual(result.errorCategory, .network)
    }

    func test套件卸载回读失败时要求刷新且不自动重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(packageListResponse)),
            .response(response(#"{"success":true}"#)),
            .response(response(#"{"success":true}"#)),
            .urlError(.timedOut),
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageUninstallation,
            ],
            transport: transport
        )
        _ = try await repository.loadPackages()

        let result = try await repository.uninstallPackageResult(id: "Example")

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.counts.unknown, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "uninstall" }.count,
            1
        )
    }

    func test套件卸载被明确拒绝时返回权限不足() async throws {
        let transport = MockHTTPTransport(responses: [
            response(packageListResponse),
            response(#"{"success":true}"#),
            response(#"{"success":false,"error":{"code":105}}"#),
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageUninstallation,
            ],
            transport: transport
        )
        _ = try await repository.loadPackages()

        let result = try await repository.uninstallPackageResult(id: "Example")

        XCTAssertEqual(result.status, .permissionDenied)
        XCTAssertTrue(result.submitted)
        XCTAssertEqual(result.counts.failed, 1)
        XCTAssertEqual(result.errorCategory, .permission)
    }

    func test套件卸载提交前取消时不发送请求() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageUninstallation,
            ],
            transport: transport
        )

        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            return try await repository.uninstallPackageResult(id: "Example")
        }
        let result = try await task.value

        XCTAssertEqual(result.status, .cancelledBeforeSubmission)
        XCTAssertFalse(result.submitted)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test套件卸载拒绝同一目标重复提交并区分提交后取消() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(packageListResponse)),
            .response(response(#"{"success":true}"#)),
            .waitUntilCancelled,
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageUninstallation,
            ],
            transport: transport
        )
        _ = try await repository.loadPackages()
        let firstTask = Task {
            try await repository.uninstallPackageResult(id: "Example")
        }
        while await transport.recordedRequests().count < 3 {
            await Task.yield()
        }

        let duplicate = try await repository.uninstallPackageResult(id: "Example")
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.requiresRefresh)
    }

    func test计划任务列表固定使用已验证的第三版而详情保存使用第四版() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"tasks":[{"id":12,"name":"示例任务","owner":"operator","real_owner":"operator","type":"script","enable":true,"can_run":true,"can_edit":true}]}}"#),
            response(#"{"success":true,"data":{"id":12,"name":"示例任务","owner":"operator","real_owner":"operator","enable":true,"schedule":{"date_type":0,"week_day":"1,2,3,4,5","repeat_date":1002,"hour":3,"minute":15,"repeat_hour":0,"repeat_min":0,"last_work_hour":3},"extra":{"script":"echo ok","notify_if_error":true,"notify_mail":"ops@example.invalid"}}}"#),
            response(#"{"success":true}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreTaskScheduler],
            transport: transport
        )

        let tasks = try await repository.loadScheduledTasks()
        var draft = try await repository.loadScheduledTaskDraft(
            id: 12,
            realOwner: "operator"
        )
        draft.name = "修改后的任务"
        try await repository.saveScheduledTask(draft)

        XCTAssertEqual(tasks.first?.canRun, true)
        XCTAssertEqual(draft.script, "echo ok")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("version", in: requests[0]), "3")
        XCTAssertEqual(requestValue("method", in: requests[1]), "get")
        XCTAssertEqual(requestValue("version", in: requests[1]), "4")
        XCTAssertEqual(requestValue("method", in: requests[2]), "set")
        XCTAssertEqual(requestValue("version", in: requests[2]), "4")
        XCTAssertEqual(requestValue("schedule", in: requests[2])?.contains(#""hour":3"#), true)
        XCTAssertEqual(requestValue("extra", in: requests[2])?.contains(#""script":"echo ok""#), true)
    }

    func test计划任务缺少数字身份或目录结构时失败() async throws {
        for data in [#"{}"#, #"{"tasks":[null]}"#, #"{"tasks":[{"name":"synthetic"}]}"#,
                     #"{"tasks":[{"id":12,"name":"synthetic"},{"id":12,"name":"other"}]}"#] {
            let transport = MockHTTPTransport(responses: [response("{\"success\":true,\"data\":\(data)}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.coreTaskScheduler], transport: transport)
            do { _ = try await repository.loadScheduledTasks(); XCTFail("不能伪造任务身份或空目录") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test计划详情缺少时间或小数时间时不补零点() async throws {
        let valid = #"{"id":12,"name":"synthetic","owner":"synthetic-owner","enable":true,"schedule":{"date_type":0,"week_day":"1","repeat_date":1002,"hour":3,"minute":15,"repeat_hour":0,"repeat_min":0,"last_work_hour":3},"extra":{"script":"synthetic-script","notify_if_error":false,"notify_mail":""}}"#
        for body in [valid.replacingOccurrences(of: #""hour":3,"#, with: ""), valid.replacingOccurrences(of: #""hour":3"#, with: #""hour":3.5"#)] {
            let transport = MockHTTPTransport(responses: [response("{\"success\":true,\"data\":\(body)}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.coreTaskScheduler], transport: transport)
            do { _ = try await repository.loadScheduledTaskDraft(id: 12, realOwner: nil); XCTFail("缺失或小数时间不能转为有效计划") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test计划执行记录不能串任务或伪造空结果() async throws {
        for body in [#"{}"#, #"[{"result_id":"r1","task_name":"other"}]"#,
                     #"[{"result_id":"r1"},{"result_id":"r1"}]"#,
                     #"[{"result_id":"r1","exit_info":{"exit_code":0},"exit_code":1}]"#] {
            let transport = MockHTTPTransport(responses: [response("{\"success\":true,\"data\":\(body)}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.coreEventScheduler], transport: transport)
            do { _ = try await repository.loadScheduledTaskResults(taskName: "synthetic"); XCTFail("畸形运行记录不能成功") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test计划任务运行记录和输出使用事件调度接口() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":[{"task_name":"示例任务","result_id":"result-1","start_time":"2026-07-25 10:00:00","exit_info":{"exit_type":"error","exit_code":1}},{"task_name":"示例任务","result_id":"result-2","start_time":"2026-07-26 10:00:00","stop_time":"2026-07-26 10:00:03","exit_info":{"exit_type":"normal","exit_code":0},"trigger_event":"manual"}]}"#),
            response(#"{"success":true,"data":{"script_in":"echo ok","script_out":"ok\n"}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreEventScheduler],
            transport: transport
        )

        let results = try await repository.loadScheduledTaskResults(taskName: "示例任务")
        let output = try await repository.loadScheduledTaskResultOutput(
            taskName: "示例任务",
            resultID: "result-2"
        )

        XCTAssertEqual(results.map(\.id), ["result-2", "result-1"])
        XCTAssertEqual(results.first?.exitCode, 0)
        XCTAssertEqual(output.command, "echo ok")
        XCTAssertEqual(output.output, "ok\n")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[0]), "result_list")
        XCTAssertEqual(requestValue("task_name", in: requests[0]), "示例任务")
        XCTAssertEqual(requestValue("method", in: requests[1]), "result_get_file")
        XCTAssertEqual(requestValue("result_id", in: requests[1]), "result-2")
    }

    func test系统更新检查使用实际更新服务并规范化可用版本() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"firmware_ver":"DSM 7.2.1"}}"#),
            response(#"{"success":true,"data":{"update":{"version":"  DSM 7.2.2  ","release_note":"  可靠性改进\n"},"promotion":null}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreSystem, DsmAPIName.coreUpgradeServer],
            transport: transport
        )

        let info = try await repository.checkSystemUpdate()

        XCTAssertTrue(info.isUpdateAvailable)
        XCTAssertEqual(info.currentVersion, "DSM 7.2.1")
        XCTAssertEqual(info.latestVersion, "DSM 7.2.2")
        XCTAssertEqual(info.releaseNotes, "可靠性改进")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("api", in: requests[1]), DsmAPIName.coreUpgradeServer)
        XCTAssertEqual(requestValue("method", in: requests[1]), "check")
        XCTAssertEqual(requestValue("version", in: requests[1]), "3")
        XCTAssertEqual(requestValue("need_promotion", in: requests[1]), "false")
    }

    func test系统更新没有候选或版本相同时不伪造可用更新() async throws {
        for updateBody in [
            "null",
            #"{"version":"DSM 7.2.1","release_note":"相同版本"}"#
        ] {
            let transport = MockHTTPTransport(responses: [
                response(#"{"success":true,"data":{"firmware_ver":"DSM 7.2.1"}}"#),
                response(
                    #"{"success":true,"data":{"update":\#(updateBody),"promotion":null}}"#
                )
            ])
            let repository = try makeRepository(
                apiNames: [DsmAPIName.coreSystem, DsmAPIName.coreUpgradeServer],
                transport: transport
            )

            let info = try await repository.checkSystemUpdate()

            XCTAssertFalse(info.isUpdateAvailable)
            XCTAssertEqual(info.currentVersion, "DSM 7.2.1")
        }
    }

    func testNAS关机与重启先预检并只确认DSM接受请求() async throws {
        for (action, method, operation, localizationKey) in [
            (NasPowerAction.shutdown, "shutdown", "nasShutdown", "power.shutdown.accepted"),
            (NasPowerAction.reboot, "reboot", "nasReboot", "power.reboot.accepted")
        ] {
            let transport = MockHTTPTransport(responses: [
                response(#"{"success":true,"data":{"model":"Synthetic NAS"}}"#),
                response(#"{"success":true}"#)
            ])
            let repository = try makeRepository(
                apiNames: [DsmAPIName.coreSystem],
                transport: transport
            )

            let result = try await repository.performPowerActionResult(action)

            XCTAssertEqual(result.status, .confirmedSuccess)
            XCTAssertEqual(result.operation, operation)
            XCTAssertTrue(result.submitted)
            XCTAssertFalse(result.requiresRefresh)
            XCTAssertEqual(result.localizationKey, localizationKey)
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requestValue("method", in: requests[0]), "info")
            XCTAssertEqual(requestValue("method", in: requests[1]), method)
        }
    }

    func testNAS电源请求能力缺失和预检权限不足时不写入() async throws {
        let unsupportedTransport = MockHTTPTransport(responses: [])
        let unsupportedRepository = try makeRepository(
            apiNames: [],
            transport: unsupportedTransport
        )

        let unsupported = try await unsupportedRepository
            .performPowerActionResult(.shutdown)

        XCTAssertEqual(unsupported.status, .unsupported)
        XCTAssertFalse(unsupported.submitted)
        let unsupportedRequests = await unsupportedTransport.recordedRequests()
        XCTAssertTrue(unsupportedRequests.isEmpty)

        let permissionTransport = MockHTTPTransport(responses: [
            response(#"{"success":false,"error":{"code":105}}"#)
        ])
        let permissionRepository = try makeRepository(
            apiNames: [DsmAPIName.coreSystem],
            transport: permissionTransport
        )

        let denied = try await permissionRepository
            .performPowerActionResult(.reboot)

        XCTAssertEqual(denied.status, .permissionDenied)
        XCTAssertFalse(denied.submitted)
        let permissionRequests = await permissionTransport.recordedRequests()
        XCTAssertEqual(permissionRequests.count, 1)
        XCTAssertEqual(
            requestValue("method", in: permissionRequests[0]),
            "info"
        )
    }

    func testNAS电源请求提交前取消时不发送任何请求() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreSystem],
            transport: transport
        )

        let result = try await Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try await repository.performPowerActionResult(.shutdown)
        }.value

        XCTAssertEqual(result.status, .cancelledBeforeSubmission)
        XCTAssertFalse(result.submitted)
        XCTAssertFalse(result.requiresRefresh)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testNAS电源请求提交超时报告未确认且不自动重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(
                response(#"{"success":true,"data":{"model":"Synthetic NAS"}}"#)
            ),
            .urlError(.timedOut)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreSystem],
            transport: transport
        )

        let result = try await repository.performPowerActionResult(.shutdown)

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.submitted)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.counts.unknown, 1)
        XCTAssertEqual(result.localizationKey, "power.action.unverified")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requestValue("method", in: requests[1]), "shutdown")
    }

    func testNAS电源请求提交后权限拒绝与登录失效不会误报未知() async throws {
        for (code, expectedStatus, expectedKey) in [
            (105, MutationResultStatus.permissionDenied, "power.action.permission-denied"),
            (106, MutationResultStatus.confirmedFailure, "power.action.session-expired")
        ] {
            let transport = MockHTTPTransport(responses: [
                response(#"{"success":true,"data":{"model":"Synthetic NAS"}}"#),
                response(#"{"success":false,"error":{"code":\#(code)}}"#)
            ])
            let repository = try makeRepository(
                apiNames: [DsmAPIName.coreSystem],
                transport: transport
            )

            let result = try await repository.performPowerActionResult(.reboot)

            XCTAssertEqual(result.status, expectedStatus)
            XCTAssertTrue(result.submitted)
            XCTAssertFalse(result.requiresRefresh)
            XCTAssertEqual(result.localizationKey, expectedKey)
        }
    }

    func testNAS电源请求全局防重复并区分提交后取消() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(
                response(#"{"success":true,"data":{"model":"Synthetic NAS"}}"#)
            ),
            .waitUntilCancelled
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreSystem],
            transport: transport
        )
        let firstTask = Task {
            try await repository.performPowerActionResult(.shutdown)
        }
        while await transport.recordedRequests().count < 2 {
            await Task.yield()
        }

        let duplicate = try await repository.performPowerActionResult(.reboot)
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(duplicate.localizationKey, "power.action.busy")
        XCTAssertEqual(
            cancelled.status,
            .cancellationRequestedAfterSubmission
        )
        XCTAssertTrue(cancelled.requiresRefresh)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func test连接派生标识不随时间改变且不包含原始设备标识() async throws {
        let before = #"{"success":true,"data":{"items":[{"pid":"88","did":"synthetic-device","who":"synthetic","from":"synthetic-source","type":"HTTP/HTTPS","descr":"DSM","time":"2026-09-17 10:00:00","can_be_kicked":true}],"total":1}}"#
        let after = before.replacingOccurrences(of: "10:00:00", with: "11:00:00")
        let transport = MockHTTPTransport(responses: [response(before), response(after)])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreCurrentConnection], transport: transport)
        let first = try await repository.loadConnections(offset: 0, limit: 500)
        let second = try await repository.loadConnections(offset: 0, limit: 500)
        XCTAssertEqual(first.connections.first?.id, second.connections.first?.id)
        XCTAssertFalse(first.connections.first?.id.contains("synthetic-device") ?? true)
    }

    func test同账号连接没有当前标志时不猜测为当前连接() async throws {
        let data = #"{"success":true,"data":{"items":[{"pid":"88","did":"synthetic-device","who":"synthetic-current","from":"synthetic-source","type":"HTTP/HTTPS","descr":"DSM","can_be_kicked":true}],"total":1}}"#
        let transport = MockHTTPTransport(responses: [response(data)])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreCurrentConnection], transport: transport, currentUsername: "synthetic-current")
        let page = try await repository.loadConnections(offset: 0, limit: 500)
        XCTAssertFalse(page.connections.first?.isCurrentConnection ?? true)
    }

    func test连接畸形目录不当作空列表() async throws {
        for data in [#"{}"#, #"{"items":[null]}"#, #"{"items":[{"who":"synthetic","can_be_kicked":"true"}]}"#] {
            let transport = MockHTTPTransport(responses: [response("{\"success\":true,\"data\":\(data)}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.coreCurrentConnection], transport: transport)
            do { _ = try await repository.loadConnections(offset: 0, limit: 500); XCTFail("畸形目录不能成功") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test连接目标来源变化不发送断开() async throws {
        let original = #"{"success":true,"data":{"items":[{"pid":"88","did":"synthetic-device","who":"synthetic","from":"synthetic-source","type":"HTTP/HTTPS","descr":"DSM","can_be_kicked":true}],"total":1}}"#
        let transport = MockHTTPTransport(responses: [response(original), response(original.replacingOccurrences(of: "synthetic-source", with: "changed-source"))])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreCurrentConnection], transport: transport)
        let directory = try await repository.loadConnections(offset: 0, limit: 500)
        do { try await repository.disconnectConnection(XCTUnwrap(directory.connections.first)); XCTFail("目标变化不能发送") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains { requestValue("method", in: $0) == "kick_connection" })
    }

    func test断开网页连接使用设备标识且写请求允许没有数据正文() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"items":[{"pid":"88","did":"device-token","who":"operator","from":"192.0.2.10","descr":"File Station","type":"HTTP/HTTPS","time":"2026-07-26 10:00:00","can_be_kicked":true}],"total":1}}"#),
            response(#"{"success":true,"data":{"items":[{"pid":"88","did":"device-token","who":"operator","from":"192.0.2.10","descr":"File Station","type":"HTTP/HTTPS","time":"2026-07-26 10:00:00","can_be_kicked":true}],"total":1}}"#),
            response(#"{"success":true}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreCurrentConnection],
            transport: transport
        )

        let page = try await repository.loadConnections(offset: 0, limit: 10)
        let connection = try XCTUnwrap(page.connections.first)
        try await repository.disconnectConnection(connection)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requestValue("method", in: requests[2]), "kick_connection")
        XCTAssertEqual(requestValue("service_conn", in: requests[2]), "[]")
        XCTAssertEqual(
            requestValue("http_conn", in: requests[2])?.contains(#""did":"device-token""#),
            true
        )
    }

    func test账号额外字段严格解析且空字符串保留() async throws {
        let data = #"{"success":true,"data":{"users":[{"name":"synthetic-account","additional":{"uid":123,"description":"","email":"","expired":false,"groups":["synthetic-group"],"can_edit":true,"can_delete":true}}],"groups":[{"name":"synthetic-group","additional":{"gid":456,"description":"","can_edit":true,"can_delete":true}}]}}"#
        let transport = MockHTTPTransport(responses: [response(data), response(data)])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreUser, DsmAPIName.coreGroup], transport: transport)
        let directory = try await repository.loadAccountsAndGroups()
        XCTAssertEqual(directory.users.first?.numericID, 123)
        XCTAssertEqual(directory.groups.first?.numericID, 456)
        XCTAssertEqual(directory.users.first?.description, "")
        XCTAssertEqual(directory.users.first?.email, "")
        XCTAssertTrue(directory.users.first?.canEdit == true)
        XCTAssertTrue(directory.groups.first?.canDelete == true)
    }

    func test缺少账号许可或可编辑字段不默认放行() async throws {
        let data = #"{"success":true,"data":{"users":[{"name":"synthetic-account","can_edit":true}],"groups":[{"name":"synthetic-group"}]}}"#
        let transport = MockHTTPTransport(responses: [response(data), response(data)])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreUser, DsmAPIName.coreGroup], transport: transport)
        let directory = try await repository.loadAccountsAndGroups()
        XCTAssertFalse(directory.users.first?.canEdit ?? true)
        XCTAssertFalse(directory.users.first?.canDelete ?? true)
        XCTAssertFalse(directory.groups.first?.canEdit ?? true)
        XCTAssertFalse(directory.groups.first?.canDelete ?? true)
    }

    func test畸形账号目录不能被当作空目录() async throws {
        for payload in [#"{}"#, #"{"users":[null],"groups":[]}"#,
                        #"{"users":[{"name":"same"},{"name":"SAME"}],"groups":[]}"#,
                        #"{"users":[{"name":"synthetic","can_delete":"true"}],"groups":[]}"#,
                        #"{"users":[{"name":"synthetic","uid":1.5}],"groups":[]}"#] {
            let data = "{\"success\":true,\"data\":\(payload)}"
            let transport = MockHTTPTransport(responses: [response(data), response(data)])
            let repository = try makeRepository(apiNames: [DsmAPIName.coreUser, DsmAPIName.coreGroup], transport: transport)
            do { _ = try await repository.loadAccountsAndGroups(); XCTFail("畸形目录应失败") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test当前账号不能通过保存被停用() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreUser, DsmAPIName.coreGroup], transport: transport, currentUsername: "synthetic-current")
        do {
            try await repository.saveAccount(NasAccountDraft(originalName: "synthetic-current", name: "synthetic-current", isExpired: true))
            XCTFail("不能停用当前登录账号")
        } catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test当前账号删除不发送请求() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreUser, DsmAPIName.coreGroup], transport: transport, currentUsername: "synthetic-current")
        let result = try await repository.deleteAccountResult(name: "synthetic-current")
        XCTAssertEqual(result.status, .permissionDenied)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test账号删除不裁剪名称后误删另一目标() async throws {
        let data = #"{"success":true,"data":{"users":[{"name":"synthetic-account","can_delete":true}],"groups":[]}}"#
        let transport = MockHTTPTransport(responses: [response(data), response(data)])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreUser, DsmAPIName.coreGroup], transport: transport)
        let result = try await repository.deleteAccountResult(name: " synthetic-account ")
        XCTAssertFalse(result.submitted)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains { requestValue("method", in: $0) == "delete" })
    }

    func test删除前重新检查账号许可() async throws {
        let data = #"{"success":true,"data":{"users":[{"name":"synthetic-account","can_delete":false}],"groups":[]}}"#
        let transport = MockHTTPTransport(responses: [response(data), response(data)])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreUser, DsmAPIName.coreGroup], transport: transport)
        let result = try await repository.deleteAccountResult(name: "synthetic-account")
        XCTAssertEqual(result.status, .permissionDenied)
        XCTAssertFalse(result.submitted)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func test新建账号只在请求正文传送密码且删除使用账号数组() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true}"#),
            response(#"{"success":true}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreUser],
            transport: transport
        )
        let draft = NasAccountDraft(
            name: "new-user",
            description: "测试",
            email: "new-user@example.invalid",
            password: "REDACTED_PASSWORD",
            passwordConfirmation: "REDACTED_PASSWORD"
        )

        try await repository.saveAccount(draft)
        try await repository.deleteAccount(name: "new-user")

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[0]), "create")
        XCTAssertEqual(requestValue("password", in: requests[0]), "REDACTED_PASSWORD")
        XCTAssertFalse(requests[0].url?.absoluteString.contains("REDACTED_PASSWORD") == true)
        XCTAssertEqual(requestValue("method", in: requests[1]), "delete")
        XCTAssertEqual(requestValue("name", in: requests[1]), #"["new-user"]"#)
    }

    func test群组新建修改和删除使用专用群组接口() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreGroup],
            transport: transport
        )

        try await repository.saveGroup(
            NasGroupDraft(name: "media-team", description: "媒体")
        )
        try await repository.saveGroup(
            NasGroupDraft(
                originalName: "media-team",
                name: "media-team",
                description: "媒体与照片"
            )
        )
        try await repository.deleteGroup(name: "media-team")

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[0]), "create")
        XCTAssertEqual(requestValue("method", in: requests[1]), "set")
        XCTAssertEqual(requestValue("method", in: requests[2]), "delete")
        XCTAssertEqual(requestValue("name", in: requests[2]), #"["media-team"]"#)
    }

    func test账号删除回读确认目标消失时返回确认成功() async throws {
        let initialDirectory = response(
            #"{"success":true,"data":{"users":[{"name":"new-user","can_delete":true}],"groups":[]}}"#
        )
        let emptyDirectory = response(
            #"{"success":true,"data":{"users":[],"groups":[]}}"#
        )
        let transport = MockHTTPTransport(responses: [
            initialDirectory,
            initialDirectory,
            response(#"{"success":true}"#),
            emptyDirectory,
            emptyDirectory
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreUser, DsmAPIName.coreGroup],
            transport: transport
        )

        let result = try await repository.deleteAccountResult(name: "new-user")

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertTrue(result.submitted)
        XCTAssertFalse(result.requiresRefresh)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 5)
        let deleteRequest = try XCTUnwrap(
            requests.first { requestValue("method", in: $0) == "delete" }
        )
        XCTAssertEqual(requestValue("api", in: deleteRequest), DsmAPIName.coreUser)
    }

    func test账号删除提交时断网保留未确认语义且不重放() async throws {
        let initialDirectory = response(
            #"{"success":true,"data":{"users":[{"name":"new-user","can_delete":true}],"groups":[]}}"#
        )
        let transport = MockHTTPTransport(steps: [
            .response(initialDirectory),
            .response(initialDirectory),
            .urlError(.timedOut)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreUser, DsmAPIName.coreGroup],
            transport: transport
        )

        let result = try await repository.deleteAccountResult(name: "new-user")

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.submitted)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.localizationKey, "account.delete.unverified")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        let deleteRequest = try XCTUnwrap(
            requests.first { requestValue("method", in: $0) == "delete" }
        )
        XCTAssertEqual(requestValue("api", in: deleteRequest), DsmAPIName.coreUser)
    }

    func test受保护账号删除在提交前被拒绝() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreUser, DsmAPIName.coreGroup],
            transport: transport
        )

        let result = try await repository.deleteAccountResult(name: "admin")

        XCTAssertEqual(result.status, .permissionDenied)
        XCTAssertFalse(result.submitted)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test群组删除回读确认目标消失时返回确认成功() async throws {
        let initialDirectory = response(
            #"{"success":true,"data":{"users":[],"groups":[{"name":"media-team","can_delete":true}]}}"#
        )
        let emptyDirectory = response(
            #"{"success":true,"data":{"users":[],"groups":[]}}"#
        )
        let transport = MockHTTPTransport(responses: [
            initialDirectory,
            initialDirectory,
            response(#"{"success":true}"#),
            emptyDirectory,
            emptyDirectory
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreUser, DsmAPIName.coreGroup],
            transport: transport
        )

        let result = try await repository.deleteGroupResult(name: "media-team")

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertTrue(result.submitted)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 5)
        let deleteRequest = try XCTUnwrap(
            requests.first { requestValue("method", in: $0) == "delete" }
        )
        XCTAssertEqual(requestValue("api", in: deleteRequest), DsmAPIName.coreGroup)
    }

    func test文件服务设置只提交真实变化并回读确认() async throws {
        let currentResponses = [
            response(#"{"success":true,"data":{"enable_samba":true}}"#),
            response(#"{"success":true,"data":{"enable_nfs":false}}"#),
            response(#"{"success":true,"data":{"enable_ftp":false,"enable_ftps":false,"portnum":21}}"#),
            response(#"{"success":true,"data":{"enable":false,"portnum":22}}"#)
        ]
        let verifiedResponses = [
            response(#"{"success":true,"data":{"enable_samba":false}}"#),
            response(#"{"success":true,"data":{"enable_nfs":false}}"#),
            response(#"{"success":true,"data":{"enable_ftp":true,"enable_ftps":true,"portnum":2121}}"#),
            response(#"{"success":true,"data":{"enable":false,"portnum":22}}"#)
        ]
        let transport = MockHTTPTransport(
            responses: currentResponses
                + [response(#"{"success":true}"#), response(#"{"success":true}"#)]
                + verifiedResponses
        )
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreFileServiceSMB,
                DsmAPIName.coreFileServiceNFS,
                DsmAPIName.coreFileServiceFTP,
                DsmAPIName.coreFileServiceSFTP
            ],
            transport: transport
        )

        let result = try await repository.saveFileServiceSettingsResult(
            NasFileServiceSettings(
                isSMBEnabled: false,
                isNFSEnabled: false,
                isFTPEnabled: true,
                isFTPSEnabled: true,
                ftpPort: 2121,
                isSFTPEnabled: false,
                sftpPort: 22
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(
            result.counts,
            try MutationResultCounts(succeeded: 2, failed: 0, unknown: 0)
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 10)
        XCTAssertEqual(requestValue("method", in: requests[4]), "set")
        XCTAssertEqual(requestValue("enable_samba", in: requests[4]), "false")
        XCTAssertEqual(requestValue("method", in: requests[5]), "set")
        XCTAssertEqual(requestValue("enable_ftp", in: requests[5]), "true")
        XCTAssertEqual(requestValue("enable_ftps", in: requests[5]), "true")
        XCTAssertEqual(requestValue("portnum", in: requests[5]), "2121")
        XCTAssertFalse(requests.contains { requestValue("enable_nfs", in: $0) != nil })
    }

    func test文件服务中途超时后整体回读并报告部分成功() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"enable_samba":true}}"#)),
            .response(response(#"{"success":true,"data":{"enable_ftp":false,"enable_ftps":false,"portnum":21}}"#)),
            .response(response(#"{"success":true}"#)),
            .urlError(.timedOut),
            .response(response(#"{"success":true,"data":{"enable_samba":false}}"#)),
            .response(response(#"{"success":true,"data":{"enable_ftp":false,"enable_ftps":false,"portnum":21}}"#))
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreFileServiceSMB,
                DsmAPIName.coreFileServiceFTP
            ],
            transport: transport
        )

        let result = try await repository.saveFileServiceSettingsResult(
            NasFileServiceSettings(
                isSMBEnabled: false,
                isNFSEnabled: nil,
                isFTPEnabled: true,
                isFTPSEnabled: false,
                ftpPort: 21,
                isSFTPEnabled: nil,
                sftpPort: nil
            )
        )

        XCTAssertEqual(result.status, .partialSuccess)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(
            result.counts,
            try MutationResultCounts(succeeded: 1, failed: 0, unknown: 1)
        )
        XCTAssertEqual(result.localizationKey, "file-services.settings.partial")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(
            requests.filter { requestValue("enable_ftp", in: $0) == "true" }.count,
            1
        )
    }

    func test文件服务提交断网且回读失败时不自动重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"enable_samba":true}}"#)),
            .urlError(.networkConnectionLost),
            .urlError(.notConnectedToInternet)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreFileServiceSMB],
            transport: transport
        )

        let result = try await repository.saveFileServiceSettingsResult(
            NasFileServiceSettings(
                isSMBEnabled: false,
                isNFSEnabled: nil,
                isFTPEnabled: nil,
                isFTPSEnabled: nil,
                ftpPort: nil,
                isSFTPEnabled: nil,
                sftpPort: nil
            )
        )

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.submitted)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.counts.unknown, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            requests.filter { requestValue("enable_samba", in: $0) == "false" }.count,
            1
        )
    }

    func test文件服务拒绝重复提交并区分提交后取消() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"enable_samba":true}}"#)),
            .waitUntilCancelled
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreFileServiceSMB],
            transport: transport
        )
        let settings = NasFileServiceSettings(
            isSMBEnabled: false,
            isNFSEnabled: nil,
            isFTPEnabled: nil,
            isFTPSEnabled: nil,
            ftpPort: nil,
            isSFTPEnabled: nil,
            sftpPort: nil
        )
        let firstTask = Task {
            try await repository.saveFileServiceSettingsResult(settings)
        }
        while await transport.recordedRequests().count < 2 {
            await Task.yield()
        }

        let duplicate = try await repository.saveFileServiceSettingsResult(settings)
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.requiresRefresh)
    }

    func test文件服务预检拒绝冲突端口且不提交() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"enable_ftp":false,"enable_ftps":false,"portnum":21}}"#),
            response(#"{"success":true,"data":{"enable":false,"portnum":22}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreFileServiceFTP,
                DsmAPIName.coreFileServiceSFTP
            ],
            transport: transport
        )

        let result = try await repository.saveFileServiceSettingsResult(
            NasFileServiceSettings(
                isSMBEnabled: nil,
                isNFSEnabled: nil,
                isFTPEnabled: true,
                isFTPSEnabled: false,
                ftpPort: 2_222,
                isSFTPEnabled: true,
                sftpPort: 2_222
            )
        )

        XCTAssertEqual(result.status, .confirmedFailure)
        XCTAssertFalse(result.submitted)
        XCTAssertEqual(result.errorCategory, .validation)
        XCTAssertEqual(result.localizationKey, "file-services.settings.invalid")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains {
            requestValue("method", in: $0) == "set"
        })
    }

    func test文件服务预检拒绝关闭TimeMachine依赖的SMB() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"enable_samba":true}}"#),
            response(#"{"success":true,"data":{"enable_smb_time_machine":true}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreFileServiceSMB,
                DsmAPIName.coreFileServiceDiscovery
            ],
            transport: transport
        )

        let result = try await repository.saveFileServiceSettingsResult(
            NasFileServiceSettings(
                isSMBEnabled: false,
                isNFSEnabled: nil,
                isFTPEnabled: nil,
                isFTPSEnabled: nil,
                ftpPort: nil,
                isSFTPEnabled: nil,
                sftpPort: nil,
                isSMBTimeMachineEnabled: true
            )
        )

        XCTAssertEqual(result.status, .confirmedFailure)
        XCTAssertFalse(result.submitted)
        XCTAssertEqual(result.errorCategory, .validation)
        XCTAssertEqual(result.localizationKey, "file-services.settings.invalid")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains {
            requestValue("method", in: $0) == "set"
        })
    }

    func test文件服务一次性能力预检避免先写后发现不支持() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"enable_samba":true}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreFileServiceSMB],
            transport: transport
        )

        let result = try await repository.saveFileServiceSettingsResult(
            NasFileServiceSettings(
                isSMBEnabled: false,
                isNFSEnabled: nil,
                isFTPEnabled: true,
                isFTPSEnabled: nil,
                ftpPort: nil,
                isSFTPEnabled: nil,
                sftpPort: nil
            )
        )

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertFalse(result.submitted)
        XCTAssertEqual(result.counts.failed, 2)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests.contains {
            requestValue("method", in: $0) == "set"
        })
    }

    func test远程连接设置写入后回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"enable_ssh":false,"enable_telnet":false,"ssh_port":22}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"enable_ssh":true,"enable_telnet":false,"ssh_port":2222}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreTerminal],
            transport: transport
        )

        let result = try await repository.saveTerminalSettingsResult(
            NasTerminalSettings(isSSHEnabled: true, isTelnetEnabled: false, sshPort: 2222)
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(
            result.counts,
            try MutationResultCounts(succeeded: 2, failed: 0, unknown: 0)
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requestValue("method", in: requests[1]), "set")
        XCTAssertEqual(requestValue("enable_ssh", in: requests[1]), "true")
        XCTAssertEqual(requestValue("enable_telnet", in: requests[1]), "false")
        XCTAssertEqual(requestValue("ssh_port", in: requests[1]), "2222")
        XCTAssertEqual(requestValue("method", in: requests[2]), "get")
    }

    func test远程连接回读不一致时不报告成功() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"enable_ssh":false,"enable_telnet":false,"ssh_port":22}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"enable_ssh":false,"enable_telnet":false,"ssh_port":22}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreTerminal],
            transport: transport
        )

        let result = try await repository.saveTerminalSettingsResult(
            NasTerminalSettings(isSSHEnabled: true, isTelnetEnabled: false, sshPort: 22)
        )

        XCTAssertEqual(result.status, .confirmedFailure)
        XCTAssertTrue(result.submitted)
        XCTAssertFalse(result.requiresRefresh)
        XCTAssertEqual(result.counts.failed, 1)
        XCTAssertEqual(result.localizationKey, "terminal.settings.failed")
    }

    func test远程终端提交超时后逐字段回读并报告部分成功() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"enable_ssh":false,"enable_telnet":false,"ssh_port":22}}"#)),
            .urlError(.timedOut),
            .response(response(#"{"success":true,"data":{"enable_ssh":true,"enable_telnet":false,"ssh_port":22}}"#))
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreTerminal],
            transport: transport
        )

        let result = try await repository.saveTerminalSettingsResult(
            NasTerminalSettings(
                isSSHEnabled: true,
                isTelnetEnabled: true,
                sshPort: 2_222
            )
        )

        XCTAssertEqual(result.status, .partialSuccess)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(
            result.counts,
            try MutationResultCounts(succeeded: 1, failed: 0, unknown: 2)
        )
        XCTAssertEqual(result.localizationKey, "terminal.settings.partial")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "set" }.count,
            1
        )
    }

    func test远程终端提交断网且回读失败时不自动重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"enable_ssh":false,"enable_telnet":false,"ssh_port":22}}"#)),
            .urlError(.networkConnectionLost),
            .urlError(.notConnectedToInternet)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreTerminal],
            transport: transport
        )

        let result = try await repository.saveTerminalSettingsResult(
            NasTerminalSettings(
                isSSHEnabled: true,
                isTelnetEnabled: false,
                sshPort: 2_222
            )
        )

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.submitted)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.counts.unknown, 2)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "set" }.count,
            1
        )
    }

    func test远程终端拒绝重复提交并区分提交后取消() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"enable_ssh":false,"enable_telnet":false,"ssh_port":22}}"#)),
            .waitUntilCancelled
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreTerminal],
            transport: transport
        )
        let settings = NasTerminalSettings(
            isSSHEnabled: true,
            isTelnetEnabled: false,
            sshPort: 22
        )
        let firstTask = Task {
            try await repository.saveTerminalSettingsResult(settings)
        }
        while await transport.recordedRequests().count < 2 {
            await Task.yield()
        }

        let duplicate = try await repository.saveTerminalSettingsResult(settings)
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.requiresRefresh)
    }

    func test远程终端预检拒绝无效端口且不发送请求() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreTerminal],
            transport: transport
        )

        let result = try await repository.saveTerminalSettingsResult(
            NasTerminalSettings(
                isSSHEnabled: true,
                isTelnetEnabled: false,
                sshPort: 65_536
            )
        )

        XCTAssertEqual(result.status, .confirmedFailure)
        XCTAssertFalse(result.submitted)
        XCTAssertEqual(result.errorCategory, .validation)
        XCTAssertEqual(result.localizationKey, "terminal.settings.invalid")
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test远程终端能力缺失时不发送请求() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(
            apiNames: [],
            transport: transport
        )

        let result = try await repository.saveTerminalSettingsResult(
            NasTerminalSettings(
                isSSHEnabled: true,
                isTelnetEnabled: false,
                sshPort: 22
            )
        )

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertFalse(result.submitted)
        XCTAssertEqual(result.errorCategory, .unsupported)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test代理设置写入后回读确认且不传入地址栏() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"enable":false,"http_host":"","http_port":8080}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"enable":true,"http_host":"proxy.example.invalid","http_port":3128}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreNetworkProxy],
            transport: transport
        )

        let result = try await repository.saveProxySettingsResult(
            NasProxySettings(
                isEnabled: true,
                host: " proxy.example.invalid ",
                port: 3128
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(
            result.counts,
            try MutationResultCounts(succeeded: 3, failed: 0, unknown: 0)
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[1]), "set")
        XCTAssertEqual(requestValue("http_host", in: requests[1]), "proxy.example.invalid")
        XCTAssertEqual(requestValue("http_port", in: requests[1]), "3128")
        XCTAssertFalse(requests[1].url?.absoluteString.contains("proxy.example.invalid") == true)
    }

    func test代理设置提交超时后逐字段回读并报告部分成功() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"enable":false,"http_host":"","http_port":8080}}"#)),
            .urlError(.timedOut),
            .response(response(#"{"success":true,"data":{"enable":true,"http_host":"","http_port":8080}}"#))
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreNetworkProxy],
            transport: transport
        )

        let result = try await repository.saveProxySettingsResult(
            NasProxySettings(
                isEnabled: true,
                host: "proxy.example.invalid",
                port: 3_128
            )
        )

        XCTAssertEqual(result.status, .partialSuccess)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(
            result.counts,
            try MutationResultCounts(succeeded: 1, failed: 0, unknown: 2)
        )
        XCTAssertEqual(result.localizationKey, "proxy.settings.partial")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "set" }.count,
            1
        )
    }

    func test代理设置提交断网且回读失败时不自动重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"enable":false,"http_host":"","http_port":8080}}"#)),
            .urlError(.networkConnectionLost),
            .urlError(.notConnectedToInternet)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreNetworkProxy],
            transport: transport
        )

        let result = try await repository.saveProxySettingsResult(
            NasProxySettings(
                isEnabled: true,
                host: "proxy.example.invalid",
                port: 3_128
            )
        )

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.submitted)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.counts.unknown, 3)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "set" }.count,
            1
        )
    }

    func test代理设置拒绝重复提交并区分提交后取消() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"enable":false,"http_host":"","http_port":8080}}"#)),
            .waitUntilCancelled
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreNetworkProxy],
            transport: transport
        )
        let settings = NasProxySettings(
            isEnabled: true,
            host: "proxy.example.invalid",
            port: 3_128
        )
        let firstTask = Task {
            try await repository.saveProxySettingsResult(settings)
        }
        while await transport.recordedRequests().count < 2 {
            await Task.yield()
        }

        let duplicate = try await repository.saveProxySettingsResult(settings)
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.requiresRefresh)
    }

    func test代理设置预检拒绝无效地址和端口且不发送请求() async throws {
        for settings in [
            NasProxySettings(
                isEnabled: true,
                host: "https://proxy.example.invalid/path",
                port: 3_128
            ),
            NasProxySettings(
                isEnabled: true,
                host: "proxy.example.invalid",
                port: 65_536
            ),
            NasProxySettings(
                isEnabled: true,
                host: " ",
                port: nil
            )
        ] {
            let transport = MockHTTPTransport(responses: [])
            let repository = try makeRepository(
                apiNames: [DsmAPIName.coreNetworkProxy],
                transport: transport
            )

            let result = try await repository.saveProxySettingsResult(settings)

            XCTAssertEqual(result.status, .confirmedFailure)
            XCTAssertFalse(result.submitted)
            XCTAssertEqual(result.errorCategory, .validation)
            XCTAssertEqual(result.localizationKey, "proxy.settings.invalid")
            let requests = await transport.recordedRequests()
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func test代理设置能力缺失时不发送请求() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(
            apiNames: [],
            transport: transport
        )

        let result = try await repository.saveProxySettingsResult(
            NasProxySettings(
                isEnabled: true,
                host: "proxy.example.invalid",
                port: 3_128
            )
        )

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertFalse(result.submitted)
        XCTAssertEqual(result.errorCategory, .unsupported)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test硬件设置使用设备范围并在提交后回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"rc_power_config":false}}"#),
            response(#"{"success":true,"data":{"led_brightness":3}}"#),
            response(#"{"success":true,"data":{"min":0,"max":7}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"rc_power_config":true}}"#),
            response(#"{"success":true,"data":{"led_brightness":5}}"#),
            response(#"{"success":true,"data":{"min":0,"max":7}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreHardwarePowerRecovery,
                DsmAPIName.coreHardwareLEDBrightness
            ],
            transport: transport
        )

        let result = try await repository.saveHardwareSettingsResult(
            NasHardwareSettings(
                restartsAfterPowerFailure: true,
                ledBrightness: 5,
                ledBrightnessRange: 0...7
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(
            result.counts,
            try MutationResultCounts(succeeded: 2, failed: 0, unknown: 0)
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 9)
        XCTAssertEqual(requestValue("method", in: requests[3]), "set")
        XCTAssertEqual(requestValue("rc_power_config", in: requests[3]), "true")
        XCTAssertEqual(requestValue("method", in: requests[4]), "set_current_brightness")
        XCTAssertEqual(requestValue("led_brightness", in: requests[4]), "5")
        XCTAssertEqual(requestValue("method", in: requests[5]), "update")
    }

    func test硬件设置中途超时后回读并报告部分成功() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"rc_power_config":false}}"#)),
            .response(response(#"{"success":true,"data":{"dual_fan_speed":"quietfan"}}"#)),
            .response(response(#"{"success":true}"#)),
            .urlError(.timedOut),
            .response(response(#"{"success":true,"data":{"rc_power_config":true}}"#)),
            .response(response(#"{"success":true,"data":{"dual_fan_speed":"quietfan"}}"#))
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreHardwarePowerRecovery,
                DsmAPIName.coreHardwareFanSpeed
            ],
            transport: transport
        )

        let result = try await repository.saveHardwareSettingsResult(
            NasHardwareSettings(
                restartsAfterPowerFailure: true,
                ledBrightness: nil,
                ledBrightnessRange: nil,
                fanMode: "coolfan"
            )
        )

        XCTAssertEqual(result.status, .partialSuccess)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(
            result.counts,
            try MutationResultCounts(succeeded: 1, failed: 0, unknown: 1)
        )
        XCTAssertEqual(result.localizationKey, "hardware.settings.partial")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(
            requests.filter { requestValue("dual_fan_speed", in: $0) == "coolfan" }.count,
            1
        )
    }

    func test硬件设置提交断网且回读失败时不自动重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"rc_power_config":false}}"#)),
            .urlError(.networkConnectionLost),
            .urlError(.notConnectedToInternet)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreHardwarePowerRecovery],
            transport: transport
        )

        let result = try await repository.saveHardwareSettingsResult(
            NasHardwareSettings(
                restartsAfterPowerFailure: true,
                ledBrightness: nil,
                ledBrightnessRange: nil
            )
        )

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.submitted)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.counts.unknown, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "set" }.count,
            1
        )
    }

    func test硬件设置预检拒绝越界亮度且不提交() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"led_brightness":3}}"#),
            response(#"{"success":true,"data":{"min":0,"max":7}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreHardwareLEDBrightness],
            transport: transport
        )

        let result = try await repository.saveHardwareSettingsResult(
            NasHardwareSettings(
                restartsAfterPowerFailure: nil,
                ledBrightness: 8,
                ledBrightnessRange: 0...7
            )
        )

        XCTAssertEqual(result.status, .confirmedFailure)
        XCTAssertFalse(result.submitted)
        XCTAssertEqual(result.errorCategory, .validation)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains {
            ["set_current_brightness", "update"].contains(
                requestValue("method", in: $0)
            )
        })
    }

    func test硬件设置拒绝重复提交并区分提交后取消() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"rc_power_config":false}}"#)),
            .waitUntilCancelled
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreHardwarePowerRecovery],
            transport: transport
        )
        let settings = NasHardwareSettings(
            restartsAfterPowerFailure: true,
            ledBrightness: nil,
            ledBrightnessRange: nil
        )
        let firstTask = Task {
            try await repository.saveHardwareSettingsResult(settings)
        }
        while await transport.recordedRequests().count < 2 {
            await Task.yield()
        }

        let duplicate = try await repository.saveHardwareSettingsResult(settings)
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.requiresRefresh)
    }

    func test远程访问设置分别写入并回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"relay_enabled":true}}"#),
            response(#"{"success":true,"data":{"enabled":false}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"relay_enabled":false}}"#),
            response(#"{"success":true,"data":{"enabled":true}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreQuickConnect,
                DsmAPIName.coreQuickConnectUPnP
            ],
            transport: transport
        )

        let result = try await repository.saveRemoteAccessSettingsResult(
            NasRemoteAccessSettings(
                isRelayEnabled: false,
                isRouterConfigurationEnabled: true,
                canDisableRelay: true
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(
            result.counts,
            try MutationResultCounts(succeeded: 2, failed: 0, unknown: 0)
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requestValue("method", in: requests[2]), "set_misc_config")
        XCTAssertEqual(requestValue("version", in: requests[2]), "3")
        XCTAssertEqual(requestValue("relay_enabled", in: requests[2]), "false")
        XCTAssertEqual(requestValue("method", in: requests[3]), "set")
        XCTAssertEqual(requestValue("enabled", in: requests[3]), "true")
        XCTAssertEqual(requestValue("version", in: requests[3]), "1")
    }

    func test远程访问字段严格布尔且一项失败不阻断另一项() async throws {
        for first in [#"{"success":true,"data":{"relay_enabled":"true"}}"#,
                      #"{"success":false,"error":{"code":105}}"#] {
            let transport = MockHTTPTransport(responses: [response(first), response(#"{"success":true,"data":{"enabled":true}}"#)])
            let repository = try makeRepository(apiNames: [DsmAPIName.coreQuickConnect, DsmAPIName.coreQuickConnectUPnP], transport: transport)
            let settings = try await repository.loadRemoteAccessSettings()
            XCTAssertNil(settings.isRelayEnabled); XCTAssertEqual(settings.isRouterConfigurationEnabled, true)
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requestValue("version", in: requests[0]), "3")
            XCTAssertEqual(requestValue("version", in: requests[1]), "1")
        }
    }

    func test远程访问当前值未知不发送猜测写入() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{}}"#)])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreQuickConnect], transport: transport)
        let result = try await repository.saveRemoteAccessSettingsResult(NasRemoteAccessSettings(isRelayEnabled: false, isRouterConfigurationEnabled: nil, canDisableRelay: true))
        XCTAssertFalse(result.submitted)
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests.contains { requestValue("method", in: $0) == "set_misc_config" })
    }

    func test远程访问明确拒绝不因其他客户端改值而成功() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"relay_enabled":true}}"#),
            response(#"{"success":true,"data":{"enabled":false}}"#), response(#"{"success":false,"error":{"code":105}}"#),
            response(#"{"success":true,"data":{"relay_enabled":false}}"#), response(#"{"success":true,"data":{"enabled":true}}"#)])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreQuickConnect, DsmAPIName.coreQuickConnectUPnP], transport: transport)
        let result = try await repository.saveRemoteAccessSettingsResult(NasRemoteAccessSettings(isRelayEnabled: false, isRouterConfigurationEnabled: true, canDisableRelay: true))
        XCTAssertEqual(result.status, .permissionDenied); XCTAssertEqual(result.counts.succeeded, 0)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "set_misc_config" }.count, 1)
        XCTAssertFalse(requests.contains { requestValue("method", in: $0) == "set" })
    }

    func test远程访问保存后字段缺失保留未知计数() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"relay_enabled":true}}"#),
            response(#"{"success":true}"#), response(#"{"success":true,"data":{}}"#)])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreQuickConnect], transport: transport)
        let result = try await repository.saveRemoteAccessSettingsResult(NasRemoteAccessSettings(isRelayEnabled: false, isRouterConfigurationEnabled: nil, canDisableRelay: true))
        XCTAssertEqual(result.status, .submittedButUnverified); XCTAssertEqual(result.counts.unknown, 1)
    }

    func test远程访问中途超时后回读并报告部分成功() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"relay_enabled":true}}"#)),
            .response(response(#"{"success":true,"data":{"enabled":false}}"#)),
            .response(response(#"{"success":true}"#)),
            .urlError(.timedOut),
            .response(response(#"{"success":true,"data":{"relay_enabled":false}}"#)),
            .response(response(#"{"success":true,"data":{"enabled":false}}"#))
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreQuickConnect,
                DsmAPIName.coreQuickConnectUPnP
            ],
            transport: transport
        )

        let result = try await repository.saveRemoteAccessSettingsResult(
            NasRemoteAccessSettings(
                isRelayEnabled: false,
                isRouterConfigurationEnabled: true,
                canDisableRelay: true
            )
        )

        XCTAssertEqual(result.status, .partialSuccess)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(
            result.counts,
            try MutationResultCounts(succeeded: 1, failed: 0, unknown: 1)
        )
        XCTAssertEqual(result.localizationKey, "remote-access.settings.partial")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(
            requests.filter { requestValue("enabled", in: $0) == "true" }.count,
            1
        )
    }

    func test远程访问提交断网且回读失败时不自动重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"relay_enabled":true}}"#)),
            .urlError(.networkConnectionLost),
            .urlError(.notConnectedToInternet)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreQuickConnect],
            transport: transport
        )

        let result = try await repository.saveRemoteAccessSettingsResult(
            NasRemoteAccessSettings(
                isRelayEnabled: false,
                isRouterConfigurationEnabled: nil,
                canDisableRelay: true
            )
        )

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.submitted)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.counts.unknown, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            requests.filter {
                requestValue("method", in: $0) == "set_misc_config"
            }.count,
            1
        )
    }

    func test远程访问拒绝重复提交并区分提交后取消() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"enabled":false}}"#)),
            .waitUntilCancelled
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreQuickConnectUPnP],
            transport: transport
        )
        let settings = NasRemoteAccessSettings(
            isRelayEnabled: nil,
            isRouterConfigurationEnabled: true,
            canDisableRelay: true
        )
        let firstTask = Task {
            try await repository.saveRemoteAccessSettingsResult(settings)
        }
        while await transport.recordedRequests().count < 2 {
            await Task.yield()
        }

        let duplicate = try await repository.saveRemoteAccessSettingsResult(settings)
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.requiresRefresh)
    }

    func test当前使用中继连接时预检拒绝关闭中继() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"relay_enabled":true}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreQuickConnect],
            transport: transport,
            host: "alpha.beta.quickconnect.to"
        )

        let result = try await repository.saveRemoteAccessSettingsResult(
            NasRemoteAccessSettings(
                isRelayEnabled: false,
                isRouterConfigurationEnabled: nil,
                canDisableRelay: false
            )
        )

        XCTAssertEqual(result.status, .confirmedFailure)
        XCTAssertFalse(result.submitted)
        XCTAssertEqual(result.errorCategory, .conflict)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func test安全防护设置写入完整规则并回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"enable":false,"attempts":10,"within_mins":5,"expire_day":0}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"enable":true,"attempts":5,"within_mins":10,"expire_day":7}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreSecurityAutoBlock],
            transport: transport
        )

        try await repository.saveSecuritySettings(
            NasSecuritySettings(
                isAutoBlockEnabled: true,
                failedAttempts: 5,
                withinMinutes: 10,
                expirationDays: 7
            )
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[1]), "set")
        XCTAssertEqual(requestValue("enable", in: requests[1]), "true")
        XCTAssertEqual(requestValue("attempts", in: requests[1]), "5")
        XCTAssertEqual(requestValue("within_mins", in: requests[1]), "10")
        XCTAssertEqual(requestValue("expire_day", in: requests[1]), "7")
    }

    func test局域网发现设置分别写入并回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"enable_ssdp":false,"enable_avahi":true}}"#),
            response(#"{"success":true,"data":{"enable_smb_time_machine":false}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"enable_ssdp":true,"enable_avahi":true}}"#),
            response(#"{"success":true,"data":{"enable_smb_time_machine":true}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreWebDSM, DsmAPIName.coreFileServiceDiscovery],
            transport: transport
        )

        try await repository.saveFileServiceSettings(
            NasFileServiceSettings(
                isSMBEnabled: nil,
                isNFSEnabled: nil,
                isFTPEnabled: nil,
                isFTPSEnabled: nil,
                ftpPort: nil,
                isSFTPEnabled: nil,
                sftpPort: nil,
                isSSDPEnabled: true,
                isBonjourEnabled: true,
                isSMBTimeMachineEnabled: true
            )
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[2]), "set")
        XCTAssertEqual(requestValue("version", in: requests[2]), "2")
        XCTAssertEqual(requestValue("enable_ssdp", in: requests[2]), "true")
        XCTAssertEqual(requestValue("enable_avahi", in: requests[2]), "true")
        XCTAssertEqual(requestValue("method", in: requests[3]), "set")
        XCTAssertEqual(requestValue("enable_smb_time_machine", in: requests[3]), "true")
    }

    func test风扇和提示音设置只提交变化并回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"dual_fan_speed":"quietfan"}}"#),
            response(#"{"success":true,"data":{"fan_fail":true,"volume_or_cache_crash":true,"poweron_beep":false,"poweroff_beep":false,"reset_beep":true}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"dual_fan_speed":"coolfan"}}"#),
            response(#"{"success":true,"data":{"fan_fail":true,"volume_or_cache_crash":true,"poweron_beep":true,"poweroff_beep":false,"reset_beep":true}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreHardwareFanSpeed,
                DsmAPIName.coreHardwareBeepControl
            ],
            transport: transport
        )

        try await repository.saveHardwareSettings(
            NasHardwareSettings(
                restartsAfterPowerFailure: nil,
                ledBrightness: nil,
                ledBrightnessRange: nil,
                fanMode: "coolfan",
                isFanFailureAlertEnabled: true,
                isVolumeFailureAlertEnabled: true,
                isPowerOnSoundEnabled: true,
                isPowerOffSoundEnabled: false,
                isResetSoundEnabled: true
            )
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("dual_fan_speed", in: requests[2]), "coolfan")
        XCTAssertEqual(requestValue("poweron_beep", in: requests[3]), "true")
        XCTAssertNil(requestValue("fan_fail", in: requests[3]))
    }

    func test拒绝服务攻击防护按真实网卡提交并回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"enable":true,"attempts":5,"within_mins":10,"expire_day":7}}"#),
            response(#"{"success":true,"data":{"interfaces":[{"id":"eth0","display":"局域网 1"},{"id":"eth1","display":"局域网 2"}]}}"#),
            response(#"{"success":true,"data":{"configs":[{"adapter":"eth0","dos_protect_enable":false},{"adapter":"eth1","dos_protect_enable":true}]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"enable":true,"attempts":5,"within_mins":10,"expire_day":7}}"#),
            response(#"{"success":true,"data":{"interfaces":[{"id":"eth0","display":"局域网 1"},{"id":"eth1","display":"局域网 2"}]}}"#),
            response(#"{"success":true,"data":{"configs":[{"adapter":"eth0","dos_protect_enable":true},{"adapter":"eth1","dos_protect_enable":true}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreSecurityAutoBlock,
                DsmAPIName.coreNetworkEthernet,
                DsmAPIName.coreSecurityDoS
            ],
            transport: transport
        )

        try await repository.saveSecuritySettings(
            NasSecuritySettings(
                isAutoBlockEnabled: true,
                failedAttempts: 5,
                withinMinutes: 10,
                expirationDays: 7,
                dosProtection: [
                    NasDoSProtectionSetting(
                        id: "eth0",
                        displayName: "局域网 1",
                        isEnabled: true
                    ),
                    NasDoSProtectionSetting(
                        id: "eth1",
                        displayName: "局域网 2",
                        isEnabled: true
                    )
                ]
            )
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[3]), "set")
        XCTAssertEqual(requestValue("version", in: requests[3]), "2")
        XCTAssertTrue(requestValue("configs", in: requests[3])?.contains("eth0") == true)
        XCTAssertFalse(requests.contains {
            requestValue("method", in: $0) == "set"
                && requestValue("enable", in: $0) != nil
        })
    }

    func test休眠设置只提交设备返回的可修改字段并回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"eunit_deep_sleep":false,"enable_log":true,"sata_deep_sleep":true,"ignore_netbios_broadcast":false,"auto_poweroff_enable":false}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"eunit_deep_sleep":true,"enable_log":true,"sata_deep_sleep":true,"ignore_netbios_broadcast":true,"auto_poweroff_enable":false}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreHardwareHibernation],
            transport: transport
        )

        try await repository.saveHardwareSettings(
            NasHardwareSettings(
                restartsAfterPowerFailure: nil,
                ledBrightness: nil,
                ledBrightnessRange: nil,
                isExternalDriveDeepSleepEnabled: true,
                isWakeUpLogEnabled: true,
                isSATASleepEnabled: true,
                ignoresNetworkDiscoveryDuringSleep: true,
                isAutomaticPowerOffEnabled: false
            )
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[1]), "set")
        XCTAssertEqual(requestValue("eunit_deep_sleep", in: requests[1]), "true")
        XCTAssertEqual(requestValue("ignore_netbios_broadcast", in: requests[1]), "true")
        XCTAssertNil(requestValue("enable_log", in: requests[1]))
        XCTAssertNil(requestValue("sata_deep_sleep", in: requests[1]))
    }

    func test区域未知模式和缺失当前时区不能默认为手动模式() async throws {
        for (mode, zones) in [
            ("unknown", #"{"zonedata":[{"value":"UTC","display":"Synthetic UTC"}]}"#),
            ("ntp", #"{"zonedata":[{"value":"Asia/Shanghai","display":"Synthetic zone"}]}"#)
        ] {
            let current = #"{"success":true,"data":{"date_format":"Y-m-d","time_format":"H:i","timezone":"UTC","enable_ntp":"\#(mode)","server":""}}"#
            let transport = MockHTTPTransport(responses: [
                response(current), response(#"{"success":true,"data":\#(zones)}"#)
            ])
            let repository = try makeRepository(apiNames: [DsmAPIName.coreRegionNTP], transport: transport)
            do {
                _ = try await repository.loadRegionSettings()
                XCTFail("未知模式或当前时区不在列表中应读取失败")
            } catch { }
        }
    }

    func test区域时间缺字段小数越界或无效日期不补午夜() async throws {
        for clock in [
            #""date":"2026/7/26","minute":30,"second":10"#,
            #""date":"2026/7/26","hour":18.5,"minute":30,"second":10"#,
            #""date":"2026/7/26","hour":1e100,"minute":30,"second":10"#,
            #""date":"2026/7/26","hour":24,"minute":30,"second":10"#,
            #""date":"2026/2/30","hour":18,"minute":30,"second":10"#,
            #""date":"2026//26","hour":18,"minute":30,"second":10"#
        ] {
            let current = #"{"success":true,"data":{"date_format":"Y-m-d","time_format":"H:i","timezone":"UTC","enable_ntp":"manual","server":"","# + clock + "}}"
            let transport = MockHTTPTransport(responses: [
                response(current), response(#"{"success":true,"data":{"zonedata":[{"value":"UTC","display":"Synthetic UTC"}]}}"#)
            ])
            let repository = try makeRepository(apiNames: [DsmAPIName.coreRegionNTP], transport: transport)
            let settings = try await repository.loadRegionSettings()
            XCTAssertNil(settings.manualDate)
        }
    }

    func test缺失NAS时间且用户未编辑时间时不得保存格式或改时() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"date_format":"Y-m-d","time_format":"H:i","timezone":"UTC","enable_ntp":"manual","server":"","date":"2026/7/26","minute":30,"second":10}}"#),
            response(#"{"success":true,"data":{"zonedata":[{"value":"UTC","display":"Synthetic UTC"}]}}"#)
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreRegionNTP], transport: transport)
        let desired = NasRegionSettings(dateFormat: "Y/m/d", timeFormat: "H:i", timeZone: "UTC",
            isNetworkTimeEnabled: false, timeServers: [], manualDate: nil,
            timeZones: [NasTimeZoneOption(id: "UTC", displayName: "Synthetic UTC")])
        let result = try await repository.saveRegionSettingsResult(desired)
        XCTAssertFalse(result.submitted)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["get", "listzone"])
    }

    func test读取区域时区和网络校时设置() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"date_format":"Y-m-d","time_format":"H:i","timezone":"Asia/Shanghai","enable_ntp":"ntp","server":"time.example.invalid,pool.example.invalid","date":"2026/7/26","hour":18,"minute":30,"second":10}}"#),
            response(#"{"success":true,"data":{"zonedata":[{"value":"Asia/Shanghai","display":"北京、上海"},{"value":"UTC","display":"协调世界时"}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreRegionNTP],
            transport: transport
        )

        let settings = try await repository.loadRegionSettings()

        XCTAssertEqual(settings.dateFormat, "Y-m-d")
        XCTAssertEqual(settings.timeFormat, "H:i")
        XCTAssertEqual(settings.timeZone, "Asia/Shanghai")
        XCTAssertTrue(settings.isNetworkTimeEnabled)
        XCTAssertEqual(
            settings.timeServers,
            ["time.example.invalid", "pool.example.invalid"]
        )
        XCTAssertEqual(settings.timeZones.map(\.id), ["Asia/Shanghai", "UTC"])
        XCTAssertNotNil(settings.manualDate)
    }

    func test网络校时先保存回读配置再立即校时并复查() async throws {
        let current = #"{"success":true,"data":{"date_format":"Y-m-d","time_format":"H:i","timezone":"Asia/Shanghai","enable_ntp":"manual","server":"","date":"2026/7/26","hour":18,"minute":30,"second":10}}"#
        let zones = #"{"success":true,"data":{"zonedata":[{"value":"Asia/Shanghai","display":"北京、上海"},{"value":"UTC","display":"协调世界时"}]}}"#
        let updated = #"{"success":true,"data":{"date_format":"Y/m/d","time_format":"H:i","timezone":"UTC","enable_ntp":"ntp","server":"time.example.invalid","date":"2026/7/26","hour":18,"minute":30,"second":10}}"#
        let transport = MockHTTPTransport(responses: [
            response(current),
            response(zones),
            response(current),
            response(zones),
            response(#"{"success":true}"#),
            response(updated),
            response(zones),
            response(#"{"success":true}"#),
            response(updated),
            response(zones)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreRegionNTP],
            transport: transport
        )
        let original = try await repository.loadRegionSettings()

        let result = try await repository.saveRegionSettingsResult(
            NasRegionSettings(
                dateFormat: "Y/m/d",
                timeFormat: "H:i",
                timeZone: "UTC",
                isNetworkTimeEnabled: true,
                timeServers: ["time.example.invalid"],
                manualDate: original.manualDate,
                timeZones: original.timeZones
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(
            result.counts,
            try MutationResultCounts(succeeded: 5, failed: 0, unknown: 0)
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[4]), "set")
        XCTAssertEqual(requestValue("enable_ntp", in: requests[4]), "ntp")
        XCTAssertEqual(requestValue("timezone", in: requests[4]), "UTC")
        XCTAssertEqual(requestValue("method", in: requests[7]), "sync")
        XCTAssertEqual(requestValue("servers", in: requests[7]), #"["time.example.invalid"]"#)
    }

    func test区域配置确认后校时超时报告部分成功且不重放() async throws {
        let current = #"{"success":true,"data":{"date_format":"Y-m-d","time_format":"H:i","timezone":"Asia/Shanghai","enable_ntp":"manual","server":"","date":"2026/7/26","hour":18,"minute":30,"second":10}}"#
        let updated = #"{"success":true,"data":{"date_format":"Y/m/d","time_format":"H:i","timezone":"UTC","enable_ntp":"ntp","server":"time.example.invalid","date":"2026/7/26","hour":18,"minute":30,"second":10}}"#
        let zones = #"{"success":true,"data":{"zonedata":[{"value":"Asia/Shanghai","display":"北京、上海"},{"value":"UTC","display":"协调世界时"}]}}"#
        let transport = MockHTTPTransport(steps: [
            .response(response(current)),
            .response(response(zones)),
            .response(response(#"{"success":true}"#)),
            .response(response(updated)),
            .response(response(zones)),
            .urlError(.timedOut)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreRegionNTP],
            transport: transport
        )

        let result = try await repository.saveRegionSettingsResult(
            NasRegionSettings(
                dateFormat: "Y/m/d",
                timeFormat: "H:i",
                timeZone: "UTC",
                isNetworkTimeEnabled: true,
                timeServers: ["time.example.invalid"],
                manualDate: nil,
                timeZones: [
                    NasTimeZoneOption(id: "Asia/Shanghai", displayName: "北京、上海"),
                    NasTimeZoneOption(id: "UTC", displayName: "协调世界时")
                ]
            )
        )

        XCTAssertEqual(result.status, .partialSuccess)
        XCTAssertEqual(
            result.counts,
            try MutationResultCounts(succeeded: 4, failed: 0, unknown: 1)
        )
        XCTAssertEqual(result.localizationKey, "region.settings.partial")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "sync" }.count,
            1
        )
    }

    func test区域配置提交超时后逐字段回读且不继续校时() async throws {
        let current = #"{"success":true,"data":{"date_format":"Y-m-d","time_format":"H:i","timezone":"Asia/Shanghai","enable_ntp":"manual","server":"","date":"2026/7/26","hour":18,"minute":30,"second":10}}"#
        let partial = #"{"success":true,"data":{"date_format":"Y/m/d","time_format":"H:i","timezone":"Asia/Shanghai","enable_ntp":"manual","server":"","date":"2026/7/26","hour":18,"minute":30,"second":10}}"#
        let zones = #"{"success":true,"data":{"zonedata":[{"value":"Asia/Shanghai","display":"北京、上海"},{"value":"UTC","display":"协调世界时"}]}}"#
        let transport = MockHTTPTransport(steps: [
            .response(response(current)),
            .response(response(zones)),
            .urlError(.timedOut),
            .response(response(partial)),
            .response(response(zones))
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreRegionNTP],
            transport: transport
        )

        let result = try await repository.saveRegionSettingsResult(
            NasRegionSettings(
                dateFormat: "Y/m/d",
                timeFormat: "H:i",
                timeZone: "UTC",
                isNetworkTimeEnabled: true,
                timeServers: ["time.example.invalid"],
                manualDate: nil,
                timeZones: [
                    NasTimeZoneOption(id: "Asia/Shanghai", displayName: "北京、上海"),
                    NasTimeZoneOption(id: "UTC", displayName: "协调世界时")
                ]
            )
        )

        XCTAssertEqual(result.status, .partialSuccess)
        XCTAssertEqual(
            result.counts,
            try MutationResultCounts(succeeded: 1, failed: 0, unknown: 4)
        )
        let requests = await transport.recordedRequests()
        XCTAssertFalse(requests.contains {
            requestValue("method", in: $0) == "sync"
        })
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "set" }.count,
            1
        )
    }

    func test区域设置未编辑手动时间时使用刚回读的NAS时间() async throws {
        let current = #"{"success":true,"data":{"date_format":"Y-m-d","time_format":"H:i","timezone":"Asia/Shanghai","enable_ntp":"manual","server":"","date":"2026/7/26","hour":18,"minute":30,"second":10}}"#
        let updated = #"{"success":true,"data":{"date_format":"Y/m/d","time_format":"H:i","timezone":"Asia/Shanghai","enable_ntp":"manual","server":"","date":"2026/7/26","hour":18,"minute":30,"second":11}}"#
        let zones = #"{"success":true,"data":{"zonedata":[{"value":"Asia/Shanghai","display":"北京、上海"}]}}"#
        let transport = MockHTTPTransport(responses: [
            response(current),
            response(zones),
            response(#"{"success":true}"#),
            response(updated),
            response(zones)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreRegionNTP],
            transport: transport
        )

        let result = try await repository.saveRegionSettingsResult(
            NasRegionSettings(
                dateFormat: "Y/m/d",
                timeFormat: "H:i",
                timeZone: "Asia/Shanghai",
                isNetworkTimeEnabled: false,
                timeServers: [],
                manualDate: nil,
                timeZones: [
                    NasTimeZoneOption(id: "Asia/Shanghai", displayName: "北京、上海")
                ]
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("date", in: requests[2]), "2026/7/26")
        XCTAssertEqual(requestValue("hour", in: requests[2]), "18")
        XCTAssertEqual(requestValue("minute", in: requests[2]), "30")
        XCTAssertEqual(requestValue("second", in: requests[2]), "10")
    }

    func test区域设置拒绝重复提交并区分提交后取消() async throws {
        let current = #"{"success":true,"data":{"date_format":"Y-m-d","time_format":"H:i","timezone":"Asia/Shanghai","enable_ntp":"manual","server":"","date":"2026/7/26","hour":18,"minute":30,"second":10}}"#
        let zones = #"{"success":true,"data":{"zonedata":[{"value":"Asia/Shanghai","display":"北京、上海"},{"value":"UTC","display":"协调世界时"}]}}"#
        let transport = MockHTTPTransport(steps: [
            .response(response(current)),
            .response(response(zones)),
            .waitUntilCancelled
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreRegionNTP],
            transport: transport
        )
        let settings = NasRegionSettings(
            dateFormat: "Y/m/d",
            timeFormat: "H:i",
            timeZone: "UTC",
            isNetworkTimeEnabled: true,
            timeServers: ["time.example.invalid"],
            manualDate: nil,
            timeZones: [
                NasTimeZoneOption(id: "Asia/Shanghai", displayName: "北京、上海"),
                NasTimeZoneOption(id: "UTC", displayName: "协调世界时")
            ]
        )
        let firstTask = Task {
            try await repository.saveRegionSettingsResult(settings)
        }
        while await transport.recordedRequests().count < 3 {
            await Task.yield()
        }

        let duplicate = try await repository.saveRegionSettingsResult(settings)
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.requiresRefresh)
    }

    func test区域设置预检拒绝无效输入和能力缺失且不发送请求() async throws {
        let zones = [
            NasTimeZoneOption(id: "Asia/Shanghai", displayName: "北京、上海")
        ]
        for settings in [
            NasRegionSettings(
                dateFormat: " ",
                timeFormat: "H:i",
                timeZone: "Asia/Shanghai",
                isNetworkTimeEnabled: true,
                timeServers: ["time.example.invalid"],
                manualDate: nil,
                timeZones: zones
            ),
            NasRegionSettings(
                dateFormat: "Y-m-d",
                timeFormat: "H:i",
                timeZone: "Asia/Shanghai",
                isNetworkTimeEnabled: true,
                timeServers: ["https://time.example.invalid/path"],
                manualDate: nil,
                timeZones: zones
            )
        ] {
            let transport = MockHTTPTransport(responses: [])
            let repository = try makeRepository(
                apiNames: [DsmAPIName.coreRegionNTP],
                transport: transport
            )

            let result = try await repository.saveRegionSettingsResult(settings)

            XCTAssertEqual(result.status, .confirmedFailure)
            XCTAssertFalse(result.submitted)
            XCTAssertEqual(result.errorCategory, .validation)
            let requests = await transport.recordedRequests()
            XCTAssertTrue(requests.isEmpty)
        }

        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(apiNames: [], transport: transport)
        let result = try await repository.saveRegionSettingsResult(
            NasRegionSettings(
                dateFormat: "Y-m-d",
                timeFormat: "H:i",
                timeZone: "Asia/Shanghai",
                isNetworkTimeEnabled: true,
                timeServers: ["time.example.invalid"],
                manualDate: nil,
                timeZones: zones
            )
        )
        XCTAssertEqual(result.status, .unsupported)
        XCTAssertFalse(result.submitted)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testDDNS连接测试与保存记录是两个独立操作() async throws {
        let providers = #"{"success":true,"data":{"providers":[{"id":"Example","display":"示例服务"}]}}"#
        let testTransport = MockHTTPTransport(responses: [
            response(providers),
            response(#"{"success":true,"data":{"records":[]}}"#),
            response(#"{"success":true}"#)
        ])
        let testRepository = try makeRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord],
            transport: testTransport
        )
        let draft = NasDDNSDraft(
            providerID: "Example",
            hostname: "nas.example.invalid",
            username: "synthetic-owner",
            password: "SYNTHETIC_EPHEMERAL_SECRET"
        )

        let testResult = try await testRepository.testDDNSResult(draft)

        XCTAssertEqual(testResult.status, .confirmedSuccess)
        let testRequests = await testTransport.recordedRequests()
        XCTAssertEqual(testRequests.count, 3)
        XCTAssertEqual(requestValue("method", in: testRequests[2]), "test")
        XCTAssertFalse(testRequests.contains {
            ["create", "set", "update_ip_address"].contains(
                requestValue("method", in: $0)
            )
        })

        let saveTransport = MockHTTPTransport(responses: [
            response(providers),
            response(#"{"success":true,"data":{"records":[]}}"#),
            response(#"{"success":true}"#),
            response(providers),
            response(#"{"success":true,"data":{"records":[{"provider":"Example","hostname":"nas.example.invalid","username":"synthetic-owner","enable":true,"heartbeat":false,"ip":"192.0.2.10","status":"service_ddns_normal"}]}}"#)
        ])
        let saveRepository = try makeRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord],
            transport: saveTransport
        )

        let saveResult = try await saveRepository.saveDDNSResult(draft)

        XCTAssertEqual(saveResult.status, .confirmedSuccess)
        let saveRequests = await saveTransport.recordedRequests()
        XCTAssertEqual(saveRequests.count, 5)
        XCTAssertEqual(requestValue("method", in: saveRequests[2]), "create")
        XCTAssertFalse(saveRequests.contains {
            ["test", "update_ip_address"].contains(requestValue("method", in: $0))
        })
        XCTAssertFalse(saveRequests[2].url?.absoluteString.contains(
            "SYNTHETIC_EPHEMERAL_SECRET"
        ) == true)
    }

    func testDDNS保存明确拒绝不被旧配置匹配覆盖() async throws {
        let providers = #"{"success":true,"data":{"providers":[{"id":"Example"}]}}"#
        let existing = #"{"success":true,"data":{"records":[{"provider":"Example","hostname":"nas.example.invalid","username":"synthetic-owner","enable":true,"heartbeat":false}]}}"#
        let transport = MockHTTPTransport(responses: [
            response(providers), response(existing),
            response(#"{"success":false,"error":{"code":105}}"#),
            response(providers), response(existing)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord], transport: transport
        )
        var draft = syntheticDDNSDraft
        draft.originalProviderID = "Example"
        let result = try await repository.saveDDNSResult(draft)
        XCTAssertEqual(result.status, .permissionDenied)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requestValue("method", in: requests[2]), "set")
    }

    func testDDNS仅换密码响应丢失不以原配置确认成功() async throws {
        let providers = #"{"success":true,"data":{"providers":[{"id":"Example"}]}}"#
        let existing = #"{"success":true,"data":{"records":[{"provider":"Example","hostname":"nas.example.invalid","username":"synthetic-owner","enable":true,"heartbeat":false}]}}"#
        let transport = MockHTTPTransport(steps: [
            .response(response(providers)), .response(response(existing)), .urlError(.timedOut),
            .response(response(providers)), .response(response(existing))
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord], transport: transport
        )
        var draft = syntheticDDNSDraft
        draft.originalProviderID = "Example"
        let result = try await repository.saveDDNSResult(draft)
        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertEqual(result.diagnosticTag, "ddns.save.credential-unverified")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
    }

    func testDDNS删除明确拒绝不被其他来源删除覆盖() async throws {
        let providers = #"{"success":true,"data":{"providers":[{"id":"Example"}]}}"#
        let existing = #"{"success":true,"data":{"records":[{"provider":"Example","hostname":"nas.example.invalid","username":"synthetic-owner","enable":true,"heartbeat":false}]}}"#
        let transport = MockHTTPTransport(responses: [
            response(providers), response(existing),
            response(#"{"success":false,"error":{"code":105}}"#),
            response(providers), response(#"{"success":true,"data":{"records":[]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord], transport: transport
        )
        let result = try await repository.deleteDDNSResult(providerID: "Example")
        XCTAssertEqual(result.status, .permissionDenied)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
    }

    func testDDNS保存超时后回读确认且不重放() async throws {
        let providers = #"{"success":true,"data":{"providers":[{"id":"Example","display":"Synthetic Provider"}]}}"#
        let saved = #"{"success":true,"data":{"records":[{"provider":"Example","hostname":"nas.example.invalid","username":"synthetic-owner","enable":true,"heartbeat":false}]}}"#
        let transport = MockHTTPTransport(steps: [
            .response(response(providers)),
            .response(response(#"{"success":true,"data":{"records":[]}}"#)),
            .urlError(.timedOut),
            .response(response(providers)),
            .response(response(saved))
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord],
            transport: transport
        )

        let result = try await repository.saveDDNSResult(
            syntheticDDNSDraft
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "create" }.count,
            1
        )
    }

    func testDDNS保存超时且回读未生效时报告未确认() async throws {
        let providers = #"{"success":true,"data":{"providers":[{"id":"Example","display":"Synthetic Provider"}]}}"#
        let transport = MockHTTPTransport(steps: [
            .response(response(providers)),
            .response(response(#"{"success":true,"data":{"records":[]}}"#)),
            .urlError(.networkConnectionLost),
            .response(response(providers)),
            .response(response(#"{"success":true,"data":{"records":[]}}"#))
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord],
            transport: transport
        )

        let result = try await repository.saveDDNSResult(
            syntheticDDNSDraft
        )

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.requiresRefresh)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "create" }.count,
            1
        )
    }

    func testDDNS删除超时但回读消失时确认成功() async throws {
        let providers = #"{"success":true,"data":{"providers":[{"id":"Example","display":"Synthetic Provider"}]}}"#
        let existing = #"{"success":true,"data":{"records":[{"provider":"Example","hostname":"nas.example.invalid","username":"synthetic-owner","enable":true}]}}"#
        let transport = MockHTTPTransport(steps: [
            .response(response(providers)),
            .response(response(existing)),
            .urlError(.timedOut),
            .response(response(providers)),
            .response(response(#"{"success":true,"data":{"records":[]}}"#))
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord],
            transport: transport
        )

        let result = try await repository.deleteDDNSResult(
            providerID: "Example"
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "delete" }.count,
            1
        )
    }

    func testDDNS立即更新只确认请求接受和列表复载() async throws {
        let providers = #"{"success":true,"data":{"providers":[{"id":"Example","display":"Synthetic Provider"}]}}"#
        let records = #"{"success":true,"data":{"records":[{"provider":"Example","hostname":"nas.example.invalid","username":"synthetic-owner","enable":true,"status":"service_ddns_normal"}]}}"#
        let transport = MockHTTPTransport(responses: [
            response(providers),
            response(records),
            response(#"{"success":true}"#),
            response(providers),
            response(records)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord],
            transport: transport
        )

        let result = try await repository.refreshDDNSResult()

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.diagnosticTag, "ddns.refresh.accepted-and-reloaded")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter {
                requestValue("method", in: $0) == "update_ip_address"
            }.count,
            1
        )
    }

    func testDDNS拒绝无效输入能力缺失与重复提交() async throws {
        let invalidTransport = MockHTTPTransport(responses: [])
        let invalidRepository = try makeRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord],
            transport: invalidTransport
        )
        let invalid = try await invalidRepository.saveDDNSResult(
            NasDDNSDraft(
                providerID: "Example",
                hostname: "https://nas.example.invalid/path",
                username: "synthetic-owner",
                password: "SYNTHETIC_EPHEMERAL_SECRET"
            )
        )
        XCTAssertEqual(invalid.status, .confirmedFailure)
        XCTAssertEqual(invalid.errorCategory, .validation)
        let invalidRequests = await invalidTransport.recordedRequests()
        XCTAssertTrue(invalidRequests.isEmpty)

        let unsupportedTransport = MockHTTPTransport(responses: [])
        let unsupportedRepository = try makeRepository(
            apiNames: [],
            transport: unsupportedTransport
        )
        let unsupported = try await unsupportedRepository.saveDDNSResult(
            syntheticDDNSDraft
        )
        XCTAssertEqual(unsupported.status, .unsupported)
        let unsupportedRequests = await unsupportedTransport.recordedRequests()
        XCTAssertTrue(unsupportedRequests.isEmpty)

        let providers = #"{"success":true,"data":{"providers":[{"id":"Example","display":"Synthetic Provider"}]}}"#
        let duplicateTransport = MockHTTPTransport(steps: [
            .response(response(providers)),
            .response(response(#"{"success":true,"data":{"records":[]}}"#)),
            .waitUntilCancelled
        ])
        let duplicateRepository = try makeRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord],
            transport: duplicateTransport
        )
        let duplicateDraft = syntheticDDNSDraft
        let firstTask = Task {
            try await duplicateRepository.saveDDNSResult(duplicateDraft)
        }
        while await duplicateTransport.recordedRequests().count < 3 {
            await Task.yield()
        }

        let duplicate = try await duplicateRepository.testDDNSResult(
            duplicateDraft
        )
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
    }

    func test读取DDNS时合并重复服务商并忽略无效项() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"providers":[{"id":"Synology"},{"id":"Synology","display":"Synology"},{"provider":"Example","name":"示例服务"},{"id":"","display":"无效项"}]}}"#),
            response(#"{"success":true,"data":{"records":[{"provider":"Synology","hostname":"nas.example.invalid","enable":true,"ip":"192.0.2.10"}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord],
            transport: transport
        )

        let directory = try await repository.loadDDNS()

        XCTAssertEqual(directory.providers.map(\.id), ["Synology", "Example"])
        XCTAssertEqual(directory.providers.map(\.displayName), ["Synology", "示例服务"])
        XCTAssertEqual(directory.records.count, 1)
        XCTAssertEqual(directory.records.first?.providerName, "Synology")
    }

    func testUPS设置提交连接方式和安全关机参数并回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"enable":false,"mode":"USB","delay_time":60,"ups_set_safemode_until_lowbatt":false,"shutdown_device":false,"net_server_ip":"","snmp_server_ip":""}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"enable":true,"mode":"SLAVE","delay_time":120,"ups_set_safemode_until_lowbatt":false,"shutdown_device":true,"net_server_ip":"192.0.2.2","snmp_server_ip":""}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreExternalDeviceUPS],
            transport: transport
        )

        try await repository.saveHardwareSettings(
            NasHardwareSettings(
                restartsAfterPowerFailure: nil,
                ledBrightness: nil,
                ledBrightnessRange: nil,
                ups: NasUPSSettings(
                    isEnabled: true,
                    mode: "SLAVE",
                    safeModeDelaySeconds: 120,
                    waitsUntilLowBattery: false,
                    shutsDownUPSAfterSafeMode: true,
                    networkServerAddress: "192.0.2.2",
                    snmpServerAddress: ""
                )
            )
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[1]), "set")
        XCTAssertEqual(requestValue("mode", in: requests[1]), "SLAVE")
        XCTAssertEqual(requestValue("delay_time", in: requests[1]), "120")
        XCTAssertEqual(requestValue("net_server_ip", in: requests[1]), "192.0.2.2")
        XCTAssertEqual(requestValue("shutdown_device", in: requests[1]), "true")
    }

    func test网卡设置使用单张网卡配置并在提交后回读() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"interfaces":[{"ifname":"eth0","title":"局域网 1","status":"connected"}]}}"#),
            response(#"{"success":true,"data":{"ifname":"eth0","title":"局域网 1","status":"connected","use_dhcp":true,"ip":"192.0.2.10","mask":"255.255.255.0","gateway":"192.0.2.1","dns":"192.0.2.1","is_default_gateway":true,"mtu":1500,"enable_vlan":false,"vlan_id":0}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"ifname":"eth0","title":"局域网 1","status":"connected","use_dhcp":false,"ip":"192.0.2.20","mask":"255.255.255.0","gateway":"192.0.2.1","dns":"192.0.2.1","is_default_gateway":true,"mtu":1500,"enable_vlan":true,"vlan_id":20}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreNetworkEthernet],
            transport: transport
        )

        try await repository.saveEthernetInterface(
            NasEthernetInterface(
                id: "eth0",
                displayName: "局域网 1",
                status: "connected",
                usesDHCP: false,
                address: "192.0.2.20",
                subnetMask: "255.255.255.0",
                gateway: "192.0.2.1",
                dnsServers: "192.0.2.1",
                isDefaultGateway: true,
                mtu: 1_500,
                isVLANEnabled: true,
                vlanID: 20
            )
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[2]), "set")
        XCTAssertEqual(requestValue("version", in: requests[2]), "1")
        XCTAssertTrue(requestValue("configs", in: requests[2])?.contains(#""ifname":"eth0""#) == true)
        XCTAssertTrue(requestValue("configs", in: requests[2])?.contains(#""vlan_id":20"#) == true)
    }

    func test网卡设置回读一致时返回确认成功() async throws {
        let transport = MockHTTPTransport(responses: [
            response(ethernetListResponse),
            response(ethernetCurrentResponse),
            response(#"{"success":true}"#),
            response(ethernetUpdatedResponse)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreNetworkEthernet],
            transport: transport
        )

        let result = try await repository.saveEthernetInterfaceResult(
            ethernetUpdate
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertTrue(result.submitted)
        XCTAssertFalse(result.requiresRefresh)
        XCTAssertEqual(result.counts.succeeded, 1)
    }

    func test网卡设置提交时断网保留未确认语义且不重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(ethernetListResponse)),
            .response(response(ethernetCurrentResponse)),
            .urlError(.networkConnectionLost)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreNetworkEthernet],
            transport: transport
        )

        let result = try await repository.saveEthernetInterfaceResult(
            ethernetUpdate
        )

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.submitted)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.errorCategory, .network)
        XCTAssertEqual(result.localizationKey, "network.ethernet.unverified")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "set" }.count,
            1
        )
    }

    func test网卡设置回读失败时要求重新连接核对() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(ethernetListResponse)),
            .response(response(ethernetCurrentResponse)),
            .response(response(#"{"success":true}"#)),
            .urlError(.timedOut)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreNetworkEthernet],
            transport: transport
        )

        let result = try await repository.saveEthernetInterfaceResult(
            ethernetUpdate
        )

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.counts.unknown, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "set" }.count,
            1
        )
    }

    func test网卡设置拒绝同一目标重复提交并区分提交后取消() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(ethernetListResponse)),
            .response(response(ethernetCurrentResponse)),
            .waitUntilCancelled
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreNetworkEthernet],
            transport: transport
        )
        let update = ethernetUpdate
        let firstTask = Task {
            try await repository.saveEthernetInterfaceResult(update)
        }
        while await transport.recordedRequests().count < 3 {
            await Task.yield()
        }

        let duplicate = try await repository.saveEthernetInterfaceResult(
            update
        )
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.requiresRefresh)
    }

    func test关闭防火墙使用专用停用动作并回读确认() async throws {
        let autoBlock = #"{"success":true,"data":{"enable":true,"attempts":5,"within_mins":10,"expire_day":0}}"#
        let transport = MockHTTPTransport(responses: [
            response(autoBlock),
            response(#"{"success":true,"data":{"enable_firewall":true,"profile_name":"default"}}"#),
            response(#"{"success":true,"data":{"enable_port_check":true}}"#),
            response(#"{"success":true}"#),
            response(autoBlock),
            response(#"{"success":true,"data":{"enable_firewall":false,"profile_name":"default"}}"#),
            response(#"{"success":true,"data":{"enable_port_check":true}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreSecurityAutoBlock,
                DsmAPIName.coreSecurityFirewall,
                DsmAPIName.coreSecurityFirewallConf
            ],
            transport: transport
        )

        try await repository.saveSecuritySettings(
            NasSecuritySettings(
                isAutoBlockEnabled: true,
                failedAttempts: 5,
                withinMinutes: 10,
                expirationDays: nil,
                isFirewallEnabled: false,
                firewallProfileName: "default",
                isPortScanProtectionEnabled: true
            )
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[3]), "set")
        XCTAssertEqual(requestValue("set_type", in: requests[3]), "disable")
    }

    func test安全设置统一结果逐项提交并回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(securityAutoBlock(enabled: false, attempts: 10, within: 5, expiration: 0)),
            response(securityFirewall(enabled: true)),
            response(securityFirewallConf(enabled: false)),
            response(securityEthernet),
            response(securityDoS(enabled: false)),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(securityAutoBlock(enabled: true, attempts: 5, within: 10, expiration: 7)),
            response(securityFirewall(enabled: false)),
            response(securityFirewallConf(enabled: true)),
            response(securityEthernet),
            response(securityDoS(enabled: true))
        ])
        let repository = try makeRepository(
            apiNames: securityAPINameSet,
            transport: transport
        )

        let result = try await repository.saveSecuritySettingsResult(
            securityUpdate
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.counts, try MutationResultCounts(
            succeeded: 4,
            failed: 0,
            unknown: 0
        ))
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[5]), "set")
        XCTAssertEqual(requestValue("method", in: requests[6]), "set")
        XCTAssertEqual(requestValue("version", in: requests[6]), "2")
        XCTAssertEqual(requestValue("method", in: requests[7]), "set")
        XCTAssertEqual(requestValue("set_type", in: requests[8]), "disable")
    }

    func test安全设置中途失败后回读并报告部分成功() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(securityAutoBlock(
                enabled: false,
                attempts: 10,
                within: 5,
                expiration: 0
            ))),
            .response(response(securityFirewallConf(enabled: false))),
            .response(response(#"{"success":true}"#)),
            .urlError(.timedOut),
            .response(response(securityAutoBlock(
                enabled: true,
                attempts: 5,
                within: 10,
                expiration: 7
            ))),
            .response(response(securityFirewallConf(enabled: false)))
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreSecurityAutoBlock,
                DsmAPIName.coreSecurityFirewallConf
            ],
            transport: transport
        )
        let settings = NasSecuritySettings(
            isAutoBlockEnabled: true,
            failedAttempts: 5,
            withinMinutes: 10,
            expirationDays: 7,
            isPortScanProtectionEnabled: true
        )

        let result = try await repository.saveSecuritySettingsResult(settings)

        XCTAssertEqual(result.status, .partialSuccess)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.counts, try MutationResultCounts(
            succeeded: 1,
            failed: 1,
            unknown: 0
        ))
        XCTAssertEqual(result.localizationKey, "security.settings.partial")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 6)
    }

    func test安全设置提交断网且回读失败时不自动重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(securityAutoBlock(
                enabled: false,
                attempts: 10,
                within: 5,
                expiration: 0
            ))),
            .urlError(.networkConnectionLost),
            .urlError(.notConnectedToInternet)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreSecurityAutoBlock],
            transport: transport
        )
        let settings = NasSecuritySettings(
            isAutoBlockEnabled: true,
            failedAttempts: 5,
            withinMinutes: 10,
            expirationDays: 7
        )

        let result = try await repository.saveSecuritySettingsResult(settings)

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.submitted)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.counts.unknown, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
    }

    func test安全设置拒绝重复提交并区分提交后取消() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(securityAutoBlock(
                enabled: false,
                attempts: 10,
                within: 5,
                expiration: 0
            ))),
            .waitUntilCancelled
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreSecurityAutoBlock],
            transport: transport
        )
        let settings = NasSecuritySettings(
            isAutoBlockEnabled: true,
            failedAttempts: 5,
            withinMinutes: 10,
            expirationDays: 7
        )
        let firstTask = Task {
            try await repository.saveSecuritySettingsResult(settings)
        }
        while await transport.recordedRequests().count < 2 {
            await Task.yield()
        }

        let duplicate = try await repository.saveSecuritySettingsResult(settings)
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.requiresRefresh)
    }

    func test开启防火墙轮询配置档任务并回读确认() async throws {
        let autoBlock = securityAutoBlock(
            enabled: true,
            attempts: 5,
            within: 10,
            expiration: 0
        )
        let transport = MockHTTPTransport(responses: [
            response(autoBlock),
            response(securityFirewall(enabled: false)),
            response(#"{"success":true,"data":{"task_id":"synthetic-task"}}"#),
            response(#"{"success":true,"data":{"success":true}}"#),
            response(#"{"success":true}"#),
            response(autoBlock),
            response(securityFirewall(enabled: true))
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreSecurityAutoBlock,
                DsmAPIName.coreSecurityFirewall,
                DsmAPIName.coreSecurityFirewallProfileApply
            ],
            transport: transport
        )

        let result = try await repository.saveSecuritySettingsResult(
            NasSecuritySettings(
                isAutoBlockEnabled: true,
                failedAttempts: 5,
                withinMinutes: 10,
                expirationDays: nil,
                isFirewallEnabled: true,
                firewallProfileName: "synthetic-profile"
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[2]), "start")
        XCTAssertEqual(requestValue("name", in: requests[2]), "synthetic-profile")
        XCTAssertEqual(requestValue("method", in: requests[3]), "status")
        XCTAssertEqual(requestValue("task_id", in: requests[3]), "synthetic-task")
        XCTAssertEqual(requestValue("method", in: requests[4]), "stop")
    }

    func test读取电源计划时仅保留白名单字段且不提交写操作() async throws {
        let transport = MockHTTPTransport(responses: [
            response(
                #"{"success":true,"data":{"timezone":"Asia/Shanghai","total":200,"schedules":[{"id":"schedule-1","action":"power_on","enabled":true,"hour":7,"minute":30,"weekdays":["mon","wed","fri"],"command":"PRIVATE_COMMAND","path":"/private/path","account":"private-user","address":"192.0.2.1"},{"id":"schedule-2","action":"shutdown","enabled":false,"hour":23,"minute":5,"date":"2026-12-31"},{"id":"schedule-3","action":"custom","hour":12,"minute":0,"weekdays":["mon","tue","wed","thu","fri","sat","sun"]}]}}"#
            )
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreHardwarePowerSchedule],
            transport: transport
        )

        let snapshot = try await repository.loadPowerSchedule()

        XCTAssertEqual(snapshot.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(snapshot.total, 200)
        XCTAssertTrue(snapshot.isTruncated)
        XCTAssertEqual(snapshot.entries.count, 3)
        XCTAssertEqual(snapshot.entries[0].action, .startup)
        XCTAssertEqual(
            snapshot.entries[0].recurrence,
            .weekly([.monday, .wednesday, .friday])
        )
        XCTAssertEqual(
            snapshot.entries[1].recurrence,
            .once(NasPowerScheduleDate(year: 2026, month: 12, day: 31))
        )
        XCTAssertEqual(snapshot.entries[2].action, .unknown)
        XCTAssertEqual(snapshot.entries[2].recurrence, .daily)
        XCTAssertNil(snapshot.entries[2].isEnabled)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requestValue("api", in: requests[0]), DsmAPIName.coreHardwarePowerSchedule)
        XCTAssertEqual(requestValue("version", in: requests[0]), "1")
        XCTAssertEqual(requestValue("method", in: requests[0]), "load")
        XCTAssertFalse(requests.contains { requestValue("method", in: $0) == "save" })
    }

    func test电源计划拒绝歧义星期和无效时间() async throws {
        let transport = MockHTTPTransport(responses: [
            response(
                #"{"success":true,"data":{"time_zone":"Unsafe Time Zone","items":[{"id":"numeric-days","action":"restart","enabled":true,"hour":8,"minute":15,"days":[1,2,3]},{"id":"invalid-time","action":"shutdown","hour":24,"minute":0,"weekdays":["sun"]}]}}"#
            )
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreHardwarePowerSchedule],
            transport: transport
        )

        let snapshot = try await repository.loadPowerSchedule()

        XCTAssertNil(snapshot.timeZoneIdentifier)
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.entries[0].action, .restart)
        XCTAssertEqual(snapshot.entries[0].recurrence, .unknown)
    }

    func test缺少电源计划能力时零请求降级() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(apiNames: [], transport: transport)

        do {
            _ = try await repository.loadPowerSchedule()
            XCTFail("缺少能力时不应发送电源计划请求")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .apiUnavailable)
        }

        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test电源计划缺失冲突或全无效根不能当成空列表() async throws {
        for data in [#"{}"#, #"{"schedules":{}}"#, #"{"schedules":[],"items":[{}]}"#, #"{"schedules":[{"hour":8.5,"minute":0}]}"#, #"{"schedules":[],"total":1}"#] {
            let transport = MockHTTPTransport(responses: [response("{\"success\":true,\"data\":\(data)}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.coreHardwarePowerSchedule], transport: transport)
            do { _ = try await repository.loadPowerSchedule(); XCTFail("无效响应不能伪装为没有计划") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test电源计划不截断小数时间或猜测布尔值() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"schedules":[{"hour":8.5,"minute":0},{"hour":8,"minute":0,"enabled":"false"}]}}"#)])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreHardwarePowerSchedule], transport: transport)
        let snapshot = try await repository.loadPowerSchedule()
        XCTAssertEqual(snapshot.entries.count, 1); XCTAssertNil(snapshot.entries[0].isEnabled)
        XCTAssertTrue(snapshot.isTruncated); XCTAssertEqual(snapshot.total, 2)
    }

    func test读取外接存储只保留明确字节字段且绝不弹出设备() async throws {
        let transport = MockHTTPTransport(responses: [
            response(
                #"{"success":true,"data":{"total":1,"devices":[{"id":"usb-1","display_name":"Synthetic USB","status":"ready","capacity_bytes":1000000000,"used_bytes":250000000,"size":999,"serial":"PRIVATE_SERIAL","device":"/private/device","mount_path":"/private/mount","share_name":"private-share","address":"192.0.2.1"}]}}"#
            ),
            response(
                #"{"success":true,"data":{"items":[{"storage_id":"esata-1","model":"Synthetic eSATA","state":"busy","total_bytes":2000000000,"usage_bytes":3000000000}]}}"#
            )
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreExternalStorageUSB,
                DsmAPIName.coreExternalStorageESATA
            ],
            transport: transport
        )

        let directory = try await repository.loadExternalStorage()

        XCTAssertEqual(directory.devices.count, 2)
        XCTAssertEqual(directory.total, 2)
        XCTAssertFalse(directory.isTruncated)
        XCTAssertTrue(directory.unavailableConnections.isEmpty)
        XCTAssertEqual(directory.devices[0].connection, .eSATA)
        XCTAssertEqual(directory.devices[0].capacityBytes, 2_000_000_000)
        XCTAssertNil(directory.devices[0].usedBytes)
        XCTAssertEqual(directory.devices[0].status, .busy)
        XCTAssertEqual(directory.devices[1].connection, .usb)
        XCTAssertEqual(directory.devices[1].displayName, "Synthetic USB")
        XCTAssertEqual(directory.devices[1].capacityBytes, 1_000_000_000)
        XCTAssertEqual(directory.devices[1].usedBytes, 250_000_000)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { requestValue("version", in: $0) == "1" })
        XCTAssertTrue(requests.allSatisfy { requestValue("method", in: $0) == "list" })
        XCTAssertFalse(requests.contains { requestValue("method", in: $0) == "eject" })
    }

    func test外接存储单项失败时保留另一连接类型() async throws {
        let transport = MockHTTPTransport(responses: [
            response(
                #"{"success":true,"data":{"devices":[{"id":"usb-1","name":"/private/device","status":"normal","size":1024}]}}"#
            ),
            response(#"{"success":false,"error":{"code":105}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.coreExternalStorageUSB,
                DsmAPIName.coreExternalStorageESATA
            ],
            transport: transport
        )

        let directory = try await repository.loadExternalStorage()

        XCTAssertEqual(directory.devices.count, 1)
        XCTAssertEqual(directory.devices[0].connection, .usb)
        XCTAssertNil(directory.devices[0].displayName)
        XCTAssertNil(directory.devices[0].capacityBytes)
        XCTAssertEqual(directory.unavailableConnections, [.eSATA])
    }

    func test外接存储每种连接最多保留六十四项() async throws {
        let rows = (0..<65).map { index in
            #"{"id":"usb-\#(index)","name":"Synthetic \#(index)","status":"ready"}"#
        }.joined(separator: ",")
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"total":65,"devices":[\#(rows)]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreExternalStorageUSB],
            transport: transport
        )

        let directory = try await repository.loadExternalStorage()

        XCTAssertEqual(directory.devices.count, 64)
        XCTAssertEqual(directory.total, 65)
        XCTAssertTrue(directory.isTruncated)
        XCTAssertEqual(directory.unavailableConnections, [.eSATA])
    }

    func test缺少外接存储能力时零请求降级() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(apiNames: [], transport: transport)

        do {
            _ = try await repository.loadExternalStorage()
            XCTFail("缺少能力时不应发送外接存储请求")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .apiUnavailable)
        }

        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test外接存储整体失败或畸形根不会返回空目录() async throws {
        for data in [#"{}"#, #"{"devices":{}}"#, #"{"devices":[],"items":[{}]}"#, #"{"devices":[],"total":1}"#] {
            let transport = MockHTTPTransport(responses: [response("{\"success\":true,\"data\":\(data)}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.coreExternalStorageUSB], transport: transport)
            do { _ = try await repository.loadExternalStorage(); XCTFail("读取失败不能误报没有设备") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test外接存储小数和冲突容量保持未知() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"devices":[{"capacity_bytes":100.5},{"capacity_bytes":100,"total_bytes":200}]}}"#)])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreExternalStorageUSB], transport: transport)
        let result = try await repository.loadExternalStorage()
        XCTAssertEqual(result.devices.count, 2); XCTAssertTrue(result.devices.allSatisfy { $0.capacityBytes == nil })
    }

    func test外接存储登录失效不降级成部分或空目录() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":false,"error":{"code":119}}"#)])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreExternalStorageUSB, DsmAPIName.coreExternalStorageESATA], transport: transport)
        do { _ = try await repository.loadExternalStorage(); XCTFail("登录失效应保持认证错误") }
        catch let error as AppError { XCTAssertEqual(error.category, .authenticationRequired) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 1)
    }

    func test读取ZRAM只保留白名单字段且绝不提交设置() async throws {
        let transport = MockHTTPTransport(responses: [
            response(
                #"{"success":true,"data":{"enable":true,"configured_bytes":1073741824,"algorithm":"lz4hc","device":"/private/zram0","kernel_parameter":"private","account":"private-user"}}"#
            )
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreHardwareZRAM],
            transport: transport
        )

        let snapshot = try await repository.loadZRAM()

        XCTAssertEqual(snapshot.isEnabled, true)
        XCTAssertEqual(snapshot.configuredBytes, 1_073_741_824)
        XCTAssertEqual(snapshot.algorithm, .lz4)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requestValue("api", in: requests[0]), DsmAPIName.coreHardwareZRAM)
        XCTAssertEqual(requestValue("version", in: requests[0]), "1")
        XCTAssertEqual(requestValue("method", in: requests[0]), "get")
        XCTAssertFalse(requests.contains { requestValue("method", in: $0) == "set" })
    }

    func testZRAM拒绝单位不明确容量和未知算法() async throws {
        let transport = MockHTTPTransport(responses: [
            response(
                #"{"success":true,"data":{"enabled":false,"size":1024,"algorithm":"private-algorithm"}}"#
            )
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.coreHardwareZRAM],
            transport: transport
        )

        let snapshot = try await repository.loadZRAM()

        XCTAssertEqual(snapshot.isEnabled, false)
        XCTAssertNil(snapshot.configuredBytes)
        XCTAssertEqual(snapshot.algorithm, .unknown)
    }

    func test缺少ZRAM能力时零请求降级() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(apiNames: [], transport: transport)

        do {
            _ = try await repository.loadZRAM()
            XCTFail("缺少能力时不应发送 ZRAM 请求")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .apiUnavailable)
        }

        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testZRAM类型错误和冲突别名保持未知() async throws {
        for data in [#"{"enable":"false","configured_bytes":100.5,"algorithm":"private"}"#,
                     #"{"enable":true,"enabled":false,"configured_bytes":100,"capacity_bytes":200,"algorithm":"lz4","compressor":"zstd"}"#] {
            let transport = MockHTTPTransport(responses: [response("{\"success\":true,\"data\":\(data)}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.coreHardwareZRAM], transport: transport)
            let snapshot = try await repository.loadZRAM()
            XCTAssertNil(snapshot.isEnabled); XCTAssertNil(snapshot.configuredBytes); XCTAssertEqual(snapshot.algorithm, .unknown)
        }
    }

    func testZRAM非对象响应不当作空信息() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":[]}"#)])
        let repository = try makeRepository(apiNames: [DsmAPIName.coreHardwareZRAM], transport: transport)
        do { _ = try await repository.loadZRAM(); XCTFail("非对象响应应失败") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
    }

    private func makeRepository(
        apiNames: [String],
        transport: any DsmHTTPTransport,
        host: String = "nas.example.invalid",
        currentUsername: String? = nil
    ) throws -> DsmNasAdministrationRepository {
        let capabilities = Dictionary(uniqueKeysWithValues: apiNames.map { name in
            (
                name,
                ApiCapability(
                    name: name,
                    path: "entry.cgi",
                    minVersion: 1,
                    maxVersion: name == DsmAPIName.coreTaskScheduler ? 4 : 3,
                    requestFormat: .form,
                    selectedVersion: name == DsmAPIName.coreTaskScheduler
                        ? 4
                        : ([
                            DsmAPIName.coreRegionNTP,
                            DsmAPIName.coreSystem
                        ].contains(name) ? 3 : 1)
                )
            )
        })
        return try DsmNasAdministrationRepository(
            profile: NasProfile(
                displayName: "测试设备",
                host: host,
                port: 5_001,
                usernameHint: currentUsername
            ),
            capabilities: CapabilitySet(capabilities),
            session: AuthSession(
                sid: "REDACTED_SESSION",
                synoToken: "REDACTED_SESSION",
                did: nil,
                isPortalPort: false
            ),
            transport: transport
        )
    }

    private func response(_ json: String) -> DsmHTTPResponse {
        DsmHTTPResponse(data: Data(json.utf8), statusCode: 200)
    }

    private var packageListResponse: String {
        #"{"success":true,"data":{"packages":[{"id":"Example","name":"示例套件","version":"1.0","additional":{"status":"stopped","startable":true,"dsm_apps":"App.One App.Two","install_type":"user","ctl_uninstall":true,"available_operation":["uninstall"]}}]}}"#
    }

    private var ethernetListResponse: String {
        #"{"success":true,"data":{"interfaces":[{"ifname":"eth0","title":"局域网 1","status":"connected"}]}}"#
    }

    private var ethernetCurrentResponse: String {
        #"{"success":true,"data":{"ifname":"eth0","title":"局域网 1","status":"connected","use_dhcp":true,"ip":"192.0.2.10","mask":"255.255.255.0","gateway":"192.0.2.1","dns":"192.0.2.1","is_default_gateway":true,"mtu":1500,"enable_vlan":false,"vlan_id":0}}"#
    }

    private var ethernetUpdatedResponse: String {
        #"{"success":true,"data":{"ifname":"eth0","title":"局域网 1","status":"connected","use_dhcp":false,"ip":"192.0.2.20","mask":"255.255.255.0","gateway":"192.0.2.1","dns":"192.0.2.1","is_default_gateway":true,"mtu":1500,"enable_vlan":true,"vlan_id":20}}"#
    }

    private var ethernetUpdate: NasEthernetInterface {
        NasEthernetInterface(
            id: "eth0",
            displayName: "局域网 1",
            status: "connected",
            usesDHCP: false,
            address: "192.0.2.20",
            subnetMask: "255.255.255.0",
            gateway: "192.0.2.1",
            dnsServers: "192.0.2.1",
            isDefaultGateway: true,
            mtu: 1_500,
            isVLANEnabled: true,
            vlanID: 20
        )
    }

    private var securityAPINameSet: [String] {
        [
            DsmAPIName.coreSecurityAutoBlock,
            DsmAPIName.coreNetworkEthernet,
            DsmAPIName.coreSecurityDoS,
            DsmAPIName.coreSecurityFirewall,
            DsmAPIName.coreSecurityFirewallConf
        ]
    }

    private var securityEthernet: String {
        #"{"success":true,"data":{"interfaces":[{"id":"eth-synthetic","display":"Synthetic LAN"}]}}"#
    }

    private func securityAutoBlock(
        enabled: Bool,
        attempts: Int,
        within: Int,
        expiration: Int
    ) -> String {
        #"{"success":true,"data":{"enable":\#(enabled),"attempts":\#(attempts),"within_mins":\#(within),"expire_day":\#(expiration)}}"#
    }

    private func securityFirewall(enabled: Bool) -> String {
        #"{"success":true,"data":{"enable_firewall":\#(enabled),"profile_name":"synthetic-profile"}}"#
    }

    private func securityFirewallConf(enabled: Bool) -> String {
        #"{"success":true,"data":{"enable_port_check":\#(enabled)}}"#
    }

    private func securityDoS(enabled: Bool) -> String {
        #"{"success":true,"data":{"configs":[{"adapter":"eth-synthetic","dos_protect_enable":\#(enabled)}]}}"#
    }

    private var securityUpdate: NasSecuritySettings {
        NasSecuritySettings(
            isAutoBlockEnabled: true,
            failedAttempts: 5,
            withinMinutes: 10,
            expirationDays: 7,
            dosProtection: [
                NasDoSProtectionSetting(
                    id: "eth-synthetic",
                    displayName: "Synthetic LAN",
                    isEnabled: true
                )
            ],
            isFirewallEnabled: false,
            firewallProfileName: "synthetic-profile",
            isPortScanProtectionEnabled: true
        )
    }

    private var syntheticDDNSDraft: NasDDNSDraft {
        NasDDNSDraft(
            providerID: "Example",
            hostname: "nas.example.invalid",
            username: "synthetic-owner",
            password: "SYNTHETIC_EPHEMERAL_SECRET"
        )
    }

    private var syntheticStorageDisk: String {
        #"{"success":true,"data":{"disks":[{"id":"synthetic-disk","device":"synthetic-device","longName":"Synthetic Disk","smart_status":"normal","smart_test_support":true}],"storagePools":[],"volumes":[]}}"#
    }

    private func syntheticDiskTestStatus(
        running: Bool,
        type: String? = nil
    ) -> String {
        var item = #"{"device":"synthetic-device","testing":\#(running),"ihm_testing":false,"perf_testing":false"#
        if let type {
            item += #","test_type":"\#(type)""#
        }
        item += "}"
        return #"{"success":true,"data":{"testInfo":[\#(item)]}}"#
    }

    private func requestValue(_ name: String, in request: URLRequest) -> String? {
        if let value = URLComponents(
            url: request.url ?? URL(fileURLWithPath: "/"),
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == name })?.value {
            return value
        }
        guard let body = request.httpBody,
              let fields = String(data: body, encoding: .utf8) else {
            return nil
        }
        return URLComponents(string: "https://example.invalid/?\(fields)")?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}

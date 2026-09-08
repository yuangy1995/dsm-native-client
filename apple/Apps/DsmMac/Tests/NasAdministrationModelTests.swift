import DsmCore
import DsmLocalization
import XCTest
@testable import DsmMacExecutable

@MainActor
final class NasAdministrationModelTests: XCTestCase {
    func test关闭NAS设置后不会发起请求且开启后可以读取() async {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)

        model.setModuleEnabled(false)
        await model.activate()
        let disabledRequestCount = await repository.systemRequestCount()
        XCTAssertEqual(disabledRequestCount, 0)

        model.setModuleEnabled(true)
        await model.activate()
        let enabledRequestCount = await repository.systemRequestCount()
        XCTAssertEqual(enabledRequestCount, 1)
        XCTAssertEqual(model.overview?.serverName, "测试 NAS")
        XCTAssertEqual(model.performanceHistory.last?.cpuUsage, 25)
    }

    func test关闭NAS设置后停止接受迟到结果() async {
        let repository = NasAdministrationRepositoryStub(delayNanoseconds: 50_000_000)
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)

        let task = Task { await model.activate() }
        await Task.yield()
        model.setModuleEnabled(false)
        await task.value

        XCTAssertNil(model.overview)
        XCTAssertFalse(model.isLoading(.overview))
    }

    func test页面切换不会清空已经读取的账号目录() async {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)

        await model.activate(.accounts)
        XCTAssertEqual(model.accounts?.users.map(\.name), ["user"])

        await model.activate(.overview)
        XCTAssertEqual(model.accounts?.users.map(\.name), ["user"])
        XCTAssertTrue(model.hasLoaded(.accounts))
    }

    func test空结果仅在请求完成后进入已加载状态() async {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)

        XCTAssertFalse(model.hasLoaded(.connections))
        await model.activate(.connections)

        XCTAssertTrue(model.hasLoaded(.connections))
        XCTAssertEqual(model.connections?.connections, [])
    }

    func test共享访问页面只展示当前账号有效权限() async {
        let shareRepository = ShareAccessRepositoryStub(
            directory: NasShareAccessDirectory(shares: [
                NasShareAccessEntry(
                    id: "synthetic-read-only",
                    name: "只读资料",
                    accessLevel: .readOnly,
                    canDelete: false
                ),
                NasShareAccessEntry(
                    id: "synthetic-unknown",
                    name: "待确认资料",
                    accessLevel: .unknown,
                    canDelete: false
                )
            ])
        )
        let model = NasSettingsModel(shareAccessRepository: shareRepository)
        model.setModuleEnabled(true)

        await model.activate(.shareAccess)

        XCTAssertTrue(model.hasLoaded(.shareAccess))
        XCTAssertEqual(model.shareAccess?.shares.map(\.accessLevel), [.readOnly, .unknown])
        XCTAssertNil(model.errorMessage(for: .shareAccess))
        let requestCount = await shareRepository.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func test缺少FileStation连接时共享访问明确降级() async {
        let model = NasSettingsModel()
        model.setModuleEnabled(true)

        await model.activate(.shareAccess)

        XCTAssertFalse(model.hasLoaded(.shareAccess))
        XCTAssertNil(model.shareAccess)
        XCTAssertEqual(
            model.errorMessage(for: .shareAccess),
            L10n.string("share-access.unavailable")
        )
    }

    func test系统活动页面读取只读进程目录() async {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)

        await model.activate(.processes)

        XCTAssertTrue(model.hasLoaded(.processes))
        XCTAssertEqual(model.processDirectory?.processes.map(\.name), ["service-worker"])
        XCTAssertEqual(model.processDirectory?.groups.map(\.name), ["Example Service"])
        XCTAssertEqual(model.processDirectory?.total, 1)
        XCTAssertNil(model.errorMessage(for: .processes))
    }

    func test电源计划页面读取只读快照() async {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)

        await model.activate(.powerSchedule)

        XCTAssertTrue(model.hasLoaded(.powerSchedule))
        XCTAssertEqual(model.powerSchedule?.entries.count, 1)
        XCTAssertEqual(model.powerSchedule?.entries.first?.action, .startup)
        XCTAssertEqual(model.powerSchedule?.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertNil(model.errorMessage(for: .powerSchedule))
    }

    func test外接存储页面读取只读目录() async {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)

        await model.activate(.externalStorage)

        XCTAssertTrue(model.hasLoaded(.externalStorage))
        XCTAssertEqual(model.externalStorage?.devices.count, 1)
        XCTAssertEqual(model.externalStorage?.devices.first?.connection, .usb)
        XCTAssertEqual(model.externalStorage?.devices.first?.status, .ready)
        XCTAssertNil(model.errorMessage(for: .externalStorage))
    }

    func test内存压缩页面读取只读摘要() async {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)

        await model.activate(.zram)

        XCTAssertTrue(model.hasLoaded(.zram))
        XCTAssertEqual(model.zram?.isEnabled, true)
        XCTAssertEqual(model.zram?.configuredBytes, 1_073_741_824)
        XCTAssertEqual(model.zram?.algorithm, .lz4)
        XCTAssertNil(model.errorMessage(for: .zram))
    }

    func test暂停套件后刷新并确认最终状态() async throws {
        let repository = NasAdministrationRepositoryStub(packages: [
            package(status: "running", canStart: false, canStop: true, canUninstall: true)
        ])
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.packages)

        let result = try await model.controlPackage(
            id: "Example",
            action: .stop
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(model.packages.first?.status, "stopped")
        XCTAssertFalse(model.packageOperationIDs.contains("Example"))
        let requestCount = await repository.packageControlRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func test套件停止未确认时保留状态并提示先刷新() async {
        let repository = NasAdministrationRepositoryStub(
            packages: [
                package(
                    status: "running",
                    canStart: false,
                    canStop: true,
                    canUninstall: true
                )
            ],
            packageControlStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.packages)

        do {
            _ = try await model.controlPackage(id: "Example", action: .stop)
            XCTFail("未确认的停止操作不应显示为完成")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("package.stop.unverified")
            )
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }

        XCTAssertEqual(model.packages.first?.status, "running")
        XCTAssertFalse(model.packageOperationIDs.contains("Example"))
    }

    func test套件控制在模型层阻止同一套件重复提交() async throws {
        let repository = NasAdministrationRepositoryStub(
            delayNanoseconds: 50_000_000,
            packages: [
                package(
                    status: "running",
                    canStart: false,
                    canStop: true,
                    canUninstall: true
                )
            ]
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.packages)

        let firstTask = Task {
            try await model.controlPackage(id: "Example", action: .stop)
        }
        while !model.packageOperationIDs.contains("Example") {
            await Task.yield()
        }

        do {
            _ = try await model.controlPackage(id: "Example", action: .stop)
            XCTFail("同一套件不应重复提交")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .serverBusy)
        }
        let first = try await firstTask.value

        XCTAssertEqual(first.status, .confirmedSuccess)
        XCTAssertFalse(model.packageOperationIDs.contains("Example"))
        let requestCount = await repository.packageControlRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func test套件升级提示不会开放未实现的写操作() async {
        let repository = NasAdministrationRepositoryStub(packages: [
            package(
                status: "running",
                canStart: false,
                canStop: true,
                canUninstall: true,
                isUpgradeAvailable: true
            )
        ])
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.packages)

        XCTAssertTrue(model.packages.first?.isUpgradeAvailable == true)
        XCTAssertFalse(model.packages.first?.canUpgrade ?? true)
        do {
            _ = try await model.controlPackage(id: "Example", action: .upgrade)
            XCTFail("只读升级提示不应发送升级请求")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .apiUnavailable)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("ui.40a27587a6302b95")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        let requestCount = await repository.packageControlRequestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func test系统套件不会提交卸载请求() async {
        let repository = NasAdministrationRepositoryStub(packages: [
            package(status: "running", canStart: false, canStop: true, canUninstall: false)
        ])
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.packages)

        do {
            _ = try await model.controlPackage(id: "Example", action: .uninstall)
            XCTFail("系统套件应拒绝卸载")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .permissionDenied)
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        let requestCount = await repository.packageControlRequestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func test套件卸载只有回读确认后才从列表移除() async throws {
        let repository = NasAdministrationRepositoryStub(packages: [
            package(status: "stopped", canStart: true, canStop: false, canUninstall: true)
        ])
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.packages)

        _ = try await model.controlPackage(id: "Example", action: .uninstall)

        XCTAssertTrue(model.packages.isEmpty)
        XCTAssertFalse(model.packageOperationIDs.contains("Example"))
        let requestCount = await repository.packageControlRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func test套件卸载未确认时提示先刷新且不建议立即重试() async {
        let repository = NasAdministrationRepositoryStub(
            packages: [
                package(
                    status: "stopped",
                    canStart: true,
                    canStop: false,
                    canUninstall: true
                )
            ],
            packageUninstallStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.packages)

        do {
            _ = try await model.controlPackage(id: "Example", action: .uninstall)
            XCTFail("未确认的卸载不应显示为完成")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("package.uninstall.unverified")
            )
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.packages.map(\.id), ["Example"])
    }

    func test套件卸载反馈覆盖权限和不支持状态() {
        let permission = NasSettingsModel.packageUninstallFeedback(
            for: .permissionDenied
        )
        let unsupported = NasSettingsModel.packageUninstallFeedback(
            for: .unsupported
        )

        XCTAssertEqual(
            permission.resourceKey,
            "package.uninstall.permission-denied"
        )
        XCTAssertEqual(permission.category, .permissionDenied)
        XCTAssertEqual(
            unsupported.resourceKey,
            "package.uninstall.unsupported"
        )
        XCTAssertEqual(unsupported.category, .apiUnavailable)
    }

    func test账号删除只有回读确认后才从目录移除() async throws {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.accounts)
        let account = try XCTUnwrap(model.accounts?.users.first)

        try await model.deleteAccount(account)

        XCTAssertTrue(model.accounts?.users.isEmpty == true)
        XCTAssertFalse(model.accountOperationIDs.contains(account.id))
    }

    func test账号删除未确认时提示先刷新且不建议立即重试() async throws {
        let repository = NasAdministrationRepositoryStub(
            accountDeleteStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.accounts)
        let account = try XCTUnwrap(model.accounts?.users.first)

        do {
            try await model.deleteAccount(account)
            XCTFail("未确认的删除不应显示为完成")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("account.delete.unverified")
            )
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.accounts?.users.map(\.name), ["user"])
    }

    func test账号与群组删除反馈覆盖权限和不支持状态() {
        let accountPermission = NasSettingsModel.directoryDeletionFeedback(
            for: .permissionDenied,
            kind: .user
        )
        let groupUnsupported = NasSettingsModel.directoryDeletionFeedback(
            for: .unsupported,
            kind: .group
        )

        XCTAssertEqual(
            accountPermission.resourceKey,
            "account.delete.permission-denied"
        )
        XCTAssertEqual(accountPermission.category, .permissionDenied)
        XCTAssertEqual(
            groupUnsupported.resourceKey,
            "group.delete.unsupported"
        )
        XCTAssertEqual(groupUnsupported.category, .apiUnavailable)
    }

    func test网卡设置只有确认成功后才更新当前配置() async throws {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.interfaces)
        let updated = ethernetUpdate

        try await model.saveEthernetInterface(updated)

        XCTAssertEqual(model.ethernetInterfaces.first?.address, updated.address)
        XCTAssertEqual(model.ethernetInterfaces.first?.vlanID, updated.vlanID)
        XCTAssertFalse(model.networkOperationIDs.contains("network:eth0"))
    }

    func test网卡设置未确认时提示重新连接且不建议立即重试() async {
        let repository = NasAdministrationRepositoryStub(
            ethernetUpdateStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.interfaces)

        do {
            try await model.saveEthernetInterface(ethernetUpdate)
            XCTFail("未确认的网卡设置不应显示为完成")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("network.ethernet.unverified")
            )
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.ethernetInterfaces.first?.usesDHCP, true)
    }

    func test网卡设置反馈覆盖权限和不支持状态() {
        let permission = NasSettingsModel.ethernetUpdateFeedback(
            for: .permissionDenied
        )
        let unsupported = NasSettingsModel.ethernetUpdateFeedback(
            for: .unsupported
        )

        XCTAssertEqual(
            permission.resourceKey,
            "network.ethernet.permission-denied"
        )
        XCTAssertEqual(permission.category, .permissionDenied)
        XCTAssertEqual(
            unsupported.resourceKey,
            "network.ethernet.unsupported"
        )
        XCTAssertEqual(unsupported.category, .apiUnavailable)
    }

    func test启动硬盘检测后保存已确认的运行状态() async throws {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.storage)

        try await model.startDiskTest(diskID: "disk1", type: .extended)

        XCTAssertEqual(model.diskTestStatuses["disk1"]?.isRunning, true)
        XCTAssertEqual(model.diskTestStatuses["disk1"]?.runningType, .extended)
        XCTAssertFalse(model.diskOperationIDs.contains("disk1"))
        let requestCount = await repository.diskTestRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func test停止硬盘检测后保存已确认的停止状态() async throws {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.storage)
        try await model.startDiskTest(diskID: "disk1", type: .quick)

        try await model.stopDiskTest(diskID: "disk1")

        XCTAssertEqual(model.diskTestStatuses["disk1"]?.isRunning, false)
        XCTAssertFalse(model.diskOperationIDs.contains("disk1"))
        let requestCount = await repository.diskTestRequestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func test启动硬盘检测未确认时保留当前状态并提示刷新() async {
        let repository = NasAdministrationRepositoryStub(
            diskTestStartStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.storage)

        do {
            try await model.startDiskTest(diskID: "disk1", type: .quick)
            XCTFail("未确认结果不应显示为检测已开始")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("storage.disk-test.start.unverified")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.diskTestStatuses["disk1"]?.isRunning, false)
    }

    func test停止硬盘检测未确认时保留运行状态并提示刷新() async throws {
        let repository = NasAdministrationRepositoryStub(
            diskTestStopStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.storage)
        try await model.startDiskTest(diskID: "disk1", type: .extended)

        do {
            try await model.stopDiskTest(diskID: "disk1")
            XCTFail("未确认结果不应显示为检测已停止")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("storage.disk-test.stop.unverified")
            )
        }
        XCTAssertEqual(model.diskTestStatuses["disk1"]?.isRunning, true)
    }

    func test硬盘检测反馈覆盖权限和不支持状态() {
        XCTAssertEqual(
            NasSettingsModel.diskTestFeedback(
                for: .permissionDenied,
                isStarting: true
            ),
            NasSettingsModel.DiskTestFeedback(
                resourceKey: "storage.disk-test.start.permission-denied",
                category: .permissionDenied
            )
        )
        XCTAssertEqual(
            NasSettingsModel.diskTestFeedback(
                for: .unsupported,
                isStarting: false
            ),
            NasSettingsModel.DiskTestFeedback(
                resourceKey: "storage.disk-test.stop.unsupported",
                category: .apiUnavailable
            )
        )
    }

    func test文件服务设置确认成功后刷新模型状态() async throws {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.fileServices)
        let expected = fileServiceUpdate

        try await model.saveFileServices(expected)

        XCTAssertEqual(model.fileServices, expected)
        XCTAssertFalse(model.isSavingServiceSettings)
    }

    func test文件服务部分成功时刷新并提示逐项核对() async {
        let repository = NasAdministrationRepositoryStub(
            fileServiceUpdateStatus: .partialSuccess
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.fileServices)

        do {
            try await model.saveFileServices(fileServiceUpdate)
            XCTFail("部分成功不应显示为全部保存")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .partialFailure)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("file-services.settings.partial")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.fileServices?.isSMBEnabled, true)
        XCTAssertEqual(model.fileServices?.isFTPEnabled, false)
    }

    func test文件服务未确认时提示先读取且不建议立即重试() async {
        let repository = NasAdministrationRepositoryStub(
            fileServiceUpdateStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.fileServices)

        do {
            try await model.saveFileServices(fileServiceUpdate)
            XCTFail("未确认结果不应显示为保存成功")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("file-services.settings.unverified")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.fileServices?.isSMBEnabled, false)
        XCTAssertEqual(model.fileServices?.isFTPEnabled, false)
    }

    func test文件服务反馈覆盖权限和不支持状态() {
        XCTAssertEqual(
            NasSettingsModel.fileServiceSettingsFeedback(for: .permissionDenied),
            NasSettingsModel.FileServiceSettingsFeedback(
                resourceKey: "file-services.settings.permission-denied",
                category: .permissionDenied
            )
        )
        XCTAssertEqual(
            NasSettingsModel.fileServiceSettingsFeedback(for: .unsupported),
            NasSettingsModel.FileServiceSettingsFeedback(
                resourceKey: "file-services.settings.unsupported",
                category: .apiUnavailable
            )
        )
    }

    func test远程终端设置确认成功后刷新模型状态() async throws {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.terminal)
        let expected = terminalUpdate

        try await model.saveTerminal(expected)

        XCTAssertEqual(model.terminal, expected)
        XCTAssertFalse(model.isSavingServiceSettings)
    }

    func test远程终端部分成功时刷新并提示逐项核对() async {
        let repository = NasAdministrationRepositoryStub(
            terminalUpdateStatus: .partialSuccess
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.terminal)

        do {
            try await model.saveTerminal(terminalUpdate)
            XCTFail("部分成功不应显示为全部保存")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .partialFailure)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("terminal.settings.partial")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.terminal?.isSSHEnabled, true)
        XCTAssertEqual(model.terminal?.isTelnetEnabled, false)
        XCTAssertEqual(model.terminal?.sshPort, 22)
    }

    func test远程终端未确认时提示先读取且不建议立即重试() async {
        let repository = NasAdministrationRepositoryStub(
            terminalUpdateStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.terminal)

        do {
            try await model.saveTerminal(terminalUpdate)
            XCTFail("未确认结果不应显示为保存成功")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("terminal.settings.unverified")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.terminal?.isSSHEnabled, false)
        XCTAssertEqual(model.terminal?.isTelnetEnabled, false)
        XCTAssertEqual(model.terminal?.sshPort, 22)
    }

    func test远程终端反馈覆盖权限和不支持状态() {
        XCTAssertEqual(
            NasSettingsModel.terminalSettingsFeedback(for: .permissionDenied),
            NasSettingsModel.TerminalSettingsFeedback(
                resourceKey: "terminal.settings.permission-denied",
                category: .permissionDenied
            )
        )
        XCTAssertEqual(
            NasSettingsModel.terminalSettingsFeedback(for: .unsupported),
            NasSettingsModel.TerminalSettingsFeedback(
                resourceKey: "terminal.settings.unsupported",
                category: .apiUnavailable
            )
        )
    }

    func test互联网代理设置确认成功后刷新模型状态() async throws {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.network)
        let expected = NasProxySettings(
            isEnabled: true,
            host: "proxy.example.invalid",
            port: 3_128
        )

        try await model.saveProxy(expected)

        XCTAssertEqual(model.proxy, expected)
        XCTAssertFalse(model.isSavingServiceSettings)
    }

    func test互联网代理部分成功时刷新并提示逐项核对() async {
        let repository = NasAdministrationRepositoryStub(
            proxyUpdateStatus: .partialSuccess
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.network)

        do {
            try await model.saveProxy(
                NasProxySettings(
                    isEnabled: true,
                    host: "proxy.example.invalid",
                    port: 3_128
                )
            )
            XCTFail("部分成功不应显示为全部保存")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .partialFailure)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("proxy.settings.partial")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.proxy?.isEnabled, true)
        XCTAssertEqual(model.proxy?.host, "")
    }

    func test互联网代理未确认时提示先读取且不建议立即重试() async {
        let repository = NasAdministrationRepositoryStub(
            proxyUpdateStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.network)

        do {
            try await model.saveProxy(
                NasProxySettings(
                    isEnabled: true,
                    host: "proxy.example.invalid",
                    port: 3_128
                )
            )
            XCTFail("未确认结果不应显示为保存成功")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("proxy.settings.unverified")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.proxy?.isEnabled, false)
    }

    func test互联网代理反馈覆盖权限和不支持状态() {
        XCTAssertEqual(
            NasSettingsModel.proxySettingsFeedback(for: .permissionDenied),
            NasSettingsModel.ProxySettingsFeedback(
                resourceKey: "proxy.settings.permission-denied",
                category: .permissionDenied
            )
        )
        XCTAssertEqual(
            NasSettingsModel.proxySettingsFeedback(for: .unsupported),
            NasSettingsModel.ProxySettingsFeedback(
                resourceKey: "proxy.settings.unsupported",
                category: .apiUnavailable
            )
        )
    }

    func test区域与时间设置确认成功后刷新模型状态() async throws {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.region)
        let expected = regionUpdate

        try await model.saveRegion(expected)

        XCTAssertEqual(model.region, expected)
        XCTAssertFalse(model.isSavingServiceSettings)
    }

    func test区域与时间部分成功时刷新并提示重新连接核对() async {
        let repository = NasAdministrationRepositoryStub(
            regionUpdateStatus: .partialSuccess
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.region)

        do {
            try await model.saveRegion(regionUpdate)
            XCTFail("部分成功不应显示为全部保存")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .partialFailure)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("region.settings.partial")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.region?.dateFormat, "Y/m/d")
        XCTAssertEqual(model.region?.timeZone, "Asia/Shanghai")
    }

    func test区域与时间未确认时提示重连且禁止立即重试() async {
        let repository = NasAdministrationRepositoryStub(
            regionUpdateStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.region)

        do {
            try await model.saveRegion(regionUpdate)
            XCTFail("未确认结果不应显示为保存成功")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("region.settings.unverified")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.region?.timeZone, "Asia/Shanghai")
    }

    func test区域与时间反馈覆盖权限和不支持状态() {
        XCTAssertEqual(
            NasSettingsModel.regionSettingsFeedback(for: .permissionDenied),
            NasSettingsModel.RegionSettingsFeedback(
                resourceKey: "region.settings.permission-denied",
                category: .permissionDenied
            )
        )
        XCTAssertEqual(
            NasSettingsModel.regionSettingsFeedback(for: .unsupported),
            NasSettingsModel.RegionSettingsFeedback(
                resourceKey: "region.settings.unsupported",
                category: .apiUnavailable
            )
        )
    }

    func testDDNS连接测试与保存分别确认结果() async throws {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.ddns)

        let testResult = try await model.testDDNS(ddnsDraft)
        try await model.saveDDNS(ddnsDraft)

        XCTAssertEqual(testResult.status, .confirmedSuccess)
        XCTAssertEqual(model.ddns?.records.first?.hostname, "nas.example.invalid")
        XCTAssertTrue(model.ddnsOperationIDs.isEmpty)
    }

    func testDDNS保存未确认时保留当前列表并禁止立即重试提示() async {
        let repository = NasAdministrationRepositoryStub(
            ddnsSaveStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.ddns)

        do {
            try await model.saveDDNS(ddnsDraft)
            XCTFail("未确认的 DDNS 保存不应显示为成功")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("ddns.save.unverified")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertTrue(model.ddns?.records.isEmpty == true)
    }

    func testDDNS删除未确认时刷新后仍保留记录() async {
        let record = ddnsRecord
        let repository = NasAdministrationRepositoryStub(
            ddnsRecords: [record],
            ddnsDeleteStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.ddns)

        do {
            try await model.deleteDDNS(record)
            XCTFail("未确认的 DDNS 删除不应显示为成功")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("ddns.delete.unverified")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.ddns?.records.map(\.providerID), ["Example"])
    }

    func testDDNS立即更新与连接测试覆盖权限和不支持反馈() async {
        let permissionRepository = NasAdministrationRepositoryStub(
            ddnsRecords: [ddnsRecord],
            ddnsRefreshStatus: .permissionDenied
        )
        let permissionModel = NasSettingsModel(repository: permissionRepository)
        permissionModel.setModuleEnabled(true)
        await permissionModel.activate(.ddns)
        do {
            try await permissionModel.refreshDDNS()
            XCTFail("权限不足不应显示为地址更新成功")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .permissionDenied)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("ddns.operation.permission-denied")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }

        let unsupportedRepository = NasAdministrationRepositoryStub(
            ddnsTestStatus: .unsupported
        )
        let unsupportedModel = NasSettingsModel(repository: unsupportedRepository)
        unsupportedModel.setModuleEnabled(true)
        await unsupportedModel.activate(.ddns)
        do {
            _ = try await unsupportedModel.testDDNS(ddnsDraft)
            XCTFail("不支持的连接测试不应显示为成功")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .apiUnavailable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("ddns.operation.unsupported")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
    }

    func testNAS电源动作保留Repository结果且结束后释放忙碌状态() async throws {
        let repository = NasAdministrationRepositoryStub(
            powerActionStatus: .confirmedSuccess
        )
        let model = NasSettingsModel(repository: repository)

        let shutdown = try await model.performPowerAction(.shutdown)
        let reboot = try await model.performPowerAction(.reboot)

        XCTAssertEqual(shutdown.status, .confirmedSuccess)
        XCTAssertEqual(shutdown.operation, "nasShutdown")
        XCTAssertEqual(shutdown.localizationKey, "power.shutdown.accepted")
        XCTAssertEqual(reboot.operation, "nasReboot")
        XCTAssertEqual(reboot.localizationKey, "power.reboot.accepted")
        XCTAssertFalse(model.isPerformingPowerAction)
        let requestCount = await repository.powerActionRequestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testNAS电源动作未确认结果不会被模型改写为成功() async throws {
        let repository = NasAdministrationRepositoryStub(
            powerActionStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)

        let result = try await model.performPowerAction(.reboot)

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.submitted)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.localizationKey, "power.action.unverified")
        XCTAssertFalse(model.isPerformingPowerAction)
    }

    func testNAS电源动作模型阻止并发重复提交() async throws {
        let repository = NasAdministrationRepositoryStub(
            delayNanoseconds: 50_000_000
        )
        let model = NasSettingsModel(repository: repository)
        let firstTask = Task {
            try await model.performPowerAction(.shutdown)
        }
        while !model.isPerformingPowerAction {
            await Task.yield()
        }

        do {
            _ = try await model.performPowerAction(.reboot)
            XCTFail("并发电源请求应在模型层被拒绝")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .serverBusy)
            XCTAssertTrue(error.isRetryable)
        }

        _ = try await firstTask.value
        XCTAssertFalse(model.isPerformingPowerAction)
        let requestCount = await repository.powerActionRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func test硬件设置确认成功后刷新模型状态() async throws {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.hardware)
        let expected = hardwareUpdate

        try await model.saveHardware(expected)

        XCTAssertEqual(model.hardware, expected)
        XCTAssertFalse(model.isSavingServiceSettings)
    }

    func test硬件设置部分成功时刷新并提示逐项核对() async {
        let repository = NasAdministrationRepositoryStub(
            hardwareUpdateStatus: .partialSuccess
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.hardware)

        do {
            try await model.saveHardware(hardwareUpdate)
            XCTFail("部分成功不应显示为全部保存")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .partialFailure)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("hardware.settings.partial")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.hardware?.restartsAfterPowerFailure, true)
        XCTAssertEqual(model.hardware?.fanMode, "quietfan")
    }

    func test硬件设置未确认时提示先读取且不建议立即重试() async {
        let repository = NasAdministrationRepositoryStub(
            hardwareUpdateStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.hardware)

        do {
            try await model.saveHardware(hardwareUpdate)
            XCTFail("未确认结果不应显示为保存成功")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("hardware.settings.unverified")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.hardware?.restartsAfterPowerFailure, false)
        XCTAssertEqual(model.hardware?.fanMode, "quietfan")
    }

    func test硬件设置反馈覆盖权限和不支持状态() {
        XCTAssertEqual(
            NasSettingsModel.hardwareSettingsFeedback(for: .permissionDenied),
            NasSettingsModel.HardwareSettingsFeedback(
                resourceKey: "hardware.settings.permission-denied",
                category: .permissionDenied
            )
        )
        XCTAssertEqual(
            NasSettingsModel.hardwareSettingsFeedback(for: .unsupported),
            NasSettingsModel.HardwareSettingsFeedback(
                resourceKey: "hardware.settings.unsupported",
                category: .apiUnavailable
            )
        )
    }

    func test远程访问设置确认成功后刷新模型状态() async throws {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.remoteAccess)
        let expected = remoteAccessUpdate

        try await model.saveRemoteAccess(expected)

        XCTAssertEqual(model.remoteAccess, expected)
        XCTAssertFalse(model.isSavingServiceSettings)
    }

    func test远程访问部分成功时刷新并提示重新连接核对() async {
        let repository = NasAdministrationRepositoryStub(
            remoteAccessUpdateStatus: .partialSuccess
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.remoteAccess)

        do {
            try await model.saveRemoteAccess(remoteAccessUpdate)
            XCTFail("部分成功不应显示为全部保存")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .partialFailure)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("remote-access.settings.partial")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.remoteAccess?.isRelayEnabled, false)
        XCTAssertEqual(model.remoteAccess?.isRouterConfigurationEnabled, false)
    }

    func test远程访问未确认时提示重连且禁止立即重试() async {
        let repository = NasAdministrationRepositoryStub(
            remoteAccessUpdateStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.remoteAccess)

        do {
            try await model.saveRemoteAccess(remoteAccessUpdate)
            XCTFail("未确认结果不应显示为保存成功")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("remote-access.settings.unverified")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.remoteAccess?.isRelayEnabled, true)
        XCTAssertEqual(model.remoteAccess?.isRouterConfigurationEnabled, false)
    }

    func test远程访问反馈覆盖权限和不支持状态() {
        XCTAssertEqual(
            NasSettingsModel.remoteAccessSettingsFeedback(for: .permissionDenied),
            NasSettingsModel.RemoteAccessSettingsFeedback(
                resourceKey: "remote-access.settings.permission-denied",
                category: .permissionDenied
            )
        )
        XCTAssertEqual(
            NasSettingsModel.remoteAccessSettingsFeedback(for: .unsupported),
            NasSettingsModel.RemoteAccessSettingsFeedback(
                resourceKey: "remote-access.settings.unsupported",
                category: .apiUnavailable
            )
        )
    }

    func test安全设置确认成功后刷新模型状态() async throws {
        let repository = NasAdministrationRepositoryStub()
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.security)
        let expected = securityUpdate

        try await model.saveSecurity(expected)

        XCTAssertEqual(model.security, expected)
        XCTAssertFalse(model.isSavingServiceSettings)
    }

    func test安全设置部分成功时刷新并提示逐项核对() async {
        let repository = NasAdministrationRepositoryStub(
            securityUpdateStatus: .partialSuccess
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.security)

        do {
            try await model.saveSecurity(securityUpdate)
            XCTFail("部分成功不应显示为全部保存")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .partialFailure)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("security.settings.partial")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
        XCTAssertEqual(model.security?.isAutoBlockEnabled, true)
        XCTAssertEqual(model.security?.isPortScanProtectionEnabled, false)
    }

    func test安全设置未确认时提示先回读且不建议立即重试() async {
        let repository = NasAdministrationRepositoryStub(
            securityUpdateStatus: .submittedButUnverified
        )
        let model = NasSettingsModel(repository: repository)
        model.setModuleEnabled(true)
        await model.activate(.security)

        do {
            try await model.saveSecurity(securityUpdate)
            XCTFail("未确认结果不应显示为保存成功")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .unknown)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.safeUserMessage,
                L10n.string("security.settings.unverified")
            )
        } catch {
            XCTFail("返回了非统一错误：\(error)")
        }
    }

    func test安全设置权限与不支持反馈映射() {
        XCTAssertEqual(
            NasSettingsModel.securitySettingsFeedback(for: .permissionDenied),
            NasSettingsModel.SecuritySettingsFeedback(
                resourceKey: "security.settings.permission-denied",
                category: .permissionDenied
            )
        )
        XCTAssertEqual(
            NasSettingsModel.securitySettingsFeedback(for: .unsupported),
            NasSettingsModel.SecuritySettingsFeedback(
                resourceKey: "security.settings.unsupported",
                category: .apiUnavailable
            )
        )
    }

    private func package(
        status: String,
        canStart: Bool,
        canStop: Bool,
        canUninstall: Bool,
        isUpgradeAvailable: Bool = false,
        canUpgrade: Bool = false
    ) -> NasPackage {
        NasPackage(
            id: "Example",
            name: "示例套件",
            version: "1.0",
            status: status,
            statusDescription: nil,
            packageDescription: nil,
            installType: canUninstall ? "user" : "system",
            installedAt: nil,
            canStart: canStart,
            canStop: canStop,
            canUninstall: canUninstall,
            isUpgradeAvailable: isUpgradeAvailable,
            canUpgrade: canUpgrade
        )
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

    private var securityUpdate: NasSecuritySettings {
        NasSecuritySettings(
            isAutoBlockEnabled: true,
            failedAttempts: 5,
            withinMinutes: 10,
            expirationDays: 7,
            isFirewallEnabled: false,
            firewallProfileName: "synthetic-profile",
            isPortScanProtectionEnabled: true
        )
    }

    private var fileServiceUpdate: NasFileServiceSettings {
        NasFileServiceSettings(
            isSMBEnabled: true,
            isNFSEnabled: true,
            isFTPEnabled: true,
            isFTPSEnabled: true,
            ftpPort: 2_121,
            isSFTPEnabled: true,
            sftpPort: 2_222,
            isSSDPEnabled: true,
            isBonjourEnabled: true,
            isSMBTimeMachineEnabled: true
        )
    }

    private var terminalUpdate: NasTerminalSettings {
        NasTerminalSettings(
            isSSHEnabled: true,
            isTelnetEnabled: true,
            sshPort: 2_222
        )
    }

    private var regionUpdate: NasRegionSettings {
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
    }

    private var ddnsDraft: NasDDNSDraft {
        NasDDNSDraft(
            providerID: "Example",
            hostname: "nas.example.invalid",
            username: "synthetic-owner",
            password: "SYNTHETIC_EPHEMERAL_SECRET"
        )
    }

    private var ddnsRecord: NasDDNSRecord {
        NasDDNSRecord(
            id: "Example",
            providerID: "Example",
            providerName: "Synthetic Provider",
            hostname: "nas.example.invalid",
            address: "192.0.2.10",
            status: "service_ddns_normal",
            lastUpdated: nil,
            isEnabled: true,
            username: "synthetic-owner",
            networkType: "auto",
            ipv4: "192.0.2.10",
            ipv6: nil,
            interfaceV4: nil,
            interfaceV6: nil,
            heartbeat: false
        )
    }

    private var hardwareUpdate: NasHardwareSettings {
        NasHardwareSettings(
            restartsAfterPowerFailure: true,
            ledBrightness: 5,
            ledBrightnessRange: 0...7,
            fanMode: "coolfan"
        )
    }

    private var remoteAccessUpdate: NasRemoteAccessSettings {
        NasRemoteAccessSettings(
            isRelayEnabled: false,
            isRouterConfigurationEnabled: true,
            canDisableRelay: true
        )
    }
}

private actor ShareAccessRepositoryStub: NasShareAccessRepository {
    private let directory: NasShareAccessDirectory
    private var requests = 0

    init(directory: NasShareAccessDirectory) {
        self.directory = directory
    }

    func loadShareAccess() async throws -> NasShareAccessDirectory {
        requests += 1
        return directory
    }

    func requestCount() -> Int {
        requests
    }
}

// 同一合成数据源供模型回归和页面绘制使用，不连接真实 NAS。
actor NasAdministrationRepositoryStub: NasSettingsRepository {
    private var systemRequests = 0
    private var packageControlRequests = 0
    private var diskTestRequests = 0
    private var powerActionRequests = 0
    private var diskTestStatus = NasDiskTestStatus(diskID: "disk1", isRunning: false)
    private let diskTestStartStatus: MutationResultStatus
    private let diskTestStopStatus: MutationResultStatus
    private var packages: [NasPackage]
    private let packageControlStatus: MutationResultStatus
    private let packageUninstallStatus: MutationResultStatus
    private var accountDirectory = NasAccountDirectory(
        users: [
            NasAccount(
                id: "user:user",
                name: "user",
                kind: .user,
                numericID: 1,
                description: nil,
                canDelete: true
            )
        ],
        groups: []
    )
    private let accountDeleteStatus: MutationResultStatus
    private var ethernetInterfaces = [
        NasEthernetInterface(
            id: "eth0",
            displayName: "局域网 1",
            status: "connected",
            usesDHCP: true,
            address: "192.0.2.10",
            subnetMask: "255.255.255.0",
            gateway: "192.0.2.1",
            dnsServers: "192.0.2.1",
            isDefaultGateway: true,
            mtu: 1_500,
            isVLANEnabled: false,
            vlanID: nil
        )
    ]
    private let ethernetUpdateStatus: MutationResultStatus
    private var securitySettings = NasSecuritySettings(
        isAutoBlockEnabled: false,
        failedAttempts: 10,
        withinMinutes: 5,
        expirationDays: nil,
        isFirewallEnabled: true,
        firewallProfileName: "synthetic-profile",
        isPortScanProtectionEnabled: false
    )
    private var hardwareSettings = NasHardwareSettings(
        restartsAfterPowerFailure: false,
        ledBrightness: 3,
        ledBrightnessRange: 0...7,
        fanMode: "quietfan"
    )
    private var remoteAccessSettings = NasRemoteAccessSettings(
        isRelayEnabled: true,
        isRouterConfigurationEnabled: false,
        canDisableRelay: true
    )
    private let securityUpdateStatus: MutationResultStatus
    private var fileServiceSettings = NasFileServiceSettings(
        isSMBEnabled: false,
        isNFSEnabled: false,
        isFTPEnabled: false,
        isFTPSEnabled: false,
        ftpPort: 21,
        isSFTPEnabled: false,
        sftpPort: 22,
        isSSDPEnabled: false,
        isBonjourEnabled: false,
        isSMBTimeMachineEnabled: false
    )
    private let fileServiceUpdateStatus: MutationResultStatus
    private var terminalSettings = NasTerminalSettings(
        isSSHEnabled: false,
        isTelnetEnabled: false,
        sshPort: 22
    )
    private let terminalUpdateStatus: MutationResultStatus
    private var proxySettings = NasProxySettings(
        isEnabled: false,
        host: "",
        port: 3_128
    )
    private let proxyUpdateStatus: MutationResultStatus
    private var regionSettings = NasRegionSettings(
        dateFormat: "Y-m-d",
        timeFormat: "H:i",
        timeZone: "Asia/Shanghai",
        isNetworkTimeEnabled: false,
        timeServers: [],
        manualDate: Date(timeIntervalSince1970: 0),
        timeZones: [
            NasTimeZoneOption(id: "Asia/Shanghai", displayName: "北京、上海"),
            NasTimeZoneOption(id: "UTC", displayName: "协调世界时")
        ]
    )
    private let regionUpdateStatus: MutationResultStatus
    private var ddnsDirectory: NasDDNSDirectory
    private let ddnsTestStatus: MutationResultStatus
    private let ddnsSaveStatus: MutationResultStatus
    private let ddnsDeleteStatus: MutationResultStatus
    private let ddnsRefreshStatus: MutationResultStatus
    private let powerActionStatus: MutationResultStatus
    private let hardwareUpdateStatus: MutationResultStatus
    private let remoteAccessUpdateStatus: MutationResultStatus
    private let delayNanoseconds: UInt64

    init(
        delayNanoseconds: UInt64 = 0,
        packages: [NasPackage] = [],
        packageControlStatus: MutationResultStatus = .confirmedSuccess,
        packageUninstallStatus: MutationResultStatus = .confirmedSuccess,
        accountDeleteStatus: MutationResultStatus = .confirmedSuccess,
        ethernetUpdateStatus: MutationResultStatus = .confirmedSuccess,
        securityUpdateStatus: MutationResultStatus = .confirmedSuccess,
        fileServiceUpdateStatus: MutationResultStatus = .confirmedSuccess,
        terminalUpdateStatus: MutationResultStatus = .confirmedSuccess,
        proxyUpdateStatus: MutationResultStatus = .confirmedSuccess,
        regionUpdateStatus: MutationResultStatus = .confirmedSuccess,
        ddnsRecords: [NasDDNSRecord] = [],
        ddnsTestStatus: MutationResultStatus = .confirmedSuccess,
        ddnsSaveStatus: MutationResultStatus = .confirmedSuccess,
        ddnsDeleteStatus: MutationResultStatus = .confirmedSuccess,
        ddnsRefreshStatus: MutationResultStatus = .confirmedSuccess,
        powerActionStatus: MutationResultStatus = .confirmedSuccess,
        hardwareUpdateStatus: MutationResultStatus = .confirmedSuccess,
        remoteAccessUpdateStatus: MutationResultStatus = .confirmedSuccess,
        diskTestStartStatus: MutationResultStatus = .confirmedSuccess,
        diskTestStopStatus: MutationResultStatus = .confirmedSuccess
    ) {
        self.delayNanoseconds = delayNanoseconds
        self.packages = packages
        self.packageControlStatus = packageControlStatus
        self.packageUninstallStatus = packageUninstallStatus
        self.accountDeleteStatus = accountDeleteStatus
        self.ethernetUpdateStatus = ethernetUpdateStatus
        self.securityUpdateStatus = securityUpdateStatus
        self.fileServiceUpdateStatus = fileServiceUpdateStatus
        self.terminalUpdateStatus = terminalUpdateStatus
        self.proxyUpdateStatus = proxyUpdateStatus
        self.regionUpdateStatus = regionUpdateStatus
        ddnsDirectory = NasDDNSDirectory(
            providers: [
                NasDDNSProvider(id: "Example", displayName: "Synthetic Provider")
            ],
            records: ddnsRecords
        )
        self.ddnsTestStatus = ddnsTestStatus
        self.ddnsSaveStatus = ddnsSaveStatus
        self.ddnsDeleteStatus = ddnsDeleteStatus
        self.ddnsRefreshStatus = ddnsRefreshStatus
        self.powerActionStatus = powerActionStatus
        self.hardwareUpdateStatus = hardwareUpdateStatus
        self.remoteAccessUpdateStatus = remoteAccessUpdateStatus
        self.diskTestStartStatus = diskTestStartStatus
        self.diskTestStopStatus = diskTestStopStatus
    }

    func systemRequestCount() -> Int { systemRequests }
    func packageControlRequestCount() -> Int { packageControlRequests }
    func diskTestRequestCount() -> Int { diskTestRequests }
    func powerActionRequestCount() -> Int { powerActionRequests }

    func loadSystemOverview() async throws -> NasSystemOverview {
        systemRequests += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return NasSystemOverview(serverName: "测试 NAS", model: "DS")
    }

    func loadPerformanceSnapshot() async throws -> NasPerformanceSnapshot {
        NasPerformanceSnapshot(
            recordedAt: Date(timeIntervalSince1970: 1),
            cpuUsage: 25,
            cpuUserUsage: 15,
            cpuSystemUsage: 8,
            cpuOtherUsage: 2,
            memoryUsage: 50,
            swapUsage: 0,
            networkReceivedBytesPerSecond: 1_024,
            networkSentBytesPerSecond: 2_048,
            diskReadBytesPerSecond: 4_096,
            diskWriteBytesPerSecond: 8_192,
            volumeReadBytesPerSecond: 4_096,
            volumeWriteBytesPerSecond: 8_192,
            diskUtilization: 10,
            nfsReadOperationsPerSecond: 0,
            nfsWriteOperationsPerSecond: 0
        )
    }

    func performPowerActionResult(
        _ action: NasPowerAction
    ) async throws -> MutationResult {
        powerActionRequests += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let unknown = powerActionStatus == .submittedButUnverified
            || powerActionStatus == .cancellationRequestedAfterSubmission
        let submitted = ![
            .cancelledBeforeSubmission,
            .permissionDenied,
            .unsupported
        ].contains(powerActionStatus)
        let localizationKey: String = switch powerActionStatus {
        case .confirmedSuccess:
            action == .shutdown
                ? "power.shutdown.accepted"
                : "power.reboot.accepted"
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            "power.action.unverified"
        case .cancelledBeforeSubmission:
            "power.action.cancelled"
        case .permissionDenied:
            "power.action.permission-denied"
        case .unsupported:
            "power.action.unsupported"
        case .confirmedFailure, .partialSuccess:
            "power.action.rejected"
        }
        return try MutationResult(
            status: powerActionStatus,
            operation: action == .shutdown ? "nasShutdown" : "nasReboot",
            submitted: submitted,
            requiresRefresh: unknown || powerActionStatus == .partialSuccess,
            counts: MutationResultCounts(
                succeeded: powerActionStatus == .confirmedSuccess
                    || powerActionStatus == .partialSuccess ? 1 : 0,
                failed: powerActionStatus == .confirmedFailure
                    || powerActionStatus == .permissionDenied
                    || powerActionStatus == .unsupported
                    || powerActionStatus == .partialSuccess ? 1 : 0,
                unknown: unknown ? 1 : 0
            ),
            localizationKey: localizationKey,
            diagnosticTag: "power.action.test"
        )
    }

    func loadStorage() async throws -> NasStorageSnapshot {
        NasStorageSnapshot(
            overallStatus: "normal",
            disks: [
                NasDisk(
                    id: "disk1",
                    name: "硬盘 1",
                    model: "MODEL",
                    type: "HDD",
                    totalBytes: 1_000,
                    status: "normal",
                    smartStatus: "normal",
                    temperatureCelsius: 35,
                    isSSD: false,
                    usedBy: nil,
                    supportsSmartTest: true
                )
            ],
            pools: [],
            volumes: []
        )
    }

    func loadDiskTestStatus(diskID: String) async throws -> NasDiskTestStatus {
        diskTestStatus
    }

    func startDiskTest(
        diskID: String,
        type: NasDiskTestType
    ) async throws -> NasDiskTestStatus {
        diskTestRequests += 1
        diskTestStatus = NasDiskTestStatus(
            diskID: diskID,
            isRunning: true,
            runningType: type,
            progressDescription: "已开始"
        )
        return diskTestStatus
    }

    func stopDiskTest(diskID: String) async throws -> NasDiskTestStatus {
        diskTestRequests += 1
        diskTestStatus = NasDiskTestStatus(diskID: diskID, isRunning: false)
        return diskTestStatus
    }

    func startDiskTestResult(
        diskID: String,
        type: NasDiskTestType
    ) async throws -> MutationResult {
        diskTestRequests += 1
        if diskTestStartStatus == .confirmedSuccess {
            diskTestStatus = NasDiskTestStatus(
                diskID: diskID,
                isRunning: true,
                runningType: type,
                progressDescription: "已开始"
            )
        }
        return try diskMutationResult(
            status: diskTestStartStatus,
            operation: "diskTestStart",
            prefix: "storage.disk-test.start"
        )
    }

    func stopDiskTestResult(diskID: String) async throws -> MutationResult {
        diskTestRequests += 1
        if diskTestStopStatus == .confirmedSuccess {
            diskTestStatus = NasDiskTestStatus(diskID: diskID, isRunning: false)
        }
        return try diskMutationResult(
            status: diskTestStopStatus,
            operation: "diskTestStop",
            prefix: "storage.disk-test.stop"
        )
    }

    private func diskMutationResult(
        status: MutationResultStatus,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        let isUnknown = status == .submittedButUnverified
            || status == .cancellationRequestedAfterSubmission
        let isPartial = status == .partialSuccess
        let submitted = status != .cancelledBeforeSubmission
            && status != .permissionDenied
            && status != .unsupported
        return try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: isUnknown || isPartial,
            counts: MutationResultCounts(
                succeeded: status == .confirmedSuccess || isPartial ? 1 : 0,
                failed: isPartial
                    || status == .permissionDenied
                    || status == .unsupported
                    || status == .confirmedFailure ? 1 : 0,
                unknown: isUnknown ? 1 : 0
            ),
            localizationKey: isUnknown ? "\(prefix).unverified" : nil,
            diagnosticTag: "\(prefix).test"
        )
    }

    func loadPackages() async throws -> [NasPackage] { packages }
    func loadScheduledTasks() async throws -> [NasScheduledTask] { [] }

    func loadAccountsAndGroups() async throws -> NasAccountDirectory {
        accountDirectory
    }

    func deleteAccountResult(name: String) async throws -> MutationResult {
        if accountDeleteStatus == .confirmedSuccess {
            accountDirectory = NasAccountDirectory(
                users: accountDirectory.users.filter { $0.name != name },
                groups: accountDirectory.groups
            )
        }
        return try deletionResult(
            status: accountDeleteStatus,
            operation: "accountDelete",
            prefix: "account.delete"
        )
    }

    func loadLogs(offset: Int, limit: Int) async throws -> NasLogPage {
        NasLogPage(entries: [], total: 0, infoCount: 0, warningCount: 0, errorCount: 0)
    }

    func loadSystemProcesses(
        start: Int,
        limit: Int
    ) async throws -> NasProcessDirectory {
        NasProcessDirectory(
            processes: [
                NasSystemProcess(
                    id: "process:7",
                    processID: "7",
                    name: "service-worker",
                    status: "running",
                    groupID: "example-service"
                )
            ],
            groups: [
                NasProcessGroup(
                    id: "example-service",
                    name: "Example Service",
                    status: "running",
                    processCount: 1
                )
            ],
            total: 1,
            isTruncated: false,
            groupsAreUnavailable: false
        )
    }

    func loadPowerSchedule() async throws -> NasPowerScheduleSnapshot {
        NasPowerScheduleSnapshot(
            entries: [
                NasPowerScheduleEntry(
                    id: "synthetic-schedule",
                    action: .startup,
                    isEnabled: true,
                    hour: 7,
                    minute: 30,
                    recurrence: .weekly([.monday, .wednesday, .friday])
                )
            ],
            timeZoneIdentifier: "Asia/Shanghai",
            total: 1,
            isTruncated: false
        )
    }

    func loadExternalStorage() async throws -> NasExternalStorageDirectory {
        NasExternalStorageDirectory(
            devices: [
                NasExternalStorageDevice(
                    id: "usb:synthetic",
                    displayName: "Synthetic USB",
                    connection: .usb,
                    status: .ready,
                    capacityBytes: 1_000_000_000,
                    usedBytes: 250_000_000
                )
            ],
            total: 1,
            isTruncated: false,
            unavailableConnections: [.eSATA]
        )
    }

    func loadZRAM() async throws -> NasZRAMSnapshot {
        NasZRAMSnapshot(
            isEnabled: true,
            configuredBytes: 1_073_741_824,
            algorithm: .lz4
        )
    }

    func loadConnections(offset: Int, limit: Int) async throws -> NasConnectionPage {
        NasConnectionPage(connections: [], total: 0)
    }

    func loadEthernetInterfaces() async throws -> [NasEthernetInterface] {
        ethernetInterfaces
    }

    func loadFileServiceSettings() async throws -> NasFileServiceSettings {
        fileServiceSettings
    }

    func saveFileServiceSettingsResult(
        _ settings: NasFileServiceSettings
    ) async throws -> MutationResult {
        switch fileServiceUpdateStatus {
        case .confirmedSuccess:
            fileServiceSettings = settings
        case .partialSuccess:
            fileServiceSettings.isSMBEnabled = settings.isSMBEnabled
        default:
            break
        }
        let isUnknown = fileServiceUpdateStatus == .submittedButUnverified
            || fileServiceUpdateStatus == .cancellationRequestedAfterSubmission
        let isPartial = fileServiceUpdateStatus == .partialSuccess
        let submitted = fileServiceUpdateStatus != .cancelledBeforeSubmission
            && fileServiceUpdateStatus != .permissionDenied
            && fileServiceUpdateStatus != .unsupported
        return try MutationResult(
            status: fileServiceUpdateStatus,
            operation: "fileServiceSettingsUpdate",
            submitted: submitted,
            requiresRefresh: isUnknown || isPartial,
            counts: MutationResultCounts(
                succeeded: fileServiceUpdateStatus == .confirmedSuccess
                    || isPartial ? 1 : 0,
                failed: isPartial
                    || fileServiceUpdateStatus == .permissionDenied
                    || fileServiceUpdateStatus == .unsupported
                    || fileServiceUpdateStatus == .confirmedFailure ? 1 : 0,
                unknown: isUnknown ? 1 : 0
            ),
            localizationKey: isPartial
                ? "file-services.settings.partial"
                : (isUnknown ? "file-services.settings.unverified" : nil),
            diagnosticTag: "file-services.settings.test"
        )
    }

    func loadTerminalSettings() async throws -> NasTerminalSettings {
        terminalSettings
    }

    func saveTerminalSettingsResult(
        _ settings: NasTerminalSettings
    ) async throws -> MutationResult {
        switch terminalUpdateStatus {
        case .confirmedSuccess:
            terminalSettings = settings
        case .partialSuccess:
            terminalSettings.isSSHEnabled = settings.isSSHEnabled
        default:
            break
        }
        let isUnknown = terminalUpdateStatus == .submittedButUnverified
            || terminalUpdateStatus == .cancellationRequestedAfterSubmission
        let isPartial = terminalUpdateStatus == .partialSuccess
        let submitted = terminalUpdateStatus != .cancelledBeforeSubmission
            && terminalUpdateStatus != .permissionDenied
            && terminalUpdateStatus != .unsupported
        return try MutationResult(
            status: terminalUpdateStatus,
            operation: "terminalSettingsUpdate",
            submitted: submitted,
            requiresRefresh: isUnknown || isPartial,
            counts: MutationResultCounts(
                succeeded: terminalUpdateStatus == .confirmedSuccess
                    || isPartial ? 1 : 0,
                failed: isPartial
                    || terminalUpdateStatus == .permissionDenied
                    || terminalUpdateStatus == .unsupported
                    || terminalUpdateStatus == .confirmedFailure ? 1 : 0,
                unknown: isUnknown ? 1 : 0
            ),
            localizationKey: isPartial
                ? "terminal.settings.partial"
                : (isUnknown ? "terminal.settings.unverified" : nil),
            diagnosticTag: "terminal.settings.test"
        )
    }

    func loadProxySettings() async throws -> NasProxySettings {
        proxySettings
    }

    func saveProxySettingsResult(
        _ settings: NasProxySettings
    ) async throws -> MutationResult {
        switch proxyUpdateStatus {
        case .confirmedSuccess:
            proxySettings = settings
        case .partialSuccess:
            proxySettings.isEnabled = settings.isEnabled
        default:
            break
        }
        let isUnknown = proxyUpdateStatus == .submittedButUnverified
            || proxyUpdateStatus == .cancellationRequestedAfterSubmission
        let isPartial = proxyUpdateStatus == .partialSuccess
        let submitted = proxyUpdateStatus != .cancelledBeforeSubmission
            && proxyUpdateStatus != .permissionDenied
            && proxyUpdateStatus != .unsupported
        return try MutationResult(
            status: proxyUpdateStatus,
            operation: "proxySettingsUpdate",
            submitted: submitted,
            requiresRefresh: isUnknown || isPartial,
            counts: MutationResultCounts(
                succeeded: proxyUpdateStatus == .confirmedSuccess
                    || isPartial ? 1 : 0,
                failed: isPartial
                    || proxyUpdateStatus == .permissionDenied
                    || proxyUpdateStatus == .unsupported
                    || proxyUpdateStatus == .confirmedFailure ? 1 : 0,
                unknown: isUnknown ? 1 : 0
            ),
            localizationKey: isPartial
                ? "proxy.settings.partial"
                : (isUnknown ? "proxy.settings.unverified" : nil),
            diagnosticTag: "proxy.settings.test"
        )
    }

    func loadRegionSettings() async throws -> NasRegionSettings {
        regionSettings
    }

    func saveRegionSettingsResult(
        _ settings: NasRegionSettings
    ) async throws -> MutationResult {
        switch regionUpdateStatus {
        case .confirmedSuccess:
            regionSettings = settings
        case .partialSuccess:
            regionSettings.dateFormat = settings.dateFormat
        default:
            break
        }
        let isUnknown = regionUpdateStatus == .submittedButUnverified
            || regionUpdateStatus == .cancellationRequestedAfterSubmission
        let isPartial = regionUpdateStatus == .partialSuccess
        let submitted = regionUpdateStatus != .cancelledBeforeSubmission
            && regionUpdateStatus != .permissionDenied
            && regionUpdateStatus != .unsupported
        return try MutationResult(
            status: regionUpdateStatus,
            operation: "regionSettingsUpdate",
            submitted: submitted,
            requiresRefresh: isUnknown || isPartial,
            counts: MutationResultCounts(
                succeeded: regionUpdateStatus == .confirmedSuccess
                    || isPartial ? 1 : 0,
                failed: isPartial
                    || regionUpdateStatus == .permissionDenied
                    || regionUpdateStatus == .unsupported
                    || regionUpdateStatus == .confirmedFailure ? 1 : 0,
                unknown: isUnknown ? 1 : 0
            ),
            localizationKey: isPartial
                ? "region.settings.partial"
                : (isUnknown ? "region.settings.unverified" : nil),
            diagnosticTag: "region.settings.test"
        )
    }

    func loadDDNS() async throws -> NasDDNSDirectory {
        ddnsDirectory
    }

    func testDDNSResult(_ draft: NasDDNSDraft) async throws -> MutationResult {
        try ddnsMutationResult(
            status: ddnsTestStatus,
            operation: "ddnsProviderTest",
            prefix: "ddns.test"
        )
    }

    func saveDDNSResult(_ draft: NasDDNSDraft) async throws -> MutationResult {
        if ddnsSaveStatus == .confirmedSuccess {
            let record = NasDDNSRecord(
                id: draft.normalizedProviderID,
                providerID: draft.normalizedProviderID,
                providerName: "Synthetic Provider",
                hostname: draft.normalizedHostname,
                address: nil,
                status: nil,
                lastUpdated: nil,
                isEnabled: draft.isEnabled,
                username: draft.normalizedUsername,
                networkType: draft.networkType,
                ipv4: draft.ipv4,
                ipv6: draft.ipv6,
                interfaceV4: draft.interfaceV4,
                interfaceV6: draft.interfaceV6,
                heartbeat: draft.heartbeat
            )
            ddnsDirectory = NasDDNSDirectory(
                providers: ddnsDirectory.providers,
                records: ddnsDirectory.records.filter {
                    $0.providerID != record.providerID
                } + [record]
            )
        }
        return try ddnsMutationResult(
            status: ddnsSaveStatus,
            operation: "ddnsRecordSave",
            prefix: "ddns.save"
        )
    }

    func deleteDDNSResult(providerID: String) async throws -> MutationResult {
        if ddnsDeleteStatus == .confirmedSuccess {
            ddnsDirectory = NasDDNSDirectory(
                providers: ddnsDirectory.providers,
                records: ddnsDirectory.records.filter {
                    $0.providerID != providerID
                }
            )
        }
        return try ddnsMutationResult(
            status: ddnsDeleteStatus,
            operation: "ddnsRecordDelete",
            prefix: "ddns.delete"
        )
    }

    func refreshDDNSResult() async throws -> MutationResult {
        try ddnsMutationResult(
            status: ddnsRefreshStatus,
            operation: "ddnsAddressRefresh",
            prefix: "ddns.refresh"
        )
    }

    private func ddnsMutationResult(
        status: MutationResultStatus,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        let unknown = status == .submittedButUnverified
            || status == .cancellationRequestedAfterSubmission
        let submitted = ![
            .cancelledBeforeSubmission,
            .permissionDenied,
            .unsupported
        ].contains(status)
        let localizationKey: String? = switch status {
        case .confirmedSuccess:
            "\(prefix).completed"
        case .confirmedFailure, .partialSuccess:
            "\(prefix).failed"
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            "\(prefix).unverified"
        case .cancelledBeforeSubmission:
            "\(prefix).cancelled"
        case .permissionDenied:
            "ddns.operation.permission-denied"
        case .unsupported:
            "ddns.operation.unsupported"
        }
        return try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: unknown || status == .partialSuccess,
            counts: MutationResultCounts(
                succeeded: status == .confirmedSuccess
                    || status == .partialSuccess ? 1 : 0,
                failed: status == .confirmedFailure
                    || status == .permissionDenied
                    || status == .unsupported
                    || status == .partialSuccess ? 1 : 0,
                unknown: unknown ? 1 : 0
            ),
            localizationKey: localizationKey,
            diagnosticTag: "\(prefix).test"
        )
    }

    func saveEthernetInterfaceResult(
        _ interface: NasEthernetInterface
    ) async throws -> MutationResult {
        if ethernetUpdateStatus == .confirmedSuccess {
            ethernetInterfaces = [interface]
        }
        return try deletionResult(
            status: ethernetUpdateStatus,
            operation: "ethernetUpdate",
            prefix: "network.ethernet"
        )
    }

    func loadHardwareSettings() async throws -> NasHardwareSettings {
        hardwareSettings
    }

    func saveHardwareSettingsResult(
        _ settings: NasHardwareSettings
    ) async throws -> MutationResult {
        switch hardwareUpdateStatus {
        case .confirmedSuccess:
            hardwareSettings = settings
        case .partialSuccess:
            hardwareSettings.restartsAfterPowerFailure =
                settings.restartsAfterPowerFailure
        default:
            break
        }
        let isUnknown = hardwareUpdateStatus == .submittedButUnverified
            || hardwareUpdateStatus == .cancellationRequestedAfterSubmission
        let isPartial = hardwareUpdateStatus == .partialSuccess
        let submitted = hardwareUpdateStatus != .cancelledBeforeSubmission
            && hardwareUpdateStatus != .permissionDenied
            && hardwareUpdateStatus != .unsupported
        return try MutationResult(
            status: hardwareUpdateStatus,
            operation: "hardwareSettingsUpdate",
            submitted: submitted,
            requiresRefresh: isUnknown || isPartial,
            counts: MutationResultCounts(
                succeeded: hardwareUpdateStatus == .confirmedSuccess || isPartial ? 1 : 0,
                failed: isPartial
                    || hardwareUpdateStatus == .permissionDenied
                    || hardwareUpdateStatus == .unsupported
                    || hardwareUpdateStatus == .confirmedFailure ? 1 : 0,
                unknown: isUnknown ? 1 : 0
            ),
            localizationKey: isPartial
                ? "hardware.settings.partial"
                : (isUnknown ? "hardware.settings.unverified" : nil),
            diagnosticTag: "hardware.settings.test"
        )
    }

    func loadRemoteAccessSettings() async throws -> NasRemoteAccessSettings {
        remoteAccessSettings
    }

    func saveRemoteAccessSettingsResult(
        _ settings: NasRemoteAccessSettings
    ) async throws -> MutationResult {
        switch remoteAccessUpdateStatus {
        case .confirmedSuccess:
            remoteAccessSettings = settings
        case .partialSuccess:
            remoteAccessSettings.isRelayEnabled = settings.isRelayEnabled
        default:
            break
        }
        let isUnknown = remoteAccessUpdateStatus == .submittedButUnverified
            || remoteAccessUpdateStatus == .cancellationRequestedAfterSubmission
        let isPartial = remoteAccessUpdateStatus == .partialSuccess
        let submitted = remoteAccessUpdateStatus != .cancelledBeforeSubmission
            && remoteAccessUpdateStatus != .permissionDenied
            && remoteAccessUpdateStatus != .unsupported
        return try MutationResult(
            status: remoteAccessUpdateStatus,
            operation: "remoteAccessSettingsUpdate",
            submitted: submitted,
            requiresRefresh: isUnknown || isPartial,
            counts: MutationResultCounts(
                succeeded: remoteAccessUpdateStatus == .confirmedSuccess || isPartial ? 1 : 0,
                failed: isPartial
                    || remoteAccessUpdateStatus == .permissionDenied
                    || remoteAccessUpdateStatus == .unsupported
                    || remoteAccessUpdateStatus == .confirmedFailure ? 1 : 0,
                unknown: isUnknown ? 1 : 0
            ),
            localizationKey: isPartial
                ? "remote-access.settings.partial"
                : (isUnknown ? "remote-access.settings.unverified" : nil),
            diagnosticTag: "remote-access.settings.test"
        )
    }

    func loadSecuritySettings() async throws -> NasSecuritySettings {
        securitySettings
    }

    func saveSecuritySettingsResult(
        _ settings: NasSecuritySettings
    ) async throws -> MutationResult {
        switch securityUpdateStatus {
        case .confirmedSuccess:
            securitySettings = settings
        case .partialSuccess:
            securitySettings.isAutoBlockEnabled = settings.isAutoBlockEnabled
            securitySettings.failedAttempts = settings.failedAttempts
            securitySettings.withinMinutes = settings.withinMinutes
            securitySettings.expirationDays = settings.expirationDays
        default:
            break
        }
        let isUnknown = securityUpdateStatus == .submittedButUnverified
            || securityUpdateStatus == .cancellationRequestedAfterSubmission
        let isPartial = securityUpdateStatus == .partialSuccess
        let submitted = securityUpdateStatus != .cancelledBeforeSubmission
            && securityUpdateStatus != .permissionDenied
            && securityUpdateStatus != .unsupported
        return try MutationResult(
            status: securityUpdateStatus,
            operation: "securitySettingsUpdate",
            submitted: submitted,
            requiresRefresh: isUnknown || isPartial,
            counts: MutationResultCounts(
                succeeded: securityUpdateStatus == .confirmedSuccess || isPartial ? 1 : 0,
                failed: isPartial
                    || securityUpdateStatus == .permissionDenied
                    || securityUpdateStatus == .unsupported
                    || securityUpdateStatus == .confirmedFailure ? 1 : 0,
                unknown: isUnknown ? 1 : 0
            ),
            localizationKey: isPartial
                ? "security.settings.partial"
                : (isUnknown ? "security.settings.unverified" : nil),
            diagnosticTag: "security.settings.test"
        )
    }


    func controlPackage(id: String, action: NasPackageAction) async throws {
        packageControlRequests += 1
        applyPackageAction(id: id, action: action)
    }

    func controlPackageResult(
        id: String,
        action: NasPackageAction
    ) async throws -> MutationResult {
        packageControlRequests += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if packageControlStatus == .confirmedSuccess {
            applyPackageAction(id: id, action: action)
        }
        let isUnknown = packageControlStatus == .submittedButUnverified
            || packageControlStatus == .cancellationRequestedAfterSubmission
        let submitted = ![
            .cancelledBeforeSubmission,
            .permissionDenied,
            .unsupported
        ].contains(packageControlStatus)
        let prefix = action == .start ? "package.start" : "package.stop"
        return try MutationResult(
            status: packageControlStatus,
            operation: action == .start ? "packageStart" : "packageStop",
            submitted: submitted,
            requiresRefresh: isUnknown,
            counts: MutationResultCounts(
                succeeded: packageControlStatus == .confirmedSuccess ? 1 : 0,
                failed: [
                    .confirmedFailure,
                    .permissionDenied,
                    .unsupported
                ].contains(packageControlStatus) ? 1 : 0,
                unknown: isUnknown ? 1 : 0
            ),
            localizationKey: isUnknown ? "\(prefix).unverified" : nil,
            diagnosticTag: "\(prefix).test"
        )
    }

    private func applyPackageAction(id: String, action: NasPackageAction) {
        switch action {
        case .uninstall:
            packages.removeAll { $0.id == id }
        case .start, .stop:
            guard let index = packages.firstIndex(where: { $0.id == id }) else { return }
            let package = packages[index]
            let isStarting = action == .start
            packages[index] = NasPackage(
                id: package.id,
                name: package.name,
                version: package.version,
                status: isStarting ? "running" : "stopped",
                statusDescription: nil,
                packageDescription: package.packageDescription,
                installType: package.installType,
                installedAt: package.installedAt,
                iconData: package.iconData,
                canStart: !isStarting,
                canStop: isStarting,
                canUninstall: package.canUninstall,
                isUpgradeAvailable: package.isUpgradeAvailable,
                canUpgrade: package.canUpgrade
            )
        case .upgrade:
            break
        }
    }

    func uninstallPackageResult(id: String) async throws -> MutationResult {
        packageControlRequests += 1
        switch packageUninstallStatus {
        case .confirmedSuccess:
            packages.removeAll { $0.id == id }
            return try MutationResult(
                status: .confirmedSuccess,
                operation: "packageUninstall",
                submitted: true,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 1, failed: 0, unknown: 0)
            )
        case .submittedButUnverified:
            return try MutationResult(
                status: .submittedButUnverified,
                operation: "packageUninstall",
                submitted: true,
                requiresRefresh: true,
                counts: MutationResultCounts(succeeded: 0, failed: 0, unknown: 1)
            )
        default:
            return try MutationResult(
                status: packageUninstallStatus,
                operation: "packageUninstall",
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0)
            )
        }
    }

    private func deletionResult(
        status: MutationResultStatus,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        let submitted = status != .cancelledBeforeSubmission
            && status != .permissionDenied
            && status != .unsupported
        let isUnknown = status == .submittedButUnverified
            || status == .cancellationRequestedAfterSubmission
        return try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: isUnknown,
            counts: MutationResultCounts(
                succeeded: status == .confirmedSuccess ? 1 : 0,
                failed: status == .permissionDenied
                    || status == .unsupported
                    || status == .confirmedFailure ? 1 : 0,
                unknown: isUnknown ? 1 : 0
            ),
            localizationKey: isUnknown ? "\(prefix).unverified" : nil,
            diagnosticTag: "\(prefix).test"
        )
    }
}

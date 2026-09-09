import DsmCore
import DsmLocalization
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class ServiceManagementModelTests: XCTestCase {
    func test下载操作按实际任务状态开放() {
        for status in ["finished", "completed", "FINISHED", "unknown"] {
            let task = DownloadStationTask(id: "task", title: "测试任务", status: status)
            XCTAssertFalse(ServiceManagementModel.supportsDownloadAction(.resume, task: task))
            XCTAssertFalse(ServiceManagementModel.supportsDownloadAction(.pause, task: task))
        }
        let paused = DownloadStationTask(id: "paused", title: "暂停任务", status: "paused")
        XCTAssertTrue(ServiceManagementModel.supportsDownloadAction(.resume, task: paused))
        XCTAssertFalse(ServiceManagementModel.supportsDownloadAction(.pause, task: paused))
        for status in ["downloading", "waiting", "hash_checking", "seeding", "uploading"] {
            let task = DownloadStationTask(id: status, title: "活动任务", status: status)
            XCTAssertFalse(ServiceManagementModel.supportsDownloadAction(.resume, task: task))
            XCTAssertTrue(ServiceManagementModel.supportsDownloadAction(.pause, task: task))
        }
    }

    func test过期下载选择不会提交操作() async {
        let model = ServiceManagementModel(repository: ServiceManagementRepositoryStub())
        model.downloadSelection = ["missing-task"]
        XCTAssertFalse(model.canControlDownloads(.resume))
        XCTAssertFalse(model.canControlDownloads(.pause))
        let succeeded = await model.controlDownloads(.pause)
        XCTAssertFalse(succeeded)
        XCTAssertNil(model.message)
    }

    func test混合选择只操作状态允许的下载任务() async {
        let repository = ServiceManagementRepositoryStub(downloadTasks: [
            DownloadStationTask(id: "done", title: "已完成", status: "finished"),
            DownloadStationTask(id: "paused", title: "已暂停", status: "paused"),
            DownloadStationTask(id: "active", title: "进行中", status: "downloading")
        ])
        let model = ServiceManagementModel(repository: repository)
        await model.activate(.downloads)
        model.downloadSelection = ["done"]
        XCTAssertFalse(model.canControlDownloads(.resume))
        XCTAssertFalse(model.canControlDownloads(.pause))
        model.downloadSelection = ["done", "paused", "active", "stale"]
        XCTAssertTrue(model.canControlDownloads(.resume))
        XCTAssertTrue(model.canControlDownloads(.pause))
        _ = await model.controlDownloads(.resume)
        _ = await model.controlDownloads(.pause)
        let calls = await repository.downloadControlCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].ids, ["paused"])
        XCTAssertEqual(calls[0].action, .resume)
        XCTAssertEqual(calls[1].ids, ["active"])
        XCTAssertEqual(calls[1].action, .pause)
    }

    func test容器删除只有确认成功才显示完成并清空选择() async {
        let repository = ServiceManagementRepositoryStub(
            containerStatus: .confirmedSuccess
        )
        let model = ServiceManagementModel(repository: repository)
        await model.activate(.containers)
        model.containerSelection = ["container-1"]

        let succeeded = await model.deleteContainers()

        XCTAssertTrue(succeeded)
        XCTAssertTrue(model.containers?.containers.isEmpty == true)
        XCTAssertTrue(model.containerSelection.isEmpty)
        XCTAssertEqual(
            model.message,
            L10n.string("container.delete.completed")
        )
        XCTAssertFalse(model.messageIsError)
    }

    func test容器删除未确认时保留项目并提示先刷新() async {
        let repository = ServiceManagementRepositoryStub(
            containerStatus: .submittedButUnverified
        )
        let model = ServiceManagementModel(repository: repository)
        await model.activate(.containers)
        model.containerSelection = ["container-1"]

        let succeeded = await model.deleteContainers()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.containers?.containers.map(\.id), ["container-1"])
        XCTAssertEqual(model.containerSelection, ["container-1"])
        XCTAssertEqual(
            model.message,
            L10n.string("container.delete.unverified")
        )
        XCTAssertTrue(model.messageIsError)
    }

    func test未确认虚拟机删除可由随后刷新确认完成() async {
        let repository = ServiceManagementRepositoryStub(
            virtualMachineStatus: .submittedButUnverified,
            removeVirtualMachineOnDelete: true
        )
        let model = ServiceManagementModel(repository: repository)
        await model.activate(.virtualMachines)
        model.virtualMachineSelection = ["vm-1"]

        let succeeded = await model.deleteVirtualMachines()

        XCTAssertTrue(succeeded)
        XCTAssertTrue(model.virtualMachines?.machines.isEmpty == true)
        XCTAssertTrue(model.virtualMachineSelection.isEmpty)
        XCTAssertEqual(
            model.message,
            L10n.string("virtual-machine.delete.completed")
        )
        XCTAssertFalse(model.messageIsError)
    }

    func test删除反馈覆盖部分成功权限不足和不支持() {
        let partial = ServiceManagementModel.deletionFeedback(
            for: .partialSuccess,
            keyPrefix: "container.delete"
        )
        let permission = ServiceManagementModel.deletionFeedback(
            for: .permissionDenied,
            keyPrefix: "virtual-machine.delete"
        )
        let unsupported = ServiceManagementModel.deletionFeedback(
            for: .unsupported,
            keyPrefix: "virtual-machine.delete"
        )

        XCTAssertEqual(partial.resourceKey, "container.delete.partial")
        XCTAssertTrue(partial.isError)
        XCTAssertEqual(
            permission.resourceKey,
            "virtual-machine.delete.permission-denied"
        )
        XCTAssertTrue(permission.isError)
        XCTAssertEqual(
            unsupported.resourceKey,
            "virtual-machine.delete.unsupported"
        )
        XCTAssertTrue(unsupported.isError)
    }

    func test下载任务删除未确认时保留选择并提示刷新() async {
        let repository = ServiceManagementRepositoryStub(
            secondaryStatus: .submittedButUnverified
        )
        let model = ServiceManagementModel(repository: repository)
        await model.activate(.downloads)
        model.downloadSelection = ["task-1"]

        let succeeded = await model.deleteDownloads(removeData: true)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.downloadSelection, ["task-1"])
        XCTAssertEqual(
            model.message,
            L10n.string("download-task.delete.unverified")
        )
        XCTAssertTrue(model.messageIsError)
    }

    func test容器映像删除确认成功后清空选择() async {
        let repository = ServiceManagementRepositoryStub()
        let model = ServiceManagementModel(repository: repository)
        await model.activate(.containers)
        model.imageSelection = ["image-1"]

        let succeeded = await model.deleteImages()

        XCTAssertTrue(succeeded)
        XCTAssertTrue(model.imageSelection.isEmpty)
        XCTAssertTrue(model.containers?.images.isEmpty == true)
        XCTAssertEqual(
            model.message,
            L10n.string("container-image.delete.completed")
        )
    }

    func test容器网络部分成功时保留仍存在的选择() async {
        let repository = ServiceManagementRepositoryStub(
            secondaryStatus: .partialSuccess
        )
        let model = ServiceManagementModel(repository: repository)
        await model.activate(.containers)
        model.networkSelection = ["network-1"]

        let succeeded = await model.deleteNetworks()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.networkSelection, ["network-1"])
        XCTAssertEqual(
            model.message,
            L10n.string("container-network.delete.partial")
        )
    }

    func test未确认虚拟机映像删除可由刷新确认完成() async {
        let repository = ServiceManagementRepositoryStub(
            secondaryStatus: .submittedButUnverified,
            removeSecondaryOnDelete: true
        )
        let model = ServiceManagementModel(repository: repository)
        await model.activate(.virtualMachines)
        model.virtualMachineImageSelection = ["vm-image-1"]

        let succeeded = await model.deleteVirtualMachineImages()

        XCTAssertTrue(succeeded)
        XCTAssertTrue(model.virtualMachineImageSelection.isEmpty)
        XCTAssertEqual(
            model.message,
            L10n.string("virtual-machine-image.delete.completed")
        )
    }

    func test虚拟机网络删除权限不足时显示可恢复反馈() async {
        let repository = ServiceManagementRepositoryStub(
            secondaryStatus: .permissionDenied
        )
        let model = ServiceManagementModel(repository: repository)
        await model.activate(.virtualMachines)
        model.virtualMachineNetworkSelection = ["vm-network-1"]

        let succeeded = await model.deleteVirtualMachineNetworks()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.virtualMachineNetworkSelection, ["vm-network-1"])
        XCTAssertEqual(
            model.message,
            L10n.string("virtual-machine-network.delete.permission-denied")
        )
        XCTAssertTrue(model.messageIsError)
    }
}

// 共用合成套件数据，供模型与页面回归使用。
actor ServiceManagementRepositoryStub: ServiceManagementRepository {
    private let virtualMachineStorages: [VirtualizationResource]

    private var downloadTasks = [
        DownloadStationTask(
            id: "task-1",
            title: "示例下载",
            status: "paused"
        )
    ]
    private var containers = [
        ContainerInstance(
            id: "container-1",
            name: "示例容器",
            image: "demo:latest",
            status: "stopped"
        )
    ]
    private var containerImages = [
        ContainerImage(
            id: "image-1",
            repository: "demo",
            tag: "latest"
        )
    ]
    private var containerNetworks = [
        ContainerNetwork(
            id: "network-1",
            name: "示例网络",
            driver: "bridge"
        )
    ]
    private var machines = [
        VirtualMachine(
            id: "vm-1",
            name: "示例虚拟机",
            status: "shutdown"
        )
    ]
    private var virtualMachineImages = [
        VirtualizationResource(
            id: "vm-image-1",
            name: "示例映像"
        )
    ]
    private var virtualMachineNetworks = [
        VirtualizationResource(
            id: "vm-network-1",
            name: "示例网络"
        )
    ]
    private let containerStatus: MutationResultStatus
    private let virtualMachineStatus: MutationResultStatus
    private let removeVirtualMachineOnDelete: Bool
    private let secondaryStatus: MutationResultStatus
    private let removeSecondaryOnDelete: Bool

    init(
        containerStatus: MutationResultStatus = .confirmedSuccess,
        virtualMachineStatus: MutationResultStatus = .confirmedSuccess,
        removeVirtualMachineOnDelete: Bool = false,
        secondaryStatus: MutationResultStatus = .confirmedSuccess,
        removeSecondaryOnDelete: Bool = false,
        virtualMachineStorages: [VirtualizationResource] = [],
        downloadTasks: [DownloadStationTask]? = nil
    ) {
        self.containerStatus = containerStatus
        self.virtualMachineStatus = virtualMachineStatus
        self.removeVirtualMachineOnDelete = removeVirtualMachineOnDelete
        self.secondaryStatus = secondaryStatus
        self.removeSecondaryOnDelete = removeSecondaryOnDelete
        self.virtualMachineStorages = virtualMachineStorages
        if let downloadTasks { self.downloadTasks = downloadTasks }
    }

    func loadContainerManager() async throws -> ContainerManagerSnapshot {
        ContainerManagerSnapshot(
            containers: containers,
            images: containerImages,
            networks: containerNetworks,
            projects: [],
            events: []
        )
    }

    func deleteContainersResult(ids: [String]) async throws -> MutationResult {
        if containerStatus == .confirmedSuccess {
            containers.removeAll { ids.contains($0.id) }
        }
        return try result(
            status: containerStatus,
            operation: "containerDelete",
            count: ids.count
        )
    }

    func loadVirtualMachineManager() async throws -> VirtualMachineManagerSnapshot {
        VirtualMachineManagerSnapshot(
            source: .official,
            machines: machines,
            hosts: [],
            storages: virtualMachineStorages,
            networks: virtualMachineNetworks,
            images: virtualMachineImages,
            protectionPlans: [],
            events: []
        )
    }

    func deleteVirtualMachinesResult(ids: [String]) async throws -> MutationResult {
        if virtualMachineStatus == .confirmedSuccess || removeVirtualMachineOnDelete {
            machines.removeAll { ids.contains($0.id) }
        }
        return try result(
            status: virtualMachineStatus,
            operation: "virtualMachineDelete",
            count: ids.count
        )
    }

    private func result(
        status: MutationResultStatus,
        operation: String,
        count: Int
    ) throws -> MutationResult {
        let submitted: Bool
        let requiresRefresh: Bool
        let counts: MutationResultCounts
        switch status {
        case .confirmedSuccess:
            submitted = true
            requiresRefresh = false
            counts = try MutationResultCounts(
                succeeded: count,
                failed: 0,
                unknown: 0
            )
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            submitted = true
            requiresRefresh = true
            counts = try MutationResultCounts(
                succeeded: 0,
                failed: 0,
                unknown: count
            )
        case .partialSuccess:
            submitted = true
            requiresRefresh = true
            counts = try MutationResultCounts(
                succeeded: 1,
                failed: 0,
                unknown: max(1, count - 1)
            )
        case .cancelledBeforeSubmission:
            submitted = false
            requiresRefresh = false
            counts = try MutationResultCounts(
                succeeded: 0,
                failed: 0,
                unknown: 0
            )
        case .confirmedFailure, .permissionDenied, .unsupported:
            submitted = false
            requiresRefresh = false
            counts = try MutationResultCounts(
                succeeded: 0,
                failed: count,
                unknown: 0
            )
        }
        return try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: counts
        )
    }

    func loadDownloadStation() async throws -> DownloadStationSnapshot {
        DownloadStationSnapshot(source: .official, tasks: downloadTasks)
    }
    func createDownloadTask(uri: String, destination: String?) async throws { throw unavailable() }
    func createDownloadTask(
        fileURL: URL,
        destination: String?,
        unzipPassword: String?
    ) async throws { throw unavailable() }
    func loadDownloadStationSettings() async throws -> DownloadStationSettings {
        DownloadStationSettings()
    }
    func saveDownloadStationSettings(_ settings: DownloadStationSettings) async throws {
        throw unavailable()
    }
    private(set) var downloadControlCalls: [(ids: [String], action: DownloadStationTaskAction)] = []

    func controlDownloadTasks(
        ids: [String],
        action: DownloadStationTaskAction
    ) async throws {
        downloadControlCalls.append((ids, action))
    }
    func deleteDownloadTasks(ids: [String], removeData: Bool) async throws {
        throw unavailable()
    }
    func deleteDownloadTasksResult(
        ids: [String],
        removeData: Bool
    ) async throws -> MutationResult {
        if secondaryStatus == .confirmedSuccess || removeSecondaryOnDelete {
            downloadTasks.removeAll { ids.contains($0.id) }
        }
        return try result(
            status: secondaryStatus,
            operation: "downloadTaskDelete",
            count: ids.count
        )
    }
    func controlContainers(ids: [String], action: ContainerAction) async throws {
        throw unavailable()
    }
    func deleteContainers(ids: [String]) async throws { throw unavailable() }
    func searchContainerImages(query: String) async throws -> [ContainerRegistryImage] {
        throw unavailable()
    }
    func loadContainerImageTags(repository: String) async throws -> [String] {
        throw unavailable()
    }
    func pullContainerImage(repository: String, tag: String) async throws {
        throw unavailable()
    }
    func deleteContainerImages(ids: [String]) async throws { throw unavailable() }
    func deleteContainerImagesResult(ids: [String]) async throws -> MutationResult {
        if secondaryStatus == .confirmedSuccess || removeSecondaryOnDelete {
            containerImages.removeAll { ids.contains($0.id) }
        }
        return try result(
            status: secondaryStatus,
            operation: "containerImageDelete",
            count: ids.count
        )
    }
    func createContainerNetwork(name: String, driver: String) async throws {
        throw unavailable()
    }
    func deleteContainerNetworks(ids: [String]) async throws { throw unavailable() }
    func deleteContainerNetworksResult(ids: [String]) async throws -> MutationResult {
        if secondaryStatus == .confirmedSuccess || removeSecondaryOnDelete {
            containerNetworks.removeAll { ids.contains($0.id) }
        }
        return try result(
            status: secondaryStatus,
            operation: "containerNetworkDelete",
            count: ids.count
        )
    }
    func createVirtualMachine(_ configuration: VirtualMachineCreation) async throws {
        throw unavailable()
    }
    func updateVirtualMachine(
        id: String,
        configuration: VirtualMachineUpdate
    ) async throws { throw unavailable() }
    func openVirtualMachineConsole(id: String) async throws -> VirtualMachineConsoleSession {
        throw unavailable()
    }
    func controlVirtualMachines(
        ids: [String],
        action: VirtualMachinePowerAction
    ) async throws { throw unavailable() }
    func deleteVirtualMachines(ids: [String]) async throws { throw unavailable() }
    func updateVirtualMachineNetwork(
        id: String,
        configuration: VirtualMachineNetworkUpdate
    ) async throws { throw unavailable() }
    func deleteVirtualMachineNetworks(ids: [String]) async throws { throw unavailable() }
    func deleteVirtualMachineNetworksResult(ids: [String]) async throws -> MutationResult {
        if secondaryStatus == .confirmedSuccess || removeSecondaryOnDelete {
            virtualMachineNetworks.removeAll { ids.contains($0.id) }
        }
        return try result(
            status: secondaryStatus,
            operation: "virtualMachineNetworkDelete",
            count: ids.count
        )
    }
    func deleteVirtualMachineImages(ids: [String]) async throws { throw unavailable() }
    func deleteVirtualMachineImagesResult(ids: [String]) async throws -> MutationResult {
        if secondaryStatus == .confirmedSuccess || removeSecondaryOnDelete {
            virtualMachineImages.removeAll { ids.contains($0.id) }
        }
        return try result(
            status: secondaryStatus,
            operation: "virtualMachineImageDelete",
            count: ids.count
        )
    }

    private func unavailable() -> AppError {
        AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: "测试存根未实现此操作"
        )
    }
}

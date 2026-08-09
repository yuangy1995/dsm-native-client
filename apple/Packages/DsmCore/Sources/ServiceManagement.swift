import Foundation

public enum ServiceContractSource: String, Equatable, Sendable {
    case official
    case internalAPI
}

public struct DownloadStationTask: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let status: String
    public let sizeBytes: Int64?
    public let downloadedBytes: Int64?
    public let uploadedBytes: Int64?
    public let downloadBytesPerSecond: Int64?
    public let uploadBytesPerSecond: Int64?
    public let destination: String?
    public let errorDescription: String?

    public init(
        id: String,
        title: String,
        status: String,
        sizeBytes: Int64? = nil,
        downloadedBytes: Int64? = nil,
        uploadedBytes: Int64? = nil,
        downloadBytesPerSecond: Int64? = nil,
        uploadBytesPerSecond: Int64? = nil,
        destination: String? = nil,
        errorDescription: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.sizeBytes = sizeBytes
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.destination = destination
        self.errorDescription = errorDescription
    }

    public var progress: Double? {
        guard let sizeBytes, sizeBytes > 0, let downloadedBytes else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(sizeBytes)))
    }
}

public struct DownloadStationSnapshot: Equatable, Sendable {
    public let source: ServiceContractSource
    public let tasks: [DownloadStationTask]
    public let downloadBytesPerSecond: Int64
    public let uploadBytesPerSecond: Int64
    public let defaultDestination: String?

    public init(
        source: ServiceContractSource,
        tasks: [DownloadStationTask],
        downloadBytesPerSecond: Int64 = 0,
        uploadBytesPerSecond: Int64 = 0,
        defaultDestination: String? = nil
    ) {
        self.source = source
        self.tasks = tasks
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.defaultDestination = defaultDestination
    }
}

/// Download Station 公开接口可读取和修改的服务器设置。
/// `0` 表示不限速，单位均为 KB/s。
public struct DownloadStationSettings: Equatable, Sendable {
    public var defaultDestination: String
    public var isEMuleEnabled: Bool
    public var isAutoExtractEnabled: Bool
    public var btDownloadLimit: Int
    public var btUploadLimit: Int
    public var httpDownloadLimit: Int
    public var ftpDownloadLimit: Int
    public var nzbDownloadLimit: Int
    public var emuleDownloadLimit: Int
    public var emuleUploadLimit: Int
    public var isScheduleEnabled: Bool
    public var isEMuleScheduleEnabled: Bool

    public init(
        defaultDestination: String = "",
        isEMuleEnabled: Bool = false,
        isAutoExtractEnabled: Bool = false,
        btDownloadLimit: Int = 0,
        btUploadLimit: Int = 0,
        httpDownloadLimit: Int = 0,
        ftpDownloadLimit: Int = 0,
        nzbDownloadLimit: Int = 0,
        emuleDownloadLimit: Int = 0,
        emuleUploadLimit: Int = 0,
        isScheduleEnabled: Bool = false,
        isEMuleScheduleEnabled: Bool = false
    ) {
        self.defaultDestination = defaultDestination
        self.isEMuleEnabled = isEMuleEnabled
        self.isAutoExtractEnabled = isAutoExtractEnabled
        self.btDownloadLimit = btDownloadLimit
        self.btUploadLimit = btUploadLimit
        self.httpDownloadLimit = httpDownloadLimit
        self.ftpDownloadLimit = ftpDownloadLimit
        self.nzbDownloadLimit = nzbDownloadLimit
        self.emuleDownloadLimit = emuleDownloadLimit
        self.emuleUploadLimit = emuleUploadLimit
        self.isScheduleEnabled = isScheduleEnabled
        self.isEMuleScheduleEnabled = isEMuleScheduleEnabled
    }
}

public enum DownloadStationTaskAction: String, Sendable {
    case pause
    case resume
    case finish
}

public struct DownloadTaskControlRequest: Equatable, Sendable {
    public let task: DownloadStationTask
    public let action: DownloadStationTaskAction

    public init(task: DownloadStationTask, action: DownloadStationTaskAction) {
        self.task = task
        self.action = action
    }
}

public struct DownloadTaskControlOutcome: Equatable, Sendable {
    public let result: MutationResult
    public let taskID: String
    public let task: DownloadStationTask?

    public init(result: MutationResult, taskID: String, task: DownloadStationTask?) {
        self.result = result
        self.taskID = taskID
        self.task = task
    }
}

public struct DownloadTaskCreateRequest: Equatable, Sendable {
    public let uri: String
    public let destination: String?

    public init(uri: String, destination: String?) {
        self.uri = uri
        self.destination = destination
    }
}

public struct DownloadTaskCreateOutcome: Equatable, Sendable {
    public let result: MutationResult
    public let taskID: String?
    public let task: DownloadStationTask?

    public init(result: MutationResult, taskID: String?, task: DownloadStationTask?) {
        self.result = result
        self.taskID = taskID
        self.task = task
    }
}

public struct ContainerInstance: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    public let project: String?
    public let status: String
    public let cpuUsage: Double?
    public let memoryBytes: Int64?
    public let createdAt: Date?

    public init(
        id: String,
        name: String,
        image: String,
        project: String? = nil,
        status: String,
        cpuUsage: Double? = nil,
        memoryBytes: Int64? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.project = project
        self.status = status
        self.cpuUsage = cpuUsage
        self.memoryBytes = memoryBytes
        self.createdAt = createdAt
    }
}

public struct ContainerImage: Identifiable, Equatable, Sendable {
    public let id: String
    public let repository: String
    public let tag: String
    public let sizeBytes: Int64?
    public let createdAt: Date?
    public let isInUse: Bool

    public init(
        id: String,
        repository: String,
        tag: String,
        sizeBytes: Int64? = nil,
        createdAt: Date? = nil,
        isInUse: Bool = false
    ) {
        self.id = id
        self.repository = repository
        self.tag = tag
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.isInUse = isInUse
    }
}

public struct ContainerRegistryImage: Identifiable, Equatable, Sendable {
    public var id: String { "\(registry)/\(name)" }
    public let name: String
    public let registry: String
    public let description: String?
    public let starCount: Int
    public let isOfficial: Bool
    public let isAutomated: Bool
    public let isTrusted: Bool

    public init(
        name: String,
        registry: String,
        description: String? = nil,
        starCount: Int = 0,
        isOfficial: Bool = false,
        isAutomated: Bool = false,
        isTrusted: Bool = false
    ) {
        self.name = name
        self.registry = registry
        self.description = description
        self.starCount = starCount
        self.isOfficial = isOfficial
        self.isAutomated = isAutomated
        self.isTrusted = isTrusted
    }
}

public struct ContainerNetwork: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let driver: String
    public let connectedContainerCount: Int

    public init(id: String, name: String, driver: String, connectedContainerCount: Int = 0) {
        self.id = id
        self.name = name
        self.driver = driver
        self.connectedContainerCount = connectedContainerCount
    }
}

public struct ContainerProject: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let containerCount: Int

    public init(id: String, name: String, status: String, containerCount: Int = 0) {
        self.id = id
        self.name = name
        self.status = status
        self.containerCount = containerCount
    }
}

public struct ServiceEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date?
    public let level: String
    public let user: String?
    public let message: String

    public init(id: String, timestamp: Date?, level: String, user: String?, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.user = user
        self.message = message
    }
}

public struct ContainerManagerSnapshot: Equatable, Sendable {
    public let containers: [ContainerInstance]
    public let images: [ContainerImage]
    public let networks: [ContainerNetwork]
    public let projects: [ContainerProject]
    public let events: [ServiceEvent]

    public init(
        containers: [ContainerInstance],
        images: [ContainerImage],
        networks: [ContainerNetwork],
        projects: [ContainerProject],
        events: [ServiceEvent]
    ) {
        self.containers = containers
        self.images = images
        self.networks = networks
        self.projects = projects
        self.events = events
    }
}

public enum ContainerAction: String, Sendable {
    case start
    case stop
    case restart
}

public struct VirtualMachine: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let description: String?
    public let hostID: String?
    public let host: String?
    public let storageID: String?
    public let cpuCount: Int?
    public let memoryBytes: Int64?
    public let storageBytes: Int64?
    public let ipAddress: String?
    public let keyboardLayout: String?
    public let autoStart: Bool
    public let cpuWeight: Int?

    public init(
        id: String,
        name: String,
        status: String,
        description: String? = nil,
        hostID: String? = nil,
        host: String? = nil,
        storageID: String? = nil,
        cpuCount: Int? = nil,
        memoryBytes: Int64? = nil,
        storageBytes: Int64? = nil,
        ipAddress: String? = nil,
        keyboardLayout: String? = nil,
        autoStart: Bool = false,
        cpuWeight: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.description = description
        self.hostID = hostID
        self.host = host
        self.storageID = storageID
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.storageBytes = storageBytes
        self.ipAddress = ipAddress
        self.keyboardLayout = keyboardLayout
        self.autoStart = autoStart
        self.cpuWeight = cpuWeight
    }
}

public struct VirtualizationResource: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: String?
    public let detail: String?
    public let hostID: String?
    public let hostName: String?
    public let allocatedBytes: Int64?
    public let capacityBytes: Int64?

    public init(
        id: String,
        name: String,
        status: String? = nil,
        detail: String? = nil,
        hostID: String? = nil,
        hostName: String? = nil,
        allocatedBytes: Int64? = nil,
        capacityBytes: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.detail = detail
        self.hostID = hostID
        self.hostName = hostName
        self.allocatedBytes = allocatedBytes
        self.capacityBytes = capacityBytes
    }
}

public struct VirtualMachineNetworkUpdate: Equatable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public enum VirtualMachineManagerSection: String, Hashable, Sendable {
    case hosts
    case storages
    case networks
    case images
    case protection
    case logs
}

public enum VirtualMachineOperatingSystem: String, CaseIterable, Identifiable, Sendable {
    case windows
    case linux
    case other

    public var id: Self { self }
}

public enum VirtualMachineFirmware: String, CaseIterable, Identifiable, Sendable {
    case legacy
    case uefi

    public var id: Self { self }
}

public struct VirtualMachineCreation: Equatable, Sendable {
    public let name: String
    public let operatingSystem: VirtualMachineOperatingSystem
    public let storageID: String
    public let networkID: String
    public let bootImageID: String?
    public let cpuCount: Int
    public let memoryMiB: Int
    public let diskGiB: Int
    public let description: String?
    public let firmware: VirtualMachineFirmware
    public let autoStart: Bool
    public let powerOnAfterCreation: Bool

    public init(
        name: String,
        operatingSystem: VirtualMachineOperatingSystem,
        storageID: String,
        networkID: String,
        bootImageID: String? = nil,
        cpuCount: Int,
        memoryMiB: Int,
        diskGiB: Int,
        description: String? = nil,
        firmware: VirtualMachineFirmware = .legacy,
        autoStart: Bool = false,
        powerOnAfterCreation: Bool = false
    ) {
        self.name = name
        self.operatingSystem = operatingSystem
        self.storageID = storageID
        self.networkID = networkID
        self.bootImageID = bootImageID
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.diskGiB = diskGiB
        self.description = description
        self.firmware = firmware
        self.autoStart = autoStart
        self.powerOnAfterCreation = powerOnAfterCreation
    }
}

public struct VirtualMachineUpdate: Equatable, Sendable {
    public let name: String?
    public let description: String?
    public let cpuCount: Int?
    public let memoryMiB: Int?
    public let cpuWeight: Int?
    public let autoStart: Bool?

    public init(
        name: String? = nil,
        description: String? = nil,
        cpuCount: Int? = nil,
        memoryMiB: Int? = nil,
        cpuWeight: Int? = nil,
        autoStart: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.cpuWeight = cpuWeight
        self.autoStart = autoStart
    }
}

/// 远程控制台凭据只保存在内存中，不应记录、持久化或拼入地址。
public struct VirtualMachineConsoleSession: Equatable, Sendable {
    public let url: URL
    public let sessionCookieValue: String

    public init(url: URL, sessionCookieValue: String) {
        self.url = url
        self.sessionCookieValue = sessionCookieValue
    }
}

public struct VirtualMachineManagerSnapshot: Equatable, Sendable {
    public let source: ServiceContractSource
    public let machines: [VirtualMachine]
    public let hosts: [VirtualizationResource]
    public let storages: [VirtualizationResource]
    public let networks: [VirtualizationResource]
    public let images: [VirtualizationResource]
    public let protectionPlans: [VirtualizationResource]
    public let protectionSchedulePolicies: [VirtualizationResource]
    public let protectionRetentionPolicies: [VirtualizationResource]
    public let events: [ServiceEvent]
    public let unavailableSections: Set<VirtualMachineManagerSection>

    public init(
        source: ServiceContractSource,
        machines: [VirtualMachine],
        hosts: [VirtualizationResource],
        storages: [VirtualizationResource],
        networks: [VirtualizationResource],
        images: [VirtualizationResource],
        protectionPlans: [VirtualizationResource],
        protectionSchedulePolicies: [VirtualizationResource] = [],
        protectionRetentionPolicies: [VirtualizationResource] = [],
        events: [ServiceEvent],
        unavailableSections: Set<VirtualMachineManagerSection> = []
    ) {
        self.source = source
        self.machines = machines
        self.hosts = hosts
        self.storages = storages
        self.networks = networks
        self.images = images
        self.protectionPlans = protectionPlans
        self.protectionSchedulePolicies = protectionSchedulePolicies
        self.protectionRetentionPolicies = protectionRetentionPolicies
        self.events = events
        self.unavailableSections = unavailableSections
    }
}

public enum VirtualMachinePowerAction: String, Sendable {
    case powerOn
    case shutdown
    case powerOff
    case restart
}

/// 三个套件的统一管理契约。公开 API 优先，内部接口必须由实现层逐项能力发现。
public protocol ServiceManagementRepository: Sendable {
    func loadDownloadStation() async throws -> DownloadStationSnapshot
    func createDownloadTask(uri: String, destination: String?) async throws
    func createDownloadTaskResult(
        _ request: DownloadTaskCreateRequest
    ) async throws -> DownloadTaskCreateOutcome
    func createDownloadTask(
        fileURL: URL,
        destination: String?,
        unzipPassword: String?
    ) async throws
    func loadDownloadStationSettings() async throws -> DownloadStationSettings
    func saveDownloadStationSettings(_ settings: DownloadStationSettings) async throws
    func controlDownloadTasks(ids: [String], action: DownloadStationTaskAction) async throws
    func controlDownloadTaskResult(
        _ request: DownloadTaskControlRequest
    ) async throws -> DownloadTaskControlOutcome
    func deleteDownloadTasks(ids: [String], removeData: Bool) async throws
    func deleteDownloadTasksResult(ids: [String], removeData: Bool) async throws -> MutationResult

    func loadContainerManager() async throws -> ContainerManagerSnapshot
    func controlContainers(ids: [String], action: ContainerAction) async throws
    func deleteContainers(ids: [String]) async throws
    func deleteContainersResult(ids: [String]) async throws -> MutationResult
    func searchContainerImages(query: String) async throws -> [ContainerRegistryImage]
    func loadContainerImageTags(repository: String) async throws -> [String]
    func pullContainerImage(repository: String, tag: String) async throws
    func deleteContainerImages(ids: [String]) async throws
    func deleteContainerImagesResult(ids: [String]) async throws -> MutationResult
    func createContainerNetwork(name: String, driver: String) async throws
    func deleteContainerNetworks(ids: [String]) async throws
    func deleteContainerNetworksResult(ids: [String]) async throws -> MutationResult

    func loadVirtualMachineManager() async throws -> VirtualMachineManagerSnapshot
    func createVirtualMachine(_ configuration: VirtualMachineCreation) async throws
    func updateVirtualMachine(id: String, configuration: VirtualMachineUpdate) async throws
    func openVirtualMachineConsole(id: String) async throws -> VirtualMachineConsoleSession
    func controlVirtualMachines(ids: [String], action: VirtualMachinePowerAction) async throws
    func deleteVirtualMachines(ids: [String]) async throws
    func deleteVirtualMachinesResult(ids: [String]) async throws -> MutationResult
    func updateVirtualMachineNetwork(
        id: String,
        configuration: VirtualMachineNetworkUpdate
    ) async throws
    func deleteVirtualMachineNetworks(ids: [String]) async throws
    func deleteVirtualMachineNetworksResult(ids: [String]) async throws -> MutationResult
    func deleteVirtualMachineImages(ids: [String]) async throws
    func deleteVirtualMachineImagesResult(ids: [String]) async throws -> MutationResult
}

public extension ServiceManagementRepository {
    func createDownloadTaskResult(
        _ request: DownloadTaskCreateRequest
    ) async throws -> DownloadTaskCreateOutcome {
        try DownloadTaskCreateOutcome(
            result: MutationResult(
                status: .unsupported,
                operation: "downloadCreate",
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                localizationKey: "download-task.create.unsupported",
                diagnosticTag: "download-task.create.unsupported"
            ),
            taskID: nil,
            task: nil
        )
    }

    func controlDownloadTaskResult(
        _ request: DownloadTaskControlRequest
    ) async throws -> DownloadTaskControlOutcome {
        let operation: String
        switch request.action {
        case .pause:
            operation = "downloadPause"
        case .resume:
            operation = "downloadResume"
        case .finish:
            operation = "downloadControl"
        }
        return try DownloadTaskControlOutcome(
            result: MutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                localizationKey: "download-task.control.unsupported",
                diagnosticTag: "download-task.control.unsupported"
            ),
            taskID: request.task.id,
            task: nil
        )
    }

    func deleteDownloadTasksResult(
        ids: [String],
        removeData: Bool
    ) async throws -> MutationResult {
        try unsupportedDeletionResult(
            operation: "downloadTaskDelete",
            localizationPrefix: "download-task.delete",
            count: ids.count
        )
    }

    func deleteContainersResult(ids: [String]) async throws -> MutationResult {
        try unsupportedDeletionResult(
            operation: "containerDelete",
            localizationPrefix: "container.delete",
            count: ids.count
        )
    }

    func deleteContainerImagesResult(ids: [String]) async throws -> MutationResult {
        try unsupportedDeletionResult(
            operation: "containerImageDelete",
            localizationPrefix: "container-image.delete",
            count: ids.count
        )
    }

    func deleteContainerNetworksResult(ids: [String]) async throws -> MutationResult {
        try unsupportedDeletionResult(
            operation: "containerNetworkDelete",
            localizationPrefix: "container-network.delete",
            count: ids.count
        )
    }

    func deleteVirtualMachinesResult(ids: [String]) async throws -> MutationResult {
        try unsupportedDeletionResult(
            operation: "virtualMachineDelete",
            localizationPrefix: "virtual-machine.delete",
            count: ids.count
        )
    }

    func deleteVirtualMachineNetworksResult(ids: [String]) async throws -> MutationResult {
        try unsupportedDeletionResult(
            operation: "virtualMachineNetworkDelete",
            localizationPrefix: "virtual-machine-network.delete",
            count: ids.count
        )
    }

    func deleteVirtualMachineImagesResult(ids: [String]) async throws -> MutationResult {
        try unsupportedDeletionResult(
            operation: "virtualMachineImageDelete",
            localizationPrefix: "virtual-machine-image.delete",
            count: ids.count
        )
    }

    private func unsupportedDeletionResult(
        operation: String,
        localizationPrefix: String,
        count: Int
    ) throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: operation,
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(
                succeeded: 0,
                failed: count,
                unknown: 0
            ),
            errorCategory: .unsupported,
            localizationKey: "\(localizationPrefix).unsupported",
            diagnosticTag: "\(localizationPrefix).unsupported"
        )
    }
}

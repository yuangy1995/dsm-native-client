package io.github.qwertyuiop1995.dsmnativeclient.domain

enum class ResourceState {
    RUNNING,
    STOPPED,
    PAUSED,
    WAITING,
    HEALTHY,
    WARNING,
    ERROR,
    UNKNOWN,
}

data class ManagedResource(
    val id: String,
    val name: String,
    val detail: String,
    val state: ResourceState,
    val metadata: Map<String, String> = emptyMap(),
    val localizedLabel: ManagedResourceLabel? = null,
)

enum class ManagedResourceLabel {
    SECURITY_AUTO_BLOCK,
    SECURITY_DOS_PROTECTION,
    SECURITY_FIREWALL,
}

data class ContainerOverview(
    val containers: List<ManagedResource>,
    val images: List<ManagedResource>,
    val networks: List<ManagedResource>,
    val projects: List<ManagedResource>,
    val events: List<LogEntry> = emptyList(),
    val unavailableSections: Set<ContainerSection> = emptySet(),
    val projectDetails: List<ContainerProjectInfo> = emptyList(),
)

data class ContainerProjectInfo(val id: String, val name: String, val state: ResourceState, val containerCount: Int?)

enum class ContainerSection { IMAGES, NETWORKS, PROJECTS, EVENTS }

data class ContainerRegistryImage(
    val name: String,
    val registry: String,
    val description: String?,
    val starCount: Int,
    val isOfficial: Boolean,
    val isAutomated: Boolean,
    val isTrusted: Boolean,
) {
    val id: String get() = "$registry/$name"
}

enum class VirtualMachineSection {
    HOSTS,
    STORAGES,
    NETWORKS,
    IMAGES,
    PROTECTION,
    LOGS,
    HARDWARE,
    TASKS,
}

enum class VirtualMachineDiskController { VIRTIO, IDE, SATA }

data class VirtualMachineDisk(
    val id: String,
    val sizeMiB: Int,
    val controller: VirtualMachineDiskController,
    val spaceReclamationEnabled: Boolean,
)

enum class VirtualMachineNetworkModel { VIRTIO, E1000, RTL8139 }

data class VirtualMachineNetworkInterface(
    val id: String,
    val networkId: String,
    val networkName: String,
    val model: VirtualMachineNetworkModel,
)

data class VirtualMachineHardware(
    val machineId: String,
    val disks: List<VirtualMachineDisk>,
    val networkInterfaces: List<VirtualMachineNetworkInterface>,
)

/** 公开 Guest.get v1 的最小只读详情投影。 */
data class VirtualMachineGuestDetails(
    val resource: ManagedResource,
    val hardware: VirtualMachineHardware,
)

/** Synology 官方 Virtual Machine Manager 规格：每台虚拟机最多 8 块虚拟磁盘。 */
const val MAX_VIRTUAL_MACHINE_DISKS = 8

/** 官方 Guest.create v1 的附加虚拟磁盘；控制器与空间回收没有公开写参数。 */
data class VirtualMachineCreationDisk(
    val sizeGiB: Int,
    val diskImageId: String? = null,
)

/** 官方 Guest.create v1 的附加虚拟网卡；空标识表示创建后暂不连接网络。 */
data class VirtualMachineCreationNetworkInterface(
    val networkId: String? = null,
)

data class VirtualMachineTask(
    /** 由服务端任务标识单向摘要得到，只用于列表稳定键。 */
    val id: String,
    val isFinished: Boolean,
    val progressPercent: Int?,
    /** 仅保存在当前 Workspace 内存中，用于清理前复核；不得展示、记录或持久化。 */
    internal val taskToken: String = id,
) {
    init {
        require(id.isNotBlank() && taskToken.isNotBlank()) { "virtual_machine.invalid_task" }
    }

    /** 避免调试输出意外包含服务端任务标识。 */
    override fun toString(): String =
        "VirtualMachineTask(id=$id, isFinished=$isFinished, progressPercent=$progressPercent)"
}

enum class VirtualMachineTaskCenterState {
    AVAILABLE,
    CAPABILITY_UNAVAILABLE,
    INVALID_RESPONSE,
    LOAD_FAILED,
}

data class VirtualMachineOverview(
    val machines: List<ManagedResource>,
    val hosts: List<ManagedResource>,
    val storages: List<ManagedResource>,
    val networks: List<ManagedResource>,
    val images: List<ManagedResource>,
    val protectionPlans: List<ManagedResource>,
    val protectionSchedules: List<ManagedResource>,
    val retentionPolicies: List<ManagedResource>,
    val logs: List<LogEntry>,
    val machineHardware: List<VirtualMachineHardware> = emptyList(),
    val tasks: List<VirtualMachineTask> = emptyList(),
    val taskCenterState: VirtualMachineTaskCenterState =
        VirtualMachineTaskCenterState.CAPABILITY_UNAVAILABLE,
    val unavailableSections: Set<VirtualMachineSection> = emptySet(),
)

data class VirtualMachineCreation(
    val name: String,
    val description: String,
    val cpuCount: Int,
    val memoryMiB: Int,
    val diskGiB: Int,
    val storageId: String,
    val networkId: String?,
    val diskImageId: String?,
    val autoStart: Boolean,
    /** 保留原有主磁盘字段，附加项只扩展创建请求，兼容既有调用者与草稿。 */
    val additionalDisks: List<VirtualMachineCreationDisk> = emptyList(),
    /** 保留原有主网卡字段；每个附加项只发送官方公开的 network_id。 */
    val additionalNetworkInterfaces: List<VirtualMachineCreationNetworkInterface> = emptyList(),
)

data class VirtualMachineSettings(
    val name: String,
    val description: String,
    val cpuCount: Int,
    val memoryMiB: Int,
    val autoStart: Boolean,
)

enum class VirtualMachineImageType(val apiValue: String) {
    DISK("disk"),
    VDSM("vdsm"),
    ISO("iso"),
}

/** 从 NAS 已有文件创建 VMM 映像所需的用户所见完整基线。 */
data class VirtualMachineImageImport(
    val imageName: String,
    val imageType: VirtualMachineImageType,
    val sourceFile: FileItem,
    val storage: ManagedResource,
)

enum class VirtualMachineImageImportVerification { PENDING, MATCHES, DIFFERS }

/** 官方明确的不可用/崩溃/已满状态关闭写入口，其余已枚举可服务状态交给 VMM 最终校验。 */
fun ManagedResource.isEligibleForVirtualMachineImageImport(): Boolean =
    id.isNotBlank() && metadata["status"]?.lowercase() in
        setOf("online", "degraded", "provision_warning")

enum class LogLevel { INFO, WARNING, ERROR, UNKNOWN }

data class LogEntry(
    val id: String,
    val level: LogLevel,
    val timeEpochSeconds: Long?,
    val user: String,
    val event: String,
    /** 容器日志未附时区，保留 NAS 本地时间，不假设为手机时区或 UTC。 */
    val localTime: java.time.LocalDateTime? = null,
)

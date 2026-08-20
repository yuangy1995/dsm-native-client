package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.domain.LogEntry
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResource
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineHardware
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineOverview
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineSection
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineTaskCenterState
import kotlinx.serialization.json.JsonObject

/**
 * VMM 只读总览编排。
 *
 * Gateway 保留 DsmRepository 内既有的能力选择、响应严格校验、任务中心状态和请求契约；
 * 本类只负责将已验证的读取结果组合为领域快照。
 */
internal interface DsmVirtualMachineRepositoryGateway {
    fun preferred(vararg names: String): String

    fun preferredOrNull(vararg names: String): String?

    fun supports(apiName: String): Boolean

    fun supportsVersion(apiName: String, version: Int): Boolean

    suspend fun officialRead(): Pair<List<ManagedResource>, List<VirtualMachineHardware>?>

    suspend fun resourceList(
        apiName: String,
        methods: List<String>,
        vararg roots: String,
    ): List<ManagedResource>

    suspend fun firstSuccessful(apiName: String, methods: List<String>): JsonObject

    fun genericResources(data: JsonObject, vararg roots: String): List<ManagedResource>

    suspend fun logs(): List<LogEntry>

    suspend fun taskCenter(): Pair<List<VirtualMachineTask>, VirtualMachineTaskCenterState>
}

internal class DsmVirtualMachineRepository(
    private val gateway: DsmVirtualMachineRepositoryGateway,
) {
    suspend fun overview(): VirtualMachineOverview {
        val guestApi = gateway.preferred(
            "SYNO.Virtualization.API.Guest",
            "SYNO.Virtualization.Guest",
        )
        val hostApi = gateway.preferredOrNull(
            "SYNO.Virtualization.API.Host",
            "SYNO.Virtualization.Host",
        )
        val storageApi = gateway.preferredOrNull(
            "SYNO.Virtualization.API.Storage",
            "SYNO.Virtualization.Repo",
        )
        val networkApi = gateway.preferredOrNull(
            "SYNO.Virtualization.API.Network",
            "SYNO.Virtualization.Network",
        )
        val imageApi = gateway.preferredOrNull(
            "SYNO.Virtualization.API.Guest.Image",
            "SYNO.Virtualization.Guest.Image",
        )
        val unavailable = mutableSetOf<VirtualMachineSection>()
        val officialGuestRead = if (gateway.supportsVersion("SYNO.Virtualization.API.Guest", 1)) {
            try {
                gateway.officialRead()
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                unavailable += VirtualMachineSection.HARDWARE
                null
            }
        } else {
            unavailable += VirtualMachineSection.HARDWARE
            null
        }
        if (officialGuestRead?.second == null) {
            unavailable += VirtualMachineSection.HARDWARE
        }
        val machines = officialGuestRead?.first
            ?: gateway.resourceList(guestApi, listOf("list"), "guests", "vms")
        suspend fun optional(
            section: VirtualMachineSection,
            apiName: String?,
            vararg roots: String,
        ): List<ManagedResource> {
            if (apiName == null) {
                unavailable += section
                return emptyList()
            }
            return runCatching {
                gateway.resourceList(apiName, listOf("list"), *roots)
            }.getOrElse {
                unavailable += section
                emptyList()
            }
        }
        val hosts = optional(
            VirtualMachineSection.HOSTS,
            hostApi,
            "hosts",
            "host",
            "data",
            "list",
        )
        val storages = optional(
            VirtualMachineSection.STORAGES,
            storageApi,
            "repos",
            "storages",
            "data",
            "list",
        )
        val networks = optional(
            VirtualMachineSection.NETWORKS,
            networkApi,
            "networks",
            "network",
            "data",
            "list",
        )
        val images = optional(
            VirtualMachineSection.IMAGES,
            imageApi,
            "images",
            "image",
            "data",
            "list",
        )
        val protectionData = if (gateway.supports("SYNO.Virtualization.GuestProtect.Plan")) {
            runCatching {
                gateway.firstSuccessful(
                    "SYNO.Virtualization.GuestProtect.Plan",
                    listOf("list", "get"),
                )
            }.getOrNull()
        } else {
            unavailable += VirtualMachineSection.PROTECTION
            null
        }
        if (gateway.supports("SYNO.Virtualization.GuestProtect.Plan") && protectionData == null) {
            unavailable += VirtualMachineSection.PROTECTION
        }
        val plans = protectionData?.let {
            gateway.genericResources(
                it,
                "plans",
                "plan",
                "protection_plans",
                "guest_protects",
                "data",
                "list",
            )
        }.orEmpty()
        val schedules = protectionData?.let {
            gateway.genericResources(it, "schedule_policies", "schedules", "schedule_policy")
        }.orEmpty()
        val retentions = protectionData?.let {
            gateway.genericResources(it, "retention_policies", "retentions", "retention_policy")
        }.orEmpty()
        val logs = if (gateway.supports("SYNO.Virtualization.Log")) {
            runCatching { gateway.logs() }.getOrElse {
                unavailable += VirtualMachineSection.LOGS
                emptyList()
            }
        } else {
            unavailable += VirtualMachineSection.LOGS
            emptyList()
        }
        val taskCenter = gateway.taskCenter()
        if (taskCenter.second != VirtualMachineTaskCenterState.AVAILABLE) {
            unavailable += VirtualMachineSection.TASKS
        }
        return VirtualMachineOverview(
            machines = machines,
            hosts = hosts,
            storages = storages,
            networks = networks,
            images = images,
            protectionPlans = plans,
            protectionSchedules = schedules,
            retentionPolicies = retentions,
            logs = logs,
            machineHardware = officialGuestRead?.second.orEmpty(),
            tasks = taskCenter.first,
            taskCenterState = taskCenter.second,
            unavailableSections = unavailable,
        )
    }
}

package io.github.qwertyuiop1995.dsmnativeclient.data.container

import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerOverview
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerRegistryImage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerSection
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResource
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.data.parseVirtualizationLogs
import io.github.qwertyuiop1995.dsmnativeclient.network.int
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Container Manager 的内部数据边界。
 *
 * `DsmRepository` 仍是应用层唯一入口；本类只通过窄 gateway 复用会话请求、统一写操作结果
 * 和并发门禁，避免复制 Repository 的公共基础设施或扩大其私有可见性。
 */
internal class ContainerRepository(
    private val gateway: ContainerRepositoryGateway,
) {
    internal val managementLock = Mutex()
    internal suspend fun managementCall(api: String, method: String, parameters: Map<String, JsonElement> = emptyMap(), write: Boolean = false): JsonObject {
        if (!gateway.supportsVersion(api, 1)) containerUnsupported()
        return gateway.managementCall(api, method, parameters, write)
    }
    internal suspend fun requireManagementWrite() = gateway.requireManagementWrite()
    internal fun supportsEvents() = gateway.supportsVersion("SYNO.Docker.Log", 1)
    suspend fun overview(): ContainerOverview = readOverview()

    fun supportsRegistry(): Boolean = gateway.supportsVersion("SYNO.Docker.Registry", 1)

    /** 旧门面没有原目标快照和持久检查点，保持关闭；正式管理入口使用下方扩展与实际能力/权限检查。 */
    fun supportsVerifiedWrites(): Boolean = false

    suspend fun searchRegistry(query: String): List<ContainerRegistryImage> {
        val normalizedQuery = query.trim()
        require(normalizedQuery.isNotEmpty() && normalizedQuery.length <= 200)
        if (!supportsRegistry()) throw DsmFailure(
            102,
            "Container image search is unavailable",
            "Search for the image in Container Manager.",
            kind = DsmErrorKind.FEATURE_UNSUPPORTED,
        )
        val data = managementCall("SYNO.Docker.Registry", "search", mapOf(
            "offset" to kotlinx.serialization.json.JsonPrimitive(0), "limit" to kotlinx.serialization.json.JsonPrimitive(50),
            "page_size" to kotlinx.serialization.json.JsonPrimitive(50), "q" to kotlinx.serialization.json.JsonPrimitive(normalizedQuery)))
        val rows = data["data"] as? kotlinx.serialization.json.JsonArray ?: containerInvalid()
        return rows.map { element ->
            val item = element as? JsonObject ?: containerInvalid()
            val name = gateway.firstNonBlank(item, "name", "repository", "repo") ?: containerInvalid()
            if (!validImageTarget(name, "latest")) containerInvalid()
            ContainerRegistryImage(name, gateway.firstNonBlank(item, "registry") ?: "docker.io",
                gateway.firstNonBlank(item, "description"), item.int("star_count") ?: item.int("stars") ?: 0,
                gateway.bool(item, "is_official") ?: gateway.bool(item, "official") ?: false,
                gateway.bool(item, "is_automated") ?: gateway.bool(item, "automated") ?: false,
                gateway.bool(item, "is_trusted") ?: gateway.bool(item, "trusted") ?: false)
        }.distinctBy(ContainerRegistryImage::id)
    }

    suspend fun registryTags(repository: String): List<String> {
        val normalizedRepository = repository.trim()
        require(normalizedRepository.isNotEmpty() && normalizedRepository.length <= 500)
        val data = managementCall("SYNO.Docker.Registry", "tags", mapOf("repo" to JsonPrimitive(normalizedRepository)))
        val sources = listOf("data", "tags", "items", "_array").mapNotNull { data[it] }
        if (sources.isEmpty()) containerInvalid()
        val results = sources.map { value ->
            val rows = value as? kotlinx.serialization.json.JsonArray ?: containerInvalid()
            rows.map { element ->
                val tag = if (element is JsonObject) {
                    val fields = listOf("tag", "name").mapNotNull { element[it] }
                    if (fields.isEmpty()) containerInvalid()
                    val names = fields.map { it.containerString() ?: containerInvalid() }.distinct()
                    if (names.size != 1) containerInvalid()
                    names.single()
                } else element.containerString() ?: containerInvalid()
                if (!validImageTarget(normalizedRepository, tag)) containerInvalid()
                tag
            }.distinct()
        }
        if (results.distinct().size != 1) containerInvalid()
        return results.singleOrNull() ?: results.first()
    }

    suspend fun controlResult(id: String, action: String): MutationResult {
        if (!supportsVerifiedWrites()) return gateway.unsupportedMutation(
            "containerControl",
            "container.control.behavior-unverified",
        )
        val normalizedId = id.trim()
        if (normalizedId.isEmpty() || action !in setOf("start", "stop", "restart")) {
            return gateway.mutationResult(
                operation = "containerControl",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "container.control.invalid-input",
            )
        }
        val expectedState = if (action == "stop") ResourceState.STOPPED else ResourceState.RUNNING
        return gateway.verifiedMutation(
            operation = "containerControl",
            targetKey = "container:$normalizedId",
            requiredApi = "SYNO.Docker.Container",
            preflight = {
                gateway.resourceList(
                    "SYNO.Docker.Container",
                    listOf("list", "get"),
                    "containers",
                ).any { it.id == normalizedId }
            },
            submit = {
                gateway.call("SYNO.Docker.Container", action, mapOf("id" to normalizedId))
            },
            verify = {
                gateway.resourceList(
                    "SYNO.Docker.Container",
                    listOf("list", "get"),
                    "containers",
                ).any { it.id == normalizedId && it.state == expectedState }
            },
        )
    }

    suspend fun deleteResult(id: String): MutationResult {
        if (!supportsVerifiedWrites()) return gateway.unsupportedMutation(
            "containerDelete",
            "container.delete.behavior-unverified",
        )
        return gateway.deleteResourceResult(
            operation = "containerDelete",
            targetType = "container",
            id = id,
            apiName = "SYNO.Docker.Container",
            root = "containers",
            method = "delete",
        )
    }

    suspend fun deleteImageResult(id: String): MutationResult {
        if (!supportsVerifiedWrites()) return gateway.unsupportedMutation(
            "containerImageDelete",
            "container.image.delete.behavior-unverified",
        )
        return gateway.deleteResourceResult(
            operation = "containerImageDelete",
            targetType = "container-image",
            id = id,
            apiName = "SYNO.Docker.Image",
            root = "images",
            method = "delete",
        )
    }

    suspend fun createNetworkResult(name: String, driver: String): MutationResult {
        if (!supportsVerifiedWrites()) return gateway.unsupportedMutation(
            "containerNetworkCreate",
            "container.network.create.behavior-unverified",
        )
        val normalizedName = name.trim()
        if (normalizedName.isEmpty() || driver !in setOf("bridge", "host", "macvlan", "ipvlan")) {
            return gateway.mutationResult(
                operation = "containerNetworkCreate",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "container.network.create.invalid-input",
            )
        }
        return gateway.verifiedMutation(
            operation = "containerNetworkCreate",
            targetKey = "container-network-name:${normalizedName.lowercase(Locale.ROOT)}",
            requiredApi = "SYNO.Docker.Network",
            preflight = {
                gateway.resourceList(
                    "SYNO.Docker.Network",
                    listOf("list", "get"),
                    "networks",
                ).none { it.name.equals(normalizedName, ignoreCase = true) }
            },
            submit = {
                gateway.call(
                    "SYNO.Docker.Network",
                    "create",
                    mapOf("name" to normalizedName, "driver" to driver),
                )
            },
            verify = {
                gateway.resourceList(
                    "SYNO.Docker.Network",
                    listOf("list", "get"),
                    "networks",
                ).any { it.name.equals(normalizedName, ignoreCase = true) }
            },
        )
    }

    suspend fun deleteNetworkResult(id: String): MutationResult {
        if (!supportsVerifiedWrites()) return gateway.unsupportedMutation(
            "containerNetworkDelete",
            "container.network.delete.behavior-unverified",
        )
        return gateway.deleteResourceResult(
            operation = "containerNetworkDelete",
            targetType = "container-network",
            id = id,
            apiName = "SYNO.Docker.Network",
            root = "networks",
            method = "remove",
        )
    }
}

internal interface ContainerRepositoryGateway {
    suspend fun requireManagementWrite(): Unit = containerUnsupported()
    suspend fun managementCall(api: String, method: String, parameters: Map<String, JsonElement>, write: Boolean): JsonObject {
        if (write) containerUnsupported()
        return call(api, method, parameters.mapValues { it.value.toString() }, 1)
    }
    fun supports(apiName: String): Boolean

    fun supportsVersion(apiName: String, version: Int): Boolean

    suspend fun call(
        apiName: String,
        method: String,
        parameters: Map<String, String> = emptyMap(),
        version: Int? = null,
    ): JsonObject

    fun strictResources(data: JsonObject, vararg roots: String): List<ManagedResource>

    fun elements(data: JsonObject, key: String): List<JsonElement>

    fun firstNonBlank(data: JsonObject, vararg keys: String): String?

    fun bool(data: JsonObject, key: String): Boolean?

    suspend fun resourceList(
        apiName: String,
        methods: List<String>,
        vararg roots: String,
    ): List<ManagedResource>

    fun unsupportedMutation(operation: String, diagnosticTag: String): MutationResult

    fun mutationResult(
        operation: String,
        status: MutationResultStatus,
        submitted: Boolean,
        requiresRefresh: Boolean = false,
        errorCategory: MutationErrorCategory? = null,
        diagnosticTag: String,
        affectedCount: Int = 1,
    ): MutationResult

    suspend fun verifiedMutation(
        operation: String,
        targetKey: String,
        requiredApi: String,
        preflight: suspend () -> Boolean,
        submit: suspend () -> Unit,
        verify: suspend () -> Boolean,
    ): MutationResult

    suspend fun deleteResourceResult(
        operation: String,
        targetType: String,
        id: String,
        apiName: String,
        root: String,
        method: String,
    ): MutationResult
}

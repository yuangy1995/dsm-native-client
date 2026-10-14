package io.github.qwertyuiop1995.dsmnativeclient.data.container

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.security.MessageDigest
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable internal enum class ContainerStage { PREPARED, SUBMITTED, ACCEPTED, VERIFIED, REJECTED, CANCELLED }

internal fun containerDigest(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
    .joinToString("") { "%02x".format(it) }
internal fun containerIdentity(target: ContainerControlTarget) = containerDigest(JsonArray(listOf(JsonPrimitive(target.id), JsonPrimitive(target.name))).toString())
internal enum class ContainerProblem { CHANGED, STORAGE }
internal class ContainerFailure(val problem: ContainerProblem) : RuntimeException(problem.name)
internal fun containerInvalid(): Nothing = throw DsmFailure(null, "Container information could not be read", "Refresh Container Manager and try again.", kind = DsmErrorKind.INVALID_RESPONSE)
internal fun containerConflict(): Nothing = throw ContainerFailure(ContainerProblem.CHANGED)
internal fun containerUnsupported(): Nothing = throw DsmFailure(null, "Container action unavailable", "Manage this container in DSM.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
internal fun JsonElement?.containerString(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf { it.isNotBlank() }
internal fun JsonElement?.containerBool(): Boolean? = (this as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull

/** 已记录的全量 list；畸形分页、缺身份和重复身份不能成为删除或控制的完成证据。 */
internal fun containerRows(data: JsonObject, root: String): List<JsonObject> {
    val rows = (data[root] as? JsonArray)?.map { it as? JsonObject ?: containerInvalid() } ?: containerInvalid()
    for ((field, expected) in listOf("offset" to 0L, "total" to rows.size.toLong())) {
        data[field]?.let { element ->
            val primitive = element as? JsonPrimitive ?: containerInvalid()
            if (primitive.isString || primitive.longOrNull != expected) containerInvalid()
        }
    }
    return rows
}

internal suspend fun ContainerRepository.controlTargets(resolveProjects: Boolean = true): List<ContainerControlTarget> {
    val data = managementCall("SYNO.Docker.Container", "list", mapOf("offset" to JsonPrimitive(0), "limit" to JsonPrimitive(-1), "type" to JsonPrimitive("all")))
    val rows = containerRows(data, "containers")
    val projects = rows.mapNotNull { row -> (row["Labels"] as? JsonObject)?.get("com.docker.compose.project").containerString() }.toSet()
    val ownership = if (!resolveProjects) null else if (projects.isEmpty()) emptyMap() else {
        val values = managementCall("SYNO.Docker.Project", "list")
        val result = mutableMapOf<String, Boolean>()
        for (entry in values.values) {
            val item = entry as? JsonObject ?: containerInvalid()
            val name = item["name"].containerString() ?: containerInvalid()
            val managed = item["is_package"]?.let { it.containerBool() ?: containerInvalid() } ?: false
            if (result.put(name, managed) != null) containerInvalid()
        }
        result
    }
    val targets = rows.map { row ->
        val state = row["State"] as? JsonObject
        val labels = row["Labels"] as? JsonObject
        val project = labels?.get("com.docker.compose.project").containerString()
        var managed = row["is_package"].containerBool()
        if (managed != true && row["Labels"] != null && row["Labels"] != JsonNull && labels == null) managed = null
        if (managed != true && labels?.containsKey("com.docker.compose.project") == true && project == null) managed = null
        if (managed == false && project != null) managed = if (ownership == null) null else ownership[project] ?: false
        ContainerControlTarget(row["id"].containerString() ?: containerInvalid(), row["name"].containerString() ?: containerInvalid(),
            state?.get("Running").containerBool(), state?.get("Paused").containerBool(), state?.get("Restarting").containerBool(),
            state?.get("StartedAt").containerString()?.takeUnless { it.startsWith("0001-") }?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() }, managed)
    }
    if (targets.map { it.id }.distinct().size != targets.size || targets.map { it.name }.distinct().size != targets.size) containerInvalid()
    return targets
}

/** 接受后只回读原身份，重启还必须有严格增加的启动时间。任何恢复入口均不提交。 */
internal suspend fun ContainerRepository.performControl(target: ContainerControlTarget, action: ContainerAction, checkpoint: (ContainerStage) -> Unit) {
    if (!managementLock.tryLock()) containerConflict()
    var submitted = false
    try {
        val current = controlTargets().singleOrNull { it.id == target.id } ?: containerConflict()
        if (current != target || !current.supports(action)) containerConflict()
        currentCoroutineContext().ensureActive()
        requireManagementWrite()
        checkpoint(ContainerStage.SUBMITTED)
        submitted = true
        val parameters = mutableMapOf<String, JsonElement>("name" to JsonPrimitive(target.name))
        if (action == ContainerAction.DELETE) {
            parameters["force"] = JsonPrimitive(false)
            parameters["preserve_profile"] = JsonPrimitive(false)
        }
        try { managementCall("SYNO.Docker.Container", action.name.lowercase(java.util.Locale.ROOT), parameters, write = true) }
        catch (error: Exception) {
            if (containerExplicitRejection(error)) checkpoint(ContainerStage.REJECTED)
            throw error
        }
        checkpoint(ContainerStage.ACCEPTED)
        if (recoverControl(containerDigest(target.id), containerIdentity(target), action, target.startedAt)) checkpoint(ContainerStage.VERIFIED)
    } catch (error: Exception) {
        if (!submitted) checkpoint(ContainerStage.CANCELLED)
        throw error
    } finally { managementLock.unlock() }
}

internal suspend fun ContainerRepository.recoverControl(idDigest: String, identity: String, action: ContainerAction, startedAt: Long?): Boolean {
    val current = controlTargets().singleOrNull { containerDigest(it.id) == idDigest }
    if (action == ContainerAction.DELETE) return current == null
    return current != null && containerIdentity(current) == identity && current.matches(action, startedAt)
}

internal fun containerExplicitRejection(error: Exception) = error !is CancellationException && error is DsmFailure &&
    (error.isExplicitApiRejection || error.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.AUTHENTICATION_FAILED))

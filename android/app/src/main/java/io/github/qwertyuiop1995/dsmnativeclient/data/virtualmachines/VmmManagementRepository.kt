package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.security.MessageDigest
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable internal enum class VmmSource(val guestApi: String, val readVersion: Int) {
    PUBLIC("SYNO.Virtualization.API.Guest", 1), INTERNAL("SYNO.Virtualization.Guest", 2)
}
@Serializable internal enum class VmmAction(val command: String) {
    START("poweron"), SHUTDOWN("shutdown"), POWER_OFF("poweroff"), RESTART("reboot"), DELETE("delete")
}
@Serializable internal enum class VmmStage { PREPARED, SUBMITTED, ACCEPTED, VERIFIED, REJECTED, CANCELLED }
internal enum class VmmProblem { CHANGED, STORAGE }
internal class VmmFailure(val problem: VmmProblem) : RuntimeException(problem.name)
internal fun vmmDigest(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
internal fun vmmIdentity(target: VmmControlTarget) = vmmDigest(JsonArray(listOf(JsonPrimitive(target.id), JsonPrimitive(target.name))).toString())
internal fun vmmConflict(): Nothing = throw VmmFailure(VmmProblem.CHANGED)
internal fun vmmInvalid(): Nothing = throw DsmFailure(null, "Virtual machine information unavailable", "Refresh Virtual Machine Manager and try again.", kind = DsmErrorKind.INVALID_RESPONSE)
internal fun vmmUnsupported(): Nothing = throw DsmFailure(null, "Virtual machine action unavailable", "Manage this virtual machine in DSM.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
internal fun JsonElement?.vmmText(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf { it.isNotEmpty() && it.none(Char::isISOControl) }
internal fun validVmmId(value: String) = value.isNotEmpty() && value == value.trim() && value.none { it.isISOControl() || it == ',' || it == '\\' }
internal fun vmmExplicitRejection(error: Exception) = error is DsmFailure &&
    (error.isExplicitApiRejection || error.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.AUTHENTICATION_FAILED))

internal data class VmmControlTarget(val id: String, val name: String, val status: String, val actions: Set<VmmAction>) {
    fun supports(action: VmmAction) = action in actions && status == if (action in setOf(VmmAction.START, VmmAction.DELETE)) "shutdown" else "running"
    fun verifies(action: VmmAction) = when (action) {
        VmmAction.START -> status == "running"
        VmmAction.SHUTDOWN, VmmAction.POWER_OFF -> status == "shutdown"
        // 内部 reboot 没有已记录的关联终态；不能把仍运行当作本次重启完成。
        VmmAction.RESTART, VmmAction.DELETE -> false
    }
    val state get() = when (status) { "running" -> ResourceState.RUNNING; "shutdown" -> ResourceState.STOPPED; else -> ResourceState.UNKNOWN }
}

/** 仅固定已记录的接口版本，公开优先；失败后不换写法或重发。 */
internal interface VmmManagementGateway {
    fun supports(api: String, version: Int): Boolean
    suspend fun requireWrite(source: VmmSource)
    suspend fun call(api: String, method: String, version: Int, fields: Map<String, JsonElement> = emptyMap(), write: Boolean = false): JsonObject
}
internal class VmmManagementRepository(private val gateway: VmmManagementGateway) {
    internal val mutationLock = Mutex()
    internal fun supports(api: String, version: Int) = gateway.supports(api, version)
    internal suspend fun call(api: String, method: String, version: Int, fields: Map<String, JsonElement> = emptyMap(), write: Boolean = false): JsonObject {
        if (!supports(api, version)) vmmUnsupported()
        return gateway.call(api, method, version, fields, write)
    }
    internal suspend fun requireWrite(source: VmmSource) = gateway.requireWrite(source)
    fun guestSource(): VmmSource = if (supports(VmmSource.PUBLIC.guestApi, 1)) VmmSource.PUBLIC
        else VmmSource.INTERNAL.also { if (!supports(it.guestApi, 2)) vmmUnsupported() }
    fun controlSource(action: VmmAction): VmmSource {
        val source = if (action == VmmAction.DELETE) guestSource() else
            if (action != VmmAction.RESTART && supports("SYNO.Virtualization.API.Guest.Action", 1)) VmmSource.PUBLIC else VmmSource.INTERNAL
        if (!supports(source.guestApi, source.readVersion) || !supports(if (action == VmmAction.DELETE) source.guestApi else "${source.guestApi}.Action", 1)) vmmUnsupported()
        return source
    }
    private fun target(row: JsonObject, source: VmmSource): VmmControlTarget {
        val id = row["guest_id"].vmmText()?.takeIf(::validVmmId) ?: vmmInvalid()
        val name = row[if (source == VmmSource.PUBLIC) "guest_name" else "name"].vmmText() ?: vmmInvalid()
        val status = row["status"].vmmText() ?: vmmInvalid()
        return VmmControlTarget(id, name, status, VmmAction.entries.filter { runCatching { controlSource(it) }.isSuccess }.toSet())
    }
    suspend fun controlTargets(source: VmmSource = guestSource()): List<VmmControlTarget> {
        val data = call(source.guestApi, "list", source.readVersion)
        val rows = vmmRows(data, "guests")
        val targets = rows.map { target(it, source) }
        if (targets.map { it.id }.distinct().size != targets.size) vmmInvalid()
        return targets
    }
    private suspend fun controlTarget(id: String, source: VmmSource): VmmControlTarget =
        target(call(source.guestApi, "get", source.readVersion, mapOf("guest_id" to JsonPrimitive(id))), source).also { if (it.id != id) vmmInvalid() }

    suspend fun performControl(expected: VmmControlTarget, action: VmmAction, source: VmmSource, checkpoint: (VmmStage) -> Unit) {
        if (!mutationLock.tryLock()) vmmConflict()
        var submitted = false
        try {
            if (controlSource(action) != source) vmmConflict()
            requireWrite(source)
            val current = if (action == VmmAction.DELETE) controlTargets(source).singleOrNull { it.id == expected.id } ?: vmmConflict()
                else controlTarget(expected.id, source)
            if (current != expected || !current.supports(action)) vmmConflict()
            currentCoroutineContext().ensureActive()
            checkpoint(VmmStage.SUBMITTED); submitted = true
            val fields = mutableMapOf<String, JsonElement>("guest_id" to JsonPrimitive(expected.id))
            if (source == VmmSource.INTERNAL && action != VmmAction.DELETE) fields["action"] = JsonPrimitive(action.command)
            try {
                call(if (action == VmmAction.DELETE) source.guestApi else "${source.guestApi}.Action",
                    if (source == VmmSource.INTERNAL && action != VmmAction.DELETE) "pwr_ctl" else action.command, 1, fields, write = true)
            } catch (error: Exception) {
                if (vmmExplicitRejection(error)) checkpoint(VmmStage.REJECTED)
                throw error
            }
            checkpoint(VmmStage.ACCEPTED)
            if (recoverControl(vmmDigest(expected.id), vmmIdentity(expected), action, source)) checkpoint(VmmStage.VERIFIED)
        } catch (error: Exception) {
            if (!submitted) checkpoint(VmmStage.CANCELLED)
            throw error
        } finally { mutationLock.unlock() }
    }
    /** 调用者必须已经持有接受回执；这里只读取原来源与原身份。 */
    suspend fun recoverControl(id: String, identity: String, action: VmmAction, source: VmmSource): Boolean {
        val target = controlTargets(source).singleOrNull { vmmDigest(it.id) == id }
        return if (action == VmmAction.DELETE) target == null else target != null && vmmIdentity(target) == identity && target.verifies(action)
    }
}

internal fun vmmRows(data: JsonObject, key: String): List<JsonObject> {
    val rows = (data[key] as? JsonArray)?.map { it as? JsonObject ?: vmmInvalid() } ?: vmmInvalid()
    for ((field, count) in listOf("offset" to 0L, "total" to rows.size.toLong())) data[field]?.let {
        val value = it as? JsonPrimitive ?: vmmInvalid()
        if (value.isString || value.longOrNull != count) vmmInvalid()
    }
    return rows
}

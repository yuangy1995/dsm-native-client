package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.packageDigest
import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

internal data class NasConnectionDirectory(val rows: List<ActiveConnection>, val complete: Boolean)
@Serializable internal enum class NasConnectionStage { PREPARED, SUBMITTED, ACCEPTED, VERIFIED, REJECTED, CANCELLED }
@Serializable internal data class NasConnectionIdentity(val web: Boolean, val primary: String,
    val related: Set<String>, val similarity: String) {
    override fun toString() = "NasConnectionIdentity(redacted)"
}
internal val ActiveConnection.isWebConnection get() = type.equals("HTTP/HTTPS", true)
internal fun connectionIdentity(row: ActiveConnection): NasConnectionIdentity {
    val keys = connectionKeys(row)
    val primary = if (row.isWebConnection) row.deviceId?.takeIf { it.isNotBlank() }?.let { packageDigest("web:$it") }
        else row.processId?.takeIf { it.isNotBlank() }?.let { packageDigest("service:$it") }
    return NasConnectionIdentity(row.isWebConnection, primary ?: connectionConflict(), keys, connectionSimilarity(row))
}
private fun connectionKeys(row: ActiveConnection): Set<String> = buildSet {
    row.deviceId?.takeIf { it.isNotBlank() }?.let { add(packageDigest("web:$it")) }
    row.processId?.takeIf { it.isNotBlank() }?.let { add(packageDigest("service:$it")) }
}
private fun connectionSimilarity(row: ActiveConnection) = packageDigest(JsonArray(listOf(
    row.user, row.client, row.type.orEmpty().lowercase(java.util.Locale.ROOT)).map(::JsonPrimitive)).toString())
internal fun connectionAbsent(expected: NasConnectionIdentity, directory: NasConnectionDirectory): Boolean = directory.complete &&
    directory.rows.none { row ->
        connectionKeys(row).any { it in expected.related } ||
            (if (expected.web) row.deviceId else row.processId).isNullOrBlank() && connectionSimilarity(row) == expected.similarity
    }

/** 列表与管理共用解码；不完整目录仍可查看，但不能用来断开或认领目标消失。 */
internal fun decodeConnections(data: JsonObject): NasConnectionDirectory {
    fun invalid(): Nothing = throw DsmFailure(null, "Connection list is incomplete", "Refresh connections or sign in again.", kind = DsmErrorKind.INVALID_RESPONSE)
    fun text(row: JsonObject, key: String): String? {
        val value = row[key] ?: return null
        if (value == JsonNull) return null
        return (value as? JsonPrimitive)?.takeIf { it.isString }?.content?.also { if (it.any(Char::isISOControl)) invalid() } ?: invalid()
    }
    fun bool(row: JsonObject, key: String): Boolean? {
        val value = row[key] ?: return null
        if (value == JsonNull) return null
        return (value as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: invalid()
    }
    val rows = data["items"] as? JsonArray ?: invalid()
    if (rows.size > 500) invalid()
    val total = data["total"]?.let { value ->
        (value as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull?.takeIf { it >= rows.size } ?: invalid()
    }
    val complete = total?.let { it == rows.size } ?: (rows.size < 500)
    val decoded = rows.mapIndexed { index, element ->
        val row = element as? JsonObject ?: invalid()
        val pid = row["pid"]?.let { value ->
            if (value == JsonNull) null else (value as? JsonPrimitive)?.let {
                if (it.isString) text(row, "pid") else it.intOrNull?.takeIf { n -> n >= 0 }?.toString() ?: invalid()
            } ?: invalid()
        }
        val did = text(row, "did"); val type = text(row, "type"); val who = text(row, "who"); val from = text(row, "from")
        val description = text(row, "descr"); val protocol = text(row, "protocol"); val location = text(row, "location")
        val current = bool(row, "is_current_connected"); val permission = bool(row, "can_be_kicked")
        val time = row["time"]?.let { value ->
            if (value == JsonNull) null else (value as? JsonPrimitive)?.let {
                if (it.isString) text(row, "time") else it.longOrNull?.toString() ?: invalid()
            } ?: invalid()
        }
        val web = type.equals("HTTP/HTTPS", true); val rawId = if (web) did else pid
        val material = rawId?.takeIf { it.isNotBlank() } ?: JsonArray(listOf(index.toString(), who, from, type, time).map { it?.let(::JsonPrimitive) ?: JsonNull }).toString()
        val id = UUID.nameUUIDFromBytes("${if (web) "http" else "service"}:$material".toByteArray()).toString()
        ActiveConnection(id, who.orEmpty(), protocol ?: type.orEmpty(), from.orEmpty(), time?.toLongOrNull(), current == true,
            pid, did, type, description,
            canDisconnect = complete && permission == true && !rawId.isNullOrBlank() && !who.isNullOrBlank() &&
                !from.isNullOrBlank() && !type.isNullOrBlank() && (!web || description != null),
            isCurrentKnown = current != null, reportedTime = time, location = location)
    }
    val keys = decoded.flatMap(::connectionKeys).groupingBy { it }.eachCount()
    return NasConnectionDirectory(decoded.mapIndexed { index, row ->
        val ambiguous = connectionKeys(row).any { keys.getValue(it) > 1 }
        row.copy(id = if (ambiguous) "${row.id}:$index" else row.id, canDisconnect = row.canDisconnect && !ambiguous)
    }, complete)
}

/** 原目标全字段预检；写入只有一次，后续恢复永远只读取。 */
internal class NasConnectionRepository(private val gateway: NasManagementGateway, private val supports: (String, Int) -> Boolean) {
    private val lock = Mutex()
    suspend fun read(): NasConnectionDirectory {
        capability()
        return decodeConnections(gateway.call("SYNO.Core.CurrentConnection", "list", 1, mapOf(
            "start" to JsonPrimitive(0), "limit" to JsonPrimitive(500), "sort_by" to JsonPrimitive("time"), "sort_direction" to JsonPrimitive("DESC"))))
    }
    private fun capability() {
        if (!supports("SYNO.Core.CurrentConnection", 1)) throw DsmFailure(null, "Connection management unavailable", "Open Resource Monitor in DSM.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
    }
    private suspend fun access() {
        capability()
        gateway.requireWriteAccess()
    }
    suspend fun recover(): NasConnectionDirectory { access(); return read() }
    suspend fun disconnect(original: ActiveConnection, checkpoint: (NasConnectionStage) -> Unit): NasConnectionDirectory? {
        if (!lock.tryLock()) connectionConflict()
        var submitted = false
        try {
            access()
            val current = read()
            if (!current.complete || !original.canDisconnect || current.rows.singleOrNull { it.id == original.id } != original) connectionConflict()
            currentCoroutineContext().ensureActive()
            val common = mapOf("who" to JsonPrimitive(original.user), "from" to JsonPrimitive(original.client))
            val target = if (original.isWebConnection) common + mapOf("did" to JsonPrimitive(requireNotNull(original.deviceId)), "descr" to JsonPrimitive(requireNotNull(original.description)))
                else common + mapOf("pid" to JsonPrimitive(requireNotNull(original.processId)), "type" to JsonPrimitive(requireNotNull(original.type)))
            checkpoint(NasConnectionStage.SUBMITTED); submitted = true
            try {
                gateway.call("SYNO.Core.CurrentConnection", "kick_connection", 1, mapOf(
                    "service_conn" to JsonArray(if (original.isWebConnection) emptyList() else listOf(JsonObject(target))),
                    "http_conn" to JsonArray(if (original.isWebConnection) listOf(JsonObject(target)) else emptyList())), write = true)
            } catch (error: Exception) {
                if (directoryExplicitRejection(error)) { checkpoint(NasConnectionStage.REJECTED); throw error }
                if (directoryTrustFailure(error) || error is kotlinx.coroutines.CancellationException) throw error
                return verify(connectionIdentity(original), checkpoint)
            }
            checkpoint(NasConnectionStage.ACCEPTED)
            return verify(connectionIdentity(original), checkpoint)
        } catch (error: Exception) {
            if (!submitted) checkpoint(NasConnectionStage.CANCELLED)
            throw error
        } finally { lock.unlock() }
    }
    private suspend fun verify(identity: NasConnectionIdentity, checkpoint: (NasConnectionStage) -> Unit): NasConnectionDirectory {
        val directory = recover()
        if (connectionAbsent(identity, directory)) checkpoint(NasConnectionStage.VERIFIED)
        return directory
    }
}

internal fun connectionConflict(): Nothing = throw DsmFailure(null, "Connection changed", "Refresh connections and choose the target again.", kind = DsmErrorKind.NAS_CONNECTION_CHANGED)

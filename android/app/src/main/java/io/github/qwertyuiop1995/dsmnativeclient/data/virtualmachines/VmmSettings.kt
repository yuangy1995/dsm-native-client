package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*

@Serializable internal data class VmmConfiguration(val name: String, val description: String?, val cpu: Int?,
    val memoryMiB: Int?, val priority: Int?, val startup: Int?) {
    fun digest(source: VmmSource) = vmmDigest(Json.encodeToString(if (source == VmmSource.PUBLIC) copy(priority = null) else this))
}
internal data class VmmSettings(val id: String, val status: String, val source: VmmSource, val configuration: VmmConfiguration) {
    val editable get() = status in setOf("running", "shutdown")
    val hardwareEditable get() = status == "shutdown"
    override fun toString() = "VmmSettings($source)"
}
internal val vmmPriorities = listOf(8, 64, 256, 512, 1024)
internal fun validVmmSettingsName(name: String) = name.isNotBlank() && name == name.trim() && name.length <= 64 && name.none(Char::isISOControl)
internal fun VmmSettings.validChange(next: VmmConfiguration): Boolean {
    val old = configuration
    return editable && next != old && validVmmSettingsName(next.name) &&
        (next.description == old.description || old.description != null && next.description != null && next.description.length <= 1024) &&
        (next.cpu == old.cpu || hardwareEditable && old.cpu != null && next.cpu in 1..64) &&
        (next.memoryMiB == old.memoryMiB || hardwareEditable && old.memoryMiB != null && next.memoryMiB in 128..1_048_576) &&
        (next.priority == old.priority || old.priority != null && next.priority in vmmPriorities) &&
        (next.startup == old.startup || old.startup != null && next.startup in 0..2)
}
internal fun VmmSettings.writeSource(next: VmmConfiguration) = if (next.priority != configuration.priority) VmmSource.INTERNAL else source

internal fun parseVmmSettings(row: JsonObject, source: VmmSource): VmmSettings {
    fun integer(key: String, range: LongRange): Long? {
        val raw = row[key] ?: return null
        val value = raw as? JsonPrimitive ?: vmmInvalid()
        return value.longOrNull?.takeIf { !value.isString && it in range } ?: vmmInvalid()
    }
    val id = row["guest_id"].vmmText()?.takeIf(::validVmmId) ?: vmmInvalid()
    val name = row[if (source == VmmSource.PUBLIC) "guest_name" else "name"].vmmText() ?: vmmInvalid()
    val status = row["status"].vmmText() ?: vmmInvalid()
    val description = row[if (source == VmmSource.PUBLIC) "description" else "desc"]?.let {
        (it as? JsonPrimitive)?.takeIf { value -> value.isString }?.content ?: vmmInvalid()
    }
    val memory = integer("vram_size", 1..if (source == VmmSource.INTERNAL) 1_073_741_824L else 1_048_576L)
    if (source == VmmSource.INTERNAL && memory != null && memory % 1024 != 0L) vmmInvalid()
    return VmmSettings(id, status, source, VmmConfiguration(name, description, integer("vcpu_num", 1L..64L)?.toInt(),
        memory?.let { if (source == VmmSource.INTERNAL) it / 1024 else it }?.toInt(),
        if (source == VmmSource.INTERNAL) integer("cpu_weight", 1..Int.MAX_VALUE.toLong())?.toInt() else null,
        integer("autorun", 0L..2L)?.toInt()))
}

internal suspend fun VmmManagementRepository.readSettings(id: String, source: VmmSource): VmmSettings {
    if (!validVmmId(id)) vmmInvalid()
    return parseVmmSettings(call(source.guestApi, "get", source.readVersion, mapOf("guest_id" to JsonPrimitive(id))), source)
        .also { if (it.id != id) vmmInvalid() }
}
/** 公开字段优先；附加内部优先级必须来自完全相同的身份、状态和基础字段。 */
internal suspend fun VmmManagementRepository.settings(id: String): VmmSettings {
    val source = guestSource()
    val baseline = readSettings(id, source)
    if (source != VmmSource.PUBLIC || !supports(VmmSource.INTERNAL.guestApi, 2) || !supports(VmmSource.INTERNAL.guestApi, 1)) return baseline
    return try {
        val detail = readSettings(id, VmmSource.INTERNAL)
        if (detail.copy(source = VmmSource.PUBLIC, configuration = detail.configuration.copy(priority = null)) == baseline)
            baseline.copy(configuration = baseline.configuration.copy(priority = detail.configuration.priority)) else baseline
    } catch (error: Exception) { vmmRethrowCritical(error); baseline }
}

internal suspend fun VmmManagementRepository.saveSettings(expected: VmmSettings, desired: VmmConfiguration, checkpoint: (VmmStage) -> Unit) {
    if (!mutationLock.tryLock()) vmmConflict()
    var submitted = false
    try {
        if (!expected.validChange(desired)) vmmConflict()
        val source = expected.writeSource(desired)
        requireWrite(source)
        val comparison = expected.copy(source = source, configuration = if (source == VmmSource.PUBLIC) expected.configuration.copy(priority = null) else expected.configuration)
        if (readSettings(expected.id, source) != comparison) vmmConflict()
        val targets = controlTargets(source)
        if (targets.singleOrNull { it.id == expected.id }?.let { it.name == expected.configuration.name && it.status == expected.status } != true ||
            targets.any { it.id != expected.id && it.name.equals(desired.name, ignoreCase = true) }) vmmConflict()
        val fields = mutableMapOf<String, JsonElement>("guest_id" to JsonPrimitive(expected.id))
        if (source == VmmSource.INTERNAL) fields["synovmm_ui_id"] = JsonPrimitive(UUID.randomUUID().toString())
        fun changed(key: String, old: Any?, next: Any?) {
            if (old != next) fields[key] = when (next) { is String -> JsonPrimitive(next); is Int -> JsonPrimitive(next); else -> vmmConflict() }
        }
        val old = expected.configuration
        changed(if (source == VmmSource.PUBLIC) "new_guest_name" else "name", old.name, desired.name)
        changed(if (source == VmmSource.PUBLIC) "description" else "desc", old.description, desired.description)
        changed("vcpu_num", old.cpu, desired.cpu); changed("vram_size", old.memoryMiB, desired.memoryMiB)
        changed("cpu_weight", old.priority, desired.priority); changed("autorun", old.startup, desired.startup)
        currentCoroutineContext().ensureActive()
        checkpoint(VmmStage.SUBMITTED); submitted = true
        try { call(source.guestApi, "set", 1, fields, write = true) }
        catch (error: Exception) { if (vmmExplicitRejection(error)) checkpoint(VmmStage.REJECTED); throw error }
        checkpoint(VmmStage.ACCEPTED)
        if (recoverSettings(vmmDigest(expected.id), desired.digest(source), source)) checkpoint(VmmStage.VERIFIED)
    } catch (error: Exception) { if (!submitted) checkpoint(VmmStage.CANCELLED); throw error }
    finally { mutationLock.unlock() }
}

/** 只供已保存接受回执的记录调用；完整原来源与全部目标字段共同匹配。 */
internal suspend fun VmmManagementRepository.recoverSettings(id: String, desired: String, source: VmmSource): Boolean {
    val target = controlTargets(source).singleOrNull { vmmDigest(it.id) == id } ?: return false
    return readSettings(target.id, source).configuration.digest(source) == desired
}

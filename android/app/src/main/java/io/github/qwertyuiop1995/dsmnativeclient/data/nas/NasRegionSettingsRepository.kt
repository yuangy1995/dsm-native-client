package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.packageDigest
import java.time.LocalDateTime
import java.time.ZoneOffset
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

internal const val REGION_SETTINGS_API = "SYNO.Core.Region.NTP"
internal val regionDateFormats = listOf("Y-m-d", "Y/m/d", "Y.m.d", "d-m-Y", "d/m/Y", "d.m.Y", "m-d-Y", "m/d/Y", "m.d.Y")
internal val regionTimeFormats = listOf("h:i a", "H:i")
@Serializable internal enum class NasRegionStep { CONFIGURATION, SYNCHRONIZATION }
internal data class NasRegionCheckpoint(val step: NasRegionStep, val stage: NasServiceStage)
internal data class NasRegionPlan(val original: NasRegionSettings, val desired: NasRegionSettings, val synchronizeOnly: Boolean = false) {
    val editsClock get() = !synchronizeOnly && !desired.isNetworkTimeEnabled && desired.manualDateTime != null
    val needsSync get() = synchronizeOnly || desired.isNetworkTimeEnabled &&
        (!original.isNetworkTimeEnabled || original.timeServers != desired.timeServers)
    val steps get() = buildList { if (!synchronizeOnly) add(NasRegionStep.CONFIGURATION); if (needsSync) add(NasRegionStep.SYNCHRONIZATION) }
}

/** 区域配置与瞬时校时分别保存提交事实；恢复只能读取，不能推断丢失的校时回执。 */
internal class NasRegionSettingsRepository(private val gateway: NasManagementGateway, private val supports: (String, Int) -> Boolean) {
    private val lock = Mutex()
    private fun requireVersions(sync: Boolean = false) {
        if (!supports(REGION_SETTINGS_API, 1) || !supports(REGION_SETTINGS_API, 3) || sync && !supports(REGION_SETTINGS_API, 2))
            throw DsmFailure(103, "Region settings unavailable", "Open these settings in DSM.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
    }
    suspend fun load(): NasRegionSettings {
        requireVersions()
        val data = gateway.call(REGION_SETTINGS_API, "get", 3)
        val zonesData = gateway.call(REGION_SETTINGS_API, "listzone", 1)
        val zones = (zonesData["zonedata"] as? JsonArray ?: serviceInvalid()).map {
            val zone = it as? JsonObject ?: serviceInvalid()
            val id = zone.regionText("value")
            val label = zone["display"]?.takeUnless { it is JsonNull }?.let { value ->
                (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: serviceInvalid()
            }?.takeIf(String::isNotBlank) ?: id
            NasTimeZoneOption(id, label)
        }
        if (zones.isEmpty() || zones.map { it.id }.distinct().size != zones.size) serviceInvalid()
        val mode = when ((data["enable_ntp"] as? JsonPrimitive)?.content?.lowercase()) {
            "ntp", "true", "yes", "1", "enabled" -> true
            "manual", "false", "no", "0", "disabled" -> false
            else -> serviceInvalid()
        }
        val serverText = if (data["server"] == null || data["server"] is JsonNull) "" else data.regionText("server", allowEmpty = true)
        val servers = serverText.split(',').map(String::trim).filter(String::isNotEmpty)
        if (!validRegionServers(servers, mode)) serviceInvalid()
        val timeZone = data.regionText("timezone")
        if (zones.none { it.id == timeZone }) serviceInvalid()
        // 无效墙上时间保留为未知；不补午夜，也不阻断不依赖手动时间的网络校时配置。
        val clock = runCatching {
            val date = data.regionText("date").split('/', '-').map { it.toIntOrNull() ?: serviceInvalid() }
            if (date.size != 3) serviceInvalid()
            fun part(name: String): Int = (data[name] as? JsonPrimitive)?.content?.toIntOrNull() ?: serviceInvalid()
            NasManualDateTime(date[0], date[1], date[2], part("hour"), part("minute"), part("second")).takeIf { it.regionSeconds() != null }
        }.getOrNull()
        return NasRegionSettings(data.regionText("date_format"), data.regionText("time_format"), timeZone, mode, servers, clock, zones)
    }
    fun plan(original: NasRegionSettings, desired: NasRegionSettings, synchronizeOnly: Boolean = false): NasRegionPlan {
        val normalized = desired.copy(dateFormat = desired.dateFormat.trim(), timeFormat = desired.timeFormat.trim(),
            timeServers = desired.timeServers.map(String::trim).filter(String::isNotEmpty),
            manualDateTime = desired.manualDateTime.takeUnless { desired.isNetworkTimeEnabled })
        if (normalized.dateFormat !in regionDateFormats && normalized.dateFormat != original.dateFormat ||
            normalized.timeFormat !in regionTimeFormats && normalized.timeFormat != original.timeFormat ||
            normalized.dateFormat.isBlank() || normalized.timeFormat.isBlank() ||
            !validRegionServers(normalized.timeServers, normalized.isNetworkTimeEnabled) ||
            normalized.manualDateTime?.regionSeconds() == null && normalized.manualDateTime != null ||
            original.timeZones.none { it.id == normalized.timeZone }) regionValidation()
        val result = NasRegionPlan(original, normalized, synchronizeOnly)
        requireVersions(result.needsSync)
        if (synchronizeOnly) {
            if (!normalized.isNetworkTimeEnabled || regionConfiguration(original) != regionConfiguration(normalized)) regionConflict()
        } else if (regionConfiguration(original) == regionConfiguration(normalized) && !result.editsClock) regionConflict()
        return result
    }
    suspend fun save(plan: NasRegionPlan, observer: suspend (NasRegionCheckpoint) -> Unit): MutationResult {
        if (!lock.tryLock()) regionConflict()
        val stages = plan.steps.associateWith { NasServiceStage.PREPARED }.toMutableMap()
        var failure: Exception? = null
        var cancelled = false
        suspend fun checkpoint(step: NasRegionStep, stage: NasServiceStage) { observer(NasRegionCheckpoint(step, stage)); stages[step] = stage }
        try {
            if (plan(plan.original, plan.desired, plan.synchronizeOnly) != plan) regionConflict()
            for (step in plan.steps) {
                val current = try {
                    currentCoroutineContext().ensureActive(); gateway.requireWriteAccess()
                    load().also {
                        val expected = if (step == NasRegionStep.CONFIGURATION || plan.synchronizeOnly) plan.original else plan.desired
                        if (regionConfiguration(it) != regionConfiguration(expected)) regionConflict()
                        if (it.timeZones.none { zone -> zone.id == plan.desired.timeZone }) regionValidation()
                    }
                } catch (error: Exception) { failure = error; cancelled = error is CancellationException; break }
                val desired = plan.desired.copy(manualDateTime = plan.desired.manualDateTime ?: current.manualDateTime)
                val parameters = try {
                    if (step == NasRegionStep.CONFIGURATION) regionParameters(desired)
                    else mapOf("servers" to JsonArray(desired.timeServers.map(::JsonPrimitive)))
                } catch (error: Exception) { failure = error; break }
                checkpoint(step, NasServiceStage.SUBMITTED)
                var accepted = false
                try {
                    currentCoroutineContext().ensureActive()
                    if (step == NasRegionStep.CONFIGURATION) gateway.call(REGION_SETTINGS_API, "set", 3, parameters, write = true)
                    else gateway.call(REGION_SETTINGS_API, "sync", 2, parameters, write = true)
                    accepted = true
                } catch (error: Exception) {
                    failure = error; cancelled = error is CancellationException
                    if (error.serviceTrustFailure()) throw error
                    if (directoryExplicitRejection(error)) { checkpoint(step, NasServiceStage.REJECTED); break }
                }
                if (accepted) checkpoint(step, NasServiceStage.ACCEPTED)
                if (cancelled) break
                val actual = try { load() } catch (error: Exception) {
                    if (error.serviceTrustFailure()) throw error
                    failure = error; break
                }
                val matches = regionDigest(actual) == regionDigest(desired) && when (step) {
                    NasRegionStep.CONFIGURATION -> !plan.editsClock || accepted && regionClockMatches(actual, plan.desired.manualDateTime?.regionSeconds())
                    NasRegionStep.SYNCHRONIZATION -> accepted
                }
                if (!matches) break
                checkpoint(step, NasServiceStage.VERIFIED)
                // 丢失保存回执后终止写链；即使配置已匹配，也不自动发出校时请求。
                if (!accepted) break
            }
            for ((step, stage) in stages.toMap()) if (stage == NasServiceStage.PREPARED) checkpoint(step, NasServiceStage.CANCELLED)
            // 第二次副作用或权限检查期间，配置可能再次改变，先前成功不能掩盖最终读取失败。
            if (stages[NasRegionStep.CONFIGURATION] == NasServiceStage.VERIFIED && plan.needsSync && !cancelled) {
                val actual = try { load() } catch (error: Exception) { if (error.serviceTrustFailure()) throw error; failure = error; null }
                if (actual == null || regionDigest(actual) != regionDigest(plan.desired)) checkpoint(NasRegionStep.CONFIGURATION, NasServiceStage.SUBMITTED)
            }
            return regionResult(stages.values, failure, cancelled)
        } finally { lock.unlock() }
    }
}

internal fun regionConfiguration(value: NasRegionSettings): JsonObject = buildJsonObject {
    put("date_format", value.dateFormat); put("time_format", value.timeFormat); put("timezone", value.timeZone)
    put("enable_ntp", if (value.isNetworkTimeEnabled) "ntp" else "manual"); put("server", value.timeServers.joinToString(","))
}
private fun regionParameters(value: NasRegionSettings) = buildJsonObject {
    regionConfiguration(value).forEach { (key, item) -> put(key, item) }
    if (!value.isNetworkTimeEnabled) {
        val clock = value.manualDateTime ?: regionValidation()
        put("date", "${clock.year}/${clock.month}/${clock.day}"); put("hour", clock.hour); put("minute", clock.minute); put("second", clock.second)
    }
}
internal fun regionDigest(value: NasRegionSettings) = packageDigest(regionConfiguration(value).toString())
/** 使用固定墙上时间基准，Android 当前时区和夏令时不参与 NAS 的日期解释。 */
internal fun NasManualDateTime.regionSeconds(): Long? = runCatching {
    require(year in 1..9999)
    LocalDateTime.of(year, month, day, hour, minute, second).toEpochSecond(ZoneOffset.UTC)
}.getOrNull()
internal fun regionClockMatches(actual: NasRegionSettings, target: Long?) = target != null &&
    actual.manualDateTime?.regionSeconds()?.let { kotlin.math.abs(it - target) <= 120 } == true
internal fun validRegionServers(servers: List<String>, enabled: Boolean) = servers.size <= 3 && servers.distinct().size == servers.size &&
    (!enabled || servers.isNotEmpty()) && servers.all { it.isNotEmpty() && it.length <= 253 &&
        it.all { char -> char.isLetterOrDigit() || char in ".-:" } && !it.startsWith('.') && !it.endsWith('.') && ".." !in it }
private fun JsonObject.regionText(key: String, allowEmpty: Boolean = false): String =
    (get(key) as? JsonPrimitive)?.takeIf { it.isString && (allowEmpty || it.content.isNotBlank()) }?.content ?: serviceInvalid()
internal fun regionResult(stages: Collection<NasServiceStage>, error: Exception? = null, cancelled: Boolean = false): MutationResult {
    val converted = when ((error as? DsmFailure)?.kind) {
        DsmErrorKind.NAS_REGION_CHANGED -> DsmFailure(null, "Region settings changed", "", kind = DsmErrorKind.NAS_SERVICE_CHANGED)
        DsmErrorKind.NAS_REGION_INVALID -> DsmFailure(null, "Invalid region settings", "", kind = DsmErrorKind.NAS_SERVICE_INVALID)
        else -> error
    }
    return serviceResult(NasServiceKind.TERMINAL, stages, converted, cancelled).copy(operation = "regionSettingsUpdate")
}
internal fun regionConflict(): Nothing = throw DsmFailure(null, "Region settings changed", "Refresh and reopen settings.", kind = DsmErrorKind.NAS_REGION_CHANGED)
internal fun regionValidation(): Nothing = throw DsmFailure(null, "Region settings are invalid", "Check the selected format, time zone, date and time servers.", kind = DsmErrorKind.NAS_REGION_INVALID)

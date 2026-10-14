package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.boolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.serialization.json.*

internal object SynologyPhotoGlobalSettingsCodec {
    fun global(profile: String, userId: Long, user: JsonObject, admin: JsonObject, team: JsonObject): SynologyPhotoGlobalSettings {
        fun recognition(raw: JsonObject) = SynologyPhotoRecognition.entries.mapNotNull { key -> raw.optionalBoolean(key.field)?.let { key to it } }.toMap()
        val extensions = admin["exclude_extension"]?.takeIf { it != JsonNull }?.let { raw ->
            (raw as? JsonArray ?: invalid()).map { (it as? JsonPrimitive)?.takeIf { value -> value.isString }?.content ?: invalid() }.toSet()
        }
        return SynologyPhotoGlobalSettings(profile, userId,
            SynologyPhotoGlobalSetting.entries.mapNotNull { key -> admin.optionalBoolean(key.field)?.let { key to it } }.toMap(),
            extensions, user.optionalObject("ame_status")?.optionalBoolean("has_hevc"), recognition(user), recognition(team),
            user.boolean("enable_home_service"), team.boolean("enabled"),
            SynologyPhotoSharedSettings.Role.entries.firstOrNull { it.value == user.text("team_space_permission") } ?: invalid())
    }
    fun cache(profile: String, userId: Long, status: JsonObject, size: JsonObject): SynologyPhotoConversionCache {
        val value = status.text("status"); val bytes = size.number("cache_size")
        if (value.isEmpty() || bytes < 0) invalid()
        return SynologyPhotoConversionCache(profile, userId, bytes, value == "processing")
    }
    data class Step(val kind: SynologyPhotoGlobalStep, val api: String, val version: Int = 1, val method: String = "set", val fields: Map<String, JsonElement>)
    fun steps(value: SynologyPhotoSettingsCheckpoint): List<Step> {
        val before = value.original; val after = value.desired
        if (before is SynologyPhotoConversionCache) return listOf(Step(SynologyPhotoGlobalStep.CACHE, "Download", 2, "clear_cache", emptyMap()))
        if (before !is SynologyPhotoGlobalSettings || after !is SynologyPhotoGlobalSettings) invalid()
        fun <K> changes(old: Map<K, Boolean>, target: Map<K, Boolean>, field: (K) -> String): Map<String, JsonElement> =
            target.filter { (key, boolean) -> old[key] != boolean }.mapKeys { field(it.key) }.mapValues { JsonPrimitive(it.value) }
        val result = mutableListOf<Step>()
        if (before.values[SynologyPhotoGlobalSetting.ORIGINAL_JPEG] == true && after.values[SynologyPhotoGlobalSetting.ORIGINAL_JPEG] == false)
            result += Step(SynologyPhotoGlobalStep.CACHE, "Download", 2, "clear_cache", emptyMap())
        val admin = changes(before.values, after.values) { it.field } + if (before.excludedExtensions != after.excludedExtensions)
            mapOf("exclude_extension" to JsonArray(after.excludedExtensions!!.sorted().map(::JsonPrimitive))) else emptyMap()
        if (admin.isNotEmpty()) result += Step(SynologyPhotoGlobalStep.ADMIN, "Setting.Admin", fields = admin)
        val personal = changes(before.personalRecognition, after.personalRecognition) { it.field }
        if (personal.isNotEmpty()) result += Step(SynologyPhotoGlobalStep.PERSONAL, "Setting.User", fields = personal)
        val shared = changes(before.sharedRecognition, after.sharedRecognition) { it.field }
        if (shared.isNotEmpty()) result += Step(SynologyPhotoGlobalStep.SHARED, "Setting.TeamSpace", fields = shared)
        return result
    }
    fun validate(value: SynologyPhotoSettingsCheckpoint) {
        when (val before = value.original) {
            is SynologyPhotoGlobalSettings -> {
                val after = value.desired as? SynologyPhotoGlobalSettings ?: invalid()
                if (before.profileId.isBlank() || before.administratorId <= 0 || before.values.keys != after.values.keys ||
                    before.values.keys.any { before.values[it] != after.values[it] && it !in before.editable } ||
                    (before.excludedExtensions == null) != (after.excludedExtensions == null) ||
                    after.excludedExtensions?.any { it !in SynologyPhotoGlobalSettings.supportedExtensions && it !in before.excludedExtensions.orEmpty() } == true ||
                    before.applying(after.values, after.excludedExtensions) != after) invalid()
            }
            is SynologyPhotoConversionCache -> if (before.profileId.isBlank() || before.administratorId <= 0 || before.clearRequested ||
                !before.canClear || before.copy(clearRequested = true) != value.desired) invalid()
            else -> invalid()
        }
        val progress = value.globalProgress ?: invalid(); val planned = steps(value).map { it.kind }
        if (planned.isEmpty() || progress.attempted.any { it !in planned } || value.attempted != progress.attempted.isNotEmpty() ||
            !progress.attempted.containsAll(progress.acknowledged + progress.rejected + progress.completed) ||
            progress.rejected.any { it in progress.acknowledged || it in progress.completed }) invalid()
        val last = planned.indexOfLast { it in progress.attempted }
        if (last >= 0 && !progress.acknowledged.containsAll(planned.take(last))) invalid()
    }
    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val value = row.settings!!; val before = value.original; val progress = value.globalProgress ?: invalid()
        val identity = when (before) {
            is SynologyPhotoGlobalSettings -> before.profileId to before.administratorId
            is SynologyPhotoConversionCache -> before.profileId to before.administratorId
            else -> invalid()
        }
        if (identity != (row.profileId to row.userId) || !row.submitted && (value.attempted || value.rejected) ||
            row.phase == SynologyPhotoAlbumPhase.COMPLETED && (value.rejected || progress.completed != steps(value).map { it.kind }.toSet()) ||
            row.phase == SynologyPhotoAlbumPhase.PARTIAL && (!value.rejected || !progress.attempted.all { it in progress.completed || it in progress.rejected })) invalid()
    }
    fun matches(step: Step, actual: SynologyPhotoGlobalSettings): Boolean = step.fields.all { (field, target) ->
        when (step.kind) {
            SynologyPhotoGlobalStep.ADMIN -> if (field == "exclude_extension") actual.excludedExtensions == (target as JsonArray).map { it.jsonPrimitive.content }.toSet()
                else actual.values[SynologyPhotoGlobalSetting.entries.first { it.field == field }] == target.jsonPrimitive.boolean
            SynologyPhotoGlobalStep.PERSONAL -> actual.personalRecognition[SynologyPhotoRecognition.entries.first { it.field == field }] == target.jsonPrimitive.boolean
            SynologyPhotoGlobalStep.SHARED -> actual.sharedRecognition[SynologyPhotoRecognition.entries.first { it.field == field }] == target.jsonPrimitive.boolean
            SynologyPhotoGlobalStep.CACHE -> false
        }
    }
}

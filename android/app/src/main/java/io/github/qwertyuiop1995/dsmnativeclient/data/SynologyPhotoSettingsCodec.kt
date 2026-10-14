package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.boolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import java.util.Locale
import kotlinx.serialization.json.*

internal object SynologyPhotoSettingsCodec {
    fun automaticPreview(raw: JsonObject) = SynologyPhotoAutomaticPreviewSettings(raw.boolean("auto_generate_thumbnail"))
    fun display(raw: JsonObject) = SynologyPhotoDisplaySettings(
        SynologyPhotoDisplaySettings.Grouping.entries.firstOrNull { it.value == raw.text("timeline_group_unit") } ?: invalid(),
        SynologyPhotoDisplaySettings.Date.entries.firstOrNull { it.value == raw.text("date_format").lowercase(Locale.ROOT) } ?: invalid(),
        SynologyPhotoDisplaySettings.Clock.entries.firstOrNull { it.value == raw.text("time_format") } ?: invalid(),
        SynologyPhotoSort(SynologyPhotoSort.Field.entries.firstOrNull { it.value == raw.text("item_sort_by") } ?: invalid(),
            SynologyPhotoSort.Direction.entries.firstOrNull { it.value == raw.text("sort_direction") } ?: invalid()),
        raw.boolean("show_item_info_in_lightbox"),
    )
    fun duplicates(raw: JsonObject) = SynologyPhotoDuplicateSettings(
        SynologyPhotoUploadDuplicate.entries.firstOrNull { it.value == raw.text("upload_default_action") } ?: invalid(),
        SynologyPhotoTransferDuplicate.entries.firstOrNull { it.value == raw.text("copy_move_default_action") } ?: invalid(),
    )
    fun recognition(user: JsonObject, admin: JsonObject) = SynologyPhotoRecognitionSettings(user.boolean("enable_home_service"),
        recognitionValues(user), recognitionValues(admin))
    private fun recognitionValues(raw: JsonObject) = SynologyPhotoRecognition.entries.mapNotNull { key -> raw.optionalBoolean(key.field)?.let { key to it } }.toMap()

    fun shared(profileId: String, administratorId: Long, user: JsonObject, admin: JsonObject, team: JsonObject): SynologyPhotoSharedSettings {
        val global = SynologyPhotoSharedSetting.entries.filter { it != SynologyPhotoSharedSetting.PUBLIC_ROOT }
            .mapNotNull { key -> admin.optionalBoolean(key.field)?.let { key to it } }.toMap()
        val values = SynologyPhotoSharedSetting.entries.filter { it == SynologyPhotoSharedSetting.PUBLIC_ROOT || it in global }
            .mapNotNull { key -> team.optionalBoolean(key.field)?.let { key to it } }.toMap()
        return SynologyPhotoSharedSettings(profileId, administratorId, team.boolean("enabled"), user.boolean("enable_home_service"),
            SynologyPhotoSharedSettings.Role.entries.firstOrNull { it.value == user.text("team_space_permission") } ?: invalid(),
            team.optionalBoolean("team_space_disabled_by_share_folder_disabled"), values, global)
    }

    fun validate(value: SynologyPhotoSettingsCheckpoint) {
        val original = value.original; val desired = value.desired
        SynologyPhotoAlbumPreferenceCodec.validate(original.target()); SynologyPhotoAlbumPreferenceCodec.validate(desired.target())
        if (original.target() != desired.target() || original == desired) invalid()
        if (original is SynologyPhotoGlobalSettings || original is SynologyPhotoConversionCache) SynologyPhotoGlobalSettingsCodec.validate(value)
        else if (value.globalProgress != null) invalid()
        listOf(original, desired).filterIsInstance<SynologyPhotoAlbumListSortSettings>().forEach { if (it.sort.field !in it.scope.fields) invalid() }
        if (original is SynologyPhotoSharedSettings && desired is SynologyPhotoSharedSettings) {
            if (original.profileId.isBlank() || original.administratorId <= 0 || original.global.keys.any { it == SynologyPhotoSharedSetting.PUBLIC_ROOT } ||
                original.values.keys.any { it != SynologyPhotoSharedSetting.PUBLIC_ROOT && it !in original.global } ||
                original.copy(enabled = desired.enabled, values = desired.values) != desired || original.values.keys != desired.values.keys) invalid()
            if (original.enabled != desired.enabled) {
                if (!original.canToggle || original.values != desired.values) invalid()
            } else if (original.values.keys.any { original.values[it] != desired.values[it] && it !in original.editable }) invalid()
        }
        if (original is SynologyPhotoRecognitionSettings && desired is SynologyPhotoRecognitionSettings) {
            if (original.personalEnabled != desired.personalEnabled || original.global != desired.global || original.personal.keys != desired.personal.keys ||
                original.personal.keys.any { original.personal[it] != desired.personal[it] && it !in original.editable }) invalid()
        }
    }
    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val value = row.settings ?: invalid(); validate(value)
        (value.original as? SynologyPhotoSharedSettings)?.let { if (it.profileId != row.profileId || it.administratorId != row.userId) invalid() }
        if (row.album != null || row.name != null || row.targets.isNotEmpty() || !row.submitted && (value.attempted || value.rejected) ||
            row.phase == SynologyPhotoAlbumPhase.COMPLETED && (!value.attempted || value.rejected) ||
            row.phase == SynologyPhotoAlbumPhase.PARTIAL && !value.rejected) invalid()
        if (value.globalProgress != null) SynologyPhotoGlobalSettingsCodec.validate(row)
    }
    fun changes(value: SynologyPhotoSettingsCheckpoint): Map<String, JsonElement> {
        validate(value)
        val before = fields(value.original)
        return fields(value.desired).filter { (key, after) -> before[key] != after }
    }
    private fun fields(value: SynologyPhotoSettings): Map<String, JsonElement> = when (value) {
        is SynologyPhotoAutomaticPreviewSettings -> json("auto_generate_thumbnail" to value.enabled)
        is SynologyPhotoGlobalSettings, is SynologyPhotoConversionCache -> invalid()
        is SynologyPhotoDisplaySettings -> json("timeline_group_unit" to value.grouping.value, "date_format" to value.date.value,
            "time_format" to value.clock.value, "item_sort_by" to value.sort.field.value, "sort_direction" to value.sort.direction.value,
            "show_item_info_in_lightbox" to value.showInfo)
        is SynologyPhotoDuplicateSettings -> json("upload_default_action" to value.upload.value, "copy_move_default_action" to value.transfer.value)
        is SynologyPhotoAlbumSortSettings -> json("sort_by" to value.sort.field.value, "sort_direction" to value.sort.direction.value)
        is SynologyPhotoAlbumListSortSettings -> json(value.scope.value + "_sort_by" to value.sort.field.value, value.scope.value + "_sort_direction" to value.sort.direction.value)
        is SynologyPhotoAlbumDisplaySettings -> json("album_display_type" to value.display.value)
        is SynologyPhotoSharedSettings -> value.values.mapKeys { it.key.field }.mapValues { JsonPrimitive(it.value) } + json("enabled" to value.enabled)
        is SynologyPhotoRecognitionSettings -> value.personal.mapKeys { it.key.field }.mapValues { JsonPrimitive(it.value) }
    }
}

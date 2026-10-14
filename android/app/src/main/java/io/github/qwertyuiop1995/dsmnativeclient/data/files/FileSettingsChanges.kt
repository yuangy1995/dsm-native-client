package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.serialization.json.*
import java.security.MessageDigest

internal val FileSettingsChange.owner get() = when (this) {
    is FileSettingsChange.General -> baseline.owner
    is FileSettingsChange.MountScope -> owner
    is FileSettingsChange.MountAccount -> baseline.owner
    is FileSettingsChange.Bandwidth -> baseline.owner
    is FileSettingsChange.Theme -> baseline.owner
}
internal val FileSettingsChange.kind get() = when (this) {
    is FileSettingsChange.General -> FileSettingsTargetKind.GENERAL
    is FileSettingsChange.MountScope -> FileSettingsTargetKind.MOUNT_SCOPE
    is FileSettingsChange.MountAccount -> FileSettingsTargetKind.MOUNT_ACCOUNT
    is FileSettingsChange.Bandwidth -> FileSettingsTargetKind.BANDWIDTH
    is FileSettingsChange.Theme -> FileSettingsTargetKind.THEME
}
internal val FileSettingsChange.api get() = when (this) {
    is FileSettingsChange.General -> FILE_SETTINGS_API
    is FileSettingsChange.MountScope, is FileSettingsChange.MountAccount -> FILE_MOUNT_USER_API
    is FileSettingsChange.Bandwidth -> FILE_BANDWIDTH_API
    is FileSettingsChange.Theme -> FILE_SHARING_THEME_API
}
internal val FileSettingsChange.target get() = settingsDigest(when (this) {
    is FileSettingsChange.General -> JsonPrimitive("general")
    is FileSettingsChange.MountScope -> JsonPrimitive("mount-scope")
    is FileSettingsChange.MountAccount -> baseline.targetValue()
    is FileSettingsChange.Bandwidth -> baseline.targetValue()
    is FileSettingsChange.Theme -> JsonPrimitive("theme")
})
internal fun settingsDigest(value: JsonElement): String = MessageDigest.getInstance("SHA-256").digest(value.toString().toByteArray(Charsets.UTF_8))
    .joinToString("") { "%02x".format(it) }

internal fun FileStationSettings.settingsValue() = buildJsonObject {
    put("transfer_log_enable", recordsTransfers); put("use_unix_default_perm", usesDefaultPermissions); put("enable_list_usergrp", showsAccounts)
    put("sharing_allow", sharing.value); put("file_request_allow", fileRequests.value); put("rf_allow", remoteMounts.value); put("vd_allow", isoMounts.value)
    put("sharing_accounts", sharingAccounts.canonical()); put("request_accounts", requestAccounts.canonical())
    put("sharing_default_limit", defaultLinkLimit); put("bandwidth_enable", bandwidth.value); put("schedule_plan", schedule)
    put("enable_sharing_custom_setting", customSharingPage?.let(::JsonPrimitive) ?: JsonNull)
}
private fun Set<FileSettingsAccountId>.canonical() = JsonArray(sortedWith(compareBy({ it.kind.name }, { it.value })).map {
    buildJsonObject { put("kind", it.kind.name); put("value", it.value) }
})
internal fun FileMountAccount.targetValue() = buildJsonObject {
    put("source", source.kind.value); put("domain", source.domain); put("kind", id.kind.name); put("value", id.value)
}
internal fun FileMountAccount.settingsValue() = buildJsonObject {
    put("target", targetValue()); put("name", name); put("enabled", enabled); put("canModify", canModify)
}
internal fun FileBandwidthEntry.targetValue() = buildJsonObject { put("name", name); put("owner_type", ownerType.value) }
internal fun FileBandwidthEntry.settingsValue() = buildJsonObject {
    put("name", name); put("protocol", "FileStation"); put("owner_type", ownerType.value); put("policy", policy.value); put("schedule_plan", schedule)
    put("upload_limit_1", uploadLimit); put("download_limit_1", downloadLimit); put("upload_limit_2", alternateUploadLimit); put("download_limit_2", alternateDownloadLimit)
}
internal fun FileSettingsChange.desiredDigest() = settingsDigest(when (this) {
    is FileSettingsChange.General -> updated.settingsValue()
    is FileSettingsChange.MountScope -> JsonPrimitive(updated.value)
    is FileSettingsChange.MountAccount -> baseline.copy(enabled = enabled).settingsValue()
    is FileSettingsChange.Bandwidth -> updated.settingsValue()
    is FileSettingsChange.Theme -> updated.settingsValue()
})

/** 保存只包含本次修改的字段；名单按稳定 uid/gid 增删，不重发整个权限表。 */
internal fun FileSettingsChange.parameters(): Map<String, String> = when (this) {
    is FileSettingsChange.General -> {
        val old = baseline; val new = updated
        if (old.owner != new.owner || new.remoteMounts == FileSettingsScope.SELECTED || new.isoMounts == FileSettingsScope.SELECTED ||
            new.bandwidth == FileBandwidthPolicy.UNCONFIGURED || new.defaultLinkLimit !in 0..999_999_999 ||
            new.schedule.isNotEmpty() && !FileWeeklySchedule.valid(new.schedule, false) ||
            new.bandwidth == FileBandwidthPolicy.SCHEDULED && !FileWeeklySchedule.valid(new.schedule, false) ||
            (new.sharingAccounts + new.requestAccounts).any { it.value < 0 }) throw settingsInvalid()
        buildMap {
            val previous = old.settingsValue(); val desired = new.settingsValue()
            for (key in listOf("transfer_log_enable", "use_unix_default_perm", "enable_list_usergrp", "sharing_allow", "file_request_allow",
                    "rf_allow", "vd_allow", "sharing_default_limit", "schedule_plan"))
                if (previous[key] != desired[key]) put(key, desired.getValue(key).jsonPrimitive.content)
            if (old.bandwidth != new.bandwidth) put("bandwidth_enable", when (new.bandwidth) {
                FileBandwidthPolicy.DISABLED -> "bandwidth_disable"; FileBandwidthPolicy.ENABLED -> "bandwidth_enable"
                FileBandwidthPolicy.SCHEDULED -> "bandwidth_schedule"; else -> throw settingsInvalid()
            })
            if (old.customSharingPage != new.customSharingPage) {
                if (old.customSharingPage == null || new.customSharingPage == null) throw settingsInvalid()
                put("enable_sharing_custom_setting", new.customSharingPage.toString())
            }
            for ((prefix, before, after) in listOf(Triple("sharing", old.sharingAccounts, new.sharingAccounts), Triple("file_request", old.requestAccounts, new.requestAccounts))) {
                for (kind in FileSharePrincipalKind.entries) {
                    val suffix = prefix + if (kind == FileSharePrincipalKind.USER) "_privilege" else "_group_privilege"
                    val added = (after - before).filter { it.kind == kind }.map { it.value }.sorted()
                    val removed = (before - after).filter { it.kind == kind }.map { it.value }.sorted()
                    if (added.isNotEmpty()) put("enabled_$suffix", added.joinToString(","))
                    if (removed.isNotEmpty()) put("disabled_$suffix", removed.joinToString(","))
                }
            }
        }
    }
    is FileSettingsChange.MountScope -> {
        if (baseline == updated) throw settingsInvalid()
        mapOf("settings" to buildJsonObject { put("user_enabled_type", updated.value) }.toString())
    }
    is FileSettingsChange.MountAccount -> {
        if (!baseline.canModify || baseline.enabled == enabled || !baseline.source.valid || baseline.id.value < 0) throw settingsInvalid()
        mapOf("settings" to buildJsonObject { putJsonArray(if (baseline.id.kind == FileSharePrincipalKind.USER) "user_settings" else "group_settings") {
            add(buildJsonObject { put(baseline.id.field, baseline.id.value); put("enabled", enabled) })
        } }.toString())
    }
    is FileSettingsChange.Bandwidth -> {
        val new = updated
        if (baseline.owner != new.owner || baseline.targetValue() != new.targetValue() || baseline == new || new.policy == FileBandwidthPolicy.UNCONFIGURED ||
            listOf(new.uploadLimit, new.downloadLimit, new.alternateUploadLimit, new.alternateDownloadLimit).any { it != 0 && it !in 10..999_999_999 } ||
            new.schedule.isNotEmpty() && !FileWeeklySchedule.valid(new.schedule, true) ||
            new.policy == FileBandwidthPolicy.SCHEDULED && !FileWeeklySchedule.valid(new.schedule, true)) throw settingsInvalid()
        mapOf("bandwidths" to JsonArray(listOf(new.settingsValue())).toString())
    }
    is FileSettingsChange.Theme -> themeParameters()
}.also { if (it.isEmpty()) throw settingsInvalid() }
internal fun settingsInvalid() = DsmFailure(null, "These settings cannot be saved", "Check the fields and try again.", kind = DsmErrorKind.FILE_SETTINGS_INVALID)

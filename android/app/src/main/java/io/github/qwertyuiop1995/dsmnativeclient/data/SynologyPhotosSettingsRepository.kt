package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** 个人、管理员共享设置与相册偏好共用恢复；统一 Foto 路由，写入限当前范围。 */
internal class SynologyPhotosSettingsRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val apply: (SynologyPhotoSettings) -> Unit,
    private val album: suspend (Long, SynologyPhotosMutationAccess) -> JsonObject,

) {
    private val global = SynologyPhotosGlobalSettingsRepository(checkAccess, write) { kind, owner -> settings(SynologyPhotoSettingsTarget(kind), owner)!! }
    suspend fun settings(target: SynologyPhotoSettingsTarget): SynologyPhotoSettings = settings(target, identity())!!
    private suspend fun settings(target: SynologyPhotoSettingsTarget, owner: SynologyPhotosMutationAccess, explicit: Boolean = false): SynologyPhotoSettings? {
        SynologyPhotoAlbumPreferenceCodec.validate(target); checkAccess(owner, null)
        val result = when (target.kind) {
            SynologyPhotoSettingsKind.CACHE -> {
                administrator(owner); capability("Download", 2, null)
                SynologyPhotoGlobalSettingsCodec.cache(owner.profileId, owner.userId, read("Download", 2, "get_cache_status", emptyMap(), null),
                    read("Download", 2, "calculate_cache_size", emptyMap(), null))
            }
            SynologyPhotoSettingsKind.SHARED, SynologyPhotoSettingsKind.GLOBAL -> {
                listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace").forEach { capability(it, 1, null) }
                administrator(owner)
                val user = read("Setting.User", 1, "get", emptyMap(), null)
                val admin = read("Setting.Admin", 1, "get", emptyMap(), null)
                val team = read("Setting.TeamSpace", 1, "get", emptyMap(), null)
                if (target.kind == SynologyPhotoSettingsKind.GLOBAL) SynologyPhotoGlobalSettingsCodec.global(owner.profileId, owner.userId, user, admin, team)
                else SynologyPhotoSettingsCodec.shared(owner.profileId, owner.userId, user, admin, team)
            }
            SynologyPhotoSettingsKind.ALBUM_SORT -> {
                capability("Browse.Album", 1, null); capability("Browse.Album", 4, null)
                val sort = SynologyPhotoAlbumPreferenceCodec.album(album(target.albumId!!, owner), explicit)
                sort?.let { SynologyPhotoAlbumSortSettings(target.albumId, it) }
            }
            SynologyPhotoSettingsKind.LIST_SORT -> {
                capability("Browse.Album", 2, null)
                SynologyPhotoAlbumListSortSettings(target.listScope!!, SynologyPhotoAlbumPreferenceCodec.list(
                    read("Browse.Album", 2, "get_album_list_order", emptyMap(), null), target.listScope))
            }
            SynologyPhotoSettingsKind.LIST_DISPLAY -> {
                capability("Browse.Album", 3, null)
                SynologyPhotoAlbumDisplaySettings(SynologyPhotoAlbumPreferenceCodec.display(read("Browse.Album", 3, "get_album_list_display", emptyMap(), null)))
            }
            else -> {
                capability("Setting.User", 1, null)
                val user = read("Setting.User", 1, "get", emptyMap(), null)
                when (target.kind) {
                    SynologyPhotoSettingsKind.AUTOMATIC_PREVIEWS -> SynologyPhotoSettingsCodec.automaticPreview(user)
                    SynologyPhotoSettingsKind.DISPLAY -> SynologyPhotoSettingsCodec.display(user)
                    SynologyPhotoSettingsKind.DUPLICATES -> SynologyPhotoSettingsCodec.duplicates(user)
                    SynologyPhotoSettingsKind.RECOGNITION -> {
                        capability("Setting.Admin", 1, null)
                        SynologyPhotoSettingsCodec.recognition(user, read("Setting.Admin", 1, "get", emptyMap(), null))
                    }
                    else -> invalid()
                }
            }
        }
        currentCoroutineContext().ensureActive(); checkAccess(owner, null)
        if (result != null) apply(result)
        return result
    }
    private suspend fun administrator(owner: SynologyPhotosMutationAccess) {
        capability("UserInfo", 1, null)
        val actual = read("UserInfo", 1, "me", emptyMap(), null)
        if (SynologyPhotosCodec.run { !actual.boolean("enabled") || actual.optionalBoolean("is_admin") != true || actual.positive("id") != owner.userId })
            throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    }
    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        val value = row.settings ?: invalid(); SynologyPhotoSettingsCodec.validate(value)
        val actual = settings(value.original.target(), owner)
        val same = if (actual is SynologyPhotoConversionCache && value.original is SynologyPhotoConversionCache)
            actual.profileId == value.original.profileId && actual.administratorId == value.original.administratorId && actual.canClear
            else actual == value.original
        if (!same) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
        if (value.globalProgress != null) SynologyPhotoGlobalSettingsCodec.steps(value).forEach { capability(it.api, it.version, null) }
    }
    suspend fun execute(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        prepare(input, owner)
        if (input.settings!!.globalProgress != null) return global.execute(input, owner, persist)
        var row = input.copy(settings = input.settings!!.copy(attempted = true))
        val value = row.settings!!.desired
        val fields = when (value) {
            is SynologyPhotoAlbumSortSettings -> SynologyPhotosCodec.json("id" to value.albumId, "sort_by" to value.sort.field.value, "sort_direction" to value.sort.direction.value)
            is SynologyPhotoAlbumListSortSettings -> SynologyPhotosCodec.json(value.scope.value + "_sort_by" to value.sort.field.value, value.scope.value + "_sort_direction" to value.sort.direction.value)
            else -> SynologyPhotoSettingsCodec.changes(row.settings!!)
        }
        currentCoroutineContext().ensureActive(); checkAccess(owner, null)
        persist(row)
        try {
            when (value) {
                is SynologyPhotoAlbumSortSettings -> write("Browse.Album", 1, "set_order", fields, null)
                is SynologyPhotoAlbumListSortSettings -> write("Browse.Album", 2, "set_album_list_order", fields, null)
                is SynologyPhotoAlbumDisplaySettings -> write("Browse.Album", 3, "set_album_list_display", fields, null)
                is SynologyPhotoSharedSettings -> write("Setting.TeamSpace", 1,
                    if ((row.settings!!.original as SynologyPhotoSharedSettings).enabled != value.enabled) "set_enable" else "set", fields, null)
                else -> write("Setting.User", 1, "set", fields, null)
            }
        }
        catch (error: DsmFailure) {
            if (error.code in setOf(105, 106, 107, 119)) {
                row = row.copy(settings = row.settings!!.copy(rejected = true)); persist(row)
            }
            throw error
        }
        return row
    }
    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        checkAccess(owner, null)
        val value = row.settings!!
        if (value.globalProgress != null) return global.review(row, owner)
        if (!value.attempted || value.rejected) return row.copy(phase = SynologyPhotoAlbumPhase.PARTIAL, settings = value.copy(rejected = true))
        val actual = settings(value.original.target(), owner, explicit = true)
        val desired = value.desired
        val matches = if (actual is SynologyPhotoSharedSettings && desired is SynologyPhotoSharedSettings &&
            (value.original as SynologyPhotoSharedSettings).enabled != desired.enabled) {
            actual.profileId == desired.profileId && actual.administratorId == desired.administratorId && actual.enabled == desired.enabled &&
                actual.personalEnabled == desired.personalEnabled && actual.role == desired.role
        } else actual == desired
        return row.copy(phase = if (matches) SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PENDING)
    }
}

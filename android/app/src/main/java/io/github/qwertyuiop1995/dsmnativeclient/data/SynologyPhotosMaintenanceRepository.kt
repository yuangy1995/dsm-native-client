package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.boolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** 当前来源维护；Foto 身份/设置与按来源选择的 Index 分开路由。 */
internal class SynologyPhotosMaintenanceRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
) {
    suspend fun status(space: SynologyPhotoSpace): SynologyPhotoMaintenanceStatus = status(space, identity())
    private suspend fun status(space: SynologyPhotoSpace, owner: SynologyPhotosMutationAccess): SynologyPhotoMaintenanceStatus {
        checkAccess(owner, space); capability("UserInfo", 1, null); capability("Setting.User", 1, null); capability("Index", 1, space)
        val actual = read("UserInfo", 1, "me", emptyMap(), null)
        if (!actual.boolean("enabled") || actual.positive("id") != owner.userId ||
            space == SynologyPhotoSpace.SHARED && actual.optionalBoolean("is_admin") != true) denied()
        val user = read("Setting.User", 1, "get", emptyMap(), null)
        if (space == SynologyPhotoSpace.PERSONAL) { if (!user.boolean("enable_home_service")) denied() }
        else {
            capability("Setting.TeamSpace", 1, null)
            val team = read("Setting.TeamSpace", 1, "get", emptyMap(), null)
            if (!team.boolean("enabled") || user.text("team_space_permission") !in setOf("entry", "management")) denied()
        }
        val counts = read("Index", 1, "get", emptyMap(), space)
        val indexing = counts.number("basic").takeIf { it >= 0 } ?: invalid()
        val previews = counts.number("thumbnail").takeIf { it >= 0 } ?: invalid()
        currentCoroutineContext().ensureActive(); checkAccess(owner, space)
        return SynologyPhotoMaintenanceStatus(owner.profileId, owner.userId, space, indexing, previews,
            user.optionalObject("ame_status")?.optionalBoolean("has_h264") == true)
    }
    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        SynologyPhotoMaintenanceCodec.validate(row)
        val value = row.maintenance!!; val original = value.original
        if (original.profileId != owner.profileId || original.userId != owner.userId || !original.canStart(value.action) ||
            !status(original.space, owner).canStart(value.action)) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
    }
    suspend fun execute(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        prepare(input, owner)
        var row = input.copy(maintenance = input.maintenance!!.copy(attempted = true))
        val value = row.maintenance!!
        currentCoroutineContext().ensureActive(); checkAccess(owner, value.original.space); persist(row)
        try { write("Index", 1, "reindex", json("type" to value.action.value), value.original.space) }
        catch (error: DsmFailure) {
            // 明确 success:false 与网络丢回执不同；包括 code 100，禁止之后凭计数认领成功。
            if (error.code != null && error.kind !in setOf(DsmErrorKind.CONNECTION_FAILED, DsmErrorKind.INVALID_RESPONSE)) {
                row = row.copy(maintenance = value.copy(rejected = true)); persist(row)
            }
            throw error
        }
        return row.copy(maintenance = value.copy(acknowledged = true)).also(persist)
    }
    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        checkAccess(owner, null)
        val value = row.maintenance!!
        if (!value.attempted || value.rejected) return row.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)
        val current = status(value.original.space, owner)
        return row.copy(phase = if (value.acknowledged && current.count(value.action) == 0L) SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PENDING)
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
}

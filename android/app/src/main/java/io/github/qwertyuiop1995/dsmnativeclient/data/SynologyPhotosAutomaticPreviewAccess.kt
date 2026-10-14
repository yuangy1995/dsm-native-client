package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.boolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.intNumber
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalText
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.permission
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import java.io.File
import java.util.Locale
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** 自动生成使用原件真实归属和Unit身份，不以相册权限或手动队列替代。 */
internal class SynologyPhotosAutomaticPreviewAccess(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val pending: (SynologyPhotoId) -> Boolean,
    private val download: suspend (ApiCapability, Long, File, suspend () -> Unit) -> Unit,
) {
    data class Source(val unitId: Long, val filename: String, val video: Boolean,
        val large: String?, val small: String?, val videoStatus: String?, val codec: String?) {
        override fun toString() = "PhotoAutomaticPreviewSource(video=$video)"
    }

    suspend fun enabled(): Boolean {
        val owner = identity()
        checkAccess(owner, null)
        return read("Setting.User", 1, "get", emptyMap(), null).boolean("auto_generate_thumbnail")
            .also { checkAccess(owner, null) }
    }

    suspend fun tasks(space: SynologyPhotoSpace, support: SynologyPhotoPreviewConversionSupport): List<SynologyPhotoAutomaticPreviewTask> =
        tasks(space, support, identity())

    private suspend fun tasks(space: SynologyPhotoSpace, support: SynologyPhotoPreviewConversionSupport,
        owner: SynologyPhotosMutationAccess): List<SynologyPhotoAutomaticPreviewTask> {
        currentCoroutineContext().ensureActive(); checkAccess(owner, space)
        if (space == SynologyPhotoSpace.SHARED && !owner.managesShared) denied()
        if (!support.available) return emptyList()
        val preset = if (support.vc1) { if (support.hevc) "windows" else "windows2" } else "macos"
        val types = if (support.hevc) array("photo", "video", "live_video") else array("video")
        val raw = read("Upload.ConvertedFile", 3, "list_convert_needed", json("type" to types, "preset" to preset), space)
        currentCoroutineContext().ensureActive(); checkAccess(owner, space)
        val result = raw.list().map { entry ->
            val type = entry.intNumber("type").also { if (it < 0) invalid() }
            SynologyPhotoAutomaticPreviewTask(owner.profileId, space, entry.positive("unit_id"),
                entry.text("filename").also { if (it.isEmpty()) invalid() }, type, flag(entry, "need_thumbnail"), flag(entry, "need_video"))
        }
        if (result.map { it.unitId }.distinct().size != result.size) invalid()
        return result
    }

    suspend fun tasks(photo: SynologyPhoto, support: SynologyPhotoPreviewConversionSupport): List<SynologyPhotoAutomaticPreviewTask> =
        tasks(SynologyPhotoEditTarget(photo), photo.thumbnail?.unitId, support, identity())

    private suspend fun tasks(target: SynologyPhotoEditTarget, thumbnailUnitId: Long?, support: SynologyPhotoPreviewConversionSupport,
        owner: SynologyPhotosMutationAccess): List<SynologyPhotoAutomaticPreviewTask> {
        currentCoroutineContext().ensureActive(); checkAccess(owner, target.id.space)
        if (!support.available) return emptyList()
        return sources(target, thumbnailUnitId, owner).mapNotNull { source ->
            val heic = !source.video && source.filename.substringAfterLast('.', "").lowercase(Locale.ROOT) in setOf("heic", "heif", "hif")
            val vc1 = source.video && source.codec in setOf("vc1", "wmv3")
            if ((heic || source.video && source.codec == "hevc") && !support.hevc ||
                source.video && (!support.video || vc1 && !support.vc1)) return@mapNotNull null
            val thumbnail = source.large == "ame_defect" || source.small == "ame_defect"
            val video = source.video && source.videoStatus == "ame_defect"
            if (!thumbnail && !video) return@mapNotNull null
            val priority = when {
                vc1 -> SynologyPhotoAutomaticPreviewPriority.VC1
                source.video && (source.codec == "hevc" || target.mediaType == "live") -> SynologyPhotoAutomaticPreviewPriority.HEVC_OR_LIVE_VIDEO
                else -> SynologyPhotoAutomaticPreviewPriority.STANDARD
            }
            SynologyPhotoAutomaticPreviewTask(owner.profileId, target.id.space, source.unitId, source.filename,
                if (source.video) 1 else 0, thumbnail, video, target, thumbnailUnitId, priority)
        }
    }

    suspend fun sources(target: SynologyPhotoEditTarget, thumbnailUnitId: Long?, owner: SynologyPhotosMutationAccess): List<Source> {
        currentCoroutineContext().ensureActive(); checkAccess(owner, target.id.space)
        if (target.id.profileId != owner.profileId || target.id.itemId <= 0 || pending(target.id)) denied()
        val raw = read("Browse.Item", 5, "get", json("id" to array(target.id.itemId),
            "additional" to array("thumbnail", "video_meta", "video_convert")), target.id.space).list().singleOrNull() ?: invalid()
        checkAccess(owner, target.id.space)
        val current = SynologyPhotosCodec.photo(raw, owner.profileId, target.id.space)
        if (!target.copy(albumContext = null).matches(current)) changed()
        val ownerId = raw.number("owner_user_id")
        if (if (target.id.space == SynologyPhotoSpace.SHARED) ownerId != 0L else ownerId <= 0 || ownerId != owner.userId) denied()
        if (target.id.space == SynologyPhotoSpace.SHARED && !owner.managesShared) {
            val folder = read("Browse.Folder", 2, "get", json("id" to target.folderId,
                "additional" to array("access_permission")), target.id.space).obj("folder")
            if (folder.number("id") != target.folderId) changed()
            val rights = folder.optionalObject("additional")?.optionalObject("access_permission")
            if (rights?.permission("view") != true || !rights.permission("download")) denied()
        }
        val result = if (target.mediaType == "live") {
            val payload = read("Browse.Unit", 1, "get", json("id_item" to array(target.id.itemId),
                "additional" to array("orientation", "resolution", "thumbnail", "video_meta", "video_convert")), target.id.space)
            val item = payload.list().singleOrNull() ?: invalid()
            if (item.number("id_item") != target.id.itemId) changed()
            item.list("unit").map { unit ->
                val kind = unit.text("live_type")
                if (kind !in setOf("photo", "video")) invalid()
                val id = unit.positive("id")
                val info = unit.obj("additional")
                if (info.obj("thumbnail").number("unit_id") != id) invalid()
                source(id, unit.text("filename"), kind == "video", info)
            }.also { if (it.isEmpty() || it.map { source -> source.unitId }.distinct().size != it.size) invalid() }
        } else {
            val info = raw.obj("additional")
            val id = info.obj("thumbnail").positive("unit_id")
            if (thumbnailUnitId != null && thumbnailUnitId != id) changed()
            listOf(source(id, current.filename, current.mediaType in setOf("video", "video360"), info))
        }
        currentCoroutineContext().ensureActive(); checkAccess(owner, target.id.space)
        return result
    }

    suspend fun validate(task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport,
        owner: SynologyPhotosMutationAccess) {
        currentCoroutineContext().ensureActive(); checkAccess(owner, task.space)
        if (task.profileId != owner.profileId || task.source?.let { it.id.profileId != task.profileId || it.id.space != task.space } == true) denied()
        if (task.unitId <= 0 || task.typeCode < 0 || task.filename.isEmpty() || !task.needsThumbnail && !task.needsVideo ||
            task.needsVideo && (!task.video || !support.video)) invalid()
        capability("Upload.ConvertedFile", 3, task.space); capability("Download", 2, task.space)
        val candidates = task.source?.let { tasks(it, task.sourceThumbnailUnitId, support, owner) } ?: tasks(task.space, support, owner)
        if (task !in candidates) changed()
    }

    suspend fun download(task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport, destination: File) {
        val owner = identity()
        validate(task, support, owner)
        download(capability("Download", 2, task.space), task.unitId, destination) { validate(task, support, owner) }
    }

    /** 恢复核对同一原件/Unit的身份和权限，不能再要求需求仍为ame_defect。 */
    suspend fun reviewSource(task: SynologyPhotoAutomaticPreviewTask, owner: SynologyPhotosMutationAccess): Source? {
        currentCoroutineContext().ensureActive(); checkAccess(owner, task.space)
        if (task.profileId != owner.profileId) denied()
        val source = task.source?.let { target ->
            sources(target, task.sourceThumbnailUnitId, owner).singleOrNull {
                it.unitId == task.unitId && it.filename == task.filename && it.video == task.video
            } ?: changed()
        }
        if (task.source == null && task.space == SynologyPhotoSpace.SHARED && !owner.managesShared) denied()
        currentCoroutineContext().ensureActive(); checkAccess(owner, task.space)
        return source
    }

    private fun source(id: Long, filename: String, video: Boolean, info: JsonObject): Source {
        if (filename.isEmpty()) invalid()
        val thumbnail = info.obj("thumbnail")
        return Source(id, filename, video, thumbnail.optionalText("xl"), thumbnail.optionalText("sm"),
            info.optionalText("video_convert_status"), info.optionalObject("video_meta")?.optionalText("video_codec"))
    }
    private fun flag(value: JsonObject, name: String): Boolean = when (value[name]) {
        JsonPrimitive(true), JsonPrimitive(1) -> true
        JsonPrimitive(false), JsonPrimitive(0) -> false
        else -> invalid()
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}

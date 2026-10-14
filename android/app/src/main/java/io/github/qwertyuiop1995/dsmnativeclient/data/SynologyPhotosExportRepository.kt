package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotosMediaTransport
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.encode
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.permission
import java.io.File
import kotlinx.serialization.json.*

/** 原件/转换/归档共用下载传输；每次重新检查对象与下载权，不借贡献权下载整册。 */
internal class SynologyPhotosExportRepository(
    private val profileId: String,
    private val generation: () -> Long,
    private val checkAccess: suspend (Long, SynologyPhotoSpace?) -> Unit,
    private val userId: () -> Long?,
    private val allowedSpaces: () -> Set<SynologyPhotoSpace>,
    private val managesShared: () -> Boolean,
    private val supportsOriginalJPEG: () -> Boolean,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val details: suspend (SynologyPhoto) -> SynologyPhoto,
    private val albumContext: suspend (Long, Boolean, Boolean) -> Map<String, JsonElement>,
    private val pending: (SynologyPhotoId, String?) -> Boolean,
    private val media: () -> SynologyPhotosMediaTransport,
) {
    private val conversions = mutableSetOf<SynologyPhotoId>()

    suspend fun download(photo: SynologyPhoto, format: SynologyPhotoDownloadFormat, destination: File,
        progress: (Long, Long) -> Unit, previewOperationId: String? = null): SynologyPhotoDownloadFormat {
        val token = generation()
        val space = photo.id.space.takeIf { photo.albumContext == null }
        requirePhoto(photo, previewOperationId); checkAccess(token, space)
        val converting = format == SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG
        if (converting && (!supportsOriginalJPEG() || !photo.supportsOriginalSizeJPEG)) unavailable()
        if (converting && !synchronized(conversions) { conversions.add(photo.id) }) changed()
        try {
            // 能力、目标和权限均在可能生成派生缓存的convert之前检查。
            val api = capability("Download", 2, space)
            val transport = media()
            val current = details(photo)
            if (!SynologyPhotoEditTarget(photo).matches(current, includeTime = true)) changed()
            val context = photo.albumContext?.let {
                val own = photo.id.space in allowedSpaces() && userId() != null && current.albumContext?.providerUserId == userId()
                val authorized = albumContext(it.albumId, own, false)
                if (converting) authorized else json("album_id" to it.albumId)
            } ?: run { folder(photo.id.space, photo.folderId); emptyMap() }
            requirePhoto(photo, previewOperationId); checkAccess(token, space)
            if (converting) {
                write("Download", 2, "convert", context + json("item_id" to photo.id.itemId), space)
                checkAccess(token, space); requirePhoto(photo, previewOperationId)
            }
            return transport.downloadPhoto(api, encode(context + json("item_id" to array(photo.id.itemId),
                "force_download" to true, "download_type" to format.value)), destination, photo.sizeBytes, format,
                post = converting, beforeCommit = { checkAccess(token, space); requirePhoto(photo, previewOperationId) }, progress = progress)
        } finally { if (converting) synchronized(conversions) { conversions.remove(photo.id) } }
    }

    suspend fun archive(target: SynologyPhotoArchiveTarget, format: SynologyPhotoDownloadFormat, destination: File,
        progress: (Long, Long) -> Unit) {
        if (format == SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG) unavailable()
        val token = generation()
        var space: SynologyPhotoSpace? = null
        val suffix: String
        val parameters: Map<String, JsonElement>
        when (target) {
            is SynologyPhotoArchiveTarget.Album -> {
                checkAccess(token, null)
                suffix = "Browse.Album"; parameters = albumContext(target.id, false, true)
            }
            is SynologyPhotoArchiveTarget.Folder -> {
                space = target.space; checkAccess(token, space); folder(target.space, target.id)
                suffix = "Download"; parameters = json("folder_id" to array(target.id), "force_download" to true)
            }
            is SynologyPhotoArchiveTarget.Selection -> {
                val parent = selectionParent(target.folders)
                space = parent.space; checkAccess(token, space)
                if (target.photos.map { it.id }.toSet().size != target.photos.size) changed()
                target.photos.forEach {
                    requirePhoto(it)
                    if (it.albumContext != null || it.id.space != parent.space || it.folderId != parent.id) changed()
                }
                for (selected in target.folders + if (target.photos.isEmpty()) emptyList() else listOf(parent)) {
                    val raw = folder(selected.space, selected.id)
                    val actual = SynologyPhotoFolderCodec.decode(raw, selected.space, managesShared(), SynologyPhotoSort()).folder
                    if (actual.path != selected.path || selected.id != parent.id && actual.parentId != parent.id) changed()
                }
                for (batch in target.photos.chunked(100)) {
                    val rows = read("Browse.Item", 5, "get", json("id" to array(*batch.map { it.id.itemId }.toTypedArray())), space).list()
                        .map { SynologyPhotosCodec.photo(it, profileId, parent.space) }
                    if (rows.size != batch.size || batch.any { photo -> rows.count { SynologyPhotoEditTarget(photo).matches(it, includeTime = true) } != 1 }) changed()
                }
                suffix = "Download"
                parameters = json("folder_id" to array(*target.folders.map { it.id }.toTypedArray()), "force_download" to true) +
                    if (target.photos.isEmpty()) emptyMap() else json("item_id" to array(*target.photos.map { it.id.itemId }.toTypedArray()))
            }
        }
        checkAccess(token, space)
        media().downloadArchive(capability(suffix, 2, space), encode(parameters + json("download_type" to format.value)), destination,
            beforeCommit = {
                checkAccess(token, space)
                if (target is SynologyPhotoArchiveTarget.Selection) target.photos.forEach { requirePhoto(it) }
            }, progress = progress)
    }

    private suspend fun folder(space: SynologyPhotoSpace, id: Long): JsonObject {
        if (id <= 0) invalid()
        val raw = read("Browse.Folder", 2, "get", json("id" to id, "additional" to array("access_permission")), space).obj("folder")
        if (raw.number("id") != id) changed()
        val rights = raw.optionalObject("additional")?.optionalObject("access_permission")
        if (!(space == SynologyPhotoSpace.SHARED && managesShared()) &&
            (rights?.permission("view") != true || if (space == SynologyPhotoSpace.PERSONAL) rights.optionalBoolean("download") == false else !rights.permission("download"))) denied()
        return raw
    }

    private fun selectionParent(folders: List<SynologyPhotoCollection>): SynologyPhotoCollection {
        if (folders.map { it.id }.toSet().size != folders.size) changed()
        return SynologyPhotoFileValidation.parent(folders.map {
            SynologyPhotoFolderSnapshot(it.id, it.parentId, it.name, it.path ?: invalid(), it.space)
        }).collection()
    }
    private fun requirePhoto(photo: SynologyPhoto, previewOperationId: String? = null) {
        if (photo.id.profileId != profileId || photo.id.itemId <= 0) denied()
        if (pending(photo.id, previewOperationId)) changed()
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
    private fun unavailable(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.UNAVAILABLE)
}

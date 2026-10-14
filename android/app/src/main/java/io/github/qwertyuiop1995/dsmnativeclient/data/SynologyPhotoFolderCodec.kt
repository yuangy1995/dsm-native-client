package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalLong
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.permission
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.serialization.json.*

internal object SynologyPhotoFolderCodec {
    fun validName(name: String): Boolean = name.isNotBlank() && name.length <= 255 && !name.startsWith('.') && !name.endsWith('.') &&
        name !in setOf("@database", "@eaDir", "@tmp", "@sharebin", "#recycle", "#snapshot") && name.none { it in "/\\:\u0000" }

    fun validPath(path: String): Boolean = path.startsWith('/') && (path == "/" || !path.endsWith('/') &&
        path.substring(1).split('/').all { it.isNotEmpty() && it != "." && it != ".." }) && '\u0000' !in path

    fun contains(parent: String, child: String): Boolean = validPath(parent) && validPath(child) &&
        (parent == "/" || child == parent || child.startsWith("$parent/"))

    fun childPath(parent: String, name: String): String {
        if (!validPath(parent) || !validName(name)) invalid()
        return if (parent == "/") "/$name" else "$parent/$name"
    }
    fun renamedPath(folder: SynologyPhotoFolderSnapshot, name: String): String {
        if (folder.path == "/") invalid()
        return childPath(folder.path.substringBeforeLast('/').ifEmpty { "/" }, name)
    }
    fun sort(value: JsonObject, default: SynologyPhotoSort = SynologyPhotoSort(), fieldKey: String = "sort_by"): SynologyPhotoSort =
        SynologyPhotoSort(field(value, fieldKey) ?: default.field, direction(value) ?: default.direction)
    private fun field(value: JsonObject, key: String = "sort_by") = SynologyPhotoSort.Field.entries.firstOrNull { it.value == (value[key] as? JsonPrimitive)?.contentOrNull }
    private fun direction(value: JsonObject) = SynologyPhotoSort.Direction.entries.firstOrNull { it.value == (value["sort_direction"] as? JsonPrimitive)?.contentOrNull }

    fun decode(value: JsonObject, space: SynologyPhotoSpace, managesShared: Boolean, default: SynologyPhotoSort): SynologyPhotoFolderAccess {
        val path = value.text("name")
        val folder = SynologyPhotoFolderSnapshot(value.positive("id"), value.optionalLong("parent"),
            path.substringAfterLast('/').ifEmpty { "/" }, path, space)
        validate(folder)
        val rights = value.optionalObject("additional")?.optionalObject("access_permission")
        val manager = space == SynologyPhotoSpace.SHARED && managesShared
        if (!manager && rights?.permission("view") != true) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        val canManage = manager || rights?.permission("manage") == true
        val canCreate = canManage || space == SynologyPhotoSpace.SHARED && rights?.permission("upload") == true
        val explicit = field(value)?.let { field -> direction(value)?.let { SynologyPhotoSort(field, it) } }
        return SynologyPhotoFolderAccess(folder, canCreate, canManage, sort(value, default), explicit, covers(value),
            canUpload = canManage || rights?.permission("upload") == true,
            canDownload = manager || rights?.permission("download") == true)
    }
    fun covers(value: JsonObject): List<SynologyPhotoFolderCover> {
        // 封面缺失或单项格式未知不能阻断目录内容读取；写后确认仍要求明确可解码的序号 0。
        val values = (value["additional"] as? JsonObject)?.get("thumbnail") as? JsonArray ?: return emptyList()
        return values.take(4).mapNotNull { raw ->
            val item = raw as? JsonObject ?: return@mapNotNull null
            val revision = (item["cache_key"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return@mapNotNull null
            val seq = (item["folder_cover_seq"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull
            val unit = (item["unit_id"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull
            when { seq != null && seq >= 0 -> SynologyPhotoFolderCover(revision, sequence = seq)
                unit != null && unit > 0 && (seq == null || seq < 0) -> SynologyPhotoFolderCover(revision, unitId = unit)
                else -> null }
        }
    }
    fun validate(folder: SynologyPhotoFolderSnapshot) {
        if (folder.id <= 0 || !validPath(folder.path) || folder.name != folder.path.substringAfterLast('/').ifEmpty { "/" } ||
            folder.parentId?.let { it < 0 || it == folder.id || it == 0L && folder.path != "/" } == true) invalid()
    }
    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val operation = row.folder ?: invalid(); validate(operation.target)
        val target = operation.target
        val naming = row.action in setOf(SynologyPhotoAlbumAction.CREATE_FOLDER, SynologyPhotoAlbumAction.RENAME_FOLDER)
        if (naming != (operation.name != null) || operation.name?.let { !validName(it) } == true ||
            (row.action == SynologyPhotoAlbumAction.SORT_FOLDER) != (operation.sort != null) ||
            (row.action == SynologyPhotoAlbumAction.COVER_FOLDER) != (operation.coverPhoto != null) ||
            row.action in setOf(SynologyPhotoAlbumAction.RENAME_FOLDER, SynologyPhotoAlbumAction.COVER_FOLDER) && target.path == "/" ||
            operation.createdFolderId?.let { it <= 0 || it == target.id || row.action != SynologyPhotoAlbumAction.CREATE_FOLDER || !row.submitted } == true ||
            operation.coverAcknowledged && (row.action != SynologyPhotoAlbumAction.COVER_FOLDER || !row.submitted) ||
            row.phase == SynologyPhotoAlbumPhase.PARTIAL || row.finished &&
            (row.action == SynologyPhotoAlbumAction.CREATE_FOLDER && operation.createdFolderId == null || row.action == SynologyPhotoAlbumAction.COVER_FOLDER && !operation.coverAcknowledged)) invalid()
        operation.coverPhoto?.let { photo ->
            if (photo.id.profileId != row.profileId || photo.id.space != target.space || photo.albumContext != null ||
                photo.id.itemId <= 0 || photo.folderId <= 0 || photo.filename.isBlank() || photo.sizeBytes < 0 ||
                !photo.takenAt.isFinite() || !photo.indexedAt.isFinite() || photo.mediaType.isBlank()) invalid()
        }
    }
}

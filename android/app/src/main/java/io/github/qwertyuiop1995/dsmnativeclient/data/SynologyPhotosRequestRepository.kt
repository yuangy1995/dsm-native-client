package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.boolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalText
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.permission
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** 复用相册操作互斥与持久阶段；请求口令仅用于当前会话，冷恢复完全只读。 */
internal class SynologyPhotosRequestRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
) {
    suspend fun get(id: String): SynologyPhotoRequest {
        if (id.isEmpty()) invalid()
        return find(identity()) { it == id } ?: changed()
    }
    suspend fun restored(row: SynologyPhotoAlbumCheckpoint): SynologyPhotoRequest? {
        val owner = identity(); validatePhotoAlbumCheckpoint(row)
        if (!row.action.isRequest || row.profileId != owner.profileId || row.userId != owner.userId) denied()
        val digest = row.request!!.targetDigest ?: return null
        return find(owner) { SynologyPhotoRequestCodec.hash(it) == digest }
    }
    private suspend fun find(owner: SynologyPhotosMutationAccess, matches: (String) -> Boolean): SynologyPhotoRequest? {
        var offset = 0; val seen = mutableSetOf<String>()
        while (true) {
            currentCoroutineContext().ensureActive(); checkAccess(owner, null)
            val page = read("PhotoRequest", 1, "list", json("offset" to offset, "limit" to 500), null).list()
            checkAccess(owner, null)
            if (page.size > 500 || page.any { !seen.add(it.text("passphrase").also { id -> if (id.isEmpty()) invalid() }) }) invalid()
            page.firstOrNull { matches(it.text("passphrase")) }?.let { return SynologyPhotoRequestCodec.decode(it, owner.profileId) }
            if (page.size < 500) return null
            if (offset > Int.MAX_VALUE - page.size) invalid()
            offset += page.size
        }
    }
    suspend fun albums(): List<SynologyPhotoRequestAlbum> {
        val owner = identity(); val result = mutableListOf<SynologyPhotoRequestAlbum>(); val seen = mutableSetOf<Long>(); var offset = 0
        while (true) {
            currentCoroutineContext().ensureActive(); checkAccess(owner, null)
            val page = read("Browse.NormalAlbum", 1, "list", json("category" to "addable", "offset" to offset, "limit" to 500,
                "sort_by" to "album_name", "sort_direction" to "asc", "additional" to array("sharing_info", "thumbnail")), null).list()
            checkAccess(owner, null)
            if (page.size > 500) invalid()
            page.forEach { raw ->
                val id = raw.positive("id"); if (!seen.add(id)) invalid()
                val author = raw.positive("owner_user_id"); val shared = raw.boolean("shared"); val name = raw.text("name")
                if (raw.optionalBoolean("freeze_album") == true) return@forEach
                if (author == owner.userId) result += SynologyPhotoRequestAlbum(albumId = id, name = name, shared = shared)
                else {
                    val passphrase = raw.optionalObject("additional")?.optionalObject("sharing_info")?.optionalText("passphrase")?.takeIf { it.isNotEmpty() } ?: invalid()
                    result += SynologyPhotoRequestAlbum(passphrase = passphrase, name = name, shared = shared, sourceAlbumId = id)
                }
            }
            if (page.size < 500) return result
            if (offset > Int.MAX_VALUE - page.size) invalid()
            offset += page.size
        }
    }
    suspend fun folder(space: SynologyPhotoSpace, id: Long): SynologyPhotoCollection {
        val owner = identity(); if (id <= 0) invalid()
        val raw = folderRaw(space, id, owner)
        return SynologyPhotosCodec.collection(raw, folder = true).copy(space = space)
    }
    private suspend fun folderRaw(space: SynologyPhotoSpace, id: Long?, owner: SynologyPhotosMutationAccess): JsonObject {
        checkAccess(owner, space)
        val fields = (if (id == null) json("name" to "/") else json("id" to id)) + json("additional" to array("access_permission"))
        val raw = read("Browse.Folder", 2, "get", fields, space).obj("folder")
        if (id != null && raw.positive("id") != id) changed()
        val rights = raw.optionalObject("additional")?.optionalObject("access_permission")
        if (!(space == SynologyPhotoSpace.SHARED && owner.managesShared) &&
            !(rights?.permission("view") == true && (rights.permission("manage") || rights.permission("upload")))) denied()
        checkAccess(owner, space)
        return raw
    }
    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, change: SynologyPhotoRequestChange, owner: SynologyPhotosMutationAccess) {
        val intent = SynologyPhotoRequestCodec.checkpoint(row.action, change)
        if (intent != row.request) changed()
        change.original?.let { old ->
            if (old.profileId != owner.profileId) denied()
            if (find(owner) { it == old.id } != old) changed()
        }
        change.settings?.let { settings ->
            SynologyPhotoRequestCodec.validate(settings); checkAccess(owner, settings.space)
            val folder = folderRaw(settings.space, settings.folderId, owner)
            if (settings.folderId != null) { if (folder.text("name") != settings.folderPath) changed() }
            else {
                if (settings.space == SynologyPhotoSpace.SHARED && !owner.managesShared ||
                    settings.folderPath != SynologyPhotoRequestSettings.defaultFolderPath(settings.subject)) denied()
                // 默认目录尚不存在；只核对实际根目录编号与上传资格，不预建收集目录。
                folderRaw(settings.space, folder.positive("id"), owner)
            }
            if (settings.albumId != null || settings.albumPassphrase != null) {
                if (albums().none { it.albumId == settings.albumId && it.passphrase == settings.albumPassphrase }) denied()
            }
        }
        checkAccess(owner, null)
    }
    suspend fun execute(row: SynologyPhotoAlbumCheckpoint, change: SynologyPhotoRequestChange, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        currentCoroutineContext().ensureActive(); checkAccess(owner, null)
        return when (row.action) {
            SynologyPhotoAlbumAction.CREATE_REQUEST -> {
                val receipt = write("PhotoRequest", 1, "create", SynologyPhotoRequestCodec.parameters(change.settings!!) + json("passphrase" to ""), null)
                val id = receipt.text("passphrase").also { if (it.isEmpty()) invalid() }
                row.copy(request = row.request!!.copy(targetDigest = SynologyPhotoRequestCodec.hash(id)))
            }
            SynologyPhotoAlbumAction.UPDATE_REQUEST -> {
                val fields = SynologyPhotoRequestCodec.updates(change.original!!.settings, change.settings!!)
                if (fields.isNotEmpty()) write("PhotoRequest", 1, "update", fields + json("passphrase" to change.original.id), null)
                row
            }
            SynologyPhotoAlbumAction.DELETE_REQUEST -> { write("PhotoRequest", 1, "delete", json("passphrase" to array(change.original!!.id)), null); row }
            else -> invalid()
        }
    }
    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): Boolean {
        val saved = row.request!!; val target = saved.targetDigest ?: return false
        checkAccess(owner, null)
        val actual = find(owner) { SynologyPhotoRequestCodec.hash(it) == target }
        if (row.action == SynologyPhotoAlbumAction.DELETE_REQUEST) return actual == null
        return actual != null && actual.isFolderValid && actual.settings.space == saved.space &&
            SynologyPhotoRequestCodec.digest(actual.settings, saved.includesFolderId) == saved.settingsDigest &&
            (row.action != SynologyPhotoAlbumAction.CREATE_REQUEST || actual.url != null)
    }
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
}

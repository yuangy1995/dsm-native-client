package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalText
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

/** 统一 Foto 用户任务，详情补充失败不隐藏已读取的原因；目标不能扩张来源权限。 */
internal class SynologyPhotosBackgroundRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val spaces: () -> Set<SynologyPhotoSpace>,
    private val folderAccess: suspend (SynologyPhotoSpace, Long) -> SynologyPhotoFolderAccess,
    private val operations: () -> List<SynologyPhotoAlbumCheckpoint>,
) {
    suspend fun tasks(): List<SynologyPhotoBackgroundTask> = tasks(identity())
    private suspend fun tasks(owner: SynologyPhotosMutationAccess): List<SynologyPhotoBackgroundTask> {
        checkAccess(owner, null); capability("BackgroundTask.Info", 1, null)
        val result = SynologyPhotoBackgroundCodec.tasks(read("BackgroundTask.Info", 1, "list_user_task", emptyMap(), null), owner.profileId, owner.userId)
        currentCoroutineContext().ensureActive(); checkAccess(owner, null)
        return result
    }
    private suspend fun current(task: SynologyPhotoBackgroundTask, owner: SynologyPhotosMutationAccess): SynologyPhotoBackgroundTask {
        if (task.profileId != owner.profileId || task.userId != owner.userId) denied()
        return tasks(owner).singleOrNull { it.sameIdentity(task) } ?: changed()
    }

    suspend fun errors(task: SynologyPhotoBackgroundTask): List<SynologyPhotoBackgroundError> {
        val owner = identity(); val current = current(task, owner)
        if (current.errors == 0L) return emptyList()
        val values = SynologyPhotoBackgroundCodec.errors(read("BackgroundTask.Info", 1, "get_error_detail", json("id" to task.id), null))
        checkAccess(owner, null)
        val space = current.targetSpace?.takeIf { it in spaces() } ?: return values
        val names = mutableMapOf<String, Pair<String, String?>>()
        val ids = values.filter { it.kind == SynologyPhotoBackgroundError.Kind.ITEM }.map { it.itemId }
        for (batch in ids.chunked(100)) {
            currentCoroutineContext().ensureActive(); checkAccess(owner, space)
            try {
                val items = read("Browse.Item", 5, "get", json("id" to JsonArray(batch.map(::JsonPrimitive)), "additional" to array("folder")), space).list()
                if (items.map { it.positive("id") }.distinct().size != items.size || items.any { it.positive("id") !in batch }) invalid()
                val additions = items.associate { item ->
                    "ITEM:${item.positive("id")}" to (item.text("filename") to item.optionalObject("additional")?.optionalText("folder"))
                }
                names.putAll(additions)
            } catch (error: Exception) { if (error is CancellationException) throw error }
        }
        for (entry in values.filter { it.kind == SynologyPhotoBackgroundError.Kind.FOLDER }) {
            currentCoroutineContext().ensureActive(); checkAccess(owner, space)
            try {
                val folder = folderAccess(space, entry.itemId).folder
                if (folder.id != entry.itemId || folder.space != space) changed()
                names[entry.key] = folder.name to folder.path.substringBeforeLast('/').ifEmpty { "/" }
            } catch (error: Exception) { if (error is CancellationException) throw error }
        }
        currentCoroutineContext().ensureActive(); checkAccess(owner, space)
        return values.map { entry -> entry.copy(name = names[entry.key]?.first, folderPath = names[entry.key]?.second) }
    }

    suspend fun target(task: SynologyPhotoBackgroundTask): List<SynologyPhotoCollection> {
        val owner = identity(); val current = current(task, owner)
        if (!current.canOpenTarget) denied()
        val space = current.targetSpace?.takeIf { it in spaces() } ?: denied()
        var id = current.snapshot.targetFolderId ?: denied()
        val path = mutableListOf<SynologyPhotoCollection>(); val visited = mutableSetOf<Long>()
        while (true) {
            currentCoroutineContext().ensureActive(); checkAccess(owner, space)
            if (!visited.add(id)) changed()
            val folder = folderAccess(space, id).folder
            if (folder.id != id || folder.space != space) changed()
            path.add(folder.collection())
            if (folder.path == "/") break
            id = folder.parentId?.takeIf { it > 0 } ?: changed()
        }
        checkAccess(owner, space)
        return path.reversed()
    }

    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        val value = row.background ?: invalid()
        SynologyPhotoBackgroundCodec.validate(value, row.action == SynologyPhotoAlbumAction.CLEAR_TASKS, row.phase)
        if (operations().any { photoAlbumsConflict(it, row) }) changed()
        val latest = tasks(owner)
        for (expected in value.tasks) {
            val task = latest.singleOrNull { it.id == expected.id } ?: changed()
            if (!expected.sameIdentity(task.snapshot) ||
                (if (row.action == SynologyPhotoAlbumAction.CLEAR_TASKS) !task.snapshot.canClear else !task.snapshot.canStop)) changed()
        }
    }

    suspend fun execute(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        var row = input
        for (expected in input.background!!.tasks) {
            currentCoroutineContext().ensureActive(); checkAccess(owner, null)
            // 每次写入重新核对该项，随后完成的新任务永远不进入固定范围。
            val latest = tasks(owner).singleOrNull { it.id == expected.id } ?: changed()
            if (!expected.sameIdentity(latest.snapshot) || operations().any { photoAlbumsConflict(it, row) } ||
                (if (row.action == SynologyPhotoAlbumAction.CLEAR_TASKS) !latest.snapshot.canClear else !latest.snapshot.canStop)) changed()
            currentCoroutineContext().ensureActive(); checkAccess(owner, null)
            row = row.copy(background = row.background!!.copy(attempted = row.background!!.attempted + expected.id))
            persist(row)
            try {
                if (row.action == SynologyPhotoAlbumAction.CLEAR_TASKS) write("BackgroundTask.Info", 1, "clear_completed_task", json("id" to expected.id), null)
                else write("BackgroundTask.Info", 1, "abort_task", json("id" to array(expected.id)), null)
            } catch (error: DsmFailure) {
                if (error.code in setOf(105, 106, 107, 119)) {
                    row = row.copy(background = row.background!!.copy(rejected = row.background!!.rejected + expected.id))
                    withContext(NonCancellable) { persist(row) }
                }
                throw error
            }
        }
        return row
    }

    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        val value = row.background ?: invalid(); checkAccess(owner, null)
        val unresolved = value.attempted - value.rejected - value.completed
        val completed = value.completed.toMutableSet()
        if (unresolved.isNotEmpty()) {
            val latest = tasks(owner)
            for (expected in value.tasks.filter { it.id in unresolved }) {
                val current = latest.singleOrNull { it.id == expected.id }
                if (current != null && !expected.sameIdentity(current.snapshot)) changed()
                if (current == null || row.action == SynologyPhotoAlbumAction.STOP_TASK && current.snapshot.status == SynologyPhotoBackgroundStatus.DONE)
                    completed.add(expected.id)
            }
        }
        val phase = when {
            completed.size == value.tasks.size -> SynologyPhotoAlbumPhase.COMPLETED
            (unresolved - completed).isEmpty() -> SynologyPhotoAlbumPhase.PARTIAL
            else -> SynologyPhotoAlbumPhase.PENDING
        }
        checkAccess(owner, null)
        return row.copy(phase = phase, background = value.copy(completed = completed))
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}

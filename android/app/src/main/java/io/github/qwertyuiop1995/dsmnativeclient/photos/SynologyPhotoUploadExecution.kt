package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.*

/** 固定清单先复制后发送；文件夹逐层确认，任何未知写入都只读恢复。 */
internal class SynologyPhotoUploadExecution(
    private val repository: SynologyPhotosServing,
    private val store: SynologyPhotoUploadStore,
    private val owner: WorkspaceOwner,
    private val beforeWrite: suspend (SynologyPhotoUploadTarget) -> Unit = {},
    private val requireCurrent: () -> Unit = {},
) {
    suspend fun stage(userId: Long, target: SynologyPhotoUploadTarget, targetName: String, duplicate: SynologyPhotoUploadDuplicate,
        sources: List<SynologyPhotoLocalSource>, keepFolders: Boolean,
        progress: (Int, Int, Long) -> Unit = { _, _, _ -> }): SynologyPhotoUploadBatch = withContext(Dispatchers.IO) {
        if (sources.isEmpty()) throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.EMPTY)
        if (sources.size > MAX_PHOTO_IMPORT_ITEMS) throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.LIMIT)
        requireCurrent()
        if (repository.profileId != owner.profileId || repository.uploadIdentity() != userId) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        val structure = keepFolders && target !is SynologyPhotoUploadTarget.Album && sources.any { it.relativeFolder.isNotEmpty() }
        val destination = if (structure && target is SynologyPhotoUploadTarget.Timeline)
            SynologyPhotoUploadTarget.Folder(target.space, repository.rootFolder(target.space).id) else target
        repository.prepareUploadTarget(destination)
        beforeWrite(destination)
        val id = UUID.randomUUID().toString()
        store.exclusive(owner, id) {
            val directory = store.directory(id)
            if (directory.exists() || !directory.mkdirs()) throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.STORAGE)
            directory.setReadable(false, false); directory.setWritable(false, false); directory.setExecutable(false, false)
            directory.setReadable(true, true); directory.setWritable(true, true); directory.setExecutable(true, true)
            var attemptedSave = false
            try {
                val entries = sources.mapIndexed { index, source ->
                    requireCurrent(); currentCoroutineContext().ensureActive()
                    copy(id, source, structure) { bytes -> progress(index, sources.size, bytes) }
                }
                val folders = entries.flatMap { entry ->
                    if (entry.relativeFolder.isEmpty()) emptyList() else entry.relativeFolder.split('/').let { parts ->
                        (1..parts.size).map { parts.take(it).joinToString("/") }
                    }
                }.distinct().sortedWith(compareBy<String> { it.count { char -> char == '/' } }.thenBy { it })
                val row = SynologyPhotoUploadBatch(id = id, owner = owner, userId = userId, target = destination,
                    targetName = targetName, duplicate = duplicate, entries = entries, folders = folders)
                requireCurrent(); currentCoroutineContext().ensureActive()
                attemptedSave = true
                store.begin(row)
                progress(entries.size, sources.size, 0)
                row
            } catch (error: SynologyPhotoUploadFailure) {
                if (error.problem != SynologyPhotoUploadProblem.STORAGE) attemptedSave = false
                throw error
            } finally {
                // 保存失败可能已经改动了磁盘；保留副本与记录一起恢复，不能留下索引却删除媒体。
                if (!attemptedSave) directory.deleteRecursively()
            }
        }
    }

    suspend fun run(batchId: String, userId: Long, reviewOnly: Boolean = false,
        update: (SynologyPhotoUploadBatch, String?, Long, Long) -> Unit): SynologyPhotoUploadBatch = withContext(Dispatchers.IO) {
        store.exclusive(owner, batchId) {
            var row = store.get(batchId, owner, userId)
            requireCurrent()
            if (repository.uploadIdentity() != userId) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
            if (!reviewOnly && !row.finished) {
                store.requireNoConflictingBatch(row)
                beforeWrite(row.target)
            }
            for (path in row.folders) {
                requireCurrent(); currentCoroutineContext().ensureActive()
                val existing = row.folderCheckpoints[path]
                if (existing?.finished == true) continue
                if (reviewOnly && existing == null) continue
                val action = row.folderAction(path)
                val checkpoint = existing ?: SynologyPhotoUploadCheckpoint(profileId = owner.profileId, userId = userId, action = action)
                fun save(next: SynologyPhotoUploadCheckpoint) {
                    store.saveFolder(batchId, owner, userId, path, next)
                    row = store.get(batchId, owner, userId); update(row, path, 0, 0)
                }
                val next = if (checkpoint.submitted) repository.reviewPhotoUpload(checkpoint, ::save)
                    else repository.performPhotoUpload(checkpoint, null, ::save)
                val resolved = settle(next, ::save)
                row = store.get(batchId, owner, userId)
                if (!resolved.finished) return@exclusive row
            }
            for (entry in row.entries) {
                requireCurrent(); currentCoroutineContext().ensureActive()
                val existing = entry.checkpoint
                if (existing?.finished == true) continue
                if (reviewOnly && existing == null) continue
                val action = row.fileAction(entry)
                val checkpoint = existing ?: SynologyPhotoUploadCheckpoint(profileId = owner.profileId, userId = userId, action = action)
                fun save(next: SynologyPhotoUploadCheckpoint) {
                    store.saveFile(batchId, owner, userId, entry.id, next)
                    row = store.get(batchId, owner, userId)
                    update(row, entry.filename, if (next.itemId != null || next.finished) entry.size else 0,
                        if (next.phase == SynologyPhotoUploadPhase.PENDING && next.itemId == null) 0 else entry.size)
                }
                val next = if (checkpoint.submitted) repository.reviewPhotoUpload(checkpoint, ::save)
                    else repository.performPhotoUpload(checkpoint, store.artifact(row.id, entry.id), ::save) { done, total -> update(row, entry.filename, done, total) }
                val resolved = settle(next, ::save)
                row = store.get(batchId, owner, userId)
                if (!resolved.finished) return@exclusive row
            }
            row
        }
    }

    private suspend fun settle(record: SynologyPhotoUploadCheckpoint, save: (SynologyPhotoUploadCheckpoint) -> Unit): SynologyPhotoUploadCheckpoint {
        var current = record
        // 新媒体可能尚未出现在图库索引中；只对明确回执编号进行有界回读，不重放写入。
        if (!current.finished && (current.itemId != null || current.folderId != null)) repeat(2) {
            delay(600); requireCurrent()
            current = repository.reviewPhotoUpload(current, save)
            if (current.finished) return current
        }
        return current
    }

    private suspend fun copy(batchId: String, source: SynologyPhotoLocalSource, keepFolders: Boolean, progress: (Long) -> Unit): SynologyPhotoUploadEntry {
        fun validName(value: String) = value.isNotBlank() && value !in setOf(".", "..") && value.none { it == '/' || it == '\u0000' }
        if (!validName(source.filename) || source.relativeFolder.isNotEmpty() && source.relativeFolder.split('/').any { !validName(it) } ||
            source.size != null && source.size <= 0) throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.LOCAL_FILE)
        val id = UUID.randomUUID().toString()
        val file = store.artifact(batchId, id)
        if (!file.createNewFile()) throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.STORAGE)
        file.setReadable(false, false); file.setWritable(false, false)
        file.setReadable(true, true); file.setWritable(true, true)
        val digest = MessageDigest.getInstance("SHA-256")
        var size = 0L
        source.open().use { input -> file.outputStream().use { output ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                currentCoroutineContext().ensureActive()
                val count = input.read(buffer); if (count < 0) break
                size = Math.addExact(size, count.toLong())
                if (source.size != null && size > source.size) throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.LOCAL_FILE)
                output.write(buffer, 0, count); digest.update(buffer, 0, count); progress(size)
            }
            output.fd.sync()
        } }
        if (size <= 0 || source.size != null && size != source.size) throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.LOCAL_FILE)
        return SynologyPhotoUploadEntry(id, source.filename, size, digest.digest().joinToString("") { "%02x".format(it) },
            source.modifiedAtSeconds?.takeIf { it >= 0 } ?: System.currentTimeMillis() / 1_000, if (keepFolders) source.relativeFolder else "")
    }
}

internal const val MAX_PHOTO_IMPORT_ITEMS = 10_000

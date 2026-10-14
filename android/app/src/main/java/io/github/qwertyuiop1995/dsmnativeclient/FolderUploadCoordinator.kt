package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** 文件夹任务只使用已经保存的清单；未知写入只能读取结果，不能自动重放。 */
internal interface FolderUploadEndpoint {
    fun requireOwner()
    suspend fun directoryIsUsable(path: String): Boolean
    suspend fun item(path: String): FileItem?
    suspend fun prepare(entry: FolderUploadEntry): UploadSource
    suspend fun createDirectory(parent: String, path: String): MutationResult
    suspend fun upload(source: UploadSource, parent: String, overwrite: Boolean, progress: (Long, Long) -> Unit): MutationResult
    suspend fun contentMatches(item: FileItem, fingerprint: UploadContentFingerprint): Boolean
}

internal class FolderUploadCoordinator(
    private val store: TransferStore,
    private val endpoint: FolderUploadEndpoint,
    private val taskId: String,
    private val executionId: String,
    private val onProgress: (Long, Long) -> Unit = { _, _ -> },
) {
    private fun plan() = store.folderUploadPlan(taskId) ?: error("Folder plan unavailable")
    private fun update(transform: (FolderUploadPlan) -> FolderUploadPlan): FolderUploadPlan =
        store.updateFolderUploadPlan(taskId, executionId, transform) ?: throw CancellationException("Folder execution changed")
    private fun save(id: String, transform: (FolderUploadEntry) -> FolderUploadEntry) = update { current ->
        current.copy(entries = current.entries.map { if (it.source.id == id) transform(it) else it })
    }
    private suspend fun requireRunning() {
        currentCoroutineContext().ensureActive()
        endpoint.requireOwner()
        val task = store.upload(taskId)
        if (task?.workId != executionId || task.state != TransferState.RUNNING) throw CancellationException("Folder task stopped")
    }

    suspend fun run(): PersistedUpload? = withContext(Dispatchers.IO) { execute() }

    private suspend fun execute(): PersistedUpload? {
        val original = store.upload(taskId) ?: return null
        if (original.workId == executionId && original.state in setOf(TransferState.CANCELLING, TransferState.CANCELLED)) {
            return finalizeFolderUploadCancellation(store, taskId, executionId)
        }
        if (original.workId != executionId || original.state !in setOf(TransferState.WAITING, TransferState.RUNNING)) return original
        try {
            endpoint.requireOwner()
            update(FolderUploadPlan::recoveringInterruptedEntries)
            store.updateUpload(taskId) { if (it.workId == executionId && it.state in setOf(TransferState.WAITING, TransferState.RUNNING))
                it.copy(state = TransferState.RUNNING, errorKind = null, startedAtEpochMillis = it.startedAtEpochMillis ?: System.currentTimeMillis()) else it }
            // 恢复读取不会创建、覆盖或删除任何内容。
            plan().entries.filter { it.state == FolderUploadEntryState.UNRESOLVED && it.source.sourceIssue == null }.forEach { entry ->
                requireRunning()
                val path = plan().destinationPath.trimEnd('/') + "/" + entry.source.relativePath
                val confirmed = if (entry.source.isDirectory) endpoint.directoryIsUsable(path) else {
                    val proof = entry.fingerprint
                    val item = if (proof != null) endpoint.item(path) else null
                    item != null && proof != null && endpoint.contentMatches(item, proof)
                }
                if (confirmed) save(entry.source.id) { it.copy(state = FolderUploadEntryState.SUCCEEDED, completedBytes = it.source.bytes, errorKind = null) }
            }
            val ordered = plan().entries.sortedWith(compareBy<FolderUploadEntry> { !it.source.isDirectory }
                .thenBy { it.source.relativePath.count { char -> char == '/' } })
            for (scheduled in ordered) {
                requireRunning()
                val currentPlan = plan()
                val entry = currentPlan.entries.first { it.source.id == scheduled.source.id }
                if (entry.state != FolderUploadEntryState.PENDING || entry.source.sourceIssue != null) continue
                val source = entry.source
                val parentEntry = currentPlan.entries.firstOrNull { it.source.relativePath == source.parent && it.source.isDirectory }
                if (source.parent.isNotEmpty() && parentEntry?.state != FolderUploadEntryState.SUCCEEDED) {
                    save(source.id) { it.copy(state = FolderUploadEntryState.FAILED, errorKind = "PARENT_UNAVAILABLE") }
                    continue
                }
                val path = currentPlan.destinationPath.trimEnd('/') + "/" + source.relativePath
                val parent = path.substringBeforeLast('/')
                var submitting = false
                try {
                    if (!endpoint.directoryIsUsable(parent)) {
                        save(source.id) { it.copy(state = FolderUploadEntryState.FAILED, errorKind = DsmErrorKind.PERMISSION_DENIED.name) }
                        continue
                    }
                    val existing = endpoint.item(path)
                    if (source.isDirectory && existing != null) {
                        save(source.id) { it.copy(state = if (existing.isDirectory && existing.canWrite) FolderUploadEntryState.SUCCEEDED else FolderUploadEntryState.FAILED,
                            errorKind = if (existing.isDirectory && existing.canWrite) null else "TARGET_CONFLICT") }
                        continue
                    }
                    if (!source.isDirectory && existing != null && (!currentPlan.overwrite || existing.isDirectory)) {
                        save(source.id) { it.copy(state = if (existing.isDirectory) FolderUploadEntryState.FAILED else FolderUploadEntryState.SKIPPED,
                            completedBytes = if (existing.isDirectory) 0 else source.bytes,
                            errorKind = if (existing.isDirectory) "TARGET_CONFLICT" else null) }
                        continue
                    }
                    val uploadSource = if (source.isDirectory) null else endpoint.prepare(entry)
                    requireRunning()
                    save(source.id) { it.copy(state = FolderUploadEntryState.SUBMITTING, errorKind = null, completedBytes = 0) }
                    submitting = true
                    requireRunning()
                    var lastPublished = 0L
                    val result = if (source.isDirectory) endpoint.createDirectory(parent, path) else {
                        endpoint.upload(requireNotNull(uploadSource).copy(onContentRead = { proof ->
                            endpoint.requireOwner()
                            save(source.id) { it.copy(fingerprint = proof) }
                        }), parent, currentPlan.overwrite) { completed, _ ->
                            val aggregate = (currentPlan.completedBytes + completed).coerceAtMost(currentPlan.totalBytes)
                            val now = System.nanoTime()
                            if (now - lastPublished >= 400_000_000L || completed == source.bytes) {
                                lastPublished = now
                                store.updateUpload(taskId) { if (it.workId == executionId && it.state == TransferState.RUNNING)
                                    it.copy(completedBytes = aggregate) else it }
                                onProgress(aggregate, currentPlan.totalBytes)
                            }
                        }
                    }
                    save(source.id) { it.copy(
                        state = when {
                            result.status == MutationResultStatus.CONFIRMED_SUCCESS -> FolderUploadEntryState.SUCCEEDED
                            result.requiresRefresh -> FolderUploadEntryState.UNRESOLVED
                            result.status == MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> FolderUploadEntryState.CANCELLED
                            else -> FolderUploadEntryState.FAILED
                        },
                        completedBytes = if (result.status == MutationResultStatus.CONFIRMED_SUCCESS) source.bytes else 0,
                        errorKind = result.errorCategory?.name,
                    ) }
                    if (result.errorCategory == MutationErrorCategory.AUTHENTICATION) {
                        throw DsmFailure(null, "", "", kind = DsmErrorKind.SESSION_EXPIRED)
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Exception) {
                    if ((failure as? DsmFailure)?.kind in setOf(DsmErrorKind.WORKSPACE_CHANGED, DsmErrorKind.SESSION_EXPIRED,
                            DsmErrorKind.SAVED_SESSION_EXPIRED, DsmErrorKind.NO_SAVED_SESSION, DsmErrorKind.AUTHENTICATION_FAILED)) throw failure
                    save(source.id) { it.copy(state = if (submitting) FolderUploadEntryState.UNRESOLVED else FolderUploadEntryState.FAILED,
                        errorKind = (failure as? DsmFailure)?.kind?.name ?: "SOURCE_UNAVAILABLE") }
                }
                onProgress(plan().completedBytes, currentPlan.totalBytes)
            }
            val finished = plan()
            val succeeded = finished.entries.all { it.state in setOf(FolderUploadEntryState.SUCCEEDED, FolderUploadEntryState.SKIPPED) }
            return store.updateUpload(taskId) { if (it.workId == executionId && it.state in setOf(TransferState.RUNNING, TransferState.CANCELLING))
                it.copy(state = if (succeeded) TransferState.SUCCEEDED else if (it.state == TransferState.CANCELLING) TransferState.CANCELLED else TransferState.FAILED,
                    completedBytes = finished.completedBytes, requiresRefresh = finished.requiresRefresh,
                    errorKind = if (succeeded) null else DsmErrorKind.UPLOAD_FAILED.name) else it }
        } catch (cancelled: CancellationException) {
            stop(cancelled = true)
            throw cancelled
        } catch (failure: Exception) {
            stop(cancelled = false, failure = failure)
            return store.upload(taskId)
        }
    }

    private fun stop(cancelled: Boolean, failure: Exception? = null) {
        // 保存失败时停止后续写入；已保存的 SUBMITTING 会在下次读取时转为未知。
        runCatching { update { current -> current.recoveringInterruptedEntries().copy(entries = current.recoveringInterruptedEntries().entries.map {
            if (it.state == FolderUploadEntryState.PENDING) it.copy(state = if (cancelled) FolderUploadEntryState.CANCELLED else FolderUploadEntryState.PAUSED) else it
        }) } }
        store.updateUpload(taskId) { if (it.workId != executionId) it else it.copy(
            state = if (it.state == TransferState.CANCELLING || cancelled && it.state != TransferState.PAUSED) TransferState.CANCELLED else TransferState.PAUSED,
            errorKind = (failure as? DsmFailure)?.kind?.name ?: it.errorKind,
        ) }
    }
}

/** 覆盖执行器尚未启动就取消，以及系统先报告停止、确定结果稍后返回的窗口。 */
internal fun finalizeFolderUploadCancellation(store: TransferStore, taskId: String, executionId: String): PersistedUpload? {
    val task = store.upload(taskId) ?: return null
    if (task.workId != executionId || task.state !in setOf(TransferState.CANCELLING, TransferState.CANCELLED)) return task
    val plan = store.updateFolderUploadPlan(taskId, executionId) { current ->
        val recovered = current.recoveringInterruptedEntries()
        recovered.copy(entries = recovered.entries.map { if (it.state == FolderUploadEntryState.PENDING)
            it.copy(state = FolderUploadEntryState.CANCELLED) else it })
    } ?: return store.upload(taskId)
    val complete = plan.entries.all { it.state in setOf(FolderUploadEntryState.SUCCEEDED, FolderUploadEntryState.SKIPPED) }
    return store.updateUpload(taskId) { if (it.workId == executionId && it.state in setOf(TransferState.CANCELLING, TransferState.CANCELLED))
        it.copy(state = if (complete) TransferState.SUCCEEDED else TransferState.CANCELLED,
            requiresRefresh = plan.requiresRefresh, completedBytes = plan.completedBytes,
            errorKind = if (complete) null else it.errorKind) else it }
}

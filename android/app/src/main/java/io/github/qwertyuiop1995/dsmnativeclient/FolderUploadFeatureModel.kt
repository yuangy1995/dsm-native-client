package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.work.*
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class FolderUploadUiState(
    val plan: FolderUploadPlan? = null,
    val preview: Boolean = false,
    val busy: Boolean = false,
    val message: Int? = null,
    val taskState: TransferState? = null,
)

/** 工作区仅负责入口；来源准备、目录任务及详情由同一个功能模型拥有。 */
internal class FolderUploadFeatureModel(
    private val context: Context,
    private val scope: CoroutineScope,
    private val transfers: TransferStore,
    private val profiles: SecureProfileStore,
    private val coordinator: TransferCoordinator,
    private val workManager: WorkManager,
    private val repository: () -> DsmRepository?,
    private val onChanged: (String) -> Unit,
    private val observe: (String, UUID) -> Unit,
) {
    private val _ui = MutableStateFlow(FolderUploadUiState())
    val ui = _ui.asStateFlow()
    private var previewRepository: DsmRepository? = null
    private var previewIsCurrent: (() -> Boolean)? = null
    private val ownership = WorkspaceTaskOwnership(profiles)
    private val uriAccess = TransferUriAccess(context, transfers)

    init {
        scope.launch { transferChanges.collect {
            val current = _ui.value
            if (!current.preview && current.plan != null) {
                val updated = withContext(Dispatchers.IO) { runCatching { transfers.folderUploadPlan(current.plan.taskId) }.getOrNull() }
                _ui.update { if (it.plan?.taskId == current.plan.taskId && !it.preview) it.copy(plan = updated, taskState = transfers.upload(current.plan.taskId)?.state) else it }
            }
        } }
    }

    suspend fun prepare(tree: Uri, destination: String, profileId: String, repo: DsmRepository, isCurrent: () -> Boolean) {
        close()
        var retained = false
        try {
            context.contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val scan = scanDocumentTree(context, tree, MAX_FILE_TREE_DOCUMENTS, includeRoot = true) { true }
            if (!isCurrent()) return
            if (scan.truncated) { _ui.value = FolderUploadUiState(message = R.string.folder_upload_too_large); return }
            val plan = folderUploadPlan(UUID.randomUUID().toString(), profileId, tree.toString(), destination, scan)
            if (plan.entries.none { it.source.isDirectory && it.source.parent.isEmpty() && it.source.sourceIssue == null }) throw IOException("Folder root unavailable")
            previewRepository = repo
            previewIsCurrent = isCurrent
            _ui.value = FolderUploadUiState(plan = plan, preview = true)
            retained = true
        } catch (cancelled: CancellationException) { throw cancelled
        } catch (_: Exception) { if (isCurrent()) _ui.value = FolderUploadUiState(message = R.string.folder_upload_scan_failed)
        } finally { if (!retained) uriAccess.releaseRead(tree) }
    }

    fun close() {
        val current = _ui.value
        if (current.preview && !current.busy) current.plan?.let { uriAccess.releaseRead(Uri.parse(it.treeUri)) }
        _ui.value = FolderUploadUiState()
        previewRepository = null
        previewIsCurrent = null
    }

    fun invalidatePreview() { if (_ui.value.preview) close() }
    fun isFolder(id: String): Boolean = transfers.hasFolderUploadPlan(id)
    fun show(id: String) {
        val repo = repository() ?: return
        if (!ownership.canUse(WorkspaceRecordKind.UPLOAD, id, repo)) return
        close()
        _ui.value = runCatching { FolderUploadUiState(plan = transfers.folderUploadPlan(id), taskState = transfers.upload(id)?.state) }
            .getOrElse { FolderUploadUiState(message = R.string.folder_upload_scan_failed) }
    }

    fun start(overwrite: Boolean) {
        val current = _ui.value
        val plan = current.plan?.copy(overwrite = overwrite) ?: return
        val repo = previewRepository ?: return
        if (!current.preview || current.busy || previewIsCurrent?.invoke() != true) { invalidatePreview(); return }
        _ui.value = current.copy(busy = true)
        scope.launch {
            try {
                val record = PersistedUpload(plan.taskId, plan.profileId, plan.treeUri, plan.rootName,
                    expectedBytes = plan.totalBytes, destinationPath = plan.destinationPath, sourceTreeUri = plan.treeUri,
                    backupMode = false, mirrorDirectories = true, overwrite = overwrite)
                withContext(Dispatchers.IO) {
                    if (previewIsCurrent?.invoke() != true) throw workspaceChangedFailure()
                    ownership.bind(WorkspaceRecordKind.UPLOAD, record.id, repo)
                    if (!transfers.createFolderUploadDurably(record, plan)) throw IOException("Folder task could not be saved")
                }
                if (_ui.value.plan?.taskId == plan.taskId && _ui.value.preview) {
                    _ui.value = FolderUploadUiState(plan = plan, taskState = TransferState.WAITING)
                    previewRepository = null
                    previewIsCurrent = null
                }
                dispatch(record, repo)
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (_: Exception) {
                _ui.update { if (it.plan?.taskId == plan.taskId) it.copy(busy = false, message = R.string.folder_upload_queue_failed) else it }
            } finally {
                if (_ui.value.plan?.taskId != plan.taskId || !_ui.value.preview) uriAccess.releaseRead(Uri.parse(plan.treeUri))
            }
        }
    }

    fun restore(record: PersistedUpload) {
        if (record.state in setOf(TransferState.PAUSED, TransferState.SUCCEEDED, TransferState.FAILED, TransferState.CANCELLED) ||
            coordinator.foregroundTask(record.id)?.isActive == true) return
        scope.launch {
            val workId = record.workId?.let { runCatching { UUID.fromString(it) }.getOrNull() }
            val info = workId?.let { withContext(Dispatchers.IO) { workManager.getWorkInfoById(it).get() } }
            if (info != null) { observe(record.id, requireNotNull(workId)); return@launch }
            withContext(Dispatchers.IO) {
                if (record.workId != null) runCatching { transfers.updateFolderUploadPlan(record.id, record.workId, FolderUploadPlan::recoveringInterruptedEntries) }
                transfers.updateUpload(record.id) { if (it.workId == record.workId && it.state in setOf(TransferState.WAITING, TransferState.RUNNING, TransferState.CANCELLING))
                    it.copy(state = TransferState.PAUSED) else it }
            }
            onChanged(record.profileId)
        }
    }

    fun retry(id: String) {
        val repo = repository() ?: return
        val record = transfers.upload(id) ?: return
        if (!ownership.canUse(WorkspaceRecordKind.UPLOAD, id, repo)) return
        scope.launch { dispatch(record, repo) }
    }

    private suspend fun dispatch(record: PersistedUpload, repo: DsmRepository) {
        try {
            ownership.require(WorkspaceRecordKind.UPLOAD, record.id, repo)
            val background = profiles.session(record.profileId) != null
            val request = OneTimeWorkRequestBuilder<FolderUploadWorker>()
                .setInputData(workDataOf(PhotoBackupWorker.KEY_TASK_ID to record.id))
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .addTag(PhotoBackupWorker.FILE_UPLOAD_UNIQUE_WORK_PREFIX + record.id).build()
            val execution = request.id.toString()
            val claimed = withContext(Dispatchers.IO) {
                ownership.require(WorkspaceRecordKind.UPLOAD, record.id, repo)
                transfers.beginFolderUploadExecution(record, execution)
            } ?: return
            if (background) {
                withContext(Dispatchers.IO) { workManager.enqueueUniqueWork(PhotoBackupWorker.FILE_UPLOAD_UNIQUE_WORK_PREFIX + record.id,
                    ExistingWorkPolicy.REPLACE, request).result.get() }
                observe(record.id, request.id)
            } else {
                val job = scope.launch(start = CoroutineStart.LAZY) {
                    try {
                        FolderUploadCoordinator(transfers, RepositoryFolderUploadEndpoint(repo, context.contentResolver, ownership, record.id),
                            record.id, execution).run()
                    } catch (cancelled: CancellationException) { throw cancelled
                    } catch (_: Exception) {
                        _ui.update { if (it.plan?.taskId == record.id) it.copy(message = R.string.folder_upload_queue_failed) else it }
                    } finally { onChanged(record.profileId) }
                }
                coordinator.registerForegroundTask(record.id, job,
                    beforeRemoval = { runCatching { finalizeFolderUploadCancellation(transfers, record.id, execution) } },
                    afterRemoval = { onChanged(record.profileId) })
                job.start()
            }
            onChanged(claimed.profileId)
        } catch (cancelled: CancellationException) { throw cancelled
        } catch (failure: Exception) {
            runCatching { transfers.updateUpload(record.id) { if (it.state == TransferState.WAITING) it.copy(state = TransferState.PAUSED,
                errorKind = (failure as? DsmFailure)?.kind?.name ?: DsmErrorKind.LOCAL_STORAGE_FAILED.name) else it } }
            _ui.update { it.copy(busy = false, message = R.string.folder_upload_queue_failed) }
            onChanged(record.profileId)
        }
    }
}

package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.Constraints
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedVirtualMachineImageImport
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedVirtualMachineImageImportStage
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedVirtualMachineImageType
import io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore
import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.data.captureTaskId
import io.github.qwertyuiop1995.dsmnativeclient.data.confirmUploaded
import io.github.qwertyuiop1995.dsmnativeclient.data.markCleanupPending
import io.github.qwertyuiop1995.dsmnativeclient.data.markCreateSubmitting
import io.github.qwertyuiop1995.dsmnativeclient.data.markImageReadback
import io.github.qwertyuiop1995.dsmnativeclient.data.markNeedsReview
import io.github.qwertyuiop1995.dsmnativeclient.data.markReadGrantReleased
import io.github.qwertyuiop1995.dsmnativeclient.data.markSucceeded
import io.github.qwertyuiop1995.dsmnativeclient.data.markTaskClearing
import io.github.qwertyuiop1995.dsmnativeclient.data.markTaskClearSubmitted
import io.github.qwertyuiop1995.dsmnativeclient.data.markTemporaryCleanup
import io.github.qwertyuiop1995.dsmnativeclient.data.markUploadSubmitting
import io.github.qwertyuiop1995.dsmnativeclient.data.toFileItem
import io.github.qwertyuiop1995.dsmnativeclient.data.toPersistedServerFileBaseline
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferDirection
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageType
import java.io.IOException
import java.util.UUID
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException

/** 本地映像上传、公开 VMM 导入和临时文件清理的可恢复后台执行器。 */
class VirtualMachineImageImportWorker(
    appContext: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(appContext, parameters) {
    override suspend fun doWork(): Result {
        val recordId = inputData.getString(KEY_RECORD_ID) ?: return Result.failure()
        val store = TransferStore(applicationContext)
        val initial = store.virtualMachineImageImport(recordId) ?: return Result.failure()
        val executionId = id.toString()
        if (initial.workId != executionId) return Result.success()
        setForeground(
            TransferNotifications.foreground(
                applicationContext,
                recordId,
                id,
                TransferState.RUNNING,
                0,
                initial.expectedBytes,
                TransferDirection.UPLOAD,
                recordKind = io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind.VMM_IMPORT,
            ),
        )
        val repository = try {
            restoreTaskRepository(applicationContext,
                io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind.VMM_IMPORT, recordId, initial.profileId)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val kind = (error as? io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure)?.kind
            if (kind == DsmErrorKind.WORKSPACE_CHANGED || kind == DsmErrorKind.NO_SAVED_SESSION) {
                store.updateVirtualMachineImageImport(recordId) { current ->
                    if (current.workId != executionId) current else current.copy(errorKind = kind.name)
                }
                return Result.failure(errorData(kind))
            }
            return Result.retry()
        }
        val runner = VirtualMachineImageImportRunner(
            store = TransferStoreVmmImportRecords(store),
            operations = RepositoryVmmImageImportOperations(applicationContext, repository, recordId),
        )
        return when (runner.run(recordId, initial.profileId, executionId)) {
            VirtualMachineImageImportRunResult.SUCCEEDED -> Result.success()
            VirtualMachineImageImportRunResult.RETRY -> Result.retry()
            VirtualMachineImageImportRunResult.NEEDS_REVIEW ->
                Result.failure(errorData(DsmErrorKind.CHANGE_NOT_CONFIRMED))
            VirtualMachineImageImportRunResult.STALE -> Result.success()
        }
    }

    companion object {
        const val KEY_RECORD_ID = "record_id"
        const val UNIQUE_WORK_PREFIX = "vmm-local-image-import-"

        /** 首次提交以一个原子存储操作完成同名判重、插入和执行权领取。 */
        fun enqueue(context: Context, record: PersistedVirtualMachineImageImport): UUID? {
            val request = request(record.id)
            val store = TransferStore(context)
            if (!store.insertAndClaimVirtualMachineImageImport(record, request.id.toString())) {
                return null
            }
            try {
                enqueue(context, record.id, request)
            } catch (_: Throwable) {
                store.removeOwnedPreparingVirtualMachineImageImport(record.id, request.id.toString())
                return null
            }
            return request.id
        }

        /** 初次排队只写 record id，并以 KEEP 阻止同一记录产生并行执行。 */
        fun enqueue(context: Context, recordId: String): UUID? {
            val store = TransferStore(context)
            val current = store.virtualMachineImageImport(recordId) ?: return null
            if (current.workId != null) return null
            val request = request(recordId)
            if (!store.claimVirtualMachineImageImportWork(recordId, request.id.toString())) return null
            try {
                enqueue(context, recordId, request)
            } catch (_: Throwable) {
                store.releaseVirtualMachineImageImportWork(recordId, request.id.toString())
                return null
            }
            return request.id
        }

        private fun request(recordId: String) =
            OneTimeWorkRequestBuilder<VirtualMachineImageImportWorker>()
                .setInputData(Data.Builder().putString(KEY_RECORD_ID, recordId).build())
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build(),
                )
                .build()

        private fun enqueue(
            context: Context,
            recordId: String,
            request: androidx.work.OneTimeWorkRequest,
        ) {
            WorkManager.getInstance(context).enqueueUniqueWork(
                stableVirtualMachineImageImportWorkName(recordId),
                ExistingWorkPolicy.KEEP,
                request,
            )
        }

        private fun errorData(kind: DsmErrorKind) = Data.Builder()
            .putString("error_kind", kind.name)
            .build()
    }
}

internal enum class VirtualMachineImageImportRunResult { SUCCEEDED, RETRY, NEEDS_REVIEW, STALE }

internal interface VirtualMachineImageImportRecordStore {
    fun get(id: String): PersistedVirtualMachineImageImport?
    fun updateOwned(
        id: String,
        profileId: String,
        workId: String,
        transform: (PersistedVirtualMachineImageImport) -> PersistedVirtualMachineImageImport,
    ): PersistedVirtualMachineImageImport?
}

private class TransferStoreVmmImportRecords(
    private val store: TransferStore,
) : VirtualMachineImageImportRecordStore {
    override fun get(id: String) = store.virtualMachineImageImport(id)

    override fun updateOwned(
        id: String,
        profileId: String,
        workId: String,
        transform: (PersistedVirtualMachineImageImport) -> PersistedVirtualMachineImageImport,
    ): PersistedVirtualMachineImageImport? = store.updateVirtualMachineImageImport(id) {
        if (it.profileId == profileId && it.workId == workId) transform(it) else it
    }?.takeIf { it.profileId == profileId && it.workId == workId }
}

internal interface VirtualMachineImageImportOperations {
    suspend fun file(path: String): FileItem?
    suspend fun upload(record: PersistedVirtualMachineImageImport): Boolean
    suspend fun startCreate(record: PersistedVirtualMachineImageImport): String
    suspend fun task(taskId: String): DsmRepository.VirtualMachineImageTaskReadback
    suspend fun imageMatches(
        record: PersistedVirtualMachineImageImport,
    ): DsmRepository.VirtualMachineImageMatch
    suspend fun clearTask(taskId: String)
    suspend fun taskExists(taskId: String): Boolean
    suspend fun deleteTemporary(baseline: FileItem): Boolean
    fun releaseReadGrant(sourceUri: String): Boolean
}

internal class VirtualMachineImageImportRunner(
    private val store: VirtualMachineImageImportRecordStore,
    private val operations: VirtualMachineImageImportOperations,
) {
    suspend fun run(
        recordId: String,
        profileId: String,
        workId: String,
    ): VirtualMachineImageImportRunResult {
        var record = store.get(recordId)?.takeIf {
            it.profileId == profileId && it.workId == workId
        } ?: return VirtualMachineImageImportRunResult.STALE
        try {
            if (record.stage == PersistedVirtualMachineImageImportStage.PREPARING) {
                record = update(record) { checkNotNull(it.markUploadSubmitting()) }
                    ?: return VirtualMachineImageImportRunResult.STALE
            }
            if (record.stage == PersistedVirtualMachineImageImportStage.UPLOAD_SUBMITTING) {
                val existing = try {
                    operations.file(record.temporaryFilePath)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Throwable) {
                    return VirtualMachineImageImportRunResult.RETRY
                }
                when {
                    existing == null -> {
                        if (!operations.upload(record)) return needsReview(record, "upload-unverified")
                        val uploaded = try {
                            operations.file(record.temporaryFilePath)
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (_: Throwable) {
                            return VirtualMachineImageImportRunResult.RETRY
                        } ?: return needsReview(record, "upload-missing")
                        record = confirmUpload(record, uploaded)
                            ?: return needsReview(record, "upload-readback-differs")
                    }
                    uploadMatches(record, existing) -> {
                        record = confirmUpload(record, existing)
                            ?: return VirtualMachineImageImportRunResult.STALE
                    }
                    else -> return needsReview(record, "upload-conflict")
                }
            }
            if (record.ownsPersistedReadGrant && record.stage !in setOf(
                    PersistedVirtualMachineImageImportStage.PREPARING,
                    PersistedVirtualMachineImageImportStage.UPLOAD_SUBMITTING,
                )
            ) {
                if (!operations.releaseReadGrant(record.sourceUri)) {
                    return needsReview(record, "source-grant-release-failed")
                }
                record = update(record) { it.markReadGrantReleased() }
                    ?: return VirtualMachineImageImportRunResult.STALE
            }
            if (record.stage == PersistedVirtualMachineImageImportStage.UPLOADED) {
                record = update(record) { checkNotNull(it.markCreateSubmitting()) }
                    ?: return VirtualMachineImageImportRunResult.STALE
                val taskId = operations.startCreate(record)
                record = update(record) { checkNotNull(it.captureTaskId(taskId)) }
                    ?: return VirtualMachineImageImportRunResult.STALE
            } else if (
                record.stage == PersistedVirtualMachineImageImportStage.CREATE_SUBMITTING &&
                record.taskId == null
            ) {
                return needsReview(record, "create-submission-unverified")
            }
            if (record.stage == PersistedVirtualMachineImageImportStage.TASK_TRACKING) {
                val task = try {
                    operations.task(checkNotNull(record.taskId))
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Throwable) {
                    return VirtualMachineImageImportRunResult.RETRY
                }
                if (!task.finished) return VirtualMachineImageImportRunResult.RETRY
                val imageId = task.imageId ?: return needsReview(record, "task-finished-without-image")
                record = update(record) { checkNotNull(it.markImageReadback(imageId)) }
                    ?: return VirtualMachineImageImportRunResult.STALE
            }
            if (record.stage == PersistedVirtualMachineImageImportStage.IMAGE_READBACK) {
                val imageMatch = try {
                    operations.imageMatches(record)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Throwable) {
                    return VirtualMachineImageImportRunResult.RETRY
                }
                when (imageMatch) {
                    DsmRepository.VirtualMachineImageMatch.MATCH -> Unit
                    DsmRepository.VirtualMachineImageMatch.MISSING ->
                        return VirtualMachineImageImportRunResult.RETRY
                    DsmRepository.VirtualMachineImageMatch.DIFFERS ->
                        return needsReview(record, "image-readback-differs")
                }
                record = update(record) { checkNotNull(it.markTaskClearing()) }
                    ?: return VirtualMachineImageImportRunResult.STALE
                record = update(record) { checkNotNull(it.markTaskClearSubmitted()) }
                    ?: return VirtualMachineImageImportRunResult.STALE
                val taskId = checkNotNull(record.taskId)
                try {
                    operations.clearTask(taskId)
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    return if (!operations.taskExists(taskId)) {
                        record = update(record) { checkNotNull(it.markTemporaryCleanup()) }
                            ?: return VirtualMachineImageImportRunResult.STALE
                        cleanup(record)
                    } else {
                        needsReview(record, failureKind(error))
                    }
                }
                record = update(record) { checkNotNull(it.markTemporaryCleanup()) }
                    ?: return VirtualMachineImageImportRunResult.STALE
            }
            if (record.stage == PersistedVirtualMachineImageImportStage.TASK_CLEARING) {
                val taskId = checkNotNull(record.taskId)
                if (record.taskClearSubmitted) {
                    val taskExists = try {
                        operations.taskExists(taskId)
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Throwable) {
                        return VirtualMachineImageImportRunResult.RETRY
                    }
                    if (taskExists) return VirtualMachineImageImportRunResult.RETRY
                    record = update(record) { checkNotNull(it.markTemporaryCleanup()) }
                        ?: return VirtualMachineImageImportRunResult.STALE
                } else {
                    record = update(record) { checkNotNull(it.markTaskClearSubmitted()) }
                        ?: return VirtualMachineImageImportRunResult.STALE
                    operations.clearTask(taskId)
                    record = update(record) { checkNotNull(it.markTemporaryCleanup()) }
                        ?: return VirtualMachineImageImportRunResult.STALE
                }
            }
            if (record.stage in setOf(
                    PersistedVirtualMachineImageImportStage.TEMP_CLEANUP,
                    PersistedVirtualMachineImageImportStage.CLEANUP_PENDING,
                )
            ) {
                return cleanup(record)
            }
            return when (record.stage) {
                PersistedVirtualMachineImageImportStage.SUCCEEDED ->
                    VirtualMachineImageImportRunResult.SUCCEEDED
                PersistedVirtualMachineImageImportStage.NEEDS_REVIEW,
                PersistedVirtualMachineImageImportStage.FAILED,
                PersistedVirtualMachineImageImportStage.CANCELLED,
                -> VirtualMachineImageImportRunResult.NEEDS_REVIEW
                else -> VirtualMachineImageImportRunResult.RETRY
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            return if (record.stage in setOf(
                    PersistedVirtualMachineImageImportStage.TEMP_CLEANUP,
                    PersistedVirtualMachineImageImportStage.CLEANUP_PENDING,
                )
            ) cleanupPending(record, failureKind(error))
            else if (record.stage in setOf(
                    PersistedVirtualMachineImageImportStage.TASK_TRACKING,
                    PersistedVirtualMachineImageImportStage.IMAGE_READBACK,
                ) || (
                    record.stage == PersistedVirtualMachineImageImportStage.TASK_CLEARING &&
                        record.taskClearSubmitted
                    )
            ) VirtualMachineImageImportRunResult.RETRY
            else needsReview(record, failureKind(error))
        }
    }

    private fun uploadMatches(record: PersistedVirtualMachineImageImport, file: FileItem): Boolean =
        !file.isDirectory && file.path == record.temporaryFilePath &&
            file.name == record.temporaryFileName && file.size == record.expectedBytes

    private suspend fun cleanup(record: PersistedVirtualMachineImageImport): VirtualMachineImageImportRunResult {
        val baseline = record.temporaryFileBaseline
            ?: return needsReview(record, "cleanup-baseline-missing")
        val observed = operations.file(record.temporaryFilePath)
        if (observed == null) return succeed(record)
        if (observed.toPersistedServerFileBaseline() != baseline) {
            return cleanupPending(record, "cleanup-baseline-differs")
        }
        if (!operations.deleteTemporary(baseline.toFileItem()) ||
            operations.file(record.temporaryFilePath) != null
        ) return cleanupPending(record, "cleanup-unverified")
        return succeed(record)
    }

    private fun confirmUpload(
        record: PersistedVirtualMachineImageImport,
        file: FileItem,
    ) = update(record) { checkNotNull(it.confirmUploaded(file.toPersistedServerFileBaseline())) }

    private fun update(
        record: PersistedVirtualMachineImageImport,
        transform: (PersistedVirtualMachineImageImport) -> PersistedVirtualMachineImageImport,
    ) = store.updateOwned(record.id, record.profileId, checkNotNull(record.workId), transform)

    private fun needsReview(record: PersistedVirtualMachineImageImport, kind: String) =
        update(record) { it.markNeedsReview(kind) }
            ?.let { VirtualMachineImageImportRunResult.NEEDS_REVIEW }
            ?: VirtualMachineImageImportRunResult.STALE

    private fun cleanupPending(record: PersistedVirtualMachineImageImport, kind: String) =
        update(record) { checkNotNull(it.markCleanupPending(kind)) }
            ?.let { VirtualMachineImageImportRunResult.NEEDS_REVIEW }
            ?: VirtualMachineImageImportRunResult.STALE

    private fun succeed(record: PersistedVirtualMachineImageImport) =
        update(record) { checkNotNull(it.markSucceeded()) }
            ?.let { VirtualMachineImageImportRunResult.SUCCEEDED }
            ?: VirtualMachineImageImportRunResult.STALE

    private fun failureKind(error: Throwable): String =
        (error as? DsmFailure)?.kind?.name ?: DsmErrorKind.UNKNOWN.name
}

private class RepositoryVmmImageImportOperations(
    private val context: Context,
    private val repository: DsmRepository,
    private val recordId: String,
) : VirtualMachineImageImportOperations {
    override suspend fun file(path: String) = repository.fileInfo(path)

    override suspend fun upload(record: PersistedVirtualMachineImageImport): Boolean {
        val uri = Uri.parse(record.sourceUri)
        val result = repository.uploadResult(
            UploadSource(
                displayName = record.temporaryFileName,
                contentType = record.sourceContentType,
                contentLength = record.expectedBytes,
                openInputStream = {
                    context.contentResolver.openInputStream(uri)
                        ?: throw IOException("The selected image is no longer available")
                },
            ),
            record.stagingDirectoryPath,
            overwrite = false,
        )
        return result.status == MutationResultStatus.CONFIRMED_SUCCESS
    }

    override suspend fun startCreate(record: PersistedVirtualMachineImageImport): String =
        repository.startVirtualMachineImageImportTask(
            source = checkNotNull(record.temporaryFileBaseline).toFileItem(),
            imageName = record.imageName,
            imageType = record.imageType.toDomain(),
            storageId = record.storageId,
            storageName = record.storageName,
            storageStatus = record.storageStatus,
        )

    override suspend fun task(taskId: String) = repository.readVirtualMachineImageImportTask(taskId)

    override suspend fun imageMatches(record: PersistedVirtualMachineImageImport) =
        repository.virtualMachineImageMatches(
            checkNotNull(record.imageId),
            record.imageName,
            record.imageType.toDomain(),
        )

    override suspend fun clearTask(taskId: String) =
        repository.clearVirtualMachineImageImportTask(taskId)

    override suspend fun taskExists(taskId: String) = repository.virtualMachineTaskExists(taskId)

    override suspend fun deleteTemporary(baseline: FileItem): Boolean =
        repository.deleteResult(baseline).status == MutationResultStatus.CONFIRMED_SUCCESS

    override fun releaseReadGrant(sourceUri: String): Boolean =
        TransferUriAccess(context, TransferStore(context)).releaseRead(Uri.parse(sourceUri), recordId)

    private fun PersistedVirtualMachineImageType.toDomain() = when (this) {
        PersistedVirtualMachineImageType.DISK -> VirtualMachineImageType.DISK
        PersistedVirtualMachineImageType.VDSM -> VirtualMachineImageType.VDSM
        PersistedVirtualMachineImageType.ISO -> VirtualMachineImageType.ISO
    }
}

internal fun stableVirtualMachineImageImportWorkName(recordId: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(
        recordId.toByteArray(Charsets.UTF_8),
    ).joinToString("") { byte -> (byte.toInt() and 0xff).toString(16).padStart(2, '0') }
    return VirtualMachineImageImportWorker.UNIQUE_WORK_PREFIX + digest
}

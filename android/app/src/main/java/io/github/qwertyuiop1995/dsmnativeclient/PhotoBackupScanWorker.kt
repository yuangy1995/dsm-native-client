package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import android.net.Uri
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ListenableWorker
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedPhotoBackupSource
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedUpload
import io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore
import io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind
import java.util.UUID

/** 扫描用户授权的目录；只登记媒体任务，不读取或记录媒体正文。 */
class PhotoBackupScanWorker(
    appContext: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(appContext, parameters) {
    private val transfers = TransferStore(appContext)

    override suspend fun doWork(): Result {
        val profileId = inputData.getString(KEY_PROFILE_ID) ?: return Result.failure()
        val source = transfers.photoBackupSource(profileId)?.takeIf(::shouldScanPhotoBackupSource)
            ?: return Result.success()
        val sourceId = inputData.getString(KEY_SOURCE_ID) ?: return Result.failure()
        if (source.sourceId != sourceId) return Result.success()
        val secureStore = SecureProfileStore(applicationContext)
        val owner = runCatching { secureStore.savedConnectionForRecord(WorkspaceRecordKind.PHOTO_SOURCE, sourceId) }
            .getOrNull()?.owner?.takeIf { it.profileId == profileId } ?: return Result.failure()
        val treeUri = Uri.parse(source.treeUri)
        val scan = suspendRunCatching {
            scanDocumentTree(applicationContext, treeUri, MAX_DOCUMENTS_PER_SCAN) { mime ->
                mime.startsWith("image/") || mime.startsWith("video/")
            }
        }.getOrElse { return Result.failure() }
        val plan = photoBackupScanPlan(scan)
        if (plan.needsAttention) {
            val current = transfers.photoBackupSource(profileId)
            if (current?.sourceId == sourceId && current.treeUri == source.treeUri && current.destinationPath == source.destinationPath) {
                if (
                    runCatching {
                        transfers.upsertPhotoBackupSource(
                            current.copy(
                                enabled = false,
                                needsAttention = true,
                                workId = null,
                            ),
                        )
                    }.isFailure
                ) {
                    return photoBackupScanFailure(SCAN_OUTCOME_SOURCE_STATE_NOT_PERSISTED)
                }
                WorkManager.getInstance(applicationContext).cancelUniqueWork(
                    UNIQUE_WORK_PREFIX + profileId,
                )
            }
            return photoBackupScanFailure(if (scan.truncated) SCAN_OUTCOME_TOO_MANY_DOCUMENTS else SCAN_OUTCOME_SOURCE_UNAVAILABLE)
        }
        val items = plan.files
        val existing = transfers.uploads(profileId)
        val workManager = WorkManager.getInstance(applicationContext)
        items.forEach { item ->
            val destination = backupDestination(source.destinationPath, item.relativeFolder)
            val duplicate = existing.any {
                it.sourceUri == item.uri.toString() &&
                    it.destinationPath == destination &&
                    it.title == item.name &&
                    it.expectedBytes == item.size
            }
            if (duplicate) return@forEach
            val record = PersistedUpload(
                id = UUID.randomUUID().toString(),
                profileId = profileId,
                sourceUri = item.uri.toString(),
                title = item.name,
                contentType = item.mimeType,
                expectedBytes = item.size,
                destinationPath = destination,
                destinationRootPath = source.destinationPath,
                ownsPersistedReadGrant = false,
                sourceTreeUri = source.treeUri,
            )
            if (transfers.photoBackupSource(profileId)?.sourceId != sourceId ||
                runCatching { secureStore.bindRecord(WorkspaceRecordKind.UPLOAD, record.id, owner) }.isFailure) return Result.failure()
            transfers.upsert(record)
            val request = OneTimeWorkRequestBuilder<PhotoBackupWorker>()
                .setInputData(workDataOf(PhotoBackupWorker.KEY_TASK_ID to record.id))
                .setConstraints(photoBackupConstraints())
                .addTag(PhotoBackupWorker.UNIQUE_WORK_PREFIX + record.id)
                .build()
            transfers.updateUpload(record.id) { it.copy(workId = request.id.toString()) }
            workManager.enqueueUniqueWork(
                PhotoBackupWorker.UNIQUE_WORK_PREFIX + record.id,
                ExistingWorkPolicy.KEEP,
                request,
            )
        }
        return Result.success()
    }

    companion object {
        const val KEY_PROFILE_ID = "profile_id"
        const val KEY_SOURCE_ID = "source_id"
        const val KEY_SCAN_OUTCOME = "scan_outcome"
        const val UNIQUE_WORK_PREFIX = "photo-backup-scan-"
        const val MAX_DOCUMENTS_PER_SCAN = 10_000
        const val SCAN_OUTCOME_TOO_MANY_DOCUMENTS = "too_many_documents"
        const val SCAN_OUTCOME_SOURCE_UNAVAILABLE = "source_unavailable"
        const val SCAN_OUTCOME_SOURCE_STATE_NOT_PERSISTED = "source_state_not_persisted"
    }
}

internal fun isSafeBackupName(value: String): Boolean =
    value.isNotBlank() && '/' !in value && '\\' !in value && value !in setOf(".", "..")

internal fun backupDestination(root: String, relativeFolder: String): String =
    if (relativeFolder.isBlank()) root else root.trimEnd('/') + "/" + relativeFolder

/** 截断目录从不部分入队，避免用户误以为整个目录已经完成自动备份。 */
internal data class PhotoBackupScanPlan(
    val files: List<BackupDocument>,
    val needsAttention: Boolean,
)

internal fun photoBackupScanPlan(scan: DocumentTreeScan): PhotoBackupScanPlan =
    if (scan.truncated || scan.unavailable.isNotEmpty()) {
        PhotoBackupScanPlan(files = emptyList(), needsAttention = true)
    } else {
        PhotoBackupScanPlan(files = scan.files, needsAttention = false)
    }

internal fun shouldScanPhotoBackupSource(source: PersistedPhotoBackupSource): Boolean =
    source.enabled && !source.needsAttention

internal fun photoBackupScanFailure(reason: String): ListenableWorker.Result =
    ListenableWorker.Result.failure(
        workDataOf(PhotoBackupScanWorker.KEY_SCAN_OUTCOME to reason),
    )

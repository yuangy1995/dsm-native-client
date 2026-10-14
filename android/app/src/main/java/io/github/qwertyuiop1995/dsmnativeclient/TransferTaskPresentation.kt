package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize

/** 当前工作区与全局任务中心共用同一持久任务展示，状态和结果不会因入口改变。 */
internal class TransferTaskPresentation(private val application: Context) {
    fun imageImport(value: PersistedVirtualMachineImageImport): TransferTask = TransferTask(
        id = value.id, title = value.imageName,
        detail = application.getString(value.stage.importStageLabelResource()), direction = TransferDirection.SERVER,
        state = when (value.stage) {
            PersistedVirtualMachineImageImportStage.SUCCEEDED -> TransferState.SUCCEEDED
            PersistedVirtualMachineImageImportStage.FAILED -> TransferState.FAILED
            PersistedVirtualMachineImageImportStage.CANCELLED -> TransferState.CANCELLED
            PersistedVirtualMachineImageImportStage.NEEDS_REVIEW, PersistedVirtualMachineImageImportStage.CLEANUP_PENDING -> TransferState.PAUSED
            else -> TransferState.RUNNING
        }, requiresRefresh = value.requiresRefresh, canCancel = false,
    )

    fun server(server: PersistedServerTransfer): TransferTask? {
        val target = server.toFileServerMutationTarget() ?: return null
        val operationName = when (target.operation) {
            FileServerMutationOperation.COMPRESS -> "archiveCompress"
            FileServerMutationOperation.EXTRACT -> "archiveExtract"
        }
        val result = server.mutationResult?.toMutationResult(operationName)
        val failure = server.errorKind?.let { value ->
            val kind = runCatching { DsmErrorKind.valueOf(value) }.getOrDefault(DsmErrorKind.UNKNOWN)
            DsmFailure(null, "", "", kind = kind)
        }
        val refreshFailure = server.refreshFailureKind?.let { value ->
            val kind = runCatching { DsmErrorKind.valueOf(value) }.getOrDefault(DsmErrorKind.UNKNOWN)
            DsmFailure(null, "", "", kind = kind)
        }
        val detail = when (server.state) {
            TransferState.WAITING, TransferState.RUNNING -> application.getString(
                if (target.operation == FileServerMutationOperation.COMPRESS) {
                    R.string.archive_creating
                } else {
                    R.string.archive_extracting
                },
            )
            TransferState.CANCELLING -> application.getString(R.string.transfer_cancelling)
            TransferState.SUCCEEDED,
            TransferState.FAILED,
            TransferState.CANCELLED,
            -> result?.let { application.getString(archiveMutationMessageResource(it)) }
                ?: application.getString(
                    if (server.requiresRefresh) R.string.transfer_refresh_before_retry
                    else R.string.transfer_failed,
                )
            TransferState.PAUSED -> application.getString(R.string.transfer_paused)
        }
        return TransferTask(
            id = server.id,
            title = server.title,
            detail = detail,
            direction = TransferDirection.SERVER,
            state = server.state,
            completedBytes = server.completedUnits,
            totalBytes = server.totalUnits,
            errorMessage = failure?.localize(application)?.combined,
            requiresRefresh = server.requiresRefresh,
            startedAtEpochMillis = server.startedAtEpochMillis,
            fileServerMutation = FileServerMutationLifecycle(
                target = target,
                result = result,
                failure = failure,
                refreshCompleted = server.refreshCompleted,
                refreshFailure = refreshFailure,
                verification = server.toFileServerMutationVerification(),
                generation = server.executionGeneration,
            ),
            canCancel = !server.readOnlyObservation,
        )
    }

    fun upload(upload: PersistedUpload): TransferTask {
        val uploadMutation = UploadMutationLifecycle(
            directoryResult = upload.directoryMutationResult?.toMutationResult("backupFolderEnsure"),
            uploadResult = upload.uploadMutationResult?.toMutationResult("fileUpload"),
        ).takeIf { it.directoryResult != null || it.uploadResult != null }
        val hasTerminalMutationFeedback = upload.uploadMutationResult != null ||
            upload.directoryMutationResult?.status?.let {
                it != MutationResultStatus.CONFIRMED_SUCCESS
            } == true
        val detail = when (upload.state) {
            TransferState.WAITING -> application.getString(
                if (upload.backupMode) R.string.transfer_waiting_to_backup else R.string.transfer_waiting,
            )
            TransferState.RUNNING -> application.getString(
                if (upload.backupMode) R.string.transfer_backing_up else R.string.transfer_uploading,
            )
            TransferState.CANCELLING -> application.getString(R.string.transfer_cancelling)
            TransferState.SUCCEEDED -> application.getString(
                if (upload.skippedExisting) R.string.transfer_backup_already_exists
                else R.string.transfer_completed,
            )
            TransferState.FAILED -> application.getString(
                if (upload.backupMode) R.string.transfer_backup_failed else R.string.transfer_failed,
            )
            TransferState.CANCELLED -> application.getString(
                if (upload.requiresRefresh) R.string.transfer_cancelled_refresh
                else R.string.transfer_cancelled,
            )
            TransferState.PAUSED -> application.getString(R.string.transfer_paused)
        }
        val errorMessage = if (upload.errorKind == DsmErrorKind.WORKSPACE_CHANGED.name) {
            io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceChangedFailure().localize(application).combined
        } else if (hasTerminalMutationFeedback) {
            null
        } else if (upload.requiresRefresh && upload.state == TransferState.FAILED) {
            application.getString(R.string.upload_unverified)
        } else upload.errorKind?.let { name ->
            val kind = runCatching { DsmErrorKind.valueOf(name) }.getOrDefault(DsmErrorKind.UPLOAD_FAILED)
            DsmFailure(null, "", "", kind = kind).localize(application).combined
        }
        return TransferTask(
            id = upload.id,
            title = upload.title,
            detail = detail,
            direction = TransferDirection.UPLOAD,
            state = upload.state,
            completedBytes = upload.completedBytes,
            totalBytes = upload.expectedBytes,
            errorMessage = errorMessage,
            requiresRefresh = upload.requiresRefresh,
            // 目录进度包含已按用户选择跳过的内容，不能据此推算网络速度。
            startedAtEpochMillis = upload.startedAtEpochMillis.takeUnless {
                upload.mirrorDirectories && !upload.backupMode && upload.sourceUri == upload.sourceTreeUri
            },
            uploadMutation = uploadMutation,
        )
    }

    fun download(download: PersistedDownload): TransferTask {
        val detail = when (download.state) {
            TransferState.WAITING -> application.getString(R.string.transfer_waiting_to_download)
            TransferState.RUNNING -> application.getString(
                if (download.backgroundCapable) {
                    R.string.transfer_downloading
                } else {
                    R.string.transfer_downloading_keep_open
                },
            )
            TransferState.CANCELLING -> application.getString(R.string.transfer_cancelling)
            TransferState.SUCCEEDED -> application.getString(R.string.transfer_completed)
            TransferState.FAILED -> application.getString(R.string.transfer_download_failed)
            TransferState.CANCELLED -> application.getString(R.string.transfer_download_cancelled)
            TransferState.PAUSED -> application.getString(R.string.transfer_download_paused)
        }
        val errorMessage = download.errorKind?.let { name ->
            val kind = runCatching { DsmErrorKind.valueOf(name) }.getOrDefault(DsmErrorKind.DOWNLOAD_FAILED)
            DsmFailure(null, "", "", kind = kind).localize(application).combined
        }
        return TransferTask(
            id = download.id,
            title = download.title,
            detail = detail,
            direction = TransferDirection.DOWNLOAD,
            state = download.state,
            completedBytes = download.completedBytes,
            totalBytes = download.totalBytes,
            errorMessage = errorMessage,
            startedAtEpochMillis = download.startedAtEpochMillis,
        )
    }

}

internal fun PersistedVirtualMachineImageImportStage.importStageLabelResource(): Int = when (this) {
    PersistedVirtualMachineImageImportStage.PREPARING ->
        R.string.virtual_machine_local_image_import_stage_preparing
    PersistedVirtualMachineImageImportStage.UPLOAD_SUBMITTING ->
        R.string.virtual_machine_local_image_import_stage_uploading
    PersistedVirtualMachineImageImportStage.UPLOADED,
    PersistedVirtualMachineImageImportStage.CREATE_SUBMITTING,
    PersistedVirtualMachineImageImportStage.TASK_TRACKING,
    PersistedVirtualMachineImageImportStage.IMAGE_READBACK,
    PersistedVirtualMachineImageImportStage.TASK_CLEARING,
    -> R.string.virtual_machine_local_image_import_stage_creating
    PersistedVirtualMachineImageImportStage.TEMP_CLEANUP,
    PersistedVirtualMachineImageImportStage.CLEANUP_PENDING,
    -> R.string.virtual_machine_local_image_import_stage_cleaning
    PersistedVirtualMachineImageImportStage.SUCCEEDED ->
        R.string.virtual_machine_local_image_import_stage_succeeded
    PersistedVirtualMachineImageImportStage.NEEDS_REVIEW,
    PersistedVirtualMachineImageImportStage.FAILED,
    PersistedVirtualMachineImageImportStage.CANCELLED,
    -> R.string.virtual_machine_local_image_import_stage_failed
}

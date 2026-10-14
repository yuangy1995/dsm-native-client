package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceChangedFailure
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal enum class RetryUploadDecision(val message: Int) {
    ALREADY_COMPLETE(R.string.upload_retry_already_complete),
    CONFLICT(R.string.upload_retry_conflict),
    REQUEUE(R.string.upload_retry_queued),
    UNRESOLVED(R.string.upload_retry_unresolved),
    SOURCE_CHANGED(R.string.upload_retry_source_changed),
    SAVED_SESSION_REQUIRED(R.string.upload_retry_requires_login),
}

internal fun retryUploadDecision(existing: FileItem?, contentMatches: Boolean?, unresolved: Boolean): RetryUploadDecision = when {
    existing != null && !existing.isDirectory && contentMatches == true -> RetryUploadDecision.ALREADY_COMPLETE
    unresolved && contentMatches == null && existing?.isDirectory != true -> RetryUploadDecision.UNRESOLVED
    existing != null -> RetryUploadDecision.CONFLICT
    unresolved -> RetryUploadDecision.UNRESOLVED
    else -> RetryUploadDecision.REQUEUE
}

internal fun confirmedUploadReadbackResult(): MutationResult = MutationResult(
    schemaVersion = 1, status = MutationResultStatus.CONFIRMED_SUCCESS, operation = "fileUpload",
    submitted = true, requiresRefresh = false, counts = MutationResultCounts(1, 0, 0),
    diagnosticTag = "file-station.upload.confirmed-by-explicit-retry-content",
)

/** 结果不明只读恢复；重排只允许明确未成功且目标不存在的上传，并取消旧覆盖授权。 */
internal suspend fun retryStoredUpload(
    repo: DsmRepository, upload: PersistedUpload, transfers: TransferStore, store: SecureProfileStore,
    source: UploadSource,
): Pair<RetryUploadDecision, PersistedUpload> = withContext(Dispatchers.IO) {
    val ownership = WorkspaceTaskOwnership(store)
    ownership.require(WorkspaceRecordKind.UPLOAD, upload.id, repo)
    val target = upload.destinationPath.trimEnd('/') + "/" + upload.title
    val existing = if (repo.itemExists(target)) repo.fileInfo(target) else null
    val proof = transfers.uploadContent(upload)
    val unresolved = upload.requiresRefresh || upload.uploadMutationResult?.requiresRefresh == true
    val contentMatches = if (existing != null && proof != null) repo.matchesUploadContent(existing, proof) else null
    var decision = retryUploadDecision(existing, contentMatches, unresolved)
    if (decision == RetryUploadDecision.REQUEUE && proof != null && source.contentFingerprint() != proof) {
        decision = RetryUploadDecision.SOURCE_CHANGED
    }
    if (decision == RetryUploadDecision.REQUEUE && store.session(upload.profileId) == null) {
        decision = RetryUploadDecision.SAVED_SESSION_REQUIRED
    }
    ownership.require(WorkspaceRecordKind.UPLOAD, upload.id, repo)
    val next = when (decision) {
        RetryUploadDecision.ALREADY_COMPLETE -> upload.copy(
            state = TransferState.SUCCEEDED, completedBytes = upload.expectedBytes, errorKind = null,
            requiresRefresh = false, uploadMutationResult = confirmedUploadReadbackResult().toPersistedMutationResult(false),
        )
        RetryUploadDecision.CONFLICT -> if (unresolved) upload else upload.copy(
            state = TransferState.FAILED, errorKind = DsmErrorKind.UPLOAD_FAILED.name,
            uploadMutationResult = uploadTargetConflictResult().toPersistedMutationResult(false),
        )
        RetryUploadDecision.REQUEUE -> upload.copy(
            state = TransferState.WAITING, completedBytes = 0, errorKind = null, workId = null,
            overwrite = false, requiresRefresh = false, directoryMutationResult = null, uploadMutationResult = null,
        )
        RetryUploadDecision.UNRESOLVED, RetryUploadDecision.SOURCE_CHANGED, RetryUploadDecision.SAVED_SESSION_REQUIRED -> upload
    }
    var applied = false
    transfers.updateUpload(upload.id) { current ->
        ownership.require(WorkspaceRecordKind.UPLOAD, upload.id, repo)
        if (current == upload) { applied = true; next } else current
    }
    if (!applied) throw workspaceChangedFailure()
    decision to next
}

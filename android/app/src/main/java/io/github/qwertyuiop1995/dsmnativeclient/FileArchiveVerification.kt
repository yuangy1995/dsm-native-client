package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*

internal fun FileServerMutationTarget.overlapsArchiveTarget(other: FileServerMutationTarget): Boolean {
    if (profileId != other.profileId) return false
    fun FileServerMutationTarget.paths() = sourceBaselines.map(FileItem::path) +
        if (operation == FileServerMutationOperation.COMPRESS) expectedOutputs.map { it.path } else listOf(destinationFolderBaseline.path)
    return paths().any { left -> other.paths().any { right -> left == right || left.startsWith(right + "/") || right.startsWith(left + "/") } }
}

internal suspend fun verifyFileServerMutation(repo: DsmRepository, target: FileServerMutationTarget,
                                              record: PersistedServerTransfer?, store: TransferStore): FileServerMutationVerification {
    if (record?.isPlannedExtraction == true) {
        val outputs = store.extractionOutputs(record)
        val taskId = record.nasTaskId
        if (taskId == null || !repo.verifyExtractionCompletion(taskId, outputs)) {
            throw DsmFailure(null, "Archive task has not completed", "Open the destination folder or refresh later.", kind = DsmErrorKind.CHANGE_NOT_CONFIRMED)
        }
        return FileServerMutationVerification.MATCHES
    }
    val destination = repo.fileInfo(target.destinationFolderBaseline.path) ?: return FileServerMutationVerification.DISAPPEARED
    if (!destination.isDirectory) return FileServerMutationVerification.DIFFERS
    if (target.expectedOutputs.isEmpty()) return FileServerMutationVerification.UNAVAILABLE
    return if (target.expectedOutputs.all { expected ->
        repo.fileInfo(expected.path)?.let { actual -> actual.path == expected.path && actual.isDirectory == expected.isDirectory &&
            (!expected.requiresNonEmptyFile || actual.size > 0) } == true
    }) FileServerMutationVerification.MATCHES else FileServerMutationVerification.DIFFERS
}

internal fun hasBlockingFileServerTransfer(transfers: List<TransferTask>): Boolean =
    transfers.any { transfer ->
        transfer.direction == TransferDirection.SERVER && (
            transfer.state !in TERMINAL_TRANSFER_STATES ||
                fileServerMutationBlocksWorkspaceExit(transfer.fileServerMutation)
            )
    }

internal fun fileServerMutationBlocksWorkspaceExit(
    lifecycle: FileServerMutationLifecycle?,
): Boolean = lifecycle?.let {
    it.refreshInProgress || it.refreshFailure != null ||
        (it.failure != null && it.result?.submitted != false && (!it.refreshCompleted ||
            it.verification == FileServerMutationVerification.UNAVAILABLE)) ||
        (it.result?.requiresRefresh == true && (!it.refreshCompleted ||
            it.verification == FileServerMutationVerification.UNAVAILABLE))
} == true

internal fun fileServerMutationCanBeExplicitlyCleared(
    lifecycle: FileServerMutationLifecycle?,
): Boolean = lifecycle?.let {
    it.refreshCompleted && !it.refreshInProgress && it.refreshFailure == null
} == true

internal fun cancelledFileServerMutationResult(
    operation: FileServerMutationOperation,
): MutationResult = MutationResult(
    schemaVersion = 1,
    status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    operation = when (operation) {
        FileServerMutationOperation.COMPRESS -> "archiveCompress"
        FileServerMutationOperation.EXTRACT -> "archiveExtract"
    },
    submitted = true,
    requiresRefresh = true,
    counts = MutationResultCounts(succeeded = 0, failed = 0, unknown = 1),
)

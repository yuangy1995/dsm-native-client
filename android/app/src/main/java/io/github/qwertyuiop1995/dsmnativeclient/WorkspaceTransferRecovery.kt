package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.storage.*

/** 保留原任务的阶段、回执和本地 URI；无法证明归属时只暂停，不重放也不清理远端。 */
internal fun pauseUnownedTransfers(store: SecureProfileStore, transfers: TransferStore, owner: WorkspaceOwner) {
    fun owned(kind: WorkspaceRecordKind, id: String) =
        runCatching { store.recordOwner(kind, id)?.hasSameIdentity(owner) == true }.getOrDefault(false)
    val stopped = setOf(TransferState.SUCCEEDED, TransferState.FAILED, TransferState.CANCELLED)
    val error = DsmErrorKind.WORKSPACE_CHANGED.name
    transfers.downloads(owner.profileId).filter { it.state !in stopped && !owned(WorkspaceRecordKind.DOWNLOAD, it.id) }
        .forEach { record -> transfers.update(record.id) { it.copy(state = TransferState.PAUSED, errorKind = error) } }
    transfers.uploads(owner.profileId).filter { it.state !in stopped && !owned(WorkspaceRecordKind.UPLOAD, it.id) }
        .forEach { record -> transfers.updateUpload(record.id) { it.copy(state = TransferState.PAUSED, errorKind = error) } }
    transfers.servers(owner.profileId).filter { it.state !in stopped && !owned(WorkspaceRecordKind.SERVER, it.id) }
        .forEach { record -> transfers.updateServer(record.id) { it.copy(state = TransferState.PAUSED, errorKind = error) } }
    transfers.photoBackupSource(owner.profileId)?.takeIf {
        it.sourceId == null || !owned(WorkspaceRecordKind.PHOTO_SOURCE, it.sourceId)
    }?.let { source -> transfers.upsertPhotoBackupSource(source.copy(enabled = false, needsAttention = true)) }
}

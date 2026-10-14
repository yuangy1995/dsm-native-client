package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.InputStream
import java.util.UUID
import kotlinx.serialization.Serializable

internal enum class SynologyPhotoUploadProblem { LOCAL_FILE, STORAGE, EMPTY, LIMIT, BUSY, PENDING }
internal class SynologyPhotoUploadFailure(val problem: SynologyPhotoUploadProblem) : RuntimeException(problem.name)

/** 外部 URI 只由选择器闭包临时持有；开始上传前复制为应用私有文件。 */
internal data class SynologyPhotoLocalSource(
    val filename: String, val size: Long?, val modifiedAtSeconds: Long?, val relativeFolder: String = "",
    val open: () -> InputStream,
)

@Serializable
internal data class SynologyPhotoUploadEntry(
    val id: String = UUID.randomUUID().toString(), val filename: String, val size: Long, val sha256: String,
    val modifiedAtSeconds: Long, val relativeFolder: String = "", val checkpoint: SynologyPhotoUploadCheckpoint? = null,
) {
    override fun toString() = "PhotoUploadEntry(size=$size, phase=${checkpoint?.phase})"
}

@Serializable
internal data class SynologyPhotoUploadBatch(
    val version: Int = 1, val id: String = UUID.randomUUID().toString(), val owner: WorkspaceOwner, val userId: Long,
    val target: SynologyPhotoUploadTarget, val targetName: String, val duplicate: SynologyPhotoUploadDuplicate,
    val entries: List<SynologyPhotoUploadEntry>, val folders: List<String> = emptyList(),
    val folderCheckpoints: Map<String, SynologyPhotoUploadCheckpoint> = emptyMap(),
    val createdAtSeconds: Long = System.currentTimeMillis() / 1_000,
) {
    val completedCount: Int get() = entries.count { it.checkpoint?.phase == SynologyPhotoUploadPhase.COMPLETED }
    val skippedCount: Int get() = entries.count { it.checkpoint?.phase == SynologyPhotoUploadPhase.SKIPPED }
    val finished: Boolean get() = entries.all { it.checkpoint?.finished == true } && folders.all { folderCheckpoints[it]?.finished == true }
    val requiresReview: Boolean get() = checkpoints.any { it.submitted && !it.finished }
    val hasSubmitted: Boolean get() = checkpoints.any { it.submitted }
    val checkpoints: List<SynologyPhotoUploadCheckpoint> get() = folderCheckpoints.values.toList() + entries.mapNotNull { it.checkpoint }
    val totalBytes: Long get() = entries.fold(0L) { sum, row -> Math.addExact(sum, row.size) }
    fun targetFor(entry: SynologyPhotoUploadEntry): SynologyPhotoUploadTarget = if (folders.isEmpty() || entry.relativeFolder.isEmpty()) target else {
        val parent = folderCheckpoints[entry.relativeFolder]?.takeIf { it.finished }?.folderId ?: throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.PENDING)
        SynologyPhotoUploadTarget.Folder((target as SynologyPhotoUploadTarget.Folder).space, parent)
    }
    fun folderAction(path: String): SynologyPhotoUploadAction.CreateFolder {
        val base = target as? SynologyPhotoUploadTarget.Folder ?: throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.STORAGE)
        val parentPath = path.substringBeforeLast('/', "")
        val parent = if (parentPath.isEmpty()) base.id else folderCheckpoints[parentPath]?.takeIf { it.finished }?.folderId
            ?: throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.PENDING)
        return SynologyPhotoUploadAction.CreateFolder(base.space, parent, path.substringAfterLast('/'))
    }
    fun fileAction(entry: SynologyPhotoUploadEntry) = SynologyPhotoUploadAction.Upload(targetFor(entry), entry.filename,
        entry.size, entry.modifiedAtSeconds, entry.sha256, duplicate)
    override fun toString() = "PhotoUploadBatch(files=${entries.size}, completed=$completedCount, skipped=$skippedCount)"
}

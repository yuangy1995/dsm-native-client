package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.DocumentTreeScan
import io.github.qwertyuiop1995.dsmnativeclient.data.files.isFileMutationPath
import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
internal enum class FolderUploadEntryState { PENDING, SUBMITTING, SUCCEEDED, SKIPPED, FAILED, UNRESOLVED, PAUSED, CANCELLED }

/** 系统授权下的一次固定来源；不随恢复重新扫描或扩大上传范围。 */
@Serializable
internal data class FolderUploadSource(
    val id: String,
    val uri: String,
    val relativePath: String,
    val isDirectory: Boolean,
    val mimeType: String? = null,
    val bytes: Long = 0,
    val modifiedAtEpochMillis: Long? = null,
    val sourceIssue: String? = null,
) {
    val name: String get() = relativePath.substringAfterLast('/')
    val parent: String get() = relativePath.substringBeforeLast('/', "")
}

@Serializable
internal data class FolderUploadEntry(
    val source: FolderUploadSource,
    val state: FolderUploadEntryState = if (source.sourceIssue == null) FolderUploadEntryState.PENDING else FolderUploadEntryState.FAILED,
    val completedBytes: Long = 0,
    val fingerprint: UploadContentFingerprint? = null,
    val errorKind: String? = null,
)

/** 详细阶段位于独立加密键，原 PersistedUpload 继续承担任务归属、通知和生命周期。 */
@Serializable
internal data class FolderUploadPlan(
    val schemaVersion: Int = 1,
    val taskId: String,
    val profileId: String,
    val treeUri: String,
    val destinationPath: String,
    val entries: List<FolderUploadEntry>,
    val overwrite: Boolean = false,
) {
    val totalBytes: Long get() = entries.asSequence().filter { !it.source.isDirectory && it.source.sourceIssue == null }
        .fold(0L) { sum, entry -> Math.addExact(sum, entry.source.bytes) }
    val completedBytes: Long get() = entries.sumOf { it.completedBytes.coerceIn(0, it.source.bytes.coerceAtLeast(0)) }
    val requiresRefresh: Boolean get() = entries.any { it.state in setOf(FolderUploadEntryState.SUBMITTING, FolderUploadEntryState.UNRESOLVED) }
    val rootName: String get() = entries.first { it.source.isDirectory && it.source.parent.isEmpty() && it.source.sourceIssue == null }.source.name

    fun matches(upload: PersistedUpload): Boolean = schemaVersion == 1 &&
        taskId == upload.id && profileId == upload.profileId && treeUri == upload.sourceUri &&
        treeUri == upload.sourceTreeUri && destinationPath == upload.destinationPath && overwrite == upload.overwrite &&
        !upload.backupMode && upload.mirrorDirectories && isFileMutationPath(destinationPath) &&
        entries.isNotEmpty() && entries.map { it.source.id }.distinct().size == entries.size &&
        entries.count { it.source.isDirectory && it.source.parent.isEmpty() && it.source.sourceIssue == null } == 1 &&
        entries.all { entry -> entry.source.sourceIssue != null ||
            (entry.source.bytes >= 0 && entry.source.uri.isNotBlank() && isFileMutationPath("/${entry.source.relativePath}") &&
                entry.source.relativePath.substringBefore('/') == rootName) }

    fun sameDefinition(other: FolderUploadPlan): Boolean =
        copy(entries = emptyList()) == other.copy(entries = emptyList()) &&
            entries.map(FolderUploadEntry::source) == other.entries.map(FolderUploadEntry::source)

    fun recoveringInterruptedEntries() = copy(entries = entries.map { entry ->
        if (entry.state == FolderUploadEntryState.SUBMITTING) entry.copy(state = FolderUploadEntryState.UNRESOLVED) else entry
    })
}

internal fun folderUploadPlan(
    taskId: String, profileId: String, treeUri: String, destinationPath: String,
    scan: DocumentTreeScan, overwrite: Boolean = false,
): FolderUploadPlan {
    require(!scan.truncated)
    val sources = scan.directories.sortedBy { it.relativePath.count { char -> char == '/' } }.map {
        FolderUploadSource(UUID.randomUUID().toString(), it.uri.toString(), it.relativePath, isDirectory = true)
    } + scan.files.map {
        FolderUploadSource(UUID.randomUUID().toString(), it.uri.toString(),
            if (it.relativeFolder.isEmpty()) it.name else "${it.relativeFolder}/${it.name}", false,
            it.mimeType, it.size, it.modifiedAtEpochMillis)
    } + scan.unavailable.map {
        FolderUploadSource(UUID.randomUUID().toString(), "", it.relativePath, false, sourceIssue = it.issue.name)
    }
    return FolderUploadPlan(taskId = taskId, profileId = profileId, treeUri = treeUri, destinationPath = destinationPath,
        entries = sources.map(::FolderUploadEntry), overwrite = overwrite)
}

package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.isFileMutationPath
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import kotlinx.serialization.Serializable
import java.util.UUID

/** ZIP 的固定来源独立保存；任务类型可在清单丢失时识别，不能降级下载首项。 */
@Serializable
internal data class ArchiveDownloadSource(
    val path: String, val name: String, val isDirectory: Boolean,
) {
    fun toFileItem() = FileItem(path = path, name = name, isDirectory = isDirectory, canRead = true)
}

@Serializable
internal data class ArchiveDownloadPlan(
    val schemaVersion: Int = 1,
    val taskId: String,
    val profileId: String,
    val destinationUri: String,
    val sources: List<ArchiveDownloadSource>,
) {
    fun matches(record: PersistedDownload): Boolean = schemaVersion == 1 && record.isArchiveDownload &&
        taskId == record.id && profileId == record.profileId && destinationUri == record.destinationUri &&
        record.isDirectory && record.expectedBytes == null && sources.isNotEmpty() &&
        record.sourcePath == sources.first().path && sources.all { isFileMutationPath(it.path) } &&
        sources.map { it.path }.distinct().size == sources.size &&
        (sources.size > 1 || sources.single().isDirectory)
}

internal val PersistedDownload.isArchiveDownload: Boolean get() = id.startsWith(ARCHIVE_DOWNLOAD_PREFIX)
internal fun newArchiveDownloadId(): String = ARCHIVE_DOWNLOAD_PREFIX + UUID.randomUUID().toString()
private const val ARCHIVE_DOWNLOAD_PREFIX = "archive-download-"

internal class ArchiveDownloadPlanUnavailable : java.io.IOException("Archive download plan is unavailable")

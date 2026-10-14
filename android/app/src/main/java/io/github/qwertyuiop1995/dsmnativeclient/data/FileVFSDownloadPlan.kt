package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.FileVFSReader
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import java.util.UUID

/** 远程文件的原连接及目录项快照；只保存来源，不保存任何密码或云授权令牌。 */
@Serializable
internal data class FileVFSDownloadSource(
    val profile: FileVFSProfile, val parent: String, val path: String, val name: String,
    val size: Long, val modifiedAtEpochSeconds: Long?,
) {
    fun valid() = profile.state == FileVFSConnectionState.CONNECTED && fileVFSPathBelongsTo(parent, profile) &&
        fileVFSPathBelongsTo(path, profile) && path.substringBeforeLast('/') == parent.removeSuffix("/") && name.isNotEmpty() && size >= 0
    fun matches(item: FileItem) = valid() && !item.isDirectory && item.canRead && path == item.path && name == item.name &&
        size == item.size && modifiedAtEpochSeconds == item.modifiedAtEpochSeconds
    fun item() = FileItem(path, name, false, size, modifiedAtEpochSeconds, canRead = true)
    override fun toString() = "FileVFSDownloadSource"
}

@Serializable
internal data class FileVFSDownloadPlan(
    val schemaVersion: Int = 1, val taskId: String, val destinationUri: String, val source: FileVFSDownloadSource,
) {
    fun matches(record: PersistedDownload) = schemaVersion == 1 && record.isVFSDownload && taskId == record.id &&
        destinationUri == record.destinationUri && source.profile.owner.profileId == record.profileId && source.valid() &&
        record.sourcePath == source.path && !record.isDirectory && record.expectedBytes == source.size.takeIf { it > 0 }
    override fun toString() = "FileVFSDownloadPlan"
}

/** 每次执行和恢复先核对原连接及原目录项，完成前不打开或截断本地目标。 */
internal suspend fun FileVFSReader.requireDownloadSource(source: FileVFSDownloadSource): FileItem {
    if (!source.valid()) throw FileVFSDownloadPlanUnavailable()
    var offset = 0
    var total: Int? = null
    val seen = mutableSetOf<String>()
    do {
        currentCoroutineContext().ensureActive()
        val page = folder(source.profile, source.parent, offset)
        if (total != null && total != page.total || page.items.any { !seen.add(it.path) }) throw FileVFSDownloadPlanUnavailable()
        total = page.total
        page.items.singleOrNull { it.path == source.path }?.let {
            if (!source.matches(it)) throw FileVFSDownloadPlanUnavailable()
            requireProfile(source.profile)
            return it
        }
        offset += page.items.size
    } while (offset < total)
    throw FileVFSDownloadPlanUnavailable()
}

internal val PersistedDownload.isVFSDownload get() = id.startsWith("vfs-download-")
internal fun newVFSDownloadId() = "vfs-download-" + UUID.randomUUID().toString()
internal class FileVFSDownloadPlanUnavailable : java.io.IOException("The original remote download source is unavailable")

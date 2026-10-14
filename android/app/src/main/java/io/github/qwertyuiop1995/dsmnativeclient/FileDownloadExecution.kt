package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import android.net.Uri
import io.github.qwertyuiop1995.dsmnativeclient.data.requireDownloadSource
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedDownload
import io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore
import java.io.FileOutputStream
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind

/** 前台与 Worker 共用输出逻辑；清单和原账号检查必须早于打开、截断目标。 */
internal suspend fun executeFileDownload(
    context: Context,
    repo: DsmRepository,
    record: PersistedDownload,
    transfers: TransferStore,
    requireExactResume: Boolean,
    requireActive: () -> Unit,
    onReset: () -> Unit,
    onProgress: (Long, Long?) -> Unit,
) = withContext(Dispatchers.IO) { withDownloadDestination(record.destinationUri) {
    val plan = transfers.archiveDownloadPlan(record)
    WorkspaceTaskOwnership(SecureProfileStore(context)).require(WorkspaceRecordKind.DOWNLOAD, record.id, repo)
    requireActive()
    val remote = transfers.vfsDownloadPlan(record)?.let { remotePlan ->
        if (repo.owner?.hasSameIdentity(remotePlan.source.profile.owner) != true)
            throw io.github.qwertyuiop1995.dsmnativeclient.data.FileVFSDownloadPlanUnavailable()
        repo.fileMounts.vfs.reader.requireDownloadSource(remotePlan.source)
    }
    requireActive()
    val descriptor = context.contentResolver.openFileDescriptor(Uri.parse(record.destinationUri), "rw")
        ?: throw IOException("The destination could not be opened")
    descriptor.use { parcel ->
        FileOutputStream(parcel.fileDescriptor).use { stream ->
            repo.requireCurrentOwner()
            requireActive()
            val requested = if (!record.isDirectory) record.completedBytes else 0L
            val resume = runCatching {
                when {
                    requested > 0 && stream.channel.size() == requested -> {
                        stream.channel.position(requested); requested
                    }
                    requireExactResume && requested > 0 -> throw IOException("The saved partial download does not match its resume offset")
                    else -> { stream.channel.truncate(0); stream.channel.position(0); 0L }
                }
            }.getOrElse { throw IOException("The destination does not support safe resume", it) }
            if (resume == 0L) onReset()
            val execution = currentCoroutineContext()
            val output = object : java.io.OutputStream() {
                override fun write(bytes: ByteArray, offset: Int, count: Int) {
                    execution.ensureActive()
                    repo.requireCurrentOwner()
                    requireActive()
                    stream.write(bytes, offset, count)
                }
                override fun write(value: Int) = write(byteArrayOf(value.toByte()), 0, 1)
                override fun flush() = stream.flush()
            }
            if (plan != null) repo.downloadArchive(plan.sources.map { it.toFileItem() }, output, onProgress)
            else repo.download(remote ?: record.toDownloadFileItem(), output, resumeFrom = resume, onProgress = onProgress)
        }
    }
} }

/** 暂停后立即重开仍需等待旧输出关闭，避免旧流覆盖新 ZIP；不同目标可并行。 */
private class DownloadDestinationLock(val mutex: Mutex = Mutex(), var users: Int = 0)
private val downloadDestinations = mutableMapOf<String, DownloadDestinationLock>()

internal suspend fun <T> withDownloadDestination(uri: String, block: suspend () -> T): T {
    val entry = synchronized(downloadDestinations) {
        downloadDestinations.getOrPut(uri) { DownloadDestinationLock() }.also { it.users++ }
    }
    try { return entry.mutex.withLock { block() } }
    finally { synchronized(downloadDestinations) {
        entry.users--
        if (entry.users == 0) downloadDestinations.remove(uri)
    } }
}

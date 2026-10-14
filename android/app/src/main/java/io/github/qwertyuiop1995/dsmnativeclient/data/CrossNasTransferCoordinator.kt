package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.supervisorScope

/** 跨 NAS 文件复制使用固定容量内存管道，不生成完整文件临时副本。 */
internal class CrossNasTransferCoordinator(
    private val pipeCapacityBytes: Int = DEFAULT_PIPE_CAPACITY_BYTES,
) {
    init {
        require(pipeCapacityBytes > 0)
    }

    internal suspend fun copyFile(
        source: CrossNasTransferEndpoint,
        target: CrossNasTransferEndpoint,
        item: FileItem,
        destinationPath: String,
        onProgress: (Long) -> Unit,
    ): MutationResult = supervisorScope {
        val input = PipedInputStream(pipeCapacityBytes)
        val output = PipedOutputStream(input)
        val opened = AtomicBoolean(false)
        val uploadSource = UploadSource(
            displayName = item.name,
            contentType = item.mimeType,
            contentLength = item.size,
            openInputStream = {
                check(opened.compareAndSet(false, true)) { "cross-nas stream already opened" }
                input
            },
        )
        val upload = async(Dispatchers.IO) {
            target.uploadResult(uploadSource, destinationPath, false) { completed, _ ->
                onProgress(completed)
            }
        }
        val download = async(Dispatchers.IO) {
            try {
                output.use { source.download(item, it) }
            } catch (failure: Throwable) {
                currentCoroutineContext().ensureActive()
                throw failure
            }
        }
        try {
            val uploadResult = upload.await()
            if (uploadResult.status != MutationResultStatus.CONFIRMED_SUCCESS) {
                download.cancel()
                input.close()
                output.close()
                return@supervisorScope uploadResult
            }
            download.await()
            uploadResult
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            currentCoroutineContext().ensureActive()
            throw failure
        } finally {
            upload.cancel()
            download.cancel()
            input.close()
            output.close()
        }
    }

    companion object { private const val DEFAULT_PIPE_CAPACITY_BYTES = 12 * 1024 * 1024 }
}

internal interface CrossNasTransferEndpoint {
    val owner: io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
    suspend fun requireAccess()
    suspend fun contentDigest(path: String): String
    suspend fun deleteSingleResult(item: FileItem): MutationResult
    fun supportsSource(moveSource: Boolean): Boolean
    fun supportsTarget(includesDirectory: Boolean): Boolean
    suspend fun listDirectory(path: String, offset: Int, limit: Int): FilePage
    suspend fun findItem(path: String): FileItem?
    suspend fun createFolderResult(parent: FileItem, name: String): MutationResult
    suspend fun uploadResult(
        source: UploadSource,
        destinationPath: String,
        overwrite: Boolean,
        onProgress: (Long, Long) -> Unit,
    ): MutationResult
    suspend fun download(item: FileItem, output: OutputStream): Long
}

internal class RepositoryCrossNasTransferEndpoint(
    private val repository: DsmRepository,
) : CrossNasTransferEndpoint {
    override val owner get() = repository.owner ?: throw io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure()
    override suspend fun requireAccess() {
        repository.requireCurrentOwner(); repository.refreshAccess(); repository.requireCurrentOwner()
        if (!repository.filePermissionAccess.granted) throw io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure(
            null, "Files are unavailable", "Refresh the connection and try again.", kind = io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind.PERMISSION_DENIED)
    }
    override suspend fun contentDigest(path: String) = repository.fileMd5(path)
    override suspend fun deleteSingleResult(item: FileItem) = repository.deleteResult(item, recursive = false)

    override fun supportsSource(moveSource: Boolean) = repository.supportsCrossNasSource(moveSource)

    override fun supportsTarget(includesDirectory: Boolean) =
        repository.supportsCrossNasTarget(includesDirectory)

    override suspend fun listDirectory(path: String, offset: Int, limit: Int) =
        repository.fileStationRepository.crossNasReader.page(path, offset, limit)

    override suspend fun findItem(path: String): FileItem? = repository.fileStationRepository.crossNasReader.item(path)

    override suspend fun createFolderResult(parent: FileItem, name: String) =
        repository.createFolderResult(parent, name, preserveSourceName = true)

    override suspend fun uploadResult(
        source: UploadSource,
        destinationPath: String,
        overwrite: Boolean,
        onProgress: (Long, Long) -> Unit,
    ) = repository.uploadResult(source, destinationPath, overwrite, onProgress)

    override suspend fun download(item: FileItem, output: OutputStream) =
        repository.download(item, output)


}

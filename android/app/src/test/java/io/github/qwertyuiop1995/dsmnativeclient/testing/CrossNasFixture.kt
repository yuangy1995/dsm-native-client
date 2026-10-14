package io.github.qwertyuiop1995.dsmnativeclient.testing

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceChangedFailure
import kotlinx.coroutines.delay
import java.io.OutputStream
import java.security.MessageDigest

/** 合成 NAS 仅替代网络，队列/清单/持久化/管道均使用正式实现。 */
internal class CrossNasFixture(pipeCapacityBytes: Int = 1024) {
    val preferences = MemoryPreferences()
    val store = CrossNasTransferStore(preferences)
    val source = Endpoint("source").apply { directory("/source") }
    val target = Endpoint("target").apply { directory("/target") }
    val queue = CrossNasTransferQueue(store, stream = CrossNasTransferCoordinator(pipeCapacityBytes))
    suspend fun create(roots: List<FileItem>, move: Boolean = false) = queue.create(source, target, roots,
        target.items.getValue("/target"), move, "Source", "Target")
    internal class Endpoint(profile: String) : CrossNasTransferEndpoint {
        override var owner = WorkspaceOwner(profile, "identity", "session")
        var access = true
        var supported = true
        val items = linkedMapOf<String, FileItem>()
        val contents = linkedMapOf<String, ByteArray>()
        var downloads = 0; var uploads = 0; var creates = 0; var opens = 0
        var onStreamOpened: (() -> Unit)? = null
        val deletions = mutableListOf<String>()
        var failUploadAfterWrite = false
        var unknownUpload = false
        var rejectUpload = false
        var failCreateAfterWrite = false
        var unknownDelete = false
        var deleteWithoutRemoval = false
        var delayUploadMillis = 0L
        var beforeUpload: (() -> Unit)? = null
        var beforeCreate: (() -> Unit)? = null
        var beforeDelete: ((FileItem) -> Unit)? = null
        var onFind: ((String) -> Unit)? = null
        var onList: ((String, Int) -> Unit)? = null
        var listOverride: ((String, Int, Int) -> FilePage)? = null
        var afterUpload: (() -> Unit)? = null
        fun directory(path: String): FileItem = FileItem(path, path.substringAfterLast('/'), true,
            modifiedAtEpochSeconds = 100, canRead = true, canWrite = true, canDelete = true, mountPointType = "normal").also { items[path] = it }
        fun file(path: String, bytes: ByteArray = byteArrayOf(1, 2, 3)): FileItem = FileItem(path, path.substringAfterLast('/'), false,
            size = bytes.size.toLong(), modifiedAtEpochSeconds = 100, canRead = true, canWrite = true, canDelete = true, mountPointType = "normal").also {
            items[path] = it; contents[path] = bytes
        }
        private fun parentChanged(path: String) { val key = crossNasParent(path); items[key]?.let { items[key] = it.copy(modifiedAtEpochSeconds = (it.modifiedAtEpochSeconds ?: 0) + 1) } }
        override suspend fun requireAccess() { if (!access) throw workspaceChangedFailure() }
        override fun supportsSource(moveSource: Boolean) = supported
        override fun supportsTarget(includesDirectory: Boolean) = supported
        override suspend fun listDirectory(path: String, offset: Int, limit: Int): FilePage {
            requireAccess(); onList?.invoke(path, offset)
            listOverride?.let { return it(path, offset, limit) }
            if (items[path]?.isDirectory != true) throw crossNasReadFailure()
            val all = items.values.filter { crossNasParent(it.path) == path }.sortedBy { it.name }
            return FilePage(all.drop(offset).take(limit), all.size, offset)
        }
        override suspend fun findItem(path: String): FileItem? { requireAccess(); onFind?.invoke(path); return items[path] }
        override suspend fun contentDigest(path: String): String { requireAccess(); return digest(contents.getValue(path)) }
        override suspend fun createFolderResult(parent: FileItem, name: String): MutationResult {
            requireAccess(); beforeCreate?.invoke(); creates++
            val path = crossNasJoin(parent.path, name)
            check(path !in items); directory(path); parentChanged(path)
            if (failCreateAfterWrite) throw crossNasReadFailure()
            return result()
        }
        override suspend fun uploadResult(source: UploadSource, destinationPath: String, overwrite: Boolean,
            onProgress: (Long, Long) -> Unit): MutationResult {
            requireAccess(); check(!overwrite); beforeUpload?.invoke()
            if (rejectUpload) return result(MutationResultStatus.PERMISSION_DENIED, false)
            uploads++
            val path = crossNasJoin(destinationPath, source.displayName)
            check(path !in items)
            val output = java.io.ByteArrayOutputStream()
            source.openInputStream().use { input ->
                opens++; onStreamOpened?.invoke()
                val buffer = ByteArray(257)
                while (true) {
                    val count = input.read(buffer); if (count < 0) break
                    output.write(buffer, 0, count); onProgress(output.size().toLong(), source.contentLength)
                    if (delayUploadMillis > 0) delay(delayUploadMillis)
                }
            }
            file(path, output.toByteArray()); parentChanged(path); afterUpload?.invoke()
            if (failUploadAfterWrite) throw crossNasReadFailure()
            return result(if (unknownUpload) MutationResultStatus.SUBMITTED_BUT_UNVERIFIED else MutationResultStatus.CONFIRMED_SUCCESS)
        }
        override suspend fun download(item: FileItem, output: OutputStream): Long {
            requireAccess(); downloads++; val bytes = contents.getValue(item.path); output.write(bytes); return bytes.size.toLong()
        }
        override suspend fun deleteSingleResult(item: FileItem): MutationResult {
            requireAccess(); beforeDelete?.invoke(item)
            check(items[item.path] == item); check(item.canDelete)
            check(!item.isDirectory || items.values.none { crossNasParent(it.path) == item.path })
            deletions += item.path
            if (!deleteWithoutRemoval) { items.remove(item.path); contents.remove(item.path); parentChanged(item.path) }
            return result(if (unknownDelete) MutationResultStatus.SUBMITTED_BUT_UNVERIFIED else MutationResultStatus.CONFIRMED_SUCCESS)
        }
        companion object {
            fun digest(bytes: ByteArray) = MessageDigest.getInstance("MD5").digest(bytes).joinToString("") { "%02x".format(it) }
            fun result(status: MutationResultStatus = MutationResultStatus.CONFIRMED_SUCCESS, submitted: Boolean = true) =
                MutationResult(1, status, "fixture", submitted, status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    MutationResultCounts(succeeded = if (status == MutationResultStatus.CONFIRMED_SUCCESS) 1 else 0, failed = 0,
                        unknown = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 1 else 0))
        }
    }
}

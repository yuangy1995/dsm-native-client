package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceChangedFailure
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.ByteArrayInputStream
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

/** 正式序列化与事务入口，内存介质和端点仅替代磁盘、网络及系统提供器。 */
class FolderUploadCoordinatorTest {
    private val preferences = MemoryPreferences()
    private val store = TransferStore(preferences)
    private val proof = UploadContentFingerprint(3, "a".repeat(64))
    private val task = PersistedUpload("folder", "account-a", "content://synthetic/tree", "Root ", expectedBytes = 6,
        destinationPath = "/synthetic", sourceTreeUri = "content://synthetic/tree", backupMode = false, mirrorDirectories = true, workId = "execution-a")
    private val entries = listOf(directory("Root "), directory("Root /Empty "), directory("Root /Other"),
        file("Root /first.txt "), file("Root /Other/second.txt"))
    private val plan = FolderUploadPlan(taskId = task.id, profileId = task.profileId, treeUri = task.sourceUri, destinationPath = task.destinationPath, entries = entries)
    private val endpoint = Endpoint()
    private fun directory(path: String) = FolderUploadEntry(FolderUploadSource(path, "content://synthetic/$path", path, true))
    private fun file(path: String) = FolderUploadEntry(FolderUploadSource(path, "content://synthetic/$path", path, false, "text/plain", 3))
    private fun seed(value: FolderUploadPlan = plan, record: PersistedUpload = task) { assertTrue(store.createFolderUploadDurably(record.copy(expectedBytes = value.totalBytes), value)) }
    private suspend fun run(execution: String = "execution-a") = FolderUploadCoordinator(store, endpoint, task.id, execution).run()
    private fun state(path: String) = checkNotNull(store.folderUploadPlan(task.id)).entries.single { it.source.relativePath == path }.state

    @Test fun `目录先于文件并保留根空目录和原始名称`() = runTest {
        seed(); val result = run()
        assertEquals(TransferState.SUCCEEDED, result?.state)
        assertEquals(listOf("mkdir:/synthetic/Root ", "mkdir:/synthetic/Root /Empty ", "mkdir:/synthetic/Root /Other",
            "upload:/synthetic/Root /first.txt ", "upload:/synthetic/Root /Other/second.txt"), endpoint.writes)
        assertEquals(6L, result?.completedBytes)
        assertEquals(proof, store.folderUploadPlan(task.id)?.entries?.last()?.fingerprint)
    }

    @Test fun `只有空根目录也能完成`() = runTest {
        seed(plan.copy(entries = listOf(directory("Root ")))); assertEquals(TransferState.SUCCEEDED, run()?.state)
        assertEquals(listOf("mkdir:/synthetic/Root "), endpoint.writes)
    }

    @Test fun `目录失败阻止子项但其他分支继续`() = runTest {
        seed(); endpoint.rejectedPath = "/synthetic/Root /Other"
        assertEquals(TransferState.FAILED, run()?.state)
        assertEquals(FolderUploadEntryState.FAILED, state("Root /Other/second.txt"))
        assertEquals(FolderUploadEntryState.SUCCEEDED, state("Root /first.txt "))
        assertFalse(endpoint.writes.any { it.endsWith("second.txt") })
    }

    @Test fun `默认跳过同名文件而同名目录冲突保留失败`() = runTest {
        seed(); endpoint.items["/synthetic/Root /first.txt "] = item("/synthetic/Root /first.txt ", false)
        endpoint.items["/synthetic/Root /Other/second.txt"] = item("/synthetic/Root /Other/second.txt", true)
        assertEquals(TransferState.FAILED, run()?.state)
        assertEquals(FolderUploadEntryState.SKIPPED, state("Root /first.txt "))
        assertEquals(FolderUploadEntryState.FAILED, state("Root /Other/second.txt"))
        assertTrue(endpoint.writes.none { it.startsWith("upload:") })
    }

    @Test fun `明确覆盖只对文件启用且发送前已有提交记录`() = runTest {
        seed(plan.copy(overwrite = true), task.copy(overwrite = true))
        endpoint.items["/synthetic/Root /first.txt "] = item("/synthetic/Root /first.txt ", false)
        assertEquals(TransferState.SUCCEEDED, run()?.state)
        assertEquals(listOf(true, true), endpoint.overwrites)
        assertTrue(endpoint.everyWriteJournaled)
    }

    @Test fun `全部同名文件跳过后任务进度完整但没有文件写入`() = runTest {
        seed()
        entries.filter { !it.source.isDirectory }.forEach { endpoint.items["/synthetic/${it.source.relativePath}"] = item("/synthetic/${it.source.relativePath}", false) }
        val completed = run()
        assertEquals(TransferState.SUCCEEDED, completed?.state)
        assertEquals(task.expectedBytes, completed?.completedBytes)
        assertTrue(endpoint.writes.none { it.startsWith("upload:") })
        assertEquals(2, store.folderUploadPlan(task.id)?.entries?.count { it.state == FolderUploadEntryState.SKIPPED })
    }

    @Test fun `提交后中断只读核对摘要且缺失时不重放`() = runTest {
        val interrupted = plan.copy(entries = entries.map { if (it.source.relativePath == "Root /first.txt ")
            it.copy(state = FolderUploadEntryState.SUBMITTING, fingerprint = proof) else it })
        seed(interrupted)
        assertEquals(TransferState.FAILED, run()?.state)
        assertEquals(FolderUploadEntryState.UNRESOLVED, state("Root /first.txt "))
        assertTrue(checkNotNull(store.upload(task.id)).requiresRefresh)
        assertTrue(endpoint.writes.none { it.endsWith("first.txt ") })
        assertEquals(FolderUploadEntryState.SUCCEEDED, state("Root /Other/second.txt"))
    }

    @Test fun `摘要吻合才能收敛未知文件且不会重新上传`() = runTest {
        seed(plan.copy(entries = entries.map { if (!it.source.isDirectory) it.copy(state = FolderUploadEntryState.UNRESOLVED, fingerprint = proof) else it }))
        entries.filter { !it.source.isDirectory }.forEach { endpoint.items["/synthetic/${it.source.relativePath}"] = item("/synthetic/${it.source.relativePath}", false) }
        assertEquals(TransferState.SUCCEEDED, run()?.state)
        assertEquals(2, endpoint.contentReads)
        assertTrue(endpoint.writes.none { it.startsWith("upload:") })
        assertFalse(checkNotNull(store.upload(task.id)).requiresRefresh)
    }

    @Test fun `取消保留完成项和未知项且不触碰其他文件`() = runTest {
        seed(); endpoint.cancelPath = "/synthetic/Root /first.txt "
        assertTrue(runCatching { run() }.exceptionOrNull() is CancellationException)
        assertEquals(TransferState.CANCELLED, store.upload(task.id)?.state)
        assertEquals(FolderUploadEntryState.SUCCEEDED, state("Root /Empty "))
        assertEquals(FolderUploadEntryState.UNRESOLVED, state("Root /first.txt "))
        assertEquals(FolderUploadEntryState.CANCELLED, state("Root /Other/second.txt"))
        assertFalse(endpoint.writes.any { it.endsWith("second.txt") })
    }

    @Test fun `取消后返回的确定成功必须保留但不继续下一项`() = runTest {
        seed(); endpoint.onUpload = { store.updateUpload(task.id) { it.copy(state = TransferState.CANCELLING) } }
        assertTrue(runCatching { run() }.exceptionOrNull() is CancellationException)
        assertEquals(FolderUploadEntryState.SUCCEEDED, state("Root /first.txt "))
        assertEquals(FolderUploadEntryState.CANCELLED, state("Root /Other/second.txt"))
        assertFalse(checkNotNull(store.upload(task.id)).requiresRefresh)
    }

    @Test fun `进入执行器前取消会结束整组且没有NAS写入`() = runTest {
        seed(record = task.copy(state = TransferState.CANCELLING))
        assertEquals(TransferState.CANCELLED, run()?.state)
        assertTrue(checkNotNull(store.folderUploadPlan(task.id)).entries.all { it.state == FolderUploadEntryState.CANCELLED })
        assertTrue(endpoint.writes.isEmpty())
        assertFalse(checkNotNull(store.upload(task.id)).requiresRefresh)
    }

    @Test fun `最后一项完成时的取消不会丢失全部完成事实`() = runTest {
        seed(); endpoint.onUpload = {
            if (endpoint.writes.last().endsWith("second.txt")) store.updateUpload(task.id) { it.copy(state = TransferState.CANCELLING) }
        }
        assertEquals(TransferState.SUCCEEDED, run()?.state)
        assertTrue(checkNotNull(store.folderUploadPlan(task.id)).entries.all { it.state == FolderUploadEntryState.SUCCEEDED })
        assertFalse(checkNotNull(store.upload(task.id)).requiresRefresh)
    }

    @Test fun `旧账号失效暂停任务且不能写入下一个目录`() = runTest {
        seed(); endpoint.onCreate = { endpoint.ownerValid = false }
        assertEquals(TransferState.PAUSED, run()?.state)
        assertEquals(1, endpoint.writes.size)
        assertEquals(DsmErrorKind.WORKSPACE_CHANGED.name, store.upload(task.id)?.errorKind)
    }

    @Test fun `登录过期暂停整组且不会逐项重试相同认证失败`() = runTest {
        seed(); endpoint.onCreate = { throw DsmFailure(null, "", "", kind = DsmErrorKind.SESSION_EXPIRED) }
        assertEquals(TransferState.PAUSED, run()?.state)
        assertEquals(1, endpoint.writes.size)
        assertEquals(DsmErrorKind.SESSION_EXPIRED.name, store.upload(task.id)?.errorKind)
        assertEquals(FolderUploadEntryState.UNRESOLVED, state("Root "))
        assertEquals(FolderUploadEntryState.PAUSED, state("Root /Other/second.txt"))
    }

    @Test fun `记录保存失败前不能进行NAS写入`() = runTest {
        seed(); preferences.commitSucceeds = false
        val failure = runCatching { run() }.exceptionOrNull()
        assertTrue(failure is IllegalStateException)
        assertEquals("transfer.upload_state_not_persisted", failure?.message)
        assertTrue(endpoint.writes.isEmpty())
    }

    @Test fun `手动继续只重排可失败项且旧执行器不能推进`() = runTest {
        seed(); endpoint.rejectedPath = "/synthetic/Root /Other"; run()
        val before = checkNotNull(store.upload(task.id))
        val next = checkNotNull(store.beginFolderUploadExecution(before, "execution-b"))
        assertNull(store.beginFolderUploadExecution(before, "execution-c"))
        val writes = endpoint.writes.size
        run(); assertEquals(writes, endpoint.writes.size)
        endpoint.rejectedPath = null; assertEquals(TransferState.SUCCEEDED, run("execution-b")?.state)
        assertEquals(1, endpoint.writes.count { it.endsWith("first.txt ") })
        assertEquals(next.workId, store.upload(task.id)?.workId)
    }

    private fun item(path: String, directory: Boolean) = FileItem(path, path.substringAfterLast('/'), directory, if (directory) 0 else 3, canWrite = true)
    private fun result(success: Boolean) = MutationResult(schemaVersion = 1,
        status = if (success) MutationResultStatus.CONFIRMED_SUCCESS else MutationResultStatus.CONFIRMED_FAILURE,
        operation = "fileUpload", submitted = true, requiresRefresh = false,
        counts = MutationResultCounts(if (success) 1 else 0, if (success) 0 else 1, 0),
        errorCategory = if (success) null else MutationErrorCategory.PERMISSION, diagnosticTag = "synthetic.folder-upload")

    private inner class Endpoint : FolderUploadEndpoint {
        val items = mutableMapOf("/synthetic" to item("/synthetic", true))
        val writes = mutableListOf<String>()
        val overwrites = mutableListOf<Boolean>()
        var rejectedPath: String? = null
        var cancelPath: String? = null
        var contentReads = 0
        var ownerValid = true
        var everyWriteJournaled = true
        var onCreate: (() -> Unit)? = null
        var onUpload: (() -> Unit)? = null
        override fun requireOwner() { if (!ownerValid) throw workspaceChangedFailure() }
        override suspend fun directoryIsUsable(path: String) = items[path]?.let { it.isDirectory && it.canWrite } == true
        override suspend fun item(path: String) = items[path]
        override suspend fun prepare(entry: FolderUploadEntry) = UploadSource(entry.source.name, "text/plain", 3, { ByteArrayInputStream("abc".toByteArray()) })
        override suspend fun createDirectory(parent: String, path: String): MutationResult {
            recordWrite("mkdir", path); onCreate?.invoke()
            if (path != rejectedPath) items[path] = item(path, true)
            return result(path != rejectedPath)
        }
        override suspend fun upload(source: UploadSource, parent: String, overwrite: Boolean, progress: (Long, Long) -> Unit): MutationResult {
            val path = "$parent/${source.displayName}"
            recordWrite("upload", path); overwrites += overwrite
            source.onContentRead(proof)
            if (path == cancelPath) throw CancellationException("Synthetic cancellation")
            onUpload?.invoke(); items[path] = item(path, false); progress(3, 3)
            return result(true)
        }
        override suspend fun contentMatches(item: FileItem, fingerprint: UploadContentFingerprint): Boolean { contentReads++; return fingerprint == proof }
        private fun recordWrite(operation: String, path: String) {
            val entry = checkNotNull(store.folderUploadPlan(task.id)).entries.single { "/synthetic/${it.source.relativePath}" == path }
            everyWriteJournaled = everyWriteJournaled && entry.state == FolderUploadEntryState.SUBMITTING
            writes += "$operation:$path"
        }
    }
}

package io.github.qwertyuiop1995.dsmnativeclient.systemfiles

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.IOException
import java.util.UUID

class SharedInputStoreTest {
    @get:Rule val temporary = TemporaryFolder()
    private val preferences = MemoryPreferences()
    private val transfers = TransferStore(MemoryPreferences())
    private fun store() = SharedInputStore(preferences, temporary.root, "synthetic.app")
    private fun source(name: String = "file.txt", length: Long? = 3) = SharedSource(name, "text/plain", length) { "abc".byteInputStream() }
    private suspend fun rejected(action: suspend () -> Unit) { try { action(); fail("Expected refusal") } catch (_: Exception) { } }
    @Test fun `完整副本和索引冷启动可读且保留原文件名空白`() = runBlocking {
        val store = store(); val batch = store.receive(listOf(source(" file.txt ", null)))
        assertEquals(batch, store().batches().single()); val file = batch.files.single()
        assertEquals(" file.txt ", store().entry(file.id).name); assertEquals("abc", store.file(file.id).readText())
        assertFalse(store.uri(file.id).contains("file.txt")); assertFalse(store.uri(file.id).contains("/share/"))
    }
    @Test fun `仅允许规范私有来源标识拒绝路径和其他authority`() {
        val store = store(); val id = UUID.randomUUID().toString(); assertEquals(id, store.id(store.uri(id)))
        listOf("file:///tmp/$id", "content://other/$id", "content://synthetic.app.shared-input/../$id",
            store.uri(id) + "?x=1", store.uri(id) + "#x", "content://synthetic.app.shared-input/%2E%2E/$id").forEach { assertNull(store.id(it)) }
    }
    @Test fun `部分复制失败长度改变和重名不发布草稿也不遗留文件`() = runBlocking {
        val store = store()
        rejected { store.receive(listOf(source(), SharedSource("bad.txt", null, 9) { throw IOException("synthetic") })) }
        rejected { store.receive(listOf(source(length = 2))) }; rejected { store.receive(listOf(source(length = 4))) }
        rejected { store.receive(listOf(source(), source("FILE.TXT"))) }
        assertTrue(store.batches().isEmpty()); assertTrue(temporary.root.listFiles().isNullOrEmpty())
    }
    @Test fun `复制取消停止后续源并清除未发布副本`() = runBlocking {
        val store = store(); val started = CompletableDeferred<Unit>()
        val worker = launch { store.receive(listOf(SharedSource("file", null, null) { object : java.io.InputStream() {
            override fun read(): Int = 1
            override fun read(bytes: ByteArray, off: Int, len: Int): Int { started.complete(Unit); Thread.sleep(5); bytes[off] = 1; return 1 }
        } })) }
        started.await(); worker.cancelAndJoin()
        assertTrue(store.batches().isEmpty()); assertTrue(temporary.root.listFiles().isNullOrEmpty())
    }
    @Test fun `未提交草稿保留副本取消只删除本批次`() = runBlocking {
        val store = store(); val first = store.receive(listOf(source())); val second = store.receive(listOf(source()))
        store.reconcile(transfers); store.release(store.uri(first.files.single().id)) { false }
        assertTrue(store.file(first.files.single().id).exists()); store.discard(first)
        assertFalse(store.file(first.files.single().id).exists()); assertEquals(listOf(second), store.batches())
    }
    @Test fun `原子提交标记防止重复接手清理任务前仍保留源`() = runBlocking {
        val store = store(); val batch = store.receive(listOf(source())); val file = batch.files.single()
        val upload = PersistedUpload(file.id, "profile", store.uri(file.id), file.name, expectedBytes = file.bytes,
            destinationPath = "/share", backupMode = false, ownsPersistedReadGrant = false)
        assertTrue(transfers.createSharedUploadsDurably(batch.id, listOf(upload)))
        assertFalse(transfers.createSharedUploadsDurably(batch.id, listOf(upload)))
        store().reconcile(transfers); assertTrue(store.batches().isEmpty()); assertTrue(store.file(file.id).exists())
        transfers.updateUpload(upload.id) { it.copy(state = TransferState.SUCCEEDED) }
        store().reconcile(transfers); assertTrue(store.file(file.id).exists())
        transfers.removeTerminal("profile"); store().reconcile(transfers); assertFalse(store.file(file.id).exists())
        assertFalse(transfers.createSharedUploadsDurably(batch.id, listOf(upload)))
    }
    @Test fun `整批保存失败不返回可调度成功且后续读到标记不重复提交`() = runBlocking {
        val prefs = MemoryPreferences(); val transfers = TransferStore(prefs); val store = store()
        val batch = store.receive(listOf(source())); val file = batch.files.single()
        val upload = PersistedUpload(file.id, "profile", store.uri(file.id), file.name, expectedBytes = 3, destinationPath = "/share", backupMode = false)
        prefs.commitSucceeds = false
        rejected { transfers.createSharedUploadsDurably(batch.id, listOf(upload)) }
        prefs.commitSucceeds = true
        assertFalse(transfers.createSharedUploadsDurably(batch.id, listOf(upload)))
        assertEquals(1, transfers.uploads("profile").size)
    }
    @Test fun `损坏索引阻止清理避免删除已有源`() = runBlocking {
        val store = store(); val batch = store.receive(listOf(source())); val id = batch.files.single().id
        preferences.edit().putString("batch:${batch.id}", "{}").commit()
        rejected { store.reconcile(transfers) }; assertTrue(store.file(id).exists())
    }
}

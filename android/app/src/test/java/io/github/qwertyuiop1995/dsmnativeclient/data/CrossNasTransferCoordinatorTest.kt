package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.CrossNasFixture
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

/** 原协调器的 13 个行为场景迁至唯一正式队列；删源断言采用独立确认的新语义。 */
class CrossNasTransferCoordinatorTest {
    @Test fun `large file crosses a small bounded pipe without a disk copy`() = runBlocking {
        val f = CrossNasFixture(1024); val bytes = ByteArray(512 * 1024) { (it % 251).toByte() }
        val row = f.create(listOf(f.source.file("/source/large.bin", bytes))); f.target.delayUploadMillis = 1
        assertEquals(CrossNasPhase.FINISHED, withTimeout(10_000) { f.queue.copy(row.id, f.source, f.target) }.phase)
        assertArrayEquals(bytes, f.target.contents["/target/large.bin"]); assertTrue(f.source.deletions.isEmpty()); assertEquals(1, f.target.opens)
    }
    @Test fun `move deletes source only after every target copy and separate confirmation`() = runBlocking {
        val f = CrossNasFixture(2); val row = f.create(listOf(f.source.file("/source/a.bin")), true)
        assertEquals(CrossNasPhase.COPIED, f.queue.copy(row.id, f.source, f.target).phase)
        assertTrue(f.source.deletions.isEmpty())
        failure { f.queue.removeSource(row.id, f.source, f.target, false) }; assertTrue(f.source.deletions.isEmpty())
        var observedUpload = false; f.source.beforeDelete = { observedUpload = f.target.uploads == 1 }
        assertEquals(CrossNasPhase.FINISHED, f.queue.removeSource(row.id, f.source, f.target, true).phase)
        assertEquals(listOf("/source/a.bin"), f.source.deletions); assertTrue(observedUpload)
    }
    @Test fun `unverified target upload retains every source item`() = runBlocking {
        val f = CrossNasFixture(2); val row = f.create(listOf(f.source.file("/source/a.bin")), true)
        f.target.unknownUpload = true; f.target.afterUpload = { f.target.contents["/target/a.bin"] = byteArrayOf(3, 2, 1) }
        failure { f.queue.copy(row.id, f.source, f.target) }
        assertEquals(CrossNasEntryState.WRITE_UNKNOWN, f.store.get(row.id).entries.single().state)
        assertTrue(f.source.deletions.isEmpty()); assertFalse(f.store.get(row.id).canRemoveSource)
    }
    @Test fun `name conflict is rejected before source download starts`() = runBlocking {
        val f = CrossNasFixture(2); val file = f.source.file("/source/a.bin"); f.target.file("/target/a.bin")
        assertEquals(DsmErrorKind.CROSS_NAS_CONFLICT, failure { f.create(listOf(file)) }.kind)
        assertEquals(0, f.source.downloads); assertEquals(0, f.target.opens)
    }
    @Test fun `move without source delete permission performs no upload or delete`() = runBlocking {
        val f = CrossNasFixture(2); val file = f.source.file("/source/a.bin").copy(canDelete = false); f.source.items[file.path] = file
        failure { f.create(listOf(file), true) }
        assertEquals(0, f.source.downloads); assertEquals(0, f.target.opens); assertTrue(f.source.deletions.isEmpty())
    }
    @Test fun `directory move keeps original until independently confirmed and only removes empty folders`() = runBlocking {
        val f = CrossNasFixture(2); val root = f.source.directory("/source/folder"); val child = f.source.file("/source/folder/a.bin")
        val row = f.create(listOf(root), true); f.queue.copy(row.id, f.source, f.target)
        assertEquals(1, f.target.creates); assertTrue(f.source.deletions.isEmpty())
        f.source.beforeDelete = { if (it.isDirectory) assertFalse(f.source.items.containsKey(child.path)) }
        f.queue.removeSource(row.id, f.source, f.target, true)
        assertEquals(listOf(child.path, root.path), f.source.deletions)
    }
    @Test fun `target preflight rejection wakes a blocked source writer`() = runBlocking {
        val f = CrossNasFixture(64); val row = f.create(listOf(f.source.file("/source/a.bin", ByteArray(1024 * 1024))))
        f.target.rejectUpload = true
        withTimeout(2_000) { failure { f.queue.copy(row.id, f.source, f.target) } }
        assertEquals(0, f.target.opens); assertEquals(CrossNasEntryState.PENDING, f.store.get(row.id).entries.single().state)
    }
    @Test fun `directory copy uses the frozen full snapshot`() = runBlocking {
        val f = CrossNasFixture(2); val root = f.source.directory("/source/folder"); f.source.file("/source/folder/a.bin")
        val row = f.create(listOf(root)); val done = f.queue.copy(row.id, f.source, f.target)
        assertEquals(CrossNasPhase.FINISHED, done.phase); assertEquals(2, done.entries.size)
        assertTrue(f.source.deletions.isEmpty()); assertArrayEquals(byteArrayOf(1, 2, 3), f.target.contents["/target/folder/a.bin"])
    }
    @Test fun `cancellation closes both sides of the pipe`() = runBlocking {
        val f = CrossNasFixture(64); val row = f.create(listOf(f.source.file("/source/a.bin", ByteArray(1024 * 1024))))
        f.target.onStreamOpened = { throw CancellationException("synthetic cancellation") }
        var cancelled = false
        try { withTimeout(2_000) { f.queue.copy(row.id, f.source, f.target) } } catch (_: CancellationException) { cancelled = true }
        assertTrue(cancelled); assertEquals(CrossNasEntryState.WRITE_UNKNOWN, f.store.get(row.id).entries.single().state)
    }
    @Test fun `directory child changed after snapshot is not downloaded or reported successful`() = runBlocking {
        val f = CrossNasFixture(2); val root = f.source.directory("/source/folder"); val child = f.source.file("/source/folder/a.bin")
        val row = f.create(listOf(root))
        f.target.beforeCreate = { f.source.items[child.path] = child.copy(modifiedAtEpochSeconds = 999) }
        failure { f.queue.copy(row.id, f.source, f.target) }
        assertEquals(0, f.source.downloads); assertEquals(1, f.target.creates); assertNotEquals(CrossNasPhase.FINISHED, f.store.get(row.id).phase)
    }
    @Test fun `replaced root directory is rejected before a target folder is created`() = runBlocking {
        val f = CrossNasFixture(2); val root = f.source.directory("/source/folder"); val row = f.create(listOf(root))
        // 替换由冻结的修改时间/类型/挂载信息判断，不持久保存账号名称。
        f.source.items[root.path] = root.copy(modifiedAtEpochSeconds = 999)
        failure { f.queue.copy(row.id, f.source, f.target) }; assertEquals(0, f.target.creates)
    }
    @Test fun `directory listing drift between snapshots is rejected before writing`() = runBlocking {
        val f = CrossNasFixture(2); val root = f.source.directory("/source/folder"); val first = f.source.file("/source/folder/a.bin")
        var reads = 0
        f.source.onList = { path, _ -> if (path == root.path && ++reads > 1) {
            f.source.items.remove(first.path); f.source.file("/source/folder/b.bin")
        } }
        failure { f.create(listOf(root)) }; assertEquals(0, f.target.creates); assertEquals(0, f.source.downloads)
    }
    @Test fun `real job cancellation after upload opens remains durably observable as submitted`() = runBlocking {
        val f = CrossNasFixture(64); val row = f.create(listOf(f.source.file("/source/a.bin", ByteArray(1024 * 1024))), true)
        val opened = CompletableDeferred<Unit>(); f.target.onStreamOpened = { opened.complete(Unit) }; f.target.delayUploadMillis = 20
        val job = launch { f.queue.copy(row.id, f.source, f.target) }
        withTimeout(2_000) { opened.await(); job.cancelAndJoin() }
        val stored = CrossNasTransferStore(f.preferences).records(f.source.owner).single()
        assertEquals(CrossNasEntryState.WRITE_UNKNOWN, stored.entries.single().state)
        assertEquals(CrossNasPhase.INTERRUPTED, stored.phase); assertTrue(f.source.deletions.isEmpty()); assertFalse(stored.canContinueCopy)
    }
    private suspend fun failure(block: suspend () -> Any?): DsmFailure {
        try { block(); throw AssertionError("Expected failure") } catch (error: DsmFailure) { return error }
    }
}

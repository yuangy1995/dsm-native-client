package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.CrossNasFixture
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class CrossNasTransferQueueTest {
    @Test fun `file copy preserves content and never deletes source`() = runBlocking {
        val f = CrossNasFixture(); val bytes = ByteArray(512 * 1024) { (it % 251).toByte() }
        val row = f.create(listOf(f.source.file("/source/a.bin", bytes)))
        f.target.delayUploadMillis = 1
        val done = withTimeout(10_000) { f.queue.copy(row.id, f.source, f.target) }
        assertEquals(CrossNasPhase.FINISHED, done.phase); assertArrayEquals(bytes, f.target.contents["/target/a.bin"])
        assertTrue(f.source.deletions.isEmpty()); assertEquals(1, f.target.uploads)
    }
    @Test fun `move requires a separate explicit confirmation after every copy`() = runBlocking {
        val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin"), f.source.file("/source/b.bin")), true)
        val copied = f.queue.copy(row.id, f.source, f.target)
        assertEquals(CrossNasPhase.COPIED, copied.phase); assertTrue(f.source.deletions.isEmpty())
        failure { f.queue.removeSource(row.id, f.source, f.target, false) }; assertTrue(f.source.deletions.isEmpty())
        f.source.beforeDelete = { assertEquals(2, f.target.uploads); assertEquals(CrossNasEntryState.DELETING,
            f.store.get(row.id).entries.single { e -> e.source.path == it.path }.state) }
        assertEquals(CrossNasPhase.FINISHED, f.queue.removeSource(row.id, f.source, f.target, true).phase)
        assertEquals(2, f.source.deletions.size)
    }
    @Test fun `directory move copies frozen tree and removes only empty directories last`() = runBlocking {
        val f = CrossNasFixture(); val root = f.source.directory("/source/folder")
        f.source.directory("/source/folder/sub"); f.source.file("/source/folder/a.bin"); f.source.file("/source/folder/sub/b.bin")
        val row = f.create(listOf(root), true); val copied = f.queue.copy(row.id, f.source, f.target)
        assertEquals(4, copied.entries.size); assertTrue(f.source.deletions.isEmpty())
        assertEquals(CrossNasPhase.FINISHED, f.queue.removeSource(row.id, f.source, f.target, true).phase)
        assertEquals("/source/folder", f.source.deletions.last())
        assertTrue(f.source.deletions.indexOf("/source/folder/sub/b.bin") < f.source.deletions.indexOf("/source/folder/sub"))
    }
    @Test fun `name conflicts and overlapping roots are rejected before any download`() = runBlocking {
        val f = CrossNasFixture(); val file = f.source.file("/source/a.bin"); f.target.file("/target/a.bin")
        assertEquals(DsmErrorKind.CROSS_NAS_CONFLICT, failure { f.create(listOf(file)) }.kind)
        val root = f.source.directory("/source/folder"); val child = f.source.file("/source/folder/b.bin")
        failure { f.create(listOf(root, child)) }; assertEquals(0, f.source.downloads); assertEquals(0, f.target.uploads)
    }
    @Test fun `source permission missing metadata or unknown mount prevents a plan`() = runBlocking {
        for (itemChange in listOf<(FileItem) -> FileItem>({ it.copy(canDelete = false) }, { it.copy(canRead = false) },
            { it.copy(modifiedAtEpochSeconds = null) }, { it.copy(mountPointType = null) })) {
            val f = CrossNasFixture(); val item = itemChange(f.source.file("/source/a.bin")); f.source.items[item.path] = item
            failure { f.create(listOf(item), true) }; assertEquals(0, f.target.uploads); assertTrue(f.source.deletions.isEmpty())
        }
    }
    @Test fun `source child root and listing drift prevent further writes`() = runBlocking {
        val f = CrossNasFixture(); val root = f.source.directory("/source/folder"); f.source.file("/source/folder/a.bin")
        val row = f.create(listOf(root))
        f.source.file("/source/folder/new.bin")
        failure { f.queue.copy(row.id, f.source, f.target) }; assertEquals(0, f.target.creates)
        f.source.items.remove("/source/folder/new.bin"); f.source.items[root.path] = root.copy(modifiedAtEpochSeconds = 101)
        failure { f.queue.copy(row.id, f.source, f.target) }; assertEquals(0, f.target.creates)
        f.source.items[root.path] = root
        f.target.beforeCreate = { f.source.contents["/source/folder/a.bin"] = byteArrayOf(3, 2, 1) }
        failure { f.queue.copy(row.id, f.source, f.target) }; assertEquals(0, f.source.downloads)
        assertEquals(CrossNasEntryState.COPIED, f.store.get(row.id).entries.first().state)
    }
    @Test fun `ending copied move keeps originals and never reopens deletion on refresh`() = runBlocking {
        val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin")), true)
        failure { f.store.keepOriginals(row) }
        val copied = f.queue.copy(row.id, f.source, f.target); val ended = f.store.keepOriginals(copied)
        assertEquals(CrossNasPhase.KEPT, ended.phase); assertTrue(ended.isFinished); assertFalse(ended.canRemoveSource)
        assertEquals(ended, f.queue.review(row.id, f.source, f.target)); assertTrue(f.source.deletions.isEmpty())
        failure { f.store.replace(ended, copied) }; failure { f.queue.removeSource(row.id, f.source, f.target, true) }
        f.store.removeFinished(ended); assertTrue(f.store.records(f.source.owner).isEmpty())
        assertTrue(f.source.items.containsKey("/source/a.bin")); assertTrue(f.target.items.containsKey("/target/a.bin"))
    }
    @Test fun `complete source tree spans every page without truncation`() = runBlocking {
        val f = CrossNasFixture(); val root = f.source.directory("/source/folder")
        repeat(401) { f.source.file("/source/folder/item-${it.toString().padStart(3, '0')}.bin") }
        val offsets = mutableListOf<Int>(); f.source.onList = { path, offset -> if (path == root.path) offsets += offset }
        val row = f.create(listOf(root))
        assertEquals(402, row.entries.size); assertEquals(401, row.entries.count { !it.source.directory })
        assertEquals(listOf(0, 200, 400, 0, 200, 400), offsets)
        assertEquals(0, f.source.downloads); assertEquals(0, f.target.uploads)
    }
    @Test fun `incomplete changing or duplicate pages cannot become empty or complete trees`() = runBlocking {
        for (variant in 0..3) {
            val f = CrossNasFixture(); val root = f.source.directory("/source/folder")
            val children = (0..200).map { f.source.file("/source/folder/f$it") }
            f.source.listOverride = { _, offset, _ -> when (variant) {
                0 -> FilePage(emptyList(), 1, 0)
                1 -> FilePage(children.take(1), 1, 1)
                2 -> if (offset == 0) FilePage(children.take(200), 201, 0) else FilePage(children.takeLast(1), 202, offset)
                else -> if (offset == 0) FilePage(children.take(200), 201, 0) else FilePage(children.take(1), 201, offset)
            } }
            failure { f.create(listOf(root)) }; assertEquals(0, f.target.creates)
        }
    }
    @Test fun `unknown uploaded file is restored only by content and never uploaded again`() = runBlocking {
        val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin")), true)
        f.target.failUploadAfterWrite = true
        failure { f.queue.copy(row.id, f.source, f.target) }
        assertEquals(CrossNasEntryState.WRITE_UNKNOWN, f.store.get(row.id).entries.single().state)
        failure { f.queue.copy(row.id, f.source, f.target) }; assertEquals(1, f.target.uploads)
        f.source.owner = f.source.owner.copy(sessionGeneration = "new")
        val restored = CrossNasTransferQueue(CrossNasTransferStore(f.preferences)).review(row.id, f.source, f.target)
        assertEquals(CrossNasPhase.COPIED, restored.phase); assertEquals(1, f.target.uploads); assertTrue(f.source.deletions.isEmpty())
    }
    @Test fun `unknown folder creation is never adopted by its matching name`() = runBlocking {
        val f = CrossNasFixture(); val row = f.create(listOf(f.source.directory("/source/folder")))
        f.target.failCreateAfterWrite = true
        failure { f.queue.copy(row.id, f.source, f.target) }
        val reviewed = f.queue.review(row.id, f.source, f.target)
        assertEquals(CrossNasEntryState.WRITE_UNKNOWN, reviewed.entries.single().state)
        assertFalse(reviewed.canContinueCopy); assertEquals(1, f.target.creates)
    }
    @Test fun `unknown upload with wrong or absent content retains source and cannot replay`() = runBlocking {
        for (remove in listOf(false, true)) {
            val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin")), true)
            f.target.failUploadAfterWrite = true; failure { f.queue.copy(row.id, f.source, f.target) }
            if (remove) f.target.items.remove("/target/a.bin") else f.target.contents["/target/a.bin"] = byteArrayOf(3, 2, 1)
            failure { f.queue.review(row.id, f.source, f.target) }; failure { f.queue.copy(row.id, f.source, f.target) }
            assertEquals(1, f.target.uploads); assertTrue(f.source.deletions.isEmpty())
        }
    }
    @Test fun `unverified response with exact final bytes can finish copy but never deletes source`() = runBlocking {
        val f = CrossNasFixture(); f.target.unknownUpload = true
        val row = f.create(listOf(f.source.file("/source/a.bin")), true)
        assertEquals(CrossNasPhase.COPIED, f.queue.copy(row.id, f.source, f.target).phase)
        assertTrue(f.source.deletions.isEmpty())
    }
    @Test fun `saving write fact fails before any source download or target creation`() = runBlocking {
        val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin")))
        f.preferences.commitSucceeds = false
        failure { f.queue.copy(row.id, f.source, f.target) }; assertEquals(0, f.target.uploads); assertEquals(0, f.source.downloads)
    }
    @Test fun `target preflight rejection closes a blocked source stream and leaves a resumable item`() = runBlocking {
        val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin", ByteArray(1024 * 1024))))
        f.target.rejectUpload = true
        withTimeout(5_000) { failure { f.queue.copy(row.id, f.source, f.target) } }
        assertEquals(CrossNasEntryState.PENDING, f.store.get(row.id).entries.single().state)
    }
    @Test fun `cancellation closes both pipe ends and retains durable unknown submission`() = runBlocking {
        val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin", ByteArray(1024 * 1024))), true)
        val opened = CompletableDeferred<Unit>(); f.target.beforeUpload = { opened.complete(Unit) }; f.target.delayUploadMillis = 20
        val job = launch { f.queue.copy(row.id, f.source, f.target) }
        withTimeout(5_000) { opened.await(); job.cancelAndJoin() }
        assertEquals(CrossNasEntryState.WRITE_UNKNOWN, f.store.get(row.id).entries.single().state)
        assertTrue(f.source.deletions.isEmpty())
    }
    @Test fun `duplicate running calls and related plans never issue a second write`() = runBlocking {
        val f = CrossNasFixture(); val item = f.source.file("/source/a.bin", ByteArray(512 * 1024)); val row = f.create(listOf(item))
        failure { f.create(listOf(item)) }
        val opened = CompletableDeferred<Unit>(); f.target.beforeUpload = { opened.complete(Unit) }; f.target.delayUploadMillis = 10
        val job = launch { f.queue.copy(row.id, f.source, f.target) }
        withTimeout(5_000) { opened.await(); failure { f.queue.copy(row.id, f.source, f.target) }; job.cancelAndJoin() }
        assertEquals(1, f.target.uploads)
    }
    @Test fun `copied target or source changes stop deletion with no source loss`() = runBlocking {
        for (targetChange in listOf(false, true)) {
            val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin")), true)
            f.queue.copy(row.id, f.source, f.target)
            if (targetChange) f.target.contents["/target/a.bin"] = byteArrayOf(3, 2, 1) else f.source.contents["/source/a.bin"] = byteArrayOf(3, 2, 1)
            failure { f.queue.removeSource(row.id, f.source, f.target, true) }; assertTrue(f.source.deletions.isEmpty())
        }
    }
    @Test fun `new child after copy prevents every source delete`() = runBlocking {
        val f = CrossNasFixture(); val root = f.source.directory("/source/folder"); f.source.file("/source/folder/a.bin")
        val row = f.create(listOf(root), true); f.queue.copy(row.id, f.source, f.target)
        f.source.file("/source/folder/new.bin")
        failure { f.queue.removeSource(row.id, f.source, f.target, true) }; assertTrue(f.source.deletions.isEmpty())
    }
    @Test fun `unknown deletion only checks exact absence and never resends`() = runBlocking {
        val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin")), true)
        f.queue.copy(row.id, f.source, f.target); f.source.deleteWithoutRemoval = true; f.source.unknownDelete = true
        failure { f.queue.removeSource(row.id, f.source, f.target, true) }
        f.queue.review(row.id, f.source, f.target)
        failure { f.queue.removeSource(row.id, f.source, f.target, true) }; assertEquals(1, f.source.deletions.size)
        f.source.items.remove("/source/a.bin")
        assertEquals(CrossNasPhase.FINISHED, f.queue.review(row.id, f.source, f.target).phase)
        assertEquals(1, f.source.deletions.size)
    }
    @Test fun `different identity or revoked access cannot restore either side`() = runBlocking {
        val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin")))
        f.target.owner = f.target.owner.copy(identityRevision = "another")
        failure { f.queue.copy(row.id, f.source, f.target) }; assertEquals(0, f.target.uploads)
        f.target.owner = row.targetOwner; f.source.access = false
        failure { f.queue.copy(row.id, f.source, f.target) }; assertEquals(0, f.target.uploads)
    }
    @Test fun `interrupted process stages normalize to unknown without touching NAS`() = runBlocking {
        val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin")), true)
        f.store.replace(row, row.copy(phase = CrossNasPhase.COPYING, entries = row.entries.map { it.copy(state = CrossNasEntryState.WRITING) }))
        val restored = CrossNasTransferStore(f.preferences).records(f.source.owner).single()
        assertEquals(CrossNasPhase.INTERRUPTED, restored.phase); assertEquals(CrossNasEntryState.WRITE_UNKNOWN, restored.entries.single().state)
        assertEquals(0, f.source.downloads); assertEquals(0, f.target.uploads)
    }
    @Test fun `store preserves original plan and isolates records by both account identities`() = runBlocking {
        val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin")))
        failure { f.store.replace(row, row.copy(targetName = "changed")) }
        assertTrue(f.preferences.all.values.single().toString().contains("\"createdAtSeconds\":${row.createdAtSeconds}"))
        assertTrue(f.store.records(f.source.owner.copy(identityRevision = "another")).isEmpty())
        assertTrue(f.store.records(f.target.owner).isEmpty())
        assertFalse(row.toString().contains("a.bin")); assertFalse(row.entries.single().toString().contains("source"))
        failure { f.store.removeFinished(row) }; f.store.removeProfile("unrelated"); assertEquals(row, f.store.get(row.id))
        f.store.removeProfile(f.target.owner.profileId); assertTrue(f.store.records(f.source.owner).isEmpty())
    }
    @Test fun `source changed during upload is not marked copied or deleted`() = runBlocking {
        val f = CrossNasFixture(); val item = f.source.file("/source/a.bin"); val row = f.create(listOf(item), true)
        f.target.afterUpload = { f.source.contents[item.path] = byteArrayOf(3, 2, 1) }
        failure { f.queue.copy(row.id, f.source, f.target) }
        assertEquals(CrossNasEntryState.WRITE_UNKNOWN, f.store.get(row.id).entries.single().state)
        assertTrue(f.source.deletions.isEmpty()); assertFalse(f.store.get(row.id).canRemoveSource)
    }
    @Test fun `permission revoked after saving but before submission keeps item pending`() = runBlocking {
        val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin")))
        failure { f.queue.copy(row.id, f.source, f.target, onChanged = {
            if (it.entries.single().state == CrossNasEntryState.WRITING) f.target.access = false
        }) }
        assertEquals(0, f.target.uploads); assertEquals(0, f.source.downloads)
        assertEquals(CrossNasEntryState.PENDING, f.store.get(row.id).entries.single().state)
    }
    @Test fun `permission revoked after upload preserves unknown original identity for read only recovery`() = runBlocking {
        val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin")))
        f.target.afterUpload = { f.target.access = false }
        failure { f.queue.copy(row.id, f.source, f.target) }
        assertEquals(CrossNasEntryState.WRITE_UNKNOWN, f.store.get(row.id).entries.single().state)
        assertEquals(row.targetOwner, f.store.get(row.id).targetOwner)
        f.target.access = true
        assertEquals(CrossNasPhase.FINISHED, f.queue.review(row.id, f.source, f.target).phase)
        assertEquals(1, f.target.uploads)
    }
    @Test fun `new child appearing during removal prevents deleting its directory`() = runBlocking {
        val f = CrossNasFixture(); val root = f.source.directory("/source/folder"); f.source.file("/source/folder/a.bin")
        val row = f.create(listOf(root), true); f.queue.copy(row.id, f.source, f.target)
        f.source.beforeDelete = { if (!it.isDirectory) f.source.file("/source/folder/new.bin") }
        failure { f.queue.removeSource(row.id, f.source, f.target, true) }
        assertEquals(listOf("/source/folder/a.bin"), f.source.deletions)
        assertTrue("/source/folder/new.bin" in f.source.items); assertTrue(root.path in f.source.items)
    }
    @Test fun `store cannot relabel unfinished work as success or rewind known submission`() = runBlocking {
        val f = CrossNasFixture(); val row = f.create(listOf(f.source.file("/source/a.bin")))
        failure { f.store.replace(row, row.copy(phase = CrossNasPhase.FINISHED)) }
        val writing = row.copy(phase = CrossNasPhase.COPYING, entries = row.entries.map { it.copy(state = CrossNasEntryState.WRITING) })
        f.store.replace(row, writing)
        val unknown = writing.interrupted(); f.store.replace(writing, unknown)
        failure { f.store.replace(unknown, row) }; assertEquals(unknown, f.store.get(row.id))
    }
    private suspend fun failure(block: suspend () -> Any?): DsmFailure {
        try { block(); throw AssertionError("Expected a domain failure") } catch (error: DsmFailure) { return error }
    }
}

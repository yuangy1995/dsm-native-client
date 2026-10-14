package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoDeletionStoreTest {
    private val owner = WorkspaceOwner("deletion-profile", "identity", "session")
    private val preferences = MemoryPreferences()
    private val store = SynologyPhotoDeletionStore(preferences)
    private fun photo(id: Long = 11) = SynologyPhoto(SynologyPhotoId(owner.profileId, SynologyPhotoSpace.PERSONAL, id),
        "synthetic-secret-name.jpg", 4, 100.25, 101.75, 9, "photo")
    private fun row(count: Int = 2) = SynologyPhotoDeletionRecord(owner = owner, userId = 41,
        entries = (1..count).map { SynologyPhotoDeletionCheckpoint(userId = 41, target = SynologyPhotoDeletionTarget(photo(it.toLong()))) })

    @Test fun `记录只含身份摘要不保存名称日期且每个身份字段都参与匹配`() {
        val photo = photo(); val target = SynologyPhotoDeletionTarget(photo)
        assertTrue(target.matches(photo.copy(description = "new description")))
        val changed = listOf(photo.copy(filename = "changed.jpg"), photo.copy(sizeBytes = 8), photo.copy(takenAt = 101.25),
            photo.copy(indexedAt = 103.75), photo.copy(folderId = 10), photo.copy(mediaType = "video"),
            photo.copy(id = photo.id.copy(itemId = 12)), photo.copy(id = photo.id.copy(space = SynologyPhotoSpace.SHARED)),
            photo.copy(id = photo.id.copy(profileId = "other")))
        changed.forEach { assertFalse(target.matches(it)) }
        val context = photo.copy(albumContext = SynologyPhotoAlbumContext(20, 41, 42))
        assertFalse(target.matches(context)); assertTrue(target.matches(context, includeContext = false))
        val row = row(1); store.begin(row)
        val raw = preferences.all.values.single().toString()
        assertFalse(raw.contains(photo.filename)); assertFalse(raw.contains("100.25")); assertFalse(raw.contains("101.75"))
        assertFalse(row.toString().contains("identity")); assertFalse(row.entries.single().toString().contains(photo.filename))
    }
    @Test fun `提交阶段只允许单调转换冷恢复保留已提交与未发送项`() {
        val row = row(); store.begin(row)
        val first = row.entries.first(); val sent = first.copy(phase = SynologyPhotoDeletionPhase.SUBMITTED)
        store.update(row.id, owner, 41, sent)
        val restored = SynologyPhotoDeletionStore(preferences).records(owner.copy(sessionGeneration = "new-login"), 41).single()
        assertEquals(listOf(SynologyPhotoDeletionPhase.SUBMITTED, SynologyPhotoDeletionPhase.PREPARED), restored.entries.map { it.phase })
        failure { store.update(row.id, owner, 41, first) }
        failure { store.update(row.id, owner, 41, sent.copy(target = SynologyPhotoDeletionTarget(photo(99)))) }
        failure { store.update(row.id, owner, 41, sent.copy(userId = 42)) }
        val done = sent.copy(phase = SynologyPhotoDeletionPhase.CONFIRMED)
        store.update(row.id, owner, 41, done)
        failure { store.update(row.id, owner, 41, sent) }
        failure { store.update(row.id, owner, 41, done.copy(phase = SynologyPhotoDeletionPhase.REJECTED)) }
    }
    @Test fun `不能跳过提交边界未决批次不能覆盖或清除`() {
        val row = row(); store.begin(row)
        failure { store.update(row.id, owner, 41, row.entries.first().copy(phase = SynologyPhotoDeletionPhase.CONFIRMED)) }
        failure { store.update(row.id, owner, 41, row.entries.first().copy(phase = SynologyPhotoDeletionPhase.REJECTED)) }
        failure { store.begin(row()) }; failure { store.discard(row) }
        val cancelled = store.cancelRemaining(row.id, owner, 41)
        assertTrue(cancelled.finished); assertEquals(2, cancelled.count(SynologyPhotoDeletionPhase.CANCELLED))
        store.discard(cancelled); assertTrue(store.records(owner, 41).isEmpty())
        store.begin(row()); assertEquals(1, store.records(owner, 41).size)
    }
    @Test fun `取消剩余不改动已提交和拒绝记录且未知不能取消`() {
        val row = row(3); store.begin(row)
        store.update(row.id, owner, 41, row.entries[0].copy(phase = SynologyPhotoDeletionPhase.SUBMITTED))
        val second = row.entries[1].copy(phase = SynologyPhotoDeletionPhase.SUBMITTED)
        store.update(row.id, owner, 41, second); store.update(row.id, owner, 41, second.copy(phase = SynologyPhotoDeletionPhase.REJECTED))
        val cancelled = store.cancelRemaining(row.id, owner, 41)
        assertEquals(listOf(SynologyPhotoDeletionPhase.SUBMITTED, SynologyPhotoDeletionPhase.REJECTED, SynologyPhotoDeletionPhase.CANCELLED), cancelled.entries.map { it.phase })
        assertFalse(cancelled.finished)
        failure { store.update(row.id, owner, 41, cancelled.entries.first().copy(phase = SynologyPhotoDeletionPhase.CANCELLED)) }
        failure { store.discard(cancelled) }
    }
    @Test fun `单批限制编号去重和身份校验不能绕过`() {
        val base = row()
        for (bad in listOf(base.copy(entries = emptyList()), row(101), base.copy(entries = listOf(base.entries[0], base.entries[0])),
            base.copy(entries = base.entries + base.entries.first().copy(operationId = java.util.UUID.randomUUID().toString())),
            base.copy(entries = base.entries.map { it.copy(userId = 42) }), base.copy(owner = owner.copy(profileId = "other")),
            base.copy(entries = base.entries.map { it.copy(target = it.target.copy(identityDigest = "not-a-digest")) }),
            base.copy(entries = base.entries.map { it.copy(phase = SynologyPhotoDeletionPhase.SUBMITTED) }))) failure { store.begin(bad) }
        assertTrue(preferences.all.isEmpty())
        store.begin(row(100)); assertEquals(100, store.records(owner, 41).single().entries.size)
    }
    @Test fun `同步落盘失败抛错不报告成功且记录保守保留`() {
        val row = row(); store.begin(row); preferences.commitSucceeds = false
        failure { store.update(row.id, owner, 41, row.entries.first().copy(phase = SynologyPhotoDeletionPhase.SUBMITTED)) }
        preferences.commitSucceeds = true
        assertEquals(SynologyPhotoDeletionPhase.SUBMITTED, store.get(row.id, owner, 41).entries.first().phase)
        failure { store.begin(row()) }
    }
    @Test fun `坏记录和未来格式保留原文并阻止修改`() {
        for (key in listOf("photos_deletion_v1_broken", "photos_deletion_v2_broken")) {
            preferences.edit().clear().putString(key, "broken").commit()
            failure { store.records(owner, 41) }; failure { store.begin(row()) }
            assertEquals("broken", preferences.getString(key, null))
        }
    }
    @Test fun `连接账号隔离重登可恢复清理只影响指定连接`() {
        val row = row(); store.begin(row)
        assertTrue(store.records(owner.copy(profileId = "other-nas"), 41).isEmpty())
        assertTrue(store.records(owner.copy(identityRevision = "other-account"), 41).isEmpty())
        assertTrue(store.records(owner, 42).isEmpty())
        assertEquals(row, store.records(owner.copy(sessionGeneration = "new-login"), 41).single())
        store.removeProfile("other-nas"); assertEquals(1, store.records(owner, 41).size)
        store.removeProfile(owner.profileId); assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `并发实例同身份互斥写入期间不允许取消或清理`() = runBlocking {
        val row = row(); store.begin(row)
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val worker = launch(Dispatchers.Default) { store.exclusive(owner, row.id) { entered.complete(Unit); release.await() } }
        entered.await()
        try {
            assertTrue(SynologyPhotoDeletionStore.isProfileBusy(owner.profileId))
            try { SynologyPhotoDeletionStore(preferences).exclusive(owner.copy(sessionGeneration = "new"), "other") {}; fail() }
            catch (error: SynologyPhotoDeletionFailure) { assertEquals(SynologyPhotoDeletionProblem.BUSY, error.problem) }
            failure { store.cancelRemaining(row.id, owner, 41) }; failure { store.removeProfile(owner.profileId) }
            store.exclusive(owner.copy(identityRevision = "different"), "other") {}
        } finally { release.complete(Unit); worker.join() }
        assertFalse(SynologyPhotoDeletionStore.isProfileBusy(owner.profileId))
    }
    private fun failure(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoDeletionFailure) {} }
}

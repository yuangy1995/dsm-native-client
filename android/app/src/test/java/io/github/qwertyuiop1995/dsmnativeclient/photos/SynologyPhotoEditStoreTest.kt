package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoEditStoreTest {
    private val owner = WorkspaceOwner("profile-store", "identity", "session")
    private val preferences = MemoryPreferences()
    private val store = SynologyPhotoEditStore(preferences)
    private fun row() = SynologyPhotoEditRecord(owner = owner, checkpoint = SynologyPhotoEditCheckpoint(
        profileId = owner.profileId, userId = 41, space = SynologyPhotoSpace.PERSONAL,
        targets = listOf(SynologyPhotoEditTarget(SynologyPhoto(SynologyPhotoId(owner.profileId, SynologyPhotoSpace.PERSONAL, 91),
            "synthetic.jpg", 4, 1000.0, 900.0, 9, "photo"))), edit = SynologyPhotoEdit.Rating(3)))

    @Test fun `重启将提交中保留为只读恢复且不允许回退或更换目标`() {
        val row = row(); store.begin(row)
        val submitted = row.checkpoint.copy(phase = SynologyPhotoEditPhase.SUBMITTING, attempted = setOf(0))
        store.save(row.id, owner, 41, submitted)
        val restored = SynologyPhotoEditStore(preferences).records(owner.copy(sessionGeneration = "relogin"), 41).single()
        assertEquals(SynologyPhotoEditPhase.PENDING, restored.checkpoint.phase)
        failure { store.save(row.id, owner, 41, row.checkpoint) }
        failure { store.save(row.id, owner, 41, submitted) }
        failure { store.save(row.id, owner, 41, restored.checkpoint.copy(edit = SynologyPhotoEdit.Rating(4))) }
        val done = restored.checkpoint.copy(phase = SynologyPhotoEditPhase.COMPLETED, completed = setOf(0))
        store.save(row.id, owner, 41, done)
        failure { store.save(row.id, owner, 41, restored.checkpoint) }
    }
    @Test fun `并发实例同账号互斥但其他身份可独立保存`() = runBlocking {
        val row = row(); store.begin(row)
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val other = SynologyPhotoEditStore(preferences)
        val task = launch(Dispatchers.Default) { store.exclusive(owner, row.id) { entered.complete(Unit); release.await() } }
        entered.await()
        try {
            try { other.exclusive(owner.copy(sessionGeneration = "new"), "another") {}; fail() } catch (error: SynologyPhotoEditFailure) { assertEquals(SynologyPhotoEditProblem.BUSY, error.problem) }
            assertTrue(SynologyPhotoEditStore.isProfileBusy(owner.profileId))
            other.exclusive(owner.copy(identityRevision = "different"), "another") { }
            failure { store.removeProfile(owner.profileId) }
        } finally { release.complete(Unit); task.join() }
        assertFalse(SynologyPhotoEditStore.isProfileBusy(owner.profileId))
    }
    @Test fun `重读活跃记录不把当前多组提交变成只读恢复`() = runBlocking {
        val row = row(); store.begin(row)
        store.exclusive(owner, row.id) {
            val started = row.checkpoint.copy(phase = SynologyPhotoEditPhase.SUBMITTING, attempted = setOf(0))
            store.save(row.id, owner, 41, started)
            assertEquals(SynologyPhotoEditPhase.SUBMITTING, SynologyPhotoEditStore(preferences).records(owner, 41).single().checkpoint.phase)
            store.save(row.id, owner, 41, started.copy(phase = SynologyPhotoEditPhase.COMPLETED, completed = setOf(0)))
        }
        Unit
    }
    @Test fun `已绑定标签编号和终态不能替换且不能跳过提交边界`() {
        val row = row().let { it.copy(checkpoint = it.checkpoint.copy(edit = SynologyPhotoEdit.CreateTag("Synthetic tag"))) }
        store.begin(row)
        failure { store.save(row.id, owner, 41, row.checkpoint.copy(phase = SynologyPhotoEditPhase.COMPLETED, attempted = setOf(0), completed = setOf(0), createdTag = SynologyPhotoChoice(51, "Synthetic tag"))) }
        val created = row.checkpoint.copy(phase = SynologyPhotoEditPhase.SUBMITTING, createdTag = SynologyPhotoChoice(51, "Synthetic tag"))
        store.save(row.id, owner, 41, created)
        failure { store.save(row.id, owner, 41, created.copy(createdTag = SynologyPhotoChoice(52, "Synthetic tag"))) }
        failure { store.save(row.id, owner, 41, created.copy(createdTag = null)) }
    }
    @Test fun `未来键和坏记录保留原文并拒绝新修改`() {
        for (key in listOf("photos_edit_v1_broken", "photos_edit_v2_broken")) {
            preferences.edit().clear().putString(key, "invalid").commit()
            failure { store.records(owner, 41) }; failure { store.begin(row()) }
            assertEquals("invalid", preferences.getString(key, null))
        }
    }
    @Test fun `同步落盘失败不能当作成功且读取保留记录`() {
        val row = row(); preferences.commitSucceeds = false
        failure { store.begin(row) }
        preferences.commitSucceeds = true
        assertEquals(row, store.records(owner, 41).single())
        assertFalse(store.records(owner, 41).single().checkpoint.submitted)
    }
    @Test fun `账号与NAS版本隔离删除只影响指定连接`() {
        val row = row(); store.begin(row)
        assertTrue(store.records(owner.copy(profileId = "other-nas"), 41).isEmpty())
        assertTrue(store.records(owner.copy(identityRevision = "other-account"), 41).isEmpty())
        assertTrue(store.records(owner, 42).isEmpty())
        store.removeProfile("other-nas"); assertEquals(1, store.records(owner, 41).size)
        store.removeProfile(owner.profileId); assertTrue(store.records(owner, 41).isEmpty())
    }
    private fun failure(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoEditFailure) { } }
}

package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoFolderSharingModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "folder-sharing-model"
        override val canManageFolderSharing = true
        override val canManageAlbums = true
        var original = SynologyPhotoFolderSharingSnapshot(target, "a".repeat(64), SynologyPhotoFolderLinkAccess.INVITED,
            listOf(SynologyPhotoShareGrant(SynologyPhotoShareMemberId("user", JsonPrimitive(51)), "future-role")), false, true, false)
        val existing = SynologyPhotoShareRecipient(original.members!!.single().id, "Synthetic existing")
        val candidate = SynologyPhotoShareRecipient(SynologyPhotoShareMemberId("group", JsonPrimitive("52")), "Synthetic new")
        var candidates = listOf(candidate); var failRead = false; var failPrepare = false; var failCandidates = false; var pending = false
        var beforeRead: suspend () -> Unit = {}; var beforeWrite: suspend () -> Unit = {}; var beforeCandidates: suspend () -> Unit = {}
        var writes = 0; var reviews = 0; var reads = 0; var last: SynologyPhotoAlbumCheckpoint? = null; var receivedPassword: String? = null
        override suspend fun access() = SynologyPhotoAccess(listOf(SynologyPhotoSpace.SHARED), "synthetic", true)
        override suspend fun photoEditIdentity() = 41L
        override suspend fun folderSharing(folder: SynologyPhotoFolderSnapshot): SynologyPhotoFolderSharing {
            reads++; beforeRead(); if (failRead) throw IOException("Synthetic read")
            return SynologyPhotoFolderSharing(original, listOf(existing), "https://example.invalid/folder")
        }
        override suspend fun folderSharingRecipients(): List<SynologyPhotoShareRecipient> {
            beforeCandidates(); if (failCandidates) throw IOException("Synthetic candidates"); return candidates
        }
        override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) {
            if (failPrepare) throw IOException("Synthetic preflight")
            if (checkpoint.folderSharing!!.change.original != original) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
        }
        override suspend fun performPhotoFolderSharing(checkpoint: SynologyPhotoAlbumCheckpoint, password: String?, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)); beforeWrite(); writes++; last = checkpoint; receivedPassword = password
            return checkpoint.copy(phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED,
                folderSharing = checkpoint.folderSharing!!.copy(updateAttempted = true, updateAcknowledged = true,
                    configAttempted = checkpoint.folderSharing.change.appliesToSubfolders != checkpoint.folderSharing.change.original.appliesToSubfolders)).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews++; return checkpoint.copy(phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED).also(save)
        }
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = emptyList<SynologyPhotoDay>()
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) = SynologyPhotoPage(emptyList(), offset, offset, false)
    }
    private class Fixture {
        val api = Api(); val preferences = MemoryPreferences(); val store = SynologyPhotoAlbumStore(preferences)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner(api.profileId, "identity", "session")
        var management = true; var allowed = true; var current = true; var beforeWrite: suspend () -> Unit = {}
        fun model() = SynologyPhotoFolderSharingModel(api, scope, store, owner, { if (!current) throw CancellationException() },
            { SynologyPhotoAccess(listOf(SynologyPhotoSpace.SHARED), "synthetic", management) }, { allowed }, { beforeWrite() })
        val model = model()
        suspend fun open() { model.open(target.collection()); ready(model) }
    }
    @Test fun `只读打开零写无改动不能保存已存在未知角色保持`() = runBlocking { fixture { f ->
        f.open(); assertEquals(0, f.api.writes); assertFalse(f.model.canSave); assertNull(f.model.save())
        assertEquals("future-role", f.model.state.value.members!!.single().role)
        f.model.dismiss(); assertNull(f.model.state.value.original); assertEquals(0, f.api.writes)
    } }
    @Test fun `仅管理共享前两层可进入第二层继承限制只读`() = runBlocking { fixture { f ->
        assertFalse(f.model.canOpen(target.copy(path = "/", name = "/").collection()))
        assertFalse(f.model.canOpen(target.copy(path = "/A/B/C", name = "C").collection()))
        assertFalse(f.model.canOpen(target.copy(space = SynologyPhotoSpace.PERSONAL).collection()))
        f.management = false; f.model.open(target.collection()); assertFalse(f.model.state.value.visible)
        f.management = true; f.api.original = f.api.original.copy(folder = target.copy(path = "/Parent/Synthetic"), parentIsShared = false)
        f.open(); assertFalse(f.model.state.value.canEdit); f.model.access(SynologyPhotoFolderLinkAccess.DOWNLOAD)
        assertEquals(SynologyPhotoFolderLinkAccess.INVITED, f.model.state.value.access); assertFalse(f.model.canSave)
    } }
    @Test fun `普通换密直接保存Unicode不修剪且完成清除内存`() = runBlocking { fixture { f ->
        f.open(); f.model.passwordMode(SynologyPhotoSharingPassword.SET); assertFalse(f.model.canSave)
        val secret = "  合成 🔑  "; f.model.password(secret); assertTrue(f.model.canSave)
        f.model.save()!!.join(); assertEquals(secret, f.api.receivedPassword); assertEquals(1, f.api.writes)
        assertTrue(f.model.state.value.password.isEmpty()); assertNull(f.model.state.value.original); assertTrue(f.model.state.value.recordsPage)
        assertFalse(f.preferences.all.values.toString().contains(secret)); assertTrue(f.store.records(f.owner, 41).single().checkpoint.finished)
    } }
    @Test fun `访问成员移除密码和子目录覆盖都需明确确认取消零写入`() = runBlocking {
        for (mode in 0..3) fixture { f ->
            f.open()
            when (mode) { 0 -> f.model.access(SynologyPhotoFolderLinkAccess.DOWNLOAD); 1 -> f.model.role(f.api.existing.id, "manage")
                2 -> f.model.passwordMode(SynologyPhotoSharingPassword.REMOVE); 3 -> f.model.applyToSubfolders(true) }
            assertNull(f.model.save()); assertNotNull(f.model.state.value.confirmation); assertEquals(0, f.api.writes)
            val frozen = f.model.state.value.change
            f.model.access(SynologyPhotoFolderLinkAccess.VIEW); assertEquals(frozen, f.model.state.value.change)
            f.model.cancelConfirmation(); assertNull(f.model.confirm()); assertEquals(0, f.api.writes)
            f.model.save(); f.model.confirm()!!.join(); assertEquals(1, f.api.writes); assertEquals(frozen, f.api.last!!.folderSharing!!.change)
        }
    }
    @Test fun `第一层默认从开启改为关闭不覆盖子目录可直接保存`() = runBlocking { fixture { f ->
        f.api.original = f.api.original.copy(appliesToSubfolders = true); f.open(); f.model.applyToSubfolders(false)
        assertTrue(f.model.canSave); f.model.save()!!.join(); assertEquals(false, f.api.last!!.folderSharing!!.change.appliesToSubfolders)
    } }
    @Test fun `第二层不能改隐藏默认选项`() = runBlocking { fixture { f ->
        f.api.original = f.api.original.copy(folder = target.copy(path = "/Parent/Synthetic")); f.open()
        f.model.applyToSubfolders(true); assertFalse(f.model.state.value.appliesToSubfolders); assertFalse(f.model.canSave)
    } }
    @Test fun `读取与预检失败可恢复且没有假提交密码需要重填`() = runBlocking { fixture { f ->
        f.api.failRead = true; f.open(); assertNotNull(f.model.state.value.error); assertNull(f.model.state.value.original)
        f.api.failRead = false; f.model.load()!!.join(); f.model.passwordMode(SynologyPhotoSharingPassword.SET); f.model.password("Synthetic")
        f.api.failPrepare = true; f.model.save()!!.join(); assertEquals(0, f.api.writes); assertTrue(f.store.records(f.owner, 41).isEmpty())
        assertTrue(f.model.state.value.password.isEmpty()); f.api.failPrepare = false; f.model.password("Synthetic again"); f.model.save()!!.join(); assertEquals(1, f.api.writes)
    } }
    @Test fun `成员加载失败空内容搜索添加去重移除和四角色使用实际候选`() = runBlocking { fixture { f ->
        f.open(); f.api.failCandidates = true; f.model.selectMembers()!!.join(); assertNotNull(f.model.state.value.membersError)
        f.api.failCandidates = false; f.api.candidates = emptyList(); f.model.selectMembers()!!.join(); assertEquals(emptyList<SynologyPhotoShareRecipient>(), f.model.state.value.candidates)
        f.model.dismiss(); f.api.candidates = listOf(f.api.candidate); f.open(); f.model.selectMembers()!!.join()
        f.model.search("not found"); assertEquals("not found", f.model.state.value.search)
        f.model.add(f.api.candidate.copy(name = "Unlisted")); assertEquals(1, f.model.state.value.members!!.size)
        f.model.add(f.api.candidate); f.model.add(f.api.candidate); assertEquals(2, f.model.state.value.members!!.size)
        for (role in SynologyPhotoFolderSharingModel.roles) { f.model.role(f.api.candidate.id, role); assertEquals(role, f.model.state.value.members!!.last().role) }
        f.model.role(f.api.candidate.id, "future"); assertEquals("manage", f.model.state.value.members!!.last().role)
        f.model.remove(f.api.candidate.id); assertEquals(1, f.model.state.value.members!!.size); f.model.closeMembers(); assertFalse(f.model.state.value.selectingMembers)
        assertEquals(0, f.api.writes)
    } }
    @Test fun `关闭或撤销后迟到表单和候选不能恢复敏感显示`() = runBlocking {
        for (members in listOf(false, true)) fixture { f ->
            val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            val hold: suspend () -> Unit = { started.complete(Unit); withContext(NonCancellable) { release.await() } }
            if (members) { f.open(); f.api.beforeCandidates = hold; f.model.selectMembers() } else { f.api.beforeRead = hold; f.model.open(target.collection()) }
            started.await(); f.model.revokeAccess(); release.complete(Unit); delay(40)
            assertFalse(f.model.state.value.visible); assertNull(f.model.state.value.original); assertNull(f.model.state.value.candidates)
        }
    }
    @Test fun `关闭正在保存页面仍保留互斥并阻止重复确认`() = runBlocking { fixture { f ->
        val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeWrite = { started.complete(Unit); release.await() }
        f.open(); f.model.access(SynologyPhotoFolderLinkAccess.VIEW); f.model.save()
        val worker = f.model.confirm()!!; started.await(); f.model.dismiss()
        assertTrue(SynologyPhotoAlbumStore.isProfileBusy(f.owner.profileId)); assertFalse(f.model.state.value.visible); assertNull(f.model.confirm()); assertNull(f.model.save())
        release.complete(Unit); worker.join(); assertEquals(1, f.api.writes); assertTrue(f.store.records(f.owner, 41).single().checkpoint.finished)
    } }
    @Test fun `未知操作冷热恢复只能读取不可清除且归属变化隔离`() = runBlocking { fixture { f ->
        f.api.pending = true; f.open(); f.model.access(SynologyPhotoFolderLinkAccess.VIEW); f.model.save(); f.model.confirm()!!.join()
        val id = f.model.state.value.records.single().id
        f.model.resume(id)!!.join(); assertEquals(1, f.api.writes); assertEquals(1, f.api.reviews)
        f.model.discard(id)!!.join(); assertEquals(1, f.store.records(f.owner, 41).size)
        try { f.model.requireNoPending(); fail() } catch (e: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.PENDING, e.problem) }
        assertTrue(f.store.records(f.owner.copy(identityRevision = "other"), 41).isEmpty())
        val cold = f.model()
        try { cold.showRecords(); await { cold.state.value.records.size == 1 }; f.api.pending = false; cold.resume(id)!!.join()
            assertTrue(cold.state.value.records.single().checkpoint.finished); assertEquals(1, f.api.writes); assertEquals(2, f.api.reviews)
        } finally { cold.close() }
    } }
    @Test fun `未提交恢复需重新输入密码并重新确认不能自动保存`() = runBlocking { fixture { f ->
        val change = SynologyPhotoFolderSharingChange(f.api.original, SynologyPhotoFolderLinkAccess.VIEW, password = SynologyPhotoSharingPassword.SET)
        val row = SynologyPhotoAlbumRecord(owner = f.owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = f.owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.SHARE_FOLDER, folderSharing = SynologyPhotoFolderSharingCheckpoint(change)))
        f.store.begin(row); f.model.showRecords(); await { f.model.state.value.records.size == 1 }; f.model.resume(row.id)!!.join()
        assertEquals(SynologyPhotoSharingPassword.SET, f.model.state.value.passwordMode); assertFalse(f.model.canSave); assertEquals(0, f.api.writes)
        f.model.password("Synthetic resumed"); f.model.save(); assertNotNull(f.model.state.value.confirmation); f.model.confirm()!!.join()
        assertEquals(1, f.api.writes); assertEquals(1, f.store.records(f.owner, 41).size); assertNotEquals(row.id, f.api.last!!.operationId)
    } }
    @Test fun `恢复草稿原权限已改变不得套用旧更改`() = runBlocking { fixture { f ->
        val row = SynologyPhotoAlbumRecord(owner = f.owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = f.owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.SHARE_FOLDER, folderSharing = SynologyPhotoFolderSharingCheckpoint(SynologyPhotoFolderSharingChange(f.api.original, SynologyPhotoFolderLinkAccess.VIEW))))
        f.store.begin(row); f.api.original = f.api.original.copy(revision = "b".repeat(64))
        f.model.showRecords(); await { f.model.state.value.records.size == 1 }; f.model.resume(row.id)!!.join()
        assertNotNull(f.model.state.value.error); assertFalse(f.model.canSave); assertEquals(0, f.api.writes)
    } }
    @Test fun `跨功能前置保护和失去管理权阻止保存`() = runBlocking { fixture { f ->
        f.open(); f.model.passwordMode(SynologyPhotoSharingPassword.SET); f.model.password("Synthetic")
        f.beforeWrite = { throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING) }; f.model.save()!!.join()
        assertEquals(0, f.api.writes); assertTrue(f.store.records(f.owner, 41).isEmpty())
        f.model.password("Synthetic"); f.management = false; assertFalse(f.model.canSave); assertNull(f.model.save())
    } }
    @Test fun `生产组合根权限写后保留图库位置且冷记录阻止相册操作`() = runBlocking { fixture { f ->
        val library = SynologyPhotosModel(f.api, f.scope, uploadOwner = f.owner, albumStore = f.store)
        try {
            library.activate(); await { library.state.value.loaded && !library.state.value.loading }
            val before = library.state.value.navigation; val sharing = library.folderSharing!!
            sharing.open(target.collection()); ready(sharing); sharing.access(SynologyPhotoFolderLinkAccess.VIEW)
            f.api.pending = true; sharing.save(); sharing.confirm()!!.join(); assertEquals(before, library.state.value.navigation)
            try { library.albums!!.requireNoPending(); fail() } catch (e: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.PENDING, e.problem) }
            library.albums!!.refreshRecords()!!.join(); assertTrue(library.albums.state.value.records.isEmpty())
            library.revokeAccess(); assertNull(sharing.state.value.original); assertFalse(sharing.state.value.visible)
        } finally { library.close() }
    } }
    companion object {
        private val target = SynologyPhotoFolderSnapshot(9, 1, "Synthetic", "/Synthetic", SynologyPhotoSpace.SHARED)
        private suspend fun ready(model: SynologyPhotoFolderSharingModel) { await { !model.state.value.loading } }
        private suspend fun await(condition: () -> Boolean) { withTimeout(5_000) { while (!condition()) delay(5) } }
        private suspend fun fixture(block: suspend (Fixture) -> Unit) {
            val f = Fixture(); try { block(f) } finally { f.model.close(); f.scope.coroutineContext[Job]!!.cancelAndJoin() }
        }
    }
}

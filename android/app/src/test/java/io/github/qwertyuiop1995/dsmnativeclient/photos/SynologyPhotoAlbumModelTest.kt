package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoAlbumModelTest {
    @Test fun `打开管理仅加载权限确认按钮之前零写`() = runBlocking {
        fixture { f ->
            f.model.manage(71); await { f.model.state.value.access != null }
            assertTrue(f.model.state.value.access!!.canManage); assertEquals(0, f.api.writes)
            f.model.open(SynologyPhotoAlbumAction.RENAME, albumId = 71); ready(f)
            assertEquals("Synthetic album", f.model.state.value.draft!!.name)
            f.model.setName("New"); f.model.save()!!.join()
            assertTrue(f.model.state.value.records.single().checkpoint.finished)
            assertEquals("New", f.model.state.value.records.single().checkpoint.name)
        }
    }
    @Test fun `当前相册读取失败不能保存且重试恢复实际目标`() = runBlocking {
        fixture { f ->
            f.api.failAccess = true; f.model.open(SynologyPhotoAlbumAction.DELETE, albumId = 71); ready(f)
            assertNotNull(f.model.state.value.error); assertNull(f.model.save()); assertEquals(0, f.api.writes)
            f.api.failAccess = false; f.model.retryAccess(); ready(f)
            f.model.save()!!.join(); assertEquals(1, f.api.writes)
        }
    }
    @Test fun `写入中重复确认被阻止且全局切换锁在结束后释放`() = runBlocking {
        fixture { f ->
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            f.api.beforeWrite = { entered.complete(Unit); release.await() }
            f.model.open(SynologyPhotoAlbumAction.CREATE); f.model.setName("New")
            val task = f.model.save()!!; entered.await()
            assertTrue(SynologyPhotoAlbumStore.isProfileBusy(owner.profileId)); assertNull(f.model.save())
            release.complete(Unit); task.join()
            assertFalse(SynologyPhotoAlbumStore.isProfileBusy(owner.profileId)); assertEquals(1, f.api.writes)
        }
    }
    @Test fun `重开同账号只回读提交记录换账号不显示`() = runBlocking {
        fixture { f ->
            f.api.pending = true; f.model.open(SynologyPhotoAlbumAction.CREATE); f.model.setName("New"); f.model.save()!!.join()
            val id = f.model.state.value.records.single().id; f.model.close()
            val restored = SynologyPhotoAlbumModel(f.api, f.scope, SynologyPhotoAlbumStore(f.preferences), owner.copy(sessionGeneration = "new"), {}, { true }, onCompleted = {})
            try {
                restored.showRecords(); await { restored.state.value.records.isNotEmpty() }
                assertEquals(1, f.api.writes)
                f.api.pending = false; restored.resume(id)!!.join()
                assertTrue(restored.state.value.records.single().checkpoint.finished)
                assertEquals(1, f.api.writes); assertEquals(1, f.api.reviews)
                assertTrue(f.store.records(owner.copy(identityRevision = "other"), 41).isEmpty())
            } finally { restored.close() }
        }
    }
    @Test fun `撤权取消后保留已提交事实并清空界面`() = runBlocking {
        fixture { f ->
            val entered = CompletableDeferred<Unit>(); f.api.beforeWrite = { entered.complete(Unit); awaitCancellation() }
            f.model.open(SynologyPhotoAlbumAction.CREATE); f.model.setName("New")
            val task = f.model.save()!!; entered.await(); f.model.revokeAccess(); task.join()
            assertFalse(f.model.state.value.visible); assertTrue(f.model.state.value.records.isEmpty())
            assertEquals(SynologyPhotoAlbumPhase.PENDING, f.store.records(owner, 41).single().checkpoint.phase)
            assertFalse(SynologyPhotoAlbumStore.isProfileBusy(owner.profileId))
        }
    }
    @Test fun `部分失败继续仅保留未完成照片原相册并重新确认`() = runBlocking {
        fixture { f ->
            val second = f.api.photo.copy(id = f.api.photo.id.copy(itemId = 92))
            val row = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId,
                userId = 41, action = SynologyPhotoAlbumAction.ADD, album = f.api.access.album,
                targets = listOf(f.api.photo, second).map(::SynologyPhotoEditTarget)))
            f.store.begin(row); f.store.save(row.id, owner, 41, row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
            f.store.save(row.id, owner, 41, row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PARTIAL, completed = setOf(0), membershipHasFailures = true))
            f.model.refreshRecords()!!.join(); f.model.continueRemaining(row.id); ready(f)
            val draft = f.model.state.value.draft!!
            assertEquals(listOf(second.id), draft.photos.map { it.id }); assertEquals(71L, draft.albumId)
            assertNotEquals(row.id, draft.id); assertEquals(0, f.api.writes); assertFalse(f.model.state.value.moreAlbums)
        }
    }
    @Test fun `贡献目标选择用实际列表随后读取权限而不把所有可见相册当目标`() = runBlocking {
        fixture { f ->
            f.model.open(SynologyPhotoAlbumAction.ADD, listOf(f.api.photo))
            await { f.model.state.value.albums.isNotEmpty() }
            f.model.selectAlbum(99); assertNull(f.model.state.value.draft!!.albumId)
            f.model.selectAlbum(71); ready(f)
            assertEquals(f.api.access.album, f.model.state.value.draft!!.album)
            assertEquals(0, f.api.writes)
        }
    }
    @Test fun `持久未决相册阻止涉及成员和同相册上传但不阻止无关照片`() = runBlocking {
        fixture { f ->
            pending(f, SynologyPhotoAlbumAction.DELETE)
            try { f.model.requireNoPending(albumId = 71); fail() } catch (error: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.PENDING, error.problem) }
            try { f.model.requireNoPending(f.api.photo.copy(albumContext = SynologyPhotoAlbumContext(71, 41))); fail() } catch (_: SynologyPhotoAlbumFailure) { }
            f.model.requireNoPending(f.api.photo)
            f.model.requireNoPending(albumId = 72)
            assertTrue(f.model.state.value.records.isEmpty()); assertEquals(0, f.api.writes)
        }
    }
    @Test fun `未知创建没有相册编号时不误阻止无关照片`() = runBlocking {
        fixture { f ->
            pending(f, SynologyPhotoAlbumAction.CREATE)
            f.model.requireNoPending(f.api.photo); assertEquals(0, f.api.writes)
        }
    }
    @Test fun `外部未决编辑保护在初次确认和未发送恢复前执行`() = runBlocking {
        fixture { f ->
            f.guard = { throw SynologyPhotoEditFailure(SynologyPhotoEditProblem.PENDING) }
            f.model.open(SynologyPhotoAlbumAction.CREATE, listOf(f.api.photo)); f.model.setName("New"); f.model.save()!!.join()
            assertEquals(0, f.api.writes); assertTrue(f.model.state.value.error is SynologyPhotoEditFailure)
            val row = f.model.state.value.records.single()
            assertFalse(row.checkpoint.submitted)
            f.model.resume(row.id)!!.join(); assertEquals(0, f.api.writes)
            f.guard = {}; f.model.resume(row.id)!!.join(); assertEquals(1, f.api.writes)
        }
    }
    @Test fun `损坏记录不当作空白且未知记录不可删除`() = runBlocking {
        fixture { f ->
            f.preferences.edit().putString("photos_album_v2_future", "invalid").commit()
            f.model.open(SynologyPhotoAlbumAction.CREATE); f.model.setName("New"); f.model.save()!!.join()
            assertTrue(f.model.state.value.error is SynologyPhotoAlbumFailure); assertEquals(0, f.api.writes)
            assertEquals("invalid", f.preferences.getString("photos_album_v2_future", null))
        }
        fixture { f ->
            val row = pending(f, SynologyPhotoAlbumAction.DELETE)
            f.model.refreshRecords()!!.join(); f.model.discard(row.id)!!.join()
            assertEquals(1, f.model.state.value.records.size); assertEquals(0, f.api.writes)
        }
    }
    @Test fun `其他写任务期间不能开启相册操作且清除完成记录不写NAS`() = runBlocking {
        fixture { f ->
            f.allowed = false; f.model.open(SynologyPhotoAlbumAction.CREATE); assertFalse(f.model.state.value.visible)
            f.allowed = true; f.model.open(SynologyPhotoAlbumAction.CREATE); f.model.setName("New"); f.model.save()!!.join()
            f.model.discard(f.model.state.value.records.single().id)!!.join()
            assertTrue(f.model.state.value.records.isEmpty()); assertEquals(1, f.api.writes)
        }
    }
    @Test fun `冻结信息读取失败仍可删除容器但不能保存或重建`() = runBlocking {
        fixture { f ->
            f.api.makeFrozen(); f.api.failFrozen = true
            f.model.manage(71); ready(f)
            assertNotNull(f.model.state.value.access); assertNotNull(f.model.state.value.error); assertNull(f.model.state.value.frozen)
            f.model.open(SynologyPhotoAlbumAction.UNFREEZE, albumId = 71); ready(f)
            assertNull(f.model.save()); assertEquals(0, f.api.writes)
            f.model.open(SynologyPhotoAlbumAction.DELETE, albumId = 71); ready(f)
            assertNull(f.model.state.value.error); f.model.save()!!.join(); assertEquals(1, f.api.writes)
        }
    }
    @Test fun `冻结重建加载真实规则摘要并且未决记录同时保护新旧相册`() = runBlocking {
        fixture { f ->
            f.api.makeFrozen(); f.api.pending = true
            f.model.manage(71); ready(f); assertTrue(f.model.state.value.frozen!!.canRebuild)
            f.model.open(SynologyPhotoAlbumAction.REBUILD_FROZEN, albumId = 71); ready(f)
            assertEquals("Synthetic album", f.model.state.value.draft!!.name)
            assertNotNull(f.model.conditions.state.value.condition); assertNull(f.model.state.value.draft!!.originalCondition)
            f.model.save()!!.join()
            val record = f.model.state.value.records.single().checkpoint
            assertNotNull(record.frozenSnapshot); assertEquals(72L, record.createdAlbumId); assertTrue(record.condition!!.names.isEmpty())
            for (id in listOf(71L, 72L)) {
                try { f.model.requireNoPending(albumId = id); fail() } catch (_: SynologyPhotoAlbumFailure) {}
                try { f.model.requireNoPending(f.api.photo.copy(albumContext = SynologyPhotoAlbumContext(id, 41))); fail() } catch (_: SynologyPhotoAlbumFailure) {}
            }
            f.model.requireNoPending(albumId = 73)
        }
    }
    @Test fun `不支持重建的冻结规则不能通过模型直接保存重建`() = runBlocking {
        fixture { f ->
            f.api.makeFrozen(); f.api.frozen = f.api.frozen!!.copy(rebuildCondition = null)
            f.model.open(SynologyPhotoAlbumAction.REBUILD_FROZEN, albumId = 71); ready(f)
            assertNull(f.model.save()); assertEquals(0, f.api.writes)
            f.model.open(SynologyPhotoAlbumAction.UNFREEZE, albumId = 71); ready(f)
            f.model.save()!!.join(); assertTrue(f.model.state.value.records.single().checkpoint.finished)
        }
    }
    private fun pending(f: Fixture, action: SynologyPhotoAlbumAction): SynologyPhotoAlbumRecord {
        val row = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = action, album = f.api.access.album.takeIf { action != SynologyPhotoAlbumAction.CREATE }, name = "New".takeIf { action == SynologyPhotoAlbumAction.CREATE }))
        f.store.begin(row); f.store.save(row.id, owner, 41, row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        return row
    }
    @Test fun `共享密码只在本次操作持有关闭清空且恢复文件不包含秘密`() = runBlocking {
        fixture { f ->
            f.model.open(SynologyPhotoAlbumAction.SHARE, albumId = 71); ready(f)
            f.model.sharing.passwordMode(SynologyPhotoSharingPassword.SET); f.model.sharing.password("synthetic-secret")
            f.model.dismiss(); assertEquals("", f.model.sharing.state.value.password)
            f.model.open(SynologyPhotoAlbumAction.SHARE, albumId = 71); ready(f)
            f.model.sharing.passwordMode(SynologyPhotoSharingPassword.SET); f.model.sharing.password("synthetic-secret")
            f.model.save()!!.join()
            assertEquals("synthetic-secret", f.api.receivedPassword); assertEquals("", f.model.sharing.state.value.password)
            assertFalse(f.preferences.all.values.any { it.toString().contains("synthetic-secret") })
            assertTrue(f.model.state.value.records.single().checkpoint.finished)
        }
    }
    @Test fun `未发送改密恢复重新读取并在明确保存后替换旧记录`() = runBlocking {
        fixture { f ->
            f.guard = { throw IOException("synthetic preflight failure") }
            f.model.open(SynologyPhotoAlbumAction.SHARE, albumId = 71); ready(f)
            f.model.sharing.passwordMode(SynologyPhotoSharingPassword.SET); f.model.sharing.password("synthetic-secret")
            f.model.save()!!.join(); val old = f.model.state.value.records.single()
            assertFalse(old.checkpoint.submitted); assertEquals(0, f.api.writes)
            f.model.resume(old.id)!!.join(); ready(f)
            assertEquals(SynologyPhotoAlbumPage.FORM, f.model.state.value.page)
            assertEquals("", f.model.sharing.state.value.password); assertEquals(old.id, f.model.state.value.draft!!.replacesRecordId)
            assertEquals(old.id, f.store.records(owner, 41).single().id)
            f.guard = {}; f.model.sharing.passwordMode(SynologyPhotoSharingPassword.SET); f.model.sharing.password("new-synthetic")
            f.model.save()!!.join()
            assertEquals(1, f.api.writes); assertEquals("new-synthetic", f.api.receivedPassword)
            assertNotEquals(old.id, f.store.records(owner, 41).single().id)
        }
    }
    @Test fun `共享读取重试不能复用失败前的草稿或密码`() = runBlocking {
        fixture { f ->
            f.model.open(SynologyPhotoAlbumAction.SHARE, albumId = 71); ready(f)
            f.model.sharing.passwordMode(SynologyPhotoSharingPassword.SET); f.model.sharing.password("synthetic-secret")
            f.api.failSharing = true; f.model.retryAccess(); ready(f)
            assertNull(f.model.sharing.state.value.original); assertEquals("", f.model.sharing.state.value.password)
            assertNull(f.model.save()); assertEquals(0, f.api.writes)
            f.api.failSharing = false; f.model.retryAccess(); ready(f)
            assertNotNull(f.model.sharing.state.value.original)
        }
    }
    @Test fun `临时分享创建后进入真实设置关闭准备自动清理且记录先保存`() = runBlocking {
        fixture { f ->
            f.model.open(SynologyPhotoAlbumAction.CREATE_TEMPORARY, listOf(f.api.photo)); f.model.setName("Synthetic temporary")
            f.model.save()!!.join(); await { f.model.sharing.state.value.original != null && !f.model.state.value.loading }
            assertEquals(SynologyPhotoAlbumAction.SHARE, f.model.state.value.draft!!.action)
            assertNotNull(f.model.state.value.temporaryPreparationId); assertEquals(1, f.api.writes)
            f.model.dismiss(); await { !f.model.state.value.working && f.api.writes == 2 }
            assertEquals(listOf(SynologyPhotoAlbumAction.CREATE_TEMPORARY, SynologyPhotoAlbumAction.STOP_TEMPORARY), f.api.actions)
            assertTrue(f.store.records(owner, 41).none { it.checkpoint.action == SynologyPhotoAlbumAction.CREATE_TEMPORARY })
            assertFalse(f.model.state.value.visible)
        }
    }
    @Test fun `创建中取消意图落盘并在返回可靠编号后只清理一次`() = runBlocking {
        fixture { f ->
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            f.api.beforeWrite = { entered.complete(Unit); release.await() }
            f.model.open(SynologyPhotoAlbumAction.CREATE_TEMPORARY, listOf(f.api.photo)); f.model.setName("Synthetic temporary")
            val task = f.model.save()!!; entered.await(); f.model.dismiss()
            await { f.store.records(owner, 41).single().checkpoint.temporaryCancelRequested }
            assertTrue(f.model.state.value.temporaryCancelRequested); release.complete(Unit); task.join()
            await { !f.model.state.value.working && f.api.writes == 2 }
            assertEquals(1, f.api.actions.count { it == SynologyPhotoAlbumAction.STOP_TEMPORARY })
            assertNull(f.model.state.value.temporaryPreparationId)
        }
    }
    @Test fun `临时分享创建未知后取消和冷恢复只读不自动清理`() = runBlocking {
        fixture { f ->
            f.api.pending = true
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            f.api.beforeWrite = { entered.complete(Unit); release.await() }
            f.model.open(SynologyPhotoAlbumAction.CREATE_TEMPORARY, listOf(f.api.photo)); f.model.setName("Synthetic temporary")
            val task = f.model.save()!!; entered.await(); f.model.cancelTemporaryCreation(); release.complete(Unit); task.join()
            val row = f.store.records(owner, 41).single(); assertTrue(row.checkpoint.temporaryCancelRequested)
            f.model.close(); f.api.pending = false
            val restored = SynologyPhotoAlbumModel(f.api, f.scope, f.store, owner.copy(sessionGeneration = "new"), {}, { true }, onCompleted = {})
            try {
                restored.showRecords(); await { restored.state.value.records.isNotEmpty() }; restored.resume(row.id)!!.join()
                assertEquals(1, f.api.writes); assertEquals(1, f.api.reviews)
                assertTrue(restored.state.value.records.single().checkpoint.finished)
                assertEquals(SynologyPhotoAlbumPage.RECORDS, restored.state.value.page)
            } finally { restored.close() }
        }
    }
    @Test fun `准备取消时成员变化保留对象并显示恢复错误`() = runBlocking {
        fixture { f ->
            f.model.open(SynologyPhotoAlbumAction.CREATE_TEMPORARY, listOf(f.api.photo)); f.model.setName("Synthetic temporary")
            f.model.save()!!.join(); await { f.model.sharing.state.value.original != null && !f.model.state.value.loading }
            f.api.temporaryDigest = "d".repeat(64); f.model.dismiss()
            await { !f.model.state.value.working && f.model.state.value.error != null }
            assertEquals(1, f.api.writes); assertTrue(f.model.state.value.visible)
            assertEquals(1, f.store.records(owner, 41).size)
            assertTrue(f.store.records(owner, 41).single().checkpoint.temporaryCancelRequested)
        }
    }
    @Test fun `分享设置完成后结束准备且关闭窗口不再清理`() = runBlocking {
        fixture { f ->
            f.model.open(SynologyPhotoAlbumAction.CREATE_TEMPORARY, listOf(f.api.photo)); f.model.setName("Synthetic temporary")
            f.model.save()!!.join(); await { f.model.sharing.state.value.original != null && !f.model.state.value.loading }
            f.model.save()!!.join(); assertNull(f.model.state.value.temporaryPreparationId)
            assertEquals(listOf(SynologyPhotoAlbumAction.CREATE_TEMPORARY, SynologyPhotoAlbumAction.SHARE), f.api.actions)
            assertEquals(SynologyPhotoAlbumAction.SHARE, f.store.records(owner, 41).single().checkpoint.action)
            f.model.dismiss(); delay(20); assertEquals(2, f.api.writes)
        }
    }
    private class Fixture {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val preferences = MemoryPreferences(); val store = SynologyPhotoAlbumStore(preferences); val api = AlbumServing()
        var allowed = true; var guard: suspend () -> Unit = {}
        val model = SynologyPhotoAlbumModel(api, scope, store, owner, {}, { allowed }, beforeWrite = { _, _ -> guard() },
            sourceAccess = { SynologyPhotoAccess(listOf(SynologyPhotoSpace.PERSONAL), "synthetic") }, onCompleted = {})
    }
    private class AlbumServing : SynologyPhotosServing {
        override val profileId = owner.profileId
        override val canManageAlbums = true
        override val canManageConditionAlbums = true
        override val canManageAlbumSharing = true
        var receivedPassword: String? = null; var failSharing = false
        override suspend fun albumSharing(id: Long): SynologyPhotoAlbumSharing {
            if (failSharing) throw IOException("synthetic sharing read failure")
            return SynologyPhotoAlbumSharing(access.album, SynologyPhotoSharingSnapshot("a".repeat(64), SynologyPhotoLinkAccess.INVITED,
                emptyList(), false, 0, "b".repeat(64)), emptyList(), "https://example.invalid/synthetic", SynologyPhotoLinkAccess.INVITED)
        }
        override suspend fun performPhotoSharing(checkpoint: SynologyPhotoAlbumCheckpoint, password: String?, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            receivedPassword = password; return performPhotoAlbum(checkpoint, save)
        }
        val photo = SynologyPhoto(SynologyPhotoId(profileId, SynologyPhotoSpace.PERSONAL, 91), "synthetic.jpg", 4, 1000.0, 900.0, 9, "photo")
        var access = SynologyPhotoAlbumAccess(SynologyPhotoAlbumSnapshot(71, "Synthetic album", 41, "normal", false, false), true, true, true)
        var frozen: SynologyPhotoFrozenAlbum? = null; var failFrozen = false
        fun makeFrozen() {
            access = access.copy(album = access.album.copy(type = "condition", frozen = true), canContribute = false)
            frozen = SynologyPhotoFrozenAlbum(access.album, SynologyPhotoFrozenAlbumSnapshot(4, "a".repeat(64), true), setOf("recently_add"),
                SynologyPhotoAlbumCondition(Json.parseToJsonElement("""{"user_id":41,"rating":[3]}""").jsonObject,
                    mapOf("rating" to listOf(SynologyPhotoConditionOption(JsonPrimitive(3), "Synthetic name")))))
        }
        override suspend fun frozenAlbum(id: Long): SynologyPhotoFrozenAlbum { if (failFrozen) throw IOException("synthetic"); return frozen!! }
        var failAccess = false; var pending = false; var writes = 0; var reviews = 0
        val actions = mutableListOf<SynologyPhotoAlbumAction>()
        var temporaryDigest = "c".repeat(64)
        override suspend fun temporaryAlbum(id: Long) = SynologyPhotoTemporaryAlbum(access.album,
            SynologyPhotoTemporarySnapshot(albumSharing(id).snapshot, temporaryDigest, 1))
        var beforeWrite: suspend () -> Unit = {}
        override suspend fun access() = SynologyPhotoAccess(listOf(SynologyPhotoSpace.PERSONAL), "synthetic")
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = emptyList<SynologyPhotoDay>()
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) = SynologyPhotoPage(emptyList(), offset, offset, false)
        override suspend fun photoEditIdentity() = 41L
        override suspend fun albumAccess(id: Long): SynologyPhotoAlbumAccess { if (failAccess) throw IOException("synthetic"); return access }
        override suspend fun addableAlbums(offset: Int, limit: Int) = listOf(SynologyPhotoCollection(71, "Synthetic album"))
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            val submitted = checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)
            save(submitted); beforeWrite(); writes++; actions += checkpoint.action
            if (checkpoint.action == SynologyPhotoAlbumAction.CREATE_TEMPORARY) access = access.copy(
                album = access.album.copy(id = 72, name = checkpoint.name!!, temporary = true), canContribute = false)
            return settle(submitted).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews++; return settle(checkpoint).also(save)
        }
        private suspend fun settle(row: SynologyPhotoAlbumCheckpoint) = row.copy(
            temporaryCreatedSnapshot = if (!pending && row.action == SynologyPhotoAlbumAction.CREATE_TEMPORARY) temporaryAlbum(72).snapshot else row.temporaryCreatedSnapshot,
            temporaryCloseAttempted = row.action == SynologyPhotoAlbumAction.STOP_TEMPORARY,
            temporaryClosedRevision = "d".repeat(64).takeIf { row.action == SynologyPhotoAlbumAction.STOP_TEMPORARY },
            temporaryDeleteAttempted = row.action == SynologyPhotoAlbumAction.STOP_TEMPORARY,
            phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED,
            createdAlbumId = 72.takeIf { row.action.createsAlbum }?.toLong(),
            completed = if (pending) emptySet() else row.targets.indices.toSet())
    }
    private suspend fun fixture(block: suspend (Fixture) -> Unit) {
        val f = Fixture(); try { block(f) } finally { f.model.close(); f.scope.coroutineContext[Job]!!.cancelAndJoin() }
    }
    private companion object {
        val owner = WorkspaceOwner("profile-album", "identity", "session")
        suspend fun ready(f: Fixture) { await { !f.model.state.value.loading } }
        suspend fun await(predicate: () -> Boolean) { withTimeout(5000) { while (!predicate()) delay(5) } }
    }
}

package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoSharedMembersCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.time.*
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoSharedMembersModelTest {
    private class Api : SynologyPhotosServing {
        override val profileId = "members-model-${UUID.randomUUID()}"
        override val canManageSharedMembers = true; override val canEditPhotos = true
        var members = listOf(member(50, "entry"), member(60, "management"), member(2, "management", protected = true))
        var role = SynologyPhotoSharedSettings.Role.MANAGEMENT
        var pending = false; var partial = false; var writes = 0; var reviews = 0; var reads = 0
        var memberError = false; var candidateError = false
        var beforeRead: suspend () -> Unit = {}; var beforeOwn: suspend () -> Unit = {}; var beforeFolders: suspend () -> Unit = {}
        var afterWrite: () -> Unit = {}; var photoRead: suspend (SynologyPhotoSpace, SynologyPhotoQuery, Int, Int) -> SynologyPhotoPage = { space, query, offset, _ ->
            queryReads += space to query
            SynologyPhotoPage(if (offset == 0) listOf(photo.copy(id = photo.id.copy(space = space))) else emptyList(), offset, if (offset == 0) 1 else offset, false)
        }
        val queryReads = CopyOnWriteArrayList<Pair<SynologyPhotoSpace, SynologyPhotoQuery>>()
        val photo = SynologyPhoto(SynologyPhotoId(profileId, SynologyPhotoSpace.PERSONAL, 51), "Synthetic.jpg", 100,
            Instant.parse("2020-03-01T12:00:00Z").epochSecond.toDouble(), 1.0, 9, "photo")
        override suspend fun photoEditIdentity() = 41L
        override suspend fun sharedMembers(): SynologyPhotoSharedMembers {
            beforeRead(); reads++; if (memberError) throw IOException("Synthetic members")
            return SynologyPhotoSharedMembers(SynologyPhotoSharedMembersSnapshot(profileId, 41, true, members.map { it.grant }), members)
        }
        override suspend fun sharedMemberCandidates(): List<SynologyPhotoShareRecipient> {
            if (candidateError) throw IOException("Synthetic candidates")
            return listOf(member(41, "entry").recipient, member(70, "entry").recipient, member(2, "management", protected = true).recipient)
        }
        override suspend fun sharedMemberFolders(member: SynologyPhotoShareMemberId): List<SynologyPhotoMemberFolder> {
            beforeFolders()
            return listOf(folder(2, 1, 0, "view"), folder(3, 2, 1, "view"), folder(4, 1, 0, null, "public-download"))
                .map { SynologyPhotoMemberFolder(it, if (it.depth == 0) "/Synthetic-${it.id}" else "/Synthetic-2/Child") }
        }
        override suspend fun photoSettings(kind: SynologyPhotoSettingsKind): SynologyPhotoSettings {
            beforeOwn(); return SynologyPhotoSharedSettings(profileId, 41, true, true, role, false,
                SynologyPhotoSharedSetting.entries.associateWith { true }, SynologyPhotoSharedSetting.entries.associateWith { true })
        }
        override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) = Unit
        override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            save(checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)); writes++
            val value = checkpoint.sharedMembers!!; val all = SynologyPhotoSharedMembersCodec.steps(value).indices.toSet()
            val attempted = if (partial) setOf(0) else all
            val next = value.copy(attempted = attempted, acknowledged = attempted, completed = if (pending) emptySet() else attempted)
            if (!pending) members = value.desired.map { grant -> SynologyPhotoSharedMember(member(grant.id.value.content.toLong(), grant.role).recipient, grant) }
            afterWrite()
            return checkpoint.copy(sharedMembers = next, phase = if (pending) SynologyPhotoAlbumPhase.PENDING else if (partial && attempted != all) SynologyPhotoAlbumPhase.PARTIAL else SynologyPhotoAlbumPhase.COMPLETED).also(save)
        }
        override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
            reviews++; val value = checkpoint.sharedMembers!!
            return checkpoint.copy(sharedMembers = value.copy(completed = if (pending) value.completed else value.attempted),
                phase = if (pending) SynologyPhotoAlbumPhase.PENDING else SynologyPhotoAlbumPhase.COMPLETED).also(save)
        }
        override suspend fun access() = SynologyPhotoAccess(if (role == SynologyPhotoSharedSettings.Role.NONE) listOf(SynologyPhotoSpace.PERSONAL) else SynologyPhotoSpace.entries,
            "synthetic", role == SynologyPhotoSharedSettings.Role.MANAGEMENT)
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = listOf(SynologyPhotoDay(LocalDate.of(2020, 3, 1), 1))
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) = photoRead(space, query, offset, limit)
        override suspend fun categories(space: SynologyPhotoSpace) = emptySet<SynologyPhotoCategory>()
        override suspend fun albums(offset: Int, limit: Int) = emptyList<SynologyPhotoCollection>()
    }
    private class Fixture {
        val api = Api(); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = WorkspaceOwner(api.profileId, "identity", "session"); val preferences = MemoryPreferences(); val store = SynologyPhotoAlbumStore(preferences)
        val applied = CopyOnWriteArrayList<SynologyPhotoSharedSettings>(); val pauses = CopyOnWriteArrayList<Long>(); val ticks = Channel<Unit>(Channel.UNLIMITED)
        fun model() = SynologyPhotoSharedMembersModel(api, scope, store, owner, {}, { true }, {}, { applied += it }, pause = { pauses += it; ticks.receive() })
        val model = model()
        suspend fun open() { model.open(); await { !model.state.value.loading } }
        fun root() = SynologyPhotosModel(api, scope, zone = ZoneOffset.UTC, uploadOwner = owner, albumStore = store, editStore = SynologyPhotoEditStore(MemoryPreferences()))
    }
    @Test fun `新增自定义先开目录取消不加入管理角色强制备份保护组不编辑`() = runBlocking { fixture { f ->
        f.open(); f.model.add(); await { !f.model.state.value.candidatesLoading }
        val new = f.model.state.value.candidates.first { it.id == id(70) }; f.model.choose(new, "entry")
        await { f.model.state.value.directory?.edit != null }; assertFalse(f.model.state.value.members.any { it.grant.id == id(70) })
        f.model.cancelFolders(); assertFalse(f.model.state.value.members.any { it.grant.id == id(70) }); assertEquals(0, f.api.writes)
        f.model.choose(new, "management"); assertTrue(f.model.state.value.members.last().grant.autoBackup)
        f.model.backup(id(70), false); assertTrue(f.model.state.value.members.last().grant.autoBackup)
        val original = f.model.state.value.members.first { it.grant.protected }; f.model.remove(original.grant.id); f.model.role(original.grant.id, "entry")
        assertTrue(original in f.model.state.value.members); assertEquals(0, f.api.writes)
    } }
    @Test fun `降级自定义取消保持管理完成目录只回草稿最终取消零写入`() = runBlocking { fixture { f ->
        f.open(); f.model.role(id(60), "entry"); await { f.model.state.value.directory?.edit != null }
        f.model.cancelFolders(); assertEquals("management", f.model.state.value.members.first { it.grant.id == id(60) }.grant.role)
        f.model.role(id(60), "entry"); await { f.model.state.value.directory?.edit != null }; f.model.folderRole(2, SynologyPhotoFolderMemberRole.UPLOAD); f.model.finishFolders()
        val member = f.model.state.value.members.first { it.grant.id == id(60) }; assertEquals("entry", member.grant.role); assertTrue(member.grant.autoBackup)
        assertEquals(1, f.model.state.value.folderEdits.size); assertEquals(0, f.api.writes)
        f.model.save(); assertNotNull(f.model.state.value.confirmation); f.model.cancelConfirmation(); assertNull(f.model.confirm()); assertEquals(0, f.api.writes)
    } }
    @Test fun `连续批量基于当前草稿再逐项覆盖父撤权清子草稿`() = runBlocking { fixture { f ->
        f.open(); f.model.editFolders(id(50)); await { f.model.state.value.directory?.edit != null }
        f.model.batch(SynologyPhotoFolderMemberRole.MANAGE, true); f.model.batch(SynologyPhotoFolderMemberRole.VIEW, true)
        var edit = f.model.state.value.directory!!.edit!!; assertTrue(edit.original.all { edit.expectedRole(it) == "manage" })
        f.model.folderRole(3, SynologyPhotoFolderMemberRole.DOWNLOAD); f.model.folderRole(2, null)
        edit = f.model.state.value.directory!!.edit!!; assertNull(edit.expectedRole(edit.original.first { it.id == 3L })); assertFalse(edit.canEdit(edit.original.first { it.id == 3L }))
        assertTrue(f.model.state.value.directory!!.childrenCleared); f.model.finishFolders(); assertEquals(0, f.api.writes)
    } }
    @Test fun `候选错误不阻断已有成员并批量备份只改可编辑自定义角色`() = runBlocking { fixture { f ->
        f.open(); f.api.candidateError = true; f.model.add(); await { !f.model.state.value.candidatesLoading }; assertNotNull(f.model.state.value.candidatesError)
        f.model.cancelAdd(); f.model.backup(null, true); assertTrue(f.model.canSave)
        f.model.backup(null, false); assertTrue(f.model.state.value.members.filter { it.grant.role == "management" }.all { it.grant.autoBackup })
        assertFalse(f.model.canSave); f.model.backup(id(50), true); f.model.save(); f.model.confirm()!!.join(); assertEquals(1, f.api.writes)
    } }
    @Test fun `保存未知也读取本人实际权限读取完成前保持互斥`() = runBlocking { fixture { f ->
        f.open(); f.api.pending = true; f.model.backup(id(50), true); f.model.save()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeOwn = { entered.complete(Unit); release.await() }; f.api.afterWrite = { f.api.role = SynologyPhotoSharedSettings.Role.ENTRY }
        val saving = f.model.confirm()!!; entered.await(); assertTrue(f.model.state.value.working); assertFalse(f.model.canSave)
        try { f.model.requireNoPending(); fail() } catch (error: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.BUSY, error.problem) }
        release.complete(Unit); saving.join(); assertEquals(SynologyPhotoSharedSettings.Role.ENTRY, f.applied.single().role)
        assertEquals(SynologyPhotoAlbumPhase.PENDING, f.model.state.value.records.single().checkpoint.phase)
    } }
    @Test fun `未知记录冷启动只读十五秒轮询关闭后台撤权停止`() = runBlocking { fixture { f ->
        f.open(); f.api.pending = true; f.model.backup(id(50), true); f.model.save(); f.model.confirm()!!.join(); f.model.dismiss()
        val cold = f.model(); try {
            cold.activate(); cold.showRecords(); await { cold.state.value.records.isNotEmpty() && f.pauses.isNotEmpty() }
            assertEquals(15_000L, f.pauses.last()); f.ticks.send(Unit); await { f.api.reviews == 1 && !cold.state.value.working }; assertEquals(1, f.api.writes)
            cold.deactivate(); delay(30); assertEquals(1, f.api.reviews)
            f.api.pending = false; cold.activate(); await { f.pauses.size >= 2 }; f.ticks.send(Unit)
            await { cold.state.value.records.single().checkpoint.finished && !cold.state.value.working }; assertEquals(1, f.api.writes)
            cold.revokeAccess(); assertFalse(cold.state.value.visible)
        } finally { cold.close() }
    } }
    @Test fun `离页不可取消的迟到名单不覆盖返回重新读取`() = runBlocking { fixture { f ->
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.api.beforeRead = { entered.complete(Unit); withContext(NonCancellable) { release.await() } }
        f.model.activate(); f.model.open(); entered.await(); f.model.deactivate(); release.complete(Unit)
        await { f.api.reads == 1 }; delay(30); assertNull(f.model.state.value.original)
        f.api.beforeRead = {}; f.model.activate(); await { f.model.state.value.original != null }; assertEquals(2, f.api.reads)
    } }
    @Test fun `取消目录迟到读取不能覆盖重新打开的加载状态`() = runBlocking { fixture { f ->
        f.open(); val first = CompletableDeferred<Unit>(); val releaseFirst = CompletableDeferred<Unit>(); val second = CompletableDeferred<Unit>(); val releaseSecond = CompletableDeferred<Unit>()
        var reads = 0
        f.api.beforeFolders = { if (++reads == 1) { first.complete(Unit); withContext(NonCancellable) { releaseFirst.await() } } else { second.complete(Unit); releaseSecond.await() } }
        f.model.editFolders(id(50)); first.await(); f.model.cancelFolders(); f.model.editFolders(id(50)); second.await(); releaseFirst.complete(Unit); delay(30)
        assertTrue(f.model.state.value.directory!!.loading); assertNull(f.model.state.value.directory!!.edit)
        releaseSecond.complete(Unit); await { f.model.state.value.directory?.edit != null }
    } }
    @Test fun `目录读取失败重试成功清除旧错误并允许完成草稿`() = runBlocking { fixture { f ->
        f.open(); f.api.beforeFolders = { throw IOException("Synthetic folders") }
        f.model.editFolders(id(50)); await { f.model.state.value.directory?.error != null }
        assertNull(f.model.state.value.directory!!.edit)
        f.api.beforeFolders = {}; f.model.loadFolders()!!.join()
        assertNull(f.model.state.value.directory!!.error); assertNotNull(f.model.state.value.directory!!.edit)
        f.model.folderRole(2, SynologyPhotoFolderMemberRole.UPLOAD); f.model.finishFolders()
        assertNull(f.model.state.value.directory); assertTrue(f.model.canSave); assertEquals(0, f.api.writes)
    } }
    @Test fun `存储恢复最小权限事实单向账号隔离拒绝跳步骤或伪造完成`() = runBlocking { fixture { f ->
        f.open(); f.model.backup(id(50), true); f.model.save(); f.api.pending = true; f.model.confirm()!!.join()
        val record = f.store.records(f.owner, 41).single(); val value = record.checkpoint.sharedMembers!!
        assertFalse(f.preferences.all.values.joinToString().contains("Synthetic-member"))
        reject { f.store.save(record.id, f.owner, 41, record.checkpoint.copy(sharedMembers = value.copy(attempted = emptySet()))) }
        reject { f.store.save(record.id, f.owner, 41, record.checkpoint.copy(sharedMembers = value.copy(attempted = setOf(1)))) }
        reject { f.store.save(record.id, f.owner, 41, record.checkpoint.copy(phase = SynologyPhotoAlbumPhase.COMPLETED)) }
        val cold = SynologyPhotoAlbumStore(f.preferences); assertEquals(record.checkpoint, cold.records(f.owner.copy(sessionGeneration = "fresh"), 41).single().checkpoint)
        assertTrue(cold.records(f.owner.copy(identityRevision = "another"), 41).isEmpty()); assertTrue(cold.records(f.owner, 42).isEmpty())
    } }
    @Test fun `成员保存不刷新个人历史月份照片与多选`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; root.jumpToMonth(YearMonth.of(2020, 3))!!.join()
            root.edits!!.selectMode(true); root.edits.toggle(f.api.photo)
            val old = root.state.value; val selected = root.edits.state.value.selected; val readCount = f.api.queryReads.size
            val model = root.sharedMembers!!; model.open(); await { !model.state.value.loading }; model.backup(id(50), true); model.save(); model.confirm()!!.join()
            assertEquals(old.items, root.state.value.items); assertEquals(old.selectedMonth, root.state.value.selectedMonth)
            assertEquals(selected, root.edits.state.value.selected); assertEquals(readCount, f.api.queryReads.size)
        } finally { root.close() }
    } }
    @Test fun `本人降级重读原共享月份`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }; root.selectSpace(SynologyPhotoSpace.SHARED)
            await { !root.state.value.loading }; root.jumpToMonth(YearMonth.of(2020, 3))!!.join()
            val old = root.state.value; val oldQuery = f.api.queryReads.last().second
            val model = root.sharedMembers!!; model.open(); await { !model.state.value.loading }; model.backup(id(50), true); model.save()
            f.api.afterWrite = { f.api.role = SynologyPhotoSharedSettings.Role.ENTRY }
            model.confirm()!!.join(); await { !root.state.value.loading }
            assertEquals(old.selectedMonth, root.state.value.selectedMonth); assertEquals(oldQuery, f.api.queryReads.last().second)
            assertFalse(root.state.value.access!!.canManageSharedSpace); assertEquals(SynologyPhotoSpace.SHARED, root.state.value.navigation.space)
        } finally { root.close() }
    } }
    @Test fun `本人共享访问撤回退出共享图库`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            root.activate(); await { !root.state.value.loading }; root.selectSpace(SynologyPhotoSpace.SHARED); await { !root.state.value.loading }
            val model = root.sharedMembers!!; model.open(); await { !model.state.value.loading }; model.backup(id(50), true); model.save()
            f.api.afterWrite = { f.api.role = SynologyPhotoSharedSettings.Role.NONE }; model.confirm()!!.join(); await { !root.state.value.loading }
            assertEquals(SynologyPhotoSpace.PERSONAL, root.state.value.navigation.space); assertTrue(root.state.value.items.all { it.id.space == SynologyPhotoSpace.PERSONAL })
        } finally { root.close() }
    } }
    @Test fun `后台完成共享保存只保留位置返回重读原月份`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            openSharedMonth(root)
            val old = root.state.value; val query = f.api.queryReads.last().second
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            f.api.beforeOwn = { entered.complete(Unit); release.await() }
            val model = prepareSave(root); val saving = model.confirm()!!; entered.await()
            assertTrue(root.state.value.items.isEmpty()); assertNull(root.preview.state.value.photo)
            root.deactivate(); val reads = f.api.queryReads.size
            release.complete(Unit); saving.join(); delay(30)
            assertTrue(root.state.value.items.isEmpty()); assertEquals(reads, f.api.queryReads.size)
            assertEquals(old.selectedMonth, root.state.value.selectedMonth)
            root.activate(); await { root.state.value.loaded && !root.state.value.loading }
            assertEquals(query, f.api.queryReads.last().second); assertEquals(old.selectedMonth, root.state.value.selectedMonth)
            assertEquals(1, f.api.writes)
        } finally { root.close() }
    } }
    @Test fun `本人权限读取失败清旧共享并允许重试读取原位置`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            openSharedMonth(root); val old = root.state.value; val query = f.api.queryReads.last().second
            val model = prepareSave(root)
            f.api.beforeOwn = { throw IOException("Synthetic own access") }; model.confirm()!!.join()
            assertTrue(root.state.value.items.isEmpty()); assertFalse(root.state.value.loading); assertNotNull(root.state.value.error)
            assertNull(root.loadPrevious()); assertNull(root.jumpToMonth(YearMonth.of(2020, 3))); assertNull(root.loadMore())
            assertNotNull(model.state.value.error); assertEquals(1, f.api.writes)
            f.api.beforeOwn = {}; f.api.role = SynologyPhotoSharedSettings.Role.ENTRY; root.refresh()!!.join()
            assertTrue(root.state.value.loaded); assertNull(root.state.value.error); assertFalse(root.state.value.access!!.canManageSharedSpace)
            assertEquals(old.selectedMonth, root.state.value.selectedMonth); assertEquals(query, f.api.queryReads.last().second)
            assertEquals(1, f.api.writes)
        } finally { root.close() }
    } }
    @Test fun `未知保存权限读取失败恢复记录仍可继续只读`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            openSharedMonth(root); val model = prepareSave(root); f.api.pending = true
            f.api.beforeOwn = { throw IOException("Synthetic own access") }; model.confirm()!!.join()
            assertTrue(root.state.value.items.isEmpty()); assertFalse(model.state.value.working)
            val record = model.state.value.records.single(); assertFalse(record.checkpoint.finished)
            f.api.beforeOwn = {}; f.api.pending = false
            model.resume(record.id)!!.join(); await { !root.state.value.loading }
            assertEquals(1, f.api.reviews); assertEquals(1, f.api.writes); assertTrue(model.state.value.records.single().checkpoint.finished)
            assertTrue(root.state.value.items.isNotEmpty())
        } finally { root.close() }
    } }
    @Test fun `旧共享分页即使不可取消迟到也不能恢复已清照片`() = runBlocking { fixture { f ->
        val root = f.root(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        try {
            openSharedMonth(root)
            var changed = false
            f.api.photoRead = { space, _, offset, _ ->
                val item = f.api.photo.copy(id = f.api.photo.id.copy(space = space, itemId = if (changed) 88 else if (offset == 0) 51 else 99))
                if (offset > 0 && !changed) { entered.complete(Unit); withContext(NonCancellable) { release.await() } }
                SynologyPhotoPage(listOf(item), offset, offset + 1, !changed && offset == 0)
            }
            root.jumpToMonth(YearMonth.of(2020, 3))!!.join()
            val paging = root.loadMore()!!; entered.await(); val model = prepareSave(root)
            f.api.afterWrite = { changed = true }; model.confirm()!!.join(); await { !root.state.value.loading }
            assertEquals(listOf(88L), root.state.value.items.map { it.id.itemId })
            release.complete(Unit); paging.join()
            assertEquals(listOf(88L), root.state.value.items.map { it.id.itemId })
        } finally { release.complete(Unit); root.close() }
    } }
    @Test fun `共享权限刷新保留已经加载的多页范围`() = runBlocking { fixture { f ->
        val root = f.root(); try {
            f.api.photoRead = { space, query, offset, limit ->
                f.api.queryReads += space to query
                val count = minOf(limit, 120 - offset).coerceAtLeast(0)
                val items = (offset until offset + count).map { f.api.photo.copy(id = f.api.photo.id.copy(space = space, itemId = it.toLong() + 1)) }
                SynologyPhotoPage(items, offset, offset + count, offset + count < 120)
            }
            openSharedMonth(root); root.loadMore()!!.join(); assertEquals(120, root.state.value.items.size)
            val model = prepareSave(root); model.confirm()!!.join(); await { !root.state.value.loading }
            assertEquals(120, root.state.value.items.size); assertEquals(120, root.state.value.items.map { it.id }.distinct().size)
            assertEquals(YearMonth.of(2020, 3), root.state.value.selectedMonth)
        } finally { root.close() }
    } }
    private suspend fun openSharedMonth(root: SynologyPhotosModel) {
        root.activate(); await { root.state.value.loaded && !root.state.value.loading }
        root.selectSpace(SynologyPhotoSpace.SHARED); await { !root.state.value.loading }
        root.jumpToMonth(YearMonth.of(2020, 3))!!.join()
    }
    private suspend fun prepareSave(root: SynologyPhotosModel): SynologyPhotoSharedMembersModel {
        val model = root.sharedMembers!!; model.open(); await { !model.state.value.loading }
        model.backup(id(50), true); model.save(); assertNotNull(model.state.value.confirmation); return model
    }
    companion object {
        private fun id(value: Long, type: String = "user") = SynologyPhotoShareMemberId(type, JsonPrimitive(value))
        private fun member(value: Long, role: String, protected: Boolean = false): SynologyPhotoSharedMember {
            val id = id(value, if (protected) "group" else "user")
            return SynologyPhotoSharedMember(SynologyPhotoShareRecipient(id, if (protected) "administrators" else "Synthetic-member-$value"), SynologyPhotoSharedMemberGrant(id, role, role == "management", protected))
        }
        private fun folder(value: Long, parent: Long, depth: Int, role: String?, privacy: String = "private") = SynologyPhotoMemberFolderSnapshot(value, parent, 1, depth, "a".repeat(64), privacy, role, "b".repeat(64))
        private suspend fun await(predicate: () -> Boolean) { withTimeout(5_000) { while (!predicate()) delay(5) } }
        private suspend fun fixture(block: suspend (Fixture) -> Unit) { val f = Fixture(); try { block(f) } finally { f.model.close(); f.scope.cancel() } }
        private fun reject(block: () -> Unit) { try { block(); fail("Expected storage rejection") } catch (_: SynologyPhotoAlbumFailure) {} }
    }
}

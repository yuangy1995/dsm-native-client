package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoAlbumStoreTest {
    @Test fun `文件任务编号目标摘要和计数只前进且冷热恢复固定同一意图`() {
        val space = SynologyPhotoSpace.PERSONAL
        val input = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.COPY_ITEMS, files = SynologyPhotoFileCheckpoint(space,
                folders = listOf(SynologyPhotoFolderSnapshot(10, 9, "Child", "/Source/Child", space)),
                destination = SynologyPhotoFolderSnapshot(20, 1, "Dest", "/Dest", space), duplicate = SynologyPhotoTransferDuplicate.SKIP)))
        store.begin(input); store.save(input.id, owner, 41, input.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        val bound = input.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PENDING, files = input.checkpoint.files!!.copy(taskId = 91, total = 3, targetVerified = true))
        store.save(input.id, owner, 41, bound)
        for (changed in listOf(bound.files!!.copy(taskId = 92), bound.files.copy(taskId = null), bound.files.copy(total = 4),
            bound.files.copy(targetVerified = false), bound.files.copy(duplicate = SynologyPhotoTransferDuplicate.OVERWRITE),
            bound.files.copy(destination = bound.files.destination!!.copy(id = 21)))) {
            failure { store.save(input.id, owner, 41, bound.copy(files = changed)) }
        }
        failure { store.discard(store.get(input.id, owner, 41)) }; failure { store.begin(row()) }
        assertEquals(bound, SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "new"), 41).single().checkpoint)
        val done = bound.copy(phase = SynologyPhotoAlbumPhase.PARTIAL, files = bound.files.copy(result = SynologyPhotoFileResult(2, 1, 0, 0)))
        store.save(input.id, owner, 41, done)
        failure { store.save(input.id, owner, 41, bound) }
        store.discard(store.get(input.id, owner, 41)); assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `收集创建摘要只可前进不允许替换回执且不保存明文`() {
        val input = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.CREATE_REQUEST, request = SynologyPhotoRequestCheckpoint(SynologyPhotoSpace.PERSONAL, null, "a".repeat(64), false)))
        store.begin(input); store.save(input.id, owner, 41, input.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        val bound = input.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PENDING, request = input.checkpoint.request!!.copy(targetDigest = "b".repeat(64)))
        store.save(input.id, owner, 41, bound)
        failure { store.save(input.id, owner, 41, bound.copy(request = bound.request!!.copy(targetDigest = null))) }
        failure { store.save(input.id, owner, 41, bound.copy(request = bound.request!!.copy(targetDigest = "c".repeat(64)))) }
        failure { store.save(input.id, owner, 41, bound.copy(request = bound.request!!.copy(settingsDigest = "c".repeat(64)))) }
        failure { store.begin(row()) }
        assertEquals(bound, SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "new"), 41).single().checkpoint)
    }
    @Test fun `未决相册与收集请求互斥结束后允许新操作旧记录仍可读`() {
        val old = row(); store.begin(old)
        store.save(old.id, owner, 41, old.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        val request = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.CREATE_REQUEST, request = SynologyPhotoRequestCheckpoint(SynologyPhotoSpace.PERSONAL, null, "a".repeat(64), false)))
        failure { store.begin(request) }
        store.save(old.id, owner, 41, old.checkpoint.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, createdAlbumId = 71))
        store.begin(request); assertEquals(2, store.records(owner, 41).size)
        assertNull(store.get(old.id, owner, 41).checkpoint.request)
    }
    private val owner = WorkspaceOwner("profile-store", "identity", "session")
    private val preferences = MemoryPreferences()
    private val store = SynologyPhotoAlbumStore(preferences)
    private fun row() = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(
        profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic album"))

    @Test fun `重启只读恢复且不能回退阶段替换原操作或覆盖已知编号`() {
        val row = row(); store.begin(row)
        val submitted = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)
        store.save(row.id, owner, 41, submitted)
        val restored = SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "new"), 41).single()
        assertEquals(SynologyPhotoAlbumPhase.PENDING, restored.checkpoint.phase)
        failure { store.save(row.id, owner, 41, row.checkpoint) }
        failure { store.save(row.id, owner, 41, submitted) }
        failure { store.save(row.id, owner, 41, restored.checkpoint.copy(name = "Other")) }
        val bound = restored.checkpoint.copy(createdAlbumId = 71)
        store.save(row.id, owner, 41, bound)
        failure { store.save(row.id, owner, 41, bound.copy(createdAlbumId = 72)) }
        failure { store.save(row.id, owner, 41, bound.copy(createdAlbumId = null)) }
        val done = bound.copy(phase = SynologyPhotoAlbumPhase.COMPLETED)
        store.save(row.id, owner, 41, done)
        failure { store.save(row.id, owner, 41, bound) }
    }
    @Test fun `不能跳过提交边界且未知创建阻止同名重复操作`() {
        val row = row(); store.begin(row)
        failure { store.save(row.id, owner, 41, row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, createdAlbumId = 71)) }
        store.save(row.id, owner, 41, row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        failure { store.begin(row()) }
        failure { store.discard(store.get(row.id, owner, 41)) }
        assertEquals(1, store.records(owner, 41).size)
    }
    @Test fun `并发存储实例账号互斥而活跃提交不会被读取降级`() = runBlocking {
        val row = row(); store.begin(row)
        val other = SynologyPhotoAlbumStore(preferences)
        store.exclusive(owner, row.id) {
            store.save(row.id, owner, 41, row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
            assertEquals(SynologyPhotoAlbumPhase.SUBMITTING, other.records(owner, 41).single().checkpoint.phase)
            try { other.exclusive(owner.copy(sessionGeneration = "new"), "other") {}; fail() } catch (error: SynologyPhotoAlbumFailure) { assertEquals(SynologyPhotoAlbumProblem.BUSY, error.problem) }
            assertTrue(SynologyPhotoAlbumStore.isProfileBusy(owner.profileId))
            failure { store.removeProfile(owner.profileId) }
        }
        assertFalse(SynologyPhotoAlbumStore.isProfileBusy(owner.profileId))
    }
    @Test fun `未来格式或损坏记录保留原文不能当作空记录`() {
        for (key in listOf("photos_album_v1_broken", "photos_album_v2_broken")) {
            preferences.edit().clear().putString(key, "invalid").commit()
            failure { store.records(owner, 41) }; failure { store.begin(row()) }
            assertEquals("invalid", preferences.getString(key, null))
        }
    }
    @Test fun `同步写入失败必须报错并保留可能已写入的数据`() {
        val row = row(); preferences.commitSucceeds = false
        failure { store.begin(row) }
        preferences.commitSucceeds = true
        assertEquals(row, store.records(owner, 41).single())
    }
    @Test fun `NAS账号身份及Photos用户编号隔离但允许同账号重新登录`() {
        val row = row(); store.begin(row)
        assertTrue(store.records(owner.copy(profileId = "other"), 41).isEmpty())
        assertTrue(store.records(owner.copy(identityRevision = "other"), 41).isEmpty())
        assertTrue(store.records(owner, 42).isEmpty())
        assertEquals(row, store.records(owner.copy(sessionGeneration = "new"), 41).single())
        store.removeProfile("other"); assertEquals(1, store.records(owner, 41).size)
        store.discard(row); assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `条件快照冷恢复保留未知规则且禁止替换新旧条件`() {
        val condition = SynologyPhotoAlbumCondition(Json.parseToJsonElement("""{"user_id":41,"item_type":[],"future":[9,2],"empty":[]}""").jsonObject)
        val record = row().copy(checkpoint = row().checkpoint.copy(action = SynologyPhotoAlbumAction.CREATE_CONDITION, condition = condition))
        store.begin(record)
        store.save(record.id, owner, 41, record.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        val restored = SynologyPhotoAlbumStore(preferences).records(owner, 41).single()
        assertEquals(condition, restored.checkpoint.condition); assertEquals(SynologyPhotoAlbumPhase.PENDING, restored.checkpoint.phase)
        failure { store.save(record.id, owner, 41, restored.checkpoint.copy(condition = SynologyPhotoAlbumCondition())) }
        val changed = row().copy(checkpoint = row().checkpoint.copy(name = record.checkpoint.name))
        failure { store.begin(changed) }
    }
    @Test fun `旧普通相册无新增字段仍可恢复而规则动作缺少原快照失败关闭`() {
        val record = row(); store.begin(record)
        val key = preferences.all.keys.single()
        val old = Json.parseToJsonElement(preferences.getString(key, null)!!).jsonObject
        val checkpoint = JsonObject(old.getValue("checkpoint").jsonObject - "condition" - "originalCondition" - "frozenSnapshot" - "frozenDeletionAttempted" - "frozenDeletionRejected" -
            "sharing" - "sharingUpdateAttempted" - "sharingUpdateAcknowledged" - "sharingEnableAttempted" - "sharingNoChanges")
        preferences.edit().putString(key, JsonObject(old + ("checkpoint" to checkpoint)).toString()).commit()
        assertEquals(record, SynologyPhotoAlbumStore(preferences).records(owner, 41).single())
        val invalid = record.copy(checkpoint = record.checkpoint.copy(action = SynologyPhotoAlbumAction.SET_CONDITION,
            name = null, album = SynologyPhotoAlbumSnapshot(71, "Synthetic", 41, "condition", false, false), condition = SynologyPhotoAlbumCondition()))
        failure { store.begin(invalid) }
    }
    @Test fun `冻结重建记录固定双方编号摘要与删除尝试不能回退`() {
        val record = frozenRow(); store.begin(record)
        val submitted = record.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)
        store.save(record.id, owner, 41, submitted)
        val created = submitted.copy(phase = SynologyPhotoAlbumPhase.PENDING, createdAlbumId = 72)
        store.save(record.id, owner, 41, created)
        failure { store.save(record.id, owner, 41, created.copy(createdAlbumId = 71)) }
        failure { store.save(record.id, owner, 41, created.copy(frozenSnapshot = created.frozenSnapshot!!.copy(shared = false))) }
        val deleting = created.copy(frozenDeletionAttempted = true)
        store.save(record.id, owner, 41, deleting)
        failure { store.save(record.id, owner, 41, created) }
        failure { store.save(record.id, owner, 41, deleting.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)) }
        val rejected = deleting.copy(frozenDeletionRejected = true, phase = SynologyPhotoAlbumPhase.PARTIAL)
        store.save(record.id, owner, 41, rejected)
        val restored = SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "new"), 41).single()
        assertEquals(rejected, restored.checkpoint)
        assertEquals(setOf(71L, 72L), restored.checkpoint.affectedAlbumIds)
        failure { store.save(record.id, owner, 41, rejected.copy(frozenDeletionRejected = false)) }
    }
    @Test fun `未决替换同时锁定新旧相册并拒绝缺失摘要或伪造删除阶段`() {
        val record = frozenRow(); store.begin(record)
        store.save(record.id, owner, 41, record.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        store.save(record.id, owner, 41, record.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PENDING, createdAlbumId = 72))
        for (id in listOf(71L, 72L)) {
            val edit = row().copy(checkpoint = row().checkpoint.copy(action = SynologyPhotoAlbumAction.RENAME,
                album = SynologyPhotoAlbumSnapshot(id, "Synthetic", 41, "condition", false, false)))
            failure { store.begin(edit) }
        }
        for (bad in listOf(frozenRow().checkpoint.copy(frozenSnapshot = null),
            frozenRow().checkpoint.copy(frozenDeletionRejected = true),
            frozenRow().checkpoint.copy(frozenDeletionAttempted = true))) failure { store.begin(record.copy(checkpoint = bad)) }
        assertEquals(1, store.records(owner, 41).size)
    }
    private fun frozenRow() = row().copy(checkpoint = row().checkpoint.copy(action = SynologyPhotoAlbumAction.REBUILD_FROZEN,
        album = SynologyPhotoAlbumSnapshot(71, "Synthetic old", 41, "condition", true, false),
        condition = SynologyPhotoAlbumCondition(Json.parseToJsonElement("""{"user_id":41,"rating":[5]}""").jsonObject),
        frozenSnapshot = SynologyPhotoFrozenAlbumSnapshot(4, "a".repeat(64), true)))
    @Test fun `共享恢复仅最小摘要阶段不能回退且不能篡改权限或跳过更新回执`() {
        val member = SynologyPhotoShareGrant(SynologyPhotoShareMemberId("group", JsonPrimitive("51")), "future-role")
        val sharing = SynologyPhotoSharingChange(SynologyPhotoSharingSnapshot("a".repeat(64), SynologyPhotoLinkAccess.DOWNLOAD,
            listOf(member), true, 1700000000, "b".repeat(64)), SynologyPhotoLinkAccess.INVITED, password = SynologyPhotoSharingPassword.SET)
        val record = row().copy(checkpoint = row().checkpoint.copy(action = SynologyPhotoAlbumAction.SHARE, name = null,
            album = SynologyPhotoAlbumSnapshot(71, "Synthetic", 41, "normal", false, false), sharing = sharing))
        store.begin(record)
        var next = record.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)
        store.save(record.id, owner, 41, next)
        failure { store.save(record.id, owner, 41, next.copy(sharingEnableAttempted = true)) }
        failure { store.save(record.id, owner, 41, next.copy(sharing = sharing.copy(access = SynologyPhotoLinkAccess.VIEW))) }
        next = next.copy(sharingUpdateAttempted = true); store.save(record.id, owner, 41, next)
        failure { store.save(record.id, owner, 41, next.copy(sharingUpdateAttempted = false)) }
        next = next.copy(sharingUpdateAcknowledged = true); store.save(record.id, owner, 41, next)
        failure { store.save(record.id, owner, 41, next.copy(sharingUpdateAcknowledged = false)) }
        next = next.copy(sharingEnableAttempted = true); store.save(record.id, owner, 41, next)
        failure { store.save(record.id, owner, 41, next.copy(sharingEnableAttempted = false)) }
        failure { store.save(record.id, owner, 41, next.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)) }
        val cold = SynologyPhotoAlbumStore(preferences).records(owner, 41).single().checkpoint
        assertEquals(SynologyPhotoAlbumPhase.PENDING, cold.phase); assertEquals(sharing, cold.sharing)
        assertTrue(cold.sharingUpdateAcknowledged); assertTrue(cold.sharingEnableAttempted)
        val other = record.copy(checkpoint = record.checkpoint.copy(operationId = java.util.UUID.randomUUID().toString(),
            action = SynologyPhotoAlbumAction.DELETE, sharing = null))
        failure { store.begin(other) }
    }
    @Test fun `临时取消与已保存的副本清理阶段不能被旧回调覆盖`() {
        val share = SynologyPhotoSharingSnapshot("a".repeat(64), SynologyPhotoLinkAccess.INVITED, emptyList(), false, 0, "b".repeat(64))
        val snapshot = SynologyPhotoTemporarySnapshot(share, "c".repeat(64), 0)
        val record = row().copy(checkpoint = row().checkpoint.copy(name = null, action = SynologyPhotoAlbumAction.STOP_TEMPORARY,
            album = SynologyPhotoAlbumSnapshot(71, "Synthetic old", 41, "normal", false, true), temporary = SynologyPhotoTemporaryChange(snapshot, true)))
        store.begin(record); var next = record.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)
        store.save(record.id, owner, 41, next)
        next = next.copy(createdAlbumId = 72, temporaryCloseAttempted = true); store.save(record.id, owner, 41, next)
        failure { store.save(record.id, owner, 41, next.copy(temporaryCloseAttempted = false)) }
        next = next.copy(temporaryClosedRevision = "d".repeat(64)); store.save(record.id, owner, 41, next)
        failure { store.save(record.id, owner, 41, next.copy(temporaryClosedRevision = null)) }
        next = next.copy(temporaryDeleteAttempted = true); store.save(record.id, owner, 41, next)
        failure { store.save(record.id, owner, 41, next.copy(temporaryDeleteAttempted = false)) }
        failure { store.save(record.id, owner, 41, next.copy(createdAlbumId = 73)) }
        val cold = SynologyPhotoAlbumStore(preferences).records(owner, 41).single().checkpoint
        assertEquals(SynologyPhotoAlbumPhase.PENDING, cold.phase); assertTrue(cold.temporaryDeleteAttempted)
        assertEquals(setOf(71L, 72L), cold.affectedAlbumIds)
    }
    @Test fun `创建取消标记持久化且迟到回调不回退用户意图`() {
        val photo = SynologyPhoto(SynologyPhotoId(owner.profileId, SynologyPhotoSpace.PERSONAL, 91), "synthetic.jpg", 4, 1000.0, 900.0, 9, "photo")
        val record = row().copy(checkpoint = row().checkpoint.copy(action = SynologyPhotoAlbumAction.CREATE_TEMPORARY,
            targets = listOf(SynologyPhotoEditTarget(photo))))
        store.begin(record); val submitted = record.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)
        store.save(record.id, owner, 41, submitted); store.requestTemporaryCancellation(record.id, owner)
        store.save(record.id, owner, 41, submitted.copy(phase = SynologyPhotoAlbumPhase.PENDING))
        val cold = SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "new"), 41).single()
        assertTrue(cold.checkpoint.temporaryCancelRequested); assertEquals(SynologyPhotoAlbumPhase.PENDING, cold.checkpoint.phase)
        failure { store.discard(cold) }
    }
    @Test fun `目录创建编号与封面回执单向保存未决目录阻止其他管理操作`() {
        val target = SynologyPhotoFolderSnapshot(9, 1, "Synthetic", "/Synthetic", SynologyPhotoSpace.PERSONAL)
        val record = row().copy(checkpoint = row().checkpoint.copy(action = SynologyPhotoAlbumAction.CREATE_FOLDER, name = null,
            folder = SynologyPhotoFolderCheckpoint(target, name = "New")))
        store.begin(record); val submitted = record.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)
        store.save(record.id, owner, 41, submitted)
        val pending = submitted.copy(phase = SynologyPhotoAlbumPhase.PENDING, folder = submitted.folder!!.copy(createdFolderId = 11))
        store.save(record.id, owner, 41, pending)
        failure { store.save(record.id, owner, 41, pending.copy(folder = pending.folder!!.copy(createdFolderId = null))) }
        failure { store.save(record.id, owner, 41, pending.copy(folder = pending.folder!!.copy(createdFolderId = 12))) }
        failure { store.save(record.id, owner, 41, pending.copy(folder = pending.folder!!.copy(target = target.copy(path = "/Changed", name = "Changed")))) }
        failure { store.begin(row()) }
        val cold = SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "new"), 41).single()
        assertEquals(11L, cold.checkpoint.folder!!.createdFolderId); assertEquals(target, cold.checkpoint.folder!!.target)
        store.save(record.id, owner, 41, pending.copy(phase = SynologyPhotoAlbumPhase.COMPLETED)); store.discard(store.get(record.id, owner, 41))
        val photo = SynologyPhotoEditTarget(SynologyPhoto(SynologyPhotoId(owner.profileId, target.space, 21), "Synthetic.jpg", 4, 1.0, 2.0, 9, "photo"))
        val cover = row().copy(checkpoint = row().checkpoint.copy(action = SynologyPhotoAlbumAction.COVER_FOLDER, name = null, folder = SynologyPhotoFolderCheckpoint(target, coverPhoto = photo)))
        store.begin(cover); val started = cover.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); store.save(cover.id, owner, 41, started)
        val acknowledged = started.copy(folder = started.folder!!.copy(coverAcknowledged = true)); store.save(cover.id, owner, 41, acknowledged)
        failure { store.save(cover.id, owner, 41, started) }
        assertTrue(SynologyPhotoAlbumStore(preferences).records(owner, 41).single().checkpoint.folder!!.coverAcknowledged)
    }
    private fun failure(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SynologyPhotoAlbumFailure) { } }
}

package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoSimilarStoreTest {
    private val owner = WorkspaceOwner("similar", "identity", "session")
    private val preferences = MemoryPreferences(); private val store = SynologyPhotoAlbumStore(preferences)
    private fun row(ids: List<Long> = listOf(51, 52, 53), edit: SynologyPhotoSimilarEdit = SynologyPhotoSimilarEdit.UNGROUP): SynologyPhotoAlbumRecord {
        val group = SynologyPhotoSimilarGroup(owner.profileId, SynologyPhotoSpace.PERSONAL, 7, ids, ids.first())
        return SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.EDIT_SIMILAR, targets = ids.map { SynologyPhotoEditTarget(
                SynologyPhotoId(owner.profileId, group.space, it), "synthetic-$it.jpg", 3, 1.0, 2.0, 9, "photo") },
            similar = SynologyPhotoSimilarCheckpoint(group, edit, if (edit == SynologyPhotoSimilarEdit.REMOVE) listOf(ids.last()) else emptyList())))
    }
    private fun complete(row: SynologyPhotoAlbumRecord): SynologyPhotoAlbumCheckpoint {
        store.begin(row)
        val attempted = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, similar = row.checkpoint.similar!!.copy(attempted = true))
        store.save(row.id, owner, 41, attempted)
        return attempted.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, similar = attempted.similar!!.copy(confirmed = true)).also { store.save(row.id, owner, 41, it) }
    }
    private fun undo(original: SynologyPhotoAlbumCheckpoint): SynologyPhotoAlbumRecord {
        val value = original.similar!!
        return SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.EDIT_SIMILAR, targets = original.targets, similar = SynologyPhotoSimilarCheckpoint(value.group,
                SynologyPhotoSimilarEdit.UNDO, undo = SynologyPhotoSimilarUndo(original.operationId, value.edit, value.selectedIds, value.resultingGroup))))
    }
    @Test fun `冷恢复保留完整大组身份和尝试且同账号重登可读不同身份不可读`() {
        val row = row((1L..101L).toList()); store.begin(row)
        val started = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, similar = row.checkpoint.similar!!.copy(attempted = true))
        store.save(row.id, owner, 41, started)
        val restored = SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "next"), 41).single()
        assertEquals(started.copy(phase = SynologyPhotoAlbumPhase.PENDING), restored.checkpoint); assertEquals(101, restored.checkpoint.targets.size)
        assertTrue(store.records(owner.copy(identityRevision = "other"), 41).isEmpty()); assertTrue(store.records(owner, 42).isEmpty())
        reject { store.discard(restored) }
    }
    @Test fun `原操作不可替换结果只能单向前进且完成不能降回未决`() {
        val row = row(); store.begin(row)
        val started = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, similar = row.checkpoint.similar!!.copy(attempted = true))
        store.save(row.id, owner, 41, started)
        reject { store.save(row.id, owner, 41, started.copy(similar = started.similar!!.copy(attempted = false))) }
        reject { store.save(row.id, owner, 41, started.copy(similar = started.similar!!.copy(group = started.similar.group.copy(topPickId = 52)))) }
        reject { store.save(row.id, owner, 41, started.copy(targets = started.targets.map { it.copy(sizeBytes = 9) })) }
        val done = started.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, similar = started.similar!!.copy(confirmed = true))
        store.save(row.id, owner, 41, done)
        reject { store.save(row.id, owner, 41, started.copy(phase = SynologyPhotoAlbumPhase.PENDING)) }
    }
    @Test fun `撤销只接受同账号已确认原动作及完整相同意图且跨重启拒绝第二编号`() {
        val original = complete(row()); val undo = undo(original)
        reject { store.begin(undo.copy(checkpoint = undo.checkpoint.copy(userId = 42))) }
        reject { store.begin(undo.copy(checkpoint = undo.checkpoint.copy(targets = undo.checkpoint.targets.map { it.copy(filename = "changed") }))) }
        store.begin(undo)
        val cold = SynologyPhotoAlbumStore(preferences)
        try { cold.begin(undo(original)); fail("Expected duplicate undo rejection") } catch (_: SynologyPhotoAlbumFailure) {}
        assertEquals(2, cold.records(owner, 41).size)
    }
    @Test fun `撤销缺原始记录或原动作未确认不能保存`() {
        val missing = row().checkpoint.copy(phase = SynologyPhotoAlbumPhase.COMPLETED).let { it.copy(similar = it.similar!!.copy(attempted = true, confirmed = true)) }
        reject { store.begin(undo(missing)) }
        val source = row(); store.begin(source)
        reject { store.begin(undo(source.checkpoint)) }
    }
    @Test fun `损坏成员混来源组属性响应进度及平行负载不能落盘`() {
        val row = row(); val c = row.checkpoint; val v = c.similar!!
        for (bad in listOf(c.copy(similar = v.copy(group = v.group.copy(photoIds = listOf(51)))),
            c.copy(similar = v.copy(group = v.group.copy(photoIds = listOf(51, 51, 53)))),
            c.copy(similar = v.copy(group = v.group.copy(topPickId = 99))), c.copy(targets = c.targets.dropLast(1)),
            c.copy(targets = c.targets.map { it.copy(id = it.id.copy(space = SynologyPhotoSpace.SHARED)) }),
            c.copy(targets = c.targets.map { it.copy(albumContext = SynologyPhotoAlbumContext(1, 41)) }),
            c.copy(similar = v.copy(attempted = true)), c.copy(similar = v.copy(selectedIds = listOf(51))),
            c.copy(phase = SynologyPhotoAlbumPhase.COMPLETED), c.copy(similar = v.copy(confirmed = true)),
            c.copy(people = SynologyPhotoPeopleCheckpoint(emptyList())), c.copy(action = SynologyPhotoAlbumAction.CREATE, name = "injected")))
            reject { store.begin(row.copy(checkpoint = bad)) }
        assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `推荐移出撤销的完成结果必须精确匹配所选变化`() {
        for (edit in listOf(SynologyPhotoSimilarEdit.TOP_PICK, SynologyPhotoSimilarEdit.REMOVE)) {
            val row = row(edit = edit).let { if (edit == SynologyPhotoSimilarEdit.TOP_PICK) it.copy(checkpoint = it.checkpoint.copy(similar = it.checkpoint.similar!!.copy(selectedIds = listOf(52)))) else it }
            store.begin(row); val c = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, similar = row.checkpoint.similar!!.copy(attempted = true))
            store.save(row.id, owner, 41, c)
            reject { store.save(row.id, owner, 41, c.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, similar = c.similar!!.copy(confirmed = true))) }
            val result = if (edit == SynologyPhotoSimilarEdit.TOP_PICK) c.similar!!.group.copy(topPickId = 52) else c.similar!!.group.copy(photoIds = listOf(51, 52))
            store.save(row.id, owner, 41, c.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, similar = c.similar!!.copy(confirmed = true, resultingGroup = result)))
        }
    }
    @Test fun `明确拒绝不可擦除未发送记录可结束且同组和原件互斥`() {
        val row = row(); store.begin(row)
        val c = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, similar = row.checkpoint.similar!!.copy(attempted = true, rejected = true))
        store.save(row.id, owner, 41, c); reject { store.begin(row()) }
        reject { store.save(row.id, owner, 41, c.copy(similar = c.similar!!.copy(rejected = false))) }
        store.save(row.id, owner, 41, c.copy(phase = SynologyPhotoAlbumPhase.PARTIAL))
        val next = row(); store.begin(next); store.save(next.id, owner, 41, next.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        store.save(next.id, owner, 41, next.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PARTIAL))
    }
    @Test fun `旧版本无相似字段记录继续可读不改变其他操作上限`() {
        val old = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic"))
        val original = Json.parseToJsonElement(Json { encodeDefaults = true }.encodeToString(old)).jsonObject
        val raw = JsonObject(original + ("checkpoint" to JsonObject(original.getValue("checkpoint").jsonObject - "similar")))
        preferences.edit().putString("photos_album_v1_${old.id}", raw.toString()).commit(); assertEquals(old, store.records(owner, 41).single())
        reject { store.begin(old.copy(checkpoint = old.checkpoint.copy(targets = row((1L..101L).toList()).checkpoint.targets))) }
    }
    @Test fun `多组顺序一次保存不可缺组混成员或者途中改变顺序`() {
        val a = row(); val b = row(listOf(61, 62)).let { it.copy(checkpoint = it.checkpoint.copy(similar = it.checkpoint.similar!!.copy(group = it.checkpoint.similar.group.copy(id = 8)))) }
        val order = listOf(a.id, b.id)
        val batch = listOf(a, b).map { it.copy(checkpoint = it.checkpoint.copy(similar = it.checkpoint.similar!!.copy(batchOrder = order))) }
        reject { store.beginSimilarBatch(batch.take(1)) }
        reject { store.beginSimilarBatch(batch.reversed()) }
        reject { store.beginSimilarBatch(listOf(batch.first(), batch.first())) }
        assertTrue(store.records(owner, 41).isEmpty())
        store.beginSimilarBatch(batch)
        val restored = SynologyPhotoAlbumStore(preferences).records(owner, 41)
        assertEquals(2, restored.size); assertTrue(restored.all { it.checkpoint.similar!!.batchOrder == order })
        val started = batch.first().checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)
        store.save(a.id, owner, 41, started)
        reject { store.save(a.id, owner, 41, started.copy(similar = started.similar!!.copy(batchOrder = order.reversed()))) }
    }
    @Test fun `保留原动作时撤销记录不得清除以防换编号重复撤销`() {
        val source = row(); val original = complete(source); val undo = undo(original); store.begin(undo)
        reject { store.discard(undo) }
        store.discard(store.get(source.id, owner, 41)); store.discard(undo)
        assertTrue(store.records(owner, 41).isEmpty())
    }
    private fun reject(block: () -> Unit) { try { block(); fail("Expected storage rejection") } catch (_: SynologyPhotoAlbumFailure) {} }
}

package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoConceptStoreTest {
    private val owner = WorkspaceOwner("concepts", "identity", "session")
    private val preferences = MemoryPreferences(); private val store = SynologyPhotoAlbumStore(preferences)
    private fun row(action: SynologyPhotoAlbumAction = SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS) = SynologyPhotoAlbumRecord(owner = owner,
        checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = action,
            targets = if (action == SynologyPhotoAlbumAction.SHOW_CONCEPTS) emptyList() else
                (if (action == SynologyPhotoAlbumAction.COVER_CONCEPT) listOf(51L) else listOf(51L, 52L)).map {
                    SynologyPhotoEditTarget(SynologyPhotoId(owner.profileId, SynologyPhotoSpace.PERSONAL, it), "Synthetic-$it.jpg", 4, 1.0, 2.0, 9, "photo") },
            concept = SynologyPhotoConceptCheckpoint((if (action == SynologyPhotoAlbumAction.SHOW_CONCEPTS) listOf(1L, 2L) else listOf(1L)).map {
                SynologyPhotoConceptSnapshot(it, "Synthetic $it", SynologyPhotoSpace.PERSONAL, true, 3, 2, 88, "cover-r") },
                visible = false.takeIf { action == SynologyPhotoAlbumAction.SHOW_CONCEPTS })))
    @Test fun `冷恢复保留固定主题原件和尝试但不串账号身份`() {
        val row = row(); store.begin(row)
        val started = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, concept = row.checkpoint.concept!!.copy(attempted = true))
        store.save(row.id, owner, 41, started)
        val cold = SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "next"), 41).single()
        assertEquals(started.copy(phase = SynologyPhotoAlbumPhase.PENDING), cold.checkpoint)
        assertTrue(store.records(owner.copy(identityRevision = "other"), 41).isEmpty()); assertTrue(store.records(owner, 42).isEmpty())
        reject { store.discard(cold) }
        val raw = preferences.all.values.single().toString()
        for (key in listOf("SynoToken", "Cookie", "SID", "image_bytes", "base64")) assertFalse(raw.contains(key))
    }
    @Test fun `意图原件封面阈值显示与来源不可替换且进度单向`() {
        val row = row(); store.begin(row); val start = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)
        store.save(row.id, owner, 41, start)
        val attempted = start.copy(concept = start.concept!!.copy(attempted = true)); store.save(row.id, owner, 41, attempted)
        reject { store.save(row.id, owner, 41, start) }
        val ack = attempted.copy(concept = attempted.concept!!.copy(acknowledged = true)); store.save(row.id, owner, 41, ack)
        reject { store.save(row.id, owner, 41, attempted) }
        val original = ack.concept!!.originals.single()
        for (changed in listOf(original.copy(name = "Changed"), original.copy(count = 4), original.copy(displayThreshold = 4),
            original.copy(coverUnitId = 89), original.copy(coverRevision = "Changed"), original.copy(visible = false), original.copy(space = SynologyPhotoSpace.SHARED)))
            reject { store.save(row.id, owner, 41, ack.copy(concept = ack.concept.copy(originals = listOf(changed)))) }
        reject { store.save(row.id, owner, 41, ack.copy(targets = ack.targets.map { it.copy(filename = "Changed.jpg") })) }
        val done = ack.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, concept = ack.concept.copy(completedIds = setOf(1), removedPhotoIds = setOf(51, 52), updated = listOf(original.copy(count = 1))))
        store.save(row.id, owner, 41, done); reject { store.save(row.id, owner, 41, ack) }
        store.discard(store.get(row.id, owner, 41)); assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `部分显示和部分移除需要回执且结果不可越界`() {
        for (action in listOf(SynologyPhotoAlbumAction.SHOW_CONCEPTS, SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS)) {
            val prefs = MemoryPreferences(); val s = SynologyPhotoAlbumStore(prefs); val row = row(action); s.begin(row)
            val tried = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, concept = row.checkpoint.concept!!.copy(attempted = true))
            s.save(row.id, owner, 41, tried)
            val partial = tried.copy(phase = SynologyPhotoAlbumPhase.PARTIAL, concept = tried.concept!!.copy(
                completedIds = if (action == SynologyPhotoAlbumAction.SHOW_CONCEPTS) setOf(1) else emptySet(),
                removedPhotoIds = if (action == SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS) setOf(51) else emptySet(),
                updated = tried.concept.originals.take(1).map { if (action == SynologyPhotoAlbumAction.SHOW_CONCEPTS) it.copy(visible = false) else it.copy(count = 2) }))
            reject { s.save(row.id, owner, 41, partial) }
            reject { s.save(row.id, owner, 41, partial.copy(concept = partial.concept!!.copy(acknowledged = true, completedIds = setOf(99)))) }
            s.save(row.id, owner, 41, partial.copy(concept = partial.concept!!.copy(acknowledged = true)))
            assertTrue(s.records(owner, 41).single().checkpoint.finished)
        }
    }
    @Test fun `完整移除必须所有目标原件已核实封面不能夹带移出结果`() {
        val c = row().checkpoint
        val start = c.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, concept = c.concept!!.copy(attempted = true, acknowledged = true, completedIds = setOf(1)))
        for (bad in listOf(start, start.copy(concept = start.concept!!.copy(removedPhotoIds = setOf(51))),
            start.copy(concept = start.concept!!.copy(removedPhotoIds = setOf(51, 52, 99))),
            start.copy(concept = start.concept!!.copy(completedIds = emptySet(), removedPhotoIds = setOf(51, 52))))) {
            val p = MemoryPreferences(); val s = SynologyPhotoAlbumStore(p); val record = row(); s.begin(record)
            val same = bad.copy(operationId = record.id)
            s.save(record.id, owner, 41, record.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
            reject { s.save(record.id, owner, 41, same) }
        }
        val cover = row(SynologyPhotoAlbumAction.COVER_CONCEPT)
        reject { store.begin(cover.copy(checkpoint = cover.checkpoint.copy(concept = cover.checkpoint.concept!!.copy(removedPhotoIds = setOf(51))))) }
    }
    @Test fun `未决同主题和同原件互斥而不同主题可以独立准备`() {
        val row = row(); store.begin(row); store.save(row.id, owner, 41, row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        reject { store.begin(row(SynologyPhotoAlbumAction.SHOW_CONCEPTS)) }
        val samePhoto = row().let { it.copy(checkpoint = it.checkpoint.copy(concept = it.checkpoint.concept!!.copy(originals = it.checkpoint.concept.originals.map { v -> v.copy(id = 9) }))) }
        reject { store.begin(samePhoto) }
        val other = row(SynologyPhotoAlbumAction.SHOW_CONCEPTS).let { it.copy(checkpoint = it.checkpoint.copy(concept = it.checkpoint.concept!!.copy(originals = it.checkpoint.concept.originals.map { v -> v.copy(id = v.id + 10) }))) }
        store.begin(other); assertEquals(2, store.records(owner, 41).size)
    }
    @Test fun `非法空集合重复混来源缺阈值和相册上下文不能落盘`() {
        val row = row(); val c = row.checkpoint; val v = c.concept!!
        for (bad in listOf(c.copy(concept = v.copy(originals = emptyList())), c.copy(concept = v.copy(originals = v.originals + v.originals)),
            c.copy(concept = v.copy(originals = v.originals.map { it.copy(displayThreshold = null) })),
            c.copy(concept = v.copy(originals = v.originals.map { it.copy(visible = null) })),
            c.copy(concept = v.copy(originals = v.originals.map { it.copy(coverRevision = null) })),
            c.copy(targets = c.targets.map { it.copy(id = it.id.copy(space = SynologyPhotoSpace.SHARED)) }),
            c.copy(targets = c.targets.map { it.copy(albumContext = SynologyPhotoAlbumContext(5, 41)) }),
            c.copy(action = SynologyPhotoAlbumAction.CREATE, name = "Injected"), c.copy(people = SynologyPhotoPeopleCheckpoint(emptyList())),
            c.copy(concept = v.copy(attempted = true)))) reject { store.begin(row.copy(checkpoint = bad)) }
        assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `明确拒绝不能撤销或变成功未尝试记录允许结束`() {
        val row = row(); store.begin(row)
        val denied = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, concept = row.checkpoint.concept!!.copy(attempted = true, rejected = true))
        store.save(row.id, owner, 41, denied)
        reject { store.save(row.id, owner, 41, denied.copy(concept = denied.concept!!.copy(rejected = false, acknowledged = true))) }
        reject { store.save(row.id, owner, 41, denied.copy(concept = denied.concept!!.copy(completedIds = setOf(1), removedPhotoIds = setOf(51, 52)))) }
        store.save(row.id, owner, 41, denied.copy(phase = SynologyPhotoAlbumPhase.PARTIAL))
        val next = row(); store.begin(next); store.save(next.id, owner, 41, next.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        store.save(next.id, owner, 41, next.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PARTIAL))
        assertEquals(2, store.records(owner, 41).size)
    }
    @Test fun `旧版本没有主题字段的相册记录仍然可读`() {
        val old = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic"))
        val json = Json { encodeDefaults = true }; val original = Json.parseToJsonElement(json.encodeToString(old)).jsonObject
        val encoded = JsonObject(original + ("checkpoint" to JsonObject(original.getValue("checkpoint").jsonObject - "concept")))
        preferences.edit().putString("photos_album_v1_${old.id}", encoded.toString()).commit()
        assertEquals(old, store.records(owner, 41).single())
    }
    private fun reject(block: () -> Unit) { try { block(); fail("Expected storage rejection") } catch (_: SynologyPhotoAlbumFailure) {} }
}

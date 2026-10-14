package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoPeopleStoreTest {
    private val owner = WorkspaceOwner("people", "identity", "session")
    private val preferences = MemoryPreferences(); private val store = SynologyPhotoAlbumStore(preferences)
    private fun row(action: SynologyPhotoAlbumAction = SynologyPhotoAlbumAction.RENAME_PERSON) = SynologyPhotoAlbumRecord(owner = owner,
        checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = action,
            people = SynologyPhotoPeopleCheckpoint(originals = (if (action == SynologyPhotoAlbumAction.RENAME_PERSON) listOf(1L) else listOf(1L, 2L)).map {
                SynologyPhotoPersonSnapshot(it, "Synthetic $it", 1, SynologyPhotoSpace.PERSONAL, true) },
                name = "".takeUnless { action == SynologyPhotoAlbumAction.SHOW_PEOPLE }, visible = false.takeIf { action == SynologyPhotoAlbumAction.SHOW_PEOPLE },
                memberIds = setOf(51L, 52L).takeIf { action == SynologyPhotoAlbumAction.MERGE_PEOPLE })))
    @Test fun `冷恢复保留人物来源原名计数状态及成员并集但不串账号`() {
        val row = row(SynologyPhotoAlbumAction.MERGE_PEOPLE); store.begin(row)
        val submitting = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); store.save(row.id, owner, 41, submitting)
        val attempted = submitting.copy(people = submitting.people!!.copy(attempted = true)); store.save(row.id, owner, 41, attempted)
        val cold = SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "new"), 41).single()
        assertEquals(attempted.copy(phase = SynologyPhotoAlbumPhase.PENDING), cold.checkpoint)
        assertTrue(store.records(owner.copy(identityRevision = "other"), 41).isEmpty()); assertTrue(store.records(owner, 42).isEmpty())
        reject { store.save(row.id, owner, 41, cold.checkpoint.copy(people = cold.checkpoint.people!!.copy(memberIds = setOf(51)))) }
        reject { store.discard(cold) }
    }
    @Test fun `已记录意图来源目标与成员不可变且尝试回执与结果只向前`() {
        val row = row(); store.begin(row)
        val start = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); store.save(row.id, owner, 41, start)
        val tried = start.copy(people = start.people!!.copy(attempted = true)); store.save(row.id, owner, 41, tried)
        reject { store.save(row.id, owner, 41, start) }
        val ack = tried.copy(people = tried.people!!.copy(acknowledged = true, nameReceipt = true)); store.save(row.id, owner, 41, ack)
        reject { store.save(row.id, owner, 41, tried) }
        for (changed in listOf(ack.people!!.copy(name = "Changed"), ack.people.copy(originals = ack.people.originals.map { it.copy(space = SynologyPhotoSpace.SHARED) }),
            ack.people.copy(originals = ack.people.originals.map { it.copy(count = 2) }), ack.people.copy(originals = ack.people.originals.map { it.copy(name = "Changed") }))) {
            reject { store.save(row.id, owner, 41, ack.copy(people = changed)) }
        }
        val done = ack.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, people = ack.people.copy(completedIds = setOf(1), removedIds = setOf(1)))
        store.save(row.id, owner, 41, done); reject { store.save(row.id, owner, 41, ack) }
        store.discard(store.get(row.id, owner, 41)); assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `清空小分组丢回执不得保存消失成功显示部分结果必须明确回执`() {
        val name = row(); store.begin(name)
        val attempted = name.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, people = name.checkpoint.people!!.copy(attempted = true))
        store.save(name.id, owner, 41, attempted)
        reject { store.save(name.id, owner, 41, attempted.copy(phase = SynologyPhotoAlbumPhase.COMPLETED,
            people = attempted.people!!.copy(completedIds = setOf(1), removedIds = setOf(1)))) }
        val p = MemoryPreferences(); val s = SynologyPhotoAlbumStore(p); val visibility = row(SynologyPhotoAlbumAction.SHOW_PEOPLE); s.begin(visibility)
        val started = visibility.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, people = visibility.checkpoint.people!!.copy(attempted = true))
        s.save(visibility.id, owner, 41, started)
        val partial = started.copy(phase = SynologyPhotoAlbumPhase.PARTIAL, people = started.people!!.copy(completedIds = setOf(1)))
        reject { s.save(visibility.id, owner, 41, partial) }
        s.save(visibility.id, owner, 41, partial.copy(people = partial.people!!.copy(acknowledged = true)))
        assertEquals(setOf(1L), s.records(owner, 41).single().checkpoint.people!!.completedIds)
    }
    @Test fun `明确拒绝不能撤销或补成成功未尝试中断可以只读结束`() {
        val row = row(); store.begin(row); val started = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)
        store.save(row.id, owner, 41, started)
        val rejected = started.copy(people = started.people!!.copy(attempted = true, rejected = true)); store.save(row.id, owner, 41, rejected)
        reject { store.save(row.id, owner, 41, started) }
        reject { store.save(row.id, owner, 41, rejected.copy(people = rejected.people!!.copy(acknowledged = true))) }
        store.save(row.id, owner, 41, rejected.copy(phase = SynologyPhotoAlbumPhase.PARTIAL))
        val next = row(); store.begin(next); store.save(next.id, owner, 41, next.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        store.save(next.id, owner, 41, next.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PARTIAL))
        assertEquals(2, store.records(owner, 41).size)
    }
    @Test fun `同来源同人物未决阻止冲突不同人物保留独立管理`() {
        val row = row(); store.begin(row); store.save(row.id, owner, 41, row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        reject { store.begin(row()) }
        val another = row().let { it.copy(checkpoint = it.checkpoint.copy(people = it.checkpoint.people!!.copy(originals = listOf(
            SynologyPhotoPersonSnapshot(9, "Different", 1, SynologyPhotoSpace.PERSONAL, true))))) }
        store.begin(another)
        val album = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic"))
        reject { store.begin(album) }; assertEquals(2, store.records(owner, 41).size)
    }
    @Test fun `非法空集合多来源无show越界成员及其他动作夹带人物字段拒绝落盘`() {
        val row = row(SynologyPhotoAlbumAction.MERGE_PEOPLE); val checkpoint = row.checkpoint; val value = checkpoint.people!!
        for (bad in listOf(checkpoint.copy(name = "Injected"), checkpoint.copy(action = SynologyPhotoAlbumAction.CREATE, name = "Injected"),
            checkpoint.copy(people = value.copy(originals = emptyList())), checkpoint.copy(people = value.copy(originals = value.originals.take(1))),
            checkpoint.copy(people = value.copy(memberIds = setOf(0))), checkpoint.copy(people = value.copy(attempted = true)),
            checkpoint.copy(people = value.copy(originals = value.originals.mapIndexed { i, p -> if (i == 0) p.copy(space = SynologyPhotoSpace.SHARED) else p })),
            checkpoint.copy(people = value.copy(completedIds = setOf(9))))) reject { store.begin(row.copy(checkpoint = bad)) }
        assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `旧版本没有人物字段仍可读新记录无原图人脸或凭据`() {
        val row = row(SynologyPhotoAlbumAction.MERGE_PEOPLE); store.begin(row)
        val raw = preferences.all.values.single().toString()
        assertFalse(raw.contains("face_id")); assertFalse(raw.contains("thumbnail")); assertFalse(raw.contains("SynoToken")); assertFalse(raw.contains("Cookie"))
        val old = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic"))
        val json = Json { encodeDefaults = true }; val original = Json.parseToJsonElement(json.encodeToString(old)).jsonObject
        val encoded = JsonObject(original + ("checkpoint" to JsonObject(original.getValue("checkpoint").jsonObject - "people")))
        preferences.edit().clear().putString("photos_album_v1_${old.id}", encoded.toString()).commit()
        assertEquals(old, store.records(owner, 41).single())
    }
    private fun faceRow(action: SynologyPhotoAlbumAction = SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES): SynologyPhotoAlbumRecord {
        val photo = SynologyPhotoEditTarget(SynologyPhotoId(owner.profileId, SynologyPhotoSpace.PERSONAL, 51), "Synthetic.jpg", 4, 1.0, 2.0, 9, "photo")
        return SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = action, targets = listOf(photo), people = SynologyPhotoPeopleCheckpoint(listOf(SynologyPhotoPersonSnapshot(1, "Synthetic", 1, photo.id.space)),
                name = "New synthetic".takeIf { action == SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES },
                faces = SynologyPhotoPersonFacesCheckpoint(if (action == SynologyPhotoAlbumAction.COVER_PERSON) emptyList() else listOf(SynologyPhotoPersonFaceSnapshot(101, photo.id))))))
    }
    @Test fun `人脸和封面冷恢复仅保留固定原件人脸关系及明确回执`() {
        for (action in listOf(SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES, SynologyPhotoAlbumAction.COVER_PERSON)) {
            val p = MemoryPreferences(); val s = SynologyPhotoAlbumStore(p); val row = faceRow(action); s.begin(row)
            val started = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, people = row.checkpoint.people!!.copy(attempted = true))
            s.save(row.id, owner, 41, started)
            val faces = if (action == SynologyPhotoAlbumAction.COVER_PERSON) started.people!!.faces!!.copy(coverReceipt = 701) else started.people!!.faces!!.copy(targetReceipt = 90)
            val ack = started.copy(people = started.people!!.copy(acknowledged = true, faces = faces)); s.save(row.id, owner, 41, ack)
            val cold = SynologyPhotoAlbumStore(p).records(owner.copy(sessionGeneration = "next"), 41).single()
            assertEquals(ack.copy(phase = SynologyPhotoAlbumPhase.PENDING), cold.checkpoint)
            val raw = p.all.values.single().toString()
            for (secret in listOf("thumbnail", "cache_key", "SynoToken", "Cookie", "face_image")) assertFalse(raw.contains(secret))
            reject { s.save(row.id, owner, 41, cold.checkpoint.copy(people = cold.checkpoint.people!!.copy(faces = faces.copy(targetReceipt = null, coverReceipt = null)))) }
        }
    }
    @Test fun `人脸意图原件目标与回执不可替换且照片结果只向前`() {
        val row = faceRow(); store.begin(row); val source = row.checkpoint
        val started = source.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, people = source.people!!.copy(attempted = true))
        store.save(row.id, owner, 41, started)
        val ack = started.copy(people = started.people!!.copy(acknowledged = true, faces = started.people.faces!!.copy(targetReceipt = 90)))
        store.save(row.id, owner, 41, ack)
        for (bad in listOf(ack.copy(targets = ack.targets.map { it.copy(filename = "Other.jpg") }),
            ack.copy(people = ack.people!!.copy(name = "Other")),
            ack.copy(people = ack.people!!.copy(faces = ack.people.faces!!.copy(selected = ack.people.faces.selected.map { it.copy(id = 102) }))),
            ack.copy(people = ack.people!!.copy(faces = ack.people.faces!!.copy(targetReceipt = 91))))) reject { store.save(row.id, owner, 41, bad) }
        val done = ack.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, people = ack.people!!.copy(completedIds = setOf(1), faces = ack.people.faces!!.copy(removedPhotoIds = setOf(51))))
        store.save(row.id, owner, 41, done)
        reject { store.save(row.id, owner, 41, done.copy(people = done.people!!.copy(faces = done.people.faces!!.copy(removedPhotoIds = emptySet())))) }
    }
    @Test fun `未知新人物和丢封面回执禁止落盘成功且拒绝跨来源相册混入`() {
        for (action in listOf(SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES, SynologyPhotoAlbumAction.COVER_PERSON)) {
            val row = faceRow(action); val c = row.checkpoint
            for (bad in listOf(c.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, people = c.people!!.copy(attempted = true, completedIds = setOf(1))),
                c.copy(targets = c.targets.map { it.copy(id = it.id.copy(space = SynologyPhotoSpace.SHARED)) }),
                c.copy(targets = c.targets.map { it.copy(albumContext = SynologyPhotoAlbumContext(5, 41)) }),
                c.copy(people = c.people!!.copy(faces = c.people.faces!!.copy(removedPhotoIds = setOf(51)))),
                c.copy(people = c.people!!.copy(faces = c.people.faces!!.copy(targetReceipt = 90))))) reject { store.begin(row.copy(checkpoint = bad)) }
        }
        assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `已回执新人物和同照片其他人物在未决期间阻止重叠写入`() {
        val row = faceRow(); store.begin(row); val started = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING,
            people = row.checkpoint.people!!.copy(attempted = true, acknowledged = true, faces = row.checkpoint.people.faces!!.copy(targetReceipt = 90)))
        store.save(row.id, owner, 41, started)
        val target = row().let { it.copy(checkpoint = it.checkpoint.copy(people = it.checkpoint.people!!.copy(originals = listOf(SynologyPhotoPersonSnapshot(90, "New synthetic", 1, SynologyPhotoSpace.PERSONAL))))) }
        reject { store.begin(target) }
        val samePhoto = faceRow().let { it.copy(checkpoint = it.checkpoint.copy(people = it.checkpoint.people!!.copy(originals = listOf(SynologyPhotoPersonSnapshot(2, "Other", 1, SynologyPhotoSpace.PERSONAL))))) }
        reject { store.begin(samePhoto) }
    }
    private fun reject(block: () -> Unit) { try { block(); fail("Expected storage rejection") } catch (_: SynologyPhotoAlbumFailure) {} }
}

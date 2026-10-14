package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoManualFacesCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoManualFacesStoreTest {
    private val owner = WorkspaceOwner("manual", "identity", "session")
    private val prefs = MemoryPreferences(); private val store = SynologyPhotoAlbumStore(prefs)
    private val bounds = SynologyPhotoFaceBounds(0.1, 0.2, 0.2, 0.3)
    private val original = SynologyPhotoFaceSnapshot(101, 1, "Synthetic", bounds)
    private val add = SynologyPhotoFaceChange.Add("draft", bounds, null, "New synthetic", "a".repeat(64))
    private fun record() = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId,
        userId = 41, action = SynologyPhotoAlbumAction.EDIT_PHOTO_FACES,
        targets = listOf(SynologyPhotoEditTarget(SynologyPhotoId(owner.profileId, SynologyPhotoSpace.PERSONAL, 51), "Synthetic.jpg", 4, 1.0, 2.0, 9, "photo")),
        manualFaces = SynologyPhotoManualFacesCheckpoint(listOf(original), listOf(add, SynologyPhotoFaceChange.Remove(original)))))
    private fun started(record: SynologyPhotoAlbumRecord): SynologyPhotoAlbumCheckpoint {
        store.begin(record)
        return record.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING).also { store.save(record.id, owner, 41, it) }
    }
    private fun uploaded(record: SynologyPhotoAlbumRecord): SynologyPhotoAlbumCheckpoint {
        val row = started(record)
        return row.copy(manualFaces = row.manualFaces!!.copy(addAttempted = true, addAcknowledged = true,
            newIds = mapOf("draft" to 901), uploadAttempted = setOf(901), uploaded = setOf(901))).also { store.save(record.id, owner, 41, it) }
    }
    @Test fun `冷恢复保留多步事实与摘要不保存图像且SUBMITTING转PENDING`() {
        val record = record(); val row = uploaded(record)
        val cold = SynologyPhotoAlbumStore(prefs).records(owner.copy(sessionGeneration = "next"), 41).single().checkpoint
        assertEquals(row.copy(phase = SynologyPhotoAlbumPhase.PENDING), cold)
        val raw = prefs.all.values.single().toString()
        assertTrue(raw.contains("jpegDigest"))
        for (secret in listOf("face.jpg", "image/jpeg", "cache_key", "Cookie", "SynoToken", "base64")) assertFalse(raw.contains(secret))
        reject { store.save(record.id, owner, 41, row) }
    }
    @Test fun `照片原框目标名称坐标临时编号摘要都不能在写后替换`() {
        val record = record(); val row = uploaded(record); val value = row.manualFaces!!
        for (changed in listOf(add.copy(temporaryId = "other"), add.copy(name = "Other"), add.copy(bounds = bounds.copy(x = 0.2)),
            add.copy(jpegDigest = "b".repeat(64)), add.copy(person = SynologyPhotoPersonSnapshot(2, add.name, 1, SynologyPhotoSpace.PERSONAL)))) {
            reject { store.save(record.id, owner, 41, row.copy(manualFaces = value.copy(changes = listOf(changed, value.changes.last())))) }
        }
        reject { store.save(record.id, owner, 41, row.copy(targets = row.targets.map { it.copy(filename = "Other.jpg") })) }
        reject { store.save(record.id, owner, 41, row.copy(manualFaces = value.copy(originals = listOf(original.copy(personId = 2))))) }
    }
    @Test fun `回执与上传事实不能回退错配或提前删除旧框`() {
        val record = record(); val row = uploaded(record); val value = row.manualFaces!!
        for (bad in listOf(value.copy(addAttempted = false), value.copy(addAcknowledged = false), value.copy(newIds = mapOf("draft" to 902)),
            value.copy(newIds = mapOf("draft" to 101)), value.copy(uploadAttempted = emptySet()), value.copy(uploaded = emptySet())))
            reject { store.save(record.id, owner, 41, row.copy(manualFaces = bad)) }
        val p = MemoryPreferences(); val s = SynologyPhotoAlbumStore(p); val second = record(); s.begin(second)
        val invalid = second.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING, manualFaces = second.checkpoint.manualFaces!!.copy(attempted = setOf("old-101")))
        reject { s.save(second.id, owner, 41, invalid) }
    }
    @Test fun `未知新增不能伪造完成或失败未发送的后续步骤可以结束部分结果`() {
        val record = record(); val start = started(record)
        val unknown = start.copy(manualFaces = start.manualFaces!!.copy(addAttempted = true)); store.save(record.id, owner, 41, unknown)
        reject { store.save(record.id, owner, 41, unknown.copy(phase = SynologyPhotoAlbumPhase.COMPLETED,
            manualFaces = unknown.manualFaces!!.copy(completed = setOf("new-draft", "old-101")))) }
        reject { store.save(record.id, owner, 41, unknown.copy(phase = SynologyPhotoAlbumPhase.PARTIAL,
            manualFaces = unknown.manualFaces!!.copy(failed = setOf("new-draft", "old-101")))) }
        val ack = unknown.copy(manualFaces = unknown.manualFaces!!.copy(addAcknowledged = true)); store.save(record.id, owner, 41, ack)
        val done = ack.copy(phase = SynologyPhotoAlbumPhase.PARTIAL, manualFaces = ack.manualFaces!!.copy(failed = setOf("new-draft", "old-101")))
        store.save(record.id, owner, 41, done)
        reject { store.save(record.id, owner, 41, ack) }
    }
    @Test fun `未发上传不能伪造成功明确拒绝不能改成已上传`() {
        val record = record(); val row = started(record)
        val ack = row.copy(manualFaces = row.manualFaces!!.copy(addAttempted = true, addAcknowledged = true, newIds = mapOf("draft" to 901)))
        store.save(record.id, owner, 41, ack)
        reject { store.save(record.id, owner, 41, ack.copy(manualFaces = ack.manualFaces!!.copy(completed = setOf("new-draft")))) }
        val rejected = ack.copy(manualFaces = ack.manualFaces!!.copy(uploadAttempted = setOf(901), rejected = setOf("new-draft")))
        store.save(record.id, owner, 41, rejected)
        reject { store.save(record.id, owner, 41, rejected.copy(manualFaces = rejected.manualFaces!!.copy(uploaded = setOf(901)))) }
        reject { store.save(record.id, owner, 41, rejected.copy(manualFaces = rejected.manualFaces!!.copy(rejected = emptySet()))) }
    }
    @Test fun `新人物重新归入的实际编号不能凭空注入或改写`() {
        val source = record(); val change = SynologyPhotoFaceChange.Reassign(original, null, "New synthetic")
        val record = source.copy(checkpoint = source.checkpoint.copy(manualFaces = SynologyPhotoManualFacesCheckpoint(listOf(original), listOf(change))))
        val row = started(record); val value = row.manualFaces!!
        reject { store.save(record.id, owner, 41, row.copy(manualFaces = value.copy(personReceipts = mapOf(change.key to 90)))) }
        val ack = row.copy(manualFaces = value.copy(attempted = setOf(change.key), acknowledged = setOf(change.key), personReceipts = mapOf(change.key to 90)))
        store.save(record.id, owner, 41, ack)
        reject { store.save(record.id, owner, 41, ack.copy(manualFaces = ack.manualFaces!!.copy(personReceipts = mapOf(change.key to 91)))) }
        val done = ack.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, manualFaces = ack.manualFaces!!.copy(completed = setOf(change.key)))
        store.save(record.id, owner, 41, done); store.discard(store.get(record.id, owner, 41)); assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `旧记录缺可选手工人脸字段仍可读取且其他动作夹带该字段拒绝`() {
        val source = record()
        reject { store.begin(source.copy(checkpoint = source.checkpoint.copy(action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic"))) }
        val old = source.copy(checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic"))
        val json = Json { encodeDefaults = true }; val raw = Json.parseToJsonElement(json.encodeToString(old)).jsonObject
        val value = JsonObject(raw + ("checkpoint" to JsonObject(raw.getValue("checkpoint").jsonObject - "manualFaces")))
        prefs.edit().putString("photos_album_v1_${old.id}", value.toString()).commit()
        assertEquals(old, store.records(owner, 41).single())
    }
    @Test fun `同照片未决阻止新编辑与人物管理不会串账号读取`() {
        val record = record(); started(record)
        reject { store.begin(record()) }
        val people = record().let { it.copy(checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.RENAME_PERSON, people = SynologyPhotoPeopleCheckpoint(listOf(
                SynologyPhotoPersonSnapshot(1, "Synthetic", 1, SynologyPhotoSpace.PERSONAL)), name = "Changed"))) }
        reject { store.begin(people) }
        assertTrue(store.records(owner.copy(profileId = "other"), 41).isEmpty()); assertTrue(store.records(owner, 99).isEmpty())
    }
    @Test fun `解码拒绝重复编号非法坐标负人物及错误字段类型`() {
        fun row(id: String = "101", person: String = "1", x: String = "0.1", right: String = "0.3") =
            """{"face_id":$id,"person_id":$person,"name":"Synthetic","face_bounding_box":{"top_left":{"x":$x,"y":0.2},"bottom_right":{"x":$right,"y":0.5}}}"""
        for (raw in listOf("[${row()},${row()}]", "[${row(id = "0")}]", "[${row(person = "-1")}]", "[${row(x = "-0.1")}]",
            "[${row(right = "1.1")}]", "[${row(right = "0.1")}]", "[${row(x = "\"0.1\"")}]") ) {
            try { SynologyPhotoManualFacesCodec.faces(Json.parseToJsonElement("{\"list\":$raw}").jsonObject); fail("Expected invalid face") }
            catch (_: SynologyPhotoFailure) { }
        }
    }
    private fun reject(block: () -> Unit) { try { block(); fail("Expected storage rejection") } catch (_: SynologyPhotoAlbumFailure) {} }
}

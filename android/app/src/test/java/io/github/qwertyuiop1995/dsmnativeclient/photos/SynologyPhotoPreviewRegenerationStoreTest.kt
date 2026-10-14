package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoPreviewFact.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoPreviewRegenerationStoreTest {
    private val owner = WorkspaceOwner("preview", "identity", "session")
    private val preferences = MemoryPreferences()
    private val store = SynologyPhotoAlbumStore(preferences)
    private fun row() = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(
        profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.REGENERATE_PREVIEWS,
        targets = listOf(SynologyPhotoEditTarget(SynologyPhotoId(owner.profileId, SynologyPhotoSpace.PERSONAL, 51), "Synthetic.jpg", 4, 1.0, 2.0, 9, "photo")),
        previews = SynologyPhotoPreviewRegeneration(false, listOf(SynologyPhotoPreviewProgress(151, "old")))))
    private fun SynologyPhotoAlbumCheckpoint.facts(vararg values: SynologyPhotoPreviewFact) = copy(previews = previews!!.copy(progress = listOf(previews.progress.single().adding(*values))))

    @Test fun `冷恢复保留事实且不能删除或倒退未决写入`() {
        val row = row(); store.begin(row)
        val started = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); store.save(row.id, owner, 41, started)
        val sent = started.facts(MARK_ATTEMPTED, MARKED, NAS_ATTEMPTED); store.save(row.id, owner, 41, sent)
        val cold = SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "new"), 41).single()
        assertEquals(sent.copy(phase = SynologyPhotoAlbumPhase.PENDING), cold.checkpoint)
        reject { store.discard(cold) }; reject { store.save(row.id, owner, 41, started) }
        assertTrue(store.records(owner.copy(identityRevision = "different"), 41).isEmpty()); assertTrue(store.records(owner, 42).isEmpty())
        reject { store.save(row.id, owner, 41, cold.checkpoint.facts(FAILED).copy(phase = SynologyPhotoAlbumPhase.PARTIAL)) }
        reject { store.save(row.id, owner, 41, cold.checkpoint.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, completed = setOf(0))) }
    }
    @Test fun `固定原件基线与恢复模式不能中途替换`() {
        val row = row(); store.begin(row); val started = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); store.save(row.id, owner, 41, started)
        val value = started.previews!!
        for (next in listOf(started.copy(previews = value.copy(resuming = true)), started.copy(previews = value.copy(progress = listOf(SynologyPhotoPreviewProgress(151, "other")))),
            started.copy(targets = listOf(started.targets.single().copy(filename = "Changed.jpg"))), started.copy(previews = null))) {
            reject { store.save(row.id, owner, 41, next) }
        }
    }
    @Test fun `生成完成还需最终读取事实终态才可清理`() {
        val row = row(); store.begin(row); val started = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); store.save(row.id, owner, 41, started)
        val generated = started.facts(MARK_ATTEMPTED, MARKED, LOCAL_ATTEMPTED, GENERATED); store.save(row.id, owner, 41, generated)
        reject { store.discard(store.get(row.id, owner, 41)) }
        val completed = generated.copy(completed = setOf(0), phase = SynologyPhotoAlbumPhase.COMPLETED)
        store.save(row.id, owner, 41, completed); reject { store.save(row.id, owner, 41, generated) }
        store.discard(store.get(row.id, owner, 41)); assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `未知标记不能直接终止还原也不能伪装生成成功`() {
        val row = row(); store.begin(row); val started = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); store.save(row.id, owner, 41, started)
        for (facts in listOf(setOf(MARK_ATTEMPTED, FAILED), setOf(MARK_ATTEMPTED, MARKED, LOCAL_ATTEMPTED, NAS_ATTEMPTED),
            setOf(MARK_ATTEMPTED, MARKED, LOCAL_ATTEMPTED, RESTORE_ATTEMPTED), setOf(MARK_ATTEMPTED, MARKED, NAS_ATTEMPTED, NAS_FAILED, GENERATED),
            setOf(MARK_ATTEMPTED, MARKED, NAS_ATTEMPTED, NAS_FAILED, RESTORE_ATTEMPTED, GENERATED))) {
            reject { store.save(row.id, owner, 41, started.facts(*facts.toTypedArray())) }
        }
    }
    @Test fun `任一未决预览阻止其他管理动作与新的预览任务`() {
        val row = row(); store.begin(row); store.save(row.id, owner, 41, row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING).facts(MARK_ATTEMPTED))
        reject { store.begin(row()) }
        reject { store.begin(SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic"))) }
        assertEquals(1, store.records(owner, 41).size)
    }
    @Test fun `旧记录缺少新字段保持兼容且不保存媒体凭据或URL`() {
        val row = row(); store.begin(row); val raw = preferences.all.values.single().toString()
        assertFalse(raw.contains("SynoToken")); assertFalse(raw.contains("Cookie")); assertFalse(raw.contains("https://")); assertFalse(raw.contains("thumb_xl"))
        val old = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic"))
        val original = Json.parseToJsonElement(Json { encodeDefaults = true }.encodeToString(old)).jsonObject
        val encoded = JsonObject(original + ("checkpoint" to JsonObject(original.getValue("checkpoint").jsonObject - "previews")))
        preferences.edit().clear().putString("photos_album_v1_${old.id}", encoded.toString()).commit()
        assertEquals(old, store.records(owner, 41).single())
    }
    private fun reject(block: () -> Unit) { try { block(); fail("Expected storage rejection") } catch (_: SynologyPhotoAlbumFailure) {} }
}

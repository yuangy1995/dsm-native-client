package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoSettingsStoreTest {
    private val owner = WorkspaceOwner("settings-store", "identity", "session")
    private val preferences = MemoryPreferences()
    private val store = SynologyPhotoAlbumStore(preferences)
    private fun row(): SynologyPhotoAlbumRecord {
        val original = SynologyPhotoDuplicateSettings(SynologyPhotoUploadDuplicate.IGNORE, SynologyPhotoTransferDuplicate.SKIP)
        return SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
            action = SynologyPhotoAlbumAction.SETTINGS, settings = SynologyPhotoSettingsCheckpoint(original, original.copy(transfer = SynologyPhotoTransferDuplicate.OVERWRITE))))
    }
    @Test fun `固定原值目标和尝试事实重启只读恢复账号隔离`() {
        val row = row(); store.begin(row)
        val submitting = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); store.save(row.id, owner, 41, submitting)
        val attempted = submitting.copy(settings = submitting.settings!!.copy(attempted = true)); store.save(row.id, owner, 41, attempted)
        reject { store.save(row.id, owner, 41, submitting) }
        reject { store.save(row.id, owner, 41, attempted.copy(settings = attempted.settings!!.copy(desired = (attempted.settings.desired as SynologyPhotoDuplicateSettings).copy(upload = SynologyPhotoUploadDuplicate.RENAME)))) }
        val restored = SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "new"), 41).single().checkpoint
        assertEquals(attempted.copy(phase = SynologyPhotoAlbumPhase.PENDING), restored)
        assertTrue(store.records(owner.copy(identityRevision = "new"), 41).isEmpty()); assertTrue(store.records(owner, 42).isEmpty())
        reject { store.discard(store.get(row.id, owner, 41)) }
        store.save(row.id, owner, 41, restored.copy(phase = SynologyPhotoAlbumPhase.COMPLETED)); reject { store.save(row.id, owner, 41, restored) }
        store.discard(store.get(row.id, owner, 41)); assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `明确拒绝事实不能倒退未决设置阻止其他管理动作`() {
        val row = row(); store.begin(row); val submitting = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); store.save(row.id, owner, 41, submitting)
        val album = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic"))
        reject { store.begin(album) }
        val rejected = submitting.copy(settings = submitting.settings!!.copy(rejected = true)); store.save(row.id, owner, 41, rejected)
        reject { store.save(row.id, owner, 41, submitting) }
        store.save(row.id, owner, 41, rejected.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)); store.begin(album)
        assertEquals(2, store.records(owner, 41).size)
    }
    @Test fun `非法终态动作混入字段和无变化均不能落盘`() {
        val row = row(); val value = row.checkpoint
        for (invalid in listOf(value.copy(phase = SynologyPhotoAlbumPhase.COMPLETED), value.copy(phase = SynologyPhotoAlbumPhase.PARTIAL),
            value.copy(settings = value.settings!!.copy(attempted = true)), value.copy(name = "Injected"), value.copy(action = SynologyPhotoAlbumAction.CREATE, name = "Injected"),
            value.copy(settings = value.settings!!.copy(desired = value.settings.original)))) reject { store.begin(row.copy(checkpoint = invalid)) }
        assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `偏好可序列化旧管理记录缺可选设置字段仍兼容`() {
        val row = row(); store.begin(row); assertEquals(row, SynologyPhotoAlbumStore(preferences).records(owner, 41).single())
        val raw = preferences.all.values.single().toString()
        assertFalse(raw.contains("enable_home_service")); assertFalse(raw.contains("package_version")); assertFalse(raw.contains("Cookie"))
        val old = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic"))
        val json = Json { encodeDefaults = true }; val objectValue = Json.parseToJsonElement(json.encodeToString(old)).jsonObject
        val checkpoint = objectValue.getValue("checkpoint").jsonObject
        preferences.edit().clear().putString("photos_album_v1_${old.id}", JsonObject(objectValue + ("checkpoint" to JsonObject(checkpoint - "settings"))).toString()).commit()
        assertEquals(old, store.records(owner, 41).single())
    }
    private fun reject(block: () -> Unit) { try { block(); fail("Expected storage rejection") } catch (_: SynologyPhotoAlbumFailure) {} }
}

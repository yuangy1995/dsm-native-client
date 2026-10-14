package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoMaintenanceStoreTest {
    private val owner = WorkspaceOwner("maintenance", "identity", "session")
    private val preferences = MemoryPreferences(); private val store = SynologyPhotoAlbumStore(preferences)
    private fun row() = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
        action = SynologyPhotoAlbumAction.MAINTAIN_LIBRARY, maintenance = SynologyPhotoMaintenanceCheckpoint(
            SynologyPhotoMaintenanceStatus(owner.profileId, 41, SynologyPhotoSpace.PERSONAL, 0, 0, true), SynologyPhotoMaintenanceAction.INDEX)))
    @Test fun `冷恢复保留固定身份来源动作和尝试回执且单向保存`() {
        val row = row(); store.begin(row); val submitting = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)
        store.save(row.id, owner, 41, submitting)
        val attempted = submitting.copy(maintenance = submitting.maintenance!!.copy(attempted = true)); store.save(row.id, owner, 41, attempted)
        reject { store.save(row.id, owner, 41, submitting) }
        val acknowledged = attempted.copy(maintenance = attempted.maintenance!!.copy(acknowledged = true)); store.save(row.id, owner, 41, acknowledged)
        reject { store.save(row.id, owner, 41, attempted) }
        reject { store.save(row.id, owner, 41, acknowledged.copy(maintenance = acknowledged.maintenance!!.copy(action = SynologyPhotoMaintenanceAction.PREVIEWS))) }
        reject { store.save(row.id, owner, 41, acknowledged.copy(maintenance = acknowledged.maintenance!!.copy(original = acknowledged.maintenance.original.copy(space = SynologyPhotoSpace.SHARED)))) }
        val cold = SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "new"), 41).single().checkpoint
        assertEquals(acknowledged.copy(phase = SynologyPhotoAlbumPhase.PENDING), cold)
        assertTrue(store.records(owner.copy(identityRevision = "new"), 41).isEmpty()); assertTrue(store.records(owner, 42).isEmpty())
        reject { store.discard(store.get(row.id, owner, 41)) }
        store.save(row.id, owner, 41, cold.copy(phase = SynologyPhotoAlbumPhase.COMPLETED))
        reject { store.save(row.id, owner, 41, cold) }; store.discard(store.get(row.id, owner, 41)); assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `拒绝不能丢失不能再写成功回执且未发出的中断允许结束`() {
        val row = row(); store.begin(row); val submitting = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); store.save(row.id, owner, 41, submitting)
        val rejected = submitting.copy(maintenance = submitting.maintenance!!.copy(attempted = true, rejected = true)); store.save(row.id, owner, 41, rejected)
        reject { store.save(row.id, owner, 41, submitting) }
        reject { store.save(row.id, owner, 41, rejected.copy(maintenance = rejected.maintenance!!.copy(acknowledged = true))) }
        store.save(row.id, owner, 41, rejected.copy(phase = SynologyPhotoAlbumPhase.PARTIAL))
        val second = row(); store.begin(second); store.save(second.id, owner, 41, second.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        store.save(second.id, owner, 41, second.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PARTIAL))
        assertEquals(2, store.records(owner, 41).size)
    }
    @Test fun `无回执不能成功未决维护阻止其他管理动作`() {
        val row = row(); store.begin(row); val submitting = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); store.save(row.id, owner, 41, submitting)
        val attempted = submitting.copy(maintenance = submitting.maintenance!!.copy(attempted = true)); store.save(row.id, owner, 41, attempted)
        reject { store.save(row.id, owner, 41, attempted.copy(phase = SynologyPhotoAlbumPhase.COMPLETED)) }
        reject { store.save(row.id, owner, 41, attempted.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)) }
        val album = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic"))
        reject { store.begin(album) }; reject { store.begin(row()) }; assertEquals(1, store.records(owner, 41).size)
    }
    @Test fun `非法原状态和其他动作混入维护字段均不能落盘`() {
        val row = row(); val value = row.checkpoint; val maintenance = value.maintenance!!
        for (invalid in listOf(value.copy(action = SynologyPhotoAlbumAction.CREATE, name = "Injected"), value.copy(name = "Injected"),
            value.copy(maintenance = maintenance.copy(original = maintenance.original.copy(indexingCount = 2))),
            value.copy(maintenance = maintenance.copy(attempted = true)), value.copy(maintenance = maintenance.copy(acknowledged = true)),
            value.copy(maintenance = maintenance.copy(rejected = true)))) reject { store.begin(row.copy(checkpoint = invalid)) }
        assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `旧版本记录无维护字段仍可读且不保存响应或凭据`() {
        val row = row(); store.begin(row); assertEquals(row, SynologyPhotoAlbumStore(preferences).records(owner, 41).single())
        val raw = preferences.all.values.single().toString(); assertFalse(raw.contains("ame_status")); assertFalse(raw.contains("Cookie")); assertFalse(raw.contains("SynoToken"))
        val old = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic"))
        val json = Json { encodeDefaults = true }; val original = Json.parseToJsonElement(json.encodeToString(old)).jsonObject
        val encoded = JsonObject(original + ("checkpoint" to JsonObject(original.getValue("checkpoint").jsonObject - "maintenance")))
        preferences.edit().clear().putString("photos_album_v1_${old.id}", encoded.toString()).commit(); assertEquals(old, store.records(owner, 41).single())
    }
    private fun reject(block: () -> Unit) { try { block(); fail("Expected storage rejection") } catch (_: SynologyPhotoAlbumFailure) {} }
}

package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoCodecPromptStoreTest {
    private val owner = WorkspaceOwner("codec", "identity", "session")
    private val preferences = MemoryPreferences(); private val store = SynologyPhotoAlbumStore(preferences)
    private fun row() = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
        action = SynologyPhotoAlbumAction.CODEC_PROMPT, codecPrompt = SynologyPhotoCodecCheckpoint(SynologyPhotoCodecPrompt(owner.profileId, 41, true, true, true), true)))
    private fun save(row: SynologyPhotoAlbumRecord, next: SynologyPhotoAlbumCheckpoint) = store.save(row.id, owner, 41, next)
    @Test fun `部分成功跨冷启动不能删除或新生成继续保存保留回执直到实际已读`() {
        val row = row(); store.begin(row)
        val submitting = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); save(row, submitting)
        val partial = submitting.copy(phase = SynologyPhotoAlbumPhase.PARTIAL, codecPrompt = submitting.codecPrompt!!.copy(
            generationAttempted = true, generationAcknowledged = true, promptAttempts = 1, promptRejections = 1)); save(row, partial)
        assertFalse(partial.finished)
        val cold = SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "new"), 41).single()
        assertEquals(partial, cold.checkpoint); assertTrue(cold.checkpoint.codecPrompt!!.canContinue)
        reject { store.discard(cold) }; reject { store.begin(row()) }
        val album = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic"))
        reject { store.begin(album) }
        val attempted = partial.copy(phase = SynologyPhotoAlbumPhase.PENDING, codecPrompt = partial.codecPrompt!!.copy(promptAttempts = 2)); save(row, attempted)
        reject { save(row, partial) }; reject { store.discard(store.get(row.id, owner, 41)) }
        val accepted = attempted.copy(codecPrompt = attempted.codecPrompt!!.copy(promptAcknowledged = true)); save(row, accepted)
        reject { save(row, attempted) }; reject { save(row, accepted.copy(phase = SynologyPhotoAlbumPhase.COMPLETED)) }
        val done = accepted.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, codecPrompt = accepted.codecPrompt!!.copy(promptClosed = true)); save(row, done)
        assertTrue(done.finished); reject { save(row, accepted) }; store.discard(store.get(row.id, owner, 41)); store.begin(row())
    }
    @Test fun `全部进度单向身份范围选择不能改且无生成回执不可追认`() {
        val row = row(); store.begin(row); val submitting = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); save(row, submitting)
        val attempted = submitting.copy(codecPrompt = submitting.codecPrompt!!.copy(generationAttempted = true)); save(row, attempted)
        reject { save(row, submitting) }
        reject { save(row, attempted.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)) }
        reject { save(row, attempted.copy(codecPrompt = attempted.codecPrompt!!.copy(promptClosed = true), phase = SynologyPhotoAlbumPhase.COMPLETED)) }
        for (change in listOf(attempted.codecPrompt!!.copy(generate = false), attempted.codecPrompt!!.copy(original = attempted.codecPrompt!!.original.copy(isAdministrator = false)),
            attempted.codecPrompt!!.copy(original = attempted.codecPrompt!!.original.copy(personalSpaceEnabled = false)), attempted.codecPrompt!!.copy(original = attempted.codecPrompt!!.original.copy(userId = 42)))) {
            reject { save(row, attempted.copy(codecPrompt = change)) }
        }
        val accepted = attempted.copy(codecPrompt = attempted.codecPrompt!!.copy(generationAcknowledged = true, promptAttempts = 1)); save(row, accepted)
        reject { save(row, attempted) }
        val refused = accepted.copy(codecPrompt = accepted.codecPrompt!!.copy(promptRejections = 1)); save(row, refused)
        reject { save(row, accepted) }; reject { save(row, refused.copy(codecPrompt = refused.codecPrompt!!.copy(promptAcknowledged = true))) }
        assertTrue(store.records(owner.copy(identityRevision = "changed"), 41).isEmpty()); assertTrue(store.records(owner, 42).isEmpty())
    }
    @Test fun `明确生成拒绝可结束但不能再变成成功未决未知不可删除`() {
        val row = row(); store.begin(row); val submitting = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); save(row, submitting)
        val rejected = submitting.copy(codecPrompt = submitting.codecPrompt!!.copy(generationAttempted = true, generationRejected = true)); save(row, rejected)
        reject { save(row, submitting) }; reject { save(row, rejected.copy(codecPrompt = rejected.codecPrompt!!.copy(generationAcknowledged = true))) }
        save(row, rejected.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)); store.discard(store.get(row.id, owner, 41))
        val next = row(); store.begin(next); save(next, next.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
        val pending = next.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PENDING, codecPrompt = next.checkpoint.codecPrompt!!.copy(generationAttempted = true)); save(next, pending)
        reject { store.discard(store.get(next.id, owner, 41)) }; reject { store.begin(row()) }
    }
    @Test fun `未发送中断允许结束多步非法进度不能落盘`() {
        val row = row(); val checkpoint = row.checkpoint; val value = checkpoint.codecPrompt!!
        for (invalid in listOf(checkpoint.copy(name = "Injected"), checkpoint.copy(action = SynologyPhotoAlbumAction.CREATE, name = "Injected"),
            checkpoint.copy(codecPrompt = value.copy(generationAttempted = true)), checkpoint.copy(codecPrompt = value.copy(generationAcknowledged = true)),
            checkpoint.copy(codecPrompt = value.copy(promptAttempts = 1)), checkpoint.copy(codecPrompt = value.copy(promptRejections = 1)),
            checkpoint.copy(codecPrompt = value.copy(promptAcknowledged = true)), checkpoint.copy(codecPrompt = value.copy(promptClosed = true)),
            checkpoint.copy(codecPrompt = value.copy(original = value.original.copy(shouldShow = false))))) reject { store.begin(row.copy(checkpoint = invalid)) }
        store.begin(row); save(row, checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)); save(row, checkpoint.copy(phase = SynologyPhotoAlbumPhase.PARTIAL))
        assertTrue(store.get(row.id, owner, 41).checkpoint.finished)
    }
    @Test fun `旧版本无新字段可读且只保存状态不保存原始提示响应`() {
        val row = row(); store.begin(row); val raw = preferences.all.values.single().toString()
        assertFalse(raw.contains("new_codec_installed")); assertFalse(raw.contains("SynoToken")); assertFalse(raw.contains("Cookie"))
        assertEquals(row, SynologyPhotoAlbumStore(preferences).records(owner, 41).single())
        val old = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic"))
        val json = Json { encodeDefaults = true }; val original = Json.parseToJsonElement(json.encodeToString(old)).jsonObject
        val encoded = JsonObject(original + ("checkpoint" to JsonObject(original.getValue("checkpoint").jsonObject - "codecPrompt")))
        preferences.edit().clear().putString("photos_album_v1_${old.id}", encoded.toString()).commit(); assertEquals(old, store.records(owner, 41).single())
    }
    private fun reject(block: () -> Unit) { try { block(); fail("Expected storage rejection") } catch (_: SynologyPhotoAlbumFailure) {} }
}

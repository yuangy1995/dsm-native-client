package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoAutomaticPreviewCodec
import io.github.qwertyuiop1995.dsmnativeclient.data.validatePhotoAlbumCheckpoint
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoAutomaticPreviewStoreTest {
    private val owner = WorkspaceOwner("auto-store", "identity", "session")
    private val preferences = MemoryPreferences()
    private val store = SynologyPhotoAlbumStore(preferences)
    private val task = SynologyPhotoAutomaticPreviewTask(owner.profileId, SynologyPhotoSpace.PERSONAL, 151, "Synthetic.mov", 3, true, true)
    private val support = SynologyPhotoPreviewConversionSupport(true, true, true)
    private val signature = SynologyPhotoPreviewVideoSignature(listOf(SynologyPhotoPreviewVideoSignature.Track("video/avc", 160, 120,
        durationMicros = 6_000_000, sampleCount = 60, configurationDigest = "a".repeat(64), contentDigest = "b".repeat(64))))
    private fun row() = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
        action = SynologyPhotoAlbumAction.GENERATE_AUTOMATIC_PREVIEW, automaticPreview = SynologyPhotoAutomaticPreviewCheckpoint(task, support))
    private fun sending(input: SynologyPhotoAlbumCheckpoint) = input.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING,
        automaticPreview = input.automaticPreview!!.copy(uploadAttempted = true, thumbnailDigests = mapOf("xl" to "a".repeat(64), "sm" to "b".repeat(64), "m" to "c".repeat(64)), videoSignature = signature))
    private fun begin(row: SynologyPhotoAlbumCheckpoint) {
        store.begin(SynologyPhotoAlbumRecord(owner = owner, checkpoint = row))
        store.save(row.operationId, owner, 41, row.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
    }
    private fun save(row: SynologyPhotoAlbumCheckpoint) = store.save(row.operationId, owner, 41, row)

    @Test fun `旧版本一记录无自动字段仍可解码验证且新字段只保存摘要`() {
        val old = Json.decodeFromString<SynologyPhotoAlbumCheckpoint>("""{"profileId":"auto-store","userId":41,"action":"CREATE","name":"Synthetic album"}""")
        validatePhotoAlbumCheckpoint(old); assertNull(old.automaticPreview)
        val input = sending(row()); val raw = Json.encodeToString(input)
        assertEquals(input, Json.decodeFromString<SynologyPhotoAlbumCheckpoint>(raw))
        for (secret in listOf("Cookie", "SynoToken", "/cache/", "source.mp4", "preview.mp4")) assertFalse(raw.contains(secret))
        assertFalse(input.toString().contains("Synthetic.mov")); assertFalse(input.automaticPreview.toString().contains("Synthetic.mov"))
    }
    @Test fun `上传摘要尝试回执不可撤回替换且重启仅转为未决`() {
        val input = row(); begin(input); val sent = sending(input); save(sent)
        val state = sent.automaticPreview!!
        for (changed in listOf(state.copy(uploadAttempted = false), state.copy(thumbnailDigests = emptyMap()),
            state.copy(thumbnailDigests = state.thumbnailDigests + ("m" to "d".repeat(64))), state.copy(videoSignature = null),
            state.copy(videoSignature = signature.copy(tracks = signature.tracks.map { it.copy(durationMicros = 7_000_000) })),
            state.copy(task = task.copy(unitId = 152)), state.copy(support = support.copy(vc1 = false)))) {
            failure { save(sent.copy(automaticPreview = changed)) }
        }
        val restored = SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "new"), 41).single().checkpoint
        assertEquals(sent.copy(phase = SynologyPhotoAlbumPhase.PENDING), restored)
        failure { save(sent) }; failure { store.discard(store.get(sent.operationId, owner, 41)) }
        val acknowledged = restored.copy(automaticPreview = state.copy(uploadAcknowledged = true)); save(acknowledged)
        failure { save(restored) }
        val done = acknowledged.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, completed = setOf(0)); save(done)
        failure { save(acknowledged) }; store.discard(store.get(sent.operationId, owner, 41)); assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `未知失败标记不能撤销换阶段或直接变成功`() {
        val input = row(); begin(input)
        val broken = input.copy(phase = SynologyPhotoAlbumPhase.PENDING,
            automaticPreview = input.automaticPreview!!.copy(failureKind = SynologyPhotoAutomaticPreviewFailure.VIDEO)); save(broken)
        for (changed in listOf(broken.automaticPreview!!.copy(failureKind = null),
            broken.automaticPreview.copy(failureKind = SynologyPhotoAutomaticPreviewFailure.PHOTO),
            broken.automaticPreview.copy(uploadAcknowledged = true))) failure { save(broken.copy(automaticPreview = changed)) }
        failure { save(broken.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)) }
        failure { save(broken.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, completed = setOf(0))) }
        val resolved = broken.copy(phase = SynologyPhotoAlbumPhase.PARTIAL, automaticPreview = broken.automaticPreview.copy(failureRecorded = true)); save(resolved)
        failure { save(broken) }; assertTrue(resolved.completed.isEmpty())
    }
    @Test fun `未知自动任务与其他管理写入互斥且可见原件快照不可替换`() {
        val source = SynologyPhotoEditTarget(SynologyPhoto(SynologyPhotoId(owner.profileId, task.space, 51), task.filename, 9, 1.0, 2.0, 7, "video"))
        val input = row().copy(targets = listOf(source), automaticPreview = row().automaticPreview!!.copy(task = task.copy(source = source, sourceThumbnailUnitId = 151)))
        begin(input); save(sending(input))
        val other = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Another")
        failure { store.begin(SynologyPhotoAlbumRecord(owner = owner, checkpoint = other)) }
        failure { save(sending(input).copy(targets = listOf(source.copy(filename = "Changed.mov")))) }
        val otherAccount = owner.copy(identityRevision = "another")
        assertTrue(store.records(otherAccount, 41).isEmpty()); assertTrue(store.records(owner, 42).isEmpty())
    }
    @Test fun `非法目标身份混合管理负载和伪终态均拒绝`() {
        val row = row()
        for (bad in listOf(row.copy(album = SynologyPhotoAlbumSnapshot(7, "Synthetic", 41, "normal", false, false)),
            row.copy(name = "Synthetic"), row.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, completed = setOf(0)),
            row.copy(automaticPreview = row.automaticPreview!!.copy(task = task.copy(profileId = "other"))),
            row.copy(automaticPreview = row.automaticPreview!!.copy(task = task.copy(unitId = 0))),
            row.copy(automaticPreview = row.automaticPreview!!.copy(task = task.copy(needsThumbnail = false, needsVideo = false))),
            row.copy(automaticPreview = row.automaticPreview!!.copy(task = task.copy(sourceThumbnailUnitId = 151))),
            row.copy(automaticPreview = row.automaticPreview!!.copy(support = SynologyPhotoPreviewConversionSupport(false, false, false))),
            row.copy(previews = SynologyPhotoPreviewRegeneration(false, emptyList())),
            row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "Other"))) invalid(bad)
    }
    @Test fun `按需求验证三档摘要和视频轨道并拒绝矛盾写入事实`() {
        val sent = sending(row()); val state = sent.automaticPreview!!
        for (bad in listOf(state.copy(thumbnailDigests = mapOf("xl" to "a".repeat(64))),
            state.copy(thumbnailDigests = state.thumbnailDigests + ("sm" to "invalid")), state.copy(videoSignature = null),
            state.copy(videoSignature = SynologyPhotoPreviewVideoSignature(emptyList())), state.copy(uploadAttempted = false),
            state.copy(uploadAcknowledged = true, uploadRejected = true), state.copy(failureKind = SynologyPhotoAutomaticPreviewFailure.VIDEO),
            state.copy(failureRecorded = true), state.copy(failureRejected = true))) invalid(sent.copy(automaticPreview = bad))
        invalid(sent.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)); invalid(sent.copy(completed = setOf(1)))
        validatePhotoAlbumCheckpoint(sent.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, completed = setOf(0)))
        val videoOnly = sent.copy(automaticPreview = state.copy(task = task.copy(needsThumbnail = false), thumbnailDigests = emptyMap()))
        validatePhotoAlbumCheckpoint(videoOnly)
        val photoOnly = sent.copy(automaticPreview = state.copy(task = task.copy(needsVideo = false, typeCode = 0), videoSignature = null))
        validatePhotoAlbumCheckpoint(photoOnly)
    }
    @Test fun `只读认领完成不伪造同步回执且单调事实检查保持原意图`() {
        val input = row(); begin(input); val sent = sending(input); save(sent)
        val matched = sent.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, completed = setOf(0)); save(matched)
        assertFalse(matched.automaticPreview!!.uploadAcknowledged)
        assertTrue(SynologyPhotoAutomaticPreviewCodec.advances(sent.automaticPreview!!, matched.automaticPreview))
        assertFalse(SynologyPhotoAutomaticPreviewCodec.advances(sent.automaticPreview, input.automaticPreview!!))
        failure { save(matched.copy(completed = emptySet())) }
    }
    private fun invalid(row: SynologyPhotoAlbumCheckpoint) {
        try { validatePhotoAlbumCheckpoint(row); fail("非法记录不应通过") } catch (_: SynologyPhotoFailure) {}
    }
    private fun failure(block: () -> Unit) {
        try { block(); fail("不允许回退持久事实") } catch (_: SynologyPhotoAlbumFailure) {}
    }
}

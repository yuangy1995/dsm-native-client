package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoPreviewVideoSignatureTest {
    private val video = SynologyPhotoPreviewVideoSignature.Track("video/avc", 160, 120, 90,
        durationMicros = 6_000_000, sampleCount = 60, configurationDigest = "a".repeat(64), contentDigest = "b".repeat(64))
    private val audio = SynologyPhotoPreviewVideoSignature.Track("audio/mp4a-latm", sampleRate = 48_000, channels = 2,
        durationMicros = 6_000_000, sampleCount = 280, configurationDigest = "c".repeat(64), contentDigest = "d".repeat(64))
    @Test fun `接受一条视频及可选的单条声音`() {
        assertTrue(SynologyPhotoPreviewVideoSignature(listOf(video)).valid())
        assertTrue(SynologyPhotoPreviewVideoSignature(listOf(video, audio)).valid())
        assertFalse(SynologyPhotoPreviewVideoSignature(emptyList()).valid())
        assertFalse(SynologyPhotoPreviewVideoSignature(listOf(audio)).valid())
        assertFalse(SynologyPhotoPreviewVideoSignature(listOf(video, video)).valid())
        assertFalse(SynologyPhotoPreviewVideoSignature(listOf(video, audio, audio)).valid())
    }
    @Test fun `拒绝无效编码身份尺寸方向时间样本与摘要`() {
        for (track in listOf(video.copy(mime = "video/hevc"), video.copy(width = 0), video.copy(height = -1), video.copy(rotation = 45),
            video.copy(durationMicros = 0), video.copy(sampleCount = -1), video.copy(configurationDigest = "A".repeat(64)),
            video.copy(configurationDigest = "a".repeat(63)), video.copy(contentDigest = "x".repeat(64)),
            video.copy(channels = 1), video.copy(sampleRate = 48_000), video.copy(pixelAspectWidth = 0), video.copy(pixelAspectHeight = -1))) assertFalse(SynologyPhotoPreviewVideoSignature(listOf(track)).valid())
    }
    @Test fun `音轨也校验参数且不能携带画面尺寸或方向`() {
        for (track in listOf(audio.copy(sampleRate = 0), audio.copy(channels = -1), audio.copy(width = 100), audio.copy(height = 100),
            audio.copy(rotation = 90), audio.copy(mime = "audio/opus"), audio.copy(durationMicros = -1), audio.copy(sampleCount = 0),
            audio.copy(configurationDigest = ""), audio.copy(contentDigest = ""), audio.copy(pixelAspectWidth = 2))) assertFalse(SynologyPhotoPreviewVideoSignature(listOf(video, track)).valid())
    }
    @Test fun `序列化往返完整保留轨道而不含媒体或路径`() {
        val signature = SynologyPhotoPreviewVideoSignature(listOf(video, audio))
        val encoded = Json.encodeToString(signature)
        assertEquals(signature, Json.decodeFromString<SynologyPhotoPreviewVideoSignature>(encoded))
        assertFalse(encoded.contains("filename")); assertFalse(encoded.contains("path"))
    }
    @Test fun `内容与时间方向等差异不能只凭时长样本数认领`() {
        val before = SynologyPhotoPreviewVideoSignature(listOf(video))
        for (track in listOf(video.copy(contentDigest = "f".repeat(64)), video.copy(configurationDigest = "f".repeat(64)),
            video.copy(rotation = 180), video.copy(durationMicros = 5_000_000), video.copy(sampleCount = 59), video.copy(pixelAspectWidth = 2))) {
            assertNotEquals(before, SynologyPhotoPreviewVideoSignature(listOf(track)))
        }
    }
}

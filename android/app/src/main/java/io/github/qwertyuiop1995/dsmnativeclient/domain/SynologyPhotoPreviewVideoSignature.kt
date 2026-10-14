package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

/** 只持久化编码轨道的结构与摘要，不保存媒体字节、文件名或路径。 */
@Serializable
data class SynologyPhotoPreviewVideoSignature(val tracks: List<Track>) {
    @Serializable
    data class Track(
        val mime: String, val width: Int = 0, val height: Int = 0, val rotation: Int = 0,
        val sampleRate: Int = 0, val channels: Int = 0, val durationMicros: Long,
        val sampleCount: Long, val configurationDigest: String, val contentDigest: String,
        val pixelAspectWidth: Int = 1, val pixelAspectHeight: Int = 1,
    )
    fun valid(): Boolean = tracks.count { it.mime == "video/avc" } == 1 && tracks.size in 1..2 && tracks.all {
        it.mime in setOf("video/avc", "audio/mp4a-latm") && it.durationMicros > 0 && it.sampleCount > 0 &&
            it.configurationDigest.matches(Regex("[0-9a-f]{64}")) && it.contentDigest.matches(Regex("[0-9a-f]{64}")) &&
            if (it.mime == "video/avc") it.width > 0 && it.height > 0 && it.pixelAspectWidth > 0 && it.pixelAspectHeight > 0 &&
                it.rotation in setOf(0, 90, 180, 270) && it.channels == 0 && it.sampleRate == 0
            else it.width == 0 && it.height == 0 && it.rotation == 0 && it.channels > 0 && it.sampleRate > 0 && it.pixelAspectWidth == 1 && it.pixelAspectHeight == 1
    }
}

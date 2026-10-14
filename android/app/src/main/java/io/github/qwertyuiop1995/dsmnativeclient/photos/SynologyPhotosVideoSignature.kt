package io.github.qwertyuiop1995.dsmnativeclient.photos

import android.media.MediaExtractor
import android.media.MediaFormat
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoPreviewVideoSignature
import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** 容器重新封装仍可比较；相同时长或大小不能代替每个编码样本及时间轴的摘要。 */
internal object SynologyPhotosVideoSignature {
    suspend fun read(file: File): SynologyPhotoPreviewVideoSignature = withContext(Dispatchers.IO) {
        currentCoroutineContext().ensureActive()
        PhotoMediaInput(file).use { input ->
            val tracks = input.formats.withIndex().filter { (_, format) ->
                format.getString(MediaFormat.KEY_MIME)?.let { it.startsWith("video/") || it.startsWith("audio/") } == true
            }.sortedBy { (_, format) -> if (format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) 0 else 1 }
            val signatures = tracks.map { (index, format) ->
                // 独立Extractor避免切换轨道继承前一轨的读取位置。
                PhotoMediaInput(file).use { trackInput ->
                    val extractor = trackInput.extractor
                    extractor.selectTrack(index)
                    val configuration = MessageDigest.getInstance("SHA-256")
                    for (key in listOf("csd-0", "csd-1", "csd-2")) {
                        val bytes = format.getByteBuffer(key)?.duplicate() ?: continue
                        configuration.update(key.toByteArray(Charsets.US_ASCII)); configuration.update(bytes)
                    }
                    val digest = MessageDigest.getInstance("SHA-256"); val buffer = PhotoSampleBuffer()
                    val header = ByteBuffer.allocate(16); var count = 0L
                    while (extractor.sampleTrackIndex >= 0) {
                        currentCoroutineContext().ensureActive()
                        if (extractor.sampleTime < 0 || extractor.sampleFlags and (MediaExtractor.SAMPLE_FLAG_ENCRYPTED or MediaExtractor.SAMPLE_FLAG_PARTIAL_FRAME) != 0) unsupportedVideo()
                        val bytes = buffer.read(extractor)
                        header.clear(); header.putLong(extractor.sampleTime); header.putLong(bytes.remaining().toLong()); header.flip()
                        digest.update(header); digest.update(bytes); count++; extractor.advance()
                    }
                    SynologyPhotoPreviewVideoSignature.Track(
                        mime = format.getString(MediaFormat.KEY_MIME) ?: unreadableVideo(),
                        width = format.intOrNull(MediaFormat.KEY_WIDTH) ?: 0, height = format.intOrNull(MediaFormat.KEY_HEIGHT) ?: 0,
                        rotation = format.intOrNull(MediaFormat.KEY_ROTATION) ?: 0,
                        sampleRate = format.intOrNull(MediaFormat.KEY_SAMPLE_RATE) ?: 0, channels = format.intOrNull(MediaFormat.KEY_CHANNEL_COUNT) ?: 0,
                        durationMicros = format.longOrNull(MediaFormat.KEY_DURATION) ?: unreadableVideo(), sampleCount = count,
                        configurationDigest = configuration.digest().hex(), contentDigest = digest.digest().hex(),
                        pixelAspectWidth = format.intOrNull(MediaFormat.KEY_PIXEL_ASPECT_RATIO_WIDTH) ?: 1,
                        pixelAspectHeight = format.intOrNull(MediaFormat.KEY_PIXEL_ASPECT_RATIO_HEIGHT) ?: 1,
                    )
                }
            }
            SynologyPhotoPreviewVideoSignature(signatures).also { if (!it.valid()) unreadableVideo() }
        }
    }
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it.toInt() and 255) }
}

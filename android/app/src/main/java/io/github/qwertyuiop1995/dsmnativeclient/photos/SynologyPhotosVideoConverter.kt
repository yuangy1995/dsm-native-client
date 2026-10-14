package io.github.qwertyuiop1995.dsmnativeclient.photos

import android.graphics.ImageDecoder
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.view.Surface
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoPreviewConversionSupport
import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** 系统Surface解码→H264编码；保留原尺寸与方向，不借帧截图冒充完整视频。 */
internal object SynologyPhotosVideoConverter {
    fun support(): SynologyPhotoPreviewConversionSupport {
        val codecs = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.toList()
        fun has(mime: String, encoder: Boolean) = codecs.any { it.isEncoder == encoder && it.supportedTypes.any { type -> type.equals(mime, true) } }
        val video = has(MediaFormat.MIMETYPE_VIDEO_AVC, true) && has(MediaFormat.MIMETYPE_VIDEO_AVC, false) && has(MediaFormat.MIMETYPE_AUDIO_AAC, true)
        return SynologyPhotoPreviewConversionSupport(
            hevc = video && has(MediaFormat.MIMETYPE_VIDEO_HEVC, false) && ImageDecoder.isMimeTypeSupported("image/heic"),
            video = video,
            vc1 = video && (has("video/vc1", false) || has("video/wmv", false)),
        )
    }

    suspend fun convert(source: File, destination: File): File {
        var promoted = false
        try { return withContext(Dispatchers.IO) {
        currentCoroutineContext().ensureActive()
        require(source.isFile && !destination.exists() && source.canonicalFile != destination.canonicalFile)
        val parent = destination.parentFile ?: unsupportedVideo()
        require(parent.isDirectory)
        val temporary = File(parent, ".photo-video-${UUID.randomUUID()}").apply { check(mkdir()) }
        try {
            val formats = PhotoMediaInput(source).use { it.formats }
            val videoIndices = formats.indices.filter { formats[it].getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true }
            val audioIndices = formats.indices.filter { formats[it].getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
            if (videoIndices.size != 1 || audioIndices.size > 1) unsupportedVideo()
            val format = formats[videoIndices.single()]
            val rotation = format.intOrNull(MediaFormat.KEY_ROTATION) ?: 0
            if (rotation !in setOf(0, 90, 180, 270)) unsupportedVideo()
            val tracks = mutableListOf(File(temporary, "video.mp4"))
            encodeVideo(source, videoIndices.single(), tracks.single())
            audioIndices.singleOrNull()?.let { index ->
                val audio = File(temporary, "audio.mp4")
                if (formats[index].getString(MediaFormat.KEY_MIME) == MediaFormat.MIMETYPE_AUDIO_AAC) copyPhotoTrack(source, index, audio)
                else SynologyPhotosAudioConverter.convert(source, index, audio)
                tracks += audio
            }
            val output = File(temporary, "preview.mp4")
            val originalTrackIndices = videoIndices + audioIndices
            val offsets = tracks.mapIndexed { position, file -> photoTrackStart(source, originalTrackIndices[position]) - photoTrackStart(file, 0) }
            muxPhotoTracks(tracks, output, rotation, offsets)
            val signature = SynologyPhotosVideoSignature.read(output)
            val converted = signature.tracks.first()
            if (converted.width != format.intOrNull(MediaFormat.KEY_WIDTH) || converted.height != format.intOrNull(MediaFormat.KEY_HEIGHT) ||
                converted.rotation != rotation || signature.tracks.size != 1 + audioIndices.size) unreadableVideo()
            currentCoroutineContext().ensureActive()
            // 不覆盖已有目标；所有中间结果只属于本次转换。
            Files.move(output.toPath(), destination.toPath())
            promoted = true
            destination
        } finally { temporary.deleteRecursively() }
        } } catch (error: Throwable) {
            // withContext在返回调用线程时仍可能被取消，只清理本次已提升的结果。
            if (promoted) destination.delete()
            throw error
        }
    }

    private suspend fun encodeVideo(source: File, index: Int, destination: File) {
        val format = PhotoMediaInput(source).use { it.extractor.getTrackFormat(index) }
        val mime = format.getString(MediaFormat.KEY_MIME) ?: unreadableVideo()
        val codecs = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        val primary = codecs.findDecoderForFormat(format) ?: unsupportedVideo()
        val alternative = codecs.codecInfos.firstOrNull { info -> info.name != primary && !info.isEncoder && info.isSoftwareOnly &&
            info.supportedTypes.any { it == mime } && info.getCapabilitiesForType(mime).isFormatSupported(format) }?.name
        try { encodeVideoAttempt(source, index, destination, primary) }
        catch (error: MediaCodec.CodecException) {
            if (alternative == null || error.isTransient || error.isRecoverable || error.errorCode in setOf(MediaCodec.CodecException.ERROR_INSUFFICIENT_RESOURCE, MediaCodec.CodecException.ERROR_RECLAIMED)) throw error
            // 已复现虚拟硬件解码器不能向编码Surface提交CSD；仅本机重试可用的系统软件解码器。
            currentCoroutineContext().ensureActive()
            destination.delete()
            encodeVideoAttempt(source, index, destination, alternative)
        }
    }

    private suspend fun encodeVideoAttempt(source: File, index: Int, destination: File, decoderName: String) {
        PhotoMediaInput(source).use { input ->
            input.extractor.selectTrack(index)
            val format = input.extractor.getTrackFormat(index)
            val width = format.intOrNull(MediaFormat.KEY_WIDTH)?.takeIf { it > 0 } ?: unreadableVideo()
            val height = format.intOrNull(MediaFormat.KEY_HEIGHT)?.takeIf { it > 0 } ?: unreadableVideo()
            val aspectWidth = format.intOrNull(MediaFormat.KEY_PIXEL_ASPECT_RATIO_WIDTH) ?: 1
            val aspectHeight = format.intOrNull(MediaFormat.KEY_PIXEL_ASPECT_RATIO_HEIGHT) ?: 1
            // 当前Surface路径没有重新采样非方形像素，不可生成被拉伸的预览。
            if (aspectWidth <= 0 || aspectHeight <= 0 || aspectWidth != aspectHeight) unsupportedVideo()
            val frameRate = format.getNumber(MediaFormat.KEY_FRAME_RATE)?.toFloat()?.takeIf { it.isFinite() && it > 0 } ?: 30f
            val output = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setFloat(MediaFormat.KEY_FRAME_RATE, frameRate)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                setInteger(MediaFormat.KEY_PRIORITY, 1)
                setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            }
            val codecs = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            val encoderName = codecs.findEncoderForFormat(output) ?: unsupportedVideo()
            val capabilities = codecs.codecInfos.first { it.name == encoderName }.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).videoCapabilities ?: unsupportedVideo()
            val bitrate = (width.toDouble() * height * frameRate / 5).coerceIn(256_000.0, 40_000_000.0).toInt()
            output.setInteger(MediaFormat.KEY_BIT_RATE, capabilities.bitrateRange.clamp(bitrate))
            val transfer = format.intOrNull(MediaFormat.KEY_COLOR_TRANSFER)
            val hdr = transfer == MediaFormat.COLOR_TRANSFER_ST2084 || transfer == MediaFormat.COLOR_TRANSFER_HLG
            if (hdr) {
                if (Build.VERSION.SDK_INT < 31) unsupportedVideo()
                format.setInteger(MediaFormat.KEY_COLOR_TRANSFER_REQUEST, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
            }
            for (key in listOf(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.KEY_COLOR_RANGE, MediaFormat.KEY_COLOR_TRANSFER)) {
                format.intOrNull(key)?.let { value -> output.setInteger(key, if (hdr && key == MediaFormat.KEY_COLOR_TRANSFER) MediaFormat.COLOR_TRANSFER_SDR_VIDEO else value) }
            }
            format.setInteger(MediaFormat.KEY_ROTATION, 0)
            format.setInteger(MediaFormat.KEY_ALLOW_FRAME_DROP, 0)
            format.setInteger(MediaFormat.KEY_PRIORITY, 1)
            var encoder: MediaCodec? = null; var decoder: MediaCodec? = null; var surface: Surface? = null
            try {
                encoder = MediaCodec.createByCodecName(encoderName)
                encoder.configure(output, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                surface = encoder.createInputSurface(); encoder.start()
                decoder = MediaCodec.createByCodecName(decoderName)
                decoder.configure(format, surface, null, 0)
                if (hdr && decoder.inputFormat.intOrNull(MediaFormat.KEY_COLOR_TRANSFER_REQUEST) != MediaFormat.COLOR_TRANSFER_SDR_VIDEO) unsupportedVideo()
                decoder.start()
                PhotoTrackOutput(destination).use { muxer ->
                    videoLoop(input.extractor, decoder, encoder, muxer)
                    muxer.finish(format.longOrNull(MediaFormat.KEY_DURATION))
                }
            } finally {
                decoder?.let { runCatching { it.stop() }; runCatching { it.release() } }
                encoder?.let { runCatching { it.stop() }; runCatching { it.release() } }
                surface?.release()
            }
        }
    }

    private suspend fun videoLoop(extractor: android.media.MediaExtractor, decoder: MediaCodec, encoder: MediaCodec, muxer: PhotoTrackOutput) {
        var inputDone = false; var decoderDone = false; var encoderDone = false
        val encoded = MediaCodec.BufferInfo(); val decoded = MediaCodec.BufferInfo(); val watchdog = PhotoCodecProgress()
        while (!encoderDone) {
            currentCoroutineContext().ensureActive()
            var progress = false
            // 先排空编码器，避免解码器释放Surface帧时等候已满的队列。
            val outputIndex = encoder.dequeueOutputBuffer(encoded, 10_000)
            if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) { muxer.format(encoder.outputFormat); progress = true }
            else if (outputIndex >= 0) {
                try { muxer.write(encoder.getOutputBuffer(outputIndex) ?: unreadableVideo(), encoded) }
                finally { encoder.releaseOutputBuffer(outputIndex, false) }
                encoderDone = encoded.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0; progress = true
            }
            if (!decoderDone) {
                val decodedIndex = decoder.dequeueOutputBuffer(decoded, 0)
                if (decodedIndex >= 0) {
                    decoderDone = decoded.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    decoder.releaseOutputBuffer(decodedIndex, decoded.size > 0)
                    if (decoderDone) encoder.signalEndOfInputStream()
                    progress = true
                } else if (decodedIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) progress = true
            }
            if (!inputDone) {
                val inputIndex = decoder.dequeueInputBuffer(0)
                if (inputIndex >= 0) { inputDone = feedPhotoDecoder(extractor, decoder, inputIndex); progress = true }
            }
            watchdog.check(progress)
        }
    }
}

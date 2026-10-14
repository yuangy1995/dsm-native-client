package io.github.qwertyuiop1995.dsmnativeclient.photos

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.nio.ByteBuffer
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** 非AAC音轨经PCM16转AAC；不支持的音轨使整个转换失败，禁止静默静音。 */
internal object SynologyPhotosAudioConverter {
    suspend fun convert(source: File, track: Int, destination: File) {
        PhotoMediaInput(source).use { input ->
            input.extractor.selectTrack(track)
            val format = input.extractor.getTrackFormat(track)
            val sampleRate = format.intOrNull(MediaFormat.KEY_SAMPLE_RATE)?.takeIf { it > 0 } ?: unreadableVideo()
            val channels = format.intOrNull(MediaFormat.KEY_CHANNEL_COUNT)?.takeIf { it > 0 } ?: unreadableVideo()
            val output = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, (channels * 96_000).coerceAtMost(512_000))
                setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            }
            format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            val codecs = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            val encoderName = codecs.findEncoderForFormat(output) ?: unsupportedVideo()
            val decoderName = codecs.findDecoderForFormat(format) ?: unsupportedVideo()
            var encoder: MediaCodec? = null; var decoder: MediaCodec? = null
            try {
                encoder = MediaCodec.createByCodecName(encoderName)
                encoder.configure(output, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); encoder.start()
                decoder = MediaCodec.createByCodecName(decoderName)
                decoder.configure(format, null, null, 0); decoder.start()
                PhotoTrackOutput(destination).use { muxer ->
                    audioLoop(input.extractor, decoder, encoder, muxer, sampleRate, channels)
                    muxer.finish()
                }
            } finally {
                decoder?.let { runCatching { it.stop() }; runCatching { it.release() } }
                encoder?.let { runCatching { it.stop() }; runCatching { it.release() } }
            }
        }
    }

    private suspend fun audioLoop(extractor: MediaExtractor, decoder: MediaCodec, encoder: MediaCodec,
        muxer: PhotoTrackOutput, sampleRate: Int, channels: Int) {
        var inputDone = false; var decoderDone = false; var encoderDone = false
        var heldIndex = -1; var heldBytes: ByteBuffer? = null; var consumed = 0; var heldTime = 0L; var heldEnd = false
        val frameBytes = channels * 2
        val encoded = MediaCodec.BufferInfo(); val decoded = MediaCodec.BufferInfo(); val watchdog = PhotoCodecProgress()
        while (!encoderDone) {
            currentCoroutineContext().ensureActive()
            var progress = false
            val outputIndex = encoder.dequeueOutputBuffer(encoded, 10_000)
            if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) { muxer.format(encoder.outputFormat); progress = true }
            else if (outputIndex >= 0) {
                try { muxer.write(encoder.getOutputBuffer(outputIndex) ?: unreadableVideo(), encoded) }
                finally { encoder.releaseOutputBuffer(outputIndex, false) }
                encoderDone = encoded.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0; progress = true
            }
            if (!decoderDone && heldIndex < 0) {
                val index = decoder.dequeueOutputBuffer(decoded, 0)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val actual = decoder.outputFormat
                    if (actual.getInteger(MediaFormat.KEY_SAMPLE_RATE) != sampleRate || actual.getInteger(MediaFormat.KEY_CHANNEL_COUNT) != channels ||
                        (actual.intOrNull(MediaFormat.KEY_PCM_ENCODING) ?: AudioFormat.ENCODING_PCM_16BIT) != AudioFormat.ENCODING_PCM_16BIT) unsupportedVideo()
                    progress = true
                } else if (index >= 0) {
                    heldIndex = index
                    heldBytes = decoder.getOutputBuffer(index)?.apply { position(decoded.offset); limit(decoded.offset + decoded.size) } ?: unreadableVideo()
                    if (decoded.size % frameBytes != 0) unreadableVideo()
                    consumed = 0; heldTime = decoded.presentationTimeUs
                    heldEnd = decoded.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0; progress = true
                }
            }
            val pcm = heldBytes
            if (heldIndex >= 0 && pcm != null) {
                val index = encoder.dequeueInputBuffer(0)
                if (index >= 0) {
                    val bytes = encoder.getInputBuffer(index) ?: unsupportedVideo()
                    bytes.clear()
                    val count = minOf(bytes.remaining(), pcm.remaining()) / frameBytes * frameBytes
                    if (pcm.hasRemaining() && count == 0) unsupportedVideo()
                    val originalLimit = pcm.limit(); pcm.limit(pcm.position() + count); bytes.put(pcm); pcm.limit(originalLimit)
                    val last = !pcm.hasRemaining()
                    encoder.queueInputBuffer(index, 0, count, heldTime + consumed.toLong() / frameBytes * 1_000_000 / sampleRate,
                        if (last && heldEnd) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
                    consumed += count
                    if (last) {
                        decoder.releaseOutputBuffer(heldIndex, false); heldIndex = -1; heldBytes = null; decoderDone = heldEnd
                    }
                    progress = true
                }
            }
            if (!inputDone) {
                val index = decoder.dequeueInputBuffer(0)
                if (index >= 0) { inputDone = feedPhotoDecoder(extractor, decoder, index); progress = true }
            }
            watchdog.check(progress)
        }
    }
}

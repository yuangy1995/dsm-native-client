package io.github.qwertyuiop1995.dsmnativeclient

import android.graphics.Color
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlin.math.abs
import kotlin.math.sin
import kotlinx.coroutines.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** 只使用纯色视频与本机生成的正弦波；执行真实系统编解码、封装和摘要。 */
class SynologyPhotosVideoConverterDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val directory = File(instrumentation.targetContext.cacheDir, "photo-video-test-${UUID.randomUUID()}").apply { check(mkdir()) }
    @After fun cleanup() { check(directory.deleteRecursively()) }

    @Test fun fullVideoRetainsEveryFrameSizeAndOriginal() = runBlocking {
        val source = fixture(); val original = source.readBytes(); val destination = File(directory, "converted.mp4")
        assertTrue(SynologyPhotosVideoConverter.support().video)
        assertEquals(destination, SynologyPhotosVideoConverter.convert(source, destination))
        val signature = SynologyPhotosVideoSignature.read(destination)
        assertTrue(signature.valid()); assertEquals(1, signature.tracks.size)
        val video = signature.tracks.single()
        assertEquals("video/avc", video.mime); assertEquals(60, video.sampleCount.toInt())
        assertEquals(160, video.width); assertEquals(120, video.height); assertEquals(0, video.rotation)
        assertTrue(video.durationMicros in 5_900_000..6_100_000)
        frame(destination, 0) { assertColor(Color.rgb(40, 120, 190), it.getPixel(80, 60)) }
        frame(destination, 5_900_000) { assertColor(Color.rgb(158, 120, 190), it.getPixel(80, 60)) }
        assertArrayEquals(original, source.readBytes())
        assertEquals(setOf("source.mp4", "converted.mp4"), directory.list()!!.toSet())
    }

    @Test fun allDisplayRotationsAreAppliedOnce() = runBlocking {
        val source = fixture("synthetic-video-landmarks.mp4")
        val cornerColors = mapOf(
            90 to listOf(Color.BLUE, Color.RED, Color.YELLOW, Color.GREEN),
            180 to listOf(Color.YELLOW, Color.BLUE, Color.GREEN, Color.RED),
            270 to listOf(Color.GREEN, Color.YELLOW, Color.RED, Color.BLUE),
        )
        for (rotation in listOf(90, 180, 270)) {
            val rotated = File(directory, "source-$rotation.mp4")
            muxPhotoTracks(listOf(source), rotated, rotation)
            val output = File(directory, "converted-$rotation.mp4")
            SynologyPhotosVideoConverter.convert(rotated, output)
            val track = SynologyPhotosVideoSignature.read(output).tracks.single()
            assertEquals(rotation, track.rotation); assertEquals(160, track.width); assertEquals(120, track.height)
            frame(output, 3_000_000) {
                assertEquals(if (rotation == 180) 160 else 120, it.width)
                assertEquals(if (rotation == 180) 120 else 160, it.height)
                assertColor(Color.rgb(100, 120, 190), it.getPixel(it.width / 2, it.height / 2))
                for ((index, color) in cornerColors.getValue(rotation).withIndex()) {
                    assertColor(color, it.getPixel(it.width * (if (index % 2 == 0) 1 else 7) / 8,
                        it.height * (if (index / 2 == 0) 1 else 7) / 8))
                }
            }
        }
    }

    @Test fun pcmAudioIsEncodedToAudibleAAC() = runBlocking {
        val wave = wave(); val original = wave.readBytes(); val audio = File(directory, "audio.mp4")
        SynologyPhotosAudioConverter.convert(wave, 0, audio)
        PhotoMediaInput(audio).use { input ->
            assertEquals(1, input.extractor.trackCount)
            val format = input.formats.single()
            assertEquals(MediaFormat.MIMETYPE_AUDIO_AAC, format.getString(MediaFormat.KEY_MIME))
            assertEquals(48_000, format.getInteger(MediaFormat.KEY_SAMPLE_RATE)); assertEquals(1, format.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
        }
        val pcm = decodedAudio(audio)
        assertTrue(pcm.first >= 48_000 * 5); assertTrue("声音不能被静音", pcm.second > pcm.first.toLong() * 1_000)
        assertArrayEquals(original, wave.readBytes())
    }

    @Test fun existingAACAndAVTimingSurviveWholeVideoConversion() = runBlocking {
        val video = fixture(); val audio = File(directory, "audio.mp4")
        SynologyPhotosAudioConverter.convert(wave(), 0, audio)
        val source = File(directory, "with-audio.mp4"); muxPhotoTracks(listOf(video, audio), source, 90)
        val original = source.readBytes(); val before = SynologyPhotosVideoSignature.read(source)
        val output = File(directory, "converted.mp4"); SynologyPhotosVideoConverter.convert(source, output)
        val after = SynologyPhotosVideoSignature.read(output)
        assertEquals(2, after.tracks.size)
        assertEquals(before.tracks.single { it.mime.startsWith("audio/") }, after.tracks.single { it.mime.startsWith("audio/") })
        assertEquals(60, after.tracks.first().sampleCount.toInt()); assertEquals(90, after.tracks.first().rotation)
        assertArrayEquals(original, source.readBytes())
    }

    @Test fun delayedAudioKeepsItsOffsetFromVideo() = runBlocking {
        val video = fixture(); val audio = File(directory, "audio.mp4")
        SynologyPhotosAudioConverter.convert(wave(), 0, audio)
        val source = File(directory, "delayed-audio.mp4")
        muxPhotoTracks(listOf(video, audio), source, 0, listOf(0, 1_000_000))
        val originalOffset = photoTrackStart(source, 1) - photoTrackStart(source, 0)
        assertEquals(1_000_000L, originalOffset)
        val output = File(directory, "converted.mp4"); SynologyPhotosVideoConverter.convert(source, output)
        assertEquals(originalOffset, photoTrackStart(output, 1) - photoTrackStart(output, 0))
        assertEquals(SynologyPhotosVideoSignature.read(source).tracks[1], SynologyPhotosVideoSignature.read(output).tracks[1])
    }

    @Test fun trackSignatureAllowsRemuxButRejectsDifferentContentOrDirection() = runBlocking {
        val original = fixture(); val source = File(directory, "baseline.mp4")
        SynologyPhotosVideoConverter.convert(original, source)
        val before = SynologyPhotosVideoSignature.read(source)
        val remuxed = File(directory, "remux.mp4"); muxPhotoTracks(listOf(source), remuxed, 0)
        // 添加合法的空闲容器box，确保容器字节不同，编码内容与时间轴保持相同。
        remuxed.appendBytes(ByteBuffer.allocate(12).putInt(12).put("free".toByteArray()).putInt(0).array())
        assertEquals(before, SynologyPhotosVideoSignature.read(remuxed))
        assertFalse(source.readBytes().contentEquals(remuxed.readBytes()))
        val rotated = File(directory, "rotated.mp4"); muxPhotoTracks(listOf(source), rotated, 90)
        assertNotEquals(before, SynologyPhotosVideoSignature.read(rotated))
        val converted = original
        val changed = SynologyPhotosVideoSignature.read(converted)
        assertEquals(before.tracks.first().sampleCount, changed.tracks.first().sampleCount)
        assertNotEquals(before.tracks.first().contentDigest, changed.tracks.first().contentDigest)
    }

    @Test fun sameSamplesAndDurationWithAlteredTimingCannotMatch() = runBlocking {
        val source = File(directory, "baseline.mp4"); SynologyPhotosVideoConverter.convert(fixture(), source)
        val before = SynologyPhotosVideoSignature.read(source)
        val remuxed = File(directory, "retimed.mp4")
        PhotoMediaInput(source).use { input ->
            val extractor = input.extractor; extractor.selectTrack(0)
            val muxer = MediaMuxer(remuxed.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            try {
                val track = muxer.addTrack(extractor.getTrackFormat(0)); muxer.start()
                val bytes = PhotoSampleBuffer(); val info = MediaCodec.BufferInfo(); var count = 0
                while (extractor.sampleTrackIndex >= 0) {
                    val sample = bytes.read(extractor)
                    info.set(0, sample.remaining(), extractor.sampleTime + if (count == 20) 50_000 else 0, extractor.sampleFlags)
                    muxer.writeSampleData(track, sample, info); extractor.advance(); count++
                }
                info.set(0, 0, before.tracks.first().durationMicros, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                muxer.writeSampleData(track, ByteBuffer.allocate(0), info); muxer.stop()
            } finally { muxer.release() }
        }
        val after = SynologyPhotosVideoSignature.read(remuxed)
        assertEquals(before.tracks.first().sampleCount, after.tracks.first().sampleCount)
        assertEquals(before.tracks.first().durationMicros, after.tracks.first().durationMicros)
        assertNotEquals(before, after)
    }

    @Test fun existingOutputIsNeverOverwritten() = runBlocking {
        val source = fixture(); val destination = File(directory, "keep.mp4").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        assertTrue(failure { SynologyPhotosVideoConverter.convert(source, destination) } is IllegalArgumentException)
        assertArrayEquals(byteArrayOf(1, 2, 3), destination.readBytes())
        assertEquals(setOf("source.mp4", "keep.mp4"), directory.list()!!.toSet())
    }

    @Test fun damagedVideoDoesNotLeavePartialOutput() = runBlocking {
        val source = File(directory, "broken.mp4").apply { writeBytes(ByteArray(128) { 23 }) }
        failure { SynologyPhotosVideoConverter.convert(source, File(directory, "output.mp4")) }
        assertEquals(listOf("broken.mp4"), directory.list()!!.toList())
    }

    @Test fun cancellationDuringConversionCleansOwnedFilesAndPreservesSource() = runBlocking {
        val source = fixture(); val original = source.readBytes(); val destination = File(directory, "converted.mp4")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val job = scope.async { SynologyPhotosVideoConverter.convert(source, destination) }
            withTimeout(10_000) { while (directory.list()!!.none { it.startsWith(".photo-video-") }) { check(!job.isCompleted); yield() } }
            job.cancel(); assertTrue(failure { job.await() } is CancellationException)
            job.join()
            assertFalse(destination.exists()); assertArrayEquals(original, source.readBytes())
            assertEquals(listOf("source.mp4"), directory.list()!!.toList())
        } finally { scope.cancel() }
    }

    private fun fixture(asset: String = "synthetic-slideshow.mp4"): File = File(directory, "source.mp4").apply {
        instrumentation.context.assets.open(asset).use { input -> outputStream().use(input::copyTo) }
    }
    private fun wave(): File = File(directory, "sound.wav").apply {
        val samples = 48_000 * 6; val pcm = ByteBuffer.allocate(44 + samples * 2).order(ByteOrder.LITTLE_ENDIAN)
        pcm.put("RIFF".toByteArray()); pcm.putInt(36 + samples * 2); pcm.put("WAVEfmt ".toByteArray())
        pcm.putInt(16); pcm.putShort(1); pcm.putShort(1); pcm.putInt(48_000); pcm.putInt(96_000); pcm.putShort(2); pcm.putShort(16)
        pcm.put("data".toByteArray()); pcm.putInt(samples * 2)
        repeat(samples) { pcm.putShort((12_000 * sin(it * 2.0 * Math.PI * 440 / 48_000)).toInt().toShort()) }
        writeBytes(pcm.array())
    }
    private fun frame(file: File, time: Long, check: (android.graphics.Bitmap) -> Unit) {
        val reader = MediaMetadataRetriever()
        try {
            reader.setDataSource(file.path)
            val bitmap = reader.getFrameAtTime(time, MediaMetadataRetriever.OPTION_CLOSEST) ?: throw AssertionError("缺少视频帧")
            try { check(bitmap) } finally { bitmap.recycle() }
        } finally { reader.release() }
    }
    private fun assertColor(expected: Int, actual: Int) {
        for (component in listOf(Color::red, Color::green, Color::blue)) assertTrue("视频颜色应保留", abs(component(expected) - component(actual)) <= 22)
    }
    private suspend fun decodedAudio(file: File): Pair<Int, Long> {
        PhotoMediaInput(file).use { input ->
            val extractor = input.extractor; extractor.selectTrack(0)
            val format = extractor.getTrackFormat(0); val decoder = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            try {
                decoder.configure(format, null, null, 0); decoder.start()
                var inputDone = false; var done = false; var count = 0; var amplitude = 0L
                val info = MediaCodec.BufferInfo()
                withTimeout(20_000) {
                    while (!done) {
                        currentCoroutineContext().ensureActive()
                        if (!inputDone) {
                            val index = decoder.dequeueInputBuffer(0)
                            if (index >= 0) inputDone = feedPhotoDecoder(extractor, decoder, index)
                        }
                        val index = decoder.dequeueOutputBuffer(info, 10_000)
                        if (index >= 0) {
                            val bytes = decoder.getOutputBuffer(index)!!.order(ByteOrder.LITTLE_ENDIAN)
                            bytes.position(info.offset); bytes.limit(info.offset + info.size)
                            while (bytes.remaining() >= 2) { amplitude += abs(bytes.short.toInt()); count++ }
                            done = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            decoder.releaseOutputBuffer(index, false)
                        }
                    }
                }
                return count to amplitude
            } finally { runCatching { decoder.stop() }; decoder.release() }
        }
    }
    private suspend fun failure(block: suspend () -> Unit): Throwable {
        try { block() } catch (error: Throwable) { return error }
        throw AssertionError("应失败")
    }
}

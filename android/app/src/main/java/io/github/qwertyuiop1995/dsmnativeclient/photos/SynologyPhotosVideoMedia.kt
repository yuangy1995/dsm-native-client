package io.github.qwertyuiop1995.dsmnativeclient.photos

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.SystemClock
import java.io.File
import java.nio.ByteBuffer
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** 本机限制与确定的内容损坏分开；前者不能回写NAS的broken状态。 */
internal enum class PhotoVideoFailureKind { UNSUPPORTED, UNREADABLE, SYSTEM, MALFORMED_SOURCE }
internal class PhotoVideoConversionFailure(val kind: PhotoVideoFailureKind) : Exception("Photo video conversion failed")
internal fun unsupportedVideo(): Nothing = throw PhotoVideoConversionFailure(PhotoVideoFailureKind.UNSUPPORTED)
internal fun unreadableVideo(): Nothing = throw PhotoVideoConversionFailure(PhotoVideoFailureKind.UNREADABLE)

internal fun MediaFormat.intOrNull(key: String): Int? = if (containsKey(key)) getInteger(key) else null
internal fun MediaFormat.longOrNull(key: String): Long? = if (containsKey(key)) getLong(key) else null

internal class PhotoMediaInput(file: File) : AutoCloseable {
    val extractor = MediaExtractor()
    init {
        try { file.inputStream().use { extractor.setDataSource(it.fd) } }
        catch (error: Throwable) { extractor.release(); throw error }
    }
    val formats: List<MediaFormat> get() = (0 until extractor.trackCount).map(extractor::getTrackFormat)
    override fun close() { extractor.release() }
}

/** 编码器输出只写入本次私有临时文件；未完成的容器永不作为结果交付。 */
internal class PhotoTrackOutput(file: File, rotation: Int = 0) : AutoCloseable {
    private val muxer = MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private var track = -1
    private var completed = false
    private var lastTimeMicros = -1L
    var samples: Long = 0; private set
    init { muxer.setOrientationHint(rotation) }
    fun format(format: MediaFormat) {
        if (track >= 0) unsupportedVideo()
        track = muxer.addTrack(format); muxer.start()
    }
    fun write(bytes: ByteBuffer, info: MediaCodec.BufferInfo) {
        if (track < 0) unreadableVideo()
        if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
            bytes.position(info.offset); bytes.limit(info.offset + info.size)
            muxer.writeSampleData(track, bytes, info); samples++
            lastTimeMicros = maxOf(lastTimeMicros, info.presentationTimeUs)
        }
    }
    fun finish(endTimeMicros: Long? = null) {
        if (samples == 0L) unreadableVideo()
        if (endTimeMicros != null && endTimeMicros > lastTimeMicros) {
            val info = MediaCodec.BufferInfo().apply { set(0, 0, endTimeMicros, MediaCodec.BUFFER_FLAG_END_OF_STREAM) }
            muxer.writeSampleData(track, ByteBuffer.allocate(0), info)
        }
        muxer.stop(); completed = true
    }
    override fun close() {
        // 错误路径不以stop的次级错误覆盖取消或原始失败；外层删除未完成文件。
        if (track >= 0 && !completed) runCatching { muxer.stop() }
        muxer.release()
    }
}

internal class PhotoCodecProgress {
    private var lastProgress = SystemClock.elapsedRealtime()
    suspend fun check(progress: Boolean) {
        currentCoroutineContext().ensureActive()
        if (progress) lastProgress = SystemClock.elapsedRealtime()
        else if (SystemClock.elapsedRealtime() - lastProgress > 30_000) {
            throw PhotoVideoConversionFailure(PhotoVideoFailureKind.SYSTEM)
        }
    }
}

/** Extractor与Codec的旗标数值不等价，禁止直接透传加密/分段旗标。 */
internal fun feedPhotoDecoder(extractor: MediaExtractor, decoder: MediaCodec, index: Int): Boolean {
    val bytes = decoder.getInputBuffer(index) ?: unsupportedVideo()
    bytes.clear()
    if (extractor.sampleTrackIndex < 0) {
        decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        return true
    }
    if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_ENCRYPTED != 0) unsupportedVideo()
    if (extractor.sampleSize > bytes.remaining()) unsupportedVideo()
    val size = extractor.readSampleData(bytes, 0)
    if (size <= 0) throw PhotoVideoConversionFailure(PhotoVideoFailureKind.MALFORMED_SOURCE)
    if (extractor.sampleTime < 0) unsupportedVideo()
    val flags = if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_PARTIAL_FRAME != 0) MediaCodec.BUFFER_FLAG_PARTIAL_FRAME else 0
    decoder.queueInputBuffer(index, 0, size, extractor.sampleTime, flags)
    extractor.advance()
    return false
}

/** 逐样本有界读取，视频不会整段进入内存。 */
internal class PhotoSampleBuffer {
    private var bytes = ByteBuffer.allocateDirect(256 * 1024)
    fun read(extractor: MediaExtractor): ByteBuffer {
        val size = extractor.sampleSize
        if (size <= 0 || size > 32L * 1024 * 1024) unsupportedVideo()
        if (bytes.capacity() < size) bytes = ByteBuffer.allocateDirect(size.toInt())
        bytes.clear()
        if (extractor.readSampleData(bytes, 0) != size.toInt()) unreadableVideo()
        bytes.position(0); bytes.limit(size.toInt())
        return bytes
    }
}

internal suspend fun copyPhotoTrack(source: File, trackIndex: Int, destination: File) {
    PhotoMediaInput(source).use { input ->
        val extractor = input.extractor
        extractor.selectTrack(trackIndex)
        PhotoTrackOutput(destination).use { output ->
            output.format(extractor.getTrackFormat(trackIndex))
            val bytes = PhotoSampleBuffer(); val info = MediaCodec.BufferInfo()
            while (extractor.sampleTrackIndex >= 0) {
                currentCoroutineContext().ensureActive()
                if (extractor.sampleFlags and (MediaExtractor.SAMPLE_FLAG_ENCRYPTED or MediaExtractor.SAMPLE_FLAG_PARTIAL_FRAME) != 0) unsupportedVideo()
                val sample = bytes.read(extractor)
                info.set(0, sample.remaining(), extractor.sampleTime,
                    if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                output.write(sample, info); extractor.advance()
            }
            output.finish(extractor.getTrackFormat(trackIndex).longOrNull(MediaFormat.KEY_DURATION))
        }
    }
}

internal fun photoTrackStart(file: File, index: Int): Long = PhotoMediaInput(file).use { input ->
    input.extractor.selectTrack(index)
    input.extractor.sampleTime.takeIf { it >= 0 } ?: unreadableVideo()
}

internal suspend fun muxPhotoTracks(sources: List<File>, destination: File, rotation: Int, offsets: List<Long> = sources.map { 0L }) {
    require(sources.size == offsets.size)
    val inputs = mutableListOf<PhotoMediaInput>()
    val muxer = MediaMuxer(destination.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    try {
        sources.forEach { inputs += PhotoMediaInput(it) }
        muxer.setOrientationHint(rotation)
        val tracks = inputs.map { input ->
            if (input.extractor.trackCount != 1) unreadableVideo()
            input.extractor.selectTrack(0)
            muxer.addTrack(input.extractor.getTrackFormat(0))
        }
        muxer.start()
        val bytes = PhotoSampleBuffer(); val info = MediaCodec.BufferInfo()
        val lastTimes = LongArray(inputs.size) { -1 }
        while (true) {
            currentCoroutineContext().ensureActive()
            val index = inputs.indices.filter { inputs[it].extractor.sampleTrackIndex >= 0 }
                .minByOrNull { inputs[it].extractor.sampleTime + offsets[it] } ?: break
            val extractor = inputs[index].extractor
            val sample = bytes.read(extractor)
            info.set(0, sample.remaining(), extractor.sampleTime + offsets[index],
                if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            muxer.writeSampleData(tracks[index], sample, info); extractor.advance()
            lastTimes[index] = maxOf(lastTimes[index], info.presentationTimeUs)
        }
        inputs.forEachIndexed { index, input ->
            val end = input.extractor.getTrackFormat(0).longOrNull(MediaFormat.KEY_DURATION)?.plus(offsets[index])
            if (end != null && end > lastTimes[index]) {
                info.set(0, 0, end, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                muxer.writeSampleData(tracks[index], ByteBuffer.allocate(0), info)
            }
        }
        muxer.stop()
    } finally {
        inputs.forEach { it.close() }; muxer.release()
    }
}

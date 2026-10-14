package io.github.qwertyuiop1995.dsmnativeclient

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.media.ExifInterface
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaMuxer
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotosPreviewConverter
import io.github.qwertyuiop1995.dsmnativeclient.photos.PhotoPreviewConversionFailure
import java.io.File
import java.nio.ByteBuffer
import java.util.UUID
import kotlinx.coroutines.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** 全部媒体由测试生成或使用已有纯色夹具；真实系统解码和编码，不替换转换器。 */
class SynologyPhotosPreviewConverterDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val directory = File(instrumentation.targetContext.cacheDir, "photo-preview-test-${UUID.randomUUID()}").apply { check(mkdir()) }
    @After fun cleanup() { check(directory.deleteRecursively()) }

    @Test fun threeJPEGsPreserveAspectAndOriginal() = runBlocking {
        val source = image(3000, 2000, "source.jpg") { canvas -> canvas.drawColor(Color.RED) }
        val original = source.readBytes()
        val converted = SynologyPhotosPreviewConverter.convert(source, "photo")
        assertDimensions(converted.large, 1920, 1280)
        assertDimensions(converted.small, 360, 240)
        assertDimensions(converted.medium, 480, 320)
        assertArrayEquals(original, source.readBytes())
        assertEquals(listOf("source.jpg"), directory.list()!!.toList())
    }

    @Test fun smallTransparentPNGUsesBlackBackgroundWithoutEnlargement() = runBlocking {
        val source = image(128, 64, "source.png") { canvas ->
            canvas.drawColor(Color.TRANSPARENT)
            canvas.drawRect(64f, 0f, 128f, 64f, Paint().apply { color = Color.argb(128, 255, 0, 0) })
        }
        val converted = SynologyPhotosPreviewConverter.convert(source, "photo")
        for (bytes in listOf(converted.large, converted.small, converted.medium)) {
            assertDimensions(bytes, 128, 64)
            withBitmap(bytes) { bitmap ->
                assertColor(Color.BLACK, bitmap.getPixel(20, 32))
                assertColor(Color.rgb(128, 0, 0), bitmap.getPixel(100, 32))
            }
        }
    }

    @Test fun allEightExifOrientationsAreAppliedExactlyOnceAndMetadataRemoved() = runBlocking {
        val expected = listOf(
            listOf(Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW),
            listOf(Color.GREEN, Color.RED, Color.YELLOW, Color.BLUE),
            listOf(Color.YELLOW, Color.BLUE, Color.GREEN, Color.RED),
            listOf(Color.BLUE, Color.YELLOW, Color.RED, Color.GREEN),
            listOf(Color.RED, Color.BLUE, Color.GREEN, Color.YELLOW),
            listOf(Color.BLUE, Color.RED, Color.YELLOW, Color.GREEN),
            listOf(Color.YELLOW, Color.GREEN, Color.BLUE, Color.RED),
            listOf(Color.GREEN, Color.YELLOW, Color.RED, Color.BLUE),
        )
        for (orientation in 1..8) {
            val source = image(160, 80, "orientation-$orientation.jpg") { canvas ->
                val paint = Paint()
                for ((index, color) in listOf(Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW).withIndex()) {
                    paint.color = color
                    val left = (index % 2) * 80f; val top = (index / 2) * 40f
                    canvas.drawRect(left, top, left + 80, top + 40, paint)
                }
            }
            ExifInterface(source).apply {
                setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString())
                setAttribute(ExifInterface.TAG_MAKE, "synthetic-camera")
                saveAttributes()
            }
            val original = source.readBytes()
            val converted = SynologyPhotosPreviewConverter.convert(source, "photo")
            for (bytes in listOf(converted.large, converted.small, converted.medium)) withBitmap(bytes) { bitmap ->
                assertEquals(if (orientation >= 5) 80 else 160, bitmap.width)
                assertEquals(if (orientation >= 5) 160 else 80, bitmap.height)
                for ((index, color) in expected[orientation - 1].withIndex()) {
                    assertColor(color, bitmap.getPixel(bitmap.width * (if (index % 2 == 0) 1 else 3) / 4,
                        bitmap.height * (if (index / 2 == 0) 1 else 3) / 4))
                }
            }
            val output = File(directory, "converted.jpg").apply { writeBytes(converted.large) }
            assertNull(ExifInterface(output).getAttribute(ExifInterface.TAG_MAKE))
            assertArrayEquals(original, source.readBytes())
            check(output.delete())
        }
    }

    @Test fun videoUsesThreeSecondFrameAndRetainsDisplayRotationWithoutFilmOutput() = runBlocking {
        val input = File(directory, "source.mp4")
        instrumentation.context.assets.open("synthetic-slideshow.mp4").use { stream -> input.outputStream().use(stream::copyTo) }
        val original = input.readBytes()
        for (rotation in listOf(0, 90, 180, 270)) {
            val source = if (rotation == 0) input else remux(input, rotation)
            val converted = SynologyPhotosPreviewConverter.convert(source, "video")
            for (bytes in listOf(converted.large, converted.small, converted.medium)) withBitmap(bytes) { bitmap ->
                assertEquals(if (rotation == 90 || rotation == 270) 120 else 160, bitmap.width)
                assertEquals(if (rotation == 90 || rotation == 270) 160 else 120, bitmap.height)
                assertColor(Color.rgb(100, 120, 190), bitmap.getPixel(bitmap.width / 2, bitmap.height / 2))
            }
        }
        assertArrayEquals(original, input.readBytes())
        assertEquals(setOf("source.mp4", "rotation-90.mp4", "rotation-180.mp4", "rotation-270.mp4"), directory.list()!!.toSet())
    }

    @Test fun damagedSourceAndUnsupportedMediaCannotProducePretendPreview() = runBlocking {
        val source = image(160, 80, "truncated.jpg") { it.drawColor(Color.RED) }
        source.writeBytes(source.readBytes().let { it.copyOf(it.size / 2) })
        assertTrue(failure { SynologyPhotosPreviewConverter.convert(source, "photo") } is Exception)
        for (type in listOf("live", "video360", "unknown")) {
            assertTrue(failure { SynologyPhotosPreviewConverter.convert(source, type) } is PhotoPreviewConversionFailure)
        }
        assertTrue(source.exists()); assertEquals(1, directory.list()!!.size)
    }

    @Test fun cancellationBeforeConversionDoesNotReadOrWriteMedia() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val job = scope.async(start = CoroutineStart.LAZY) { SynologyPhotosPreviewConverter.convert(File(directory, "missing"), "photo") }
            job.cancel()
            assertTrue(failure { job.await() } is CancellationException)
            assertTrue(directory.list()!!.isEmpty())
        } finally { scope.cancel() }
    }

    private fun image(width: Int, height: Int, name: String, draw: (Canvas) -> Unit): File {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        return try {
            draw(Canvas(bitmap))
            File(directory, name).apply { outputStream().use { check(bitmap.compress(if (name.endsWith("png")) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, 100, it)) } }
        } finally { bitmap.recycle() }
    }
    private fun assertDimensions(bytes: ByteArray, width: Int, height: Int) {
        assertEquals(255, bytes[0].toInt() and 255); assertEquals(216, bytes[1].toInt() and 255)
        withBitmap(bytes) { bitmap -> assertEquals(width, bitmap.width); assertEquals(height, bitmap.height) }
    }
    private fun withBitmap(bytes: ByteArray, block: (Bitmap) -> Unit) {
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: throw AssertionError("JPEG应可完整解码")
        try { block(bitmap) } finally { bitmap.recycle() }
    }
    private fun assertColor(expected: Int, actual: Int) {
        for (component in listOf(Color::red, Color::green, Color::blue)) assertTrue("JPEG颜色应保留", kotlin.math.abs(component(expected) - component(actual)) <= 18)
    }
    private fun remux(input: File, rotation: Int): File {
        val output = File(directory, "rotation-$rotation.mp4")
        val extractor = MediaExtractor()
        val muxer = MediaMuxer(output.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        try {
            extractor.setDataSource(input.path); extractor.selectTrack(0)
            muxer.setOrientationHint(rotation)
            val track = muxer.addTrack(extractor.getTrackFormat(0)); muxer.start()
            val bytes = ByteBuffer.allocate(256 * 1024); val info = MediaCodec.BufferInfo()
            while (true) {
                bytes.clear(); val size = extractor.readSampleData(bytes, 0); if (size < 0) break
                info.set(0, size, extractor.sampleTime, extractor.sampleFlags)
                muxer.writeSampleData(track, bytes, info); extractor.advance()
            }
            muxer.stop()
        } finally { extractor.release(); muxer.release() }
        return output
    }
    private suspend fun failure(block: suspend () -> Unit): Throwable {
        try { block() } catch (error: Throwable) { return error }
        throw AssertionError("应失败")
    }
}

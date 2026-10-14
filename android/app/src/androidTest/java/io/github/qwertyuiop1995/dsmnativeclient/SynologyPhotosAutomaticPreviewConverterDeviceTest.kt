package io.github.qwertyuiop1995.dsmnativeclient

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** 自动入口接入真实系统媒体转换；合成素材，不替换设备编解码器。 */
class SynologyPhotosAutomaticPreviewConverterDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val directory = File(instrumentation.targetContext.cacheDir, "automatic-preview-device-${UUID.randomUUID()}").apply { check(mkdir()) }
    private val task = SynologyPhotoAutomaticPreviewTask("synthetic", SynologyPhotoSpace.PERSONAL, 151, "Synthetic.png", 0, true, false)
    @After fun cleanup() { check(directory.deleteRecursively()) }

    @Test fun automaticImageProducesAllSizesWithoutCreatingVideoOrChangingOriginal() = runBlocking {
        val source = File(directory, "source.png")
        val bitmap = Bitmap.createBitmap(80, 40, Bitmap.Config.ARGB_8888)
        try { bitmap.eraseColor(Color.GREEN); source.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { bitmap.recycle() }
        val original = source.readBytes()
        val converted = SynologyPhotosAutomaticPreviewConverter.convert(source, task, File(directory, "preview.mp4"))
        assertNull(converted.video); assertNull(converted.signature)
        for (bytes in listOf(converted.thumbnail!!.large, converted.thumbnail.small, converted.thumbnail.medium)) {
            val output = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            try { assertEquals(80, output.width); assertEquals(40, output.height); assertTrue(Color.green(output.getPixel(40, 20)) > 240) }
            finally { output.recycle() }
        }
        assertArrayEquals(original, source.readBytes()); assertEquals(listOf("source.png"), directory.list()!!.toList())
    }
    @Test fun automaticVideoRespectsRequestedPartsAndCapturesActualEncodedSignature() = runBlocking {
        val source = File(directory, "source.mp4")
        instrumentation.context.assets.open("synthetic-slideshow.mp4").use { input -> source.outputStream().use(input::copyTo) }
        val original = source.readBytes()
        for (thumbnail in listOf(false, true)) {
            val output = File(directory, "preview-$thumbnail.mp4")
            val converted = SynologyPhotosAutomaticPreviewConverter.convert(source, task.copy(typeCode = 1, needsThumbnail = thumbnail, needsVideo = true), output)
            assertEquals(thumbnail, converted.thumbnail != null); assertEquals(output, converted.video)
            assertTrue(converted.signature!!.valid()); assertEquals(60L, converted.signature.tracks.first().sampleCount)
            assertEquals(SynologyPhotosVideoSignature.read(output), converted.signature)
            assertArrayEquals(original, source.readBytes()); assertTrue(output.delete())
        }
        assertEquals(listOf("source.mp4"), directory.list()!!.toList())
    }
    @Test fun truncatedEncodedImageIsReportedAsPhotoContentFailureWithoutOutput() = runBlocking {
        val source = File(directory, "truncated.jpg")
        val bitmap = Bitmap.createBitmap(256, 256, Bitmap.Config.ARGB_8888)
        try {
            for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) bitmap.setPixel(x, y,
                Color.rgb((x * 37 + y * 11) % 256, (x * 13 + y * 31) % 256, (x * 23 + y * 17) % 256))
            source.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it)) }
        } finally { bitmap.recycle() }
        val bytes = source.readBytes(); source.writeBytes(bytes.copyOf(bytes.size / 2)); val original = source.readBytes()
        try { SynologyPhotosAutomaticPreviewConverter.convert(source, task, File(directory, "preview.mp4")); fail("应拒绝不完整图片") }
        catch (error: SynologyPhotoAutomaticPreviewConversionFailure) { assertEquals(SynologyPhotoAutomaticPreviewFailure.PHOTO, error.kind) }
        assertArrayEquals(original, source.readBytes()); assertEquals(listOf("truncated.jpg"), directory.list()!!.toList())
    }
}

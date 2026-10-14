package io.github.qwertyuiop1995.dsmnativeclient

import android.graphics.*
import android.media.ExifInterface
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoFaceBounds
import io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotoFaceDraft
import io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotoFaceEditing
import io.github.qwertyuiop1995.dsmnativeclient.ui.photos.PhotoBitmapDecoder
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoFaceCropDeviceTest {
    @Test fun 显示方向八种EXIF只应用一次裁剪不携带原元数据且原件不变() = runBlocking {
        val expected = listOf(Color.RED, Color.GREEN, Color.YELLOW, Color.BLUE, Color.RED, Color.BLUE, Color.YELLOW, Color.GREEN)
        for (orientation in 1..8) {
            val file = File.createTempFile("synthetic-face-", ".jpg", InstrumentationRegistry.getInstrumentation().targetContext.cacheDir)
            try {
                val bitmap = Bitmap.createBitmap(160, 80, Bitmap.Config.ARGB_8888); val canvas = Canvas(bitmap); val paint = Paint()
                listOf(Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW).forEachIndexed { index, color ->
                    paint.color = color; val x = index % 2 * 80f; val y = index / 2 * 40f
                    canvas.drawRect(x, y, x + 80, y + 40, paint)
                }
                file.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 100, it)) }; bitmap.recycle()
                ExifInterface(file).apply { setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString()); setAttribute(ExifInterface.TAG_MAKE, "synthetic-camera"); saveAttributes() }
                val original = file.readBytes(); val image = PhotoBitmapDecoder.decode(original, 2560)
                try {
                    assertEquals(if (orientation >= 5) 80 else 160, image.width); assertEquals(if (orientation >= 5) 160 else 80, image.height)
                    val bytes = SynologyPhotoFaceEditing.crop(image, SynologyPhotoFaceBounds(.05, .05, .25, .25))
                    val cropped = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)!!
                    try {
                        val actual = cropped.getPixel(cropped.width / 2, cropped.height / 2); val color = expected[orientation - 1]
                        for (component in listOf<(Int) -> Int>(Color::red, Color::green, Color::blue)) assertTrue(kotlin.math.abs(component(color) - component(actual)) < 15)
                    } finally { cropped.recycle() }
                    val exif = ExifInterface(ByteArrayInputStream(bytes)); assertNull(exif.getAttribute(ExifInterface.TAG_MAKE))
                    assertEquals(ExifInterface.ORIENTATION_UNDEFINED, exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_UNDEFINED))
                    assertArrayEquals(original, file.readBytes())
                } finally { image.recycle() }
            } finally { assertTrue(file.delete()) }
        }
    }
    @Test fun 裁剪向外取整不越界最大256像素且保留纵横比() = runBlocking {
        val image = Bitmap.createBitmap(1200, 800, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.MAGENTA) }
        val original = ByteArrayOutputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it); image.recycle(); it.toByteArray() }
        val draft = SynologyPhotoFaceDraft("synthetic", null, SynologyPhotoFaceBounds(.5, .5, .5, .5), null, "Synthetic")
        val bytes = SynologyPhotoFaceEditing.crops(original, listOf(draft)).getValue("synthetic")
        val result = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)!!
        try { assertEquals(256, result.width); assertEquals(171, result.height); assertFalse(result.hasAlpha()) }
        finally { result.recycle() }
        val small = Bitmap.createBitmap(13, 11, Bitmap.Config.ARGB_8888)
        try {
            val tiny = SynologyPhotoFaceEditing.crop(small, SynologyPhotoFaceBounds(.91, .9, .09, .1))
            val bitmap = BitmapFactory.decodeByteArray(tiny, 0, tiny.size)!!
            try { assertEquals(2, bitmap.width); assertEquals(2, bitmap.height) } finally { bitmap.recycle() }
        } finally { small.recycle() }
    }
}

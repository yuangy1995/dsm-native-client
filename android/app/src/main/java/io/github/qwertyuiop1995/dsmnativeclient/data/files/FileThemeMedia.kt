package io.github.qwertyuiop1995.dsmnativeclient.data.files

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import io.github.qwertyuiop1995.dsmnativeclient.data.UploadContentDigest
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileThemeImage
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import kotlinx.coroutines.*
import java.io.File

/** 文件为本次选图的私有临时副本；不保存用户 URI，页面关闭后由所属页面清理。 */
internal data class FileThemeUpload(val file: File, val filename: String, val bytes: Long, val digest: String) {
    override fun toString() = "FileThemeUpload"
    suspend fun unchanged() = bytes == file.length() && digest == themeFileDigest(file)
}
internal data class FileThemeUploadOutcome(val status: FileSettingsOutcomeStatus, val image: FileThemeImage? = null, val failure: DsmFailure? = null)
internal suspend fun prepareThemeUpload(file: File, filename: String): FileThemeUpload = withContext(Dispatchers.IO) {
    if (!FileThemeImage.supportsFilename(filename) || filename.any { it == '\r' || it == '\n' || it == '\u0000' || it == '"' || it == '/' || it == '\\' }) throw settingsInvalid()
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw themeImageInvalid()
    FileThemeUpload(file, filename, file.length(), themeFileDigest(file))
}
internal suspend fun themeFileDigest(file: File): String = withContext(Dispatchers.IO) {
    val digest = UploadContentDigest(file.length())
    file.inputStream().buffered().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) { currentCoroutineContext().ensureActive(); val count = input.read(buffer); if (count < 0) break; digest.write(buffer, 0, count) }
    }
    digest.finish().sha256
}
/** 按显示区域采样，不把完整大图解码到内存，也不猜测 NAS 的上传尺寸上限。 */
internal suspend fun themePreview(file: File, displayPixels: Int): Bitmap = withContext(Dispatchers.IO) {
    require(displayPixels > 0)
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }; BitmapFactory.decodeFile(file.path, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw themeImageInvalid()
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / sample > displayPixels && sample <= Int.MAX_VALUE / 2) sample *= 2
    BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: throw themeImageInvalid()
}
private fun themeImageInvalid() = DsmFailure(null, "This image could not be opened", "Try again or choose another image.", kind = DsmErrorKind.FILE_THEME_IMAGE_INVALID)

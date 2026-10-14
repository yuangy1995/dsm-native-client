package io.github.qwertyuiop1995.dsmnativeclient.photos

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.Rect
import android.media.MediaMetadataRetriever
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotoConvertedPreview
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** 系统解码器处理EXIF/视频轨道方向，手动重建只取一帧，不转码整个视频。 */
internal object SynologyPhotosPreviewConverter {
    suspend fun convert(file: File, mediaType: String): SynologyPhotoConvertedPreview = withContext(Dispatchers.IO) {
        currentCoroutineContext().ensureActive()
        val bitmap = when (mediaType) {
            "photo" -> ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
                val size = dimensions(info.size.width, info.size.height, 1280)
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
                decoder.setTargetSize(size.first, size.second)
                decoder.setOnPartialImageListener { false }
            }
            "video" -> videoFrame(file)
            else -> throw PhotoPreviewConversionFailure()
        }
        try {
            currentCoroutineContext().ensureActive()
            SynologyPhotoConvertedPreview(jpeg(bitmap, 1280), jpeg(bitmap, 240), jpeg(bitmap, 320))
        } finally { bitmap.recycle() }
    }

    private suspend fun videoFrame(file: File): Bitmap {
        val retriever = MediaMetadataRetriever()
        try {
            file.inputStream().use { retriever.setDataSource(it.fd) }
            currentCoroutineContext().ensureActive()
            val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                ?.takeIf { it > 0 } ?: throw PhotoPreviewConversionFailure()
            val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: throw PhotoPreviewConversionFailure()
            val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: throw PhotoPreviewConversionFailure()
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            if (rotation !in setOf(0, 90, 180, 270)) throw PhotoPreviewConversionFailure()
            val displaySize = if (rotation == 90 || rotation == 270) dimensions(height, width, 1280) else dimensions(width, height, 1280)
            // 返回帧已应用轨道方向，不能再按metadata旋转第二次。
            return retriever.getScaledFrameAtTime(frameTimeMicros(duration), MediaMetadataRetriever.OPTION_CLOSEST,
                displaySize.first, displaySize.second) ?: throw PhotoPreviewConversionFailure()
        } finally { retriever.release() }
    }

    internal fun frameTimeMicros(durationMillis: Long): Long {
        if (durationMillis <= 0 || durationMillis > Long.MAX_VALUE / 1_000) throw PhotoPreviewConversionFailure()
        val duration = durationMillis * 1_000
        return minOf(if (durationMillis > 3_000) 3_000_000 else 1_000_000, maxOf(0, duration - 1_000_000 / 30))
    }

    internal fun dimensions(width: Int, height: Int, shortEdge: Int): Pair<Int, Int> {
        if (width <= 0 || height <= 0 || shortEdge <= 0) throw PhotoPreviewConversionFailure()
        val scale = minOf(1.0, shortEdge.toDouble() / minOf(width, height))
        val targetWidth = maxOf(1, (width * scale).toInt())
        val targetHeight = maxOf(1, (height * scale).toInt())
        // 极端长图不能在移动设备分配无界位图；保留NAS生成分支，不裁剪用户内容。
        if (targetWidth.toLong() * targetHeight > 16_777_216) throw PhotoPreviewConversionFailure()
        return targetWidth to targetHeight
    }

    private suspend fun jpeg(source: Bitmap, shortEdge: Int): ByteArray {
        currentCoroutineContext().ensureActive()
        val (width, height) = dimensions(source.width, source.height, shortEdge)
        val target = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            target.setHasAlpha(false)
            val canvas = Canvas(target)
            canvas.drawColor(Color.BLACK)
            canvas.drawBitmap(source, null, Rect(0, 0, width, height), Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
            val output = ByteArrayOutputStream()
            if (!target.compress(Bitmap.CompressFormat.JPEG, 90, output) || output.size() == 0) throw PhotoPreviewConversionFailure()
            currentCoroutineContext().ensureActive()
            return output.toByteArray()
        } finally { target.recycle() }
    }
}

internal class PhotoPreviewConversionFailure : Exception("Photo preview conversion failed")

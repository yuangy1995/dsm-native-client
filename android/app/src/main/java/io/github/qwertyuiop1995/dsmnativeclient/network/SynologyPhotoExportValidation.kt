package io.github.qwertyuiop1995.dsmnativeclient.network

import android.graphics.ImageDecoder
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoFailureKind
import java.io.File
import java.io.RandomAccessFile

internal object SynologyPhotoExportValidation {
    /** 使用平台解码器拒绝不完整图片，采样避免为了校验导出分配原尺寸位图。 */
    fun jpeg(file: File) {
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
            if (info.mimeType != "image/jpeg" || info.size.width <= 0 || info.size.height <= 0) invalid()
            decoder.setOnPartialImageListener { false }
            val ratio = minOf(1.0, 512.0 / maxOf(info.size.width, info.size.height))
            decoder.setTargetSize(maxOf(1, (info.size.width * ratio).toInt()), maxOf(1, (info.size.height * ratio).toInt()))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        bitmap.recycle()
    }

    /** 只校验ZIP首标识和完整结束记录；不将容器检查等同每个成员的CRC验证。 */
    fun archive(file: File) {
        RandomAccessFile(file, "r").use { input ->
            val size = input.length()
            if (size < 22) invalid()
            if (input.readInt() !in setOf(0x504b0304, 0x504b0506, 0x504b0606)) invalid()
            val tail = ByteArray(minOf(size, 65_557L).toInt())
            input.seek(size - tail.size); input.readFully(tail)
            for (index in tail.size - 22 downTo 0) {
                if (tail[index] == 0x50.toByte() && tail[index + 1] == 0x4b.toByte() && tail[index + 2] == 5.toByte() && tail[index + 3] == 6.toByte()) {
                    val commentLength = (tail[index + 20].toInt() and 255) or ((tail[index + 21].toInt() and 255) shl 8)
                    if (index + 22 + commentLength == tail.size) return
                }
            }
            invalid()
        }
    }
    private fun invalid(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
}

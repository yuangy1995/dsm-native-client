package io.github.qwertyuiop1995.dsmnativeclient.photos

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoManualFacesCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.photos.PhotoBitmapDecoder
import java.io.ByteArrayOutputStream
import kotlin.math.*
import kotlinx.coroutines.*

/** 草稿不持久化；改变原框等价于先新增成功，再移除原标记。 */
internal data class SynologyPhotoFaceDraft(
    val key: String, val original: SynologyPhotoFaceSnapshot?, val bounds: SynologyPhotoFaceBounds,
    val person: SynologyPhotoPersonSnapshot?, val name: String, val removed: Boolean = false,
) {
    val resized: Boolean get() = original != null && !bounds.matches(original.bounds)
    val changed: Boolean get() = if (removed) original != null else original == null || resized ||
        person?.id != original.personId.takeIf { it > 0 } || name != original.name
    val valid: Boolean get() = removed || !changed || bounds.valid && (person != null || name.isNotBlank())
    val needsCrop: Boolean get() = !removed && (original == null || resized)
    override fun toString() = "PhotoFaceDraft"
}

internal object SynologyPhotoFaceEditing {
    fun center(width: Int, height: Int): SynologyPhotoFaceBounds {
        require(width > 0 && height > 0)
        val side = min(width, height) * 0.3
        return SynologyPhotoFaceBounds((1 - side / width) / 2, (1 - side / height) / 2, side / width, side / height)
    }
    fun drafts(faces: List<SynologyPhotoFaceSnapshot>, space: SynologyPhotoSpace) = faces.map { face ->
        SynologyPhotoFaceDraft("face-${face.id}", face, face.bounds,
            face.personId.takeIf { it > 0 }?.let { SynologyPhotoPersonSnapshot(it, face.name, null, space) }, face.name)
    }
    fun changes(drafts: List<SynologyPhotoFaceDraft>, images: Map<String, ByteArray>): List<SynologyPhotoFaceChange> = buildList {
        for (draft in drafts.filter { it.changed }) {
            if (!draft.valid) throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
            val original = draft.original
            if (draft.removed) { original?.let { add(SynologyPhotoFaceChange.Remove(it)) }; continue }
            val name = draft.person?.name ?: draft.name.trim()
            if (draft.needsCrop) {
                val bytes = images[draft.key] ?: throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
                add(SynologyPhotoFaceChange.Add(draft.key, draft.bounds, draft.person, name, SynologyPhotoManualFacesCodec.digest(bytes)))
                original?.let { add(SynologyPhotoFaceChange.Remove(it)) }
            } else if (original != null) add(SynologyPhotoFaceChange.Reassign(original, draft.person, name))
        }
    }
    /** 输入为显示图像内的像素坐标，避免留白、反向拖动及非方形图片改变归一化比例。 */
    fun square(startX: Float, startY: Float, endX: Float, endY: Float, width: Float, height: Float): SynologyPhotoFaceBounds? {
        if (width <= 0 || height <= 0 || !listOf(startX, startY, endX, endY, width, height).all { it.isFinite() }) return null
        val x = startX.coerceIn(0f, width); val y = startY.coerceIn(0f, height)
        val dx = endX - x; val dy = endY - y
        val limit = min(if (dx < 0) x else width - x, if (dy < 0) y else height - y)
        val side = min(max(abs(dx), abs(dy)), limit)
        if (side < min(36f, min(width, height))) return null
        val left = if (dx < 0) x - side else x; val top = if (dy < 0) y - side else y
        val nx = left.toDouble() / width; val ny = top.toDouble() / height
        return SynologyPhotoFaceBounds(nx, ny, min(side.toDouble() / width, 1 - nx), min(side.toDouble() / height, 1 - ny))
    }
    suspend fun crops(data: ByteArray, drafts: List<SynologyPhotoFaceDraft>): Map<String, ByteArray> {
        val additions = drafts.filter { it.needsCrop }
        if (additions.isEmpty()) return emptyMap()
        val image = PhotoBitmapDecoder.decode(data, 2560)
        return try { withContext(Dispatchers.Default) { additions.associate { ensureActive(); it.key to crop(image, it.bounds) } } }
        finally { image.recycle() }
    }
    /** 向外取整裁剪，输出不超过256像素的RGB JPEG，原图始终只读。 */
    fun crop(image: Bitmap, bounds: SynologyPhotoFaceBounds): ByteArray {
        require(bounds.valid)
        val source = Rect(floor(bounds.x * image.width).toInt(), floor(bounds.y * image.height).toInt(),
            ceil((bounds.x + bounds.width) * image.width).toInt().coerceAtMost(image.width),
            ceil((bounds.y + bounds.height) * image.height).toInt().coerceAtMost(image.height))
        val scale = min(1.0, 256.0 / max(source.width(), source.height()))
        val target = Bitmap.createBitmap(max(1, (source.width() * scale).roundToInt()), max(1, (source.height() * scale).roundToInt()), Bitmap.Config.ARGB_8888)
        return try {
            target.setHasAlpha(false)
            Canvas(target).drawBitmap(image, source, Rect(0, 0, target.width, target.height), Paint(Paint.FILTER_BITMAP_FLAG))
            ByteArrayOutputStream().use { output -> check(target.compress(Bitmap.CompressFormat.JPEG, 90, output)); output.toByteArray() }
        } finally { target.recycle() }
    }
}

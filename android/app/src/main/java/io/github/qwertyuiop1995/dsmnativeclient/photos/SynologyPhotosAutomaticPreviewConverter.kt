package io.github.qwertyuiop1995.dsmnativeclient.photos

import android.graphics.ImageDecoder
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoAutomaticPreviewFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoAutomaticPreviewTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoPreviewVideoSignature
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotoConvertedPreview
import java.io.File

internal class SynologyPhotoAutomaticPreviewMedia(
    val thumbnail: SynologyPhotoConvertedPreview?, val video: File?, val signature: SynologyPhotoPreviewVideoSignature?,
) {
    override fun toString() = "PhotoAutomaticPreviewMedia"
}

/** 只有系统明确报告源内容损坏才允许同步失败，设备能力及未知异常继续保持本机失败。 */
internal class SynologyPhotoAutomaticPreviewConversionFailure(val kind: SynologyPhotoAutomaticPreviewFailure) :
    Exception("Photo automatic preview source could not be decoded")

internal object SynologyPhotosAutomaticPreviewConverter {
    suspend fun convert(source: File, task: SynologyPhotoAutomaticPreviewTask, output: File): SynologyPhotoAutomaticPreviewMedia {
        val thumbnail = if (task.needsThumbnail) try {
            SynologyPhotosPreviewConverter.convert(source, if (task.video) "video" else "photo")
        } catch (error: ImageDecoder.DecodeException) {
            if (error.error !in setOf(ImageDecoder.DecodeException.SOURCE_INCOMPLETE, ImageDecoder.DecodeException.SOURCE_MALFORMED_DATA)) throw error
            throw SynologyPhotoAutomaticPreviewConversionFailure(SynologyPhotoAutomaticPreviewFailure.PHOTO)
        } else null
        val video = if (task.needsVideo) try { SynologyPhotosVideoConverter.convert(source, output) }
        catch (error: PhotoVideoConversionFailure) {
            if (error.kind != PhotoVideoFailureKind.MALFORMED_SOURCE) throw error
            throw SynologyPhotoAutomaticPreviewConversionFailure(SynologyPhotoAutomaticPreviewFailure.VIDEO)
        } else null
        // 输出校验失败不能反推原件损坏，不能进入set_broken。
        val signature = video?.let { SynologyPhotosVideoSignature.read(it) }
        return SynologyPhotoAutomaticPreviewMedia(thumbnail, video, signature)
    }
}

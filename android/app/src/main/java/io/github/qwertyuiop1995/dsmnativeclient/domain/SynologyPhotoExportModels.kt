package io.github.qwertyuiop1995.dsmnativeclient.domain

import java.util.Locale

enum class SynologyPhotoDownloadFormat(val value: String) {
    ORIGINAL("source"), OPTIMIZED_JPEG("optimized_jpeg"), ORIGINAL_SIZE_JPEG("original_size_jpeg"),
}

/** 集合导出使用完整相册/目录，不能用当前加载页替代。 */
sealed interface SynologyPhotoArchiveTarget {
    data class Album(val id: Long) : SynologyPhotoArchiveTarget
    data class Folder(val id: Long, val space: SynologyPhotoSpace) : SynologyPhotoArchiveTarget
    data class Selection(val photos: List<SynologyPhoto>, val folders: List<SynologyPhotoCollection>) : SynologyPhotoArchiveTarget
}

val SynologyPhoto.supportsOptimizedJPEG: Boolean get() = mediaType != "video" &&
    filename.substringAfterLast('.', "").lowercase(Locale.ROOT) !in setOf("gif", "webp")

val SynologyPhoto.supportsOriginalSizeJPEG: Boolean get() {
    val extension = filename.substringAfterLast('.', "").lowercase(Locale.ROOT)
    return if (extension in setOf("heic", "heif", "hif")) mediaType in setOf("photo", "photo360", "burst", "motion_photo", "live")
    else extension in setOf("tif", "tiff", "arw", "srf", "sr2", "dcr", "k25", "kdc", "cr2", "cr3", "crw", "nef", "mrw", "ptx", "pef", "raf", "3fr", "erf", "mef", "mos", "orf", "rw2", "dng", "x3f", "raw")
}

package io.github.qwertyuiop1995.dsmnativeclient.network

/** 三档派生JPEG只在当前操作内存中流转，不保存源文件名、EXIF或原始路径。 */
internal class SynologyPhotoConvertedPreview(val large: ByteArray, val small: ByteArray, val medium: ByteArray) {
    override fun toString() = "PhotoConvertedPreview"
}

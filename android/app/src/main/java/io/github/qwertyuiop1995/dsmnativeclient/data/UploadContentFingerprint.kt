package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable

/** 仅保存完整文件的摘要；不包含本地 URI、NAS 路径或文件正文。 */
@Serializable
data class UploadContentFingerprint(val bytes: Long, val sha256: String)

@Serializable
internal data class UploadContentRecord(
    val schemaVersion: Int = 1,
    val profileId: String,
    val executionId: String,
    val fingerprint: UploadContentFingerprint,
)

/** 有界内存计数，长度超出时立即停止，不接收追加到旧文件的内容。 */
internal class UploadContentDigest(private val expectedBytes: Long) : OutputStream() {
    private val digest = MessageDigest.getInstance("SHA-256")
    private var bytes = 0L

    override fun write(value: Int) = write(byteArrayOf(value.toByte()), 0, 1)

    override fun write(buffer: ByteArray, offset: Int, length: Int) {
        if (length.toLong() > expectedBytes - bytes) throw IOException("Upload content length changed")
        digest.update(buffer, offset, length)
        bytes += length
    }

    fun finish(): UploadContentFingerprint {
        if (bytes != expectedBytes) throw IOException("Upload content length changed")
        return UploadContentFingerprint(bytes, digest.digest().joinToString("") { "%02x".format(it) })
    }
}

internal suspend fun UploadSource.contentFingerprint(): UploadContentFingerprint = withContext(Dispatchers.IO) {
    val digest = UploadContentDigest(contentLength)
    openInputStream().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            currentCoroutineContext().ensureActive()
            val count = input.read(buffer)
            if (count < 0) break
            digest.write(buffer, 0, count)
        }
    }
    digest.finish()
}

/** 使用原 Repository 的权限和流式下载，仅在结果不明或明确恢复时读取正文。 */
internal suspend fun DsmRepository.matchesUploadContent(item: FileItem, fingerprint: UploadContentFingerprint): Boolean {
    if (item.isDirectory || item.size != fingerprint.bytes) return false
    val digest = UploadContentDigest(fingerprint.bytes)
    return try {
        download(item, digest)
        digest.finish() == fingerprint
    } catch (_: IOException) { false }
}

internal suspend fun DsmRepository.uploadMatches(
    path: String, expectedSize: Long, fingerprint: UploadContentFingerprint? = null, requireContent: Boolean = false,
): Boolean {
    if (requireContent && fingerprint == null) return false
    val item = fileInfo(path) ?: return false
    if (item.isDirectory || item.size != expectedSize) return false
    return !requireContent || matchesUploadContent(item, requireNotNull(fingerprint))
}

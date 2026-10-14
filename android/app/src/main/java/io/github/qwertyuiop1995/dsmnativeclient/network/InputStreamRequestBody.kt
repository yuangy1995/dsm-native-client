package io.github.qwertyuiop1995.dsmnativeclient.network

import java.io.InputStream
import java.io.IOException
import okhttp3.RequestBody
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okio.BufferedSink

internal class InputStreamRequestBody(
    contentType: String?,
    private val contentLength: Long,
    private val openInputStream: () -> InputStream,
    private val onProgress: (Long, Long) -> Unit,
    private val onContentRead: (io.github.qwertyuiop1995.dsmnativeclient.data.UploadContentFingerprint) -> Unit = {},
) : RequestBody() {
    private val mediaType = contentType?.toMediaTypeOrNull()

    override fun contentType() = mediaType

    override fun contentLength() = contentLength

    // ContentResolver、跨 NAS 管道等上传源均不可倒带，禁止 OkHttp 自动重放正文。
    override fun isOneShot() = true

    override fun writeTo(sink: BufferedSink) {
        var completed = 0L
        val digest = io.github.qwertyuiop1995.dsmnativeclient.data.UploadContentDigest(contentLength)
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        openInputStream().use { input ->
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.write(buffer, 0, count)
                sink.write(buffer, 0, count)
                completed += count
                onProgress(completed, contentLength)
            }
        }
        if (completed != contentLength) {
            throw IOException("Upload source length changed")
        }
        onContentRead(digest.finish())
    }
}

package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.Collections
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/**
 * 仅承载已记录的 Photos 媒体 GET。复用连接的 OkHttp/TLS 策略；凭据只在 Header，
 * 缩略图有界、原件流式、播放器按范围读取。禁止跳转、整段视频预下载和错误页落盘。
 */
class SynologyPhotosMediaTransport internal constructor(
    private val profile: NasProfile,
    private val session: DsmSession,
    private val endpoint: String,
    private val http: OkHttpClient,
) {
    init {
        if (profile.id != session.profileId || session.sid.isBlank()) fail(SynologyPhotoFailureKind.PERMISSION)
        // 不绕过主连接的证书策略；也不允许意外配置的客户端把会话发到重定向目标。
        require(!http.followRedirects && !http.followSslRedirects && !http.retryOnConnectionFailure)
    }

    suspend fun thumbnail(thumbnail: SynologyPhotoThumbnail, large: Boolean): ByteArray = withContext(Dispatchers.IO) {
        require(thumbnail.unitId > 0)
        val request = request("/synofoto/api/v2/p/Thumbnail/get", mapOf(
            "id" to thumbnail.unitId.toString(),
            "cache_key" to JsonPrimitive(thumbnail.revision).toString(),
            "type" to JsonPrimitive("unit").toString(),
            "size" to JsonPrimitive(if (large) "xl" else "m").toString(),
        ), "image/*")
        withResponse(request) { response ->
            validate(response, 200, imageOnly = true)
            if ((response.body?.contentLength() ?: -1) > MAX_IMAGE_BYTES) fail()
            val result = ByteArrayOutputStream()
            response.body!!.byteStream().use { input ->
                val buffer = ByteArray(32 * 1024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count > MAX_IMAGE_BYTES - result.size()) fail()
                    result.write(buffer, 0, count)
                }
            }
            if (result.size() == 0) fail()
            result.toByteArray()
        }
    }

    suspend fun download(
        capability: ApiCapability,
        parameters: Map<String, String>,
        destination: File,
        expectedBytes: Long,
        progress: (Long, Long) -> Unit,
    ): Unit = withContext(Dispatchers.IO) {
        require(expectedBytes >= 0)
        if (destination.exists()) throw java.nio.file.FileAlreadyExistsException(destination.name)
        val parent = destination.absoluteFile.parentFile ?: fail()
        val staging = File(parent, ".${UUID.randomUUID()}.photos-download")
        check(staging.createNewFile())
        try {
            withResponse(apiRequest(capability, "download", parameters)) { response ->
                validate(response, 200)
                val declared = response.body!!.contentLength()
                if (declared >= 0 && declared != expectedBytes) fail(SynologyPhotoFailureKind.LENGTH_MISMATCH)
                var done = 0L
                var lastProgress = 0L
                response.body!!.byteStream().use { input ->
                    staging.outputStream().buffered().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (count.toLong() > expectedBytes - done) fail(SynologyPhotoFailureKind.LENGTH_MISMATCH)
                            output.write(buffer, 0, count)
                            done += count
                            val now = System.nanoTime()
                            if (now - lastProgress >= 100_000_000L || done == expectedBytes) {
                                progress(done, expectedBytes)
                                lastProgress = now
                            }
                        }
                    }
                }
                if (done != expectedBytes) fail(SynologyPhotoFailureKind.LENGTH_MISMATCH)
                currentCoroutineContext().ensureActive()
                // 不使用 REPLACE_EXISTING，也不清理用户已有目标；仅清理本次随机暂存文件。
                Files.move(staging.toPath(), destination.toPath())
            }
        } finally {
            staging.delete()
        }
    }

    suspend fun video(
        capability: ApiCapability, method: String, parameters: Map<String, String>,
    ): RandomAccessMediaSource = withContext(Dispatchers.IO) {
        val mediaRequest = apiRequest(capability, method, parameters)
        val probe = mediaRequest.newBuilder().header("Range", "bytes=0-0").build()
        val total = withResponse(probe) { response ->
            validate(response, 206)
            val range = contentRange(response)
            if (range.first != 0L || range.second != 0L || range.third <= 0) fail()
            val body = response.body!!
            if (body.contentLength() >= 0 && body.contentLength() != 1L) fail()
            body.byteStream().use { if (it.read() < 0 || it.read() != -1) fail() }
            range.third
        }
        currentCoroutineContext().ensureActive()
        PhotosRangeSource(mediaRequest, total)
    }

    private fun apiRequest(capability: ApiCapability, method: String, parameters: Map<String, String>): Request {
        require(capability.name in setOf("SYNO.Foto.Download", "SYNO.Foto.Streaming"))
        require(capability.minVersion <= 2 && capability.maxVersion >= 2 && capability.requestFormat.equals("JSON", true))
        require((capability.name == "SYNO.Foto.Download" && method == "download") ||
            (capability.name == "SYNO.Foto.Streaming" && method == "streaming"))
        require(parameters.keys.none { it.lowercase() in setOf("api", "version", "method", "_sid", "sid", "synotoken", "cookie", "did") })
        return request(photoApiPath(capability.path), mapOf(
            "api" to capability.name, "version" to "2", "method" to method,
        ) + parameters)
    }

    private fun request(path: String, parameters: Map<String, String>, accept: String = "application/octet-stream, video/*"): Request {
        val base = endpoint.toHttpUrl()
        val url = "$endpoint$path".toHttpUrl().newBuilder().apply {
            parameters.forEach { (name, value) -> addQueryParameter(name, value) }
        }.build()
        require(url.scheme == base.scheme && url.host == base.host && url.port == base.port)
        return Request.Builder().url(url).get().header("Accept", accept)
            .header("User-Agent", "LanStash-Android/0.1")
            .header("Cookie", "id=${session.sid}")
            .apply { session.synoToken?.takeIf { it.isNotBlank() }?.let { header("X-SYNO-TOKEN", it) } }
            .build()
    }

    private suspend fun <T> withResponse(request: Request, body: suspend (Response) -> T): T = coroutineScope {
        val call = http.newCall(request)
        // 收到响应头后仍保持取消关联；阻塞中的响应体读取必须立即随页面/账号取消。
        val cancellation = launch(start = CoroutineStart.UNDISPATCHED) {
            try { awaitCancellation() } finally { call.cancel() }
        }
        try { await(call).use { body(it) } } finally { cancellation.cancel() }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private suspend fun await(call: Call): Response = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, error: IOException) {
                if (!continuation.isCancelled) continuation.resumeWithException(SynologyPhotoFailure(SynologyPhotoFailureKind.MEDIA, error))
            }
            override fun onResponse(call: Call, response: Response) {
                continuation.resume(response) { response.close() }
            }
        })
    }

    private fun validate(response: Response, status: Int, imageOnly: Boolean = false) {
        if (response.code == 401 || response.code == 403) fail(SynologyPhotoFailureKind.PERMISSION)
        if (response.code != status || response.body == null) fail()
        val type = response.header("Content-Type").orEmpty().lowercase()
        if (type.contains("json") || type.contains("html") || type.contains("zip") ||
            (imageOnly && !type.startsWith("image/"))) fail()
    }

    private fun contentRange(response: Response): Triple<Long, Long, Long> {
        val match = RANGE.matchEntire(response.header("Content-Range").orEmpty().trim()) ?: fail()
        val (start, end, total) = match.destructured
        val values = listOf(start, end, total).map { it.toLongOrNull() ?: fail() }
        if (values[0] < 0 || values[1] < values[0] || values[2] <= values[1]) fail()
        return Triple(values[0], values[1], values[2])
    }

    /** 每个播放器最多保留两个 1 MiB 块；关闭播放器时立即取消活动网络读取。 */
    private inner class PhotosRangeSource(private val request: Request, override val size: Long) : RandomAccessMediaSource {
        private val closed = AtomicBoolean(false)
        private val active = Collections.synchronizedSet(mutableSetOf<Call>())
        private val cache = LinkedHashMap<Long, ByteArray>(4, 0.75f, true)
        private val lock = ReentrantLock()

        override fun readAt(position: Long, buffer: ByteArray, offset: Int, length: Int): Int {
            if (closed.get()) throw IOException("Photos media source closed")
            if (position < 0 || offset < 0 || length < 0 || offset > buffer.size - length) throw IndexOutOfBoundsException()
            if (length == 0) return 0
            if (position >= size) return -1
            lock.withLock {
                try {
                if (closed.get()) throw IOException("Photos media source closed")
                val blockStart = (position / RANGE_BLOCK_BYTES) * RANGE_BLOCK_BYTES
                val data = cache[blockStart] ?: readBlock(blockStart).also {
                    cache[blockStart] = it
                    while (cache.size > 2) cache.remove(cache.keys.first())
                }
                val from = (position - blockStart).toInt()
                val count = minOf(length, data.size - from)
                data.copyInto(buffer, offset, from, from + count)
                return count
                } finally { if (closed.get()) cache.clear() }
            }
        }

        private fun readBlock(start: Long): ByteArray {
            val end = minOf(size - 1, start + RANGE_BLOCK_BYTES - 1)
            val call = http.newCall(request.newBuilder().header("Range", "bytes=$start-$end").build())
            active.add(call)
            try {
                if (closed.get()) { call.cancel(); throw IOException("Photos media source closed") }
                return call.execute().use { response ->
                    validate(response, 206)
                    if (contentRange(response) != Triple(start, end, size)) fail()
                    val count = (end - start + 1).toInt()
                    if (response.body!!.contentLength() >= 0 && response.body!!.contentLength() != count.toLong()) fail()
                    val bytes = ByteArray(count)
                    response.body!!.byteStream().use { input ->
                        var done = 0
                        while (done < count) {
                            if (closed.get()) throw IOException("Photos media source closed")
                            val read = input.read(bytes, done, count - done)
                            if (read < 0) fail()
                            done += read
                        }
                        if (input.read() != -1) fail()
                    }
                    bytes
                }
            } finally { active.remove(call) }
        }

        override fun close() {
            if (!closed.compareAndSet(false, true)) return
            synchronized(active) { active.forEach { it.cancel() } }
            // 关闭可能发生在主线程，不能等待正在读取的网络块持锁退出。
            if (lock.tryLock()) try { cache.clear() } finally { lock.unlock() }
        }
    }

    private companion object {
        const val MAX_IMAGE_BYTES = 8 * 1024 * 1024
        const val RANGE_BLOCK_BYTES = 1024L * 1024L
        val RANGE = Regex("bytes\\s+(\\d+)-(\\d+)/(\\d+)", RegexOption.IGNORE_CASE)
        fun fail(kind: SynologyPhotoFailureKind = SynologyPhotoFailureKind.MEDIA): Nothing = throw SynologyPhotoFailure(kind)
    }
}

/** 能力路径只能是本 NAS 的路径；不接受查询、片段、反斜线或目录穿越。 */
internal fun photoApiPath(path: String): String {
    require(path.isNotBlank() && !path.startsWith("//") && !path.contains(":") &&
        path.none { it == '?' || it == '#' || it == '\\' || it.code < 32 } &&
        path.split('/').none { it == "." || it == ".." } && !path.contains('%'))
    return if (path.startsWith('/')) path else "/webapi/$path"
}

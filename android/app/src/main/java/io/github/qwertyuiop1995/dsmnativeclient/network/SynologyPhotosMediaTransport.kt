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
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.MultipartBody

/**
 * 仅承载已记录的 Photos 媒体 GET/POST。复用连接的 OkHttp/TLS 策略；凭据只在 Header，
 * 缩略图有界、原件流式、播放器按范围读取。禁止跳转、整段视频预下载和错误页落盘。
 */
class SynologyPhotosMediaTransport internal constructor(
    private val profile: NasProfile,
    private val session: DsmSession,
    private val endpoint: String,
    private val http: OkHttpClient,
    private val authorizeRequest: () -> Unit = {},
    private val onAccessFailure: () -> Unit = {},
    private val validateJPEG: (File) -> Unit = SynologyPhotoExportValidation::jpeg,
) {
    init {
        if (profile.id != session.profileId || session.sid.isBlank()) fail(SynologyPhotoFailureKind.PERMISSION)
        // 不绕过主连接的证书策略；也不允许意外配置的客户端把会话发到重定向目标。
        require(!http.followRedirects && !http.followSslRedirects && !http.retryOnConnectionFailure)
    }

    internal fun previewEvents(): SynologyPhotoPreviewEvents = SynologyPhotosPreviewEvents(connect = {
        SynologyPhotosPreviewSocket(http, photoPreviewSocketRequest(endpoint, session), authorizeRequest, onAccessFailure)
    })

    /** 同步转换上传只返回明确成功/拒绝；网络、HTTP及畸形回执均抛出并保留未知。 */
    internal suspend fun uploadPreview(capability: ApiCapability, unitId: Long, converted: SynologyPhotoConvertedPreview): Boolean =
        uploadAutomaticPreview(capability, unitId, converted, null)

    internal suspend fun uploadAutomaticPreview(capability: ApiCapability, unitId: Long,
        thumbnail: SynologyPhotoConvertedPreview?, video: File?): Boolean = withContext(Dispatchers.IO) {
        require(capability.name in setOf("SYNO.Foto.Upload.ConvertedFile", "SYNO.FotoTeam.Upload.ConvertedFile") &&
            3 in capability.minVersion..capability.maxVersion && capability.requestFormat.equals("JSON", true) && unitId > 0)
        require(thumbnail != null || video != null)
        require(video == null || video.isFile && video.length() > 0)
        val multipart = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("api", capability.name).addFormDataPart("version", "3")
            .addFormDataPart("method", "upload").addFormDataPart("unit_id", unitId.toString())
            .apply {
                for ((name, bytes) in thumbnail?.let { listOf("thumb_xl" to it.large, "thumb_sm" to it.small, "thumb_m" to it.medium) }.orEmpty()) {
                    require(bytes.isNotEmpty())
                    addFormDataPart(name, "$name.jpg", bytes.toRequestBody("image/jpeg".toMediaType()))
                }
                video?.let { addFormDataPart("film_h264", "preview.mp4", it.asRequestBody("video/mp4".toMediaType())) }
            }.build()
        uploadMultipart(capability, multipart)
    }

    internal suspend fun uploadFace(capability: ApiCapability, faceId: Long, jpeg: ByteArray): Boolean = withContext(Dispatchers.IO) {
        require(capability.name in setOf("SYNO.Foto.Upload.Face", "SYNO.FotoTeam.Upload.Face") &&
            1 in capability.minVersion..capability.maxVersion && capability.requestFormat.equals("JSON", true) && faceId > 0)
        require(jpeg.size >= 3 && jpeg[0] == 0xff.toByte() && jpeg[1] == 0xd8.toByte() && jpeg[2] == 0xff.toByte())
        val multipart = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("api", capability.name).addFormDataPart("version", "1")
            .addFormDataPart("method", "upload").addFormDataPart("face_id", faceId.toString())
            .addFormDataPart("file", "face.jpg", jpeg.toRequestBody("image/jpeg".toMediaType())).build()
        uploadMultipart(capability, multipart)
    }

    private suspend fun uploadMultipart(capability: ApiCapability, multipart: MultipartBody): Boolean {
        val upload = request(photoApiPath(capability.path), emptyMap(), "application/json")
            .newBuilder().post(OneShotRequestBody(multipart)).build()
        return withResponse(upload) { response ->
            if (response.code in setOf(401, 403)) { onAccessFailure(); fail(SynologyPhotoFailureKind.PERMISSION) }
            if (!response.isSuccessful || response.body == null) fail(SynologyPhotoFailureKind.INVALID_RESPONSE)
            val source = response.body!!.source()
            source.request(65_537)
            if (source.buffer.size > 65_536) fail(SynologyPhotoFailureKind.INVALID_RESPONSE)
            val bytes = source.buffer.readByteArray()
            val envelope = try { Json.parseToJsonElement(bytes.decodeToString()) as? JsonObject } catch (_: Exception) { null }
                ?: fail(SynologyPhotoFailureKind.INVALID_RESPONSE)
            val success = (envelope["success"] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull
                ?: fail(SynologyPhotoFailureKind.INVALID_RESPONSE)
            if (success) {
                if (envelope.containsKey("error")) fail(SynologyPhotoFailureKind.INVALID_RESPONSE)
                true
            } else {
                val code = ((envelope["error"] as? JsonObject)?.get("code") as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull
                    ?: fail(SynologyPhotoFailureKind.INVALID_RESPONSE)
                val failure = dsmApiFailure(code)
                if (failure.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED)) {
                    onAccessFailure(); throw failure
                }
                false
            }
        }
    }

    suspend fun thumbnail(thumbnail: SynologyPhotoThumbnail, large: Boolean,
        space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL, albumId: Long? = null,
    ): ByteArray = thumbnail(thumbnail, if (large) "xl" else "m", space, albumId)

    internal suspend fun previewThumbnail(unitId: Long, size: String, space: SynologyPhotoSpace): ByteArray =
        thumbnail(SynologyPhotoThumbnail(unitId, ""), size, space, null)

    private suspend fun thumbnail(thumbnail: SynologyPhotoThumbnail, size: String,
        space: SynologyPhotoSpace, albumId: Long?): ByteArray = withContext(Dispatchers.IO) {
        require(thumbnail.unitId > 0)
        require(albumId == null || albumId > 0)
        require(size in setOf("xl", "sm", "m"))
        val namespace = if (space == SynologyPhotoSpace.SHARED && albumId == null) "t" else "p"
        val request = request("/synofoto/api/v2/$namespace/Thumbnail/get", mapOf(
            "id" to thumbnail.unitId.toString(),
            "cache_key" to JsonPrimitive(thumbnail.revision).toString(),
            "type" to JsonPrimitive("unit").toString(),
            "size" to JsonPrimitive(size).toString(),
        ) + (albumId?.let { mapOf("album_id" to it.toString()) } ?: emptyMap()), "image/*")
        image(request.newBuilder().cacheControl(okhttp3.CacheControl.FORCE_NETWORK).build())
    }

    suspend fun personThumbnail(cover: SynologyPhotoPersonCover, space: SynologyPhotoSpace): ByteArray = withContext(Dispatchers.IO) {
        require(cover.id > 0)
        val namespace = if (space == SynologyPhotoSpace.SHARED) "t" else "p"
        image(request("/synofoto/api/v2/$namespace/Thumbnail/get", mapOf(
            "id" to cover.id.toString(), "cache_key" to JsonPrimitive(cover.revision).toString(),
            "type" to JsonPrimitive(cover.type.value).toString(),
        ), "image/*"))
    }

    suspend fun faceThumbnail(face: SynologyPhotoPersonFace): ByteArray = withContext(Dispatchers.IO) {
        require(face.id > 0 && face.revision != null)
        val namespace = if (face.photoId.space == SynologyPhotoSpace.SHARED) "t" else "p"
        image(request("/synofoto/api/v2/$namespace/Thumbnail/get", mapOf(
            "id" to face.id.toString(), "cache_key" to JsonPrimitive(face.revision).toString(), "type" to JsonPrimitive("face").toString(),
        ), "image/*"))
    }

    suspend fun folderThumbnail(id: Long, cover: SynologyPhotoFolderCover, space: SynologyPhotoSpace): ByteArray = withContext(Dispatchers.IO) {
        require(id > 0)
        val sequence = cover.sequence
        if (sequence == null) return@withContext thumbnail(SynologyPhotoThumbnail(cover.unitId?.takeIf { it > 0 } ?: fail(), cover.revision), false, space)
        require(sequence >= 0)
        val namespace = if (space == SynologyPhotoSpace.SHARED) "t" else "p"
        image(request("/synofoto/api/v2/$namespace/Thumbnail/get", mapOf(
            "id" to id.toString(), "cache_key" to JsonPrimitive(cover.revision).toString(),
            "type" to JsonPrimitive("folder").toString(), "folder_cover_seq" to sequence.toString(),
        ), "image/*"))
    }

    private suspend fun image(request: Request): ByteArray =
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

    suspend fun download(
        capability: ApiCapability, parameters: Map<String, String>, destination: File, expectedBytes: Long,
        beforeCommit: suspend () -> Unit = {}, progress: (Long, Long) -> Unit,
    ) {
        require(expectedBytes >= 0)
        transfer(apiRequest(capability, "download", parameters), destination, expectedBytes, false, beforeCommit, progress) { _, _ -> Unit }
    }

    /** 自动预览按真实单元下载；实况子单元大小不能由整个Item大小推算。 */
    internal suspend fun downloadPreviewUnit(capability: ApiCapability, unitId: Long, destination: File,
        beforeCommit: suspend () -> Unit,
    ) {
        require(capability.name in setOf("SYNO.Foto.Download", "SYNO.FotoTeam.Download") && unitId > 0)
        transfer(apiRequest(capability, "download", mapOf("unit_id" to "[$unitId]")), destination,
            null, false, beforeCommit, { _, _ -> }) { file, _ -> if (file.length() <= 0) fail() }
    }

    internal suspend fun downloadConvertedPreview(capability: ApiCapability, unitId: Long, destination: File,
        beforeCommit: suspend () -> Unit) {
        require(capability.name in setOf("SYNO.Foto.Streaming", "SYNO.FotoTeam.Streaming") && unitId > 0)
        transfer(apiRequest(capability, "streaming", mapOf("id" to unitId.toString(), "type" to JsonPrimitive("unit").toString(),
            "quality" to JsonPrimitive("orig_h264").toString(), "use_mov" to "true"))
            .newBuilder().cacheControl(okhttp3.CacheControl.FORCE_NETWORK).build(), destination,
            null, false, beforeCommit, { _, _ -> }) { file, _ -> if (file.length() <= 0) fail() }
    }

    suspend fun downloadPhoto(
        capability: ApiCapability, parameters: Map<String, String>, destination: File, originalBytes: Long,
        format: SynologyPhotoDownloadFormat, post: Boolean = false,
        beforeCommit: suspend () -> Unit = {}, progress: (Long, Long) -> Unit,
    ): SynologyPhotoDownloadFormat {
        require(originalBytes >= 0)
        return transfer(apiRequest(capability, "download", parameters, post), destination,
            originalBytes.takeIf { format == SynologyPhotoDownloadFormat.ORIGINAL }, false, beforeCommit, progress) { file, type ->
            if (format == SynologyPhotoDownloadFormat.ORIGINAL) format
            else {
                if (file.length() <= 0) fail()
                val header = ByteArray(minOf(file.length(), 3L).toInt())
                java.io.DataInputStream(file.inputStream()).use { it.readFully(header) }
                if (header.contentEquals(byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte()))) {
                    validateJPEG(file)
                    format
                } else {
                    if (format != SynologyPhotoDownloadFormat.OPTIMIZED_JPEG || type.contains("jpeg") || file.length() != originalBytes) fail()
                    SynologyPhotoDownloadFormat.ORIGINAL
                }
            }
        }
    }

    suspend fun downloadArchive(
        capability: ApiCapability, parameters: Map<String, String>, destination: File,
        beforeCommit: suspend () -> Unit = {}, progress: (Long, Long) -> Unit,
    ) = transfer(apiRequest(capability, "download", parameters, post = true), destination, null, true, beforeCommit, progress) { file, _ ->
        SynologyPhotoExportValidation.archive(file)
    }

    /** 所有导出共享有界流与无覆盖提升；先验证完整文件再交给系统文档提供器。 */
    private suspend fun <T> transfer(
        request: Request, destination: File, expectedBytes: Long?, archive: Boolean,
        beforeCommit: suspend () -> Unit, progress: (Long, Long) -> Unit, validateFile: (File, String) -> T,
    ): T = withContext(Dispatchers.IO) {
        if (destination.exists()) throw java.nio.file.FileAlreadyExistsException(destination.name)
        val parent = destination.absoluteFile.parentFile ?: fail()
        val staging = File(parent, ".${UUID.randomUUID()}.photos-download")
        check(staging.createNewFile())
        try {
            withResponse(request) { response ->
                validate(response, 200, archive = archive)
                val declared = response.body!!.contentLength()
                if (expectedBytes != null && declared >= 0 && declared != expectedBytes) fail(SynologyPhotoFailureKind.LENGTH_MISMATCH)
                val total = expectedBytes ?: declared
                var done = 0L
                var lastProgress = 0L
                response.body!!.byteStream().buffered().use { input ->
                    input.mark(512)
                    val prefix = ByteArray(512)
                    var prefixCount = 0
                    while (prefixCount < prefix.size) {
                        currentCoroutineContext().ensureActive()
                        val count = input.read(prefix, prefixCount, prefix.size - prefixCount)
                        if (count < 0) break
                        prefixCount += count
                    }
                    val header = prefix.decodeToString(0, prefixCount).trimStart { it.isWhitespace() || it == '\uFEFF' }
                    if (header.startsWith("{") || header.startsWith("[") || header.startsWith("<") ||
                        (!archive && prefixCount >= 4 && prefix[0] == 0x50.toByte() && prefix[1] == 0x4b.toByte() &&
                            ((prefix[2] == 3.toByte() && prefix[3] == 4.toByte()) || (prefix[2] == 5.toByte() && prefix[3] == 6.toByte()) ||
                                (prefix[2] == 6.toByte() && prefix[3] == 6.toByte())))) fail()
                    input.reset()
                    staging.outputStream().buffered().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (total >= 0 && count.toLong() > total - done) fail(SynologyPhotoFailureKind.LENGTH_MISMATCH)
                            output.write(buffer, 0, count)
                            done += count
                            val now = System.nanoTime()
                            if (now - lastProgress >= 100_000_000L || done == total) {
                                progress(done, total); lastProgress = now
                            }
                        }
                    }
                }
                if (total >= 0 && done != total) fail(SynologyPhotoFailureKind.LENGTH_MISMATCH)
                val result = validateFile(staging, response.header("Content-Type").orEmpty().lowercase(java.util.Locale.ROOT))
                currentCoroutineContext().ensureActive()
                beforeCommit()
                currentCoroutineContext().ensureActive()
                // 只清理本次随机暂存文件，不删除或覆盖既有目标。
                Files.move(staging.toPath(), destination.toPath())
                progress(done, if (total >= 0) total else done)
                result
            }
        } finally { staging.delete() }
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

    private fun apiRequest(capability: ApiCapability, method: String, parameters: Map<String, String>, post: Boolean = false): Request {
        require(capability.name in setOf("SYNO.Foto.Download", "SYNO.Foto.Streaming", "SYNO.FotoTeam.Download", "SYNO.FotoTeam.Streaming", "SYNO.Foto.Browse.Album"))
        require(capability.minVersion <= 2 && capability.maxVersion >= 2 && capability.requestFormat.equals("JSON", true))
        require(((capability.name.endsWith(".Download") || capability.name == "SYNO.Foto.Browse.Album" && post) && method == "download") ||
            (capability.name.endsWith(".Streaming") && method == "streaming"))
        require(parameters.keys.none { it.lowercase() in setOf("api", "version", "method", "_sid", "sid", "synotoken", "cookie", "did") })
        return request(photoApiPath(capability.path), mapOf(
            "api" to capability.name, "version" to "2", "method" to method,
        ) + parameters, post = post)
    }

    private fun request(path: String, parameters: Map<String, String>, accept: String = "application/octet-stream, video/*", post: Boolean = false): Request {
        val base = endpoint.toHttpUrl()
        val url = "$endpoint$path".toHttpUrl().newBuilder().apply {
            if (!post) parameters.forEach { (name, value) -> addQueryParameter(name, value) }
        }.build()
        require(url.scheme == base.scheme && url.host == base.host && url.port == base.port)
        require(post || "passphrase" !in parameters)
        return Request.Builder().url(url).apply {
            if (post) post(okhttp3.FormBody.Builder().apply { parameters.forEach { (name, value) -> add(name, value) } }.build()) else get()
        }.header("Accept", accept)
            .header("User-Agent", "LanStash-Android/0.1")
            .header("Cookie", "id=${session.sid}")
            .apply { session.synoToken?.takeIf { it.isNotBlank() }?.let { header("X-SYNO-TOKEN", it) } }
            .build()
    }

    private suspend fun <T> withResponse(request: Request, body: suspend (Response) -> T): T = coroutineScope {
        authorizeRequest()
        val call = http.newCall(request)
        // 收到响应头后仍保持取消关联；阻塞中的响应体读取必须立即随页面/账号取消。
        val cancellation = launch(start = CoroutineStart.UNDISPATCHED) {
            try { awaitCancellation() } finally { call.cancel() }
        }
        try {
            await(call).use { body(it) }
        } catch (error: IOException) {
            // 取消会关闭正在读取的套接字；保留协程取消语义，不能把它升级为父任务失败。
            currentCoroutineContext().ensureActive()
            throw SynologyPhotoFailure(SynologyPhotoFailureKind.MEDIA, error)
        } finally {
            cancellation.cancel()
        }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private suspend fun await(call: Call): Response = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, error: IOException) {
                if (!continuation.isCancelled) continuation.resumeWithException(
                    if (error is LocalNetworkPermissionException) localNetworkPermissionFailure()
                    else SynologyPhotoFailure(SynologyPhotoFailureKind.MEDIA, error))
            }
            override fun onResponse(call: Call, response: Response) {
                continuation.resume(response) { response.close() }
            }
        })
    }

    private fun validate(response: Response, status: Int, imageOnly: Boolean = false, archive: Boolean = false) {
        if (response.code == 401 || response.code == 403) {
            onAccessFailure()
            fail(SynologyPhotoFailureKind.PERMISSION)
        }
        if (response.code != status || response.body == null) fail()
        val type = response.header("Content-Type").orEmpty().lowercase()
        if (type.contains("json") || type.contains("html") || !archive && type.contains("zip") ||
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
            authorizeRequest()
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
            authorizeRequest()
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

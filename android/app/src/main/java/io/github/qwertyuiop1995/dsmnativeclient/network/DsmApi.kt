package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import java.io.IOException
import java.io.InputStream
import java.io.File
import java.io.OutputStream
import java.net.URI
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Call
import okhttp3.Callback
import okhttp3.FormBody
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.BufferedSink

/**
 * DSM WebAPI 的统一传输层。请求正文、SID、令牌和用户数据不会写入日志。
 */
class DsmApiClient(
    private val http: OkHttpClient = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        // 写请求结果未知时必须先回读，不能由传输层自动重放。
        .retryOnConnectionFailure(false)
        .build(),
    private val json: Json = Json { ignoreUnknownKeys = true },
) {
    internal fun openWebSocket(request: Request, listener: WebSocketListener): WebSocket =
        http.newWebSocket(request, listener)

    fun endpoint(profile: NasProfile): String {
        val raw = profile.address.trim()
        if (raw.endsWith("://")) {
            throw DsmFailure(
                null,
                "NAS host is missing",
                "Enter a complete NAS address.",
                kind = DsmErrorKind.INVALID_ADDRESS,
            )
        }
        val uri = runCatching {
            URI(if ("://" in raw) raw else "https://$raw")
        }.getOrElse {
            throw DsmFailure(
                null,
                "NAS address is invalid",
                "Check the address and try again.",
                kind = DsmErrorKind.INVALID_ADDRESS,
            )
        }
        val scheme = uri.scheme?.lowercase()
        if (scheme != "https" && !(BuildPolicy.allowCleartext && scheme == "http")) {
            throw DsmFailure(
                null,
                "Only HTTPS connections are supported",
                "Use the HTTPS address of the NAS.",
                kind = DsmErrorKind.INSECURE_ADDRESS,
            )
        }
        val host = uri.host?.takeIf { it.isNotBlank() }
            ?: throw DsmFailure(
                null,
                "NAS host is missing",
                "Enter a complete NAS address.",
                kind = DsmErrorKind.INVALID_ADDRESS,
            )
        val port = profile.port ?: if (uri.port > 0) uri.port else -1
        val authority = if (port > 0) "$host:$port" else host
        val basePath = uri.path?.trimEnd('/').orEmpty()
        return "$scheme://$authority$basePath"
    }

    /** 复用当前连接的证书校验与禁止重定向策略，不把凭据交给系统播放器。 */
    fun photosMedia(profile: NasProfile, session: DsmSession): SynologyPhotosMediaTransport =
        SynologyPhotosMediaTransport(profile, session, endpoint(profile), http)

    suspend fun discover(profile: NasProfile): Map<String, ApiCapability> {
        val result = post(
            profile = profile,
            path = "/webapi/query.cgi",
            parameters = mapOf(
                "api" to "SYNO.API.Info",
                "version" to "1",
                "method" to "query",
                "query" to "all",
            ),
        )
        val data = requireSuccess(result)
        return data.entries.mapNotNull { (name, element) ->
            val value = element as? JsonObject ?: return@mapNotNull null
            val path = value.string("path") ?: return@mapNotNull null
            val min = value.int("minVersion") ?: 1
            val max = value.int("maxVersion") ?: min
            name to ApiCapability(name, path, min, max, value.string("requestFormat").orEmpty())
        }.toMap()
    }

    suspend fun login(
        profile: NasProfile,
        password: String,
        otp: String? = null,
        deviceName: String = "LanStash Android",
        deviceId: String? = null,
    ): DsmSession {
        val parameters = buildMap {
            put("api", "SYNO.API.Auth")
            put("version", "7")
            put("method", "login")
            put("account", profile.username)
            put("passwd", password)
            put("session", "FileStation")
            put("format", "sid")
            put("enable_syno_token", "yes")
            put("enable_device_token", "yes")
            put("device_name", deviceName)
            otp?.takeIf { it.isNotBlank() }?.let { put("otp_code", it) }
            deviceId?.takeIf { it.isNotBlank() }?.let { put("device_id", it) }
        }
        val result = post(profile, "/webapi/auth.cgi", parameters)
        val data = requireSuccess(result)
        val sid = data.string("sid")
            ?: throw DsmFailure(
                null,
                "The NAS did not return a session",
                "Sign in again.",
                true,
                DsmErrorKind.SESSION_EXPIRED,
            )
        return DsmSession(
            profileId = profile.id,
            sid = sid,
            synoToken = data.string("synotoken"),
            deviceId = data.string("did") ?: deviceId,
        )
    }

    suspend fun logout(profile: NasProfile, session: DsmSession) {
        runCatching {
            post(
                profile,
                "/webapi/auth.cgi",
                mapOf(
                    "api" to "SYNO.API.Auth",
                    "version" to "7",
                    "method" to "logout",
                    "session" to "FileStation",
                ),
                session,
            )
        }
    }

    suspend fun call(
        profile: NasProfile,
        session: DsmSession,
        capability: ApiCapability,
        method: String,
        parameters: Map<String, String> = emptyMap(),
    ): JsonObject {
        val requestParameters = buildMap {
            put("api", capability.name)
            put("version", capability.maxVersion.toString())
            put("method", method)
            putAll(parameters)
        }
        val path = if (capability.path.startsWith("/")) capability.path else "/webapi/${capability.path}"
        return requireSuccess(post(profile, path, requestParameters, session))
    }

    suspend fun upload(
        profile: NasProfile,
        session: DsmSession,
        capability: ApiCapability,
        destinationPath: String,
        filename: String,
        contentType: String?,
        contentLength: Long,
        overwrite: Boolean,
        openInputStream: () -> InputStream,
        onProgress: (Long, Long) -> Unit,
    ): JsonObject = withContext(Dispatchers.IO) {
        require(contentLength >= 0) { "Upload content length is required" }
        val resolvedVersion = capability.version(2)
        val requestBody = InputStreamRequestBody(
            contentType = contentType,
            contentLength = contentLength,
            openInputStream = openInputStream,
            onProgress = onProgress,
        )
        val multipart = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("api", capability.name)
            .addFormDataPart("version", resolvedVersion.toString())
            .addFormDataPart("method", "upload")
            .addFormDataPart("_sid", session.sid)
            .addFormDataPart("path", destinationPath)
            .addFormDataPart("create_parents", "false")
            .addFormDataPart("overwrite", overwrite.toString())
            .apply {
                session.synoToken?.takeIf { it.isNotBlank() }?.let {
                    addFormDataPart("SynoToken", it)
                    addFormDataPart("synotoken", it)
                }
            }
            // DSM 要求文件二进制部分位于 multipart 正文末尾。
            .addFormDataPart("file", filename, requestBody)
            .build()
        val relativePath = if (capability.path.startsWith('/')) {
            capability.path
        } else {
            "/webapi/${capability.path}"
        }
        val requestUrl = "${endpoint(profile)}$relativePath".toHttpUrl().newBuilder()
            .addQueryParameter("api", capability.name)
            .addQueryParameter("version", resolvedVersion.toString())
            .addQueryParameter("method", "upload")
            .addQueryParameter("_sid", session.sid)
            .apply {
                session.synoToken?.takeIf { it.isNotBlank() }?.let {
                    addQueryParameter("SynoToken", it)
                    addQueryParameter("synotoken", it)
                }
            }
            .build()
        val multipartLength = multipart.contentLength()
        if (multipartLength < 0) {
            throw DsmFailure(
                null,
                "The upload size could not be prepared",
                "Choose the file again and retry.",
                kind = DsmErrorKind.UPLOAD_LENGTH_MISMATCH,
            )
        }
        val request = Request.Builder()
            .url(requestUrl)
            .post(multipart)
            .header("Content-Length", multipartLength.toString())
            .header("Accept", "application/json")
            .header("User-Agent", "LanStash-Android/0.1")
            .header("Cookie", "id=${session.sid}")
            .apply {
                session.synoToken?.takeIf { it.isNotBlank() }?.let {
                    header("X-SYNO-TOKEN", it)
                }
            }
            .build()
        http.newCall(request).await().use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw DsmFailure(
                    response.code,
                    "Could not upload the file",
                    "Check the connection and try again.",
                    kind = DsmErrorKind.CONNECTION_FAILED,
                )
            }
            requireSuccess(
                runCatching { json.parseToJsonElement(text).jsonObject }
                    .getOrElse {
                        throw DsmFailure(
                            null,
                            "The NAS returned an unrecognized upload response",
                            "Refresh the folder and check whether the file was uploaded.",
                            kind = DsmErrorKind.INVALID_RESPONSE,
                        )
                    },
            )
        }
    }

    suspend fun uploadDownloadTaskFile(
        profile: NasProfile,
        session: DsmSession,
        capability: ApiCapability,
        filename: String,
        contentType: String?,
        contentLength: Long,
        destination: String?,
        unzipPassword: String?,
        openInputStream: () -> InputStream,
    ): JsonObject = withContext(Dispatchers.IO) {
        require(contentLength in 0..MAX_DOWNLOAD_TASK_FILE_BYTES)
        val safeFilename = filename.replace(Regex("[\\r\\n\"]"), "_")
        val multipart = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .apply {
                addFormDataPart("_sid", session.sid)
                session.synoToken?.takeIf(String::isNotBlank)?.let {
                    addFormDataPart("SynoToken", it)
                    addFormDataPart("synotoken", it)
                }
                destination?.takeIf(String::isNotBlank)?.let {
                    addFormDataPart("destination", it)
                }
                unzipPassword?.takeIf(String::isNotBlank)?.let {
                    addFormDataPart("unzip_password", it)
                }
            }
            .addFormDataPart(
                "file",
                safeFilename,
                InputStreamRequestBody(
                    contentType = contentType,
                    contentLength = contentLength,
                    openInputStream = openInputStream,
                    onProgress = { _, _ -> },
                ),
            )
            .build()
        val path = if (capability.path.startsWith('/')) {
            capability.path
        } else {
            "/webapi/${capability.path}"
        }
        val url = "${endpoint(profile)}$path".toHttpUrl().newBuilder()
            .addQueryParameter("api", capability.name)
            .addQueryParameter("version", capability.maxVersion.toString())
            .addQueryParameter("method", "create")
            .build()
        val request = Request.Builder()
            .url(url)
            .post(multipart)
            .header("Cookie", "id=${session.sid}")
            .apply {
                session.synoToken?.takeIf(String::isNotBlank)?.let {
                    header("X-SYNO-TOKEN", it)
                }
            }
            .build()
        http.newCall(request).await().use { response ->
            val text = response.body?.string() ?: throw invalidBinaryResponse()
            val envelope = runCatching { json.parseToJsonElement(text).jsonObject }
                .getOrElse { throw invalidBinaryResponse() }
            requireSuccess(envelope)
        }
    }

    suspend fun uploadChatAttachment(
        profile: NasProfile,
        session: DsmSession,
        capability: ApiCapability,
        conversationId: String,
        message: String,
        filename: String,
        contentType: String?,
        contentLength: Long,
        openInputStream: () -> InputStream,
        onProgress: (Long, Long) -> Unit,
    ): JsonObject = withContext(Dispatchers.IO) {
        require(contentLength >= 0)
        val version = 5
        if (version !in capability.minVersion..capability.maxVersion) throw DsmFailure(
            103,
            "Chat attachments are unavailable",
            "Update Synology Chat or use Chat in a browser.",
            kind = DsmErrorKind.FEATURE_UNSUPPORTED,
        )
        val safeFilename = filename.replace(Regex("[\\r\\n\"]"), "_")
        val multipart = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("api", capability.name)
            .addFormDataPart("version", version.toString())
            .addFormDataPart("method", "create")
            .addFormDataPart("channel_id", conversationId)
            .addFormDataPart("type", "file")
            .addFormDataPart("message", message)
            .addFormDataPart("is_thread", "false")
            .addFormDataPart("_sid", session.sid)
            .apply {
                session.synoToken?.takeIf(String::isNotBlank)?.let {
                    addFormDataPart("SynoToken", it)
                    addFormDataPart("synotoken", it)
                }
            }
            .addFormDataPart(
                "file",
                safeFilename,
                InputStreamRequestBody(contentType, contentLength, openInputStream, onProgress),
            )
            .build()
        val path = if (capability.path.startsWith('/')) capability.path else "/webapi/${capability.path}"
        val url = "${endpoint(profile)}$path".toHttpUrl().newBuilder()
            .addQueryParameter("api", capability.name)
            .addQueryParameter("version", version.toString())
            .addQueryParameter("method", "create")
            .build()
        val multipartLength = multipart.contentLength()
        if (multipartLength < 0) throw DsmFailure(
            null,
            "The attachment size could not be prepared",
            "Choose the file again and retry.",
            kind = DsmErrorKind.UPLOAD_LENGTH_MISMATCH,
        )
        val request = Request.Builder()
            .url(url)
            .post(multipart)
            .header("Content-Length", multipartLength.toString())
            .header("Accept", "application/json")
            .header("User-Agent", "LanStash-Android/0.1")
            .header("Cookie", "id=${session.sid}")
            .apply {
                session.synoToken?.takeIf(String::isNotBlank)?.let { header("X-SYNO-TOKEN", it) }
            }
            .build()
        http.newCall(request).await().use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw DsmFailure(
                response.code,
                "The attachment could not be uploaded",
                "Check the connection and try again.",
                kind = DsmErrorKind.CONNECTION_FAILED,
            )
            requireSuccess(
                runCatching { json.parseToJsonElement(text).jsonObject }
                    .getOrElse { throw invalidBinaryResponse() },
            )
        }
    }

    suspend fun readBinary(
        profile: NasProfile,
        session: DsmSession,
        capability: ApiCapability,
        preferredVersion: Int,
        method: String,
        parameters: Map<String, String>,
        maximumBytes: Long,
        range: LongRange? = null,
    ): ByteArray = withContext(Dispatchers.IO) {
        require(maximumBytes in 1..MAX_BINARY_RESPONSE_BYTES)
        val request = binaryRequest(
            profile = profile,
            session = session,
            capability = capability,
            preferredVersion = preferredVersion,
            method = method,
            parameters = parameters,
            range = range,
        )
        http.newCall(request).await().use { response ->
            val rangeBytes = validateBinaryResponse(response, maximumBytes, range)
            val body = response.body ?: throw invalidBinaryResponse()
            body.contentLength().takeIf { it >= 0 }?.let { length ->
                if (length > maximumBytes) throw binaryTooLarge()
                if (rangeBytes != null && length != rangeBytes) throw invalidBinaryResponse()
            }
            val output = java.io.ByteArrayOutputStream()
            var total = 0L
            body.byteStream().use { input ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    val nextTotal = total + count
                    if (nextTotal > maximumBytes) throw binaryTooLarge()
                    if (rangeBytes != null && nextTotal > rangeBytes) {
                        throw invalidBinaryResponse()
                    }
                    output.write(buffer, 0, count)
                    total = nextTotal
                }
            }
            if (rangeBytes != null && total != rangeBytes) throw invalidBinaryResponse()
            output.toByteArray()
        }
    }

    suspend fun downloadBinaryToFile(
        profile: NasProfile,
        session: DsmSession,
        capability: ApiCapability,
        preferredVersion: Int,
        method: String,
        parameters: Map<String, String>,
        destination: File,
        expectedBytes: Long?,
        maximumBytes: Long,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
    ): Long {
        try {
            destination.parentFile?.mkdirs()
            return destination.outputStream().buffered().use { output ->
                downloadBinaryToOutput(
                    profile = profile,
                    session = session,
                    capability = capability,
                    preferredVersion = preferredVersion,
                    method = method,
                    parameters = parameters,
                    output = output,
                    expectedBytes = expectedBytes,
                    maximumBytes = maximumBytes,
                    onProgress = onProgress,
                )
            }
        } catch (error: Throwable) {
            destination.delete()
            throw error
        }
    }

    suspend fun downloadBinaryToOutput(
        profile: NasProfile,
        session: DsmSession,
        capability: ApiCapability,
        preferredVersion: Int,
        method: String,
        parameters: Map<String, String>,
        output: OutputStream,
        expectedBytes: Long?,
        maximumBytes: Long? = null,
        range: LongRange? = null,
        initialBytes: Long = 0,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
    ): Long = withContext(Dispatchers.IO) {
        maximumBytes?.let { require(it in 1..MAX_STREAM_RESPONSE_BYTES) }
        require(initialBytes >= 0)
        expectedBytes?.takeIf { it >= 0 }?.let { expected ->
            if (maximumBytes != null && expected > maximumBytes) throw binaryTooLarge()
            if (initialBytes > expected) throw downloadLengthMismatch()
        }
        val request = binaryRequest(
            profile = profile,
            session = session,
            capability = capability,
            preferredVersion = preferredVersion,
            method = method,
            parameters = parameters,
            range = range,
        )
        http.newCall(request).await().use { response ->
            val rangeBytes = validateBinaryResponse(
                response,
                maximumBytes ?: MAX_ERROR_RESPONSE_BYTES,
                range = range,
                expectedBytes = expectedBytes,
            )
            val body = response.body ?: throw invalidBinaryResponse()
            val declared = body.contentLength().takeIf { it >= 0 }
            val remainingExpected = expectedBytes
                ?.takeIf { it >= 0 }
                ?.let { it - initialBytes }
            val responseLimit = remainingExpected ?: rangeBytes
            if (declared != null && responseLimit != null && declared != responseLimit) {
                throw binaryBodyLengthMismatch(expectedBytes)
            }
            if (maximumBytes != null && declared != null && declared > maximumBytes) {
                throw binaryTooLarge()
            }
            var total = 0L
            body.byteStream().use { input ->
                val buffer = ByteArray(STREAM_BUFFER_BYTES)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    val countBytes = count.toLong()
                    if (responseLimit != null &&
                        (total > responseLimit || countBytes > responseLimit - total)
                    ) {
                        throw binaryBodyLengthMismatch(expectedBytes)
                    }
                    if (maximumBytes != null &&
                        (total > maximumBytes || countBytes > maximumBytes - total)
                    ) {
                        throw binaryTooLarge()
                    }
                    val nextTotal = total + count
                    output.write(buffer, 0, count)
                    total = nextTotal
                    onProgress(initialBytes + total, expectedBytes ?: declared?.let { initialBytes + it })
                }
            }
            output.flush()
            if (rangeBytes != null && total != rangeBytes) {
                throw binaryBodyLengthMismatch(expectedBytes)
            }
            if (remainingExpected != null && total != remainingExpected) throw downloadLengthMismatch()
            initialBytes + total
        }
    }

    private fun binaryRequest(
        profile: NasProfile,
        session: DsmSession,
        capability: ApiCapability,
        preferredVersion: Int,
        method: String,
        parameters: Map<String, String>,
        range: LongRange?,
    ): Request {
        val relativePath = if (capability.path.startsWith('/')) {
            capability.path
        } else {
            "/webapi/${capability.path}"
        }
        val url = "${endpoint(profile)}$relativePath".toHttpUrl().newBuilder()
            .addQueryParameter("api", capability.name)
            .addQueryParameter("version", capability.version(preferredVersion).toString())
            .addQueryParameter("method", method)
            .apply {
                parameters.forEach(::addQueryParameter)
            }
            .build()
        return Request.Builder()
            .url(url)
            .get()
            .header("Accept", "application/octet-stream, image/*, application/pdf, text/plain")
            .header("User-Agent", "LanStash-Android/0.1")
            .header("Cookie", "id=${session.sid}")
            .apply {
                session.synoToken?.takeIf { it.isNotBlank() }?.let {
                    header("X-SYNO-TOKEN", it)
                }
                range?.let { header("Range", "bytes=${it.first}-${it.last}") }
            }
            .build()
    }

    private fun validateBinaryResponse(
        response: Response,
        maximumBytes: Long,
        range: LongRange?,
        expectedBytes: Long? = null,
    ): Long? {
        val contentType = response.header("Content-Type").orEmpty().lowercase()
        if (contentType.contains("application/json") || contentType.contains("text/html")) {
            val text = response.body?.source()?.let { source ->
                source.request(minOf(maximumBytes, 1_048_576L))
                source.buffer.clone().readUtf8(minOf(source.buffer.size, 1_048_576L))
            }.orEmpty()
            val envelope = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
            if (envelope != null) requireSuccess(envelope)
            throw invalidBinaryResponse()
        }
        if (range != null) {
            if (response.code != 206) throw invalidBinaryResponse()
            val contentRange = response.header("Content-Range")
                ?: throw invalidBinaryResponse()
            val match = CONTENT_RANGE_PATTERN.matchEntire(contentRange.trim())
                ?: throw invalidBinaryResponse()
            val start = match.groupValues[1].toLongOrNull() ?: throw invalidBinaryResponse()
            val end = match.groupValues[2].toLongOrNull() ?: throw invalidBinaryResponse()
            val totalToken = match.groupValues[3]
            val total = if (totalToken == "*") {
                null
            } else {
                totalToken.toLongOrNull() ?: throw invalidBinaryResponse()
            }
            if (start != range.first || end < start || end != range.last) {
                throw invalidBinaryResponse()
            }
            if (total != null && total <= end) throw invalidBinaryResponse()
            expectedBytes?.takeIf { it >= 0 }?.let { expected ->
                if (total != expected) throw invalidBinaryResponse()
            }
            val distance = end - start
            if (distance == Long.MAX_VALUE) throw invalidBinaryResponse()
            return distance + 1
        } else {
            if (response.code == 206 || response.header("Content-Range") != null) {
                throw invalidBinaryResponse()
            }
            if (!response.isSuccessful) {
                throw DsmFailure(
                    response.code,
                    "Could not read this file",
                    "Check the connection and try again.",
                    kind = DsmErrorKind.CONNECTION_FAILED,
                )
            }
        }
        return null
    }

    private fun binaryTooLarge() = DsmFailure(
        null,
        "This file is too large to preview safely",
        "Download the file or use DSM to open it.",
        kind = DsmErrorKind.PREVIEW_TOO_LARGE,
    )

    private fun invalidBinaryResponse() = DsmFailure(
        null,
        "The NAS returned an invalid preview response",
        "Close the preview and try again.",
        kind = DsmErrorKind.INVALID_RESPONSE,
    )

    private fun binaryBodyLengthMismatch(expectedBytes: Long?) =
        if (expectedBytes != null && expectedBytes >= 0) {
            downloadLengthMismatch()
        } else {
            invalidBinaryResponse()
        }

    private fun downloadLengthMismatch() = DsmFailure(
        null,
        "The downloaded file size did not match",
        "Delete the incomplete file and try again.",
        kind = DsmErrorKind.DOWNLOAD_LENGTH_MISMATCH,
    )

    suspend fun call(
        profile: NasProfile,
        session: DsmSession,
        api: String,
        version: Int,
        method: String,
        parameters: Map<String, String> = emptyMap(),
        path: String = "/webapi/entry.cgi",
    ): JsonObject {
        val requestParameters = buildMap {
            put("api", api)
            put("version", version.toString())
            put("method", method)
            putAll(parameters)
        }
        return requireSuccess(post(profile, path, requestParameters, session))
    }

    private suspend fun post(
        profile: NasProfile,
        path: String,
        parameters: Map<String, String>,
        session: DsmSession? = null,
    ): JsonObject = withContext(Dispatchers.IO) {
        val body = FormBody.Builder().apply {
            parameters.forEach { (key, value) -> add(key, value) }
            session?.sid?.let { add("_sid", it) }
            session?.synoToken?.takeIf { it.isNotBlank() }?.let { add("SynoToken", it) }
        }.build()
        val request = Request.Builder()
            .url("${endpoint(profile)}$path")
            .post(body)
            .header("Accept", "application/json")
            .header("User-Agent", "LanStash-Android/0.1")
            .apply {
                session?.sid?.let { header("Cookie", "id=$it") }
                session?.synoToken?.takeIf { it.isNotBlank() }?.let {
                    header("X-SYNO-TOKEN", it)
                }
            }
            .build()
        val response = http.newCall(request).await()
        response.use {
            val text = it.body?.string().orEmpty()
            if (!it.isSuccessful) {
                throw DsmFailure(
                    it.code,
                    "Could not connect to the NAS",
                    "Check the network, address, and certificate.",
                    it.code == 401 || it.code == 403,
                    DsmErrorKind.CONNECTION_FAILED,
                )
            }
            runCatching { json.parseToJsonElement(text).jsonObject }
                .getOrElse {
                    throw DsmFailure(
                        null,
                        "The NAS returned an unrecognized response",
                        "Make sure the address points to DSM and try again.",
                        kind = DsmErrorKind.INVALID_RESPONSE,
                    )
                }
        }
    }

    private fun requireSuccess(envelope: JsonObject): JsonObject {
        if (envelope["success"]?.jsonPrimitive?.booleanOrNull == true) {
            return when (val data = envelope["data"]) {
                is JsonObject -> data
                is kotlinx.serialization.json.JsonArray -> JsonObject(mapOf("_array" to data))
                else -> JsonObject(emptyMap())
            }
        }
        val code = (envelope["error"] as? JsonObject)?.int("code")
        throw mapFailure(code)
    }

    private fun mapFailure(code: Int?): DsmFailure = when (code) {
        101 -> DsmFailure(code, "DSM request failed", "Refresh and try again.", kind = DsmErrorKind.REQUEST_FAILED)
        102 -> DsmFailure(code, "Feature unsupported", "Update DSM or the related package.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
        103 -> DsmFailure(code, "Package version unsupported", "Update the package and try again.", kind = DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED)
        104 -> DsmFailure(code, "Session expired", "Sign in again.", true, DsmErrorKind.SESSION_EXPIRED)
        105 -> DsmFailure(code, "Permission denied", "Use an account with the required permission.", kind = DsmErrorKind.PERMISSION_DENIED)
        106, 107 -> DsmFailure(code, "Too many requests", "Try again later.", kind = DsmErrorKind.RATE_LIMITED)
        400, 401, 402, 403, 404 -> DsmFailure(code, "Sign-in information is incorrect", "Check the account, password, and verification code.", true, DsmErrorKind.AUTHENTICATION_FAILED)
        406 -> DsmFailure(code, "Two-factor code required", "Enter the current code from your authenticator.", true, DsmErrorKind.OTP_REQUIRED)
        407 -> DsmFailure(code, "Two-factor code is incorrect", "Use the latest code and try again.", true, DsmErrorKind.OTP_INVALID)
        408, 409 -> DsmFailure(code, "Device confirmation required", "Confirm the device in DSM and try again.", true, DsmErrorKind.DEVICE_CONFIRMATION_REQUIRED)
        108 -> DsmFailure(code, "The upload was not completed", "Choose the file again and retry.", kind = DsmErrorKind.UPLOAD_FAILED)
        115 -> DsmFailure(code, "The NAS did not allow this upload", "Check folder permissions and available space.", kind = DsmErrorKind.UPLOAD_NOT_ALLOWED)
        1800 -> DsmFailure(code, "The upload size could not be verified", "Choose the file again and retry.", kind = DsmErrorKind.UPLOAD_LENGTH_MISMATCH)
        1801, 1802, 1803, 1804, 1805 -> DsmFailure(code, "The NAS could not accept this file", "Check the file name, folder permissions, and available space.", kind = DsmErrorKind.UPLOAD_FAILED)
        else -> DsmFailure(code, "NAS operation failed", "Refresh and try again.", kind = DsmErrorKind.REQUEST_FAILED)
    }

    private suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { cancel() }
        enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isCancelled) return
                continuation.resumeWithException(
                    DsmFailure(
                        null,
                        "Could not connect to the NAS",
                        "Check the network connection and NAS address.",
                        kind = DsmErrorKind.CONNECTION_FAILED,
                    )
                )
            }

            override fun onResponse(call: Call, response: Response) {
                continuation.resume(response)
            }
        })
    }

    private object BuildPolicy {
        // Debug 也保持 HTTPS，避免测试配置意外进入正式行为。
        const val allowCleartext = false
    }

    private companion object {
        const val MAX_BINARY_RESPONSE_BYTES = 256L * 1024L * 1024L
        const val MAX_STREAM_RESPONSE_BYTES = 1024L * 1024L * 1024L * 1024L
        const val MAX_ERROR_RESPONSE_BYTES = 1024L * 1024L
        const val MAX_DOWNLOAD_TASK_FILE_BYTES = 100L * 1024L * 1024L
        const val STREAM_BUFFER_BYTES = 64 * 1024
        val CONTENT_RANGE_PATTERN = Regex("bytes\\s+(\\d+)-(\\d+)/(\\d+|\\*)", RegexOption.IGNORE_CASE)
    }
}

private class InputStreamRequestBody(
    contentType: String?,
    private val contentLength: Long,
    private val openInputStream: () -> InputStream,
    private val onProgress: (Long, Long) -> Unit,
) : RequestBody() {
    private val mediaType = contentType?.toMediaTypeOrNull()

    override fun contentType() = mediaType

    override fun contentLength() = contentLength

    // ContentResolver、跨 NAS 管道等上传源均不可倒带，禁止 OkHttp 自动重放正文。
    override fun isOneShot() = true

    override fun writeTo(sink: BufferedSink) {
        var completed = 0L
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        openInputStream().use { input ->
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                sink.write(buffer, 0, count)
                completed += count
                onProgress(completed, contentLength)
            }
        }
        if (completed != contentLength) {
            throw IOException("Upload source length changed")
        }
    }
}

internal fun JsonObject.string(key: String): String? =
    this[key]?.jsonPrimitive?.contentOrNull

internal fun JsonObject.int(key: String): Int? =
    this[key]?.jsonPrimitive?.intOrNull

internal fun JsonObject.long(key: String): Long? =
    this[key]?.jsonPrimitive?.contentOrNull?.toLongOrNull()

internal fun JsonObject.objectValue(key: String): JsonObject? =
    this[key] as? JsonObject

internal fun JsonObject.arrayValue(key: String): List<JsonElement> =
    (this[key] as? kotlinx.serialization.json.JsonArray)?.toList().orEmpty()

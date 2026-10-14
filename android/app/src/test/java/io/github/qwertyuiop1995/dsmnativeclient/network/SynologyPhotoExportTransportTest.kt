package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoExportTransportTest {
    @Test fun `压缩与原尺寸JPEG校验后返回实际格式且失败不提升`() = runBlocking {
        val directory = Files.createTempDirectory("export-jpeg-test-").toFile()
        try {
            val bytes = byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte(), 1, 2)
            var validations = 0
            val transport = transport(bytes, "image/jpeg", jpeg = { validations++; assertArrayEquals(bytes, it.readBytes()) })
            for (format in listOf(SynologyPhotoDownloadFormat.OPTIMIZED_JPEG, SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG))
                assertEquals(format, transport.downloadPhoto(api, parameters, File(directory, format.name), 88, format) { _, _ -> })
            assertEquals(2, validations)
            val rejecting = transport(bytes, "image/jpeg", jpeg = { throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE) })
            failure { rejecting.downloadPhoto(api, parameters, File(directory, "invalid"), 88, SynologyPhotoDownloadFormat.OPTIMIZED_JPEG) { _, _ -> } }
            assertFalse(File(directory, "invalid").exists()); assertEquals(2, directory.listFiles()!!.size)
        } finally { directory.deleteRecursively() }
    }

    @Test fun `压缩非JPEG只有原件长度且非JPEG类型才保留原格式`() = runBlocking {
        val directory = Files.createTempDirectory("export-retain-test-").toFile()
        try {
            val bytes = byteArrayOf(1, 2, 3, 4)
            for (format in SynologyPhotoDownloadFormat.entries) for (type in listOf("image/heic", "image/jpeg")) for (size in listOf(4L, 5L)) {
                val target = File(directory, "result")
                val transport = transport(bytes, type)
                val valid = size == 4L && (format == SynologyPhotoDownloadFormat.ORIGINAL || format == SynologyPhotoDownloadFormat.OPTIMIZED_JPEG && type == "image/heic")
                if (valid) { assertEquals(SynologyPhotoDownloadFormat.ORIGINAL, transport.downloadPhoto(api, parameters, target, size, format) { _, _ -> }); target.delete() }
                else failure { transport.downloadPhoto(api, parameters, target, size, format) { _, _ -> } }
                assertTrue(directory.listFiles()!!.isEmpty())
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun `ZIP完整结束记录含注释可接受而截断尾部伪前缀与错误页不能落盘`() = runBlocking {
        val directory = Files.createTempDirectory("export-zip-test-").toFile()
        try {
            val empty = byteArrayOf(0x50, 0x4b, 5, 6) + ByteArray(18)
            val comment = empty.copyOf().apply { this[20] = 3 } + byteArrayOf(1, 2, 3)
            for (bytes in listOf(empty, comment)) {
                transport(bytes, "application/zip").downloadArchive(api, parameters, File(directory, "valid")) { _, _ -> }
                assertArrayEquals(bytes, File(directory, "valid").readBytes()); File(directory, "valid").delete()
            }
            val invalid = listOf(empty.dropLast(1).toByteArray(), empty + byteArrayOf(1), comment.dropLast(1).toByteArray(), ByteArray(40),
                "{\"success\":false}".toByteArray(), "<html>login</html>".toByteArray(), byteArrayOf(0x50, 0x4b, 3, 4) + ByteArray(40))
            for (bytes in invalid) {
                failure { transport(bytes, "application/zip").downloadArchive(api, parameters, File(directory, "invalid")) { _, _ -> } }
                assertTrue(directory.listFiles()!!.isEmpty())
            }
            failure { transport(empty, "text/html").downloadArchive(api, parameters, File(directory, "mime")) { _, _ -> } }
        } finally { directory.deleteRecursively() }
    }

    @Test fun `JPEG下载拒绝所有ZIP首标识且未知长度有实际进度`() = runBlocking {
        val directory = Files.createTempDirectory("export-progress-test-").toFile()
        try {
            for (signature in listOf(byteArrayOf(0x50, 0x4b, 3, 4), byteArrayOf(0x50, 0x4b, 5, 6), byteArrayOf(0x50, 0x4b, 6, 6))) {
                failure { transport(signature, "image/heic").downloadPhoto(api, parameters, File(directory, "zip"), 4, SynologyPhotoDownloadFormat.OPTIMIZED_JPEG) { _, _ -> } }
            }
            val content = byteArrayOf(1, 2, 3, 4); val progress = mutableListOf<Pair<Long, Long>>()
            val transport = transport(content, "image/heic", declared = -1)
            transport.downloadPhoto(api, parameters, File(directory, "valid"), 4, SynologyPhotoDownloadFormat.OPTIMIZED_JPEG) { done, total -> progress += done to total }
            assertEquals(4L to 4L, progress.last()); assertTrue(progress.any { it.second == -1L })
            failure { transport(content, "image/heic", declared = 7).downloadPhoto(api, parameters, File(directory, "length"), 4, SynologyPhotoDownloadFormat.OPTIMIZED_JPEG) { _, _ -> } }
            assertFalse(File(directory, "length").exists())
        } finally { directory.deleteRecursively() }
    }

    @Test fun `归档只能POST且口令不进URL提升前取消与既有文件均保留`() = runBlocking {
        val directory = Files.createTempDirectory("export-post-test-").toFile()
        try {
            val bytes = byteArrayOf(0x50, 0x4b, 5, 6) + ByteArray(18)
            val requests = mutableListOf<Request>(); val transport = transport(bytes, "application/zip", inspect = { requests += it })
            val fields = parameters + ("passphrase" to "\"synthetic-passphrase\"")
            transport.downloadArchive(api.copy(name = "SYNO.Foto.Browse.Album"), fields, File(directory, "valid")) { _, _ -> }
            assertEquals("POST", requests.single().method); assertNull(requests.single().url.query)
            val target = File(directory, "existing").apply { writeText("keep") }
            try { transport.downloadArchive(api, fields, target) { _, _ -> }; fail() } catch (_: java.nio.file.FileAlreadyExistsException) { }
            assertEquals("keep", target.readText()); assertEquals(1, requests.size)
            try { transport.downloadArchive(api, fields, File(directory, "late"), beforeCommit = { throw CancellationException() }) { _, _ -> }; fail() } catch (_: CancellationException) { }
            assertFalse(File(directory, "late").exists()); assertEquals(2, directory.listFiles()!!.size)
            try { transport.downloadPhoto(api, fields, File(directory, "bad-get"), bytes.size.toLong(), SynologyPhotoDownloadFormat.ORIGINAL) { _, _ -> }; fail() } catch (_: IllegalArgumentException) { }
            assertEquals(2, requests.size)
        } finally { directory.deleteRecursively() }
    }

    private suspend fun failure(block: suspend () -> Any?) { try { block(); fail("应拒绝不完整导出") } catch (_: SynologyPhotoFailure) { } }
    private fun transport(bytes: ByteArray, type: String, declared: Long = bytes.size.toLong(), jpeg: (File) -> Unit = { error("不应解码非JPEG") }, inspect: (Request) -> Unit = {}) =
        SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic-session", "synthetic-token"), profile.address,
            OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); inspect(request)
                val body = bytes.toResponseBody(type.toMediaType())
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic").header("Content-Type", type)
                    .body(object : ResponseBody() { override fun contentType() = body.contentType(); override fun contentLength() = declared; override fun source() = body.source() }).build()
            }.build(), validateJPEG = jpeg)
    companion object {
        val profile = NasProfile("export-transport", "Synthetic", "https://nas.example.invalid", "tester")
        val api = ApiCapability("SYNO.Foto.Download", "entry.cgi", 1, 2, "JSON")
        val parameters = mapOf("item_id" to "[11]", "force_download" to "true", "download_type" to "\"optimized_jpeg\"")
    }
}

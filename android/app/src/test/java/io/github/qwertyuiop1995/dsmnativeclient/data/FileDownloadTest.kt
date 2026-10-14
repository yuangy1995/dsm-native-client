package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.canPauseDownload
import io.github.qwertyuiop1995.dsmnativeclient.canResumeDownload
import io.github.qwertyuiop1995.dsmnativeclient.downloadFailureKind
import io.github.qwertyuiop1995.dsmnativeclient.isCurrentDownloadExecution
import io.github.qwertyuiop1995.dsmnativeclient.ownsDownloadExecution
import io.github.qwertyuiop1995.dsmnativeclient.shouldDeleteCancelledDownload
import io.github.qwertyuiop1995.dsmnativeclient.shouldDeleteFailedDownload
import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.ByteArrayOutputStream
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FileDownloadTest {
    @Test
    fun `文件下载流式写入目标并报告最终进度`() = runBlocking {
        val bytes = "synthetic-download".encodeToByteArray()
        val transport = DownloadInterceptor(bytes)
        val output = ByteArrayOutputStream()
        val progress = mutableListOf<Pair<Long, Long?>>()

        val written = repository(transport).download(
            FileItem(
                path = "/share/synthetic.bin",
                name = "synthetic.bin",
                isDirectory = false,
                size = bytes.size.toLong(),
            ),
            output,
        ) { completed, total -> progress += completed to total }

        assertEquals(bytes.size.toLong(), written)
        assertTrue(bytes.contentEquals(output.toByteArray()))
        assertEquals(bytes.size.toLong() to bytes.size.toLong(), progress.last())
        val request = transport.requests.single()
        assertEquals("SYNO.FileStation.Download", request.url.queryParameter("api"))
        assertEquals("download", request.url.queryParameter("method"))
        assertEquals("[\"/share/synthetic.bin\"]", request.url.queryParameter("path"))
        assertTrue(request.url.queryParameter("_sid") == null)
        assertEquals("id=test-session", request.header("Cookie"))
    }

    @Test
    fun `文件夹下载不把目录列表大小误作ZIP大小`() = runBlocking {
        val zip = "synthetic-zip-stream".encodeToByteArray()
        val output = ByteArrayOutputStream()

        repository(DownloadInterceptor(zip)).download(
            FileItem(
                path = "/share/folder",
                name = "folder",
                isDirectory = true,
                size = 999,
            ),
            output,
        )

        assertTrue(zip.contentEquals(output.toByteArray()))
    }

    @Test
    fun `续传必须使用Range并验证内容范围后累计进度`() = runBlocking {
        val remaining = "download".encodeToByteArray()
        val transport = DownloadInterceptor(
            responseBytes = remaining,
            responseCode = 206,
            contentRange = "bytes 10-17/18",
        )
        val output = ByteArrayOutputStream()
        val progress = mutableListOf<Pair<Long, Long?>>()

        val written = repository(transport).download(
            FileItem("/share/file.bin", "file.bin", isDirectory = false, size = 18),
            output,
            resumeFrom = 10,
        ) { completed, total -> progress += completed to total }

        assertEquals(18L, written)
        assertEquals("bytes=10-17", transport.requests.single().header("Range"))
        assertEquals(18L to 18L, progress.last())
    }

    @Test
    fun `已知长度短响应保留已写片段并报告长度不一致`() = runBlocking {
        val partial = "short".encodeToByteArray()
        val output = ByteArrayOutputStream()
        val progress = mutableListOf<Long>()

        val failure = runCatching {
            repository(DownloadInterceptor(partial, unknownContentLength = true)).download(
                FileItem("/share/file.bin", "file.bin", isDirectory = false, size = 8),
                output,
            ) { completed, _ -> progress += completed }
        }.exceptionOrNull() as DsmFailure

        assertEquals(DsmErrorKind.DOWNLOAD_LENGTH_MISMATCH, failure.kind)
        assertTrue(partial.contentEquals(output.toByteArray()))
        assertTrue(progress.all { it <= 8 })
    }

    @Test
    fun `已知长度超长响应不会写入或报告超过预期的字节`() = runBlocking {
        val expected = 65_537
        val response = ByteArray(expected + 1) { (it % 251).toByte() }
        val output = ByteArrayOutputStream()
        val progress = mutableListOf<Long>()

        val failure = runCatching {
            repository(DownloadInterceptor(response, unknownContentLength = true)).download(
                FileItem(
                    "/share/file.bin",
                    "file.bin",
                    isDirectory = false,
                    size = expected.toLong(),
                ),
                output,
            ) { completed, _ -> progress += completed }
        }.exceptionOrNull() as DsmFailure

        assertEquals(DsmErrorKind.DOWNLOAD_LENGTH_MISMATCH, failure.kind)
        assertTrue(output.size().toLong() <= expected)
        assertTrue(progress.all { it <= expected })
    }

    @Test
    fun `续传拒绝错误的Content Range结束位置和总大小`() = runBlocking {
        listOf(
            "bytes 10-16/18",
            "bytes 10-17/19",
            "bytes 10-17/*",
        ).forEach { contentRange ->
            val failure = runCatching {
                repository(
                    DownloadInterceptor(
                        responseBytes = "download".encodeToByteArray(),
                        responseCode = 206,
                        contentRange = contentRange,
                    ),
                ).download(
                    FileItem("/share/file.bin", "file.bin", isDirectory = false, size = 18),
                    ByteArrayOutputStream(),
                    resumeFrom = 10,
                )
            }.exceptionOrNull() as DsmFailure

            assertEquals(DsmErrorKind.INVALID_RESPONSE, failure.kind)
        }
    }

    @Test
    fun `续传响应体短于或长于Content Range跨度均失败`() = runBlocking {
        listOf(7, 9).forEach { bodySize ->
            val output = ByteArrayOutputStream()
            val failure = runCatching {
                repository(
                    DownloadInterceptor(
                        responseBytes = ByteArray(bodySize),
                        responseCode = 206,
                        contentRange = "bytes 10-17/18",
                        unknownContentLength = true,
                    ),
                ).download(
                    FileItem("/share/file.bin", "file.bin", isDirectory = false, size = 18),
                    output,
                    resumeFrom = 10,
                )
            }.exceptionOrNull() as DsmFailure

            assertEquals(DsmErrorKind.DOWNLOAD_LENGTH_MISMATCH, failure.kind)
            assertTrue(output.size() <= 8)
        }
    }

    @Test
    fun `无读取权限时不会发出下载请求`() = runBlocking {
        val transport = DownloadInterceptor("unused".encodeToByteArray())

        val failure = runCatching {
            repository(transport).download(
                FileItem("/share/private", "private", isDirectory = false, canRead = false),
                ByteArrayOutputStream(),
            )
        }.exceptionOrNull() as DsmFailure

        assertEquals(DsmErrorKind.PERMISSION_DENIED, failure.kind)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `持久下载状态序列化不包含会话材料`() {
        val encoded = Json.encodeToString(
            PersistedDownload(
                id = "task-1",
                profileId = "profile-1",
                sourcePath = "/synthetic/source",
                title = "synthetic.bin",
                destinationUri = "content://synthetic/destination",
                isDirectory = false,
                expectedBytes = 17,
                state = TransferState.RUNNING,
                completedBytes = 8,
                workId = "00000000-0000-0000-0000-000000000001",
                backgroundCapable = true,
            ),
        )

        assertTrue(encoded.contains("task-1"))
        assertTrue(!encoded.contains("sid", ignoreCase = true))
        assertTrue(!encoded.contains("token", ignoreCase = true))
        assertTrue(!encoded.contains("password", ignoreCase = true))
        assertTrue(!encoded.contains("username", ignoreCase = true))
        assertTrue(!encoded.contains("address", ignoreCase = true))
    }

    @Test
    fun `仅未完成任务允许清理本次创建的目标`() {
        assertTrue(TransferState.WAITING.hasIncompleteDownloadDestination())
        assertTrue(TransferState.RUNNING.hasIncompleteDownloadDestination())
        assertTrue(TransferState.PAUSED.hasIncompleteDownloadDestination())
        assertTrue(TransferState.CANCELLING.hasIncompleteDownloadDestination())
        assertTrue(!TransferState.SUCCEEDED.hasIncompleteDownloadDestination())
        assertTrue(!TransferState.FAILED.hasIncompleteDownloadDestination())
        assertTrue(!TransferState.CANCELLED.hasIncompleteDownloadDestination())
    }

    @Test
    fun `普通文件仅在等待或运行时允许暂停且暂停后允许继续`() {
        val waiting = persistedDownload(state = TransferState.WAITING)
        val running = waiting.copy(state = TransferState.RUNNING)
        val paused = waiting.copy(state = TransferState.PAUSED)

        assertTrue(waiting.canPauseDownload())
        assertTrue(running.canPauseDownload())
        assertTrue(!paused.canPauseDownload())
        assertTrue(paused.canResumeDownload())
        assertTrue(!running.canResumeDownload())
    }

    @Test
    fun `目录下载不开放暂停或继续`() {
        val directory = persistedDownload(
            state = TransferState.RUNNING,
            isDirectory = true,
        )

        assertTrue(!directory.canPauseDownload())
        assertTrue(!directory.copy(state = TransferState.PAUSED).canResumeDownload())
    }

    @Test
    fun `旧执行标识不能拥有快速继续后的下载记录`() {
        val resumed = persistedDownload(
            state = TransferState.WAITING,
            workId = "new-execution",
        )

        assertTrue(resumed.ownsDownloadExecution("new-execution"))
        assertTrue(!resumed.ownsDownloadExecution("old-execution"))
        assertTrue("new-execution".isCurrentDownloadExecution("new-execution"))
        assertTrue(!"old-execution".isCurrentDownloadExecution("new-execution"))
        assertTrue(!null.isCurrentDownloadExecution("new-execution"))
    }

    @Test
    fun `取消回调仅能删除当前非暂停执行的片段`() {
        assertTrue(
            !shouldDeleteCancelledDownload(
                TransferState.PAUSED,
                currentExecutionId = "current",
                cancelledExecutionId = "current",
            ),
        )
        assertTrue(
            !shouldDeleteCancelledDownload(
                TransferState.RUNNING,
                currentExecutionId = "new",
                cancelledExecutionId = "old",
            ),
        )
        assertTrue(
            shouldDeleteCancelledDownload(
                TransferState.CANCELLING,
                currentExecutionId = "current",
                cancelledExecutionId = "current",
            ),
        )
    }

    @Test
    fun `失败时仅当前执行的目录下载需要删除目标`() {
        val directory = persistedDownload(
            state = TransferState.FAILED,
            isDirectory = true,
            workId = "current",
        )

        assertTrue(directory.shouldDeleteFailedDownload("current"))
        assertFalse(directory.shouldDeleteFailedDownload("old"))
        assertFalse(directory.copy(isDirectory = false).shouldDeleteFailedDownload("current"))
        assertFalse(directory.copy(state = TransferState.RUNNING).shouldDeleteFailedDownload("current"))
    }

    @Test
    fun `Worker保留DSM错误类别且将普通IO错误归为下载失败`() {
        assertEquals(DsmErrorKind.DOWNLOAD_FAILED, downloadFailureKind(IOException("synthetic")))
        assertEquals(
            DsmErrorKind.DOWNLOAD_LENGTH_MISMATCH,
            downloadFailureKind(
                DsmFailure(
                    null,
                    "synthetic",
                    "synthetic",
                    kind = DsmErrorKind.DOWNLOAD_LENGTH_MISMATCH,
                ),
            ),
        )
    }

    @Test fun archivePreservesContentEmptyDirectoryAndRawPathsWithoutRange() = runBlocking {
        val archive = ByteArrayOutputStream().also { buffer ->
            java.util.zip.ZipOutputStream(buffer).use { zip ->
                zip.putNextEntry(java.util.zip.ZipEntry("a.txt ")); zip.write("fixture-content".encodeToByteArray()); zip.closeEntry()
                zip.putNextEntry(java.util.zip.ZipEntry("Empty/")); zip.closeEntry()
            }
        }.toByteArray()
        val transport = DownloadInterceptor(archive, unknownContentLength = true)
        val output = ByteArrayOutputStream()
        val progress = mutableListOf<Pair<Long, Long?>>()
        val written = repository(transport).downloadArchive(listOf(
            FileItem("/synthetic/a.txt ", "a.txt ", false, 100_000),
            FileItem("/synthetic/Empty", "Empty", true, 999),
        ), output) { completed, total -> progress += completed to total }
        assertEquals(archive.size.toLong(), written)
        assertTrue(archive.contentEquals(output.toByteArray()))
        assertEquals(archive.size.toLong(), progress.last().first)
        assertEquals(null, transport.requests.single().header("Range"))
        assertEquals("""["/synthetic/a.txt ","/synthetic/Empty"]""", transport.requests.single().url.queryParameter("path"))
        java.util.zip.ZipInputStream(output.toByteArray().inputStream()).use { zip ->
            assertEquals("a.txt ", zip.nextEntry.name)
            assertEquals("fixture-content", zip.readBytes().decodeToString())
            assertEquals("Empty/", zip.nextEntry.name)
            assertEquals(null, zip.nextEntry)
        }
    }

    @Test fun invalidOrUnreadableArchiveSelectionSendsNoRequests() = runBlocking {
        val transport = DownloadInterceptor(byteArrayOf())
        val repo = repository(transport)
        val file = FileItem("/synthetic/a", "a", false)
        val folder = FileItem("/synthetic/empty", "empty", true)
        listOf(emptyList(), listOf(file), listOf(file, folder.copy(canRead = false)),
            listOf(file, folder.copy(path = "/synthetic/../other"))).forEach { items ->
            assertTrue(runCatching { repo.downloadArchive(items, ByteArrayOutputStream()) }.isFailure)
        }
        assertTrue(transport.requests.isEmpty())
    }

    private fun persistedDownload(
        state: TransferState,
        isDirectory: Boolean = false,
        workId: String? = "execution",
    ) = PersistedDownload(
        id = "task",
        profileId = "profile",
        sourcePath = "/synthetic/source",
        title = "synthetic.bin",
        destinationUri = "content://synthetic/destination",
        isDirectory = isDirectory,
        state = state,
        completedBytes = 8,
        workId = workId,
    )

    private fun repository(interceptor: DownloadInterceptor): DsmRepository = authorizedRepository(
        profile = NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        session = DsmSession("test", "test-session", "test-token"),
        api = DsmApiClient(
            OkHttpClient.Builder()
                .retryOnConnectionFailure(false)
                .addInterceptor(interceptor)
                .build(),
        ),
        capabilities = mapOf(
            "SYNO.FileStation.Download" to
                ApiCapability("SYNO.FileStation.Download", "entry.cgi", 1, 2),
        ),
    )
}

private class DownloadInterceptor(
    private val responseBytes: ByteArray,
    private val responseCode: Int = 200,
    private val contentRange: String? = null,
    private val unknownContentLength: Boolean = false,
) : Interceptor {
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(responseCode)
            .message("OK")
            .body(
                if (unknownContentLength) {
                    object : ResponseBody() {
                        override fun contentType() = "application/octet-stream".toMediaType()
                        override fun contentLength() = -1L
                        override fun source() = Buffer().write(responseBytes)
                    }
                } else {
                    responseBytes.toResponseBody("application/octet-stream".toMediaType())
                },
            )
            .apply { contentRange?.let { header("Content-Range", it) } }
            .build()
    }
}

package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.ArchiveCompressionLevel
import io.github.qwertyuiop1995.dsmnativeclient.domain.ArchiveFormat
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationExpectedOutput
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ArchiveRepositoryTest {
    @Test
    fun `恢复已提交压缩任务只读轮询且输出回读后确认成功`() = runBlocking {
        val transport = ArchiveInterceptor(
            success("""{"finished":true,"progress":1}"""),
            fileInfoResponse(fileItem("/home/archive.zip", size = 123)),
        )

        val result = repository(transport).resumeArchiveMutationResult(
            operation = FileServerMutationOperation.COMPRESS,
            taskId = "compress-task",
            expectedOutputs = listOf(
                FileServerMutationExpectedOutput(
                    path = "/home/archive.zip",
                    isDirectory = false,
                    requiresNonEmptyFile = true,
                ),
            ),
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(listOf("status", "getinfo"), transport.methods())
        assertFalse(transport.methods().contains("start"))
    }

    @Test
    fun `恢复任务即使状态完成也必须输出回读成功`() = runBlocking {
        val transport = ArchiveInterceptor(
            success("""{"finished":true}"""),
            *Array(8) { listResponse() },
        )

        val result = repository(transport).resumeArchiveMutationResult(
            operation = FileServerMutationOperation.EXTRACT,
            taskId = "extract-task",
            expectedOutputs = listOf(
                FileServerMutationExpectedOutput(
                    path = "/home/target/restored.txt",
                    isDirectory = false,
                ),
            ),
        )

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertTrue(result.submitted)
        assertTrue(result.requiresRefresh)
        assertEquals(1, result.counts.failed)
        assertEquals("file-station.archive-extract.readback-mismatch", result.diagnosticTag)
        assertEquals(1, transport.methods().count { it == "status" })
        assertEquals(8, transport.methods().count { it == "getinfo" })
        assertFalse(transport.methods().contains("start"))
    }

    @Test
    fun `压缩使用公开任务接口且完成后复查目标`() = runBlocking {
        val transport = ArchiveInterceptor(
            success("""{"files":[{"name":"home","path":"/home","isdir":true,"additional":{"perm":{"write":true}}}]}"""),
            listResponse(),
            success("""{"taskid":"compress-task"}"""),
            success("""{"finished":true}"""),
            listResponse("""{"name":"资料.7z","path":"/home/资料.7z","isdir":false,"size":123}"""),
        )

        repository(transport).compress(
            paths = listOf("/home/图片", "/home/说明.txt"),
            destinationFilePath = "/home/资料.7z",
            format = ArchiveFormat.SEVEN_ZIP,
            level = ArchiveCompressionLevel.BEST,
            password = "REDACTED_ARCHIVE_PASSWORD",
        )

        val start = transport.requests.first { it.formFields()["method"] == "start" }.formFields()
        assertEquals("SYNO.FileStation.Compress", start["api"])
        assertEquals("[\"/home/图片\",\"/home/说明.txt\"]", start["path"])
        assertEquals("/home/资料.7z", start["dest_file_path"])
        assertEquals("7z", start["format"])
        assertEquals("best", start["level"])
        assertEquals("REDACTED_ARCHIVE_PASSWORD", start["password"])
        assertFalse(transport.requests.first().url.toString().contains("REDACTED_ARCHIVE_PASSWORD"))
        RequestFixtureAssertions.assertRequest(
            transport.requests.first { it.formFields()["method"] == "start" },
            "file-station/compress/synthetic-selection/request.json",
        )
    }

    @Test
    fun `解压先读取内容拒绝覆盖并按顶层类型复查`() = runBlocking {
        val transport = ArchiveInterceptor(
            success("""{"files":[{"name":"target","path":"/home/target","isdir":true,"additional":{"perm":{"write":true}}}]}"""),
            fileInfoResponse(fileItem("/home/资料.zip", size = 10)),
            success("""{"items":[{"itemid":7,"name":"存档","path":"存档","is_dir":true}]}"""),
            success("""{"items":[],"total":0}"""),
            listResponse(),
            success("""{"taskid":"extract-task"}"""),
            success("""{"finished":true,"progress":0.75}"""),
            listResponse("""{"name":"存档","path":"/home/target/存档","isdir":true}"""),
        )

        val result = repository(transport).extractResult(
            filePath = "/home/资料.zip",
            destinationFolder = "/home/target",
            codepage = "chs",
        )

        val list = transport.requests.first { it.formFields()["method"] == "list" && it.formFields()["api"] == "SYNO.FileStation.Extract" }.formFields()
        assertEquals("-1", list["item_id"])
        assertEquals("chs", list["codepage"])
        val start = transport.requests.first { it.formFields()["method"] == "start" }.formFields()
        assertEquals("false", start["overwrite"])
        assertEquals("true", start["keep_dir"])
        assertEquals("false", start["create_subfolder"])
        RequestFixtureAssertions.assertRequest(
            transport.requests.first { it.formFields()["method"] == "start" },
            "file-station/extract/synthetic-archive/request.json",
        )
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `压缩密码全为空白时原样传递而不是创建无密码压缩包`() = runBlocking {
        val transport = ArchiveInterceptor(directoryResponse("/home", true), listResponse(),
            success("""{"taskid":"compress-task"}"""), success("""{"finished":true}"""),
            fileInfoResponse(fileItem("/home/archive.zip", size = 12)))
        repository(transport).compress(listOf("/home/source.txt"), "/home/archive.zip", ArchiveFormat.ZIP,
            ArchiveCompressionLevel.MODERATE, password = "   ")
        assertEquals("   ", transport.requests.single { it.formFields()["method"] == "start" }.formFields()["password"])
    }

    @Test
    fun `压缩提交钩子失败时不发送启动请求`() = runBlocking {
        val transport = ArchiveInterceptor(
            directoryResponse("/home", canWrite = true),
            listResponse(),
        )

        val failure = runCatching {
            repository(transport).compressResult(
                paths = listOf("/home/source.txt"),
                destinationFilePath = "/home/archive.zip",
                format = ArchiveFormat.ZIP,
                level = ArchiveCompressionLevel.MODERATE,
                onBeforeSubmit = { error("synthetic compression ownership failure") },
            )
        }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertEquals(0, transport.methods().count { it == "start" })
    }

    @Test
    fun `压缩启动成功后只回调一次任务标识且先于状态轮询`() = runBlocking {
        val transport = ArchiveInterceptor(
            directoryResponse("/home", canWrite = true),
            listResponse(),
            success("""{"taskid":"compress-task"}"""),
            success("""{"finished":true}"""),
            listResponse("""{"name":"archive.zip","path":"/home/archive.zip","isdir":false,"size":123}"""),
        )
        val callbacks = mutableListOf<Pair<String, List<String?>>>()

        val result = repository(transport).compressResult(
            paths = listOf("/home/source.txt"),
            destinationFilePath = "/home/archive.zip",
            format = ArchiveFormat.ZIP,
            level = ArchiveCompressionLevel.MODERATE,
            onTaskStarted = { taskId -> callbacks += taskId to transport.methods().toList() },
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, callbacks.size)
        assertEquals("compress-task", callbacks.single().first)
        assertEquals(1, callbacks.single().second.count { it == "start" })
        assertFalse(callbacks.single().second.contains("status"))
        assertTrue(transport.methods().indexOf("start") < transport.methods().indexOf("status"))
    }

    @Test
    fun `解压提交钩子失败时不发送启动请求`() = runBlocking {
        val transport = ArchiveInterceptor(
            directoryResponse("/home/target", canWrite = true),
            fileInfoResponse(fileItem("/home/archive.zip", size = 10)),
            success("""{"items":[{"itemid":1,"name":"a.txt","path":"a.txt","is_dir":false}]}"""),
            listResponse(),
        )

        val failure = runCatching {
            repository(transport).extractResult(
                filePath = "/home/archive.zip",
                destinationFolder = "/home/target",
                onBeforeSubmit = { error("synthetic extraction ownership failure") },
            )
        }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertEquals(0, transport.methods().count { it == "start" })
    }

    @Test
    fun `解压启动成功后只回调一次任务标识且先于状态轮询`() = runBlocking {
        val transport = ArchiveInterceptor(
            directoryResponse("/home/target", canWrite = true),
            fileInfoResponse(fileItem("/home/archive.zip", size = 10)),
            success("""{"items":[{"itemid":1,"name":"a.txt","path":"a.txt","is_dir":false}]}"""),
            listResponse(),
            success("""{"taskid":"extract-task"}"""),
            success("""{"finished":true}"""),
            listResponse("""{"name":"a.txt","path":"/home/target/a.txt","isdir":false}"""),
        )
        val callbacks = mutableListOf<Pair<String, List<String?>>>()

        val result = repository(transport).extractResult(
            filePath = "/home/archive.zip",
            destinationFolder = "/home/target",
            onTaskStarted = { taskId -> callbacks += taskId to transport.methods().toList() },
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, callbacks.size)
        assertEquals("extract-task", callbacks.single().first)
        assertEquals(1, callbacks.single().second.count { it == "start" })
        assertFalse(callbacks.single().second.contains("status"))
        assertTrue(transport.methods().indexOf("start") < transport.methods().indexOf("status"))
    }

    @Test
    fun `压缩目标目录只读时提交前拒绝`() = runBlocking {
        val transport = ArchiveInterceptor(directoryResponse("/home", canWrite = false))

        val result = repository(transport).compressResult(
            paths = listOf("/home/source.txt"),
            destinationFilePath = "/home/archive.zip",
            format = ArchiveFormat.ZIP,
            level = ArchiveCompressionLevel.MODERATE,
        )

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertEquals(MutationErrorCategory.PERMISSION, result.errorCategory)
        assertFalse(result.submitted)
        assertFalse(transport.methods().contains("start"))
    }

    @Test
    fun `压缩启动断线但目标回读存在时确认成功且不重放`() = runBlocking {
        val transport = ArchiveInterceptor(
            directoryResponse("/home", canWrite = true),
            listResponse(),
            IOException("synthetic disconnect"),
            listResponse("""{"name":"archive.zip","path":"/home/archive.zip","isdir":false,"size":123}"""),
        )

        val result = repository(transport).compressResult(
            paths = listOf("/home/source.txt"),
            destinationFilePath = "/home/archive.zip",
            format = ArchiveFormat.ZIP,
            level = ArchiveCompressionLevel.MODERATE,
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `压缩启动断线且目标不存在时保持未确认`() = runBlocking {
        val transport = ArchiveInterceptor(
            directoryResponse("/home", canWrite = true),
            listResponse(),
            IOException("synthetic disconnect"),
            listResponse(),
        )

        val result = repository(transport).compressResult(
            paths = listOf("/home/source.txt"),
            destinationFilePath = "/home/archive.zip",
            format = ArchiveFormat.ZIP,
            level = ArchiveCompressionLevel.MODERATE,
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `压缩提交权限拒绝不重放`() = runBlocking {
        val transport = ArchiveInterceptor(
            directoryResponse("/home", canWrite = true),
            listResponse(),
            """{"success":false,"error":{"code":105}}""",
        )

        val result = repository(transport).compressResult(
            paths = listOf("/home/source.txt"),
            destinationFilePath = "/home/archive.zip",
            format = ArchiveFormat.ZIP,
            level = ArchiveCompressionLevel.MODERATE,
        )

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `解压只确认部分目标时返回部分成功`() = runBlocking {
        val responses = mutableListOf<Any>(
            directoryResponse("/home/target", canWrite = true),
            fileInfoResponse(fileItem("/home/archive.zip", size = 10)),
            success("""{"items":[{"itemid":1,"name":"a","path":"a","is_dir":false},{"itemid":2,"name":"b","path":"b","is_dir":false}]}"""),
            listResponse(),
            listResponse(),
            success("""{"taskid":"extract-task"}"""),
            success("""{"finished":true}"""),
        )
        repeat(8) {
            responses += listResponse("""{"name":"a","path":"/home/target/a","isdir":false}""")
            responses += listResponse()
        }
        val transport = ArchiveInterceptor(*responses.toTypedArray())

        val result = repository(transport).extractResult("/home/archive.zip", "/home/target")

        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(1, result.counts.failed)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `解压目标目录只读时提交前拒绝`() = runBlocking {
        val transport = ArchiveInterceptor(directoryResponse("/home/target", canWrite = false))

        val result = repository(transport).extractResult("/home/archive.zip", "/home/target")

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertFalse(result.submitted)
        assertEquals(listOf("getinfo"), transport.methods())
        assertTrue(
            transport.requests.single().formFields().getValue("additional")
                .contains("mount_point_type"),
        )
    }

    @Test
    fun `解压启动断线但全部目标回读存在时确认成功且不重放`() = runBlocking {
        val transport = ArchiveInterceptor(
            directoryResponse("/home/target", canWrite = true),
            fileInfoResponse(fileItem("/home/archive.zip", size = 10)),
            success("""{"items":[{"itemid":1,"name":"a","path":"a","is_dir":false}]}"""),
            listResponse(),
            IOException("synthetic disconnect"),
            listResponse("""{"name":"a","path":"/home/target/a","isdir":false}"""),
        )

        val result = repository(transport).extractResult("/home/archive.zip", "/home/target")

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `压缩解压非法输入和能力不足均不发送请求`() = runBlocking {
        val transport = ArchiveInterceptor()
        val invalid = repository(transport).compressResult(
            paths = emptyList(),
            destinationFilePath = "/home/archive.zip",
            format = ArchiveFormat.ZIP,
            level = ArchiveCompressionLevel.MODERATE,
        )
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, invalid.status)
        assertEquals(MutationErrorCategory.VALIDATION, invalid.errorCategory)
        assertTrue(transport.requests.isEmpty())

        val unsupportedRepo = repository(transport, supportsArchives = false)
        val unsupported = unsupportedRepo.extractResult("/home/archive.zip", "/home/target")
        assertEquals(MutationResultStatus.UNSUPPORTED, unsupported.status)
        assertFalse(unsupported.submitted)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `压缩提交前协程取消时不访问网络`() {
        val transport = ArchiveInterceptor()
        val job = Job()
        var status: MutationResultStatus? = null

        runCatching {
            runBlocking(job) {
                job.cancel()
                status = repository(transport).compressResult(
                    paths = listOf("/home/source.txt"),
                    destinationFilePath = "/home/archive.zip",
                    format = ArchiveFormat.ZIP,
                    level = ArchiveCompressionLevel.MODERATE,
                ).status
            }
        }

        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, status)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `压缩提交后取消会停止任务并只要求刷新`() = runBlocking {
        val transport = BlockingArchiveInterceptor()
        val repo = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.compressResult(
                paths = listOf("/home/source.txt"),
                destinationFilePath = "/home/archive.zip",
                format = ArchiveFormat.ZIP,
                level = ArchiveCompressionLevel.MODERATE,
            ).status
        }
        assertTrue(transport.statusStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowStatus.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.methods().count { it == "start" })
        assertEquals(1, transport.methods().count { it == "stop" })
    }

    @Test
    fun `解压提交后取消会停止任务且不会再次启动`() = runBlocking {
        val transport = BlockingExtractStatusInterceptor()
        val repo = repository(transport)
        var status: MutationResultStatus? = null
        val worker = launch(Dispatchers.IO) {
            status = repo.extractResult("/home/archive.zip", "/home/target").status
        }
        assertTrue(transport.statusStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowStatus.countDown()
        worker.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, status)
        assertEquals(1, transport.methods().count { it == "start" })
        assertEquals(1, transport.methods().count { it == "stop" })
    }

    @Test
    fun `恢复已提交压缩任务取消时只停止本地观察且不发送写请求`() = runBlocking {
        val transport = BlockingResumeArchiveStatusInterceptor()
        val worker = launch(Dispatchers.IO) {
            repository(transport).resumeArchiveMutationResult(
                operation = FileServerMutationOperation.COMPRESS,
                taskId = "compress-task",
                expectedOutputs = listOf(
                    FileServerMutationExpectedOutput(
                        path = "/home/archive.zip",
                        isDirectory = false,
                        requiresNonEmptyFile = true,
                    ),
                ),
            )
        }
        assertTrue(transport.statusStarted.await(2, TimeUnit.SECONDS))

        worker.cancel()
        transport.allowStatus.countDown()
        worker.join()

        assertTrue(worker.isCancelled)
        assertEquals(listOf("status"), transport.methods())
        assertFalse(transport.methods().contains("start"))
        assertFalse(transport.methods().contains("stop"))
    }

    @Test
    fun `同一压缩目标进行中时拒绝重复提交`() = runBlocking {
        val transport = BlockingArchiveInterceptor(targetAppears = true)
        val repo = repository(transport)
        val first = async(Dispatchers.IO) {
            repo.compressResult(
                paths = listOf("/home/source.txt"),
                destinationFilePath = "/home/archive.zip",
                format = ArchiveFormat.ZIP,
                level = ArchiveCompressionLevel.MODERATE,
            )
        }
        assertTrue(transport.statusStarted.await(2, TimeUnit.SECONDS))

        val duplicate = repo.compressResult(
            paths = listOf("/home/source.txt"),
            destinationFilePath = "/home/archive.zip",
            format = ArchiveFormat.ZIP,
            level = ArchiveCompressionLevel.MODERATE,
        )
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, duplicate.status)
        assertEquals(MutationErrorCategory.CONFLICT, duplicate.errorCategory)
        assertFalse(duplicate.submitted)

        transport.allowStatus.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `压缩进行中时拒绝删除源文件`() = runBlocking {
        val transport = BlockingArchiveInterceptor(targetAppears = true)
        val repo = repository(transport)
        val compression = async(Dispatchers.IO) {
            repo.compressResult(
                paths = listOf("/home/source.txt"),
                destinationFilePath = "/home/archive.zip",
                format = ArchiveFormat.ZIP,
                level = ArchiveCompressionLevel.MODERATE,
            )
        }
        assertTrue(transport.statusStarted.await(2, TimeUnit.SECONDS))

        val deletion = repo.deleteResult(listOf("/home/source.txt"))
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, deletion.status)
        assertEquals(MutationErrorCategory.CONFLICT, deletion.errorCategory)
        assertFalse(deletion.submitted)

        transport.allowStatus.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, compression.await().status)
        assertFalse(transport.methods().contains("delete"))
    }

    @Test
    fun `压缩源文件基线漂移时零提交`() = runBlocking {
        val destination = directoryItem("/home")
        val source = fileItem("/home/source.txt", size = 10)
        val transport = ArchiveInterceptor(
            fileInfoResponse(destination),
            fileInfoResponse(source.copy(size = 11)),
        )

        val result = repository(transport).compressResult(
            sourceBaselines = listOf(source),
            destinationBaseline = destination,
            destinationFilePath = "/home/archive.zip",
            format = ArchiveFormat.ZIP,
            level = ArchiveCompressionLevel.MODERATE,
        )

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertEquals(listOf("getinfo", "getinfo"), transport.methods())
        assertFalse(transport.methods().contains("start"))
    }

    @Test
    fun `压缩目标目录基线漂移时零提交`() = runBlocking {
        val destination = directoryItem("/home")
        val source = fileItem("/home/source.txt", size = 10)
        val transport = ArchiveInterceptor(fileInfoResponse(destination.copy(owner = "changed")))

        val result = repository(transport).compressResult(
            sourceBaselines = listOf(source),
            destinationBaseline = destination,
            destinationFilePath = "/home/archive.zip",
            format = ArchiveFormat.ZIP,
            level = ArchiveCompressionLevel.MODERATE,
        )

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertEquals(listOf("getinfo"), transport.methods())
    }

    @Test
    fun `压缩完成后零字节目标不能确认成功`() = runBlocking {
        val responses = mutableListOf<Any>(
            directoryResponse("/home", canWrite = true),
            listResponse(),
            success("""{"taskid":"compress-task"}"""),
            success("""{"finished":true}"""),
        )
        repeat(8) {
            responses += listResponse(
                """{"name":"archive.zip","path":"/home/archive.zip","isdir":false,"size":0}""",
            )
        }
        val transport = ArchiveInterceptor(*responses.toTypedArray())

        val result = repository(transport).compressResult(
            paths = listOf("/home/source.txt"),
            destinationFilePath = "/home/archive.zip",
            format = ArchiveFormat.ZIP,
            level = ArchiveCompressionLevel.MODERATE,
        )

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(0, result.counts.succeeded)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `压缩完成后同名目录不能冒充归档文件`() = runBlocking {
        val responses = mutableListOf<Any>(
            directoryResponse("/home", canWrite = true),
            listResponse(),
            success("""{"taskid":"compress-task"}"""),
            success("""{"finished":true}"""),
        )
        repeat(8) {
            responses += listResponse(
                """{"name":"archive.zip","path":"/home/archive.zip","isdir":true,"size":123}""",
            )
        }
        val transport = ArchiveInterceptor(*responses.toTypedArray())

        val result = repository(transport).compressResult(
            paths = listOf("/home/source.txt"),
            destinationFilePath = "/home/archive.zip",
            format = ArchiveFormat.ZIP,
            level = ArchiveCompressionLevel.MODERATE,
        )

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(0, result.counts.succeeded)
    }

    @Test
    fun `解压源文件基线漂移时不会读取归档或启动任务`() = runBlocking {
        val destination = directoryItem("/home/target")
        val source = fileItem("/home/archive.zip", size = 10)
        val transport = ArchiveInterceptor(
            fileInfoResponse(destination),
            fileInfoResponse(source.copy(size = 11)),
        )

        val result = repository(transport).extractResult(source, destination)

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertEquals(listOf("getinfo", "getinfo"), transport.methods())
        assertFalse(transport.methods().contains("list"))
        assertFalse(transport.methods().contains("start"))
    }

    @Test
    fun `压缩源读取权限撤销后不能沿用旧快照提交`() = runBlocking {
        val source = fileItem("/home/a.txt", size = 10)
        val destination = directoryItem("/home")
        val transport = ArchiveInterceptor(fileInfoResponse(destination), fileInfoResponse(source.copy(canRead = false)))
        val result = repository(transport).compressResult(listOf(source), destination, "/home/archive.zip", ArchiveFormat.ZIP, ArchiveCompressionLevel.MODERATE)
        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertEquals(0, transport.methods().count { it == "start" })
    }

    @Test
    fun `解压目标目录基线漂移时不会读取归档或启动任务`() = runBlocking {
        val destination = directoryItem("/home/target")
        val source = fileItem("/home/archive.zip", size = 10)
        val transport = ArchiveInterceptor(fileInfoResponse(destination.copy(owner = "changed")))

        val result = repository(transport).extractResult(source, destination)

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
        assertFalse(result.submitted)
        assertEquals(listOf("getinfo"), transport.methods())
    }

    @Test
    fun `解压完成后输出类型必须与归档目录项一致`() = runBlocking {
        val destination = directoryItem("/home/target")
        val source = fileItem("/home/archive.zip", size = 10)
        val responses = mutableListOf<Any>(
            fileInfoResponse(destination),
            fileInfoResponse(source),
            success("""{"items":[{"itemid":1,"name":"a.txt","path":"a.txt","is_dir":false}]}"""),
            listResponse(),
            success("""{"taskid":"extract-task"}"""),
            success("""{"finished":true}"""),
        )
        repeat(8) {
            responses += listResponse(
                """{"name":"a.txt","path":"/home/target/a.txt","isdir":true}""",
            )
        }
        val transport = ArchiveInterceptor(*responses.toTypedArray())

        val result = repository(transport).extractResult(source, destination)

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(0, result.counts.succeeded)
        assertEquals(
            listOf("getinfo", "getinfo", "list", "getinfo", "start", "status"),
            transport.methods().take(6),
        )
    }

    @Test
    fun `解压在读取归档前持有源文件路径锁`() = runBlocking {
        val transport = BlockingExtractListInterceptor()
        val repo = repository(transport)
        val extraction = async(Dispatchers.IO) {
            repo.extractResult(
                fileItem("/home/archive.zip", size = 10),
                directoryItem("/home/target"),
            )
        }
        assertTrue(transport.listStarted.await(2, TimeUnit.SECONDS))

        val deletion = repo.deleteResult(listOf("/home/archive.zip"))

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, deletion.status)
        assertEquals(MutationErrorCategory.CONFLICT, deletion.errorCategory)
        assertFalse(deletion.submitted)
        assertFalse(transport.methods().contains("delete"))
        transport.allowList.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, extraction.await().status)
        assertEquals(listOf("getinfo", "getinfo", "list"), transport.methods().take(3))
    }

    private fun repository(
        interceptor: Interceptor,
        supportsArchives: Boolean = true,
    ): DsmRepository = authorizedRepository(
        profile = NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        session = DsmSession("test", "test-session", "test-token"),
        api = DsmApiClient(
            OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(interceptor).build(),
        ),
        capabilities = buildList {
            add(
            ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2),
            )
            add(
            ApiCapability("SYNO.FileStation.Delete", "entry.cgi", 1, 2),
            )
            if (supportsArchives) {
                add(ApiCapability("SYNO.FileStation.Compress", "entry.cgi", 3, 3))
                add(ApiCapability("SYNO.FileStation.Extract", "entry.cgi", 2, 2))
            }
        }.associateBy(ApiCapability::name),
    )

    private fun success(data: String) = """{"success":true,"data":$data}"""

    private fun directoryItem(path: String) = FileItem(
        path = path,
        name = path.substringAfterLast('/'),
        isDirectory = true,
        owner = "tester",
        canWrite = true,
    )

    private fun fileItem(path: String, size: Long) = FileItem(
        path = path,
        name = path.substringAfterLast('/'),
        isDirectory = false,
        size = size,
        owner = "tester",
    )

    private fun fileInfoResponse(item: FileItem) = success(
        """{"files":[{"name":"${item.name}","path":"${item.path}","isdir":${item.isDirectory},"size":${item.size},"additional":{"owner":"${item.owner}","perm":{"read":${item.canRead},"write":${item.canWrite},"delete":${item.canDelete}}}}]}""",
    )

    private fun directoryResponse(path: String, canWrite: Boolean) = success(
        """{"files":[{"name":"${path.substringAfterLast('/')}","path":"$path","isdir":true,"additional":{"perm":{"write":$canWrite}}}]}""",
    )

    private fun listResponse(item: String? = null) = success(
        """{"offset":0,"total":${if (item == null) 0 else 1},"files":[${item.orEmpty()}]}""",
    )
}

private class ArchiveInterceptor(vararg responses: Any) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val step = pending.removeFirstOrNull() ?: error("缺少合成压缩响应")
        if (step is IOException) throw step
        val body = step as String
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }

    fun methods(): List<String?> = requests.map { it.formFields()["method"] }
}

private class BlockingArchiveInterceptor(
    private val targetAppears: Boolean = false,
) : Interceptor {
    val statusStarted = CountDownLatch(1)
    val allowStatus = CountDownLatch(1)
    val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val fields = request.formFields()
        val method = fields["method"]
        val body = when (method) {
            "getinfo" -> if (fields["path"] == "[\"/home/archive.zip\"]") {
                if (targetAppears && statusStarted.count == 0L) {
                    """{"success":true,"data":{"files":[{"name":"archive.zip","path":"/home/archive.zip","isdir":false,"size":123}]}}"""
                } else {
                    """{"success":true,"data":{"files":[]}}"""
                }
            } else {
                """{"success":true,"data":{"files":[{"name":"home","path":"/home","isdir":true,"additional":{"perm":{"write":true}}}]}}"""
            }
            "start" -> """{"success":true,"data":{"taskid":"compress-task"}}"""
            "status" -> {
                statusStarted.countDown()
                check(allowStatus.await(2, TimeUnit.SECONDS)) { "等待压缩状态响应超时" }
                """{"success":true,"data":{"finished":true}}"""
            }
            "stop" -> """{"success":true,"data":{}}"""
            "list" -> """{"success":true,"data":{"offset":0,"total":0,"files":[]}}"""
            else -> error("未处理的压缩方法：$method")
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }

    fun methods(): List<String?> = requests.map { it.formFields()["method"] }
}

private class BlockingExtractListInterceptor : Interceptor {
    val listStarted = CountDownLatch(1)
    val allowList = CountDownLatch(1)
    val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())
    @Volatile
    private var taskStarted = false

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val fields = request.formFields()
        val method = fields["method"]
        val body = when (method) {
            "getinfo" -> when (fields["path"]) {
                "[\"/home/target\"]" -> fileInfo(
                    name = "target",
                    path = "/home/target",
                    isDirectory = true,
                    size = 0,
                    canWrite = true,
                )
                "[\"/home/archive.zip\"]" -> fileInfo(
                    name = "archive.zip",
                    path = "/home/archive.zip",
                    isDirectory = false,
                    size = 10,
                )
                "[\"/home/target/a.txt\"]" -> if (taskStarted) {
                    fileInfo("a.txt", "/home/target/a.txt", isDirectory = false, size = 5)
                } else {
                    """{"success":true,"data":{"files":[]}}"""
                }
                else -> error("未处理的解压路径：${fields["path"]}")
            }
            "list" -> {
                listStarted.countDown()
                check(allowList.await(2, TimeUnit.SECONDS)) { "等待解压列表响应超时" }
                """{"success":true,"data":{"items":[{"itemid":1,"name":"a.txt","path":"a.txt","is_dir":false}]}}"""
            }
            "start" -> {
                taskStarted = true
                """{"success":true,"data":{"taskid":"extract-task"}}"""
            }
            "status" -> """{"success":true,"data":{"finished":true}}"""
            else -> error("未处理的解压方法：$method")
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }

    fun methods(): List<String?> = requests.map { it.formFields()["method"] }

    private fun fileInfo(
        name: String,
        path: String,
        isDirectory: Boolean,
        size: Long,
        canWrite: Boolean = false,
    ) = """{"success":true,"data":{"files":[{"name":"$name","path":"$path","isdir":$isDirectory,"size":$size,"additional":{"owner":"tester","perm":{"read":true,"write":$canWrite,"delete":false}}}]}}"""
}

private class BlockingExtractStatusInterceptor : Interceptor {
    val statusStarted = CountDownLatch(1)
    val allowStatus = CountDownLatch(1)
    private val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val fields = request.formFields()
        val body = when (fields["method"]) {
            "getinfo" -> when (fields["path"]) {
                "[\"/home/target\"]" -> fileInfo("target", "/home/target", isDirectory = true, canWrite = true)
                "[\"/home/archive.zip\"]" -> fileInfo("archive.zip", "/home/archive.zip", isDirectory = false, canWrite = false)
                "[\"/home/target/a.txt\"]" -> """{"success":true,"data":{"files":[]}}"""
                else -> error("未处理的解压路径：${fields["path"]}")
            }
            "list" -> """{"success":true,"data":{"items":[{"itemid":1,"name":"a.txt","path":"a.txt","is_dir":false}]}}"""
            "start" -> """{"success":true,"data":{"taskid":"extract-task"}}"""
            "status" -> {
                statusStarted.countDown()
                check(allowStatus.await(2, TimeUnit.SECONDS)) { "等待解压状态响应超时" }
                """{"success":true,"data":{"finished":false}}"""
            }
            "stop" -> """{"success":true,"data":{}}"""
            else -> error("未处理的解压方法：${fields["method"]}")
        }
        return archiveTestResponse(request, body)
    }

    fun methods(): List<String?> = requests.map { it.formFields()["method"] }

    private fun fileInfo(name: String, path: String, isDirectory: Boolean, canWrite: Boolean) =
        """{"success":true,"data":{"files":[{"name":"$name","path":"$path","isdir":$isDirectory,"additional":{"perm":{"read":true,"write":$canWrite}}}]}}"""
}

private class BlockingResumeArchiveStatusInterceptor : Interceptor {
    val statusStarted = CountDownLatch(1)
    val allowStatus = CountDownLatch(1)
    private val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        check(request.formFields()["method"] == "status")
        statusStarted.countDown()
        check(allowStatus.await(2, TimeUnit.SECONDS)) { "等待恢复任务状态响应超时" }
        return archiveTestResponse(request, """{"success":true,"data":{"finished":false}}""")
    }

    fun methods(): List<String?> = requests.map { it.formFields()["method"] }
}

private fun archiveTestResponse(request: Request, body: String): Response = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body.toResponseBody("application/json".toMediaType()))
    .build()

private fun Request.formFields(): Map<String, String> {
    val body = body as? okhttp3.FormBody ?: return emptyMap()
    return (0 until body.size).associate { body.name(it) to body.value(it) }
}

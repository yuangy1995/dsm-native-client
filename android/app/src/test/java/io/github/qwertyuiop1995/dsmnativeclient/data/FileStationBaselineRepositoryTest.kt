package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileShareLink
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.coroutines.runBlocking
import okhttp3.FormBody
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class FileStationBaselineRepositoryTest {
    @Test
    fun `创建目录基线一致时按专项回读确认单项成功`() = runBlocking {
        val created = parent.copy(path = "/share/New", name = "New")
        val transport = QueueTransport(
            fileInfo(parent),
            EMPTY_FILES,
            SUCCESS,
            fileInfo(created),
        )

        val result = repository(transport).createFolderResult(parent, "New")

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(MutationResultCounts(1, 0, 0), result.counts)
        assertEquals(listOf("getinfo", "list", "create", "getinfo"), transport.methods())
    }

    @Test
    fun `创建目录的用户所见父目录权限漂移时零写拒绝`() = runBlocking {
        val transport = QueueTransport(fileInfo(parent.copy(canWrite = false)))

        val result = repository(transport).createFolderResult(parent, "New")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertFalse(result.submitted)
        assertEquals(MutationResultCounts(0, 1, 0), result.counts)
        assertEquals(listOf("getinfo"), transport.methods())
    }

    @Test
    fun `重命名源路径已被同名不同大小文件替换时零写拒绝`() = runBlocking {
        val baseline = file("/share/Old.txt", size = 10, modified = 100)
        val replacement = baseline.copy(size = 20, modifiedAtEpochSeconds = 200)
        val transport = QueueTransport(fileInfo(replacement))

        val result = repository(transport).renameResult(baseline, "New.txt")

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertFalse(result.submitted)
        assertEquals(listOf("getinfo"), transport.methods())
    }

    @Test
    fun `移动源文件基线漂移时不启动服务端任务`() = runBlocking {
        val source = file("/share/a.jpg", size = 10, modified = 100)
        val destination = parent.copy(path = "/share/Trips", name = "Trips")
        val transport = QueueTransport(
            fileInfo(destination),
            fileInfo(source.copy(modifiedAtEpochSeconds = 101)),
        )

        val result = repository(transport).moveResult(listOf(source), destination)

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertFalse(result.submitted)
        assertEquals(MutationResultCounts(0, 1, 0), result.counts)
        assertEquals(listOf("getinfo", "getinfo"), transport.methods())
    }

    @Test
    fun `移动源文件不可删除时不启动服务端任务`() = runBlocking {
        val source = file("/share/a.jpg", size = 10, modified = 100).copy(canDelete = false)
        val destination = parent.copy(path = "/share/Trips", name = "Trips")
        val transport = QueueTransport(fileInfo(destination), fileInfo(source))

        val result = repository(transport).moveResult(listOf(source), destination)

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertFalse(result.submitted)
        assertEquals(listOf("getinfo", "getinfo"), transport.methods())
    }

    @Test
    fun `移动写后同名不同内容不冒充本次目标`() = runBlocking {
        val source = file("/share/a.jpg", size = 10, modified = 100)
        val destination = parent.copy(path = "/share/Trips", name = "Trips")
        val target = source.copy(path = "/share/Trips/a.jpg", size = 11)
        val transport = QueueTransport(
            fileInfo(destination),
            fileInfo(source),
            EMPTY_FILES,
            MOVE_START,
            TASK_FINISHED,
            EMPTY_FILES,
            fileInfo(target),
        )

        val result = repository(transport).moveResult(listOf(source), destination)

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(MutationResultCounts(0, 1, 0), result.counts)
        assertEquals(
            listOf("getinfo", "getinfo", "list", "start", "status", "getinfo", "getinfo"),
            transport.methods(),
        )
    }

    @Test
    fun `移动写后目标继承不同权限但内容一致仍确认成功`() = runBlocking {
        val source = file("/share/a.jpg", size = 10, modified = 100)
        val destination = parent.copy(path = "/share/Trips", name = "Trips")
        val target = source.copy(
            path = "/share/Trips/a.jpg",
            owner = "inherited-owner",
            canWrite = false,
            canDelete = false,
        )
        val transport = QueueTransport(
            fileInfo(destination),
            fileInfo(source),
            EMPTY_FILES,
            MOVE_START,
            TASK_FINISHED,
            EMPTY_FILES,
            fileInfo(target),
        )

        val result = repository(transport).moveResult(listOf(source), destination)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(MutationResultCounts(1, 0, 0), result.counts)
    }

    @Test
    fun `删除使用完整文件基线并在任务后复查目标消失`() = runBlocking {
        val baseline = file("/share/a.jpg", size = 10, modified = 100)
        val transport = QueueTransport(
            fileInfo(baseline),
            DELETE_START,
            TASK_FINISHED,
            EMPTY_FILES,
        )

        val result = repository(transport).deleteResult(baseline)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(MutationResultCounts(1, 0, 0), result.counts)
        assertEquals(listOf("getinfo", "start", "status", "getinfo"), transport.methods())
    }

    @Test
    fun `删除源文件基线漂移时不启动服务端任务`() = runBlocking {
        val baseline = file("/share/a.jpg", size = 10, modified = 100)
        val transport = QueueTransport(fileInfo(baseline.copy(size = 11)))

        val result = repository(transport).deleteResult(baseline)

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertFalse(result.submitted)
        assertEquals(MutationResultCounts(0, 1, 0), result.counts)
        assertEquals(listOf("getinfo"), transport.methods())
    }

    @Test
    fun `批量删除逐项核对完整基线后只提交一次任务`() = runBlocking {
        val first = file("/share/a.jpg", size = 10, modified = 100)
        val second = file("/share/b.jpg", size = 20, modified = 200)
        val transport = QueueTransport(
            fileInfo(first),
            fileInfo(second),
            DELETE_START,
            TASK_FINISHED,
            EMPTY_FILES,
            EMPTY_FILES,
        )

        val result = repository(transport).deleteResult(listOf(first, second))

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(MutationResultCounts(2, 0, 0), result.counts)
        assertEquals(
            listOf("getinfo", "getinfo", "start", "status", "getinfo", "getinfo"),
            transport.methods(),
        )
    }

    @Test
    fun `批量删除任务完成后逐项回读并报告部分成功`() = runBlocking {
        val first = file("/share/a.jpg", size = 10, modified = 100)
        val second = file("/share/b.jpg", size = 20, modified = 200)
        val transport = QueueTransport(
            fileInfo(first),
            fileInfo(second),
            DELETE_START,
            TASK_FINISHED,
            EMPTY_FILES,
            fileInfo(second),
        )

        val result = repository(transport).deleteResult(listOf(first, second))

        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(MutationResultCounts(1, 1, 0), result.counts)
        assertEquals(true, result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "start" })
    }

    @Test
    fun `批量删除任一基线漂移时核对全部目标并保持零写`() = runBlocking {
        val first = file("/share/a.jpg", size = 10, modified = 100)
        val second = file("/share/b.jpg", size = 20, modified = 200)
        val transport = QueueTransport(
            fileInfo(first.copy(size = 11)),
            fileInfo(second),
        )

        val result = repository(transport).deleteResult(listOf(first, second))

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertFalse(result.submitted)
        assertEquals(MutationResultCounts(0, 2, 0), result.counts)
        assertEquals(listOf("getinfo", "getinfo"), transport.methods())
    }

    @Test
    fun `批量删除任一目标已不可删除时核对全部目标并保持零写`() = runBlocking {
        val first = file("/share/a.jpg", size = 10, modified = 100)
        val second = file("/share/b.jpg", size = 20, modified = 200)
        val transport = QueueTransport(
            fileInfo(first.copy(canDelete = false)),
            fileInfo(second),
        )

        val result = repository(transport).deleteResult(listOf(first, second))

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertFalse(result.submitted)
        assertEquals(MutationResultCounts(0, 2, 0), result.counts)
        assertEquals(listOf("getinfo", "getinfo"), transport.methods())
    }

    @Test
    fun `批量删除模糊提交后只逐项回读且不重放`() = runBlocking {
        val first = file("/share/a.jpg", size = 10, modified = 100)
        val second = file("/share/b.jpg", size = 20, modified = 200)
        val transport = QueueTransport(
            fileInfo(first),
            fileInfo(second),
            "{",
            EMPTY_FILES,
            EMPTY_FILES,
        )

        val result = repository(transport).deleteResult(listOf(first, second))

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(MutationResultCounts(2, 0, 0), result.counts)
        assertEquals(listOf("getinfo", "getinfo", "start", "getinfo", "getinfo"), transport.methods())
    }

    @Test
    fun `收藏新增基线漂移时不发送 add`() = runBlocking {
        val baseline = file("/share/a.jpg", size = 10, modified = 100)
        val transport = QueueTransport(fileInfo(baseline.copy(size = 11)))

        val result = repository(transport).addFavoriteResult(baseline)

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertFalse(result.submitted)
        assertEquals(listOf("getinfo"), transport.methods())
    }

    @Test
    fun `共享链接创建基线漂移时不发送 create`() = runBlocking {
        val baseline = file("/share/a.jpg", size = 10, modified = 100)
        val transport = QueueTransport(fileInfo(baseline.copy(owner = "changed")))

        val outcome = repository(transport).createShareLinkResult(baseline)

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, outcome.result.status)
        assertFalse(outcome.result.submitted)
        assertEquals(listOf("getinfo"), transport.methods())
    }

    @Test
    fun `共享创建响应缺少链接标识时不认领提交前已有同路径链接`() = runBlocking {
        val baseline = file("/share/a.jpg", size = 10, modified = 100)
        val existing = FileShareLink(
            id = "link-existing",
            name = baseline.name,
            path = baseline.path,
            url = "https://example.invalid/existing",
        )
        val transport = QueueTransport(
            fileInfo(baseline),
            shareLinks(existing),
            SUCCESS,
            shareLinks(existing),
        )

        val outcome = repository(transport).createShareLinkResult(baseline)

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, outcome.result.status)
        assertEquals(MutationResultCounts(0, 0, 1), outcome.result.counts)
        assertEquals(listOf("getinfo", "list", "create", "list"), transport.methods())
    }

    @Test
    fun `共享链接删除稳定标识相同但用户所见链接漂移时零写拒绝`() = runBlocking {
        val baseline = FileShareLink(
            id = "link-1",
            name = "a.jpg",
            path = "/share/a.jpg",
            url = "https://example.invalid/original",
        )
        val transport = QueueTransport(
            shareLinks(baseline.copy(url = "https://example.invalid/replaced")),
        )

        val result = repository(transport).deleteShareLinksResult(listOf("link-1"), listOf(baseline))

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertFalse(result.submitted)
        assertEquals(MutationResultCounts(0, 1, 0), result.counts)
        assertEquals(listOf("list"), transport.methods())
    }

    private fun repository(transport: Interceptor) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(transport).build()),
        listOf(
            "SYNO.FileStation.List",
            "SYNO.FileStation.CreateFolder",
            "SYNO.FileStation.Rename",
            "SYNO.FileStation.CopyMove",
            "SYNO.FileStation.Delete",
            "SYNO.FileStation.Favorite",
            "SYNO.FileStation.Sharing",
        ).associateWith { name -> ApiCapability(name, "entry.cgi", 1, if (name == "SYNO.FileStation.Sharing") 3 else 2) },
    )

    private companion object {
        const val EMPTY_FILES = """{"success":true,"data":{"files":[],"total":0}}"""
        const val SUCCESS = """{"success":true,"data":{}}"""
        const val DELETE_START = """{"success":true,"data":{"taskid":"delete-task"}}"""
        const val MOVE_START = """{"success":true,"data":{"taskid":"move-task"}}"""
        const val TASK_FINISHED = """{"success":true,"data":{"finished":true}}"""

        val parent = FileItem(
            path = "/share",
            name = "share",
            isDirectory = true,
            owner = "tester",
            canRead = true,
            canWrite = true,
            canDelete = false,
        )

        fun file(path: String, size: Long, modified: Long) = FileItem(
            path = path,
            name = path.substringAfterLast('/'),
            isDirectory = false,
            size = size,
            modifiedAtEpochSeconds = modified,
            owner = "tester",
            canRead = true,
            canWrite = true,
            canDelete = true,
        )

        fun fileInfo(item: FileItem): String = """
            {"success":true,"data":{"files":[{
              "path":"${item.path}","name":"${item.name}","isdir":${item.isDirectory},"size":${item.size},
              "additional":{"time":{"mtime":${item.modifiedAtEpochSeconds ?: 0}},"owner":{"user":"${item.owner.orEmpty()}"},
              "perm":{"read":${item.canRead},"write":${item.canWrite},"delete":${item.canDelete}}}
            }]}}
        """.trimIndent()

        fun shareLinks(link: FileShareLink): String = """
            {"success":true,"data":{"links":[{"id":"${link.id}","name":"${link.name}",
            "path":"${link.path}","url":"${link.url}"}],"total":1}}
        """.trimIndent()
    }
}

private class QueueTransport(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(
                (pending.removeFirstOrNull() ?: error("缺少合成 File Station 响应"))
                    .toResponseBody("application/json".toMediaType()),
            )
            .build()
    }

    fun methods(): List<String?> = requests.map { request ->
        val form = request.body as? FormBody
        (0 until (form?.size ?: 0)).firstNotNullOfOrNull { index ->
            form?.takeIf { it.name(index) == "method" }?.value(index)
        }
    }
}

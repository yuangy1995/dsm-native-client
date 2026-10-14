package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.ArchiveCompressionLevel
import io.github.qwertyuiop1995.dsmnativeclient.domain.ArchiveFormat
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.FormBody
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 合成路径特意保留末尾空白，用真实编码/解码和结果回读覆盖文件身份边界。 */
class FileMutationPathIdentityTest {
    @Test
    fun `跨 NAS 删源逐项请求非递归且保留精确路径`() = runBlocking {
        for (directory in listOf(false, true)) {
            val source = item("/share/source ", directory)
            val transport = PathTransport(info(source), START, FINISHED, EMPTY)
            val result = repository(transport).deleteResult(source, recursive = false)
            assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
            assertEquals(listOf(source.path), transport.start().paths())
            assertEquals("false", transport.start()["recursive"])
            assertEquals(listOf(source.path, source.path), transport.infoPaths())
        }
    }

    @Test
    fun `跨 NAS 复制目录保留源名称首尾空格`() = runBlocking {
        val parent = item("/share/Target ", directory = true)
        val created = item("${parent.path}/ Folder ", directory = true)
        val transport = PathTransport(info(parent), EMPTY, SUCCESS, info(created))
        val result = repository(transport).createFolderResult(parent, " Folder ", preserveSourceName = true)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(" Folder ", transport.fields.single { it["method"] == "create" }["name"])
        assertEquals(listOf(parent.path, created.path), transport.infoPaths())
    }

    @Test
    fun `批量删除两个仅末尾空格不同的文件逐个预检提交并回读`() = runBlocking {
        val first = item("/share/report.txt")
        val second = item("/share/report.txt ")
        val transport = PathTransport(info(first), info(second), START, FINISHED, EMPTY, EMPTY)

        val result = repository(transport).deleteResult(listOf(second, first))

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(2, result.counts.succeeded)
        assertEquals(listOf(first.path, second.path), transport.start().paths())
        assertEquals(listOf(first.path, second.path, first.path, second.path), transport.infoPaths())
    }

    @Test
    fun `旧路径删除入口也保留空白且不会回读近似文件`() = runBlocking {
        val transport = PathTransport(START, FINISHED, EMPTY)
        val path = "/share/ 报告.txt "

        val result = repository(transport).deleteResult(listOf(path, path))

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(listOf(path), transport.start().paths())
        assertEquals(listOf(path), transport.infoPaths())
    }

    @Test
    fun `带空格父目录中新建子目录保留父目录身份`() = runBlocking {
        val parent = item("/share/Folder ", directory = true)
        val created = item("${parent.path}/New", directory = true)
        val transport = PathTransport(info(parent), EMPTY, SUCCESS, info(created))

        val result = repository(transport).createFolderResult(parent, "New")

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(parent.path, transport.fields.single { it["method"] == "create" }["folder_path"])
        assertEquals(listOf(parent.path, created.path), transport.infoPaths())
    }

    @Test
    fun `重命名末尾空格文件不操作普通同名文件`() = runBlocking {
        val source = item("/share/Old.txt ")
        val target = item("/share/New.txt")
        val transport = PathTransport(
            info(source), info(item("/share", true)), EMPTY, SUCCESS,
            info(item("/share/Old.txt")), info(target),
        )

        val result = repository(transport).renameResult(source, "New.txt")

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(source.path, transport.fields.single { it["method"] == "rename" }["path"])
        assertEquals(listOf(source.path, "/share", target.path), transport.infoPaths())
    }

    @Test
    fun `批量复制同名不同空格文件到带空格目录保持两个目标`() = runBlocking {
        val sources = listOf(item("/share/a.txt"), item("/share/a.txt "))
        val destination = item("/share/Target ", true)
        val targets = sources.map { it.copy(path = "${destination.path}/${it.name}") }
        val transport = PathTransport(
            info(destination), info(sources[0]), info(sources[1]), EMPTY, EMPTY,
            START, FINISHED, info(targets[0]), info(targets[1]),
        )

        val result = repository(transport).copyResult(sources, destination)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(2, result.counts.succeeded)
        assertEquals(sources.map(FileItem::path), transport.start().paths())
        assertEquals(destination.path, transport.start()["dest_folder_path"])
        assertEquals(targets.map(FileItem::path), transport.infoPaths().takeLast(2))
    }

    @Test
    fun `移动带空格文件只读取原源路径和原目标`() = runBlocking {
        val source = item("/share/a.txt ")
        val destination = item("/share/Target ", true)
        val target = source.copy(path = "${destination.path}/${source.name}")
        val transport = PathTransport(info(destination), info(source), EMPTY, START, FINISHED, EMPTY, info(target))

        val result = repository(transport).moveResult(listOf(source), destination)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(listOf(source.path), transport.start().paths())
        assertEquals("true", transport.start()["remove_src"])
        assertEquals(listOf(source.path, target.path), transport.infoPaths().takeLast(2))
    }

    @Test
    fun `分享末尾空格文件绑定原文件与返回链接`() = runBlocking {
        val source = item("/share/report.txt ")
        val links = """{"success":true,"data":{"links":[{"id":"fixture-link","error":0,"has_password":false,"date_available":0,"date_expired":0,"path":"${source.path}","url":"https://example.invalid/share"}],"total":1}}"""
        val transport = PathTransport(info(source), """{"success":true,"data":{"links":[],"total":0}}""", links, links)

        val outcome = repository(transport).createShareLinkResult(source)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, outcome.result.status)
        assertEquals(source.path, outcome.link?.path)
        assertEquals(listOf(source.path), transport.fields.single { it["method"] == "create" }.paths())
    }

    @Test
    fun `压缩保留两个源文件与带空格输出目录`() = runBlocking {
        val sources = listOf(item("/share/a.txt"), item("/share/a.txt "))
        val destination = item("/share/Target ", true)
        val target = item("${destination.path}/archive.zip")
        val transport = PathTransport(info(destination), info(sources[0]), info(sources[1]), EMPTY, START, FINISHED, info(target))

        val result = repository(transport).compressResult(sources, destination, target.path, ArchiveFormat.ZIP, ArchiveCompressionLevel.MODERATE)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(sources.map(FileItem::path), transport.start().paths())
        assertEquals(target.path, transport.start()["dest_file_path"])
        assertEquals(target.path, transport.infoPaths().last())
    }

    @Test
    fun `解压读取和提交保留源归档和目标目录的末尾空格`() = runBlocking {
        val source = item("/share/archive.zip ")
        val destination = item("/share/Target ", true)
        val target = item("${destination.path}/a.txt ")
        val members = """{"success":true,"data":{"items":[{"itemid":1,"name":"a.txt ","path":"a.txt ","is_dir":false}]}}"""
        val transport = PathTransport(info(destination), info(source), members, EMPTY, START, FINISHED, info(target))

        val result = repository(transport).extractResult(source, destination)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(source.path, transport.start()["file_path"])
        assertEquals(destination.path, transport.start()["dest_folder_path"])
        assertEquals(source.path, transport.fields.single { it["api"] == "SYNO.FileStation.Extract" && it["method"] == "list" }["file_path"])
        assertEquals(target.path, transport.infoPaths().last())
    }

    @Test
    fun `无效路径不能裁剪或解析为另一个写目标`() = runBlocking {
        val invalid = listOf("", " /share/a", "share/a", "/share/./a", "/share/../a", "/share//a")
        for (path in invalid) {
            val transport = PathTransport()
            val repo = repository(transport)
            val results = listOf(
                repo.createFolderResult(path, "New"), repo.renameResult(path, "New"),
                repo.deleteResult(listOf(path)), repo.copyResult(listOf(path), "/share/target"),
                repo.moveResult(listOf("/share/a"), path), repo.createShareLinkResult(path).result,
                repo.compressResult(listOf(path), "/share/out.zip", ArchiveFormat.ZIP, ArchiveCompressionLevel.MODERATE),
                repo.extractResult(path, "/share/target"),
            )
            for (result in results) {
                assertEquals(path, MutationErrorCategory.VALIDATION, result.errorCategory)
                assertFalse(result.submitted)
            }
            assertTrue(path, transport.fields.isEmpty())
        }
        val transport = PathTransport()
        assertFalse(repository(transport).deleteResult(listOf("/")).submitted)
        assertTrue(transport.fields.isEmpty())
    }

    private fun repository(transport: Interceptor) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(transport).build()),
        listOf("List", "CreateFolder", "Rename", "CopyMove", "Delete", "Sharing", "Compress", "Extract")
            .associate { short -> "SYNO.FileStation.$short".let { it to ApiCapability(it, "entry.cgi", 1, 3) } },
    )

    private fun item(path: String, directory: Boolean = false) = FileItem(
        path, path.substringAfterLast('/'), directory, size = if (directory) 0 else 12,
        modifiedAtEpochSeconds = 100, owner = "tester", canRead = true, canWrite = true, canDelete = true,
    )

    private fun info(item: FileItem) = """{"success":true,"data":{"files":[{
        "path":"${item.path}","name":"${item.name}","isdir":${item.isDirectory},"size":${item.size},
        "additional":{"owner":{"user":"tester"},"time":{"mtime":100},"perm":{"read":true,"write":true,"delete":true}}
    }],"total":1}}"""

    private fun Map<String, String>.paths() = Json.parseToJsonElement(checkNotNull(this["path"]))
        .jsonArray.map { it.jsonPrimitive.content }

    private class PathTransport(vararg responses: String) : Interceptor {
        private val pending = ArrayDeque(responses.toList())
        val fields = mutableListOf<Map<String, String>>()
        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            val body = request.body as FormBody
            fields += (0 until body.size).associate { body.name(it) to body.value(it) }
            return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(checkNotNull(pending.removeFirstOrNull()) { "缺少路径身份合成响应" }.toResponseBody("application/json".toMediaType())).build()
        }
        fun start() = fields.single { it["method"] == "start" }
        fun infoPaths() = fields.filter { it["method"] == "getinfo" }
            .flatMap { Json.parseToJsonElement(checkNotNull(it["path"])).jsonArray.map { value -> value.jsonPrimitive.content } }
    }

    private companion object {
        const val EMPTY = """{"success":true,"data":{"files":[],"total":0}}"""
        const val SUCCESS = """{"success":true,"data":{}}"""
        const val START = """{"success":true,"data":{"taskid":"fixture-task"}}"""
        const val FINISHED = """{"success":true,"data":{"finished":true}}"""
    }
}

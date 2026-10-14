package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.PERSONAL_PHOTO_SPACE
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoItemKind
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.FormBody
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoRepositoryTest {
    @Test
    fun `照片分页只使用公开FileStation并映射文件夹图片和视频`() = runBlocking {
        val transport = PhotoListInterceptor(
            listResponse(
                total = 4,
                files = """
                    {"name":"Trips","path":"/home/Photos/Trips","isdir":true},
                    {"name":"a.jpg","path":"/home/Photos/a.jpg","isdir":false},
                    {"name":"clip.mp4","path":"/home/Photos/clip.mp4","isdir":false},
                    {"name":"note.txt","path":"/home/Photos/note.txt","isdir":false}
                """.trimIndent(),
            ),
        )

        val page = PhotoRepository(repository(transport)).page(
            PERSONAL_PHOTO_SPACE,
            PERSONAL_PHOTO_SPACE.rootPath,
            limit = 20,
        )

        assertEquals(listOf(PhotoItemKind.FOLDER, PhotoItemKind.IMAGE, PhotoItemKind.VIDEO), page.items.map { it.kind })
        assertEquals(4, page.nextOffset)
        assertTrue(!page.hasMore)
        val request = transport.requests.single()
        val fields = request.formFields()
        assertEquals("SYNO.FileStation.List", fields["api"])
        assertEquals("list", fields["method"])
        assertEquals("/home/Photos", fields["folder_path"])
        assertEquals("0", fields["offset"])
        assertEquals("20", fields["limit"])
    }

    @Test
    fun `首个源分页没有媒体时继续扫描并保持源偏移量`() = runBlocking {
        val transport = PhotoListInterceptor(
            listResponse(2, """{"name":"note.txt","path":"/home/Photos/note.txt","isdir":false}"""),
            listResponse(2, """{"name":"a.jpg","path":"/home/Photos/a.jpg","isdir":false}"""),
        )

        val page = PhotoRepository(repository(transport)).page(
            PERSONAL_PHOTO_SPACE,
            PERSONAL_PHOTO_SPACE.rootPath,
            limit = 1,
        )

        assertEquals("a.jpg", page.items.single().file.name)
        assertEquals(2, page.nextOffset)
        assertEquals(listOf("0", "1"), transport.requests.map { it.formFields()["offset"] })
    }

    @Test(expected = IllegalArgumentException::class)
    fun `拒绝读取所选照片空间之外的目录`() {
        runBlocking {
            PhotoRepository(repository(PhotoListInterceptor())).page(
                PERSONAL_PHOTO_SPACE,
                "/photo",
            )
        }
    }

    @Test
    fun `外链单项只从当前照片空间读取并映射支持的媒体`() = runBlocking {
        val transport = PhotoListInterceptor(
            listResponse(
                1,
                """{"name":"target.jpg","path":"/home/Photos/target.jpg","isdir":false}""",
            ),
        )

        val item = PhotoRepository(repository(transport)).item(
            PERSONAL_PHOTO_SPACE,
            "/home/Photos/target.jpg",
        )

        assertEquals(PhotoItemKind.IMAGE, item?.kind)
        assertEquals("getinfo", transport.requests.single().formFields()["method"])
    }

    @Test(expected = IllegalArgumentException::class)
    fun `外链单项拒绝越过照片空间边界`() {
        runBlocking {
            PhotoRepository(repository(PhotoListInterceptor())).item(
                PERSONAL_PHOTO_SPACE,
                "/photo/target.jpg",
            )
        }
    }

    @Test
    fun `时间轴递归扫描且子文件夹失败不遮蔽已有内容`() = runBlocking {
        val transport = PhotoListInterceptor(
            listResponse(
                2,
                """
                    {"name":"Private","path":"/home/Photos/Private","isdir":true},
                    {"name":"root.jpg","path":"/home/Photos/root.jpg","isdir":false,"additional":{"time":{"mtime":1704067200}}}
                """.trimIndent(),
            ),
            """{"success":false,"error":{"code":408}}""",
        )
        val progress = mutableListOf<io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoTimelineProgress>()

        val timeline = PhotoRepository(repository(transport)).scanTimeline(PERSONAL_PHOTO_SPACE) {
            progress += it
        }

        assertEquals("root.jpg", timeline.items.single().file.name)
        assertEquals(1, timeline.scannedFolderCount)
        assertEquals(1, timeline.failedFolderCount)
        assertTrue(timeline.isComplete)
        assertTrue(progress.isNotEmpty())
        val paths = transport.requests.map { it.formFields()["folder_path"] }
        assertEquals(listOf("/home/Photos", "/home/Photos/Private"), paths)
    }

    @Test
    fun `删除复查会继续分页避免把后续项目误判为不存在`() = runBlocking {
        val transport = PhotoListInterceptor(
            listResponse(2, """{"name":"a.jpg","path":"/home/Photos/a.jpg","isdir":false}"""),
            listResponse(2, """{"name":"target.jpg","path":"/home/Photos/target.jpg","isdir":false}"""),
        )

        val exists = repository(transport).itemExists("/home/Photos/target.jpg")

        assertTrue(exists)
        assertEquals(listOf("0", "1"), transport.requests.map { it.formFields()["offset"] })
    }

    private fun repository(interceptor: Interceptor): DsmRepository = authorizedRepository(
        profile = NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        session = DsmSession("test", "test-session", "test-token"),
        api = DsmApiClient(
            OkHttpClient.Builder()
                .retryOnConnectionFailure(false)
                .addInterceptor(interceptor)
                .build(),
        ),
        capabilities = mapOf(
            "SYNO.FileStation.List" to ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2),
        ),
    )

    private fun listResponse(total: Int, files: String): String =
        """{"success":true,"data":{"offset":0,"total":$total,"files":[$files]}}"""

    private fun Request.formFields(): Map<String, String> {
        val form = body as FormBody
        return (0 until form.size).associate { form.name(it) to form.value(it) }
    }
}

private class PhotoListInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val body = pending.removeFirstOrNull() ?: error("缺少合成照片列表响应")
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }
}

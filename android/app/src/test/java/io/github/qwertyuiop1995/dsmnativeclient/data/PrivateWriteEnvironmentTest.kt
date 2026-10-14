package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.prepareAction
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okio.Buffer
import java.net.URLDecoder
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

/** 通过真实组合根与认证传输检查实际权限与无版本白名单的写入边界，全部响应为合成数据。 */
class PrivateWriteEnvironmentTest {
    @Test fun `照片普通账号在未知DSM与套件版本下仍可提交且不读取系统版本`() = runBlocking {
        for (version in listOf("1.9.1-10911", "future", "")) {
            val f = Fixture(administrator = false); f.photosVersion = version; f.ready(); f.system = system("DSM 7.3")
            var saved = false
            f.onRequest = { if (it.method == "create") assertTrue(saved) }
            f.repo.synologyPhotos.performPhotoAlbum(album()) { saved = true }
            assertEquals(listOf("create"), f.writes.map { it.method })
            assertNoVersionRequests(f)
        }
    }

    @Test fun `照片版本字段缺失不关闭原有写能力`() = runBlocking {
        val f = Fixture(administrator = false); f.photosVersion = null; f.ready()
        f.repo.synologyPhotos.performPhotoAlbum(album()) {}
        assertEquals(1, f.writes.size); assertNoVersionRequests(f)
    }

    @Test fun `系统信息或套件清单不可读取不阻止照片与Chat业务请求`() = runBlocking {
        val f = Fixture(administrator = false).ready()
        f.onRequest = { check(it.api !in setOf("SYNO.Core.System", "SYNO.Core.Package")) }
        f.repo.synologyPhotos.performPhotoAlbum(album()) {}
        f.repo.chatRepository.gateway.call("SYNO.Chat.Post", "create", 5, oneShot = true)
        assertEquals(2, f.writes.size); assertNoVersionRequests(f)
    }

    @Test fun `照片写前保存失败仍然零写且不会因移除版本门绕过持久边界`() = runBlocking {
        val f = Fixture(administrator = false).ready()
        assertTrue(runCatching { f.repo.synologyPhotos.performPhotoAlbum(album()) { error("synthetic storage failure") } }.isFailure)
        assertTrue(f.writes.isEmpty()); assertNoVersionRequests(f)
    }

    @Test fun `照片实际授权撤销后停止写入`() = runBlocking {
        val f = Fixture(administrator = false).ready(); f.allowed = false; f.repo.refreshAccess()
        val result = f.repo.synologyPhotos.performPhotoAlbum(album()) {}
        assertFalse(result.finished); assertEquals(SynologyPhotoAlbumPhase.PENDING, result.phase)
        assertTrue(f.writes.isEmpty()); assertNoVersionRequests(f)
    }

    @Test fun `未知版本的历史照片操作仍可只读恢复且不重发创建`() = runBlocking {
        val f = Fixture(administrator = false).ready(); f.system = system("DSM 7.3")
        val pending = album().copy(phase = SynologyPhotoAlbumPhase.PENDING)
        assertEquals(pending, f.repo.synologyPhotos.reviewPhotoAlbum(pending) {})
        assertTrue(f.writes.isEmpty()); assertNoVersionRequests(f)
    }

    @Test fun `Chat普通账号可以发送及同步已读而不读取系统或套件版本`() = runBlocking {
        val f = Fixture(administrator = false).ready(); f.system = system("DSM 7.3"); f.chatVersion = "future"
        val gateway = f.repo.chatRepository.gateway
        for ((api, method) in listOf("SYNO.Chat.Post" to "create", "SYNO.Chat.Channel" to "view", "SYNO.Chat.Post.Subscribe" to "view"))
            gateway.call(api, method, 5, oneShot = method == "create")
        assertEquals(3, f.writes.size); assertNoVersionRequests(f)
    }

    @Test fun `Chat实际模块权限撤销仍在业务请求前拒绝`() = runBlocking {
        val f = Fixture(administrator = false).ready(); f.allowed = false; f.repo.refreshAccess()
        val error = runCatching { f.repo.chatRepository.gateway.call("SYNO.Chat.Post", "create", 5, oneShot = true) }.exceptionOrNull()
        assertEquals(DsmErrorKind.PERMISSION_DENIED, (error as DsmFailure).kind)
        assertTrue(f.writes.isEmpty()); assertNoVersionRequests(f)
    }

    @Test fun `Chat仍拒绝实际接口不支持的参数版本`() = runBlocking {
        val f = Fixture(administrator = false).ready()
        assertTrue(runCatching { f.repo.chatRepository.gateway.call("SYNO.Chat.Post", "create", 99, oneShot = true) }.isFailure)
        assertTrue(f.writes.isEmpty()); assertNoVersionRequests(f)
    }

    private fun assertNoVersionRequests(f: Fixture) {
        assertFalse(f.requests.any { it.api in setOf("SYNO.Core.System", "SYNO.Core.Package", "SYNO.Foto.Setting.Admin") })
    }

    private data class Call(val api: String, val method: String)
    private class Fixture(administrator: Boolean = true) : Interceptor {
        var system = system(); var photosVersion: String? = "1.8.2-10090"; var chatVersion = "2.4.1-22111"; var packageError: Int? = null
        var allowed = true
        val requests = mutableListOf<Call>(); var onRequest: (Call) -> Unit = {}
        val writes get() = requests.filter { it.method !in setOf("get", "list", "me", "info") }
        private val profile = NasProfile("synthetic-profile", "Synthetic", "https://nas.example.invalid", "synthetic-user")
        private val capabilities = (listOf("SYNO.Core.System", "SYNO.Core.Package", "SYNO.Chat.Post", "SYNO.Chat.Channel", "SYNO.Chat.Post.Subscribe", "SYNO.Chat.User") +
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Album", "Browse.NormalAlbum", "Browse.Item").map { "SYNO.Foto.$it" })
            .associateWith { ApiCapability(it, "entry.cgi", 1, 8, "JSON") }
        private val api = DsmApiClient(OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor(this).build())
        val repo = DsmRepository(profile, DsmSession(profile.id, "synthetic-session", "synthetic-token"), api, capabilities,
            WorkspaceAccessReader(capabilities, { DesktopAppPrivileges(DesktopApplication.entries.associateWith { allowed }, administrator) }, {}, { if (!allowed) throw DsmFailure(105, "Synthetic", "Retry", kind = DsmErrorKind.PERMISSION_DENIED) }))
        suspend fun ready(): Fixture { repo.refreshAccess(); repo.synologyPhotos.access(); requests.clear(); return this }
        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request(); val buffer = Buffer(); request.body!!.writeTo(buffer)
            val fields = buffer.readUtf8().split('&').associate { value ->
                val parts = value.split('=', limit = 2); URLDecoder.decode(parts[0], "UTF-8") to URLDecoder.decode(parts[1], "UTF-8")
            }
            fun field(name: String) = fields.getValue(name)
            val call = Call(field("api"), field("method")); requests += call; onRequest(call)
            val data = when (call.api) {
                "SYNO.Core.System" -> system
                "SYNO.Core.Package" -> obj("""{"total":1,"packages":[{"id":"Chat","name":"Chat","version":"$chatVersion","status":"running","startable":true,"available_operation":[],"dsm_apps":[]}]}""")
                "SYNO.Foto.UserInfo" -> obj("""{"enabled":true,"id":41}""")
                "SYNO.Foto.Setting.User" -> obj("""{"enable_home_service":true,"team_space_permission":"none"}""")
                "SYNO.Foto.Setting.Admin" -> if (photosVersion == null) obj("{}") else obj("""{"package_version":"$photosVersion"}""")
                "SYNO.Foto.Setting.TeamSpace" -> obj("""{"enabled":false}""")
                "SYNO.Foto.Browse.NormalAlbum" -> obj("{}") // 无返回编号保持未知，不以此用例宣称创建完成。
                else -> obj("""{"list":[]}""")
            }
            val text = if (call.api == "SYNO.Foto.Setting.Admin" && packageError != null) """{"success":false,"error":{"code":$packageError}}"""
                else """{"success":true,"data":$data}"""
            return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .body(text.toResponseBody("application/json".toMediaType())).build()
        }
    }
    companion object {
        private fun obj(text: String) = Json.parseToJsonElement(text).jsonObject
        private fun system(firmware: String = "DSM 7.2.1-69057 Update 12") = obj("""{"firmware_ver":"$firmware","buildnumber":69057,"smallfixnumber":12}""")
        private fun album() = SynologyPhotoAlbumCheckpoint(profileId = "synthetic-profile", userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic")
    }
}

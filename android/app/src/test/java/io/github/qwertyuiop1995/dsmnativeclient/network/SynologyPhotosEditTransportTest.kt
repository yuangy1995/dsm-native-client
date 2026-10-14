package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosRepository
import java.io.IOException
import java.net.URLDecoder
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotosEditTransportTest {
    @Test fun `Photos表单外层标记单次发送并保留JSON字段和同源请求头`() = runBlocking {
        var request: Request? = null
        val api = api { current -> request = current; response(current) }
        val fields = mapOf("id" to "[91,92]", "description" to "\"Synthetic\\n测试\"")
        api.call(profile, session, capability, "set", fields, oneShot = true)
        val sent = request!!
        assertTrue(sent.body!!.isOneShot()); assertNull(sent.url.query)
        val sink = Buffer(); sent.body!!.writeTo(sink)
        val form = sink.readUtf8().split('&').associate { part ->
            val values = part.split('=', limit = 2); URLDecoder.decode(values[0], "UTF-8") to URLDecoder.decode(values[1], "UTF-8")
        }
        assertEquals(fields["description"], form["description"]); assertEquals("[91,92]", form["id"])
        assertEquals("2", form["version"]); assertEquals("set", form["method"])
        assertEquals("id=synthetic-session", sent.header("Cookie")); assertEquals("synthetic-token", sent.header("X-SYNO-TOKEN"))
    }
    @Test fun `创建标签同样使用单次发送正文且矛盾回执不接受`() = runBlocking {
        val requests = mutableListOf<Request>()
        val api = api { request -> requests += request; response(request, """{"success":true,"error":{"code":105},"data":{"tag":{"id":51,"name":"Synthetic"}}}""") }
        try {
            api.call(profile, session, capability.copy(name = "SYNO.Foto.Browse.GeneralTag", minVersion = 1, maxVersion = 1), "create",
                mapOf("name" to "\"Synthetic\""), oneShot = true); fail()
        } catch (error: DsmFailure) { assertEquals(DsmErrorKind.INVALID_RESPONSE, error.kind) }
        assertEquals(1, requests.size); assertTrue(requests.single().body!!.isOneShot())
    }
    @Test fun `授权失败在发送之前停止`() = runBlocking {
        var sent = 0
        val api = api { request -> sent++; response(request) }.authorized({ throw IOException("synthetic denial") })
        try { api.call(profile, session, capability, "set", mapOf("id" to "[91]", "rating" to "4"), oneShot = true); fail() }
        catch (_: IOException) { }
        assertEquals(0, sent)
    }
    @Test fun `未选择单次发送的其他调用保持既有正文策略`() = runBlocking {
        var oneShot: Boolean? = null
        val api = api { request -> oneShot = request.body!!.isOneShot(); response(request) }
        api.call(profile, session, capability.copy(name = "SYNO.FileStation.Info"), "get")
        assertEquals(false, oneShot)
    }
    @Test fun `生产Photos仓储实际装配单次发送并回读评分`() = runBlocking {
        var rating = 0
        val requests = mutableListOf<Request>()
        val api = api { request ->
            requests += request
            val sink = Buffer(); request.body!!.writeTo(sink)
            val fields = sink.readUtf8().split('&').associate {
                val pair = it.split('=', limit = 2); URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair[1], "UTF-8")
            }
            val body = when {
                fields.getValue("api").endsWith("UserInfo") -> """{"enabled":true,"id":41}"""
                fields.getValue("api").endsWith("Setting.User") -> """{"enable_home_service":true,"team_space_permission":"none"}"""
                fields.getValue("api").endsWith("Setting.Admin") -> """{"package_version":"1.8.2-10090"}"""
                fields.getValue("api").endsWith("Setting.TeamSpace") -> """{"enabled":false}"""
                fields.getValue("api").endsWith("Browse.Folder") -> """{"folder":{"id":9,"additional":{"access_permission":{"view":true,"manage":true}}}}"""
                fields["method"] == "set" -> { rating = fields.getValue("rating").toInt(); "{}" }
                else -> """{"list":[{"id":91,"filename":"synthetic.jpg","filesize":4,"time":1000,"indexed_time":900,"folder_id":9,"type":"photo","additional":{"rating":$rating}}]}"""
            }
            response(request, """{"success":true,"data":$body}""")
        }
        val capabilities = listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Item", "Browse.Folder")
            .associate { "SYNO.Foto.$it" to ApiCapability("SYNO.Foto.$it", "entry.cgi", 1, 5, "JSON") }
        val repository = SynologyPhotosRepository(profile, session, api, capabilities)
        repository.access()
        val photo = SynologyPhoto(SynologyPhotoId(profile.id, SynologyPhotoSpace.PERSONAL, 91), "synthetic.jpg", 4, 1000.0, 900.0, 9, "photo")
        val row = SynologyPhotoEditCheckpoint(profileId = profile.id, userId = 41, space = SynologyPhotoSpace.PERSONAL,
            targets = listOf(SynologyPhotoEditTarget(photo)), edit = SynologyPhotoEdit.Rating(4))
        assertEquals(SynologyPhotoEditPhase.COMPLETED, repository.performPhotoEdit(row) {}.phase)
        assertTrue(requests.isNotEmpty()); assertTrue(requests.all { it.body!!.isOneShot() && it.url.query == null })
    }
    private fun api(block: (Request) -> Response) = DsmApiClient(OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .retryOnConnectionFailure(false).addInterceptor { block(it.request()) }.build())
    private fun response(request: Request, value: String = """{"success":true,"data":{}}""") = Response.Builder().request(request)
        .protocol(Protocol.HTTP_1_1).code(200).message("synthetic").body(value.toResponseBody("application/json".toMediaType())).build()
    private companion object {
        val profile = NasProfile("profile-edit", "Synthetic", "https://photos.example.invalid", "synthetic")
        val session = DsmSession(profile.id, "synthetic-session", "synthetic-token")
        val capability = ApiCapability("SYNO.Foto.Browse.Item", "entry.cgi", 2, 2, "JSON")
    }
}

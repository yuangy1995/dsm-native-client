package io.github.qwertyuiop1995.dsmnativeclient

import android.graphics.Bitmap
import android.graphics.Color
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotosMediaTransport
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.photos.SynologyPhotosLibrary
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.*
import org.junit.Assert.*

/** 原生图库与实际 Photos 仓储；所有接口响应和媒体均为合成夹具，禁止真实网络。 */
class SynologyPhotosSourceUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var model: SynologyPhotosModel
    private data class Request(val name: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Request>()
    private val mediaCalls = CopyOnWriteArrayList<okhttp3.Request>()
    private var home = true
    private var team = "entry"
    private var empty = false
    private var fail = false
    private var gate: CompletableDeferred<Unit>? = null

    @After fun cleanup() { gate?.complete(Unit); if (::model.isInitialized) model.close(); scope.cancel() }

    @Test fun 双来源在现有工具栏切换且搜索目录和媒体沿用选定来源() {
        show(); ready()
        compose.onNodeWithTag("photos_source").assertIsDisplayed().assertHeightIsAtLeast(48.dp).performClick()
        compose.onNodeWithText(text(R.string.sp_source_shared)).performClick(); ready()
        compose.runOnIdle { assertEquals(SynologyPhotoSpace.SHARED, model.state.value.navigation.space) }
        capture("shared-timeline")
        photo("shared.jpg").performClick()
        compose.waitUntil(10_000) { model.preview.state.value.photo != null && !model.preview.state.value.loading }
        capture("preview-result")
        assertNull(model.preview.state.value.error?.stackTraceToString(), model.preview.state.value.error)
        assertNotNull(model.preview.state.value.image)
        compose.onNodeWithContentDescription(text(R.string.sp_delete_action)).assertDoesNotExist()
        assertTrue(mediaCalls.any { it.url.encodedPath == "/synofoto/api/v2/t/Thumbnail/get" })
        capture("shared-preview")
        compose.onNodeWithContentDescription(text(R.string.go_up)).performClick()
        compose.onNode(hasSetTextAction()).performTextInput("missing")
        compose.onNode(hasSetTextAction()).performImeAction(); ready()
        compose.onNodeWithText(text(R.string.sp_library_no_results)).assertIsDisplayed()
        assertTrue(calls.any { it.name == "SYNO.FotoTeam.Search.Search" && it.fields["keyword"] == "\"missing\"" })
        capture("shared-filtered-empty")
        section(R.string.sp_library_folders).performClick(); ready()
        assertTrue(calls.any { it.name == "SYNO.FotoTeam.Browse.Folder" })
        assertEquals(SynologyPhotoSpace.SHARED, model.state.value.navigation.folders.single().space)
        capture("shared-folders")
    }

    @Test fun 仅共享来源直接可用且不显示无用来源选择器() {
        home = false
        show(); ready()
        compose.onNodeWithTag("photos_source").assertDoesNotExist()
        photo("shared.jpg").assertIsDisplayed()
        assertEquals(SynologyPhotoSpace.SHARED, model.state.value.navigation.space)
        capture("shared-only")
    }

    @Test fun 没有原来源仍可进入混合相册而每张媒体保留相册权限() {
        home = false; team = "none"
        show(); ready()
        compose.onNodeWithTag("photos_source").assertDoesNotExist()
        compose.onNodeWithText(text(R.string.sp_library_timeline)).assertDoesNotExist()
        compose.onNodeWithText(text(R.string.sp_library_folders)).assertDoesNotExist()
        compose.onNodeWithText("Synthetic album").performClick(); ready()
        assertEquals(listOf(SynologyPhotoSpace.PERSONAL, SynologyPhotoSpace.SHARED), model.state.value.items.map { it.id.space })
        photo("album-shared.jpg").performClick()
        compose.waitUntil(10_000) { model.preview.state.value.photo != null && !model.preview.state.value.loading }
        capture("preview-result")
        assertNull(model.preview.state.value.error?.stackTraceToString(), model.preview.state.value.error)
        assertNotNull(model.preview.state.value.image)
        assertEquals(7L, model.preview.state.value.photo?.albumContext?.albumId)
        compose.onNodeWithContentDescription(text(R.string.sp_delete_action)).assertDoesNotExist()
        assertTrue(calls.filter { it.name.endsWith("Browse.Item") }.all { it.name == "SYNO.Foto.Browse.Item" && it.fields["album_id"] == "7" })
        assertTrue(mediaCalls.all { it.url.encodedPath == "/synofoto/api/v2/p/Thumbnail/get" && it.url.queryParameter("album_id") == "7" })
        capture("album-shared-preview")
    }

    @Test fun 加载失败重试与空内容均有真实状态且权限收回会切换到允许来源() {
        gate = CompletableDeferred()
        show()
        compose.waitUntil(10_000) { model.state.value.loading && calls.any { it.name.endsWith("Browse.Timeline") } }
        capture("loading")
        fail = true; gate!!.complete(Unit); gate = null
        compose.waitUntil(10_000) { model.state.value.error != null && !model.state.value.loading }
        compose.onNodeWithText(text(R.string.sp_service_invalid_response)).assertIsDisplayed()
        capture("error")
        fail = false; empty = true
        compose.onNodeWithText(text(R.string.sp_retry)).performClick(); ready()
        compose.onNodeWithText(text(R.string.sp_library_empty)).assertIsDisplayed(); capture("empty")
        home = false; empty = false
        compose.onNodeWithContentDescription(text(R.string.sp_library_refresh)).performClick(); ready()
        photo("shared.jpg").assertIsDisplayed()
        compose.onNodeWithTag("photos_source").assertDoesNotExist()
        assertEquals(SynologyPhotoSpace.SHARED, model.state.value.navigation.space)
    }

    @Test fun 共享entry相册页不显示仅管理者可用的全局分类() {
        home = false; team = "entry"
        show(); ready()
        section(R.string.sp_library_albums).performClick(); ready()
        compose.onNodeWithText("Synthetic album").assertIsDisplayed()
        assertTrue(model.state.value.categories.isEmpty())
        assertTrue(calls.none { it.name.endsWith("Browse.Category") })
        capture("entry-albums")
    }

    private fun show() {
        val profile = NasProfile("photos-source-fixture", "Photos NAS", "https://photos.example.invalid", "synthetic")
        val session = DsmSession(profile.id, "synthetic")
        val bitmap = Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.rgb(62, 137, 177)) }
        val image = ByteArrayOutputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it); it.toByteArray() }; bitmap.recycle()
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request(); mediaCalls += request
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .header("Content-Type", "image/png").body(image.toResponseBody("image/png".toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, session, profile.address, http)
        val suffixes = listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Folder",
            "Browse.Album", "Browse.Category", "Search.Search", "Search.Filter", "Sharing.Misc", "PhotoRequest")
        val capabilities = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix -> suffixes.map { "$prefix.$it" } }
            .associateWith { ApiCapability(it, "entry.cgi", 1, 5, "JSON") }
        val repository = SynologyPhotosRepository(profile.id, capabilities, { capability, method, fields ->
            val request = Request(capability.name, method, fields); calls += request
            if (capability.name.endsWith("Browse.Timeline")) gate?.await()
            response(request)
        }, media, canDeleteOriginals = true)
        model = SynologyPhotosModel(repository, scope)
        compose.setContent { LanStashTheme {
            Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, canBackup = true, onBackup = {}) }
            }
        } }
    }

    private fun response(request: Request): JsonObject {
        val source = request.name.startsWith("SYNO.FotoTeam.")
        val owner = if (source) 0 else 41
        val name = if (source) "shared.jpg" else "personal.jpg"
        val json = when {
            request.name.endsWith("UserInfo") -> """{"enabled":true,"id":41}"""
            request.name.endsWith("Setting.User") -> """{"enable_home_service":$home,"team_space_permission":"$team"}"""
            request.name.endsWith("Setting.Admin") -> """{"package_version":"synthetic"}"""
            request.name.endsWith("Setting.TeamSpace") -> """{"enabled":true}"""
            fail -> throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
            request.name.endsWith("Browse.Timeline") -> if (empty) """{"section":[]}""" else """{"section":[{"list":[{"year":2025,"month":1,"day":1,"item_count":1}]}]}"""
            request.method == "get_search_timeline" -> """{"section":[]}"""
            request.name.endsWith("Browse.Category") -> """{"list":[]}"""
            request.name.endsWith("Browse.Album") -> """{"list":[{"id":7,"name":"Synthetic album"}]}"""
            request.name.endsWith("Browse.Folder") && request.method == "get" -> """{"folder":{"id":5,"name":"/","parent":0,"additional":{"access_permission":{"view":true}}}}"""
            request.name.endsWith("Browse.Folder") -> """{"list":[]}"""
            request.name.endsWith("Browse.Item") && request.fields["album_id"] == "7" -> when {
                request.method == "get" -> """{"list":[${item(12, 0, "album-shared.jpg")}]}"""
                else -> """{"list":[${item(11, 42, "album-personal.jpg")},${item(12, 0, "album-shared.jpg")}]}"""
            }
            request.name.endsWith("Browse.Item") -> """{"list":[${item(11, owner.toLong(), name)}]}"""
            else -> error("Unexpected synthetic Photos request: ${request.name}")
        }
        return Json.parseToJsonElement(json).jsonObject
    }

    private fun item(id: Long, owner: Long, filename: String) = """{"id":$id,"filename":"$filename","filesize":4,"time":1735689600,"indexed_time":1735689600,"folder_id":5,"owner_user_id":$owner,"type":"photo","additional":{"thumbnail":{"unit_id":$id,"cache_key":"r"}}}"""
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun text(id: Int) = context.getString(id)
    private fun photo(name: String) = compose.onNodeWithContentDescription(context.getString(R.string.photo_thumbnail_description, name))
    private fun section(id: Int) = compose.onNode(hasText(text(id)) and hasClickAction())
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onNode(isDialog())
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-source-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}

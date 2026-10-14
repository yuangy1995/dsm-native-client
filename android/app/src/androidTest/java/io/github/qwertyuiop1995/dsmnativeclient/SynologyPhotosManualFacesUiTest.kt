package io.github.qwertyuiop1995.dsmnativeclient

import android.graphics.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoManualFacesCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotosMediaTransport
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.ui.photos.SynologyPhotosLibrary
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.*
import org.junit.Assert.*

/** 真实编辑入口、画布、JPEG裁剪和媒体上传链；全部图像和人物数据为合成夹具。 */
class SynologyPhotosManualFacesUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("manual-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private var epoch by mutableIntStateOf(0)
    private val editor get() = model.manualFaces!!
    private data class Call(val api: String, val method: String, val fields: Map<String, String>) {
        fun ids(key: String) = Json.parseToJsonElement(fields.getValue(key)).jsonArray.map { it.jsonPrimitive.long }
        fun id(key: String) = fields.getValue(key).toLong()
        fun text(key: String) = Json.parseToJsonElement(fields.getValue(key)).jsonPrimitive.content
    }
    private val calls = CopyOnWriteArrayList<Call>(); private val events = CopyOnWriteArrayList<String>()
    private val writes get() = calls.filter { it.method in setOf("add_face", "delete_face", "separate") }
    private val faces = ConcurrentHashMap<Long, JsonObject>().apply { put(101, face(101, 1, "Synthetic A", bounds(.1, .1, .3, .4))) }
    private val people = ConcurrentHashMap<Long, JsonObject>().apply { put(1, person(1, "Synthetic A")); put(2, person(2, "Synthetic B")) }
    private val uploads = ConcurrentHashMap<Long, ByteArray>()
    private var gate: CompletableDeferred<Unit>? = null
    @Volatile private var failRead = false
    @Volatile private var unknownAdd = false
    @Volatile private var unknownUpload = false
    @Volatile private var manage = true
    private var sharedOnly = false
    private val sourceImage by lazy {
        val bitmap = Bitmap.createBitmap(480, 320, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap); val paint = Paint()
        listOf(Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW).forEachIndexed { index, color ->
            paint.color = color; val x = (index % 2) * 240f; val y = (index / 2) * 160f
            canvas.drawRect(x, y, x + 240, y + 160, paint)
        }
        ByteArrayOutputStream().use { output -> bitmap.compress(Bitmap.CompressFormat.PNG, 100, output); bitmap.recycle(); output.toByteArray() }
    }
    @After fun cleanup() {
        gate?.complete(Unit); if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
    }
    @Test fun 实际预览入口拖动框选新人物直接保存真实JPEG并保留照片() {
        show(); open(); capture("canvas-normal"); val original = sourceImage.copyOf()
        scroll("photos_manual_draw").performClick()
        scroll("photos_manual_canvas").performTouchInput { swipe(Offset(width * .45f, height * .25f), Offset(width * .8f, height * .75f), 400) }
        compose.waitUntil(5_000) { editor.state.value.drafts.size == 2 }; name("Synthetic drawn"); capture("drawn-name")
        save(); finished(); capture("drawn-saved")
        assertEquals(listOf("add_face", "upload"), events.toList()); assertNull(editor.state.value.confirmation)
        val change = editor.state.value.records.single().checkpoint.manualFaces!!.changes.single() as SynologyPhotoFaceChange.Add
        val jpeg = uploads.getValue(801); assertEquals(change.jpegDigest, SynologyPhotoManualFacesCodec.digest(jpeg))
        val bitmap = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)!!
        assertTrue(bitmap.width <= 256 && bitmap.height <= 256); assertTrue(kotlin.math.abs(bitmap.width - bitmap.height) <= 1); bitmap.recycle()
        assertArrayEquals(original, sourceImage); assertEquals(listOf(51L), model.state.value.items.map { it.id.itemId })
        scroll("photos_manual_save").assertIsNotEnabled()
    }
    @Test fun 改框先新增上传后移除原框取消确认零写保存保留月份() {
        show(); open(); val before = model.state.value
        scroll("photos_manual_position_0").performSemanticsAction(SemanticsActions.SetProgress) { it(.2f) }; capture("position-adjusted")
        save(); confirmation(); capture("position-risk"); cancel(); assertTrue(writes.isEmpty()); assertTrue(uploads.isEmpty())
        save(); confirmation(); confirm(); finished(); capture("position-saved")
        assertEquals(listOf("add_face", "upload", "delete_face"), events.toList()); assertFalse(faces.containsKey(101)); assertTrue(faces.containsKey(801))
        assertEquals(before.selectedMonth, model.state.value.selectedMonth); assertEquals(before.items.map { it.id }, model.state.value.items.map { it.id })
    }
    @Test fun 选择已有或新人物分别使用固定目标和不带目标的改归属() {
        show(); open(); scroll("photos_manual_search").performTextReplacement("Synthetic B"); keyboard()
        scroll("photos_manual_person_2").performClick(); capture("person-existing"); save(); confirmation(); confirm(); finished()
        assertEquals(mapOf("name" to "\"Synthetic B\"", "target_id" to "2", "face_id" to "[101]"), writes.single().fields)
        scroll("photos_manual_new_person").performClick(); name("Synthetic new"); save(); confirmation(); capture("person-new-risk"); confirm(); finished()
        assertEquals(mapOf("name" to "\"Synthetic new\"", "face_id" to "[101]"), writes.last().fields)
        assertEquals(90L, faces.getValue(101).getValue("person_id").jsonPrimitive.long); assertTrue(uploads.isEmpty()); capture("person-new-saved")
    }
    @Test fun 移除标记可撤销且最终只删除人脸不删除照片() {
        show(); open(); scroll("photos_manual_remove").performClick(); capture("mark-removed")
        scroll("photos_manual_remove").performClick(); scroll("photos_manual_save").assertIsNotEnabled()
        scroll("photos_manual_remove").performClick(); save(); confirmation(); capture("mark-remove-risk"); confirm(); finished(); capture("mark-empty")
        assertEquals(listOf("delete_face"), events.toList()); assertTrue(faces.isEmpty()); assertTrue(editor.state.value.drafts.isEmpty())
        assertEquals(listOf(51L), model.state.value.items.map { it.id.itemId })
    }
    @Test fun 加载错误刷新保留草稿搜索空及空标记有操作入口() {
        gate = CompletableDeferred(); show(); open(wait = false); compose.waitUntil(5_000) { editor.state.value.loading }; capture("loading")
        failRead = true; compose.runOnIdle { gate!!.complete(Unit); gate = null }
        compose.waitUntil(5_000) { !editor.state.value.loading && editor.state.value.error != null }; capture("load-error")
        failRead = false; scroll("photos_manual_refresh").performClick(); form(); scroll("photos_manual_add").performClick(); name("Unsaved")
        val drafts = editor.state.value.drafts; failRead = true; scroll("photos_manual_refresh").performClick()
        compose.waitUntil(5_000) { !editor.state.value.loading && editor.state.value.error != null }; assertEquals(drafts, editor.state.value.drafts)
        failRead = false; scroll("photos_manual_refresh").performClick(); form(); assertEquals(drafts, editor.state.value.drafts)
        scroll("photos_manual_search").performTextReplacement("missing"); keyboard()
        compose.onNodeWithTag("photos_manual_list").performScrollToNode(hasText(text(R.string.sp_people_search_empty))); capture("search-empty")
        faces.clear(); scroll("photos_manual_refresh").performClick(); compose.waitUntil(5_000) { !editor.state.value.loading && editor.state.value.error != null }
        scroll("photos_manual_restart").performClick(); form(); capture("empty"); assertTrue(editor.state.value.drafts.isEmpty()); assertTrue(writes.isEmpty())
    }
    @Test fun 新增丢回执冷恢复不按相同名称或位置认领() {
        show(); open(); scroll("photos_manual_add").performClick(); name("Synthetic pending"); unknownAdd = true
        save(); pending(); capture("add-pending"); assertTrue(faces.containsKey(801)); assertTrue(uploads.isEmpty())
        cold(); open(); capture("cold-pending"); val count = calls.count { it.method == "list_face" }
        scroll("photos_manual_review").performClick(); compose.waitUntil(5_000) { calls.count { it.method == "list_face" } > count && !editor.state.value.working }
        pending(); capture("cold-reviewed"); assertEquals(1, writes.size); scroll("photos_manual_save").assertIsNotEnabled()
        assertTrue(editor.state.value.records.single().checkpoint.manualFaces!!.newIds.isEmpty())
    }
    @Test fun 上传回执丢失仅相同裁剪摘要恢复并保留尚未移除的原框() {
        show(); open(); scroll("photos_manual_position_0").performSemanticsAction(SemanticsActions.SetProgress) { it(.2f) }
        unknownUpload = true; save(); confirmation(); confirm(); finished(); capture("upload-partial")
        val row = editor.state.value.records.single().checkpoint
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, row.phase); assertEquals(1, row.manualFaces!!.completed.size); assertEquals(1, row.manualFaces!!.failed.size)
        assertEquals(listOf("add_face", "upload"), events.toList()); assertTrue(faces.containsKey(101)); assertTrue(faces.containsKey(801))
    }
    @Test fun 共享确认前撤销权限零写恢复后仍用原草稿与共享接口() {
        sharedOnly = true; show(); open(); scroll("photos_manual_new_person").performClick(); name("Synthetic shared")
        save(); confirmation(); manage = false; confirm()
        compose.waitUntil(5_000) { !editor.state.value.working && editor.state.value.error != null }; capture("shared-permission")
        assertTrue(writes.isEmpty()); assertEquals("Synthetic shared", editor.state.value.selectedDraft!!.name)
        manage = true; save(); confirmation(); confirm(); finished(); capture("shared-saved")
        assertEquals("SYNO.FotoTeam.Browse.Person", writes.single().api); assertEquals(SynologyPhotoSpace.SHARED, editor.state.value.photo!!.id.space)
    }

    private fun show() {
        store = SynologyPhotoAlbumStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Category", "Browse.Person", "Browse.Album", "Browse.NormalAlbum", "Browse.Folder", "Upload.Face")
                .map { "$prefix.$it" to ApiCapability("$prefix.$it", "entry.cgi", 1, if (it == "Browse.Item") 6 else 5, "JSON") }
        }.toMap()
        val profile = NasProfile(owner.profileId, "Synthetic", "https://example.invalid", "tester")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request()
            val bytes: ByteArray; val type: String
            if (request.method == "POST") {
                val body = request.body!!; assertTrue(body.isOneShot())
                val raw = Buffer().also { body.writeTo(it) }.readByteArray().toString(Charsets.ISO_8859_1)
                fun field(name: String) = Regex("name=\"$name\"\\r\\n(?:[^\\r\\n]+\\r\\n)*\\r\\n([^\\r\\n]*)").find(raw)!!.groupValues[1]
                assertEquals(if (sharedOnly) "SYNO.FotoTeam.Upload.Face" else "SYNO.Foto.Upload.Face", field("api")); assertEquals("1", field("version")); assertEquals("upload", field("method"))
                val id = field("face_id").toLong(); val record = store.records(owner, 41).first { it.checkpoint.manualFaces != null }
                assertTrue(id in record.checkpoint.manualFaces!!.uploadAttempted)
                assertTrue(raw.contains("name=\"file\"; filename=\"face.jpg\"\r\nContent-Type: image/jpeg"))
                val boundary = body.contentType()!!.parameter("boundary")!!
                uploads[id] = raw.substringAfter("name=\"file\"; filename=\"face.jpg\"").substringAfter("\r\n\r\n")
                    .substringBefore("\r\n--$boundary").toByteArray(Charsets.ISO_8859_1); events += "upload"
                if (unknownUpload) throw IOException("Synthetic upload interrupted")
                bytes = "{\"success\":true,\"data\":{\"success\":true}}".toByteArray(); type = "application/json"
            } else {
                val id = request.url.queryParameter("id")?.toLongOrNull()
                bytes = if (request.url.queryParameter("type") == "\"face\"" && id != null) uploads[id] ?: sourceImage else sourceImage
                type = if (id != null && uploads.containsKey(id)) "image/jpeg" else "image/png"
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic").header("Content-Type", type).body(bytes.toResponseBody(type.toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic", "synthetic"), profile.address, http)
        val repo = SynologyPhotosRepository(profile.id, caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call
            if (cap.name.endsWith("Browse.Item") && method == "list_face") { gate?.await(); if (failRead) throw IOException("Synthetic read unavailable") }
            response(call)
        }, media)
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store)
    }
    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
        c.api.endsWith("Setting.User") -> obj("""{"enable_home_service":${!sharedOnly},"team_space_permission":"${if (manage) "management" else "entry"}","enable_person":true}""")
        c.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic","enable_person":true}""")
        c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$sharedOnly,"enable_person":true}""")
        c.api.endsWith("Browse.Category") -> obj("""{"list":[{"id":"person"}]}""")
        c.api.endsWith("Browse.Album") -> list(emptyList())
        c.api.endsWith("Browse.Person") && c.method == "list" -> list(people.values.sortedBy { it.getValue("id").jsonPrimitive.long }.drop(c.id("offset").toInt()).take(c.id("limit").toInt()))
        c.api.endsWith("Browse.Person") && c.method == "get" -> list(c.ids("id").mapNotNull(people::get))
        c.api.endsWith("Browse.Item") && c.method == "list_face" -> list(faces.values.sortedBy { it.getValue("face_id").jsonPrimitive.long })
        c.api.endsWith("Browse.Item") -> list(listOf(photo()))
        c.api.endsWith("Browse.Timeline") -> obj("""{"section":[{"list":[{"year":2026,"month":10,"day":1,"item_count":1}]}]}""")
        c.api.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"name":"/Synthetic","parent":8,"additional":{"access_permission":{"view":true,"manage":$manage}}}}""")
        c.method == "add_face" -> {
            val record = store.records(owner, 41).first { it.checkpoint.manualFaces != null }; assertTrue(record.checkpoint.manualFaces!!.addAttempted)
            events += c.method
            val receipts = Json.parseToJsonElement(c.fields.getValue("face")).jsonArray.mapIndexed { index, value ->
                val change = value.jsonObject; val id = 801L + index
                val personId = change["person_id"]?.jsonPrimitive?.long ?: 90L
                val name = change["name"]?.jsonPrimitive?.content ?: people.getValue(personId).getValue("name").jsonPrimitive.content
                faces[id] = face(id, personId, name, change.getValue("face_bounding_box").jsonObject); people[personId] = person(personId, name)
                obj("""{"face_id_temp":${change.getValue("face_id_temp")},"face_id":$id}""")
            }
            if (unknownAdd) throw IOException("Synthetic add interrupted")
            list(receipts)
        }
        c.method == "delete_face" -> { events += c.method; c.ids("face_id").forEach(faces::remove); obj("{}") }
        c.method == "separate" -> {
            events += c.method; val id = c.fields["target_id"]?.toLong() ?: 90L; val name = c.text("name"); people[id] = person(id, name)
            c.ids("face_id").forEach { key -> faces[key] = JsonObject(faces.getValue(key) + mapOf("person_id" to JsonPrimitive(id), "name" to JsonPrimitive(name))) }
            obj("""{"id":$id,"name":${c.fields.getValue("name")}}""")
        }
        else -> error("Unexpected synthetic call ${c.api}.${c.method}")
    }
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun open(wait: Boolean = true) {
        ready(); compose.runOnIdle { model.preview.open(model.state.value.items.single()) }
        compose.waitUntil(5_000) { !model.preview.state.value.loading }
        compose.onNodeWithTag("photos_preview_actions").performScrollToNode(hasTestTag("photos_manual_open"))
        compose.onNodeWithTag("photos_manual_open").performClick(); if (wait) form()
    }
    private fun form() { compose.waitUntil(10_000) { editor.state.value.loaded && !editor.state.value.loading }; assertNull(editor.state.value.error) }
    private fun scroll(tag: String): SemanticsNodeInteraction { compose.onNodeWithTag("photos_manual_list").performScrollToNode(hasTestTag(tag)); return compose.onNodeWithTag(tag) }
    private fun keyboard() = androidx.test.espresso.Espresso.closeSoftKeyboard()
    private fun name(value: String) { scroll("photos_manual_name").performTextReplacement(value); keyboard() }
    private fun save() { scroll("photos_manual_save").performClick() }
    private fun confirmation() { compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.confirmation != null } }
    private fun cancel() { compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick() }
    private fun confirm() { compose.onNodeWithTag("photos_manual_confirm").performClick() }
    private fun finished() { compose.waitUntil(10_000) { !editor.state.value.working && !editor.state.value.loading && editor.state.value.records.isNotEmpty() && editor.state.value.records.all { it.checkpoint.finished } }; assertNull(editor.state.value.error) }
    private fun pending() { compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.pending } }
    private fun cold() { compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready() }
    private fun text(id: Int) = context.getString(id)
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-manual-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object {
        private fun obj(raw: String) = Json.parseToJsonElement(raw).jsonObject
        private fun list(rows: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(rows)))
        private fun bounds(x: Double, y: Double, width: Double, height: Double) = obj("""{"top_left":{"x":$x,"y":$y},"bottom_right":{"x":${x + width},"y":${y + height}}}""")
        private fun face(id: Long, person: Long, name: String, box: JsonObject) = obj("""{"face_id":$id,"person_id":$person,"name":${JsonPrimitive(name)},"face_bounding_box":$box,"additional":{"thumbnail":{"cache_key":"synthetic-$id"}}}""")
        private fun person(id: Long, name: String) = obj("""{"id":$id,"name":${JsonPrimitive(name)},"item_count":1,"show":true}""")
        private fun photo() = obj("""{"id":51,"filename":"Synthetic-51.jpg","filesize":4,"time":1790812800,"indexed_time":1790812800,"folder_id":9,"type":"photo","additional":{"thumbnail":{"cache_key":"synthetic","unit_id":51}}}""")
    }
}

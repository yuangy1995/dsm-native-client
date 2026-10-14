package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import java.io.IOException
import java.nio.file.Files
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*

/** 正式组合根与媒体传输；仅替换网络及设备编解码边界，不含真实媒体或账号。 */
internal class SynologyPhotosAutomaticPreviewFixture(val space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL) : AutoCloseable {
    val cache = Files.createTempDirectory("automatic-preview-integration-").toFile()
    val support = SynologyPhotoPreviewConversionSupport(true, true, true)
    var type = "photo"; var filename = "Synthetic.heic"; var home = true; var enabled = true; var management = false; var download = true
    var large = "ame_defect"; var small = "ame_defect"; var videoStatus = "ame_defect"; var ownerId = if (space == SynologyPhotoSpace.SHARED) 0L else 41L
    var backgroundPresent = true; var conversionCount = 0
    var convertHook: suspend () -> Unit = {}; var uploadHook: () -> Unit = {}; var readHook: suspend (String, String) -> Unit = { _, _ -> }
    var brokenHook: suspend () -> Unit = {}; var signatureHook: suspend () -> Unit = {}; var thumbnailHook: (String) -> Unit = {}
    var uploadResponse = "{\"success\":true}"; var uploadCode = 200; var unknownUpload = false
    val requests = mutableListOf<Request>(); val uploadBodies = mutableListOf<String>()
    data class Call(val api: String, val method: String, val fields: Map<String, String>)
    val calls = mutableListOf<Call>(); val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
    val thumbs = mapOf("xl" to byteArrayOf(1, 2, 3), "sm" to byteArrayOf(4, 5), "m" to byteArrayOf(6))
    var receivedThumbs = thumbs
    val signature = SynologyPhotoPreviewVideoSignature(listOf(SynologyPhotoPreviewVideoSignature.Track("video/avc", 160, 120,
        durationMicros = 6_000_000, sampleCount = 60, configurationDigest = "a".repeat(64), contentDigest = "b".repeat(64))))
    var receivedSignature = signature
    val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
        listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Item", "Browse.Folder", "Browse.Unit",
            "Upload.ConvertedFile", "Download", "Streaming", "Browse.NormalAlbum", "Browse.Album")
            .map { ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
    }.associateBy { it.name }
    private val media = SynologyPhotosMediaTransport(NasProfile("auto-root", "synthetic", "nas.example.invalid", "synthetic"),
        DsmSession("auto-root", "synthetic-session", "synthetic-token"), "https://nas.example.invalid",
        OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request(); requests += request
            val content: ByteArray; val mime: String; var code = 200
            if (request.method == "POST") {
                val buffer = Buffer(); request.body!!.writeTo(buffer); uploadBodies += buffer.readUtf8()
                assertTrue(saved.last().automaticPreview!!.uploadAttempted); uploadHook()
                if (unknownUpload) throw IOException("Synthetic upload interrupted")
                content = uploadResponse.toByteArray(); mime = "application/json"; code = uploadCode
            } else if (request.url.encodedPath.endsWith("Thumbnail/get")) {
                val size = Json.parseToJsonElement(request.url.queryParameter("size")!!).jsonPrimitive.content
                thumbnailHook(size); content = receivedThumbs.getValue(size); mime = "image/jpeg"
            } else { content = byteArrayOf(9, 8, 7, 6); mime = "application/octet-stream" }
            Response.Builder().request(request).code(code).protocol(Protocol.HTTP_1_1).message("Synthetic")
                .header("Content-Type", mime).body(content.toResponseBody(mime.toMediaType())).build()
        }.build())
    var repository = createRepository()
    fun photo() = SynologyPhoto(SynologyPhotoId("auto-root", space, 51), filename, 999, 1.0, 2.0, 9, type, SynologyPhotoThumbnail(151, "old"))
    fun createRepository() = SynologyPhotosRepository("auto-root", caps, { api, method, fields ->
        val suffix = api.name.substringAfter("SYNO.Foto").removePrefix("Team").removePrefix(".")
        calls += Call(api.name, method, fields); readHook(suffix, method)
        when (suffix) {
            "UserInfo" -> obj("""{"enabled":true,"id":41}""")
            "Setting.User" -> obj("""{"enable_home_service":$home,"team_space_permission":"${if (management) "management" else "entry"}","auto_generate_thumbnail":$enabled}""")
            "Setting.Admin" -> obj("""{"package_version":"synthetic"}""")
            "Setting.TeamSpace" -> obj("""{"enabled":true}""")
            "Browse.Item" -> obj("""{"list":[{"id":51,"filename":"$filename","filesize":999,"time":1,"indexed_time":2,"folder_id":9,"type":"$type","owner_user_id":$ownerId,"additional":{"thumbnail":{"unit_id":151,"cache_key":"old","xl":"$large","sm":"$small"},"video_convert_status":"$videoStatus","video_meta":{"video_codec":"hevc"}}}]}""")
            "Browse.Folder" -> obj("""{"folder":{"id":9,"additional":{"access_permission":{"view":true,"download":$download}}}}""")
            "Upload.ConvertedFile" -> if (method == "set_broken") {
                assertNotNull(saved.last().automaticPreview!!.failureKind); brokenHook(); obj("{}")
            } else {
                assertEquals("list_convert_needed", method)
                if (!backgroundPresent) obj("""{"list":[]}""") else obj("""{"list":[{"unit_id":151,"filename":"$filename","type":${if (type == "photo") 0 else 3},"need_thumbnail":${large == "ame_defect" || small == "ame_defect"},"need_video":${type != "photo" && videoStatus == "ame_defect"}}]}""")
            }
            else -> error("Unexpected synthetic API: $suffix")
        }
    }, media, automaticConverter = { source, task, output ->
        assertArrayEquals(byteArrayOf(9, 8, 7, 6), source.readBytes()); conversionCount++; convertHook()
        val thumbnail = if (task.needsThumbnail) SynologyPhotoConvertedPreview(thumbs.getValue("xl"), thumbs.getValue("sm"), thumbs.getValue("m")) else null
        val video = if (task.needsVideo) output.also { it.writeBytes(byteArrayOf(5, 4, 3, 2)) } else null
        SynologyPhotoAutomaticPreviewMedia(thumbnail, video, if (task.needsVideo) signature else null)
    }, automaticVideoSignature = { file -> assertArrayEquals(byteArrayOf(9, 8, 7, 6), file.readBytes()); signatureHook(); receivedSignature })
    suspend fun ready() { repository.access() }
    suspend fun row(background: Boolean = false): SynologyPhotoAlbumCheckpoint {
        val task = if (background) repository.automaticPreviewTasks(space, support).single() else repository.automaticPreviewTasks(photo(), support).single()
        return repository.prepareAutomaticPreview(task, support)
    }
    fun save(row: SynologyPhotoAlbumCheckpoint) { validatePhotoAlbumCheckpoint(row); saved += row }
    suspend fun perform(row: SynologyPhotoAlbumCheckpoint? = null) = repository.performAutomaticPreview(row ?: this.row(), cache, ::save)
    suspend fun review(row: SynologyPhotoAlbumCheckpoint) = repository.reviewAutomaticPreview(row, cache, ::save)
    suspend fun cold() { repository = createRepository(); ready() }
    fun clean() { assertTrue("临时媒体应已清理", cache.list()!!.isEmpty()) }
    override fun close() { assertTrue(cache.deleteRecursively()) }
    private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
}

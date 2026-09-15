package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotosMediaTransport
import io.github.qwertyuiop1995.dsmnativeclient.network.photoApiPath
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.boolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.encode
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalList
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalText
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.permission
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import java.io.File
import java.net.URI
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*

/**
 * Synology Photos 内部接口适配；请求契约来自 photos-library-read.md 与 photos-item-deletion.md。
 * 每个实例绑定一个已登录账号；共享空间保持关闭，个人单项删除仍逐次检查实际权限与身份。
 */
class SynologyPhotosRepository internal constructor(
    override val profileId: String,
    capabilities: Map<String, ApiCapability>,
    private val callTransport: suspend (ApiCapability, String, Map<String, String>) -> JsonObject,
    private val media: SynologyPhotosMediaTransport? = null,
    override val canDeleteOriginals: Boolean = false,
) : SynologyPhotosServing {
    constructor(profile: NasProfile, session: DsmSession, api: DsmApiClient, capabilities: Map<String, ApiCapability>) :
        this(profile.id, capabilities, { capability, method, parameters ->
            api.call(profile, session, capability, method, parameters)
        }, api.photosMedia(profile, session), canDeleteOriginals = true)

    private val capabilities = capabilities.toMap()
    private val accessGeneration = AtomicLong()
    @Volatile private var personalAllowed = false
    private val deletionMutex = Mutex()
    private val pendingDeletions = mutableMapOf<SynologyPhotoId, SynologyPhoto>()
    private val confirmedDeletions = mutableMapOf<SynologyPhotoId, SynologyPhoto>()
    private val deletionOperations = mutableMapOf<UUID, SynologyPhoto>()

    override suspend fun access(): SynologyPhotoAccess {
        personalAllowed = false
        val generation = accessGeneration.incrementAndGet()
        if (!call("UserInfo", 1, "me").boolean("enabled")) denied()
        val user = call("Setting.User", 1, "get")
        val homeEnabled = user.boolean("enable_home_service")
        user.text("team_space_permission")
        val admin = call("Setting.Admin", 1, "get")
        call("Setting.TeamSpace", 1, "get").boolean("enabled")
        currentCoroutineContext().ensureActive()
        if (generation != accessGeneration.get()) throw CancellationException()
        // 已记录 none 为无权；不猜测其他共享权限枚举，也不使用管理员身份绕过权限。
        personalAllowed = homeEnabled
        return SynologyPhotoAccess(if (homeEnabled) listOf(SynologyPhotoSpace.PERSONAL) else emptyList(), admin.text("package_version"))
    }

    override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?): List<SynologyPhotoDay> {
        requireAccess(space)
        val parameters = mutableMapOf<String, JsonElement>("timeline_group_unit" to JsonPrimitive("day"))
        var api = "Browse.Timeline"
        var version = 5
        var method = "get"
        when (query) {
            null, is SynologyPhotoQuery.Timeline -> Unit
            is SynologyPhotoQuery.Search -> {
                api = "Search.Search"; version = 2; method = "get_search_timeline"
                parameters["keyword"] = JsonPrimitive(query.keyword)
            }
            is SynologyPhotoQuery.Filtered -> {
                version = 3; method = "get_with_filter"
                parameters.putAll(SynologyPhotosCodec.filterParameters(query.filter))
            }
            is SynologyPhotoQuery.Category -> parameters[categoryParameter(query.category)] = JsonPrimitive(query.id.also { if (it <= 0) invalid() })
            else -> invalid()
        }
        return SynologyPhotosCodec.days(read(api, version, method, parameters))
    }

    override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
        requireAccess(space)
        val parameters = pageParameters(offset, limit).toMutableMap()
        parameters["additional"] = array("thumbnail", "resolution", "orientation", "video_convert", "video_meta", "address")
        var api = "Browse.Item"
        var version = 4
        var method = "list"
        fun range(start: Long, end: Long) {
            SynologyPhotosCodec.time(start, end)
            parameters["start_time"] = JsonPrimitive(start)
            parameters["end_time"] = JsonPrimitive(end)
        }
        when (query) {
            is SynologyPhotoQuery.Timeline -> range(query.start, query.end)
            is SynologyPhotoQuery.Search -> {
                api = "Search.Search"; version = 1; method = "list_item"
                parameters["keyword"] = JsonPrimitive(query.keyword)
                range(query.start, query.end)
            }
            is SynologyPhotoQuery.Folder -> {
                if (query.id <= 0) invalid()
                parameters.putAll(json("folder_id" to query.id, "sort_by" to "takentime", "sort_direction" to "asc"))
                parameters["additional"] = array("thumbnail", "resolution", "orientation", "video_convert", "video_meta")
            }
            is SynologyPhotoQuery.Album -> {
                if (query.id <= 0) invalid()
                parameters.putAll(json("album_id" to query.id, "sort_by" to "takentime", "sort_direction" to "desc"))
                parameters["additional"] = array("thumbnail", "resolution", "orientation", "video_convert", "video_meta", "provider_user_id")
            }
            SynologyPhotoQuery.Recent -> { api = "Browse.RecentlyAdded"; version = 1; parameters["additional"] = array("thumbnail") }
            is SynologyPhotoQuery.Filtered -> {
                version = 2; method = "list_with_filter"
                parameters.putAll(SynologyPhotosCodec.filterParameters(query.filter))
                SynologyPhotosCodec.time(query.start, query.end)
                val start = maxOf(query.start, query.filter.startTime ?: query.start)
                val end = minOf(query.end, query.filter.endTime ?: query.end)
                if (start > end) return SynologyPhotoPage(emptyList(), offset, offset, false)
                parameters["time"] = SynologyPhotosCodec.time(start, end)
            }
            is SynologyPhotoQuery.Category -> {
                if (query.id <= 0) invalid()
                parameters[categoryParameter(query.category)] = JsonPrimitive(query.id)
                range(query.start, query.end)
            }
        }
        val payload = read(api, version, method, parameters).list()
        val items = payload.map { SynologyPhotosCodec.photo(it, profileId, space) }
        if (items.size > limit || items.map { it.id }.distinct().size != items.size) invalid()
        // 游标按服务端原始条数推进，不使用时间轴计数、客户端去重后的数量或虚构 total。
        return SynologyPhotoPage(items, offset, offset + payload.size, payload.size == limit)
    }

    override suspend fun rootFolder(space: SynologyPhotoSpace): SynologyPhotoCollection {
        requireAccess(space)
        val folder = read("Browse.Folder", 2, "get", json("name" to "/", "additional" to array("access_permission"))).obj("folder")
        if (folder.optionalObject("additional")?.optionalObject("access_permission")?.permission("view") != true) denied()
        return SynologyPhotosCodec.collection(folder, folder = true)
    }

    override suspend fun folders(space: SynologyPhotoSpace, parentId: Long, offset: Int, limit: Int): List<SynologyPhotoCollection> {
        requireAccess(space)
        if (parentId <= 0) invalid()
        val parameters = pageParameters(offset, limit) + json("id" to parentId, "sort_by" to "filename",
            "sort_direction" to "asc", "additional" to array("thumbnail"))
        return SynologyPhotosCodec.collectionPage(read("Browse.Folder", 2, "list", parameters), limit, folder = true, parentId = parentId)
    }

    override suspend fun albums(offset: Int, limit: Int): List<SynologyPhotoCollection> =
        SynologyPhotosCodec.collectionPage(read("Browse.Album", 4, "list", pageParameters(offset, limit) +
            json("category" to "normal_share_with_me", "additional" to array("thumbnail", "sharing_info"))), limit)

    override suspend fun categories(): Set<SynologyPhotoCategory> = read("Browse.Category", 3, "get").list().mapNotNull { entry ->
        val id = entry.text("id")
        SynologyPhotoCategory.entries.firstOrNull { it.serverId == id }
    }.toSet()

    override suspend fun categoryItems(category: SynologyPhotoCategory, offset: Int, limit: Int): List<SynologyPhotoCollection> {
        val suffix = when (category) {
            SynologyPhotoCategory.PEOPLE -> "Person"
            SynologyPhotoCategory.SUBJECTS -> "Concept"
            SynologyPhotoCategory.LOCATIONS -> "Geocoding"
            SynologyPhotoCategory.TAGS -> "GeneralTag"
            else -> invalid()
        }
        return SynologyPhotosCodec.collectionPage(read("Browse.$suffix", if (category == SynologyPhotoCategory.SUBJECTS) 2 else 1,
            "list", pageParameters(offset, limit) + json("additional" to array("thumbnail"))), limit)
    }

    override suspend fun sharedEntries(scope: SynologyPhotoShareScope, offset: Int, limit: Int): List<SynologyPhotoSharedEntry> {
        var parameters = pageParameters(offset, limit)
        val values: List<SynologyPhotoSharedEntry>
        when (scope) {
            SynologyPhotoShareScope.REQUESTS -> values = read("PhotoRequest", 1, "list", parameters).list().map {
                SynologyPhotoSharedEntry(it.text("passphrase"), it.text("subject"), url = safeSharingUrl(it.optionalText("sharing_link")))
            }
            SynologyPhotoShareScope.WITH_ME -> {
                parameters += json("additional" to array("sharing_info", "thumbnail", "access_permission"))
                values = read("Sharing.Misc", 2, "list_shared_with_me_album", parameters).list().map(::sharedAlbum)
            }
            SynologyPhotoShareScope.WITH_OTHERS -> {
                parameters += json("category" to "shared", "sort_by" to "share_modify_time", "sort_direction" to "desc",
                    "additional" to array("thumbnail", "sharing_info"))
                values = read("Browse.Album", 4, "list", parameters).list().map(::sharedAlbum)
            }
        }
        if (values.size > limit || values.map { it.id }.distinct().size != values.size) invalid()
        return values
    }

    override suspend fun filterOptions(): SynologyPhotoFilterOptions = SynologyPhotosCodec.filterOptions(read("Search.Filter", 3, "list",
        json("additional" to array("thumbnail"), "setting" to JsonObject(listOf(
            "item_type", "time", "person", "geocoding", "rating", "general_tag", "camera", "lens", "iso", "aperture",
            "focal_length_group", "exposure_time_group",
        ).associateWith { JsonPrimitive(true) }))))

    override suspend fun thumbnail(photo: SynologyPhoto, large: Boolean): ByteArray {
        requirePhoto(photo)
        val generation = accessGeneration.get()
        val result = media().thumbnail(photo.thumbnail ?: invalid(), large)
        requireGeneration(generation)
        return result
    }

    override suspend fun details(photo: SynologyPhoto): SynologyPhoto {
        requirePhoto(photo)
        val item = read("Browse.Item", 5, "get", json("id" to array(photo.id.itemId), "additional" to array(
            "description", "tag", "exif", "resolution", "orientation", "gps", "video_meta", "video_convert", "thumbnail",
            "address", "geocoding_id", "rating", "motion_photo", "person",
        ))).list().singleOrNull() ?: invalid()
        return SynologyPhotosCodec.photo(item, profileId, photo.id.space).also { if (it.id != photo.id) invalid() }
    }

    /** 测试可独立核对选源；实况必须使用视频单元 ID，不复用照片或缩略图单元 ID。 */
    internal suspend fun videoRequest(photo: SynologyPhoto): Pair<ApiCapability, Pair<String, Map<String, String>>> {
        requirePhoto(photo)
        if (photo.mediaType !in setOf("video", "live")) invalid()
        val entry: JsonObject
        var id = photo.id.itemId
        var type = "item"
        if (photo.mediaType == "live") {
            val parent = read("Browse.Unit", 1, "get", json("id_item" to array(id), "additional" to array(
                "orientation", "resolution", "thumbnail", "video_meta", "video_convert",
            ))).list().singleOrNull() ?: invalid()
            if (parent.number("id_item") != id) invalid()
            entry = parent.list("unit").filter { it.text("live_type") == "video" }.singleOrNull() ?: invalid()
            id = entry.positive("id"); type = "unit"
        } else {
            entry = read("Browse.Item", 5, "get", json("id" to array(id), "additional" to array("video_convert"))).list().singleOrNull() ?: invalid()
            if (entry.number("id") != id || entry.text("type") != "video") invalid()
        }
        val conversions = entry.optionalObject("additional")?.optionalList("video_convert").orEmpty().map { it.text("quality") }
        val quality = listOf("raw", "orig_h264", "high", "medium", "low", "mobile").firstOrNull { it in conversions }
        return if (quality == null || quality == "raw") {
            capability("Download", 2) to ("download" to encode(json((if (type == "unit") "unit_id" else "item_id") to array(id))))
        } else {
            capability("Streaming", 2) to ("streaming" to encode(json("id" to id, "type" to type, "quality" to quality, "use_mov" to true)))
        }
    }

    override suspend fun videoSource(photo: SynologyPhoto): RandomAccessMediaSource {
        val generation = accessGeneration.get()
        val (capability, request) = videoRequest(photo)
        val source = media().video(capability, request.first, request.second)
        try { requireGeneration(generation); return source } catch (error: Throwable) { source.close(); throw error }
    }

    override suspend fun downloadOriginal(photo: SynologyPhoto, destination: File, progress: (Long, Long) -> Unit) {
        requirePhoto(photo)
        val generation = accessGeneration.get()
        media().download(capability("Download", 2), encode(json(
            "item_id" to array(photo.id.itemId), "force_download" to true, "download_type" to "source",
        )), destination, photo.sizeBytes, beforeCommit = { requireGeneration(generation) }, progress = progress)
    }

    override suspend fun prepareDeletion(photo: SynologyPhoto) {
        requirePhoto(photo)
        if (!canDeleteOriginals) throw SynologyPhotoFailure(SynologyPhotoFailureKind.DELETION_UNVERIFIED)
        capability("BackgroundTask.File", 1)
        if (!photo.sameDeletionTarget(details(photo))) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
        val folder = read("Browse.Folder", 2, "get", json("id" to photo.folderId, "additional" to array("access_permission"))).obj("folder")
        val access = folder.optionalObject("additional")?.optionalObject("access_permission")
        if (folder.number("id") != photo.folderId || access?.permission("view") != true || access?.permission("manage") != true) {
            throw SynologyPhotoFailure(SynologyPhotoFailureKind.DELETE_DENIED)
        }
    }

    override suspend fun deletePhoto(photo: SynologyPhoto, operationId: UUID): SynologyPhotoDeletionResult = deletionMutex.withLock {
        requirePhoto(photo)
        deletionOperations[operationId]?.let { if (!it.sameDeletionTarget(photo)) changed() }
        confirmedDeletions[photo.id]?.let { if (it.sameDeletionTarget(photo)) return@withLock SynologyPhotoDeletionResult.CONFIRMED }
        pendingDeletions[photo.id]?.let {
            if (!it.sameDeletionTarget(photo)) changed()
            return@withLock reviewDeletionLocked(photo)
        }
        val generation = accessGeneration.get()
        prepareDeletion(photo)
        currentCoroutineContext().ensureActive()
        requireGeneration(generation)
        deletionOperations[operationId] = photo
        pendingDeletions[photo.id] = photo
        try {
            call("BackgroundTask.File", 1, "delete", json("item_id" to array(photo.id.itemId), "folder_id" to array()))
        } catch (_: Exception) {
            // 请求发送后的断网/取消并非未执行；保留待核对状态，绝不重放删除。
            return@withLock SynologyPhotoDeletionResult.PENDING_REVIEW
        }
        try { reviewDeletionLocked(photo) } catch (_: Exception) { SynologyPhotoDeletionResult.PENDING_REVIEW }
    }

    override suspend fun reviewDeletion(photo: SynologyPhoto): SynologyPhotoDeletionResult = deletionMutex.withLock { reviewDeletionLocked(photo) }

    private suspend fun reviewDeletionLocked(photo: SynologyPhoto): SynologyPhotoDeletionResult {
        requirePhoto(photo)
        confirmedDeletions[photo.id]?.let { if (it.sameDeletionTarget(photo)) return SynologyPhotoDeletionResult.CONFIRMED }
        if (pendingDeletions[photo.id]?.sameDeletionTarget(photo) != true) changed()
        val items = read("Browse.Item", 5, "get", json("id" to array(photo.id.itemId))).list()
        if (items.isNotEmpty()) return SynologyPhotoDeletionResult.PENDING_REVIEW
        pendingDeletions.remove(photo.id)
        confirmedDeletions[photo.id] = photo
        return SynologyPhotoDeletionResult.CONFIRMED
    }

    private fun requirePhoto(photo: SynologyPhoto) {
        requireAccess(photo.id.space)
        if (photo.id.profileId != profileId || photo.id.itemId <= 0) denied()
    }
    private fun requireAccess(space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL) {
        if (space != SynologyPhotoSpace.PERSONAL || !personalAllowed) denied()
    }
    private suspend fun requireGeneration(generation: Long) {
        currentCoroutineContext().ensureActive()
        if (generation != accessGeneration.get()) throw CancellationException()
        requireAccess()
    }
    private suspend fun read(suffix: String, version: Int, method: String, parameters: Map<String, JsonElement> = emptyMap()): JsonObject {
        requireAccess()
        val generation = accessGeneration.get()
        return call(suffix, version, method, parameters).also { requireGeneration(generation) }
    }
    private suspend fun call(suffix: String, version: Int, method: String, parameters: Map<String, JsonElement> = emptyMap()): JsonObject =
        callTransport(capability(suffix, version), method, encode(parameters))
    private fun capability(suffix: String, version: Int): ApiCapability {
        val name = "SYNO.Foto.$suffix"
        val value = capabilities[name] ?: throw SynologyPhotoFailure(SynologyPhotoFailureKind.UNAVAILABLE)
        if (value.name != name || version !in value.minVersion..value.maxVersion || !value.requestFormat.equals("JSON", true)) {
            throw SynologyPhotoFailure(SynologyPhotoFailureKind.UNAVAILABLE)
        }
        try { photoApiPath(value.path) } catch (_: IllegalArgumentException) { throw SynologyPhotoFailure(SynologyPhotoFailureKind.UNAVAILABLE) }
        return value.copy(minVersion = version, maxVersion = version)
    }
    private fun media(): SynologyPhotosMediaTransport = media ?: throw SynologyPhotoFailure(SynologyPhotoFailureKind.UNAVAILABLE)
    private fun pageParameters(offset: Int, limit: Int): Map<String, JsonElement> {
        if (offset < 0 || limit !in 1..500 || offset > Int.MAX_VALUE - limit) invalid()
        return json("offset" to offset, "limit" to limit)
    }
    private fun categoryParameter(category: SynologyPhotoCategory): String = category.parameter ?: invalid()
    private fun sharedAlbum(value: JsonObject): SynologyPhotoSharedEntry = value.positive("id").let {
        SynologyPhotoSharedEntry(it.toString(), value.text("name"), albumId = it)
    }
    private fun safeSharingUrl(value: String?): String? = value?.let {
        runCatching { URI(it) }.getOrNull()?.takeIf { uri -> uri.scheme == "https" && uri.host != null && uri.userInfo == null }?.toString()
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}

package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.serialization.json.*

/** 正式仓储与分页模型共用的合成 NAS；无真实数据或外部网络。 */
internal class SynologyPhotoPreferenceFixture {
    data class Call(val api: String, val version: Int, val method: String, val fields: Map<String, String>)
    val calls = CopyOnWriteArrayList<Call>()
    val writes get() = calls.filter { it.method.startsWith("set_") }
    var album = obj("""{"id":7,"name":"Synthetic album","owner_user_id":41,"type":"normal","sort_by":"takentime","sort_direction":"asc","passphrase":"synthetic"}""")
    var order = obj("""{"album_list_sort_by":"album_name","album_list_sort_direction":"asc","shared_with_me_sort_by":"start_time","shared_with_me_sort_direction":"desc","shared_with_others_sort_by":"share_modify_time","shared_with_others_sort_direction":"asc"}""")
    var display = obj("""{"album_display_type":"all_album"}""")
    var userId = 41L; var home = true; var shared = true; var permitted = true
    var apply = true; var writeError: Exception? = null
    var failMethods = emptySet<String>(); var after: suspend (Call) -> Unit = {}; var before: suspend (Call) -> Unit = {}
    var albumOverride: JsonObject? = null
    var capabilities = listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Album", "Browse.Item", "Browse.NormalAlbum", "Browse.Timeline", "Browse.Category", "Sharing.Passphrase", "Sharing.Misc", "PhotoRequest").associate {
        val name = "SYNO.Foto.$it"; name to ApiCapability(name, "entry.cgi", 1, 5, "JSON")
    }
    fun repository(): SynologyPhotosRepository = SynologyPhotosRepository("preference", capabilities, { cap, method, fields ->
        val c = Call(cap.name, cap.maxVersion, method, fields); calls += c; before(c)
        if (method in failMethods) throw IOException("Synthetic read failure")
        val result = when {
            cap.name.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$userId}""")
            cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"management"}""")
            cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
            cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$shared}""")
            cap.name.endsWith("Browse.Album") && method == "get" -> albumOverride ?: list(listOf(album))
            cap.name.endsWith("Sharing.Passphrase") -> { if (!permitted) throw DsmFailure(105, "Synthetic", "Synthetic"); obj("""{"permission":{"upload":false,"download":false}}""") }
            method == "get_album_list_order" -> order
            method == "get_album_list_display" -> display
            method.startsWith("set_") -> {
                val values = fields.mapValues { Json.parseToJsonElement(it.value) }
                if (apply) when (method) {
                    "set_order" -> album = JsonObject(album + values.filterKeys { it != "id" })
                    "set_album_list_order" -> order = JsonObject(order + values)
                    "set_album_list_display" -> display = JsonObject(display + values)
                    else -> error("Unexpected synthetic write")
                }
                writeError?.let { throw it }; obj("{}")
            }
            cap.name.endsWith("Browse.Timeline") -> obj("""{"section":[]}""")
            cap.name.endsWith("Browse.Category") -> list(emptyList())
            cap.name.endsWith("Browse.Item") -> {
                val ids = if (fields["sort_direction"] == "\"asc\"") listOf(1L, 2L, 3L) else listOf(3L, 2L, 1L)
                list(ids.drop(fields.getValue("offset").toInt()).take(fields.getValue("limit").toInt()).map(::photo))
            }
            cap.name.endsWith("PhotoRequest") -> list(emptyList())
            method == "list" || method == "list_shared_with_me_album" -> {
                val ids = if (fields["category"] == "\"normal\"") listOf(7L, 9L) else listOf(7L, 8L, 9L)
                list(ids.drop(fields.getValue("offset").toInt()).take(fields.getValue("limit").toInt()).map { id -> obj("""{"id":$id,"name":"Synthetic album $id","type":"normal"}""") })
            }
            else -> error("Unexpected synthetic call ${c.api}.${c.method}")
        }
        after(c); result
    })
    suspend fun ready() = repository().also { it.access(); calls.clear() }
    suspend fun row(repo: SynologyPhotosServing, target: SynologyPhotoSettingsTarget = albumTarget,
        change: (SynologyPhotoSettings) -> SynologyPhotoSettings = { (it as SynologyPhotoAlbumSortSettings).copy(sort = SynologyPhotoSort(SynologyPhotoSort.Field.FILENAME)) }): SynologyPhotoAlbumCheckpoint {
        val original = repo.photoSettings(target)
        return SynologyPhotoAlbumCheckpoint(profileId = repo.profileId, userId = userId, action = SynologyPhotoAlbumAction.SETTINGS,
            settings = SynologyPhotoSettingsCheckpoint(original, change(original)))
    }
    fun field(key: String, value: JsonElement?) { album = JsonObject(if (value == null) album - key else album + (key to value)) }
    companion object {
        val albumTarget = SynologyPhotoSettingsTarget(SynologyPhotoSettingsKind.ALBUM_SORT, albumId = 7)
        val displayTarget = SynologyPhotoSettingsTarget(SynologyPhotoSettingsKind.LIST_DISPLAY)
        fun sortTarget(scope: SynologyPhotoAlbumListScope) = SynologyPhotoSettingsTarget(SynologyPhotoSettingsKind.LIST_SORT, listScope = scope)
        fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
        fun photo(id: Long) = obj("""{"id":$id,"filename":"Synthetic$id.jpg","filesize":10,"time":$id,"indexed_time":$id,"folder_id":9,"type":"photo","owner_user_id":41,"additional":{"provider_user_id":41}}""")
    }
}

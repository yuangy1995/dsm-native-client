package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoAlbumListSort.Field

@Serializable
enum class SynologyPhotoAlbumListScope(val value: String) {
    ALBUMS("album_list"), WITH_ME("shared_with_me"), WITH_OTHERS("shared_with_others");
    val fields: List<SynologyPhotoAlbumListSort.Field> get() =
        if (this@SynologyPhotoAlbumListScope == ALBUMS) listOf(Field.NAME, Field.TYPE, Field.START_TIME, Field.CREATED_TIME, Field.SHARING)
        else listOf(Field.NAME, Field.TYPE, Field.START_TIME, Field.SHARED_TIME)
}

@Serializable
data class SynologyPhotoAlbumListSort(val field: Field, val direction: SynologyPhotoSort.Direction) {
    @Serializable enum class Field(val value: String) {
        NAME("album_name"), TYPE("album_type"), START_TIME("start_time"), CREATED_TIME("create_time"), SHARING("share_status"), SHARED_TIME("share_modify_time")
    }
}

@Serializable
enum class SynologyPhotoAlbumDisplay(val value: String, val category: String) { ALL("all_album", "normal_share_with_me"), MINE("my_album", "normal") }

/** 仅承载读取目标；持久恢复继续使用原设置值及其固有目标。 */
data class SynologyPhotoSettingsTarget(val kind: SynologyPhotoSettingsKind, val albumId: Long? = null, val listScope: SynologyPhotoAlbumListScope? = null)

@Serializable
data class SynologyPhotoAlbumSortSettings(val albumId: Long, val sort: SynologyPhotoSort) : SynologyPhotoSettings() {
    override val kind: SynologyPhotoSettingsKind get() = SynologyPhotoSettingsKind.ALBUM_SORT
}
@Serializable
data class SynologyPhotoAlbumListSortSettings(val scope: SynologyPhotoAlbumListScope, val sort: SynologyPhotoAlbumListSort) : SynologyPhotoSettings() {
    override val kind: SynologyPhotoSettingsKind get() = SynologyPhotoSettingsKind.LIST_SORT
}
@Serializable
data class SynologyPhotoAlbumDisplaySettings(val display: SynologyPhotoAlbumDisplay) : SynologyPhotoSettings() {
    override val kind: SynologyPhotoSettingsKind get() = SynologyPhotoSettingsKind.LIST_DISPLAY
}

fun SynologyPhotoSettings.target(): SynologyPhotoSettingsTarget = when (this) {
    is SynologyPhotoAlbumSortSettings -> SynologyPhotoSettingsTarget(kind, albumId = albumId)
    is SynologyPhotoAlbumListSortSettings -> SynologyPhotoSettingsTarget(kind, listScope = scope)
    else -> SynologyPhotoSettingsTarget(kind)
}

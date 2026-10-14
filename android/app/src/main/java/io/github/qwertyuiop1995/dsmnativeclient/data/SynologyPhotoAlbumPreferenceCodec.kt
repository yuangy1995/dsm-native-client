package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalText
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.serialization.json.JsonObject

internal object SynologyPhotoAlbumPreferenceCodec {
    fun validate(target: SynologyPhotoSettingsTarget) {
        if ((target.kind == SynologyPhotoSettingsKind.ALBUM_SORT) != (target.albumId != null) || target.albumId?.let { it <= 0 } == true ||
            (target.kind == SynologyPhotoSettingsKind.LIST_SORT) != (target.listScope != null)) invalid()
    }
    /** 缺省仅供首次展示；写后缺失明确字段不能证明保存成功。 */
    fun album(raw: JsonObject, explicit: Boolean): SynologyPhotoSort? {
        val fieldText = raw.optionalText("sort_by")?.takeIf { it.isNotEmpty() }
        val directionText = raw.optionalText("sort_direction")?.takeIf { it.isNotEmpty() }
        val field = fieldText?.let { value -> SynologyPhotoSort.Field.entries.firstOrNull { it.value == value } ?: invalid() }
        val direction = directionText?.let { value -> SynologyPhotoSort.Direction.entries.firstOrNull { it.value == value } ?: invalid() }
        if (explicit && (field == null || direction == null)) return null
        return SynologyPhotoSort(field ?: SynologyPhotoSort.Field.TAKEN_TIME, direction ?: SynologyPhotoSort.Direction.ASCENDING)
    }
    fun list(raw: JsonObject, scope: SynologyPhotoAlbumListScope): SynologyPhotoAlbumListSort {
        val field = scope.fields.firstOrNull { it.value == raw.text(scope.value + "_sort_by") } ?: invalid()
        val direction = SynologyPhotoSort.Direction.entries.firstOrNull { it.value == raw.text(scope.value + "_sort_direction") } ?: invalid()
        return SynologyPhotoAlbumListSort(field, direction)
    }
    fun display(raw: JsonObject): SynologyPhotoAlbumDisplay = SynologyPhotoAlbumDisplay.entries.firstOrNull { it.value == raw.text("album_display_type") } ?: invalid()
}

package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*

@Composable
internal fun AlbumPreferenceSettings(value: SynologyPhotoSettings, enabled: Boolean, change: (SynologyPhotoSettings) -> Unit) {
    when (value) {
        is SynologyPhotoAlbumSortSettings -> {
            SharingChoice(stringResource(R.string.sp_folder_sort_field), stringResource(value.sort.field.folderLabel()),
                SynologyPhotoSort.Field.entries.map { it to stringResource(it.folderLabel()) }, enabled, "photos_album_sort_field") { change(value.copy(sort = value.sort.copy(field = it))) }
            AlbumSortDirection(value.sort.direction, enabled) { change(value.copy(sort = value.sort.copy(direction = it))) }
        }
        is SynologyPhotoAlbumListSortSettings -> {
            SharingChoice(stringResource(R.string.sp_folder_sort_field), stringResource(value.sort.field.albumFieldLabel()),
                value.scope.fields.map { it to stringResource(it.albumFieldLabel()) }, enabled, "photos_album_list_sort_field") { change(value.copy(sort = value.sort.copy(field = it))) }
            AlbumSortDirection(value.sort.direction, enabled) { change(value.copy(sort = value.sort.copy(direction = it))) }
        }
        is SynologyPhotoAlbumDisplaySettings -> SharingChoice(stringResource(R.string.sp_album_list_display), stringResource(value.display.displayLabel()),
            SynologyPhotoAlbumDisplay.entries.map { it to stringResource(it.displayLabel()) }, enabled, "photos_album_list_display") { change(value.copy(display = it)) }
        else -> Unit
    }
}

@Composable
private fun AlbumSortDirection(value: SynologyPhotoSort.Direction, enabled: Boolean, change: (SynologyPhotoSort.Direction) -> Unit) {
    SharingChoice(stringResource(R.string.sp_folder_sort_direction), stringResource(value.folderLabel()),
        SynologyPhotoSort.Direction.entries.map { it to stringResource(it.folderLabel()) }, enabled, "photos_album_sort_direction", change)
}

internal fun SynologyPhotoSettingsTarget.settingsLabel(): Int = if (kind == SynologyPhotoSettingsKind.LIST_SORT) when (listScope) {
    SynologyPhotoAlbumListScope.WITH_ME -> R.string.sp_album_sort_with_me
    SynologyPhotoAlbumListScope.WITH_OTHERS -> R.string.sp_album_sort_with_others
    else -> kind.settingsLabel()
} else kind.settingsLabel()

private fun SynologyPhotoAlbumDisplay.displayLabel(): Int = if (this == SynologyPhotoAlbumDisplay.ALL) R.string.sp_album_display_all else R.string.sp_album_display_mine
private fun SynologyPhotoAlbumListSort.Field.albumFieldLabel(): Int = when (this) {
    SynologyPhotoAlbumListSort.Field.NAME -> R.string.sp_album_sort_name
    SynologyPhotoAlbumListSort.Field.TYPE -> R.string.sp_album_sort_type
    SynologyPhotoAlbumListSort.Field.START_TIME -> R.string.sp_album_sort_start
    SynologyPhotoAlbumListSort.Field.CREATED_TIME -> R.string.sp_album_sort_created
    SynologyPhotoAlbumListSort.Field.SHARING -> R.string.sp_album_sort_sharing
    SynologyPhotoAlbumListSort.Field.SHARED_TIME -> R.string.sp_album_sort_shared
}

package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotosSection

@StringRes
internal fun SynologyPhotosSection.label() = when (this) {
    SynologyPhotosSection.TIMELINE -> R.string.sp_library_timeline
    SynologyPhotosSection.FOLDERS -> R.string.sp_library_folders
    SynologyPhotosSection.ALBUMS -> R.string.sp_library_albums
    SynologyPhotosSection.SHARING -> R.string.sp_sharing
}

@StringRes
internal fun SynologyPhotoCategory.label() = when (this) {
    SynologyPhotoCategory.RECENT -> R.string.sp_category_recently_added
    SynologyPhotoCategory.PEOPLE -> R.string.sp_category_person
    SynologyPhotoCategory.SUBJECTS -> R.string.sp_category_concept
    SynologyPhotoCategory.LOCATIONS -> R.string.sp_category_location
    SynologyPhotoCategory.TAGS -> R.string.sp_category_tags
    SynologyPhotoCategory.VIDEOS -> R.string.sp_category_videos
}

@StringRes
internal fun SynologyPhotoShareScope.label() = when (this) {
    SynologyPhotoShareScope.WITH_ME -> R.string.sp_sharing_with_me
    SynologyPhotoShareScope.WITH_OTHERS -> R.string.sp_sharing_with_others
    SynologyPhotoShareScope.REQUESTS -> R.string.sp_sharing_requests
}

@Composable
internal fun photoError(error: Throwable): String = stringResource(when ((error as? SynologyPhotoFailure)?.kind) {
    SynologyPhotoFailureKind.UNAVAILABLE -> R.string.sp_service_unavailable
    SynologyPhotoFailureKind.PERMISSION -> R.string.sp_service_permission
    SynologyPhotoFailureKind.INVALID_RESPONSE -> R.string.sp_service_invalid_response
    SynologyPhotoFailureKind.DELETION_UNVERIFIED -> R.string.sp_delete_unverified
    SynologyPhotoFailureKind.TARGET_CHANGED -> R.string.sp_delete_changed
    SynologyPhotoFailureKind.DELETE_DENIED -> R.string.sp_delete_denied
    SynologyPhotoFailureKind.DELETE_FAILED -> R.string.sp_delete_failed
    else -> R.string.sp_media_failed
})

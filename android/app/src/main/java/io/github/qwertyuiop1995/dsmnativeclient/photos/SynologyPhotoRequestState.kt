package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoRequestCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID

internal enum class SynologyPhotoRequestPage { FORM, FOLDERS, ALBUMS, RECORDS }
internal data class SynologyPhotoRequestDraft(
    val id: String = UUID.randomUUID().toString(), val original: SynologyPhotoRequest? = null,
    val settings: SynologyPhotoRequestSettings = SynologyPhotoRequestSettings(), val deleting: Boolean = false,
    val usesDefaultFolder: Boolean = true, val limitsSize: Boolean = false, val sizeMiB: String = "25", val sizeEdited: Boolean = false,
    val replacesRecordId: String? = null,
) {
    fun prepared(access: SynologyPhotoAccess?): SynologyPhotoRequestSettings? {
        var value = settings.copy(subject = settings.subject.trim())
        if (value.space !in access?.spaces.orEmpty()) return null
        if (usesDefaultFolder) {
            if (!canUseDefaultRequestFolder(access, value.space)) return null
            value = value.copy(folderId = null, folderPath = SynologyPhotoRequestSettings.defaultFolderPath(value.subject))
        } else if (value.folderId == null || original?.isFolderValid == false && value.space == original.settings.space && value.folderId == original.settings.folderId) return null
        if (sizeEdited || original == null) {
            val size = sizeMiB.toLongOrNull()
            if (limitsSize && (size == null || size !in 1L..3000L)) return null
            value = value.copy(sizeLimit = if (limitsSize) size!! * 1_048_576L else 0)
        }
        return value.takeIf { runCatching { SynologyPhotoRequestCodec.validate(it) }.isSuccess }
    }
    override fun toString() = "PhotoRequestDraft"
}
internal fun canUseDefaultRequestFolder(access: SynologyPhotoAccess?, space: SynologyPhotoSpace): Boolean =
    space in access?.spaces.orEmpty() && (space == SynologyPhotoSpace.PERSONAL || access?.canManageSharedSpace == true)

internal data class SynologyPhotoRequestState(
    val visible: Boolean = false, val page: SynologyPhotoRequestPage = SynologyPhotoRequestPage.FORM,
    val draft: SynologyPhotoRequestDraft? = null, val loading: Boolean = false, val working: Boolean = false,
    val error: Throwable? = null, val activeId: String? = null,
    val records: List<SynologyPhotoAlbumRecord> = emptyList(), val result: SynologyPhotoRequest? = null,
    val albums: List<SynologyPhotoRequestAlbum> = emptyList(), val albumsLoaded: Boolean = false,
    val albumsLoading: Boolean = false, val albumError: Throwable? = null, val albumSearch: String = "",
    val newAlbumName: String = "", val pendingAlbum: SynologyPhotoAlbumRecord? = null,
    val folders: List<SynologyPhotoCollection> = emptyList(), val folderPath: List<SynologyPhotoCollection> = emptyList(),
    val foldersLoading: Boolean = false, val moreFolders: Boolean = false, val folderError: Throwable? = null,
) { override fun toString() = "PhotoRequestState(page=$page, working=$working)" }

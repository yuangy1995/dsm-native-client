package io.github.qwertyuiop1995.dsmnativeclient.domain

import java.io.File
import java.time.LocalDate
import java.time.YearMonth

/** Photos 项目不是 File Station 文件；身份不从目录、文件名或缩略图单元推导。 */
@kotlinx.serialization.Serializable
enum class SynologyPhotoSpace { PERSONAL, SHARED }

@kotlinx.serialization.Serializable
data class SynologyPhotoId(val profileId: String, val space: SynologyPhotoSpace, val itemId: Long)
@kotlinx.serialization.Serializable
data class SynologyPhotoAlbumContext(val albumId: Long, val ownerUserId: Long, val providerUserId: Long? = null)
data class SynologyPhotoThumbnail(val unitId: Long, val revision: String)
data class SynologyPhoto(
    val id: SynologyPhotoId,
    val filename: String,
    val sizeBytes: Long,
    val takenAt: Double,
    val indexedAt: Double,
    val folderId: Long,
    val mediaType: String,
    val thumbnail: SynologyPhotoThumbnail? = null,
    val width: Int? = null,
    val height: Int? = null,
    val orientation: Int? = null,
    val description: String? = null,
    val camera: String? = null,
    val lens: String? = null,
    val aperture: String? = null,
    val exposureTime: String? = null,
    val focalLength: String? = null,
    val iso: String? = null,
    val duration: Double? = null,
    val rating: Int? = null,
    val address: List<String> = emptyList(),
    val latitude: Double? = null,
    val longitude: Double? = null,
    val albumContext: SynologyPhotoAlbumContext? = null,
    val tags: List<SynologyPhotoChoice>? = null,
    val originalOrientation: Int? = null,
    val similarGroup: SynologyPhotoSimilarGroup? = null,
) {
    val supportsRotation: Boolean get() = mediaType in setOf("photo", "live", "motion_photo", "burst") &&
        filename.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT) !in setOf("gif", "webp") && orientation in 1..8
    val canPlayMotion: Boolean get() = mediaType == "live" && (originalOrientation == null || originalOrientation == orientation)

    fun sameDeletionTarget(other: SynologyPhoto): Boolean =
        id == other.id && filename == other.filename && sizeBytes == other.sizeBytes &&
            takenAt == other.takenAt && indexedAt == other.indexedAt &&
            folderId == other.folderId && mediaType == other.mediaType && albumContext == other.albumContext
}

data class SynologyPhotoPage(
    val items: List<SynologyPhoto>, val offset: Int, val nextOffset: Int, val hasMore: Boolean,
)
data class SynologyPhotoAccess(val spaces: List<SynologyPhotoSpace>, val packageVersion: String, val canManageSharedSpace: Boolean = false,
    val displaySettings: SynologyPhotoDisplaySettings? = null, val supportsOriginalSizeJPEG: Boolean = false)
data class SynologyPhotoDay(val date: LocalDate, val count: Int) {
    val month: YearMonth get() = YearMonth.from(date)
}
data class SynologyPhotoCollection(
    val id: Long, val name: String, val parentId: Long? = null,
    val count: Int? = null, val thumbnail: SynologyPhotoThumbnail? = null,
    val space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL,
    val isConditional: Boolean = false, val isFrozen: Boolean = false, val isTemporary: Boolean = false,
    val path: String? = null,
    val sort: SynologyPhotoSort? = null,
    val folderCovers: List<SynologyPhotoFolderCover> = emptyList(),
    val personVisible: Boolean? = null,
    val personCover: SynologyPhotoPersonCover? = null,
    val conceptVisible: Boolean? = null,
    val conceptDisplayThreshold: Int? = null,
)
enum class SynologyPhotoCategory(val serverId: String, val parameter: String?) {
    RECENT("recently_added", null), PEOPLE("person", "person_id"),
    SUBJECTS("concept", "concept_id"), LOCATIONS("geocoding", "geocoding_id"),
    TAGS("general_tag", "general_tag_id"), VIDEOS("video", null), SIMILAR("similar", null),
}
enum class SynologyPhotoShareScope { WITH_ME, WITH_OTHERS, REQUESTS }
data class SynologyPhotoSharedEntry(
    val id: String, val title: String, val albumId: Long? = null, val url: String? = null, val isTemporary: Boolean = false,
)

@kotlinx.serialization.Serializable
data class SynologyPhotoChoice(val id: Long, val name: String)
data class SynologyPhotoLocation(
    val id: Long, val name: String, val level: Int,
    val children: List<SynologyPhotoLocation> = emptyList(),
)
data class SynologyPhotoFocalRange(val start: Int, val end: Int)
data class SynologyPhotoFraction(val num: Int, val den: Int)
data class SynologyPhotoExposureRange(val start: SynologyPhotoFraction, val end: SynologyPhotoFraction)

data class SynologyPhotoFilter(
    val mediaType: Int? = null,
    val startTime: Long? = null,
    val endTime: Long? = null,
    val personId: Long? = null,
    val locationId: Long? = null,
    val tagId: Long? = null,
    val rating: Int? = null,
    val cameraId: Long? = null,
    val lensId: Long? = null,
    val isoId: Long? = null,
    val apertureId: Long? = null,
    val focalRange: SynologyPhotoFocalRange? = null,
    val exposureRange: SynologyPhotoExposureRange? = null,
) {
    val isActive: Boolean get() = this != SynologyPhotoFilter()
}

data class SynologyPhotoFilterOptions(
    val people: List<SynologyPhotoChoice> = emptyList(),
    val locations: List<SynologyPhotoLocation> = emptyList(),
    val tags: List<SynologyPhotoChoice> = emptyList(),
    val cameras: List<SynologyPhotoChoice> = emptyList(),
    val lenses: List<SynologyPhotoChoice> = emptyList(),
    val iso: List<SynologyPhotoChoice> = emptyList(),
    val apertures: List<SynologyPhotoChoice> = emptyList(),
    val focalRanges: List<SynologyPhotoFocalRange> = emptyList(),
    val exposureRanges: List<SynologyPhotoExposureRange> = emptyList(),
)

sealed interface SynologyPhotoQuery {
    data class Timeline(val start: Long, val end: Long) : SynologyPhotoQuery
    data class Similar(val start: Long, val end: Long) : SynologyPhotoQuery
    data class Search(val keyword: String, val start: Long, val end: Long) : SynologyPhotoQuery
    data class Filtered(val filter: SynologyPhotoFilter, val start: Long, val end: Long) : SynologyPhotoQuery
    data class Category(val category: SynologyPhotoCategory, val id: Long, val start: Long, val end: Long) : SynologyPhotoQuery
    data class Folder(val id: Long, val sort: SynologyPhotoSort = SynologyPhotoSort()) : SynologyPhotoQuery
    data class Album(val id: Long, val sort: SynologyPhotoSort = SynologyPhotoSort(direction = SynologyPhotoSort.Direction.DESCENDING)) : SynologyPhotoQuery
    data object Recent : SynologyPhotoQuery
}

enum class SynologyPhotoFailureKind {
    UNAVAILABLE, PERMISSION, INVALID_RESPONSE, MEDIA, LENGTH_MISMATCH,
    DELETION_UNVERIFIED, TARGET_CHANGED, DELETE_DENIED, DELETE_FAILED,
}
class SynologyPhotoFailure(val kind: SynologyPhotoFailureKind, cause: Throwable? = null) :
    RuntimeException(kind.name, cause)

/** 所有方法使用已发现且版本匹配的 Photos 接口；不回退文件系统扫描。 */
interface SynologyPhotosServing {
    val profileId: String
    val canDeleteOriginals: Boolean get() = false
    val canUploadPhotos: Boolean get() = false
    val canEditPhotos: Boolean get() = false
    val canManageAlbums: Boolean get() = false
    val canManageConditionAlbums: Boolean get() = false
    val canManageAlbumSharing: Boolean get() = false
    val canManagePhotoRequests: Boolean get() = false
    val canManageFolders: Boolean get() = false
    val canManageSharedMembers: Boolean get() = false
    suspend fun sharedMembers(): SynologyPhotoSharedMembers = unsupported()
    suspend fun sharedMemberCandidates(): List<SynologyPhotoShareRecipient> = unsupported()
    suspend fun sharedMemberFolders(member: SynologyPhotoShareMemberId): List<SynologyPhotoMemberFolder> = unsupported()
    val canManageFolderSharing: Boolean get() = false
    fun canManageSettings(kind: SynologyPhotoSettingsKind): Boolean = false
    suspend fun photoSettings(kind: SynologyPhotoSettingsKind): SynologyPhotoSettings = unsupported()
    suspend fun photoSettings(target: SynologyPhotoSettingsTarget): SynologyPhotoSettings =
        if ((target.kind.userSetting || target.kind in setOf(SynologyPhotoSettingsKind.SHARED, SynologyPhotoSettingsKind.GLOBAL, SynologyPhotoSettingsKind.CACHE)) && target.albumId == null && target.listScope == null) photoSettings(target.kind) else unsupported()
    val canTransferPhotos: Boolean get() = false
    val canDeleteFolders: Boolean get() = false
    val canControlBackgroundTasks: Boolean get() = false
    val canRespondToCodecPrompt: Boolean get() = false
    val canGenerateCodecPreviews: Boolean get() = false
    fun canRegeneratePreviews(space: SynologyPhotoSpace): Boolean = false
    suspend fun pendingPreviewRegenerations(space: SynologyPhotoSpace): List<SynologyPhoto> = unsupported()
    suspend fun preparePreviewRegeneration(photos: List<SynologyPhoto>, resuming: Boolean): SynologyPhotoAlbumCheckpoint = unsupported()
    suspend fun performPreviewRegeneration(checkpoint: SynologyPhotoAlbumCheckpoint, cache: File,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint = unsupported()
    fun canGenerateAutomaticPreviews(space: SynologyPhotoSpace): Boolean = false
    suspend fun automaticPreviewEnabled(): Boolean = unsupported()
    suspend fun automaticPreviewTasks(space: SynologyPhotoSpace, support: SynologyPhotoPreviewConversionSupport): List<SynologyPhotoAutomaticPreviewTask> = unsupported()
    suspend fun automaticPreviewTasks(photo: SynologyPhoto, support: SynologyPhotoPreviewConversionSupport): List<SynologyPhotoAutomaticPreviewTask> = unsupported()
    suspend fun downloadAutomaticPreviewSource(task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport, destination: File): Unit = unsupported()
    suspend fun prepareAutomaticPreview(task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport): SynologyPhotoAlbumCheckpoint = unsupported()
    suspend fun performAutomaticPreview(checkpoint: SynologyPhotoAlbumCheckpoint, cache: File,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint = unsupported()
    suspend fun reviewAutomaticPreview(checkpoint: SynologyPhotoAlbumCheckpoint, cache: File,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint = unsupported()
    suspend fun codecPrompt(): SynologyPhotoCodecPrompt = unsupported()
    suspend fun continueCodecPrompt(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint = unsupported()
    fun canMaintainLibrary(space: SynologyPhotoSpace): Boolean = false
    suspend fun maintenanceStatus(space: SynologyPhotoSpace): SynologyPhotoMaintenanceStatus = unsupported()
    suspend fun backgroundTasks(): List<SynologyPhotoBackgroundTask> = unsupported()
    suspend fun backgroundTaskErrors(task: SynologyPhotoBackgroundTask): List<SynologyPhotoBackgroundError> = unsupported()
    suspend fun backgroundTaskTarget(task: SynologyPhotoBackgroundTask): List<SynologyPhotoCollection> = unsupported()
    fun canDelete(photo: SynologyPhoto): Boolean = canDeleteOriginals && photo.id.profileId == profileId &&
        photo.albumContext == null
    suspend fun access(): SynologyPhotoAccess
    suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery? = null): List<SynologyPhotoDay>
    suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage
    suspend fun rootFolder(space: SynologyPhotoSpace): SynologyPhotoCollection = unsupported()
    suspend fun folders(space: SynologyPhotoSpace, parentId: Long, offset: Int, limit: Int): List<SynologyPhotoCollection> = unsupported()
    suspend fun folders(space: SynologyPhotoSpace, parentId: Long, offset: Int, limit: Int, direction: SynologyPhotoSort.Direction): List<SynologyPhotoCollection> =
        if (direction == SynologyPhotoSort.Direction.ASCENDING) folders(space, parentId, offset, limit) else unsupported()
    suspend fun folderAccess(space: SynologyPhotoSpace, id: Long): SynologyPhotoFolderAccess = unsupported()
    suspend fun folderSharing(folder: SynologyPhotoFolderSnapshot): SynologyPhotoFolderSharing = unsupported()
    suspend fun folderSharingRecipients(): List<SynologyPhotoShareRecipient> = unsupported()
    suspend fun transferDuplicate(): SynologyPhotoTransferDuplicate = unsupported()
    suspend fun folderThumbnail(folder: SynologyPhotoCollection, cover: SynologyPhotoFolderCover): ByteArray = unsupported()
    suspend fun albums(offset: Int, limit: Int): List<SynologyPhotoCollection> = unsupported()
    suspend fun albums(offset: Int, limit: Int, display: SynologyPhotoAlbumDisplay?, sort: SynologyPhotoAlbumListSort?): List<SynologyPhotoCollection> =
        if (display == null && sort == null) albums(offset, limit) else unsupported()
    suspend fun categories(space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL): Set<SynologyPhotoCategory> = unsupported()
    suspend fun categoryItems(category: SynologyPhotoCategory, offset: Int, limit: Int, space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL): List<SynologyPhotoCollection> = unsupported()
    fun canManageSimilar(space: SynologyPhotoSpace): Boolean = false
    suspend fun similarPhotos(photo: SynologyPhoto): SynologyPhotoSimilarDetail = unsupported()
    suspend fun similarGroupDetails(group: SynologyPhotoSimilarGroup): SynologyPhotoSimilarDetail? = unsupported()
    suspend fun similarStatus(space: SynologyPhotoSpace): SynologyPhotoSimilarStatus = unsupported()
    suspend fun prepareSimilarChange(detail: SynologyPhotoSimilarDetail, edit: SynologyPhotoSimilarEdit,
        selectedIds: List<Long> = emptyList()): SynologyPhotoAlbumCheckpoint = unsupported()
    suspend fun prepareSimilarUndo(original: SynologyPhotoAlbumCheckpoint): SynologyPhotoAlbumCheckpoint = unsupported()
    fun canManagePeople(space: SynologyPhotoSpace, merging: Boolean = false): Boolean = false
    fun canManageConcepts(space: SynologyPhotoSpace, editingPhotos: Boolean = false): Boolean = false
    suspend fun managementConcepts(space: SynologyPhotoSpace): List<SynologyPhotoCollection> = unsupported()
    suspend fun concept(id: Long, space: SynologyPhotoSpace): SynologyPhotoCollection = unsupported()
    suspend fun conceptThumbnail(concept: SynologyPhotoCollection): ByteArray = unsupported()
    suspend fun prepareConceptChange(action: SynologyPhotoAlbumAction, originals: List<SynologyPhotoConceptSnapshot>,
        photos: List<SynologyPhoto> = emptyList(), visible: Boolean? = null): SynologyPhotoAlbumCheckpoint = unsupported()
    suspend fun managementPeople(space: SynologyPhotoSpace, includingHidden: Boolean = false): List<SynologyPhotoCollection> = unsupported()
    suspend fun personThumbnail(person: SynologyPhotoCollection): ByteArray = unsupported()
    suspend fun preparePeopleChange(action: SynologyPhotoAlbumAction, originals: List<SynologyPhotoPersonSnapshot>,
        name: String? = null, visible: Boolean? = null): SynologyPhotoAlbumCheckpoint = unsupported()
    fun canManagePersonFaces(space: SynologyPhotoSpace): Boolean = false
    fun canEditPhotoFaces(photo: SynologyPhoto): Boolean = false
    suspend fun photoFaces(photo: SynologyPhoto): List<SynologyPhotoFaceRegion> = unsupported()
    suspend fun prepareManualFaces(photo: SynologyPhoto, originals: List<SynologyPhotoFaceSnapshot>,
        changes: List<SynologyPhotoFaceChange>): SynologyPhotoAlbumCheckpoint = unsupported()
    suspend fun performManualFaces(checkpoint: SynologyPhotoAlbumCheckpoint, images: Map<String, ByteArray>,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint = unsupported()
    suspend fun personFaces(personId: Long, photos: List<SynologyPhoto>): List<SynologyPhotoPersonFace> = unsupported()
    suspend fun faceThumbnail(face: SynologyPhotoPersonFace): ByteArray = unsupported()
    suspend fun preparePersonFaces(action: SynologyPhotoAlbumAction, original: SynologyPhotoPersonSnapshot,
        photos: List<SynologyPhoto>, faces: List<SynologyPhotoPersonFace>, target: SynologyPhotoPersonSnapshot? = null,
        name: String? = null): SynologyPhotoAlbumCheckpoint = unsupported()
    suspend fun sharedEntries(scope: SynologyPhotoShareScope, offset: Int, limit: Int): List<SynologyPhotoSharedEntry> = unsupported()
    suspend fun sharedEntries(scope: SynologyPhotoShareScope, offset: Int, limit: Int, sort: SynologyPhotoAlbumListSort?): List<SynologyPhotoSharedEntry> =
        if (sort == null) sharedEntries(scope, offset, limit) else unsupported()
    suspend fun filterOptions(space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL): SynologyPhotoFilterOptions = unsupported()
    suspend fun thumbnail(photo: SynologyPhoto, large: Boolean = false): ByteArray = unsupported()
    suspend fun details(photo: SynologyPhoto): SynologyPhoto = unsupported()
    suspend fun videoSource(photo: SynologyPhoto): RandomAccessMediaSource = unsupported()
    suspend fun downloadOriginal(photo: SynologyPhoto, destination: File, progress: (Long, Long) -> Unit = { _, _ -> }): Unit = unsupported()
    suspend fun download(photo: SynologyPhoto, format: SynologyPhotoDownloadFormat, destination: File,
        progress: (Long, Long) -> Unit = { _, _ -> }): SynologyPhotoDownloadFormat {
        if (format != SynologyPhotoDownloadFormat.ORIGINAL) unsupported()
        downloadOriginal(photo, destination, progress)
        return SynologyPhotoDownloadFormat.ORIGINAL
    }
    suspend fun downloadArchive(target: SynologyPhotoArchiveTarget, format: SynologyPhotoDownloadFormat, destination: File,
        progress: (Long, Long) -> Unit = { _, _ -> }): Unit = unsupported()
    suspend fun prepareDeletion(photo: SynologyPhoto): Unit = unsupported()
    suspend fun deletionTarget(checkpoint: SynologyPhotoDeletionCheckpoint): SynologyPhoto = unsupported()
    suspend fun performPhotoDeletion(photo: SynologyPhoto, checkpoint: SynologyPhotoDeletionCheckpoint,
        save: (SynologyPhotoDeletionCheckpoint) -> Unit): SynologyPhotoDeletionCheckpoint = unsupported()
    suspend fun reviewPhotoDeletion(checkpoint: SynologyPhotoDeletionCheckpoint,
        save: (SynologyPhotoDeletionCheckpoint) -> Unit): SynologyPhotoDeletionCheckpoint = unsupported()
    suspend fun uploadIdentity(): Long = unsupported()
    suspend fun uploadDuplicatePolicy(): SynologyPhotoUploadDuplicate = unsupported()
    suspend fun addableAlbums(offset: Int, limit: Int): List<SynologyPhotoCollection> = unsupported()
    suspend fun prepareUploadTarget(target: SynologyPhotoUploadTarget): Unit = unsupported()
    suspend fun performPhotoUpload(checkpoint: SynologyPhotoUploadCheckpoint, source: File?,
        save: (SynologyPhotoUploadCheckpoint) -> Unit, progress: (Long, Long) -> Unit = { _, _ -> }): SynologyPhotoUploadCheckpoint = unsupported()
    suspend fun reviewPhotoUpload(checkpoint: SynologyPhotoUploadCheckpoint,
        save: (SynologyPhotoUploadCheckpoint) -> Unit): SynologyPhotoUploadCheckpoint = unsupported()
    suspend fun photoEditIdentity(): Long = unsupported()
    suspend fun photoTags(space: SynologyPhotoSpace, offset: Int, limit: Int): List<SynologyPhotoChoice> = unsupported()
    suspend fun preparePhotoEdit(checkpoint: SynologyPhotoEditCheckpoint): Unit = unsupported()
    suspend fun performPhotoEdit(checkpoint: SynologyPhotoEditCheckpoint,
        save: (SynologyPhotoEditCheckpoint) -> Unit): SynologyPhotoEditCheckpoint = unsupported()
    suspend fun reviewPhotoEdit(checkpoint: SynologyPhotoEditCheckpoint,
        save: (SynologyPhotoEditCheckpoint) -> Unit): SynologyPhotoEditCheckpoint = unsupported()
    suspend fun albumAccess(id: Long): SynologyPhotoAlbumAccess = unsupported()
    suspend fun albumCondition(id: Long): SynologyPhotoAlbumCondition = unsupported()
    suspend fun frozenAlbum(id: Long): SynologyPhotoFrozenAlbum = unsupported()
    suspend fun temporaryAlbum(id: Long): SynologyPhotoTemporaryAlbum = unsupported()
    suspend fun albumSharing(id: Long): SynologyPhotoAlbumSharing = unsupported()
    suspend fun sharingRecipients(): List<SynologyPhotoShareRecipient> = unsupported()
    suspend fun photoRequest(id: String): SynologyPhotoRequest = unsupported()
    suspend fun restoredPhotoRequest(checkpoint: SynologyPhotoAlbumCheckpoint): SynologyPhotoRequest? = unsupported()
    suspend fun photoRequestAlbums(): List<SynologyPhotoRequestAlbum> = unsupported()
    suspend fun photoRequestFolder(space: SynologyPhotoSpace, id: Long): SynologyPhotoCollection = unsupported()
    suspend fun preparePhotoRequest(checkpoint: SynologyPhotoAlbumCheckpoint, change: SynologyPhotoRequestChange): Unit = unsupported()
    suspend fun performPhotoRequest(checkpoint: SynologyPhotoAlbumCheckpoint, change: SynologyPhotoRequestChange,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint = unsupported()
    suspend fun conditionSuggestions(keyword: String, space: SynologyPhotoSpace): Map<String, List<SynologyPhotoConditionOption>> = unsupported()
    suspend fun conditionItemCount(condition: SynologyPhotoAlbumCondition): Long = unsupported()
    suspend fun albumThumbnail(id: Long): ByteArray = unsupported()
    suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint): Unit = unsupported()
    suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint = unsupported()
    suspend fun performPhotoSharing(checkpoint: SynologyPhotoAlbumCheckpoint, password: String?,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint = unsupported()
    suspend fun performPhotoFolderSharing(checkpoint: SynologyPhotoAlbumCheckpoint, password: String?,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint = unsupported()
    suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint = unsupported()

    private fun unsupported(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.UNAVAILABLE)
}

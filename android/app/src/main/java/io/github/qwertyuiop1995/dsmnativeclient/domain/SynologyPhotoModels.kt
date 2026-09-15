package io.github.qwertyuiop1995.dsmnativeclient.domain

import java.io.File
import java.time.LocalDate
import java.time.YearMonth
import java.util.UUID

/** Photos 项目不是 File Station 文件；身份不从目录、文件名或缩略图单元推导。 */
enum class SynologyPhotoSpace { PERSONAL, SHARED }

data class SynologyPhotoId(val profileId: String, val space: SynologyPhotoSpace, val itemId: Long)
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
) {
    fun sameDeletionTarget(other: SynologyPhoto): Boolean =
        id == other.id && filename == other.filename && sizeBytes == other.sizeBytes &&
            takenAt == other.takenAt && indexedAt == other.indexedAt &&
            folderId == other.folderId && mediaType == other.mediaType
}

data class SynologyPhotoPage(
    val items: List<SynologyPhoto>, val offset: Int, val nextOffset: Int, val hasMore: Boolean,
)
data class SynologyPhotoAccess(val spaces: List<SynologyPhotoSpace>, val packageVersion: String)
data class SynologyPhotoDay(val date: LocalDate, val count: Int) {
    val month: YearMonth get() = YearMonth.from(date)
}
data class SynologyPhotoCollection(
    val id: Long, val name: String, val parentId: Long? = null,
    val count: Int? = null, val thumbnail: SynologyPhotoThumbnail? = null,
)
enum class SynologyPhotoCategory(val serverId: String, val parameter: String?) {
    RECENT("recently_added", null), PEOPLE("person", "person_id"),
    SUBJECTS("concept", "concept_id"), LOCATIONS("geocoding", "geocoding_id"),
    TAGS("general_tag", "general_tag_id"), VIDEOS("video", null),
}
enum class SynologyPhotoShareScope { WITH_ME, WITH_OTHERS, REQUESTS }
data class SynologyPhotoSharedEntry(
    val id: String, val title: String, val albumId: Long? = null, val url: String? = null,
)

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
    data class Search(val keyword: String, val start: Long, val end: Long) : SynologyPhotoQuery
    data class Filtered(val filter: SynologyPhotoFilter, val start: Long, val end: Long) : SynologyPhotoQuery
    data class Category(val category: SynologyPhotoCategory, val id: Long, val start: Long, val end: Long) : SynologyPhotoQuery
    data class Folder(val id: Long) : SynologyPhotoQuery
    data class Album(val id: Long) : SynologyPhotoQuery
    data object Recent : SynologyPhotoQuery
}

enum class SynologyPhotoFailureKind {
    UNAVAILABLE, PERMISSION, INVALID_RESPONSE, MEDIA, LENGTH_MISMATCH,
    DELETION_UNVERIFIED, TARGET_CHANGED, DELETE_DENIED, DELETE_FAILED,
}
class SynologyPhotoFailure(val kind: SynologyPhotoFailureKind, cause: Throwable? = null) :
    RuntimeException(kind.name, cause)

enum class SynologyPhotoDeletionResult { CONFIRMED, PENDING_REVIEW }

/** 所有方法使用已发现且版本匹配的 Photos 接口；不回退文件系统扫描。 */
interface SynologyPhotosServing {
    val profileId: String
    val canDeleteOriginals: Boolean get() = false
    suspend fun access(): SynologyPhotoAccess
    suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery? = null): List<SynologyPhotoDay>
    suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage
    suspend fun rootFolder(space: SynologyPhotoSpace): SynologyPhotoCollection = unsupported()
    suspend fun folders(space: SynologyPhotoSpace, parentId: Long, offset: Int, limit: Int): List<SynologyPhotoCollection> = unsupported()
    suspend fun albums(offset: Int, limit: Int): List<SynologyPhotoCollection> = unsupported()
    suspend fun categories(): Set<SynologyPhotoCategory> = unsupported()
    suspend fun categoryItems(category: SynologyPhotoCategory, offset: Int, limit: Int): List<SynologyPhotoCollection> = unsupported()
    suspend fun sharedEntries(scope: SynologyPhotoShareScope, offset: Int, limit: Int): List<SynologyPhotoSharedEntry> = unsupported()
    suspend fun filterOptions(): SynologyPhotoFilterOptions = unsupported()
    suspend fun thumbnail(photo: SynologyPhoto, large: Boolean = false): ByteArray = unsupported()
    suspend fun details(photo: SynologyPhoto): SynologyPhoto = unsupported()
    suspend fun videoSource(photo: SynologyPhoto): RandomAccessMediaSource = unsupported()
    suspend fun downloadOriginal(photo: SynologyPhoto, destination: File, progress: (Long, Long) -> Unit = { _, _ -> }): Unit = unsupported()
    suspend fun prepareDeletion(photo: SynologyPhoto): Unit = unsupported()
    suspend fun deletePhoto(photo: SynologyPhoto, operationId: UUID): SynologyPhotoDeletionResult = unsupported()
    suspend fun reviewDeletion(photo: SynologyPhoto): SynologyPhotoDeletionResult = unsupported()

    private fun unsupported(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.UNAVAILABLE)
}

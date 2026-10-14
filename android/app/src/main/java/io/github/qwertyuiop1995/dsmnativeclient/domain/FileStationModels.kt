package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

enum class FileLocationKind {
    SHARE,
    DIRECTORY,
    RECYCLE_BIN,
    FAVORITE,
    RECENT,
    REMOTE,
}

data class FileItem(
    val path: String,
    val name: String,
    val isDirectory: Boolean,
    val size: Long = 0,
    val modifiedAtEpochSeconds: Long? = null,
    val accessedAtEpochSeconds: Long? = null,
    val owner: String? = null,
    val mimeType: String? = null,
    val canRead: Boolean = true,
    val canWrite: Boolean = false,
    val canDelete: Boolean = false,
    val isFavorite: Boolean = false,
    val mountPointType: String? = null,
) {
    val extension: String get() = name.substringAfterLast('.', "").lowercase()
}

enum class StorageFileCategory { IMAGE, VIDEO, AUDIO, DOCUMENT, ARCHIVE, OTHER, NO_EXTENSION }

data class StorageAnalysisShare(
    val name: String,
    val path: String,
    val usedBytes: Long,
    val fileCount: Int,
)

data class StorageAnalysisCategory(
    val category: StorageFileCategory,
    val usedBytes: Long,
    val fileCount: Int,
)

data class StorageAnalysisOwner(
    val name: String?,
    val usedBytes: Long,
    val fileCount: Int,
)

data class StorageDuplicateGroup(
    val checksum: String,
    val sizeBytes: Long,
    val files: List<FileItem>,
) {
    val reclaimableBytes: Long get() = (files.size - 1).coerceAtLeast(0) * sizeBytes
}

data class StorageAnalysisSnapshot(
    val generatedAtEpochSeconds: Long,
    val shares: List<StorageAnalysisShare>,
    val categories: List<StorageAnalysisCategory>,
    val owners: List<StorageAnalysisOwner>,
    val largeFiles: List<FileItem>,
    val recentlyModifiedFiles: List<FileItem>,
    val leastRecentlyAccessedFiles: List<FileItem>,
    val duplicateGroups: List<StorageDuplicateGroup>,
    val scannedFileCount: Int,
    val scannedBytes: Long,
    val duplicateCheckWasLimited: Boolean,
    val duplicateCheckUnavailable: Boolean,
)

data class StorageAnalysisProgress(
    val phase: String,
    val completed: Int,
    val total: Int,
) {
    val fraction: Float? get() = total.takeIf { it > 0 }?.let { completed.toFloat() / it }
}

data class FilePage(
    val items: List<FileItem>,
    val total: Int,
    val offset: Int,
)

/** File Station 在 NAS 上执行的后台任务类别。 */
@Serializable
enum class FileBackgroundTaskKind { COPY_OR_MOVE, DELETE, COMPRESS, EXTRACT }

/** `FINISHED` 只表示任务已经结束，不代表任务成功。 */
enum class FileBackgroundTaskState { ACTIVE, FINISHED }

/**
 * NAS 后台文件任务的脱敏摘要。
 *
 * 此模型刻意不包含任务参数、源/目标路径、当前处理路径或服务端消息，避免敏感内容进入
 * 界面、日志或持久化数据。
 */
data class FileBackgroundTaskSummary(
    val id: String,
    val kind: FileBackgroundTaskKind,
    val state: FileBackgroundTaskState,
    val progress: Double?,
    val createdAtEpochSeconds: Long?,
    val processedItemCount: Int?,
    val totalItemCount: Int?,
    val processedBytes: Long?,
    val totalBytes: Long?,
    val apiVersion: Int? = null,
    val method: String? = null,
    /** 控制身份保留完整创建时间；旧脱敏快照没有此字段，刷新前只能查看。 */
    val controlCreatedAtSeconds: Double? = null,
)

data class FileBackgroundTaskPage(
    val tasks: List<FileBackgroundTaskSummary>,
    val offset: Int,
    val nextOffset: Int,
    val total: Int,
    val hasMore: Boolean,
)

data class FavoriteLocation(
    val path: String,
    val name: String,
)

@Serializable
data class FileShareLink(
    val id: String,
    val name: String,
    val path: String,
    val url: String,
    val hasPassword: Boolean = false,
    val expiresAt: String? = null,
    val availableAt: String? = null,
    val passwordKnown: Boolean = false,
    val expirationKnown: Boolean = false,
    val availabilityKnown: Boolean = false,
    val status: FileShareStatus = FileShareStatus.UNKNOWN,
    val advanced: FileShareAdvancedDetails? = null,
)

data class RecycleLocation(
    val recycleRoot: String,
    val relativePath: String,
    val originalPath: String,
    val originalParentPath: String,
) {
    companion object {
        fun from(recyclePath: String): RecycleLocation? {
            val normalized = if (recyclePath.startsWith('/')) recyclePath else "/$recyclePath"
            val components = normalized.split('/').filter(String::isNotBlank)
            val recycleIndex = components.indexOf("#recycle")
            if (recycleIndex != 1 || components.size <= recycleIndex + 1) return null
            val share = components.first()
            val tail = components.drop(recycleIndex + 1)
            val relative = "/${tail.joinToString("/")}"
            val original = "/$share$relative"
            return RecycleLocation(
                recycleRoot = "/$share/#recycle",
                relativePath = relative,
                originalPath = original,
                originalParentPath = original.substringBeforeLast('/', "/$share"),
            )
        }
    }
}

@Serializable
enum class TransferDirection { DOWNLOAD, UPLOAD, SERVER }

@Serializable
enum class TransferState { WAITING, RUNNING, PAUSED, CANCELLING, SUCCEEDED, FAILED, CANCELLED }

enum class FileServerMutationOperation { COMPRESS, EXTRACT }

enum class FileServerMutationVerification { MATCHES, DIFFERS, DISAPPEARED, UNAVAILABLE }

data class FileServerMutationExpectedOutput(
    val path: String,
    val isDirectory: Boolean,
    val requiresNonEmptyFile: Boolean = false,
    val expectedBytes: Long? = null,
    val requiresTaskCompletion: Boolean = false,
)

data class FileServerMutationTarget(
    val profileId: String,
    val module: Module,
    val operation: FileServerMutationOperation,
    val sourceBaselines: List<FileItem>,
    val destinationFolderBaseline: FileItem,
    val expectedOutputs: List<FileServerMutationExpectedOutput> = emptyList(),
)

data class FileServerMutationLifecycle(
    val target: FileServerMutationTarget,
    val result: MutationResult? = null,
    val failure: DsmFailure? = null,
    val refreshInProgress: Boolean = false,
    val refreshCompleted: Boolean = false,
    val refreshFailure: DsmFailure? = null,
    val verification: FileServerMutationVerification? = null,
    val generation: Long = 0L,
)

data class UploadMutationLifecycle(
    val directoryResult: MutationResult? = null,
    val uploadResult: MutationResult? = null,
)

data class TransferTask(
    val id: String,
    val title: String,
    val detail: String,
    val direction: TransferDirection,
    val state: TransferState,
    val completedBytes: Long = 0,
    val totalBytes: Long? = null,
    val errorMessage: String? = null,
    val requiresRefresh: Boolean = false,
    val startedAtEpochMillis: Long? = null,
    val fileServerMutation: FileServerMutationLifecycle? = null,
    val uploadMutation: UploadMutationLifecycle? = null,
    val canCancel: Boolean = true,
) {
    val progress: Float?
        get() = totalBytes?.takeIf { it > 0 }?.let {
            (completedBytes.toDouble() / it.toDouble()).coerceIn(0.0, 1.0).toFloat()
        }

    fun speedBytesPerSecond(nowEpochMillis: Long = System.currentTimeMillis()): Long? =
        transferSpeedBytesPerSecond(completedBytes, startedAtEpochMillis, nowEpochMillis)

    fun estimatedRemainingSeconds(nowEpochMillis: Long = System.currentTimeMillis()): Long? {
        val total = totalBytes ?: return null
        val speed = speedBytesPerSecond(nowEpochMillis)?.takeIf { it > 0 } ?: return null
        return ((total - completedBytes).coerceAtLeast(0) + speed - 1) / speed
    }
}

internal fun transferSpeedBytesPerSecond(
    completedBytes: Long,
    startedAtEpochMillis: Long?,
    nowEpochMillis: Long,
): Long? {
    val started = startedAtEpochMillis ?: return null
    val elapsedMillis = nowEpochMillis - started
    if (completedBytes <= 0 || elapsedMillis < 1_000) return null
    return (completedBytes * 1_000L / elapsedMillis).takeIf { it > 0 }
}

enum class ArchiveFormat(val apiValue: String, val fileExtension: String) {
    ZIP("zip", "zip"),
    SEVEN_ZIP("7z", "7z"),
}

enum class ArchiveCompressionLevel(val apiValue: String) {
    STORE("store"),
    FASTEST("fastest"),
    MODERATE("moderate"),
    BEST("best"),
}

data class ArchiveItem(
    val id: Int,
    val name: String,
    val path: String,
    val isDirectory: Boolean,
    val size: Long? = null,
)

package io.github.qwertyuiop1995.dsmnativeclient

import android.net.Uri
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*

data class PhotoMoveLocation(
    val path: String,
    val canWrite: Boolean,
    val baseline: FileItem? = null,
)

data class PhotoMoveState(
    val item: PhotoItem,
    val space: PhotoSpace,
    val location: PhotoMoveLocation,
    val history: List<PhotoMoveLocation> = emptyList(),
)

enum class FileCopyMoveOperation {
    COPY,
    MOVE,
}

data class FileCopyMoveLocation(
    val path: String,
    val canWrite: Boolean,
)

data class FileCopyMoveState(
    val items: List<FileItem>,
    val operation: FileCopyMoveOperation,
    val sourceProfileId: String = "",
    val targetProfileId: String = sourceProfileId,
    val targetProfiles: List<NasProfile> = emptyList(),
    val location: FileCopyMoveLocation = FileCopyMoveLocation("", canWrite = false),
    val history: List<FileCopyMoveLocation> = emptyList(),
    val destinationBaselines: Map<String, FileItem> = emptyMap(),
)

enum class FileStationMutationOperation {
    TEXT_SAVE,
    CREATE_FOLDER,
    RENAME,
    FAVORITE_ADD,
    FAVORITE_REMOVE,
    FAVORITE_ADD_BATCH,
    COPY,
    MOVE,
    DELETE,
    RESTORE,
    SHARE_CREATE,
    SHARE_DELETE,
}

enum class FileStationMutationVerification {
    MATCHES,
    DIFFERS,
    DISAPPEARED,
    UNAVAILABLE,
}

data class FileStationMutationTarget(
    val profileId: String,
    val module: Module,
    val operation: FileStationMutationOperation,
    val sourceBaselines: List<FileItem> = emptyList(),
    val parentPath: String? = null,
    val parentBaseline: FileItem? = null,
    val destinationPath: String? = null,
    val destinationBaseline: FileItem? = null,
    val requestedName: String? = null,
    val shareLinkBaselines: List<FileShareLink> = emptyList(),
    val expectedContentSha256: String? = null,
    val expectedContentByteCount: Long? = null,
) {
    init {
        require(profileId.isNotBlank()) { "file_station.invalid_profile" }
        require(sourceBaselines.map(FileItem::path).distinct().size == sourceBaselines.size) {
            "file_station.duplicate_source"
        }
        require(shareLinkBaselines.map(FileShareLink::id).distinct().size == shareLinkBaselines.size) {
            "file_station.duplicate_share_link"
        }
        when (operation) {
            FileStationMutationOperation.TEXT_SAVE ->
                require(
                    sourceBaselines.size == 1 && !sourceBaselines.single().isDirectory &&
                        !expectedContentSha256.isNullOrBlank() &&
                        expectedContentByteCount != null && expectedContentByteCount >= 0,
                ) {
                    "file_station.invalid_text_save_target"
                }
            FileStationMutationOperation.CREATE_FOLDER ->
                require(
                    parentBaseline != null && parentBaseline.isDirectory &&
                        parentBaseline.path == parentPath && !requestedName.isNullOrBlank(),
                ) {
                    "file_station.invalid_create_target"
                }
            FileStationMutationOperation.RENAME ->
                require(sourceBaselines.size == 1 && !requestedName.isNullOrBlank()) {
                    "file_station.invalid_rename_target"
                }
            FileStationMutationOperation.COPY,
            FileStationMutationOperation.MOVE,
            -> require(
                sourceBaselines.isNotEmpty() &&
                    (destinationBaseline == null ||
                        destinationBaseline.isDirectory && destinationBaseline.path == destinationPath),
            ) {
                "file_station.invalid_transfer_target"
            }
            FileStationMutationOperation.DELETE ->
                require(sourceBaselines.isNotEmpty()) { "file_station.invalid_delete_target" }
            FileStationMutationOperation.SHARE_DELETE ->
                require(shareLinkBaselines.isNotEmpty()) { "file_station.invalid_share_target" }
            else -> require(sourceBaselines.isNotEmpty()) { "file_station.missing_source_baseline" }
        }
    }
}

data class FileStationMutationWorkspaceState(
    val draftTarget: FileStationMutationTarget? = null,
    val target: FileStationMutationTarget? = null,
    val editorVisible: Boolean = false,
    val nameDraft: String = "",
    val editorParentBaseline: FileItem? = null,
    val editorSourceBaseline: FileItem? = null,
    val confirmationRequested: Boolean = false,
    val mutationInProgress: Boolean = false,
    val mutationResult: MutationResult? = null,
    val createdShareLink: FileShareLink? = null,
    val mutationFailure: DsmFailure? = null,
    val mutationRefreshFailure: DsmFailure? = null,
    val mutationRefreshInProgress: Boolean = false,
    val mutationRefreshCompleted: Boolean = false,
    val mutationVerification: FileStationMutationVerification? = null,
    val mutationGeneration: Long = 0L,
)


internal fun fileStationMutationCallbackMatches(
    repositoryMatches: Boolean,
    profileMatches: Boolean,
    stateTarget: FileStationMutationTarget?,
    callbackTarget: FileStationMutationTarget,
    stateGeneration: Long,
    callbackGeneration: Long,
    globalGeneration: Long,
): Boolean = repositoryMatches && profileMatches && stateTarget == callbackTarget &&
    stateGeneration == callbackGeneration && callbackGeneration == globalGeneration

internal fun fileStationMutationBlocksOrdinaryLoad(
    state: FileStationMutationWorkspaceState,
): Boolean = state.target != null || state.mutationInProgress || state.mutationRefreshInProgress ||
    state.editorVisible || state.confirmationRequested || state.mutationResult != null ||
    state.mutationFailure != null ||
    state.mutationRefreshFailure != null

internal fun fileStationMutationBlocksWorkspaceExit(
    state: FileStationMutationWorkspaceState,
): Boolean = state.editorVisible || state.confirmationRequested ||
    structuredMutationBlocksWorkspaceExit(
    mutationInProgress = state.mutationInProgress,
    refreshInProgress = state.mutationRefreshInProgress,
    result = state.mutationResult,
    failure = state.mutationFailure ?: state.mutationRefreshFailure,
    refreshCompleted = state.mutationRefreshCompleted,
)

internal fun shouldDiscardSettledFileStationMutationOnModuleChange(
    state: FileStationMutationWorkspaceState,
    nextModule: Module,
): Boolean {
    val owner = state.target?.module ?: state.draftTarget?.module ?: return false
    return owner != nextModule && !fileStationMutationBlocksWorkspaceExit(state)
}

internal fun canContinueEditingFileStationMutation(
    state: FileStationMutationWorkspaceState,
): Boolean = !state.mutationInProgress && !state.mutationRefreshInProgress &&
    state.target?.operation in setOf(
        FileStationMutationOperation.CREATE_FOLDER,
        FileStationMutationOperation.RENAME,
        FileStationMutationOperation.COPY,
        FileStationMutationOperation.MOVE,
        FileStationMutationOperation.TEXT_SAVE,
    ) && (state.mutationFailure != null || state.mutationResult?.status in setOf(
        MutationResultStatus.CONFIRMED_FAILURE,
        MutationResultStatus.PERMISSION_DENIED,
        MutationResultStatus.UNSUPPORTED,
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
    ))

internal fun fileStationMutationVerification(
    target: FileStationMutationTarget,
    files: FilePage? = null,
    favoritePaths: Set<String>? = null,
    shareLinks: List<FileShareLink>? = null,
): FileStationMutationVerification {
    return when (target.operation) {
    FileStationMutationOperation.CREATE_FOLDER -> {
        val page = files ?: return FileStationMutationVerification.UNAVAILABLE
        val expectedPath = target.parentPath?.trimEnd('/') + "/" + target.requestedName
        if (page.items.any { it.path == expectedPath }) FileStationMutationVerification.MATCHES
        else FileStationMutationVerification.DIFFERS
    }
    FileStationMutationOperation.RENAME -> {
        val page = files ?: return FileStationMutationVerification.UNAVAILABLE
        val source = target.sourceBaselines.single()
        val expectedPath = source.path.substringBeforeLast('/', "") + "/" + target.requestedName
        when {
            page.items.any { it.matchesMutationOutcome(source, expectedPath) } ->
                FileStationMutationVerification.MATCHES
            page.items.none { it.path == source.path } -> FileStationMutationVerification.DISAPPEARED
            else -> FileStationMutationVerification.DIFFERS
        }
    }
    FileStationMutationOperation.FAVORITE_ADD,
    FileStationMutationOperation.FAVORITE_ADD_BATCH,
    -> favoritePaths?.let { paths ->
        if (target.sourceBaselines.all { it.path in paths }) FileStationMutationVerification.MATCHES
        else FileStationMutationVerification.DIFFERS
    } ?: FileStationMutationVerification.UNAVAILABLE
    FileStationMutationOperation.FAVORITE_REMOVE -> favoritePaths?.let { paths ->
        if (target.sourceBaselines.none { it.path in paths }) FileStationMutationVerification.MATCHES
        else FileStationMutationVerification.DIFFERS
    } ?: FileStationMutationVerification.UNAVAILABLE
    FileStationMutationOperation.COPY -> {
        val page = files ?: return FileStationMutationVerification.UNAVAILABLE
        val destination = target.destinationPath?.trimEnd('/')
            ?: return FileStationMutationVerification.UNAVAILABLE
        if (target.sourceBaselines.all { source ->
                page.items.any { it.matchesMutationOutcome(source, "$destination/${source.name}") }
            }
        ) {
            FileStationMutationVerification.MATCHES
        } else FileStationMutationVerification.DIFFERS
    }
    FileStationMutationOperation.MOVE,
    FileStationMutationOperation.RESTORE,
    -> {
        val page = files ?: return FileStationMutationVerification.UNAVAILABLE
        if (target.sourceBaselines.none { source -> page.items.any { it.path == source.path } }) {
            FileStationMutationVerification.DISAPPEARED
        } else FileStationMutationVerification.DIFFERS
    }
    FileStationMutationOperation.DELETE -> {
        val page = files ?: return FileStationMutationVerification.UNAVAILABLE
        if (target.sourceBaselines.none { source -> page.items.any { it.path == source.path } }) {
            FileStationMutationVerification.DISAPPEARED
        } else FileStationMutationVerification.DIFFERS
    }
    FileStationMutationOperation.SHARE_CREATE -> shareLinks?.let { links ->
        val expected = target.shareLinkBaselines.singleOrNull()
            ?: return FileStationMutationVerification.UNAVAILABLE
        if (links.any { it.id == expected.id && it.path == expected.path }) {
            FileStationMutationVerification.MATCHES
        } else FileStationMutationVerification.DIFFERS
    } ?: FileStationMutationVerification.UNAVAILABLE
    FileStationMutationOperation.SHARE_DELETE -> shareLinks?.let { links ->
        if (target.shareLinkBaselines.none { baseline -> links.any { it.id == baseline.id } }) {
            FileStationMutationVerification.DISAPPEARED
        } else FileStationMutationVerification.DIFFERS
    } ?: FileStationMutationVerification.UNAVAILABLE
    FileStationMutationOperation.TEXT_SAVE -> FileStationMutationVerification.UNAVAILABLE
    }
}

/** 写后核对只比较操作应保持不变的文件属性；目录大小和时间会随子项自然变化。 */
private fun FileItem.matchesMutationOutcome(baseline: FileItem, expectedPath: String): Boolean =
    path == expectedPath && name == expectedPath.substringAfterLast('/') &&
        isDirectory == baseline.isDirectory &&
        (isDirectory || size == baseline.size &&
            modifiedAtEpochSeconds == baseline.modifiedAtEpochSeconds)

/** 当前工作区的文件写后读取沿用同一结果规则，缺少工作区时不认定成功。 */
internal suspend fun WorkspaceState?.verifyFileStationMutation(
    target: FileStationMutationTarget,
    fileInfo: suspend (String) -> FileItem?,
): FileStationMutationVerification {
    val current = this ?: return FileStationMutationVerification.UNAVAILABLE
    return verifyFileStationMutationOutcome(target, fileInfo, current.favoritePaths,
        (current.fileShareLinks as? Loadable.Ready)?.value, current.fileStationMutationState.createdShareLink)
}

internal suspend fun verifyFileStationMutationOutcome(
    target: FileStationMutationTarget,
    fileInfo: suspend (String) -> FileItem?,
    favoritePaths: Set<String> = emptySet(),
    shareLinks: List<FileShareLink>? = null,
    createdShareLink: FileShareLink? = null,
): FileStationMutationVerification = when (target.operation) {
    FileStationMutationOperation.CREATE_FOLDER -> {
        val path = checkNotNull(target.parentPath).trimEnd('/') + "/" + target.requestedName
        if (fileInfo(path)?.let { it.path == path && it.isDirectory } == true) {
            FileStationMutationVerification.MATCHES
        } else FileStationMutationVerification.DIFFERS
    }
    FileStationMutationOperation.RENAME -> {
        val source = target.sourceBaselines.single()
        val path = source.path.substringBeforeLast('/', "") + "/" + target.requestedName
        when {
            fileInfo(path)?.matchesMutationOutcome(source, path) == true ->
                FileStationMutationVerification.MATCHES
            fileInfo(source.path) == null -> FileStationMutationVerification.DISAPPEARED
            else -> FileStationMutationVerification.DIFFERS
        }
    }
    FileStationMutationOperation.COPY -> {
        val destination = checkNotNull(target.destinationPath).trimEnd('/')
        if (target.sourceBaselines.all { source ->
                val path = "$destination/${source.name}"
                fileInfo(path)?.matchesMutationOutcome(source, path) == true
            }
        ) FileStationMutationVerification.MATCHES else FileStationMutationVerification.DIFFERS
    }
    FileStationMutationOperation.MOVE -> {
        val destination = checkNotNull(target.destinationPath).trimEnd('/')
        val destinationsExist = target.sourceBaselines.all { source ->
            val path = "$destination/${source.name}"
            fileInfo(path)?.matchesMutationOutcome(source, path) == true
        }
        val sourcesAbsent = target.sourceBaselines.all { fileInfo(it.path) == null }
        when {
            destinationsExist && sourcesAbsent -> FileStationMutationVerification.MATCHES
            sourcesAbsent -> FileStationMutationVerification.DISAPPEARED
            else -> FileStationMutationVerification.DIFFERS
        }
    }
    FileStationMutationOperation.RESTORE -> {
        val source = target.sourceBaselines.single()
        val original = RecycleLocation.from(source.path)?.originalPath
            ?: return FileStationMutationVerification.UNAVAILABLE
        when {
            fileInfo(original)?.matchesMutationOutcome(source, original) == true &&
                fileInfo(source.path) == null -> FileStationMutationVerification.MATCHES
            fileInfo(source.path) == null -> FileStationMutationVerification.DISAPPEARED
            else -> FileStationMutationVerification.DIFFERS
        }
    }
    FileStationMutationOperation.DELETE -> if (
        target.sourceBaselines.all { fileInfo(it.path) == null }
    ) {
        FileStationMutationVerification.DISAPPEARED
    } else {
        FileStationMutationVerification.DIFFERS
    }
    FileStationMutationOperation.TEXT_SAVE -> FileStationMutationVerification.UNAVAILABLE
    else -> fileStationMutationVerification(
        target = if (target.operation == FileStationMutationOperation.SHARE_CREATE) {
            createdShareLink?.let { target.copy(shareLinkBaselines = listOf(it)) } ?: target
        } else target,
        favoritePaths = favoritePaths,
        shareLinks = shareLinks,
    )
}

internal fun cancelledFileStationMutationResult(
    operation: FileStationMutationOperation,
): MutationResult = MutationResult(
    schemaVersion = 1,
    status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
    operation = operation.resultOperation,
    submitted = false,
    requiresRefresh = false,
    counts = MutationResultCounts(0, 0, 0),
)

internal fun shouldClearFileSelectionAfterDelete(
    result: MutationResult?,
    userDiscarded: Boolean = false,
): Boolean = userDiscarded || result?.status == MutationResultStatus.CONFIRMED_SUCCESS

private val FileStationMutationOperation.resultOperation: String
    get() = when (this) {
        FileStationMutationOperation.TEXT_SAVE -> "textSave"
        FileStationMutationOperation.CREATE_FOLDER -> "folderCreate"
        FileStationMutationOperation.RENAME -> "fileRename"
        FileStationMutationOperation.FAVORITE_ADD -> "favoriteAdd"
        FileStationMutationOperation.FAVORITE_REMOVE -> "favoriteRemove"
        FileStationMutationOperation.FAVORITE_ADD_BATCH -> "favoriteAddBatch"
        FileStationMutationOperation.COPY -> "fileCopy"
        FileStationMutationOperation.MOVE -> "fileMove"
        FileStationMutationOperation.DELETE -> "fileDelete"
        FileStationMutationOperation.RESTORE -> "fileRestore"
        FileStationMutationOperation.SHARE_CREATE -> "shareLinkCreate"
        FileStationMutationOperation.SHARE_DELETE -> "shareLinkDelete"
    }

internal fun aggregateFileStationMutationResults(
    operation: FileStationMutationOperation,
    expectedCount: Int,
    results: List<MutationResult?>,
): MutationResult {
    require(expectedCount > 0 && results.size == expectedCount)
    val succeeded = results.sumOf { it?.counts?.succeeded ?: 0 }
    val failed = results.sumOf { it?.counts?.failed ?: 0 }
    val unknown = results.sumOf { it?.counts?.unknown ?: 1 }
    val submitted = results.any { it?.submitted == true } || unknown > 0
    val statuses = results.mapNotNull { it?.status }.toSet()
    val status = when {
        succeeded == expectedCount && failed == 0 && unknown == 0 ->
            MutationResultStatus.CONFIRMED_SUCCESS
        succeeded > 0 -> MutationResultStatus.PARTIAL_SUCCESS
        unknown > 0 -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
        statuses == setOf(MutationResultStatus.PERMISSION_DENIED) ->
            MutationResultStatus.PERMISSION_DENIED
        statuses == setOf(MutationResultStatus.UNSUPPORTED) -> MutationResultStatus.UNSUPPORTED
        statuses == setOf(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION) ->
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION
        submitted -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
        else -> MutationResultStatus.CONFIRMED_FAILURE
    }
    val normalizedCounts = when (status) {
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> MutationResultCounts(0, 0, 0)
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED ->
            MutationResultCounts(succeeded, failed, unknown)
        else -> MutationResultCounts(succeeded, failed, unknown)
    }
    return MutationResult(
        schemaVersion = 1,
        status = status,
        operation = operation.resultOperation,
        submitted = submitted,
        requiresRefresh = status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED ||
            unknown > 0 || results.any { it?.requiresRefresh == true },
        counts = normalizedCounts,
        errorCategory = results.firstNotNullOfOrNull { it?.errorCategory },
        diagnosticTag = "file-station.batch",
    )
}

data class PendingFileUploads(
    val uris: List<Uri>,
    val destinationPath: String,
    val conflictCount: Int,
    val profileId: String,
    val module: Module,
    val generation: Long,
)

internal data class FileUploadPreflightToken(
    val profileId: String,
    val module: Module,
    val destinationPath: String,
    val generation: Long,
)

internal fun WorkspaceState.matchesFileUploadPreflight(
    token: FileUploadPreflightToken,
    currentGeneration: Long,
): Boolean = token.generation == currentGeneration &&
    profile.id == token.profileId && selectedModule == token.module &&
    fileBrowser.path == token.destinationPath


internal fun interruptedServerMutationResult(
    operation: FileServerMutationOperation,
    submitted: Boolean,
    expectedCount: Int,
): MutationResult = MutationResult(
    schemaVersion = 1,
    status = if (submitted) {
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
    } else {
        MutationResultStatus.CONFIRMED_FAILURE
    },
    operation = when (operation) {
        FileServerMutationOperation.COMPRESS -> "archiveCompress"
        FileServerMutationOperation.EXTRACT -> "archiveExtract"
    },
    submitted = submitted,
    requiresRefresh = submitted,
    counts = if (submitted) {
        MutationResultCounts(0, 0, expectedCount.coerceAtLeast(1))
    } else {
        MutationResultCounts(0, expectedCount.coerceAtLeast(1), 0)
    },
    errorCategory = MutationErrorCategory.UNKNOWN,
    diagnosticTag = if (submitted) {
        "archive.interrupted-after-submission"
    } else {
        "archive.interrupted-before-submission"
    },
)

internal suspend fun listFilePage(
    repo: DsmRepository,
    browser: FileBrowserState,
    offset: Int,
): FilePage {
    val sortBy = when (browser.sortOption) {
        FileSortOption.NAME -> "name"
        FileSortOption.MODIFIED_TIME -> "mtime"
        FileSortOption.SIZE -> "size"
    }
    return if (browser.path.isBlank()) {
        repo.listShares(offset, FILE_PAGE_SIZE, sortBy, browser.sortAscending)
    } else {
        repo.listDirectory(
            browser.path,
            offset,
            FILE_PAGE_SIZE,
            sortBy,
            browser.sortAscending,
            when (browser.typeFilter) {
                FileTypeFilter.ALL -> "all"
                FileTypeFilter.FOLDERS -> "dir"
                FileTypeFilter.FILES -> "file"
            },
        )
    }
}

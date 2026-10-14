package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.Closeable
import java.time.YearMonth
import java.time.ZoneId
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** 与会话同寿命的 Photos 导航模型；UI 只负责触控/键盘，绝不启动旧文件扫描。 */
internal class SynologyPhotosModel(
    private val repository: SynologyPhotosServing,
    parent: CoroutineScope,
    private val pageSize: Int = 100,
    private val zone: ZoneId = ZoneId.systemDefault(),
    uploadStore: SynologyPhotoUploadStore? = null,
    uploadOwner: io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner? = null,
    requireUploadOwner: () -> Unit = {},
    editStore: SynologyPhotoEditStore? = null,
    albumStore: SynologyPhotoAlbumStore? = null,
    deletionStore: SynologyPhotoDeletionStore? = null,
    automaticPreviewCache: java.io.File? = null,
    automaticPreviewSupport: () -> SynologyPhotoPreviewConversionSupport = SynologyPhotosVideoConverter::support,
    private val execution: io.github.qwertyuiop1995.dsmnativeclient.background.WorkspaceExecution? = null,
) : Closeable {
    init { require(pageSize in 1..500) }
    private val job = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotosState())
    val state = mutable.asStateFlow()
    val profileId: String get() = repository.profileId
    private val settingsApplication = SynologyPhotoSettingsApplication(repository, mutable, zone, { generation }, ::current, ::checkCurrent) { changedSpace ->
        if (changedSpace) edits?.selectMode(false)
        preview.closePreview(); deletion.cancelCandidate(); refresh()
    }
    private val backgroundIdle: suspend () -> Unit = { similar?.requireNoPending(); concepts?.requireNoPending(); manualFaces?.requireNoPending(); people?.requireNoPending(); automaticPreviews?.requireNoPending(); previewRegeneration?.requireNoPending(); codecPrompt?.requireNoPending(); maintenance?.requireNoPending(); sharedMembers?.requireNoPending(); background?.requireNoPending() ?: albumStore?.requireNoPendingBackground(uploadOwner, repository::photoEditIdentity, requireUploadOwner) }
    val uploads: SynologyPhotoUploadModel? = if (uploadStore != null && uploadOwner != null && repository.canUploadPhotos)
        SynologyPhotoUploadModel(repository, scope, uploadStore, uploadOwner, requireUploadOwner, executionHost = execution,
            beforeWrite = { target ->
                exports.requireIdle()
                if (requests?.state?.value?.working == true) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
                deletion.requireNoPending(); files?.requireNoPending(); folders?.requireNoPending(); folderSharing?.requireNoPending(); settings?.requireNoPending(); backgroundIdle()
                albums?.requireNoPending(albumId = (target as? SynologyPhotoUploadTarget.Album)?.id)
            }) { if (active) refresh() } else null
    val thumbnails = SynologyPhotoThumbnailStore(scope)
    val exports: SynologyPhotoExportModel = SynologyPhotoExportModel(repository, scope, requireUploadOwner, execution = execution, owner = uploadOwner,
        canStart = { active && state.value.access != null && !writesInProgress && uploads?.state?.value?.working != true &&
            !deletion.state.value.checking && deletion.state.value.candidate == null && deletion.state.value.pending == null },
        beforeStart = { request ->
            deletion.requireNoPending(); files?.requireNoPending(); folders?.requireNoPending(); folderSharing?.requireNoPending(); settings?.requireNoPending(); backgroundIdle()
            if (request is SynologyPhotoExportRequest.Archive) edits?.requireNoPending()
            val photos = when (request) {
                is SynologyPhotoExportRequest.Items -> request.photos
                is SynologyPhotoExportRequest.Archive -> (request.target as? SynologyPhotoArchiveTarget.Selection)?.photos.orEmpty()
            }
            photos.forEach { edits?.requireNoPending(it); albums?.requireNoPending(it) }
            if (request is SynologyPhotoExportRequest.Archive && request.target is SynologyPhotoArchiveTarget.Album)
                albums?.requireNoPending(albumId = request.target.id)
        })
    val preview = SynologyPhotoPreviewModel(repository, scope) { similar?.state?.value?.takeIf { it.visible }?.detail?.photos ?: state.value.items }
    val slideshow = SynologyPhotoSlideshowModel(repository, scope, pageSize)
    val deletion: SynologyPhotoDeletionModel = SynologyPhotoDeletionModel(repository, scope, deletionStore, uploadOwner, requireUploadOwner,
        canStart = { similar?.state?.value?.working != true && concepts?.state?.value?.working != true && manualFaces?.state?.value?.working != true && people?.state?.value?.working != true && previewRegeneration?.state?.value?.working != true && codecPrompt?.state?.value?.working != true && maintenance?.state?.value?.working != true && sharedMembers?.state?.value?.working != true && background?.state?.value?.working != true && !exports.state.value.busy && uploads?.state?.value?.working != true && edits?.state?.value?.working != true && albums?.state?.value?.working != true &&
            requests?.state?.value?.working != true && folders?.state?.value?.working != true && files?.state?.value?.working != true && folderSharing?.state?.value?.working != true && settings?.state?.value?.working != true },
        beforeWrite = { photo ->
            files?.requireNoPending(); folders?.requireNoPending(); folderSharing?.requireNoPending(); settings?.requireNoPending(); backgroundIdle(); edits?.requireNoPending(photo); albums?.requireNoPending(photo)
            if (uploadStore != null && uploadOwner != null && uploadStore.records(uploadOwner, repository.uploadIdentity()).any { row ->
                    !row.finished && row.entries.any { it.checkpoint?.submitted == true && it.checkpoint.finished.not() }
                }) throw SynologyPhotoDeletionFailure(SynologyPhotoDeletionProblem.PENDING)
        }, onConfirmed = ::deletionConfirmed)
    private val confirmedDeletedIds = mutableSetOf<SynologyPhotoId>()
    private val confirmedDeletionTargets = mutableMapOf<SynologyPhotoId, SynologyPhotoDeletionTarget>()
    val canEditPhotos: Boolean get() = repository.canEditPhotos
    val edits: SynologyPhotoEditModel? = if (editStore != null && uploadOwner != null && (repository.canEditPhotos || repository.canManageAlbums || repository.canTransferPhotos || repository.canDeleteFolders || repository.canDeleteOriginals))
        SynologyPhotoEditModel(repository, scope, editStore, uploadOwner, requireUploadOwner,
            canStart = { similar?.state?.value?.working != true && concepts?.state?.value?.working != true && manualFaces?.state?.value?.working != true && people?.state?.value?.working != true && previewRegeneration?.state?.value?.working != true && codecPrompt?.state?.value?.working != true && maintenance?.state?.value?.working != true && sharedMembers?.state?.value?.working != true && background?.state?.value?.working != true && !exports.state.value.busy && !deletion.state.value.writing && !deletion.state.value.checking && deletion.state.value.candidate == null &&
                deletion.state.value.pending == null && uploads?.state?.value?.working != true && albums?.state?.value?.working != true && requests?.state?.value?.working != true && folders?.state?.value?.working != true && files?.state?.value?.working != true && folderSharing?.state?.value?.working != true && settings?.state?.value?.working != true },
            beforeWrite = { photos -> deletion.requireNoPending(); files?.requireNoPending(); folders?.requireNoPending(); folderSharing?.requireNoPending(); settings?.requireNoPending(); backgroundIdle(); photos.forEach { albums?.requireNoPending(it) } },
            onRotationFinished = { mediaUpdates.rotationFinished(it) },
            onCompleted = { if (active) { preview.state.value.photo?.let { preview.open(it) }; refresh() } }) else null
    val albums: SynologyPhotoAlbumModel? = if (albumStore != null && uploadOwner != null && repository.canManageAlbums)
        SynologyPhotoAlbumModel(repository, scope, albumStore, uploadOwner, requireUploadOwner,
            canStart = { similar?.state?.value?.working != true && concepts?.state?.value?.working != true && manualFaces?.state?.value?.working != true && people?.state?.value?.working != true && previewRegeneration?.state?.value?.working != true && codecPrompt?.state?.value?.working != true && maintenance?.state?.value?.working != true && sharedMembers?.state?.value?.working != true && background?.state?.value?.working != true && !exports.state.value.busy && !deletion.state.value.writing && !deletion.state.value.checking && deletion.state.value.candidate == null &&
                deletion.state.value.pending == null && uploads?.state?.value?.working != true && edits?.state?.value?.working != true && requests?.state?.value?.working != true && folders?.state?.value?.working != true && files?.state?.value?.working != true && folderSharing?.state?.value?.working != true && settings?.state?.value?.working != true },
            beforeWrite = { photos, albumId ->
                deletion.requireNoPending()
                files?.requireNoPending(); folders?.requireNoPending(); folderSharing?.requireNoPending(); settings?.requireNoPending(); backgroundIdle()
                photos.forEach { edits?.requireNoPending(it) }
                if (albumId != null && uploadStore != null && uploadStore.records(uploadOwner, repository.uploadIdentity()).any {
                        !it.finished && (it.target as? SynologyPhotoUploadTarget.Album)?.id == albumId && it.entries.any { entry -> entry.checkpoint?.submitted == true && entry.checkpoint.finished.not() }
                    }) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
            }, sourceAccess = { state.value.access }, onCompleted = { row ->
                edits?.selectMode(false)
                if (row?.finished == true && state.value.navigation.album?.id == row.albumId) {
                    when (row.action) {
                        SynologyPhotoAlbumAction.DELETE, SynologyPhotoAlbumAction.STOP_TEMPORARY -> if (row.phase == SynologyPhotoAlbumPhase.COMPLETED) mutable.update { it.copy(navigation = it.navigation.copy(album = null)) }
                        SynologyPhotoAlbumAction.RENAME -> mutable.update { it.copy(navigation = it.navigation.copy(album = it.navigation.album?.copy(name = row.name!!))) }
                        SynologyPhotoAlbumAction.UNFREEZE -> mutable.update { it.copy(navigation = it.navigation.copy(album = it.navigation.album?.copy(isFrozen = false, isConditional = false))) }
                        SynologyPhotoAlbumAction.REBUILD_FROZEN -> mutable.update { it.copy(navigation = it.navigation.copy(album =
                            SynologyPhotoCollection(row.createdAlbumId!!, row.name!!, isConditional = true))) }
                        else -> Unit
                    }
                }
                if (active) refresh()
            }) else null
    val requests: SynologyPhotoRequestModel? = if (albumStore != null && uploadOwner != null && repository.canManagePhotoRequests)
        SynologyPhotoRequestModel(repository, scope, albumStore, uploadOwner, requireUploadOwner, { state.value.access },
            canStart = { similar?.state?.value?.working != true && concepts?.state?.value?.working != true && manualFaces?.state?.value?.working != true && people?.state?.value?.working != true && previewRegeneration?.state?.value?.working != true && codecPrompt?.state?.value?.working != true && maintenance?.state?.value?.working != true && sharedMembers?.state?.value?.working != true && background?.state?.value?.working != true && !exports.state.value.busy && !deletion.state.value.writing && !deletion.state.value.checking && deletion.state.value.candidate == null &&
                deletion.state.value.pending == null && uploads?.state?.value?.working != true && edits?.state?.value?.working != true && albums?.state?.value?.working != true && folders?.state?.value?.working != true && files?.state?.value?.working != true && folderSharing?.state?.value?.working != true && settings?.state?.value?.working != true },
            beforeWrite = { deletion.requireNoPending(); files?.requireNoPending(); folders?.requireNoPending(); folderSharing?.requireNoPending(); settings?.requireNoPending(); backgroundIdle() },
            onCompleted = { albums?.refreshRecords(); if (active) refresh() }) else null
    val folders: SynologyPhotoFolderModel? = if (albumStore != null && uploadOwner != null && repository.canManageFolders)
        SynologyPhotoFolderModel(repository, scope, albumStore, uploadOwner, requireUploadOwner,
            canStart = { similar?.state?.value?.working != true && concepts?.state?.value?.working != true && manualFaces?.state?.value?.working != true && people?.state?.value?.working != true && previewRegeneration?.state?.value?.working != true && codecPrompt?.state?.value?.working != true && maintenance?.state?.value?.working != true && sharedMembers?.state?.value?.working != true && background?.state?.value?.working != true && !exports.state.value.busy && !deletion.state.value.writing && !deletion.state.value.checking && deletion.state.value.candidate == null &&
                deletion.state.value.pending == null && uploads?.state?.value?.working != true && edits?.state?.value?.working != true &&
                albums?.state?.value?.working != true && requests?.state?.value?.working != true && files?.state?.value?.working != true && folderSharing?.state?.value?.working != true && settings?.state?.value?.working != true },
            beforeWrite = { row ->
                deletion.requireNoPending()
                files?.requireNoPending(); folderSharing?.requireNoPending(); settings?.requireNoPending(); backgroundIdle()
                row.folder?.coverPhoto?.photo()?.let { edits?.requireNoPending(it) }
                if (uploadStore != null && uploadStore.records(uploadOwner, repository.uploadIdentity()).any { record ->
                        !record.finished && record.entries.any { it.checkpoint?.submitted == true && it.checkpoint.finished.not() }
                    }) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
            }, onCompleted = ::folderCompleted) else null
    val files: SynologyPhotoFileModel? = if (albumStore != null && uploadOwner != null && (repository.canTransferPhotos || repository.canDeleteFolders))
        SynologyPhotoFileModel(repository, scope, albumStore, uploadOwner, requireUploadOwner, { state.value.access },
            canStart = { similar?.state?.value?.working != true && concepts?.state?.value?.working != true && manualFaces?.state?.value?.working != true && people?.state?.value?.working != true && previewRegeneration?.state?.value?.working != true && codecPrompt?.state?.value?.working != true && maintenance?.state?.value?.working != true && sharedMembers?.state?.value?.working != true && background?.state?.value?.working != true && !exports.state.value.busy && !deletion.state.value.writing && !deletion.state.value.checking && deletion.state.value.candidate == null &&
                deletion.state.value.pending == null && uploads?.state?.value?.working != true && edits?.state?.value?.working != true &&
                albums?.state?.value?.working != true && requests?.state?.value?.working != true && folders?.state?.value?.working != true && folderSharing?.state?.value?.working != true && settings?.state?.value?.working != true },
            beforeWrite = { row ->
                deletion.requireNoPending()
                folders?.requireNoPending(); folderSharing?.requireNoPending(); settings?.requireNoPending(); backgroundIdle(); row.targets.forEach { edits?.requireNoPending(it.photo()) }
                if (uploadStore != null && uploadStore.records(uploadOwner, repository.uploadIdentity()).any { record ->
                        !record.finished && record.entries.any { it.checkpoint?.submitted == true && it.checkpoint.finished.not() }
                    }) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
            }, onCompleted = ::fileCompleted) else null
    val folderSharing: SynologyPhotoFolderSharingModel? = if (albumStore != null && uploadOwner != null && repository.canManageFolderSharing)
        SynologyPhotoFolderSharingModel(repository, scope, albumStore, uploadOwner, requireUploadOwner, { state.value.access },
            canStart = { similar?.state?.value?.working != true && concepts?.state?.value?.working != true && manualFaces?.state?.value?.working != true && people?.state?.value?.working != true && previewRegeneration?.state?.value?.working != true && codecPrompt?.state?.value?.working != true && maintenance?.state?.value?.working != true && sharedMembers?.state?.value?.working != true && background?.state?.value?.working != true && !exports.state.value.busy && !deletion.state.value.writing && !deletion.state.value.checking && deletion.state.value.candidate == null &&
                deletion.state.value.pending == null && uploads?.state?.value?.working != true && edits?.state?.value?.working != true &&
                albums?.state?.value?.working != true && requests?.state?.value?.working != true && folders?.state?.value?.working != true && files?.state?.value?.working != true && settings?.state?.value?.working != true },
            beforeWrite = {
                settings?.requireNoPending(); backgroundIdle(); deletion.requireNoPending(); files?.requireNoPending(); folders?.requireNoPending()
                requireNoPendingPhotoInputs(editStore, uploadStore, uploadOwner, repository)
            }) else null
    val settings: SynologyPhotoSettingsModel? = if (albumStore != null && uploadOwner != null && SynologyPhotoSettingsKind.entries.any(repository::canManageSettings))
        SynologyPhotoSettingsModel(repository, scope, albumStore, uploadOwner, requireUploadOwner,
            canStart = { similar?.state?.value?.working != true && concepts?.state?.value?.working != true && manualFaces?.state?.value?.working != true && people?.state?.value?.working != true && previewRegeneration?.state?.value?.working != true && codecPrompt?.state?.value?.working != true && maintenance?.state?.value?.working != true && sharedMembers?.state?.value?.working != true && background?.state?.value?.working != true && !exports.state.value.busy && state.value.access != null && !state.value.loading && !deletion.state.value.writing && !deletion.state.value.checking &&
                deletion.state.value.candidate == null && deletion.state.value.pending == null && uploads?.state?.value?.working != true &&
                edits?.state?.value?.working != true && albums?.state?.value?.working != true && requests?.state?.value?.working != true &&
                folders?.state?.value?.working != true && files?.state?.value?.working != true && folderSharing?.state?.value?.working != true },
            beforeWrite = {
                backgroundIdle(); deletion.requireNoPending(); files?.requireNoPending(); folders?.requireNoPending(); folderSharing?.requireNoPending()
                requireNoPendingPhotoInputs(editStore, uploadStore, uploadOwner, repository)
            }, onApplied = ::settingsApplied, onSaved = ::preferencesSaved) else null
    val sharedMembers: SynologyPhotoSharedMembersModel? = if (albumStore != null && uploadOwner != null)
        SynologyPhotoSharedMembersModel(repository, scope, albumStore, uploadOwner, requireUploadOwner,
            canStart = { active && state.value.access != null && !writesInProgress && !state.value.loading && uploads?.state?.value?.working != true &&
                !deletion.state.value.checking && deletion.state.value.candidate == null && deletion.state.value.pending == null },
            beforeWrite = {
                similar?.requireNoPending(); previewRegeneration?.requireNoPending(); codecPrompt?.requireNoPending(); maintenance?.requireNoPending(); background?.requireNoPending(); deletion.requireNoPending(); settings?.requireNoPending()
                requireNoPendingPhotoInputs(editStore, uploadStore, uploadOwner, repository)
            }, onApplied = ::sharedMembersApplied, onChanging = ::sharedMembersChanging,
            onReadFailed = { error -> if (memberWindow != null) mutable.update { it.copy(error = error, loading = false) } }) else null
    val background: SynologyPhotoBackgroundModel? = if (albumStore != null && uploadOwner != null && repository.canControlBackgroundTasks)
        SynologyPhotoBackgroundModel(repository, scope, albumStore, uploadOwner, requireUploadOwner,
            canStart = { active && state.value.access != null && !writesInProgress && !state.value.loading &&
                !deletion.state.value.checking && deletion.state.value.candidate == null && deletion.state.value.pending == null &&
                uploads?.state?.value?.working != true && files?.state?.value?.recovering != true },
            beforeWrite = {
                similar?.requireNoPending(); previewRegeneration?.requireNoPending(); codecPrompt?.requireNoPending(); maintenance?.requireNoPending(); deletion.requireNoPending(); folders?.requireNoPending(); folderSharing?.requireNoPending(); settings?.requireNoPending()
                requireNoPendingPhotoInputs(editStore, uploadStore, uploadOwner, repository)
            }, onCompleted = { files?.refreshRecords() }, onOpenTarget = ::openBackgroundTarget) else null
    val maintenance: SynologyPhotoMaintenanceModel? = if (albumStore != null && uploadOwner != null)
        SynologyPhotoMaintenanceModel(repository, scope, albumStore, uploadOwner, requireUploadOwner,
            canStart = { active && state.value.access != null && !state.value.loading && !writesInProgress && uploads?.state?.value?.working != true &&
                !deletion.state.value.checking && deletion.state.value.candidate == null && deletion.state.value.pending == null },
            beforeWrite = {
                similar?.requireNoPending(); previewRegeneration?.requireNoPending(); codecPrompt?.requireNoPending(); deletion.requireNoPending(); sharedMembers?.requireNoPending(); background?.requireNoPending()
                requireNoPendingPhotoInputs(editStore, uploadStore, uploadOwner, repository)
            }) else null
    val codecPrompt: SynologyPhotoCodecPromptModel? = if (albumStore != null && uploadOwner != null)
        SynologyPhotoCodecPromptModel(repository, scope, albumStore, uploadOwner, requireUploadOwner,
            canStart = { active && state.value.access != null && !state.value.loading && !writesInProgress && uploads?.state?.value?.working != true &&
                !deletion.state.value.checking && deletion.state.value.candidate == null && deletion.state.value.pending == null },
            beforeWrite = {
                similar?.requireNoPending(); previewRegeneration?.requireNoPending(); maintenance?.requireNoPending(); deletion.requireNoPending(); sharedMembers?.requireNoPending(); background?.requireNoPending()
                requireNoPendingPhotoInputs(editStore, uploadStore, uploadOwner, repository)
            }) else null
    val previewRegeneration: SynologyPhotoPreviewRegenerationModel? = if (albumStore != null && uploadOwner != null)
        SynologyPhotoPreviewRegenerationModel(repository, scope, albumStore, uploadOwner, requireUploadOwner,
            canStart = { active && state.value.access != null && !state.value.loading && !writesInProgress && uploads?.state?.value?.working != true &&
                !deletion.state.value.checking && deletion.state.value.candidate == null && deletion.state.value.pending == null },
            beforeWrite = {
                similar?.requireNoPending(); codecPrompt?.requireNoPending(); maintenance?.requireNoPending(); deletion.requireNoPending(); sharedMembers?.requireNoPending(); background?.requireNoPending()
                files?.requireNoPending(); folders?.requireNoPending(); folderSharing?.requireNoPending(); settings?.requireNoPending()
                requireNoPendingPhotoInputs(editStore, uploadStore, uploadOwner, repository)
            }, onUpdated = { mediaUpdates.previewsUpdated(it) }) else null
    val people: SynologyPhotoPeopleModel? = if (albumStore != null && uploadOwner != null)
        SynologyPhotoPeopleModel(repository, scope, albumStore, uploadOwner, requireUploadOwner, thumbnails,
            canStart = { active && state.value.access != null && !state.value.loading && !writesInProgress && uploads?.state?.value?.working != true && !deletion.state.value.checking && deletion.state.value.candidate == null && deletion.state.value.pending == null },
            beforeWrite = { similar?.requireNoPending(); concepts?.requireNoPending(); manualFaces?.requireNoPending(); automaticPreviews?.requireNoPending(); previewRegeneration?.requireNoPending(); codecPrompt?.requireNoPending(); maintenance?.requireNoPending(); sharedMembers?.requireNoPending(); background?.requireNoPending(); deletion.requireNoPending(); requireNoPendingPhotoInputs(editStore, uploadStore, uploadOwner, repository) },
            onApplied = { row, latest -> applyPhotoPeopleChange(mutable, row, latest) { edits?.removeSelection(it) }?.let { collectionOffset = it } }) else null
    val concepts: SynologyPhotoConceptModel? = if (albumStore != null && uploadOwner != null)
        SynologyPhotoConceptModel(repository, scope, albumStore, uploadOwner, requireUploadOwner, thumbnails,
            canStart = { active && state.value.access != null && !state.value.loading && !writesInProgress && uploads?.state?.value?.working != true && !deletion.state.value.checking && deletion.state.value.candidate == null && deletion.state.value.pending == null },
            beforeWrite = { similar?.requireNoPending(); manualFaces?.requireNoPending(); people?.requireNoPending(); automaticPreviews?.requireNoPending(); previewRegeneration?.requireNoPending(); codecPrompt?.requireNoPending(); maintenance?.requireNoPending(); sharedMembers?.requireNoPending(); background?.requireNoPending(); deletion.requireNoPending(); requireNoPendingPhotoInputs(editStore, uploadStore, uploadOwner, repository) },
            onApplied = { row, latest -> applyPhotoConceptChange(mutable, row, latest) { removed ->
                resetRequests(); nextOffset = maxOf(0, nextOffset - pagedPhotoIds.count { it in removed })
                pagedPhotoIds.removeAll(removed)
                edits?.removeSelection(removed); if (preview.state.value.photo?.id in removed) preview.closePreview()
            }?.let { collectionOffset = it } }) else null
    val manualFaces: SynologyPhotoManualFacesModel? = if (albumStore != null && uploadOwner != null)
        SynologyPhotoManualFacesModel(repository, scope, albumStore, uploadOwner, requireUploadOwner,
            canStart = { active && state.value.access != null && !state.value.loading && !writesInProgress && uploads?.state?.value?.working != true && !deletion.state.value.checking && deletion.state.value.candidate == null && deletion.state.value.pending == null },
            beforeWrite = { similar?.requireNoPending(); concepts?.requireNoPending(); people?.requireNoPending(); automaticPreviews?.requireNoPending(); previewRegeneration?.requireNoPending(); codecPrompt?.requireNoPending(); maintenance?.requireNoPending(); sharedMembers?.requireNoPending(); background?.requireNoPending(); deletion.requireNoPending(); requireNoPendingPhotoInputs(editStore, uploadStore, uploadOwner, repository) },
            onApplied = { row -> mediaUpdates.previewsUpdated(row.targets); val token = generation
                applyPhotoManualFacesChange(repository, mutable, row, { checkCurrent(token) }) { edits?.removeSelection(it) }?.let { collectionOffset = it } }) else null
    val similar: SynologyPhotoSimilarModel? = if (albumStore != null && uploadOwner != null)
        SynologyPhotoSimilarModel(repository, scope, albumStore, uploadOwner, requireUploadOwner,
            canStart = { active && state.value.access != null && !state.value.loading && !writesInProgress && uploads?.state?.value?.working != true && !deletion.state.value.checking && deletion.state.value.candidate == null && deletion.state.value.pending == null },
            beforeWrite = { concepts?.requireNoPending(); manualFaces?.requireNoPending(); people?.requireNoPending(); automaticPreviews?.requireNoPending(); previewRegeneration?.requireNoPending(); codecPrompt?.requireNoPending(); maintenance?.requireNoPending(); sharedMembers?.requireNoPending(); background?.requireNoPending(); deletion.requireNoPending(); requireNoPendingPhotoInputs(editStore, uploadStore, uploadOwner, repository) },
            onApplied = { row -> similarApplication.apply(row) }, onPreview = { preview.open(it) },
            onExport = { exports.open(SynologyPhotoExportRequest.Items(it), state.value.access?.supportsOriginalSizeJPEG == true) },
            canDelete = deletion::enabled, onDelete = { deletion.prepare(it) }) else null
    private suspend fun openBackgroundTarget(path: List<SynologyPhotoCollection>) = openPhotoBackgroundTarget(path, mutable,
        { active && !writesInProgress }, { preview.closePreview(); deletion.cancelCandidate(); edits?.selectMode(false) }, ::refresh)
    val canRotatePreview: Boolean get() = preview.state.value.photo?.id?.space in state.value.access?.spaces.orEmpty() &&
        !writesInProgress && !deletion.state.value.checking && deletion.state.value.candidate == null && deletion.state.value.pending == null && mediaUpdates.canRotate
    fun rotatePreview(): Job? = if (canRotatePreview) mediaUpdates.rotate() else null
    val automaticPreviews: SynologyPhotoAutomaticPreviewModel? = if (albumStore != null && uploadOwner != null && automaticPreviewCache != null)
        SynologyPhotoAutomaticPreviewModel(repository, scope, albumStore, uploadOwner, automaticPreviewCache, requireUploadOwner,
            canRun = { active && state.value.access != null && state.value.loaded && !state.value.loading && !writesInProgress && uploads?.state?.value?.working != true && !deletion.state.value.checking && deletion.state.value.candidate == null && deletion.state.value.pending == null },
            settingsVisible = { settings?.state?.value?.visible == true },
            view = { SynologyPhotoAutomaticPreviewView(if (slideshow.state.value.active) slideshow.previewItems else state.value.items,
                if (slideshow.state.value.active) slideshow.preview.state.value.photo else preview.state.value.photo, state.value.navigation.space,
                state.value.access?.spaces.orEmpty(), state.value.access?.canManageSharedSpace == true, !slideshow.state.value.active && state.value.navigation.section == SynologyPhotosSection.TIMELINE,
                if (slideshow.state.value.active) slideshow.previewComplete else !state.value.hasMore && !state.value.hasPrevious) },
            beforeClaim = { similar?.requireNoPending(); deletion.requireNoPending(); edits?.requireNoPending()
                if (uploadStore != null && uploadStore.records(uploadOwner, repository.uploadIdentity()).any { row -> !row.finished && row.entries.any { it.checkpoint?.submitted == true && !it.checkpoint.finished } }) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING) },
            onUpdated = { task -> mediaUpdates.previewsUpdated((listOfNotNull(task.source) + state.value.items.filter { it.id.space == task.space && it.thumbnail?.unitId == task.unitId }.map(::SynologyPhotoEditTarget)).distinct()); slideshow.previewsUpdated(task) }, support = automaticPreviewSupport) else null
    private val mediaUpdates = SynologyPhotoMediaUpdates(repository, { active }, { generation }, ::checkCurrent,
        preview, thumbnails, { state.value.items }, ::replaceItems, { edits })

    private val writesInProgress: Boolean get() = similar?.state?.value?.working == true || concepts?.state?.value?.working == true || manualFaces?.state?.value?.working == true || people?.state?.value?.working == true || previewRegeneration?.state?.value?.working == true || codecPrompt?.state?.value?.working == true || maintenance?.state?.value?.working == true || sharedMembers?.state?.value?.working == true || background?.state?.value?.working == true || exports.state.value.busy || deletion.state.value.writing || edits?.state?.value?.working == true || albums?.state?.value?.working == true || requests?.state?.value?.working == true || folders?.state?.value?.working == true || files?.state?.value?.working == true || folderSharing?.state?.value?.working == true || settings?.state?.value?.working == true
    private var active = false
    private var generation = 0L
    private var navigationJob: Job? = null
    private var pagingJob: Job? = null
    private var previousJob: Job? = null
    private var optionsJob: Job? = null
    private var optionsGeneration = 0L
    private var memberWindow: SynologyPhotoMemberWindow? = null
    private var query: SynologyPhotoQuery? = null
    private var baseQuery: SynologyPhotoQuery? = null
    private var previousMonth: YearMonth? = null
    private var nextOffset = 0
    private var collectionOffset = 0
    private val pagedPhotoIds = mutableSetOf<SynologyPhotoId>()
    private val similarApplication = SynologyPhotoSimilarApplication(repository, mutable, { query }, pagedPhotoIds,
        { nextOffset }, { nextOffset = it }, { generation }, ::checkCurrent, { resetRequests() }, ::replaceItems,
        { edits?.removeSelection(it) })

    val canStartSlideshow: Boolean get() = active && state.value.loaded && !state.value.loading &&
        state.value.access != null && state.value.items.isNotEmpty() && query != null && !writesInProgress &&
        !deletion.state.value.checking && deletion.state.value.candidate == null && deletion.state.value.pending == null &&
        (preview.state.value.photo ?: state.value.items.firstOrNull())?.let { edits?.blocks(it) != true } == true

    fun startSlideshow(): Job? {
        if (!canStartSlideshow) return null
        val photo = preview.state.value.photo ?: state.value.items.first()
        if (edits?.blocks(photo) == true) return null
        similar?.state?.value?.takeIf { it.visible }?.detail?.let { detail ->
            preview.closePreview(); return slideshow.startGroup(detail, photo)
        }
        val frozen = baseQuery ?: query ?: return null
        preview.closePreview()
        return slideshow.start(state.value.navigation.space, frozen, photo)
    }

    fun activate() {
        active = true; if (state.value.access != null) { files?.activate(); deletion.activate(); background?.activate(); people?.activate(); concepts?.activate(); similar?.activate(); manualFaces?.activate(); settings?.activate(); sharedMembers?.activate(); maintenance?.activate(); codecPrompt?.activate(); previewRegeneration?.activate(); automaticPreviews?.activate() }
        if (!state.value.loaded && !state.value.loading) refresh()
    }

    fun refresh(): Job? {
        if (!active || writesInProgress) return null
        if (memberWindow?.navigation == state.value.navigation) return reloadMemberWindow()
        memberWindow = null
        val token = resetRequests()
        query = null; baseQuery = null; previousMonth = null
        nextOffset = 0; collectionOffset = 0; pagedPhotoIds.clear()
        mutable.value = state.value.copy(items = emptyList(), groups = emptyList(), collections = emptyList(), sharing = emptyList(),
            months = emptyList(), selectedMonth = null, hasPrevious = false, hasMore = false, hasMoreCollections = false,
            loaded = false, loading = true, error = null, albumSort = null, albumListSort = null, albumDisplay = null, preferenceErrors = emptyMap(), folderAccess = null, categories = emptySet(), categoriesError = null, previousError = null)
        navigationJob = scope.launch {
            try {
                thumbnails.clear()
                // 上传中切换图库视图复用当前访问快照，避免刷新设置使同一批次的授权代次失效。
                val access = if (uploads?.state?.value?.working == true) state.value.access ?: repository.access() else repository.access()
                checkCurrent(token)
                val old = state.value.navigation
                val space = old.space.takeIf { it in access.spaces } ?: access.spaces.firstOrNull()
                val navigation = when {
                    space == null && old.section in setOf(SynologyPhotosSection.TIMELINE, SynologyPhotosSection.FOLDERS) ->
                        SynologyPhotoNavigation(section = SynologyPhotosSection.ALBUMS)
                    space == null -> old.copy(category = null, categoryItem = null, keyword = "", filter = SynologyPhotoFilter())
                    space != old.space -> SynologyPhotoNavigation(space = space, section = old.section)
                    else -> old
                }
                mutable.update { it.copy(access = access, navigation = navigation) }
                if (sharedMembers?.available == false) sharedMembers.revokeAccess()
                uploads?.refreshRecords()
                edits?.refreshRecords()
                albums?.refreshRecords()
                requests?.refreshRecords()
                folders?.refreshRecords(); files?.activate(); deletion.activate(); background?.activate(); people?.activate(); concepts?.activate(); similar?.activate(); manualFaces?.activate(); settings?.activate(); sharedMembers?.activate(); maintenance?.activate(); codecPrompt?.activate(); previewRegeneration?.activate(); automaticPreviews?.activate()
                settingsApplication.loadListPreferences(navigation, token)
                when {
                    navigation.section == SynologyPhotosSection.SHARING && navigation.album == null -> loadCollections(token)
                    navigation.showsCollectionRoot -> {
                        try {
                            val categories = if (access.spaces.isEmpty()) emptySet() else repository.categories(navigation.space)
                            checkCurrent(token)
                            mutable.update { it.copy(categories = categories) }
                        } catch (error: Exception) {
                            checkCurrent(token)
                            if (error is CancellationException) throw error
                            mutable.update { it.copy(categoriesError = error) }
                        }
                        loadCollections(token)
                    }
                    navigation.category != null && navigation.category !in setOf(SynologyPhotoCategory.RECENT, SynologyPhotoCategory.VIDEOS, SynologyPhotoCategory.SIMILAR) && navigation.categoryItem == null -> loadCollections(token)
                    else -> loadQuery(navigation, token)
                }
                checkCurrent(token)
                mutable.update { it.copy(loaded = true) }
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loading = false) } }
        }
        return navigationJob
    }

    private suspend fun loadQuery(navigation: SynologyPhotoNavigation, token: Long) {
        val initial: SynologyPhotoQuery
        when {
            navigation.category == SynologyPhotoCategory.SIMILAR -> initial = SynologyPhotoQuery.Similar(0, Long.MAX_VALUE)
            navigation.category == SynologyPhotoCategory.RECENT -> initial = SynologyPhotoQuery.Recent
            navigation.filter.isActive -> initial = SynologyPhotoQuery.Filtered(navigation.filter, 0, Long.MAX_VALUE)
            navigation.keyword.isNotEmpty() -> initial = SynologyPhotoQuery.Search(navigation.keyword, 0, Long.MAX_VALUE)
            navigation.category != null && navigation.categoryItem != null -> initial = SynologyPhotoQuery.Category(navigation.category, navigation.categoryItem.id, 0, Long.MAX_VALUE)
            navigation.section == SynologyPhotosSection.FOLDERS -> {
                if (navigation.folders.isEmpty()) {
                    val root = repository.rootFolder(navigation.space)
                    checkCurrent(token)
                    mutable.update { it.copy(navigation = it.navigation.copy(folders = listOf(root))) }
                }
                if (repository.canManageFolders) {
                    val folder = state.value.navigation.folders.last()
                    val actual = repository.folderAccess(folder.space, folder.id)
                    checkCurrent(token)
                    mutable.update { it.copy(folderAccess = actual, navigation = it.navigation.copy(folders = it.navigation.folders.dropLast(1) + actual.collection())) }
                }
                loadCollections(token)
                checkCurrent(token)
                val folder = state.value.navigation.folders.last()
                initial = SynologyPhotoQuery.Folder(folder.id, folder.sort ?: SynologyPhotoSort())
            }
            navigation.album != null -> {
                val target = SynologyPhotoSettingsTarget(SynologyPhotoSettingsKind.ALBUM_SORT, albumId = navigation.album.id)
                val value = settingsApplication.readPreference(target, token) as? SynologyPhotoAlbumSortSettings
                mutable.update { it.copy(albumSort = value?.sort) }
                initial = SynologyPhotoQuery.Album(navigation.album.id, value?.sort ?: SynologyPhotoSort(direction = SynologyPhotoSort.Direction.DESCENDING))
            }
            else -> initial = SynologyPhotoQuery.Timeline(0, Long.MAX_VALUE)
        }
        val resolved = when (initial) {
            is SynologyPhotoQuery.Folder, is SynologyPhotoQuery.Album, SynologyPhotoQuery.Recent -> initial
            else -> {
                val days = repository.timeline(navigation.space, initial)
                checkCurrent(token)
                val months = days.filter { it.count > 0 }.map { it.month }.distinct().sortedDescending()
                mutable.update { it.copy(months = months) }
                val bounds = SynologyPhotoWindows.bounds(days) ?: return
                val bounded = SynologyPhotoWindows.constrain(initial, bounds.first, bounds.last) ?: return
                baseQuery = bounded
                bounded
            }
        }
        query = resolved
        val page = repository.photos(navigation.space, resolved, 0, pageSize)
        checkCurrent(token)
        accept(page, 0)
    }

    fun selectSpace(space: SynologyPhotoSpace) {
        if (writesInProgress || space !in state.value.access?.spaces.orEmpty() || space == state.value.navigation.space) return
        mutable.update { it.copy(navigation = SynologyPhotoNavigation(space = space, section = it.navigation.section)) }
        preview.closePreview(); deletion.cancelCandidate(); refresh()
    }

    fun selectSection(section: SynologyPhotosSection) {
        if (writesInProgress || state.value.access?.spaces?.isEmpty() == true &&
            section in setOf(SynologyPhotosSection.TIMELINE, SynologyPhotosSection.FOLDERS)) return
        mutable.update { it.copy(navigation = SynologyPhotoNavigation(space = it.navigation.space, section = section)) }
        preview.closePreview(); deletion.cancelCandidate(); refresh()
    }

    fun search(keyword: String) {
        if (writesInProgress || state.value.access?.spaces?.isEmpty() == true) return
        if (state.value.navigation.isRequests) {
            mutable.update { it.copy(requestSearch = keyword.trim()) }
            if (state.value.visibleSharing.isEmpty() && state.value.hasMoreCollections) loadMore()
            return
        }
        mutable.update { it.copy(navigation = SynologyPhotoNavigation(space = it.navigation.space, keyword = keyword.trim())) }
        refresh()
    }

    fun applyFilter(filter: SynologyPhotoFilter) {
        if (writesInProgress || state.value.access?.spaces?.isEmpty() == true) return
        mutable.update { it.copy(navigation = SynologyPhotoNavigation(space = it.navigation.space, filter = filter)) }
        refresh()
    }

    fun openCategory(category: SynologyPhotoCategory) {
        if (category !in state.value.categories || writesInProgress) return
        mutable.update { it.copy(navigation = SynologyPhotoNavigation(space = it.navigation.space, section = SynologyPhotosSection.ALBUMS,
            category = category, filter = if (category == SynologyPhotoCategory.VIDEOS) SynologyPhotoFilter(mediaType = 1) else SynologyPhotoFilter())) }
        refresh()
    }

    fun openCollection(collection: SynologyPhotoCollection) {
        if (writesInProgress || state.value.collections.none { it == collection }) return
        val old = state.value.navigation
        val next = when {
            old.section == SynologyPhotosSection.FOLDERS -> old.copy(folders = old.folders + collection)
            old.category != null -> old.copy(categoryItem = collection, filter = when (old.category) {
                SynologyPhotoCategory.PEOPLE -> SynologyPhotoFilter(personId = collection.id)
                SynologyPhotoCategory.LOCATIONS -> SynologyPhotoFilter(locationId = collection.id)
                else -> SynologyPhotoFilter()
            })
            else -> old.copy(album = collection)
        }
        mutable.update { it.copy(navigation = next) }
        refresh()
    }

    fun folderBackTo(index: Int) {
        if (writesInProgress || index !in 0 until state.value.navigation.folders.lastIndex) return
        mutable.update { it.copy(navigation = it.navigation.copy(folders = it.navigation.folders.take(index + 1))) }
        refresh()
    }

    private fun folderCompleted(row: SynologyPhotoAlbumCheckpoint?, actual: SynologyPhotoFolderAccess?) {
        albums?.refreshRecords()
        if (row?.finished != true) return
        val operation = row.folder ?: return
        val target = operation.target
        if (row.action == SynologyPhotoAlbumAction.RENAME_FOLDER || row.action == SynologyPhotoAlbumAction.COVER_FOLDER) {
            val newPath = actual?.folder?.path ?: if (row.action == SynologyPhotoAlbumAction.RENAME_FOLDER)
                io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoFolderCodec.renamedPath(target, operation.name!!) else target.path
            fun changed(value: SynologyPhotoCollection): SynologyPhotoCollection {
                if (value.space != target.space) return value
                if (value.id == target.id) return value.copy(name = actual?.folder?.name ?: operation.name ?: value.name, path = newPath,
                    folderCovers = actual?.covers ?: value.folderCovers)
                val path = value.path ?: return value
                return if (row.action == SynologyPhotoAlbumAction.RENAME_FOLDER && path.startsWith("${target.path}/"))
                    value.copy(path = newPath + path.removePrefix(target.path)) else value
            }
            mutable.update { it.copy(collections = it.collections.map(::changed),
                folderAccess = if (it.folderAccess?.folder?.id == target.id && it.navigation.space == target.space) actual ?: it.folderAccess else it.folderAccess,
                navigation = it.navigation.copy(folders = it.navigation.folders.map(::changed))) }
        } else if (active && state.value.navigation.section == SynologyPhotosSection.FOLDERS &&
            state.value.navigation.space == target.space && state.value.navigation.folders.lastOrNull()?.id == target.id) refresh()
    }

    private fun deletionConfirmed(row: SynologyPhotoDeletionCheckpoint) {
        if (!active) return
        val target = row.target
        state.value.items.firstOrNull { it.id.space == target.id.space && target.id.itemId in it.similarGroup?.photoIds.orEmpty() }?.similarGroup?.let { group ->
            scope.launch { try { similarApplication.originalDeleted(group); similar?.originalDeleted(target.id) } catch (error: Exception) { if (error !is CancellationException) mutable.update { it.copy(error = error) } } }
        }
        confirmedDeletionTargets[target.id] = target
        val removed = state.value.items.filter { it.similarGroup == null && target.matches(it, includeContext = false) }.mapTo(mutableSetOf()) { it.id }
        if (removed.isNotEmpty()) {
            resetRequests()
            nextOffset = maxOf(0, nextOffset - pagedPhotoIds.count { it in removed })
            pagedPhotoIds.removeAll(removed)
            replaceItems(state.value.items.filterNot { it.id in removed })
        }
        if (preview.state.value.photo?.let { target.matches(it, includeContext = false) } == true) preview.closePreview()
        edits?.selectMode(false)
    }
    private fun wasDeleted(photo: SynologyPhoto): Boolean = photo.id in confirmedDeletedIds ||
        confirmedDeletionTargets[photo.id]?.matches(photo, includeContext = false) == true

    private fun fileCompleted(row: SynologyPhotoAlbumCheckpoint) {
        if (!active) return
        val files = row.files ?: return
        val navigation = state.value.navigation
        if (row.action != SynologyPhotoAlbumAction.COPY_ITEMS && row.submitted && navigation.section == SynologyPhotosSection.FOLDERS && navigation.space == files.space) {
            val inside = navigation.folders.indexOfFirst { folder -> files.folders.any { it.id == folder.id } }
            if (inside > 0) {
                mutable.update { it.copy(navigation = it.navigation.copy(folders = navigation.folders.take(inside))) }
                refresh(); return
            }
        }
        if (row.phase != SynologyPhotoAlbumPhase.COMPLETED) return
        edits?.selectMode(false); albums?.refreshRecords(); folders?.refreshRecords()
        if (state.value.loading) { refresh(); return }
        if (row.action == SynologyPhotoAlbumAction.COPY_ITEMS) {
            if (navigation.section == SynologyPhotosSection.FOLDERS && navigation.space == files.destination?.space &&
                navigation.folders.lastOrNull()?.id == files.destination.id) refresh()
            return
        }
        val removing = row.action == SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS
        val crossSpace = files.destination?.space != files.space
        if (!removing && navigation.album != null && crossSpace) { refresh(); return }
        val targets = row.targets.associateBy { it.id }
        val removed = state.value.items.filter { photo -> targets[photo.id]?.let { target ->
            target.filename == photo.filename && target.sizeBytes == photo.sizeBytes && target.folderId == photo.folderId &&
                (removing || crossSpace || navigation.section == SynologyPhotosSection.FOLDERS && navigation.folders.lastOrNull()?.id == target.folderId)
        } == true }.mapTo(mutableSetOf()) { it.id }
        val sourceParent = files.folders.firstOrNull()?.parentId
        val removedFolders = if (navigation.section == SynologyPhotosSection.FOLDERS && navigation.space == files.space && navigation.folders.lastOrNull()?.id == sourceParent)
            state.value.collections.filter { folder -> files.folders.any { it.id == folder.id && it.path == folder.path } } else emptyList()
        if (removed.isNotEmpty() || removedFolders.isNotEmpty()) {
            // 作废仍使用旧偏移的在途分页，保留月份、查询与已加载内容。
            resetRequests()
            nextOffset = maxOf(0, nextOffset - pagedPhotoIds.count { it in removed }); pagedPhotoIds.removeAll(removed)
            collectionOffset = maxOf(0, collectionOffset - removedFolders.size)
            mutable.update { it.copy(collections = it.collections.filterNot { folder -> folder in removedFolders }) }
        }
        if (removing) confirmedDeletedIds.addAll(row.targets.map { it.id })
        replaceItems(state.value.items.filterNot { it.id in removed }.map { photo ->
            if (!removing && !crossSpace && photo.id in targets) photo.copy(folderId = files.destination!!.id) else photo
        })
        if (preview.state.value.photo?.id in removed) preview.closePreview()
    }

    fun goBack(): Boolean {
        if (writesInProgress) return false
        val old = state.value.navigation
        val next = when {
            old.folders.size > 1 -> old.copy(folders = old.folders.dropLast(1))
            old.album != null -> old.copy(album = null)
            old.categoryItem != null -> old.copy(categoryItem = null, filter = SynologyPhotoFilter())
            old.category != null -> old.copy(category = null, filter = SynologyPhotoFilter())
            else -> return false
        }
        mutable.update { it.copy(navigation = next) }
        refresh()
        return true
    }

    fun selectShareScope(scope: SynologyPhotoShareScope) {
        if (writesInProgress) return
        mutable.update { it.copy(navigation = SynologyPhotoNavigation(space = it.navigation.space, section = SynologyPhotosSection.SHARING, shareScope = scope)) }
        refresh()
    }

    fun openSharedAlbum(entry: SynologyPhotoSharedEntry) {
        val id = entry.albumId ?: return
        if (writesInProgress || state.value.sharing.none { it == entry }) return
        mutable.update { it.copy(navigation = it.navigation.copy(album = SynologyPhotoCollection(id, entry.title, isTemporary = entry.isTemporary))) }
        refresh()
    }

    fun loadMore(automatic: Boolean = false): Job? {
        val state = state.value
        if (!active || writesInProgress || memberWindow != null || state.loading || state.loadingMore ||
            (!state.hasMore && !state.hasMoreCollections) || (automatic && state.error != null)) return null
        val token = generation
        mutable.update { it.copy(loadingMore = true, error = null) }
        pagingJob = scope.launch {
            try {
                if (state.hasMoreCollections) loadCollections(token) else {
                    val requested = nextOffset
                    val page = repository.photos(state.navigation.space, query ?: return@launch, requested, pageSize)
                    checkCurrent(token)
                    accept(page, requested)
                }
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loadingMore = false) } }
        }
        return pagingJob
    }

    private suspend fun loadCollections(token: Long) {
        val navigation = state.value.navigation
        val offset = collectionOffset
        val sharing = navigation.section == SynologyPhotosSection.SHARING && navigation.album == null
        if (sharing) {
            do {
            val offset = collectionOffset
            val page = repository.sharedEntries(navigation.shareScope, offset, pageSize, state.value.albumListSort)
            checkCurrent(token)
            if (page.size > pageSize || page.map { it.id }.distinct().size != page.size) invalid()
            val previous = state.value.sharing.mapTo(mutableSetOf()) { it.id }
            val added = page.filter { previous.add(it.id) }
            if (page.size == pageSize && added.isEmpty()) invalid()
            collectionOffset += page.size
            mutable.update { it.copy(sharing = it.sharing + added, hasMoreCollections = page.size == pageSize, paginationKey = it.paginationKey + 1) }
            } while (navigation.isRequests && state.value.requestSearch.isNotEmpty() && state.value.visibleSharing.isEmpty() && state.value.hasMoreCollections)
        } else {
            val page = when {
                navigation.section == SynologyPhotosSection.FOLDERS -> repository.folders(navigation.space, navigation.folders.last().id, offset, pageSize, navigation.folders.last().sort?.direction ?: SynologyPhotoSort.Direction.ASCENDING)
                navigation.category != null -> repository.categoryItems(navigation.category, offset, pageSize, navigation.space)
                else -> repository.albums(offset, pageSize, state.value.albumDisplay, state.value.albumListSort)
            }
            checkCurrent(token)
            if (page.size > pageSize || page.map { it.id }.distinct().size != page.size) invalid()
            val previous = state.value.collections.mapTo(mutableSetOf()) { it.id }
            val added = page.filter { previous.add(it.id) }
            if (page.size == pageSize && added.isEmpty()) invalid()
            collectionOffset += page.size
            mutable.update { it.copy(collections = it.collections + added, hasMoreCollections = page.size == pageSize, paginationKey = it.paginationKey + 1) }
        }
    }

    fun jumpToMonth(month: YearMonth): Job? {
        if (!active || writesInProgress || memberWindow != null || month !in state.value.months) return null
        val end = month.plusMonths(1).atDay(1).atStartOfDay(zone).toEpochSecond() - 1
        val nextQuery = SynologyPhotoWindows.constrain(baseQuery ?: return null, end = end) ?: return null
        val token = resetRequests()
        query = nextQuery; previousMonth = month; nextOffset = 0; pagedPhotoIds.clear()
        replaceItems(emptyList())
        mutable.update { it.copy(selectedMonth = month, loading = true, error = null, previousError = null,
            hasMore = false, hasPrevious = it.months.any { candidate -> candidate > month }) }
        navigationJob = scope.launch {
            try {
                val page = repository.photos(state.value.navigation.space, nextQuery, 0, pageSize)
                checkCurrent(token); accept(page, 0)
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loading = false) } }
        }
        return navigationJob
    }

    fun loadPrevious(): Job? {
        if (!active || writesInProgress || memberWindow != null || state.value.loading || state.value.loadingPrevious) return null
        val prior = previousMonth ?: return null
        val next = state.value.months.lastOrNull { it > prior } ?: return null
        val base = baseQuery ?: return null
        val request = SynologyPhotoWindows.constrain(base,
            start = prior.plusMonths(1).atDay(1).atStartOfDay(zone).toEpochSecond(),
            end = next.plusMonths(1).atDay(1).atStartOfDay(zone).toEpochSecond() - 1) ?: return null
        val token = generation
        mutable.update { it.copy(loadingPrevious = true, previousError = null) }
        previousJob = scope.launch {
            try {
                // 同月可能有多页甚至相同拍摄秒；原始游标分页完整后再一次性插入。
                val staged = mutableListOf<SynologyPhoto>()
                val stagedIds = mutableSetOf<SynologyPhotoId>()
                var offset = 0
                do {
                    val page = repository.photos(state.value.navigation.space, request, offset, pageSize)
                    checkCurrent(token); validatePage(page, offset)
                    val added = page.items.filter { stagedIds.add(it.id) && !wasDeleted(it) }
                    if (page.hasMore && added.isEmpty()) invalid()
                    staged += added
                    offset = page.nextOffset
                    if (!page.hasMore) break
                    yield()
                } while (true)
                checkCurrent(token)
                val existing = state.value.items.mapTo(mutableSetOf()) { it.id }
                replaceItems(staged.filterNot { it.id in existing } + state.value.items)
                previousMonth = next
                mutable.update { it.copy(hasPrevious = it.months.any { month -> month > next }, paginationKey = it.paginationKey + 1) }
            } catch (error: Exception) {
                if (error !is CancellationException && current(token)) mutable.update { it.copy(previousError = error) }
            } finally { if (current(token)) mutable.update { it.copy(loadingPrevious = false) } }
        }
        return previousJob
    }

    fun loadFilterOptions(): Job? {
        if (!active || state.value.optionsLoading || state.value.access?.spaces?.isEmpty() == true) return null
        val token = ++optionsGeneration
        mutable.update { it.copy(optionsLoading = true, optionsError = null) }
        optionsJob = scope.launch {
            try {
                val options = repository.filterOptions(state.value.navigation.space)
                if (active && token == optionsGeneration) mutable.update { it.copy(options = options) }
            } catch (error: Exception) {
                if (error !is CancellationException && active && token == optionsGeneration) mutable.update { it.copy(optionsError = error) }
            } finally { if (active && token == optionsGeneration) mutable.update { it.copy(optionsLoading = false) } }
        }
        return optionsJob
    }

    suspend fun thumbnail(photo: SynologyPhoto) = mediaUpdates.thumbnail(photo)
    suspend fun albumThumbnail(id: Long) = mediaUpdates.albumThumbnail(id)
    suspend fun folderThumbnail(folder: SynologyPhotoCollection, cover: SynologyPhotoFolderCover) = mediaUpdates.folderThumbnail(folder, cover)

    private fun accept(page: SynologyPhotoPage, requestedOffset: Int) {
        validatePage(page, requestedOffset)
        val existing = state.value.items.mapTo(mutableSetOf()) { it.id }
        val additions = page.items.filter { existing.add(it.id) && !wasDeleted(it) }
        if (page.hasMore && additions.isEmpty()) invalid()
        replaceItems(state.value.items + additions)
        nextOffset = page.nextOffset; pagedPhotoIds.addAll(page.items.map { it.id })
        mutable.update { it.copy(hasMore = page.hasMore, paginationKey = it.paginationKey + 1) }
    }
    private fun validatePage(page: SynologyPhotoPage, offset: Int) {
        if (page.offset != offset || page.items.size > pageSize || page.nextOffset != offset + page.items.size ||
            (page.hasMore && page.items.isEmpty()) || page.items.map { it.id }.distinct().size != page.items.size ||
            page.items.any { photo ->
                val albumId = state.value.navigation.album?.id
                photo.id.profileId != profileId || if (albumId == null) {
                    photo.id.space != state.value.navigation.space || photo.albumContext != null
                } else photo.albumContext?.let { context ->
                    context.albumId != albumId || context.ownerUserId < 0 ||
                        photo.id.space != if (context.ownerUserId == 0L) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL
                } != false
            }) invalid()
    }
    private fun preferencesSaved(value: SynologyPhotoSettings) {
        val navigation = state.value.navigation
        val matching = when (value) {
            is SynologyPhotoAlbumSortSettings -> navigation.album?.id == value.albumId && navigation.keyword.isEmpty() && !navigation.filter.isActive
            is SynologyPhotoAlbumListSortSettings -> navigation.albumListScope == value.scope
            is SynologyPhotoAlbumDisplaySettings -> navigation.albumListScope == SynologyPhotoAlbumListScope.ALBUMS
            else -> false
        }
        if (matching) refresh()
    }
    private suspend fun sharedMembersChanging() {
        val previous = state.value
        if (previous.navigation.space != SynologyPhotoSpace.SHARED) return
        if (memberWindow == null) memberWindow = SynologyPhotoMemberWindow(previous.navigation, query, maxOf(pageSize, previous.items.size))
        resetRequests(); preview.closePreview(); deletion.cancelCandidate(); edits?.selectMode(false)
        mutable.update { it.copy(items = emptyList(), groups = emptyList(), collections = emptyList(), sharing = emptyList(),
            categories = emptySet(), folderAccess = null, loading = false, loaded = false, hasMore = false, hasMoreCollections = false, error = null) }
        thumbnails.clear()
    }
    private suspend fun sharedMembersApplied(value: SynologyPhotoSharedSettings) {
        if (active && memberWindow?.navigation == state.value.navigation) reloadMemberWindow(value) else settingsApplied(value)
    }
    private fun reloadMemberWindow(settings: SynologyPhotoSharedSettings? = null): Job? {
        val window = memberWindow ?: return null
        if (!active || writesInProgress) return null
        val token = resetRequests(); nextOffset = 0; pagedPhotoIds.clear()
        mutable.update { it.copy(items = emptyList(), groups = emptyList(), loading = true, error = null) }
        navigationJob = scope.launch {
            try {
                val actual = settings ?: repository.photoSettings(SynologyPhotoSettingsKind.SHARED) as SynologyPhotoSharedSettings
                checkCurrent(token); settingsApplied(actual); checkCurrent(token)
                if (window.query == null) { memberWindow = null; mutable.update { it.copy(loading = false) }; refresh(); return@launch }
                readPhotoMemberWindow(repository, state.value.navigation.space, window.query, window.count, pageSize) { page, offset ->
                    checkCurrent(token); accept(page, offset)
                }
                memberWindow = null; mutable.update { it.copy(loaded = true) }
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loading = false) } }
        }
        return navigationJob
    }
    private suspend fun settingsApplied(value: SynologyPhotoSettings) { if (value is SynologyPhotoAutomaticPreviewSettings) automaticPreviews?.applySettings(value); settingsApplication.apply(value) }
    private fun replaceItems(items: List<SynologyPhoto>) {
        val groups = SynologyPhotoWindows.groups(items, state.value.navigation.category == SynologyPhotoCategory.RECENT, zone, state.value.access?.displaySettings?.grouping)
        mutable.update { it.copy(items = items, groups = groups) }
    }
    private fun resetRequests(): Long {
        slideshow.stop()
        generation++; navigationJob?.cancel(); pagingJob?.cancel(); previousJob?.cancel()
        optionsGeneration++; optionsJob?.cancel()
        mutable.update { it.copy(loadingMore = false, loadingPrevious = false, optionsLoading = false, options = SynologyPhotoFilterOptions(), optionsError = null, paginationKey = it.paginationKey + 1) }
        return generation
    }
    private fun current(token: Long): Boolean = active && token == generation
    private suspend fun checkCurrent(token: Long) { currentCoroutineContext().ensureActive(); if (!current(token)) throw CancellationException() }
    private fun present(error: Exception, token: Long) {
        if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) }
    }
    private fun invalid(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)

    fun deactivate(preservePreparedExport: Boolean = false) {
        if (preservePreparedExport && (exports.state.value.awaitingPicker || execution != null && exports.state.value.busy)) {
            active = false; generation++; navigationJob?.cancel(); pagingJob?.cancel(); previousJob?.cancel(); slideshow.stop()
            preview.deactivate(); background?.deactivate(); people?.deactivate(); concepts?.deactivate(); similar?.deactivate(); manualFaces?.deactivate(); settings?.deactivate(); sharedMembers?.deactivate(); maintenance?.deactivate(); codecPrompt?.deactivate(); previewRegeneration?.deactivate(); automaticPreviews?.deactivate(); mutable.update { it.copy(loading = false, loadingMore = false, loadingPrevious = false) }
            return
        }
        active = false; resetRequests(); optionsGeneration++; optionsJob?.cancel()
        exports.deactivate(false); preview.deactivate(); deletion.deactivate(); files?.deactivate(); background?.deactivate(); people?.deactivate(); concepts?.deactivate(); similar?.deactivate(); manualFaces?.deactivate(); settings?.deactivate(); sharedMembers?.deactivate(); maintenance?.deactivate(); codecPrompt?.deactivate(); previewRegeneration?.deactivate(); automaticPreviews?.deactivate()
        mutable.update { it.copy(loading = false, loaded = false, optionsLoading = false) }
        scope.launch { thumbnails.clear() }
    }
    /** 撤权清除图库和媒体，但保留 deletion 的已提交事实，恢复授权后只能继续只读回查。 */
    fun revokeAccess() { deactivate(); memberWindow = null; similarApplication.clear(); deletion.revokeAccess(); uploads?.revokeAccess(); edits?.revokeAccess(); albums?.revokeAccess(); requests?.revokeAccess(); folders?.revokeAccess(); files?.revokeAccess(); folderSharing?.revokeAccess(); settings?.revokeAccess(); sharedMembers?.revokeAccess(); maintenance?.revokeAccess(); codecPrompt?.revokeAccess(); previewRegeneration?.revokeAccess(); automaticPreviews?.revokeAccess(); background?.revokeAccess(); people?.revokeAccess(); concepts?.revokeAccess(); similar?.revokeAccess(); manualFaces?.revokeAccess(); mutable.value = SynologyPhotosState() }
    override fun close() { deactivate(); memberWindow = null; similarApplication.clear(); deletion.close(); uploads?.close(); edits?.close(); albums?.close(); requests?.close(); folders?.close(); files?.close(); folderSharing?.close(); settings?.close(); sharedMembers?.close(); maintenance?.close(); codecPrompt?.close(); previewRegeneration?.close(); automaticPreviews?.close(); background?.close(); people?.close(); concepts?.close(); similar?.close(); manualFaces?.close(); thumbnails.close(); job.cancel(); mutable.value = SynologyPhotosState() }
}

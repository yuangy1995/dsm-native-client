package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import java.util.UUID
import io.github.qwertyuiop1995.dsmnativeclient.background.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoUploadDraft(
    val id: String = UUID.randomUUID().toString(), val target: SynologyPhotoUploadTarget?, val targetName: String,
    val duplicate: SynologyPhotoUploadDuplicate? = null, val keepFolders: Boolean = true,
)
internal data class SynologyPhotoUploadState(
    val visible: Boolean = false, val draft: SynologyPhotoUploadDraft? = null,
    val records: List<SynologyPhotoUploadBatch> = emptyList(), val selectedId: String? = null,
    val albums: List<SynologyPhotoCollection> = emptyList(), val moreAlbums: Boolean = true,
    val loading: Boolean = false, val albumsLoading: Boolean = false, val working: Boolean = false,
    val importing: Boolean = false, val importedFiles: Int = 0, val importCount: Int = 0,
    val activeName: String? = null, val bytes: Long = 0, val totalBytes: Long = 0, val error: Throwable? = null,
) {
    val selected: SynologyPhotoUploadBatch? get() = records.firstOrNull { it.id == selectedId }
}

/** 与当前连接同寿命；切页不改目标，退出账号取消执行并保留已提交记录。 */
internal class SynologyPhotoUploadModel(
    private val repository: SynologyPhotosServing,
    parent: CoroutineScope,
    private val store: SynologyPhotoUploadStore,
    private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit,
    beforeWrite: suspend (SynologyPhotoUploadTarget) -> Unit = {},
    private val executionHost: WorkspaceExecution? = null,
    private val onCompleted: () -> Unit,
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + job)
    private val execution = SynologyPhotoUploadExecution(repository, store, owner, beforeWrite = beforeWrite, requireCurrent = requireCurrent)
    private val mutable = MutableStateFlow(SynologyPhotoUploadState())
    val state = mutable.asStateFlow()
    private var worker: Job? = null
    private var settings: Job? = null
    private var albumsJob: Job? = null
    private var recordJob: Job? = null
    private var albumOffset = 0
    private var generation = 0L
    private var pickerDraft: SynologyPhotoUploadDraft? = null

    fun preparePicker(): Boolean {
        val draft = state.value.draft ?: return false
        if (state.value.working || draft.target == null || draft.duplicate == null) return false
        pickerDraft = draft
        return true
    }
    fun receiveSelection(sources: suspend () -> List<SynologyPhotoLocalSource>): Job? {
        val draft = pickerDraft ?: return null
        pickerDraft = null
        return stage(draft, sources)
    }

    fun open(navigation: SynologyPhotoNavigation, access: SynologyPhotoAccess?) {
        if (!job.isActive || !repository.canUploadPhotos) return
        if (state.value.working) { mutable.update { it.copy(visible = true) }; return }
        generation++; settings?.cancel(); albumsJob?.cancel(); recordJob?.cancel(); pickerDraft = null
        val album = navigation.album?.takeIf { !it.isConditional && !it.isFrozen }
        val folder = navigation.folders.lastOrNull()
        val target = when {
            album != null -> SynologyPhotoUploadTarget.Album(album.id)
            folder != null && navigation.section == SynologyPhotosSection.FOLDERS -> SynologyPhotoUploadTarget.Folder(navigation.space, folder.id)
            navigation.space in access?.spaces.orEmpty() -> SynologyPhotoUploadTarget.Timeline(navigation.space)
            else -> null
        }
        val draft = SynologyPhotoUploadDraft(target = target, targetName = album?.name ?: folder?.name.orEmpty())
        mutable.update { it.copy(visible = true, draft = draft, selectedId = null, albums = emptyList(), moreAlbums = true,
            loading = false, albumsLoading = false, error = null) }
        albumOffset = 0
        loadSettings(draft.id)
        refreshRecords()
    }

    fun showQueue() { mutable.update { it.copy(visible = true, draft = null, error = null) }; refreshRecords() }
    fun dismiss() { mutable.update { it.copy(visible = false) } }
    fun selectBatch(id: String) {
        if (state.value.working || state.value.records.none { it.id == id }) return
        mutable.update { it.copy(draft = null, selectedId = id, error = null) }
    }
    fun selectTarget(target: SynologyPhotoUploadTarget, name: String = "") {
        if (state.value.working) return
        mutable.update { it.copy(draft = it.draft?.copy(target = target, targetName = name), error = null) }
    }
    fun selectDuplicate(value: SynologyPhotoUploadDuplicate) {
        if (state.value.working) return
        mutable.update { it.copy(draft = it.draft?.copy(duplicate = value), error = null) }
    }
    fun keepFolders(value: Boolean) { if (!state.value.working) mutable.update { it.copy(draft = it.draft?.copy(keepFolders = value)) } }

    fun loadSettings(id: String? = state.value.draft?.id) {
        if (id == null) return
        settings?.cancel()
        val token = generation
        mutable.update { it.copy(loading = true, error = null) }
        settings = scope.launch {
            try {
                requireCurrent()
                val policy = repository.uploadDuplicatePolicy()
                if (current(token) && state.value.draft?.id == id) mutable.update {
                    it.copy(draft = it.draft?.let { draft -> if (draft.duplicate == null) draft.copy(duplicate = policy) else draft })
                }
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loading = false) } }
        }
    }

    fun loadAlbums(): Job? {
        if (state.value.albumsLoading || !state.value.moreAlbums || state.value.draft == null) return null
        val token = generation
        val draftId = state.value.draft?.id
        mutable.update { it.copy(albumsLoading = true, error = null) }
        albumsJob = scope.launch {
            try {
                requireCurrent()
                val result = repository.addableAlbums(albumOffset, 100)
                if (!current(token) || state.value.draft?.id != draftId) return@launch
                val known = state.value.albums.mapTo(mutableSetOf()) { it.id }
                if (result.size > 100 || result.map { it.id }.distinct().size != result.size || result.any { !known.add(it.id) })
                    throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
                albumOffset += result.size
                mutable.update { it.copy(albums = it.albums + result, moreAlbums = result.size == 100) }
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(albumsLoading = false) } }
        }
        return albumsJob
    }

    fun refreshRecords(): Job? {
        if (!job.isActive || state.value.working || recordJob?.isActive == true) return null
        val token = generation
        recordJob = scope.launch {
            try { reload(token) } catch (error: Exception) { present(error, token) }
        }
        return recordJob
    }

    /** 选择器回调必须携带打开时的草稿；迟到结果不能换账号、换目录或换相册。 */
    fun stage(draft: SynologyPhotoUploadDraft, sources: suspend () -> List<SynologyPhotoLocalSource>): Job? {
        if (!job.isActive || state.value.working || state.value.draft != draft || draft.target == null || draft.duplicate == null) return null
        val token = generation
        mutable.update { it.copy(working = true, importing = true, error = null, importedFiles = 0, importCount = 0) }
        worker = scope.launch {
            var lease: WorkspaceExecutionLease? = null
            try {
                lease = executionHost?.begin(owner, WorkspaceExecutionActivity.PHOTO_UPLOAD)
                requireCurrent()
                val userId = repository.uploadIdentity()
                val selected = withContext(Dispatchers.IO) { sources() }
                val row = execution.stage(userId, draft.target, draft.targetName, draft.duplicate, selected, draft.keepFolders) { done, total, bytes ->
                    if (current(token)) { lease?.update(bytes, 0); mutable.update { it.copy(importedFiles = done, importCount = total, bytes = bytes) } }
                }
                if (current(token)) mutable.update { it.copy(draft = null, selectedId = row.id) }
            } catch (error: Exception) { present(error, token) }
            finally {
                lease?.finish()
                if (current(token)) {
                    mutable.update { it.copy(working = false, importing = false) }
                    try { reload(token) } catch (error: Exception) { present(error, token) }
                }
            }
        }
        return worker
    }

    fun start(id: String, reviewOnly: Boolean = false): Job? {
        val selected = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!job.isActive || state.value.working || selected.finished) return null
        val token = generation
        mutable.update { it.copy(working = true, selectedId = id, draft = null, error = null, activeName = null, bytes = 0, totalBytes = 0) }
        worker = scope.launch {
            var lease: WorkspaceExecutionLease? = null
            try {
                lease = executionHost?.begin(owner, WorkspaceExecutionActivity.PHOTO_UPLOAD)
                val result = execution.run(id, selected.userId, reviewOnly) { row, name, done, total ->
                    lease?.update(done, total)
                    if (current(token)) mutable.update { state -> state.copy(records = state.records.map { if (it.id == id) row else it },
                        activeName = name, bytes = done, totalBytes = total) }
                }
                if (current(token)) mutable.update { it.copy(records = it.records.map { row -> if (row.id == id) result else row }) }
            } catch (error: Exception) { present(error, token) }
            finally {
                lease?.finish()
                if (current(token)) {
                    mutable.update { it.copy(working = false, activeName = null, bytes = 0, totalBytes = 0) }
                    try { reload(token) } catch (error: Exception) { present(error, token) }
                    onCompleted()
                }
            }
        }
        return worker
    }

    fun pause() { worker?.cancel() }
    fun discard(id: String): Job? {
        if (state.value.working) return null
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        val token = generation
        return scope.launch {
            try {
                withContext(Dispatchers.IO) { requireCurrent(); store.discard(row) }
                reload(token)
                if (current(token)) mutable.update { it.copy(selectedId = null, error = null) }
            } catch (error: Exception) { present(error, token) }
        }
    }

    fun revokeAccess() {
        generation++; worker?.cancel(); settings?.cancel(); albumsJob?.cancel(); recordJob?.cancel()
        pickerDraft = null
        mutable.value = SynologyPhotoUploadState()
    }
    override fun close() { revokeAccess(); job.cancel() }

    private suspend fun reload(token: Long) {
        requireCurrent()
        val userId = repository.uploadIdentity()
        val records = withContext(Dispatchers.IO) { store.records(owner, userId) }
        if (current(token)) mutable.update { it.copy(records = records) }
    }
    private fun current(token: Long) = token == generation && job.isActive
    private fun present(error: Exception, token: Long) {
        if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) }
    }
}

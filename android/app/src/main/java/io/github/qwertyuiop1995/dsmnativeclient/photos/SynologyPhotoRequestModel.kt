package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoRequestCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** 表单只保留在会话内；持久写入与相册共用归属、互斥和阶段记录。 */
internal class SynologyPhotoRequestModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit, private val access: () -> SynologyPhotoAccess?,
    private val canStart: () -> Boolean, private val beforeWrite: suspend () -> Unit = {},
    private val onCompleted: () -> Unit,
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoRequestState())
    val state = mutable.asStateFlow()
    val spaces get() = access()?.spaces.orEmpty()
    val canCreateAlbum get() = repository.canManageAlbums && SynologyPhotoSpace.PERSONAL in spaces
    private var generation = 0L
    private var folderGeneration = 0L
    private var loader: Job? = null
    private var albumLoader: Job? = null
    private var folderLoader: Job? = null
    private var worker: Job? = null
    private var recordLoader: Job? = null
    private var openId: String? = null
    private var deleting = false
    private var shortcutFolder: SynologyPhotoCollection? = null
    private var shortcutAlbum: Long? = null

    fun open(id: String? = null, delete: Boolean = false, folder: SynologyPhotoCollection? = null, albumId: Long? = null) {
        if (!canOpen() || delete && id == null) return
        reset(); openId = id; deleting = delete; shortcutFolder = folder; shortcutAlbum = albumId
        mutable.value = SynologyPhotoRequestState(visible = true)
        load()
    }
    fun load(): Job? {
        if (state.value.working || state.value.loading || !state.value.visible) return null
        val token = generation; val id = openId; val folder = shortcutFolder; val albumId = shortcutAlbum
        mutable.update { it.copy(loading = true, error = null, draft = null) }
        loader = scope.launch {
            try {
                requireCurrent()
                val original = id?.let { repository.photoRequest(it) }
                val source = original?.settings?.space ?: folder?.space ?: spaces.firstOrNull() ?: denied()
                var settings = original?.settings ?: SynologyPhotoRequestSettings(space = source)
                var defaultFolder = original == null && canUseDefaultRequestFolder(access(), source)
                if (original == null && folder != null) {
                    val actual = repository.photoRequestFolder(source, folder.id)
                    if (actual.path == null || folder.path != null && actual.path != folder.path) changed()
                    settings = settings.copy(folderId = actual.id, folderPath = actual.path, subject = actual.name.takeIf { it != "/" }.orEmpty())
                    defaultFolder = false
                }
                if (original == null && albumId != null) {
                    val album = repository.photoRequestAlbums().singleOrNull { it.sourceAlbumId == albumId } ?: denied()
                    settings = settings.copy(albumId = album.albumId, albumPassphrase = album.passphrase, subject = album.name)
                    check(token); mutable.update { it.copy(albums = listOf(album)) }
                }
                check(token)
                mutable.update { it.copy(draft = SynologyPhotoRequestDraft(original = original, settings = settings, deleting = deleting,
                    usesDefaultFolder = defaultFolder, limitsSize = settings.sizeLimit > 0,
                    sizeMiB = if (settings.sizeLimit > 0) maxOf(1, settings.sizeLimit / 1_048_576).toString() else "25")) }
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loading = false) } }
        }
        return loader
    }
    private fun edit(change: (SynologyPhotoRequestDraft) -> SynologyPhotoRequestDraft) {
        if (state.value.working || state.value.loading || state.value.draft?.deleting == true) return
        mutable.update { it.copy(draft = it.draft?.let(change), error = null) }
    }
    fun subject(value: String) = edit { it.copy(settings = it.settings.copy(subject = value)) }
    fun description(value: String) = edit { it.copy(settings = it.settings.copy(description = value)) }
    fun expiration(value: Long) { if (value >= 0) edit { it.copy(settings = it.settings.copy(expiration = value)) } }
    fun size(value: String) = edit { it.copy(sizeMiB = value, sizeEdited = true) }
    fun limitsSize(value: Boolean) = edit { it.copy(limitsSize = value, sizeEdited = true) }
    fun useDefaultFolder(value: Boolean) = edit { it.copy(usesDefaultFolder = value && canUseDefaultRequestFolder(access(), it.settings.space)) }
    fun changeSpace(value: SynologyPhotoSpace) {
        if (value !in spaces || value == state.value.draft?.settings?.space || state.value.working) return
        resetFolders()
        edit { it.copy(settings = it.settings.copy(space = value, folderId = null, folderPath = ""), usesDefaultFolder = canUseDefaultRequestFolder(access(), value)) }
    }
    val canUseDefault get() = state.value.draft?.let { canUseDefaultRequestFolder(access(), it.settings.space) } == true
    val canSave: Boolean get() {
        val draft = state.value.draft ?: return false
        if (!canOpen() || state.value.loading) return false
        return if (draft.deleting) draft.original != null else draft.prepared(access())?.let { it != draft.original?.settings } == true
    }
    fun selectAlbums(): Job? {
        if (state.value.working || state.value.draft == null) return null
        mutable.update { it.copy(page = SynologyPhotoRequestPage.ALBUMS) }
        if (state.value.albumsLoading || state.value.albumsLoaded) return null
        val token = generation; mutable.update { it.copy(albumsLoading = true, albumError = null) }
        albumLoader = scope.launch {
            try { requireCurrent(); val values = repository.photoRequestAlbums(); check(token); mutable.update { it.copy(albums = values, albumsLoaded = true) } }
            catch (error: Exception) { if (error !is CancellationException && current(token)) mutable.update { it.copy(albumError = error) } }
            finally { if (current(token)) mutable.update { it.copy(albumsLoading = false) } }
        }
        return albumLoader
    }
    fun selectAlbum(album: SynologyPhotoRequestAlbum?) {
        if (album != null && album !in state.value.albums) return
        edit { it.copy(settings = it.settings.copy(albumId = album?.albumId, albumPassphrase = album?.passphrase)) }
        backToForm()
    }
    fun albumSearch(value: String) { mutable.update { it.copy(albumSearch = value) } }
    fun albumName(value: String) { if (!state.value.working && state.value.pendingAlbum == null) mutable.update { it.copy(newAlbumName = value) } }
    fun backToForm() { if (!state.value.working) mutable.update { it.copy(page = SynologyPhotoRequestPage.FORM) } }
    fun folders(path: List<SynologyPhotoCollection> = emptyList(), more: Boolean = false): Job? {
        val space = state.value.draft?.settings?.space ?: return null
        if (state.value.working || more && (state.value.foldersLoading || !state.value.moreFolders) || path.any { it.space != space }) return null
        folderLoader?.cancel(); val folderToken = ++folderGeneration; val token = generation
        val original = if (more) state.value.folders else emptyList()
        mutable.update { it.copy(page = SynologyPhotoRequestPage.FOLDERS, folders = original, folderPath = path, foldersLoading = true, folderError = null) }
        folderLoader = scope.launch {
            try {
                requireCurrent(); val selected = if (path.isEmpty()) listOf(repository.rootFolder(space)) else path
                val values = repository.folders(space, selected.last().id, original.size, 100)
                if (values.size > 100 || (original + values).map { it.id }.distinct().size != original.size + values.size) changed()
                check(token); if (folderToken != folderGeneration) return@launch
                mutable.update { it.copy(folderPath = selected, folders = original + values, moreFolders = values.size == 100) }
            } catch (error: Exception) { if (error !is CancellationException && current(token) && folderToken == folderGeneration) mutable.update { it.copy(folderError = error) } }
            finally { if (current(token) && folderToken == folderGeneration) mutable.update { it.copy(foldersLoading = false) } }
        }
        return folderLoader
    }
    fun chooseFolder(): Job? {
        val selected = state.value.folderPath.lastOrNull() ?: return null
        if (state.value.foldersLoading || state.value.working || state.value.folderError != null) return null
        val token = generation; val folderToken = folderGeneration
        mutable.update { it.copy(foldersLoading = true) }
        folderLoader = scope.launch {
            try {
                requireCurrent(); val actual = repository.photoRequestFolder(selected.space, selected.id); check(token)
                if (folderToken != folderGeneration) return@launch
                if (actual.path == null || selected.path != null && actual.path != selected.path) changed()
                edit { it.copy(usesDefaultFolder = false, settings = it.settings.copy(folderId = actual.id, folderPath = actual.path)) }
                mutable.update { it.copy(page = SynologyPhotoRequestPage.FORM) }
            } catch (error: Exception) { if (error !is CancellationException && current(token) && folderToken == folderGeneration) mutable.update { it.copy(folderError = error) } }
            finally { if (current(token) && folderToken == folderGeneration) mutable.update { it.copy(foldersLoading = false) } }
        }
        return folderLoader
    }
    fun save(): Job? {
        val draft = state.value.draft ?: return null
        if (!canSave) return null
        val action = if (draft.deleting) SynologyPhotoAlbumAction.DELETE_REQUEST else if (draft.original == null) SynologyPhotoAlbumAction.CREATE_REQUEST else SynologyPhotoAlbumAction.UPDATE_REQUEST
        val change = SynologyPhotoRequestChange(draft.original, draft.prepared(access()).takeUnless { draft.deleting })
        return perform(draft.id, createsAlbum = false) {
            val row = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId,
                userId = repository.photoEditIdentity(), operationId = draft.id, action = action, request = SynologyPhotoRequestCodec.checkpoint(action, change)))
            repository.preparePhotoRequest(row.checkpoint, change)
            draft.replacesRecordId?.let { store.discard(store.get(it, owner, row.checkpoint.userId)) }
            store.begin(row)
            mutable.update { it.copy(draft = null, page = SynologyPhotoRequestPage.RECORDS) }
            execute(row, change)
        }
    }
    fun createAlbum(): Job? {
        val name = state.value.newAlbumName.trim()
        if (!canCreateAlbum || name.isEmpty() || !canOpen() || state.value.pendingAlbum != null) return null
        val id = UUID.randomUUID().toString()
        return perform(id, createsAlbum = true) {
            val row = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId,
                userId = repository.photoEditIdentity(), operationId = id, action = SynologyPhotoAlbumAction.CREATE, name = name))
            store.begin(row); mutable.update { it.copy(pendingAlbum = row) }; execute(row)
        }
    }
    fun reviewAlbum(): Job? {
        val row = state.value.pendingAlbum ?: return null
        if (!canOpen()) return null
        return perform(row.id, createsAlbum = true) { execute(store.get(row.id, owner, row.checkpoint.userId)) }
    }
    fun showRecords() {
        if (state.value.working) return
        reset(); mutable.value = SynologyPhotoRequestState(visible = true, page = SynologyPhotoRequestPage.RECORDS)
        refreshRecords()
    }
    fun resume(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!canOpen()) return null
        if (!row.checkpoint.submitted) return reopen(row)
        if (row.checkpoint.finished) return null
        return perform(id, createsAlbum = false) { execute(store.get(id, owner, row.checkpoint.userId)) }
    }
    fun reopen(row: SynologyPhotoAlbumRecord): Job? {
        if (!canOpen() || row !in state.value.records || row.checkpoint.submitted && !row.checkpoint.finished) return null
        val token = generation; mutable.update { it.copy(loading = true, error = null, result = null) }
        loader = scope.launch {
            try {
                requireCurrent(); val original = repository.restoredPhotoRequest(row.checkpoint); check(token)
                if (original == null && (row.checkpoint.action != SynologyPhotoAlbumAction.CREATE_REQUEST || row.checkpoint.submitted)) changed()
                val settings = original?.settings ?: SynologyPhotoRequestSettings(space = row.checkpoint.request!!.space)
                mutable.update { it.copy(page = SynologyPhotoRequestPage.FORM, draft = SynologyPhotoRequestDraft(original = original, settings = settings,
                    deleting = row.checkpoint.action == SynologyPhotoAlbumAction.DELETE_REQUEST,
                    usesDefaultFolder = original == null && canUseDefaultRequestFolder(access(), settings.space), limitsSize = settings.sizeLimit > 0,
                    sizeMiB = if (settings.sizeLimit > 0) maxOf(1, settings.sizeLimit / 1_048_576).toString() else "25",
                    replacesRecordId = row.id.takeUnless { row.checkpoint.submitted })) }
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loading = false) } }
        }
        return loader
    }
    private fun perform(id: String, createsAlbum: Boolean, operation: suspend () -> SynologyPhotoAlbumCheckpoint): Job {
        val token = generation; mutable.update { it.copy(working = true, activeId = id, error = null, result = null) }
        worker = scope.launch {
            try {
                val result = withContext(Dispatchers.IO) { store.exclusive(owner, id) { requireCurrent(); beforeWrite(); operation() } }
                check(token)
                if (createsAlbum) {
                    val saved = withContext(Dispatchers.IO) { store.get(id, owner, result.userId) }
                    mutable.update { it.copy(pendingAlbum = saved) }
                    if (result.phase == SynologyPhotoAlbumPhase.COMPLETED) {
                        val album = SynologyPhotoRequestAlbum(albumId = result.createdAlbumId!!, name = result.name!!, shared = false)
                        mutable.update { it.copy(page = SynologyPhotoRequestPage.FORM, pendingAlbum = null, newAlbumName = "", albums = it.albums.filterNot { old -> old.albumId == album.albumId } + album,
                            draft = it.draft?.copy(settings = it.draft.settings.copy(albumId = album.albumId, albumPassphrase = null))) }
                    }
                } else if (result.finished && result.action != SynologyPhotoAlbumAction.DELETE_REQUEST) {
                    val actual = repository.restoredPhotoRequest(result); check(token); mutable.update { it.copy(result = actual) }
                }
            } catch (error: Exception) { present(error, token) }
            finally {
                if (current(token)) {
                    try { withContext(NonCancellable) { reload(token) } } catch (error: Exception) { present(error, token) }
                    if (current(token)) { mutable.update { it.copy(working = false) }; onCompleted() }
                }
            }
        }
        return worker!!
    }
    private suspend fun execute(row: SynologyPhotoAlbumRecord, change: SynologyPhotoRequestChange? = null): SynologyPhotoAlbumCheckpoint {
        requireCurrent(); if (repository.photoEditIdentity() != row.checkpoint.userId) denied()
        store.requireNoConflict(row)
        fun save(next: SynologyPhotoAlbumCheckpoint) {
            requireCurrent(); store.save(row.id, owner, row.checkpoint.userId, next)
            if (next.action.isRequest) mutable.update { it.copy(records = listOf(row.copy(checkpoint = next)) + it.records.filterNot { old -> old.id == row.id }) }
            else mutable.update { it.copy(pendingAlbum = row.copy(checkpoint = next)) }
        }
        return if (row.checkpoint.submitted) repository.reviewPhotoAlbum(row.checkpoint, ::save)
            else if (row.checkpoint.action.isRequest) repository.performPhotoRequest(row.checkpoint, change ?: changed(), ::save)
            else repository.performPhotoAlbum(row.checkpoint, ::save)
    }
    fun refreshRecords(): Job? {
        if (state.value.working || recordLoader?.isActive == true) return null
        val token = generation
        recordLoader = scope.launch { try { reload(token) } catch (error: Exception) { present(error, token) } }
        return recordLoader
    }
    private suspend fun reload(token: Long) {
        requireCurrent(); val rows = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()).filter { it.checkpoint.action.isRequest } }
        if (current(token)) mutable.update { it.copy(records = rows) }
    }
    fun discard(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (state.value.working) return null
        val token = generation
        return scope.launch { try { withContext(Dispatchers.IO) { requireCurrent(); store.discard(row) }; reload(token) } catch (error: Exception) { present(error, token) } }
    }
    fun dismiss() { if (state.value.working) { mutable.update { it.copy(visible = false) }; return }; reset(); mutable.value = SynologyPhotoRequestState() }
    private fun resetFolders() { folderGeneration++; folderLoader?.cancel(); mutable.update { it.copy(folders = emptyList(), folderPath = emptyList(), foldersLoading = false, moreFolders = false, folderError = null) } }
    private fun reset() { generation++; loader?.cancel(); albumLoader?.cancel(); recordLoader?.cancel(); resetFolders(); openId = null; shortcutFolder = null; shortcutAlbum = null }
    private fun canOpen() = job.isActive && canStart() && spaces.isNotEmpty() && !state.value.working
    private fun current(token: Long) = token == generation && job.isActive
    private fun check(token: Long) { requireCurrent(); if (!current(token)) throw CancellationException() }
    private fun present(error: Exception, token: Long) { if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) } }
    fun revokeAccess() { reset(); worker?.cancel(); mutable.value = SynologyPhotoRequestState() }
    override fun close() { revokeAccess(); job.cancel() }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}

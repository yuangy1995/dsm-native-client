package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoFolderCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoFolderDraft(
    val action: SynologyPhotoAlbumAction, val access: SynologyPhotoFolderAccess,
    val name: String = "", val sort: SynologyPhotoSort = access.sort, val photo: SynologyPhoto? = null,
    val id: String = UUID.randomUUID().toString(), val replaces: String? = null,
)
internal data class SynologyPhotoFolderState(
    val visible: Boolean = false, val recordsPage: Boolean = false, val draft: SynologyPhotoFolderDraft? = null,
    val loading: Boolean = false, val working: Boolean = false, val error: Throwable? = null,
    val path: List<SynologyPhotoCollection> = emptyList(), val children: List<SynologyPhotoCollection> = emptyList(),
    val photos: List<SynologyPhoto> = emptyList(), val moreFolders: Boolean = false, val morePhotos: Boolean = false,
    val browsing: Boolean = false, val browseError: Throwable? = null,
    val records: List<SynologyPhotoAlbumRecord> = emptyList(), val activeId: String? = null,
)

/** 目录表单固定原目标，封面浏览独立前进；关闭表单不抹掉已提交事实。 */
internal class SynologyPhotoFolderModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit, private val canStart: () -> Boolean,
    private val beforeWrite: suspend (SynologyPhotoAlbumCheckpoint) -> Unit = {},
    private val onCompleted: (SynologyPhotoAlbumCheckpoint?, SynologyPhotoFolderAccess?) -> Unit,
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoFolderState())
    val state = mutable.asStateFlow()
    private var generation = 0L; private var browseGeneration = 0L
    private var loader: Job? = null; private var browser: Job? = null; private var worker: Job? = null; private var recordLoader: Job? = null
    private var target: SynologyPhotoCollection? = null
    private var action: SynologyPhotoAlbumAction? = null
    private var reopening: SynologyPhotoAlbumRecord? = null

    fun open(action: SynologyPhotoAlbumAction, target: SynologyPhotoCollection) {
        if (!action.isFolder || !canOpen()) return
        reset(); this.action = action; this.target = target
        mutable.value = SynologyPhotoFolderState(visible = true)
        load()
    }
    fun load(): Job? {
        val target = target ?: return null; val action = action ?: return null
        if (state.value.working || state.value.loading || !state.value.visible) return null
        val token = generation; val previous = reopening
        mutable.update { it.copy(loading = true, error = null, draft = null) }
        loader = scope.launch {
            try {
                requireCurrent()
                val actual = repository.folderAccess(target.space, target.id)
                if (target.path != null && target.path != actual.folder.path || target.parentId != null && target.parentId != actual.folder.parentId) changed()
                if (!allows(action, actual)) denied()
                check(token)
                val old = previous?.checkpoint?.folder
                mutable.update { it.copy(draft = SynologyPhotoFolderDraft(action, actual,
                    name = old?.name ?: actual.folder.name.takeIf { action == SynologyPhotoAlbumAction.RENAME_FOLDER }.orEmpty(),
                    sort = old?.sort ?: actual.sort, replaces = previous?.id)) }
                if (action == SynologyPhotoAlbumAction.COVER_FOLDER) browse(listOf(actual.collection()))
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loading = false) } }
        }
        return loader
    }
    private fun edit(change: (SynologyPhotoFolderDraft) -> SynologyPhotoFolderDraft) {
        if (!state.value.working && !state.value.loading) mutable.update { it.copy(draft = it.draft?.let(change), error = null) }
    }
    fun name(value: String) = edit { it.copy(name = value) }
    fun sort(value: SynologyPhotoSort) = edit { it.copy(sort = value) }
    fun select(photo: SynologyPhoto) {
        if (photo in state.value.photos && !state.value.browsing && state.value.browseError == null) edit { it.copy(photo = photo) }
    }
    val canSave: Boolean get() {
        val draft = state.value.draft ?: return false
        if (!canOpen() || state.value.loading || state.value.browsing) return false
        return when (draft.action) {
            SynologyPhotoAlbumAction.CREATE_FOLDER -> SynologyPhotoFolderCodec.validName(draft.name.trim())
            SynologyPhotoAlbumAction.RENAME_FOLDER -> SynologyPhotoFolderCodec.validName(draft.name.trim()) && draft.name.trim() != draft.access.folder.name
            SynologyPhotoAlbumAction.SORT_FOLDER -> draft.sort != draft.access.sort
            SynologyPhotoAlbumAction.COVER_FOLDER -> draft.photo != null
            else -> false
        }
    }
    fun browse(path: List<SynologyPhotoCollection> = state.value.path, more: Boolean = false): Job? {
        val draft = state.value.draft ?: return null
        if (state.value.working || state.value.browsing || draft.action != SynologyPhotoAlbumAction.COVER_FOLDER || path.isEmpty()) return null
        val folder = path.last()
        if (folder.space != draft.access.folder.space || !SynologyPhotoFolderCodec.contains(draft.access.folder.path, folder.path ?: "")) return null
        if (path.first().id != draft.access.folder.id || path.size > 1 && path.dropLast(1) != state.value.path.take(path.size - 1)) return null
        val token = generation; val browsing = ++browseGeneration
        val previous = state.value
        val folderOffset = if (more) previous.children.size else 0; val photoOffset = if (more) previous.photos.size else 0
        mutable.update { it.copy(path = path, browsing = true, browseError = null,
            children = if (more) it.children else emptyList(), photos = if (more) it.photos else emptyList(),
            moreFolders = more && it.moreFolders, morePhotos = more && it.morePhotos) }
        browser = scope.launch {
            try {
                requireCurrent()
                val actual = repository.folderAccess(folder.space, folder.id)
                if (actual.folder.path != folder.path) changed()
                check(token)
                if (browsing != browseGeneration) return@launch
                mutable.update { it.copy(path = path.dropLast(1) + actual.collection()) }
                // 分页分别保留原游标；某一类读取失败不会把另一类已有结果重复追加。
                if (!more || previous.moreFolders) {
                    val children = repository.folders(folder.space, folder.id, folderOffset, 100, actual.sort.direction)
                    if (children.size > 100 || children.any { it.space != folder.space || it.parentId != folder.id } ||
                        (state.value.children + children).map { it.id }.distinct().size != folderOffset + children.size) changed()
                    check(token); if (browsing != browseGeneration) return@launch
                    mutable.update { it.copy(children = it.children + children, moreFolders = children.size == 100) }
                }
                if (!more || previous.morePhotos) {
                    val page = repository.photos(folder.space, SynologyPhotoQuery.Folder(folder.id, actual.sort), photoOffset, 100)
                    if (page.offset != photoOffset || page.nextOffset != photoOffset + page.items.size || page.items.size > 100 || page.hasMore && page.items.isEmpty() ||
                        page.items.any { it.id.profileId != owner.profileId || it.id.space != folder.space || it.albumContext != null || it.folderId != folder.id } ||
                        (state.value.photos + page.items).map { it.id }.distinct().size != photoOffset + page.items.size) changed()
                    check(token); if (browsing != browseGeneration) return@launch
                    mutable.update { it.copy(photos = it.photos + page.items, morePhotos = page.hasMore) }
                }
            } catch (error: Exception) {
                if (error !is CancellationException && current(token) && browsing == browseGeneration) mutable.update { it.copy(browseError = error) }
            } finally { if (current(token) && browsing == browseGeneration) mutable.update { it.copy(browsing = false) } }
        }
        return browser
    }
    fun enter(folder: SynologyPhotoCollection) { if (folder in state.value.children) browse(state.value.path + folder) }
    fun backTo(index: Int) { if (index in 0 until state.value.path.lastIndex) browse(state.value.path.take(index + 1)) }
    fun save(): Job? {
        val draft = state.value.draft ?: return null; if (!canSave) return null
        return perform(draft.id) {
            val operation = SynologyPhotoFolderCheckpoint(draft.access.folder,
                name = draft.name.trim().takeIf { draft.action in setOf(SynologyPhotoAlbumAction.CREATE_FOLDER, SynologyPhotoAlbumAction.RENAME_FOLDER) },
                sort = draft.sort.takeIf { draft.action == SynologyPhotoAlbumAction.SORT_FOLDER },
                coverPhoto = draft.photo?.let(::SynologyPhotoEditTarget).takeIf { draft.action == SynologyPhotoAlbumAction.COVER_FOLDER })
            val row = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId,
                userId = repository.photoEditIdentity(), operationId = draft.id, action = draft.action, folder = operation))
            beforeWrite(row.checkpoint); repository.preparePhotoAlbum(row.checkpoint)
            draft.replaces?.let { store.discard(store.get(it, owner, row.checkpoint.userId)) }
            store.begin(row)
            mutable.update { it.copy(draft = null, recordsPage = true) }
            execute(row)
        }
    }
    fun showRecords() {
        if (state.value.working) return
        reset(); mutable.value = SynologyPhotoFolderState(visible = true, recordsPage = true)
        refreshRecords()
    }
    fun resume(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!canOpen() || row.checkpoint.finished) return null
        if (!row.checkpoint.submitted) {
            reset(); action = row.checkpoint.action; target = row.checkpoint.folder!!.target.collection(); reopening = row
            mutable.value = SynologyPhotoFolderState(visible = true)
            return load()
        }
        return perform(id) { execute(store.get(id, owner, row.checkpoint.userId)) }
    }
    private fun perform(id: String, operation: suspend () -> SynologyPhotoAlbumCheckpoint): Job {
        val token = generation; mutable.update { it.copy(working = true, activeId = id, error = null) }
        worker = scope.launch {
            var result: SynologyPhotoAlbumCheckpoint? = null; var actual: SynologyPhotoFolderAccess? = null
            try {
                result = withContext(Dispatchers.IO) { store.exclusive(owner, id) { requireCurrent(); operation() } }
                check(token)
                if (result.finished) {
                    val folder = result.folder!!
                    actual = repository.folderAccess(folder.target.space, folder.createdFolderId ?: folder.target.id)
                    if (result.action == SynologyPhotoAlbumAction.COVER_FOLDER) actual = actual.copy(covers = actual.covers.map {
                        if (it.sequence != null) it.copy(revision = UUID.randomUUID().toString()) else it
                    })
                    check(token)
                }
            } catch (error: Exception) { present(error, token) }
            finally {
                if (current(token)) {
                    try { withContext(NonCancellable) { reload(token) } } catch (error: Exception) { present(error, token) }
                    if (current(token)) { mutable.update { it.copy(working = false) }; onCompleted(result, actual) }
                }
            }
        }
        return worker!!
    }
    private suspend fun execute(row: SynologyPhotoAlbumRecord): SynologyPhotoAlbumCheckpoint {
        requireCurrent(); if (repository.photoEditIdentity() != row.checkpoint.userId) denied()
        store.requireNoConflict(row)
        fun save(next: SynologyPhotoAlbumCheckpoint) {
            requireCurrent(); store.save(row.id, owner, row.checkpoint.userId, next)
            mutable.update { it.copy(records = listOf(row.copy(checkpoint = next)) + it.records.filterNot { old -> old.id == row.id }) }
        }
        return if (row.checkpoint.submitted) repository.reviewPhotoAlbum(row.checkpoint, ::save) else repository.performPhotoAlbum(row.checkpoint, ::save)
    }
    suspend fun requireNoPending() {
        if (state.value.working) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
        requireCurrent()
        if (withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()) }.any { it.checkpoint.action.isFolder && it.checkpoint.submitted && !it.checkpoint.finished })
            throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    }
    fun refreshRecords(): Job? {
        if (state.value.working || recordLoader?.isActive == true) return null
        val token = generation
        recordLoader = scope.launch { try { reload(token) } catch (error: Exception) { present(error, token) } }
        return recordLoader
    }
    private suspend fun reload(token: Long) {
        requireCurrent(); val rows = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()).filter { it.checkpoint.action.isFolder } }
        if (current(token)) mutable.update { it.copy(records = rows) }
    }
    fun discard(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (state.value.working) return null
        val token = generation
        return scope.launch { try { withContext(Dispatchers.IO) { requireCurrent(); store.discard(row) }; reload(token) } catch (error: Exception) { present(error, token) } }
    }
    fun dismiss() { if (state.value.working) { mutable.update { it.copy(visible = false) }; return }; reset(); mutable.value = SynologyPhotoFolderState() }
    private fun reset() { generation++; browseGeneration++; loader?.cancel(); browser?.cancel(); recordLoader?.cancel(); target = null; action = null; reopening = null }
    private fun canOpen() = job.isActive && canStart() && !state.value.working
    private fun current(token: Long) = token == generation && job.isActive
    private fun check(token: Long) { requireCurrent(); if (!current(token)) throw CancellationException() }
    private fun present(error: Exception, token: Long) { if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) } }
    fun revokeAccess() { reset(); worker?.cancel(); mutable.value = SynologyPhotoFolderState() }
    override fun close() { revokeAccess(); job.cancel() }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
    companion object {
        fun allows(action: SynologyPhotoAlbumAction, access: SynologyPhotoFolderAccess) = when (action) {
            SynologyPhotoAlbumAction.CREATE_FOLDER -> access.canCreate
            SynologyPhotoAlbumAction.SORT_FOLDER -> true
            SynologyPhotoAlbumAction.RENAME_FOLDER, SynologyPhotoAlbumAction.COVER_FOLDER -> access.canManage && access.folder.path != "/"
            else -> false
        }
    }
}

internal fun SynologyPhotoFolderAccess.collection() = folder.collection().copy(sort = sort, folderCovers = covers)

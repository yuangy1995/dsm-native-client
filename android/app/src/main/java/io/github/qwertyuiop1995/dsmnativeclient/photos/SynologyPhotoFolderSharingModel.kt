package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoFolderSharingCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoFolderSharingState(
    val visible: Boolean = false, val recordsPage: Boolean = false,
    val original: SynologyPhotoFolderSharing? = null,
    val access: SynologyPhotoFolderLinkAccess = SynologyPhotoFolderLinkAccess.MANAGEMENT,
    val members: List<SynologyPhotoShareGrant>? = null, val names: Map<SynologyPhotoShareMemberId, String> = emptyMap(),
    val passwordMode: SynologyPhotoSharingPassword = SynologyPhotoSharingPassword.UNCHANGED, val password: String = "",
    val appliesToSubfolders: Boolean = false, val confirmation: SynologyPhotoFolderSharingChange? = null,
    val loading: Boolean = false, val working: Boolean = false, val error: Throwable? = null,
    val selectingMembers: Boolean = false, val candidates: List<SynologyPhotoShareRecipient>? = null,
    val membersLoading: Boolean = false, val membersError: Throwable? = null, val search: String = "",
    val records: List<SynologyPhotoAlbumRecord> = emptyList(), val activeId: String? = null,
) {
    val change: SynologyPhotoFolderSharingChange? get() = original?.let {
        SynologyPhotoFolderSharingChange(it.snapshot, access, members, passwordMode, appliesToSubfolders)
    }
    val canEdit: Boolean get() = original != null && original.snapshot.inheritsManagementOnly.not() && !working && !loading && confirmation == null
    override fun toString() = "PhotoFolderSharingState"
}

/** 密码仅留当前表单内存；确认固定变更，未知提交只读恢复。 */
internal class SynologyPhotoFolderSharingModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit, private val sourceAccess: () -> SynologyPhotoAccess?,
    private val canStart: () -> Boolean, private val beforeWrite: suspend () -> Unit = {},
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoFolderSharingState())
    val state = mutable.asStateFlow()
    private var generation = 0L
    private var loader: Job? = null; private var memberLoader: Job? = null; private var worker: Job? = null; private var recordLoader: Job? = null
    private var target: SynologyPhotoFolderSnapshot? = null
    private var reopening: SynologyPhotoAlbumRecord? = null
    private var operationId = UUID.randomUUID().toString()

    fun canOpen(folder: SynologyPhotoCollection): Boolean = allowed() && folder.path?.let { path ->
        SynologyPhotoFolderSharingCodec.eligible(SynologyPhotoFolderSnapshot(folder.id, folder.parentId, folder.name, path, folder.space))
    } == true
    private fun allowed() = job.isActive && sourceAccess()?.canManageSharedSpace == true && canStart() && !state.value.working
    fun open(folder: SynologyPhotoCollection) {
        if (!canOpen(folder)) return
        reset(); target = SynologyPhotoFolderSnapshot(folder.id, folder.parentId, folder.name, folder.path!!, folder.space)
        mutable.value = SynologyPhotoFolderSharingState(visible = true); load()
    }
    fun load(): Job? {
        val target = target ?: return null
        if (!state.value.visible || state.value.working || state.value.loading) return null
        val token = generation; val restored = reopening?.checkpoint?.folderSharing?.change
        memberLoader?.cancel()
        mutable.update { SynologyPhotoFolderSharingState(visible = true, loading = true, records = it.records) }
        loader = scope.launch {
            try {
                requireCurrent(); val actual = repository.folderSharing(target); check(token)
                if (restored != null && restored.original != actual.snapshot) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
                mutable.update { it.copy(original = actual, access = restored?.access ?: actual.snapshot.access,
                    members = restored?.members ?: actual.snapshot.members, names = actual.recipients.associate { member -> member.id to member.name },
                    passwordMode = restored?.password ?: SynologyPhotoSharingPassword.UNCHANGED,
                    appliesToSubfolders = restored?.appliesToSubfolders ?: actual.snapshot.appliesToSubfolders) }
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loading = false) } }
        }
        return loader
    }
    private fun edit(change: (SynologyPhotoFolderSharingState) -> SynologyPhotoFolderSharingState) {
        if (allowed() && state.value.canEdit) mutable.update { change(it).copy(error = null) }
    }
    fun access(value: SynologyPhotoFolderLinkAccess) = edit { it.copy(access = value) }
    fun passwordMode(value: SynologyPhotoSharingPassword) = edit { it.copy(passwordMode = value, password = "") }
    fun password(value: String) = edit { if (it.passwordMode == SynologyPhotoSharingPassword.SET) it.copy(password = value) else it }
    fun applyToSubfolders(value: Boolean) = edit { if (it.original?.snapshot?.depth == 1) it.copy(appliesToSubfolders = value) else it }
    fun role(id: SynologyPhotoShareMemberId, value: String) = edit {
        if (value in roles) it.copy(members = it.members?.map { grant -> if (grant.id == id) grant.copy(role = value) else grant }) else it
    }
    fun remove(id: SynologyPhotoShareMemberId) = edit { it.copy(members = it.members?.filterNot { grant -> grant.id == id }) }
    fun add(recipient: SynologyPhotoShareRecipient) = edit { old ->
        if (old.members == null || recipient !in old.candidates.orEmpty() || old.members.any { it.id == recipient.id }) old
        else old.copy(members = old.members + SynologyPhotoShareGrant(recipient.id, "view"), names = old.names + (recipient.id to recipient.name))
    }
    fun search(value: String) = edit { it.copy(search = value) }
    fun closeMembers() { mutable.update { it.copy(selectingMembers = false) } }
    fun selectMembers(): Job? {
        if (!allowed() || !state.value.canEdit || state.value.members == null) return null
        mutable.update { it.copy(selectingMembers = true) }
        if (state.value.membersLoading || state.value.candidates != null) return null
        val token = generation; mutable.update { it.copy(membersLoading = true, membersError = null) }
        memberLoader = scope.launch {
            try { requireCurrent(); val values = repository.folderSharingRecipients(); check(token); mutable.update { it.copy(candidates = values) } }
            catch (error: Exception) { if (error !is CancellationException && current(token)) mutable.update { it.copy(membersError = error) } }
            finally { if (current(token)) mutable.update { it.copy(membersLoading = false) } }
        }
        return memberLoader
    }
    val canSave: Boolean get() = allowed() && state.value.canEdit && state.value.change?.let {
        it.hasChanges && runCatching { SynologyPhotoFolderSharingCodec.validate(it) }.isSuccess &&
            (it.password != SynologyPhotoSharingPassword.SET || state.value.password.isNotEmpty())
    } == true
    fun save(): Job? {
        if (!canSave) return null
        val change = state.value.change!!
        if (change.needsConfirmation) { mutable.update { it.copy(confirmation = change) }; return null }
        return submit(change)
    }
    fun cancelConfirmation() { mutable.update { it.copy(confirmation = null) } }
    fun confirm(): Job? {
        val change = state.value.confirmation ?: return null
        if (!allowed() || change != state.value.change) return null
        return submit(change)
    }
    private fun submit(change: SynologyPhotoFolderSharingChange): Job {
        val password = state.value.password.takeIf { change.password == SynologyPhotoSharingPassword.SET }
        mutable.update { it.copy(confirmation = null) }
        return perform(operationId) {
            val row = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId,
                userId = repository.photoEditIdentity(), operationId = operationId, action = SynologyPhotoAlbumAction.SHARE_FOLDER,
                folderSharing = SynologyPhotoFolderSharingCheckpoint(change)))
            beforeWrite(); repository.preparePhotoAlbum(row.checkpoint)
            reopening?.let { store.discard(store.get(it.id, owner, row.checkpoint.userId)) }
            store.begin(row)
            mutable.update { it.copy(original = null, members = null, names = emptyMap(), candidates = null, password = "", recordsPage = true) }
            execute(row, password)
        }
    }
    fun showRecords() {
        if (state.value.working) return
        reset(); mutable.value = SynologyPhotoFolderSharingState(visible = true, recordsPage = true); refreshRecords()
    }
    fun resume(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!allowed() || row.checkpoint.finished) return null
        if (!row.checkpoint.submitted) {
            reset(); target = row.checkpoint.folderSharing!!.change.original.folder; reopening = row
            mutable.value = SynologyPhotoFolderSharingState(visible = true); return load()
        }
        return perform(id) { execute(store.get(id, owner, row.checkpoint.userId), null) }
    }
    private fun perform(id: String, operation: suspend () -> SynologyPhotoAlbumCheckpoint): Job {
        val token = generation; mutable.update { it.copy(working = true, activeId = id, error = null) }
        worker = scope.launch {
            try { withContext(Dispatchers.IO) { store.exclusive(owner, id) { requireCurrent(); operation() } } }
            catch (error: Exception) { present(error, token) }
            finally {
                if (current(token)) {
                    try { withContext(NonCancellable) { reload(token) } } catch (error: Exception) { present(error, token) }
                    if (current(token)) mutable.update { it.copy(working = false, password = "") }
                }
            }
        }
        return worker!!
    }
    private suspend fun execute(row: SynologyPhotoAlbumRecord, password: String?): SynologyPhotoAlbumCheckpoint {
        requireCurrent(); if (repository.photoEditIdentity() != row.checkpoint.userId) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        store.requireNoConflict(row)
        val token = generation
        fun save(next: SynologyPhotoAlbumCheckpoint) {
            requireCurrent(); val saved = store.save(row.id, owner, row.checkpoint.userId, next)
            if (current(token)) mutable.update { it.copy(records = listOf(saved) + it.records.filterNot { old -> old.id == row.id }) }
        }
        return if (row.checkpoint.submitted) repository.reviewPhotoAlbum(row.checkpoint, ::save)
            else repository.performPhotoFolderSharing(row.checkpoint, password, ::save)
    }
    suspend fun requireNoPending() {
        if (state.value.working) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
        requireCurrent()
        if (withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()) }.any {
            it.checkpoint.action == SynologyPhotoAlbumAction.SHARE_FOLDER && it.checkpoint.submitted && !it.checkpoint.finished
        }) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    }
    fun refreshRecords(): Job? {
        if (state.value.working || recordLoader?.isActive == true) return null
        val token = generation
        recordLoader = scope.launch { try { reload(token) } catch (error: Exception) { present(error, token) } }
        return recordLoader
    }
    private suspend fun reload(token: Long) {
        requireCurrent(); val rows = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()).filter { it.checkpoint.action == SynologyPhotoAlbumAction.SHARE_FOLDER } }
        if (current(token)) mutable.update { it.copy(records = rows) }
    }
    fun discard(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (state.value.working) return null
        val token = generation
        return scope.launch { try { withContext(Dispatchers.IO) { requireCurrent(); store.discard(row) }; reload(token) } catch (error: Exception) { present(error, token) } }
    }
    fun dismiss() {
        if (state.value.working) { mutable.update { it.copy(visible = false, password = "") }; return }
        reset(); mutable.value = SynologyPhotoFolderSharingState()
    }
    private fun reset() { generation++; loader?.cancel(); memberLoader?.cancel(); recordLoader?.cancel(); target = null; reopening = null; operationId = UUID.randomUUID().toString() }
    private fun current(token: Long) = token == generation && job.isActive
    private fun check(token: Long) { requireCurrent(); if (!current(token)) throw CancellationException() }
    private fun present(error: Exception, token: Long) { if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) } }
    fun revokeAccess() { reset(); worker?.cancel(); mutable.value = SynologyPhotoFolderSharingState() }
    override fun close() { revokeAccess(); job.cancel() }
    companion object { val roles = listOf("view", "download", "upload", "manage") }
}

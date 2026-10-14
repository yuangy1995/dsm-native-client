package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoSharedMembersCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.Closeable
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoMemberDirectoryDraft(
    val member: SynologyPhotoSharedMember, val folders: List<SynologyPhotoMemberFolder> = emptyList(),
    val edit: SynologyPhotoMemberFolderEdit? = null, val loading: Boolean = false, val error: Throwable? = null,
    val expanded: Set<Long> = emptySet(), val keyword: String = "", val childrenCleared: Boolean = false,
)
internal data class SynologyPhotoSharedMembersState(
    val visible: Boolean = false, val loading: Boolean = false, val working: Boolean = false,
    val original: SynologyPhotoSharedMembersSnapshot? = null, val members: List<SynologyPhotoSharedMember> = emptyList(),
    val names: Map<SynologyPhotoShareMemberId, String> = emptyMap(),
    val folderEdits: List<SynologyPhotoMemberFolderEdit> = emptyList(), val folderNames: Map<SynologyPhotoShareMemberId, List<SynologyPhotoMemberFolder>> = emptyMap(),
    val keyword: String = "", val adding: Boolean = false, val candidates: List<SynologyPhotoShareRecipient> = emptyList(),
    val candidatesLoading: Boolean = false, val candidatesError: Throwable? = null,
    val directory: SynologyPhotoMemberDirectoryDraft? = null, val confirmation: SynologyPhotoSharedMembersCheckpoint? = null,
    val recordsPage: Boolean = false, val records: List<SynologyPhotoAlbumRecord> = emptyList(), val activeId: String? = null,
    val error: Throwable? = null,
) {
    val canEdit: Boolean get() = original?.enabled == true && !loading && !working && confirmation == null
    val change: SynologyPhotoSharedMembersCheckpoint? get() = original?.let { SynologyPhotoSharedMembersCheckpoint(it, members.map { member -> member.grant }, folderEdits) }
}

/** 名单、角色和目录只编辑本地草稿，最终确认才进入现有管理通道。 */
internal class SynologyPhotoSharedMembersModel(
    private val repository: SynologyPhotosServing, parent: CoroutineScope,
    private val store: SynologyPhotoAlbumStore, private val owner: WorkspaceOwner,
    private val requireCurrent: () -> Unit, private val canStart: () -> Boolean,
    private val beforeWrite: suspend () -> Unit, private val onApplied: suspend (SynologyPhotoSharedSettings) -> Unit,
    private val pause: suspend (Long) -> Unit = { delay(it) },
    private val onChanging: suspend () -> Unit = {}, private val onReadFailed: (Throwable) -> Unit = {},
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job]); private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotoSharedMembersState()); val state = mutable.asStateFlow()
    private var generation = 0L; private var viewGeneration = 0L; private var active = false
    private var candidateGeneration = 0L; private var folderGeneration = 0L
    private var loader: Job? = null; private var candidatesLoader: Job? = null; private var folderLoader: Job? = null
    private var worker: Job? = null; private var recordLoader: Job? = null; private var poller: Job? = null
    private var reopening: SynologyPhotoAlbumRecord? = null; private var operationId = UUID.randomUUID().toString()
    val available: Boolean get() = repository.canManageSharedMembers
    private fun allowed() = available && job.isActive && canStart() && !state.value.working
    fun open() { if (allowed()) { reset(); mutable.value = SynologyPhotoSharedMembersState(visible = true); load() } }
    fun load(): Job? {
        if (!state.value.visible || state.value.working || state.value.loading) return null
        val token = generation; val view = viewGeneration
        mutable.update { it.copy(loading = true, original = null, members = emptyList(), folderEdits = emptyList(), folderNames = emptyMap(), error = null) }
        loader = scope.launch {
            try {
                requireCurrent(); val value = repository.sharedMembers(); check(token, view)
                // 未提交的记录也从当前名单重开，不能把陈旧权限草稿直接恢复成待写请求。
                mutable.update { it.copy(original = value.snapshot, members = value.members, names = value.members.associate { member -> member.grant.id to member.recipient.name }) }
            } catch (error: Exception) { present(error, token, view) }
            finally { if (current(token, view)) mutable.update { it.copy(loading = false) } }
        }; return loader
    }
    fun keyword(value: String) { mutable.update { it.copy(keyword = value) } }
    fun add() { if (allowed() && state.value.canEdit) { mutable.update { it.copy(adding = true, keyword = "") }; loadCandidates() } }
    fun cancelAdd() { candidateGeneration++; candidatesLoader?.cancel(); mutable.update { it.copy(adding = false, keyword = "", candidatesLoading = false) } }
    fun loadCandidates(): Job? {
        if (!state.value.adding || state.value.candidatesLoading || !allowed()) return null
        val token = generation; val view = viewGeneration; val attempt = ++candidateGeneration; mutable.update { it.copy(candidatesLoading = true, candidatesError = null) }
        candidatesLoader = scope.launch {
            try { requireCurrent(); val values = repository.sharedMemberCandidates(); check(token, view); if (attempt == candidateGeneration) mutable.update { it.copy(candidates = values) } }
            catch (error: Exception) { if (error !is CancellationException && current(token, view) && attempt == candidateGeneration) mutable.update { it.copy(candidatesError = error, candidates = emptyList()) } }
            finally { if (current(token, view) && attempt == candidateGeneration) mutable.update { it.copy(candidatesLoading = false) } }
        }; return candidatesLoader
    }
    fun choose(candidate: SynologyPhotoShareRecipient, role: String) {
        if (!allowed() || !state.value.canEdit || candidate !in state.value.candidates || state.value.members.any { it.grant.id == candidate.id } ||
            candidate.id.type == "group" && candidate.name == "administrators" || role !in setOf("entry", "management")) return
        val member = SynologyPhotoSharedMember(candidate, SynologyPhotoSharedMemberGrant(candidate.id, role, role == "management"))
        if (role == "entry") openFolders(member) else { applyMember(member); cancelAdd() }
    }
    fun role(id: SynologyPhotoShareMemberId, role: String) {
        val member = state.value.members.firstOrNull { it.grant.id == id } ?: return
        if (!allowed() || !state.value.canEdit || !member.grant.canEdit || role !in setOf("entry", "management") || member.grant.role == role) return
        val changed = member.copy(grant = member.grant.changingRole(role))
        if (changed.grant.role == "entry") openFolders(changed) else {
            applyMember(changed); mutable.update { it.copy(folderEdits = it.folderEdits.filterNot { edit -> edit.member == id }, folderNames = it.folderNames - id) }
        }
    }
    fun remove(id: SynologyPhotoShareMemberId) {
        if (!allowed() || !state.value.canEdit || state.value.members.firstOrNull { it.grant.id == id }?.grant?.canEdit != true) return
        mutable.update { it.copy(members = it.members.filterNot { member -> member.grant.id == id }, folderEdits = it.folderEdits.filterNot { edit -> edit.member == id }, folderNames = it.folderNames - id) }
    }
    fun backup(id: SynologyPhotoShareMemberId?, enabled: Boolean) {
        if (!allowed() || !state.value.canEdit) return
        mutable.update { it.copy(members = it.members.map { member ->
            if ((id == null || id == member.grant.id) && member.grant.canEdit && member.grant.role == "entry") member.copy(grant = member.grant.copy(autoBackup = enabled)) else member
        }) }
    }
    fun editFolders(id: SynologyPhotoShareMemberId) { state.value.members.firstOrNull { it.grant.id == id }?.let(::openFolders) }
    private fun openFolders(member: SynologyPhotoSharedMember) {
        if (!allowed() || !state.value.canEdit || !member.grant.canEdit || member.grant.role != "entry") return
        val saved = state.value.folderEdits.firstOrNull { it.member == member.grant.id }
        mutable.update { it.copy(directory = SynologyPhotoMemberDirectoryDraft(member,
            folders = it.folderNames[member.grant.id].orEmpty(), edit = saved)) }
        if (saved == null) loadFolders()
    }
    fun loadFolders(): Job? {
        val draft = state.value.directory ?: return null
        if (!allowed() || draft.loading) return null
        val token = generation; val view = viewGeneration; val attempt = ++folderGeneration
        mutable.update { it.copy(directory = draft.copy(loading = true, error = null)) }
        folderLoader = scope.launch {
            try {
                requireCurrent(); val values = repository.sharedMemberFolders(draft.member.grant.id); check(token, view)
                if (attempt != folderGeneration || state.value.directory?.member != draft.member) return@launch
                mutable.update { it.copy(directory = draft.copy(folders = values, error = null, edit = SynologyPhotoMemberFolderEdit(draft.member.grant.id, values.map { value -> value.snapshot }))) }
            } catch (error: Exception) {
                if (error !is CancellationException && current(token, view) && attempt == folderGeneration && state.value.directory?.member == draft.member)
                    mutable.update { it.copy(directory = draft.copy(error = error)) }
            } finally { if (current(token, view) && attempt == folderGeneration) mutable.update { it.copy(directory = it.directory?.copy(loading = false)) } }
        }; return folderLoader
    }
    fun cancelFolders() { folderGeneration++; folderLoader?.cancel(); mutable.update { it.copy(directory = null) } }
    fun finishFolders() {
        val draft = state.value.directory ?: return; val edit = draft.edit ?: return
        if (!allowed() || !state.value.canEdit || draft.loading || draft.error != null) return
        applyMember(draft.member)
        mutable.update { it.copy(directory = null, adding = false, keyword = "", folderEdits = it.folderEdits.filterNot { old -> old.member == edit.member } +
            if (edit.canSave) listOf(edit) else emptyList(), folderNames = it.folderNames + (edit.member to draft.folders)) }
    }
    fun folderKeyword(value: String) { mutable.update { it.copy(directory = it.directory?.copy(keyword = value)) } }
    fun expand(id: Long) { mutable.update { it.copy(directory = it.directory?.let { draft -> draft.copy(expanded = if (id in draft.expanded) draft.expanded - id else draft.expanded + id) }) } }
    fun folderRole(id: Long, role: SynologyPhotoFolderMemberRole?) {
        val draft = state.value.directory ?: return; val edit = draft.edit ?: return; val folder = edit.original.firstOrNull { it.id == id } ?: return
        if (!allowed() || !state.value.canEdit || !edit.canEdit(folder)) return
        mutable.update { it.copy(directory = draft.copy(edit = edit.withRole(folder, role), childrenCleared = folder.depth == 0 && folder.privacy == "private" && role == null && edit.original.any { child -> child.parentId == id })) }
    }
    fun batch(role: SynologyPhotoFolderMemberRole, grant: Boolean) {
        val draft = state.value.directory ?: return; val edit = draft.edit ?: return
        if (allowed() && state.value.canEdit) mutable.update { it.copy(directory = draft.copy(edit = edit.withBatch(SynologyPhotoMemberFolderBatch(role, grant)), childrenCleared = false)) }
    }
    private fun applyMember(member: SynologyPhotoSharedMember) {
        mutable.update { it.copy(names = it.names + (member.grant.id to member.recipient.name), members = if (it.members.any { old -> old.grant.id == member.grant.id })
            it.members.map { old -> if (old.grant.id == member.grant.id) member else old } else it.members + member) }
    }
    val canSave: Boolean get() = allowed() && state.value.canEdit && state.value.directory == null && state.value.change?.let {
        runCatching { SynologyPhotoSharedMembersCodec.validate(it) }.isSuccess
    } == true
    fun save() { if (canSave) mutable.update { it.copy(confirmation = it.change) } }
    fun cancelConfirmation() { mutable.update { it.copy(confirmation = null) } }
    fun confirm(): Job? {
        val value = state.value.confirmation ?: return null
        if (!allowed() || value != state.value.change) return null
        mutable.update { it.copy(confirmation = null) }
        return perform(operationId) {
            val row = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId,
                userId = repository.photoEditIdentity(), operationId = operationId, action = SynologyPhotoAlbumAction.SHARED_MEMBERS, sharedMembers = value))
            beforeWrite(); repository.preparePhotoAlbum(row.checkpoint)
            reopening?.let { store.discard(store.get(it.id, owner, row.checkpoint.userId)) }; store.begin(row)
            mutable.update { it.copy(recordsPage = true, original = null, members = emptyList(), folderEdits = emptyList(), folderNames = emptyMap()) }
            execute(row)
        }
    }
    fun showRecords() { if (!state.value.working) { reset(); mutable.value = SynologyPhotoSharedMembersState(visible = true, recordsPage = true); refreshRecords(); startPolling() } }
    fun resume(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (!allowed() || row.checkpoint.finished) return null
        if (!row.checkpoint.submitted) { reset(); reopening = row; mutable.value = SynologyPhotoSharedMembersState(visible = true); return load() }
        return perform(id) { execute(store.get(id, owner, row.checkpoint.userId)) }
    }
    private fun perform(id: String, operation: suspend () -> SynologyPhotoAlbumCheckpoint): Job {
        val token = generation; mutable.update { it.copy(working = true, activeId = id, error = null) }
        worker = scope.launch {
            var applied: SynologyPhotoSharedSettings? = null
            try {
                val result = withContext(Dispatchers.IO) { store.exclusive(owner, id) { requireCurrent(); operation() } }
                if (result.submitted) {
                    applied = withContext(Dispatchers.IO) { repository.photoSettings(SynologyPhotoSettingsKind.SHARED) as SynologyPhotoSharedSettings }; check(token)
                }
            } catch (error: Exception) { present(error, token); if (error !is CancellationException && current(token)) onReadFailed(error) }
            finally {
                if (current(token)) {
                    try { withContext(NonCancellable) { reload(token) } } catch (error: Exception) { present(error, token) }
                    if (current(token)) { mutable.update { it.copy(working = false) }; startPolling() }
                }
            }
            if (current(token) && applied != null) try { requireCurrent(); onApplied(applied) } catch (error: Exception) { present(error, token) }
        }; return worker!!
    }
    private suspend fun execute(row: SynologyPhotoAlbumRecord): SynologyPhotoAlbumCheckpoint {
        requireCurrent(); if (repository.photoEditIdentity() != row.checkpoint.userId) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        store.requireNoConflict(row); val token = generation
        withContext(scope.coroutineContext.minusKey(Job)) { check(token); onChanging() }
        fun save(next: SynologyPhotoAlbumCheckpoint) {
            requireCurrent(); val saved = store.save(row.id, owner, row.checkpoint.userId, next)
            if (current(token)) mutable.update { it.copy(records = listOf(saved) + it.records.filterNot { old -> old.id == row.id }) }
        }
        return if (row.checkpoint.submitted) repository.reviewPhotoAlbum(row.checkpoint, ::save) else repository.performPhotoAlbum(row.checkpoint, ::save)
    }
    suspend fun requireNoPending() {
        if (state.value.working) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.BUSY)
        requireCurrent()
        if (withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()) }.any {
            it.checkpoint.action == SynologyPhotoAlbumAction.SHARED_MEMBERS && it.checkpoint.submitted && !it.checkpoint.finished
        }) throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
    }
    fun refreshRecords(): Job? {
        if (state.value.working || recordLoader?.isActive == true) return null
        val token = generation; recordLoader = scope.launch { try { reload(token) } catch (error: Exception) { present(error, token) } }; return recordLoader
    }
    private suspend fun reload(token: Long) {
        requireCurrent(); val rows = withContext(Dispatchers.IO) { store.records(owner, repository.photoEditIdentity()).filter { it.checkpoint.action == SynologyPhotoAlbumAction.SHARED_MEMBERS } }
        check(token); mutable.update { it.copy(records = rows) }
    }
    fun discard(id: String): Job? {
        val row = state.value.records.firstOrNull { it.id == id } ?: return null
        if (state.value.working) return null
        val token = generation; return scope.launch { try { withContext(Dispatchers.IO) { requireCurrent(); store.discard(row) }; reload(token) } catch (error: Exception) { present(error, token) } }
    }
    private fun startPolling() {
        if (!active || !state.value.visible || !state.value.recordsPage || poller?.isActive == true) return
        val token = generation; poller = scope.launch {
            while (isActive && active && current(token) && state.value.visible && state.value.recordsPage) {
                pause(15_000)
                if (!active || !current(token) || state.value.working) continue
                refreshRecords()?.join(); state.value.records.firstOrNull { it.checkpoint.submitted && !it.checkpoint.finished }?.let { resume(it.id)?.join() }
            }
        }
    }
    fun activate() { active = true; if (state.value.visible) {
        if (!state.value.recordsPage && state.value.original == null) load()
        if (state.value.directory?.edit == null) loadFolders()
        if (state.value.adding && state.value.candidates.isEmpty()) loadCandidates()
        startPolling()
    } }
    fun deactivate() {
        active = false; viewGeneration++; loader?.cancel(); candidatesLoader?.cancel(); folderLoader?.cancel(); recordLoader?.cancel(); poller?.cancel(); poller = null
        mutable.update { it.copy(loading = false, candidatesLoading = false, directory = it.directory?.copy(loading = false)) }
    }
    fun dismiss() { if (state.value.directory != null) { cancelFolders(); return }; if (state.value.working) { poller?.cancel(); mutable.update { it.copy(visible = false) }; return }; reset(); mutable.value = SynologyPhotoSharedMembersState() }
    private fun reset() { generation++; val wasActive = active; deactivate(); active = wasActive; reopening = null; operationId = UUID.randomUUID().toString() }
    private fun current(token: Long, view: Long = viewGeneration) = token == generation && view == viewGeneration && job.isActive
    private suspend fun check(token: Long, view: Long = viewGeneration) { currentCoroutineContext().ensureActive(); requireCurrent(); if (!current(token, view)) throw CancellationException() }
    private fun present(error: Exception, token: Long, view: Long = viewGeneration) { if (error !is CancellationException && current(token, view)) mutable.update { it.copy(error = error) } }
    fun revokeAccess() { reset(); worker?.cancel(); mutable.value = SynologyPhotoSharedMembersState() }
    override fun close() { revokeAccess(); job.cancel() }
}

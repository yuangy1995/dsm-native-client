package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.FilePermissionOutcome
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal enum class FilePermissionMemberPurpose { RULE, OWNER, GROUP }
internal data class FilePermissionDraft(
    val rules: List<FileACLRule> = emptyList(), val posixMode: String = "",
    val owner: FileSharePrincipal? = null, val group: FileSharePrincipal? = null, val recursive: Boolean = false,
)
internal data class FilePermissionState(
    val path: String? = null, val account: String = "", val snapshot: Loadable<FilePermissionSnapshot> = Loadable.Idle,
    val draft: FilePermissionDraft = FilePermissionDraft(), val busy: Boolean = false, val submitted: Boolean = false,
    val confirmation: Boolean = false, val pending: Boolean = false, val recoveryReadable: Boolean = false,
    val relatedPendingPath: String? = null,
    val outcome: FilePermissionOutcome? = null, val failure: DsmFailure? = null,
    val memberPurpose: FilePermissionMemberPurpose? = null, val memberQuery: String = "", val memberResultQuery: String = "",
    val members: Loadable<FileSharePrincipalPage> = Loadable.Idle, val membersLoadingMore: Boolean = false,
    val membersMoreFailure: DsmFailure? = null,
)

/** 独立工作区草稿；权限变化撤销旧确认，后台提交保留原仓储及只读恢复日志。 */
internal class FilePermissionFeatureModel(
    private val scope: CoroutineScope,
    private val repository: () -> DsmRepository?,
    private val workspace: () -> WorkspaceState?,
    private val onBusy: (Boolean) -> Unit,
    private val onChanged: () -> Unit,
) {
    private val _state = MutableStateFlow(FilePermissionState())
    val state = _state.asStateFlow()
    private var editorRepository: DsmRepository? = null
    private var access = FilePermissionAccess()
    private var readJob: Job? = null
    private var memberJob: Job? = null
    private var epoch = 0L

    fun open(item: FileItem): Boolean = openPath(item.path)
    fun openRelatedChange() { _state.value.relatedPendingPath?.let(::openPath) }
    private fun openPath(path: String): Boolean {
        val current = workspace() ?: return false
        val repo = repository() ?: return false
        if (_state.value.busy || current.isPerformingAction || current.selectedModule != Module.FILES || !current.availability.allows(Module.FILES) ||
            !repo.filePermissions.supportsRead() || fileStationMutationBlocksOrdinaryLoad(current.fileStationMutationState) ||
            runCatching(repo::requireCurrentOwner).isFailure) return false
        invalidate(); editorRepository = repo; access = repo.filePermissionAccess
        _state.value = FilePermissionState(path = path, account = current.profile.username)
        reload()
        return true
    }
    fun reload() {
        val repo = editorRepository ?: return
        val path = _state.value.path ?: return
        if (_state.value.busy || repository() !== repo) return
        readJob?.cancel()
        val generation = ++epoch
        _state.update { it.copy(snapshot = Loadable.Loading, confirmation = false, failure = null, recoveryReadable = false) }
        readJob = scope.launch {
            val result = captureLoadable { repo.filePermissions.load(path) }
            val pending = suspendRunCatching { repo.filePermissions.pending() }
            if (!current(repo, generation)) return@launch
            access = repo.filePermissionAccess
            val snapshot = (result as? Loadable.Ready)?.value
            val exact = pending.getOrNull()?.any { it.path == path } ?: true
            val related = pending.getOrNull()?.firstOrNull { it.path != path &&
                io.github.qwertyuiop1995.dsmnativeclient.data.files.permissionPathsOverlap(it.path, path) }?.path
            _state.update { it.copy(snapshot = result, draft = FilePermissionDraft(snapshot?.explicitRules.orEmpty(), snapshot?.posixMode.orEmpty()),
                pending = exact, relatedPendingPath = related, recoveryReadable = pending.isSuccess, submitted = false,
                outcome = if (exact) it.outcome else null, failure = pending.exceptionOrNull()?.asDsmFailure()) }
        }
    }
    fun edit(transform: (FilePermissionDraft) -> FilePermissionDraft) {
        val current = _state.value
        if (current.busy || current.submitted || current.pending || current.relatedPendingPath != null || !current.recoveryReadable || current.snapshot !is Loadable.Ready) return
        _state.update { it.copy(draft = transform(it.draft), confirmation = false, failure = null) }
    }
    fun change(): FilePermissionChange? {
        val current = _state.value
        val snapshot = (current.snapshot as? Loadable.Ready)?.value ?: return null
        val draft = current.draft
        return FilePermissionChange(snapshot, draft.rules.takeIf { snapshot.isACL && it != snapshot.explicitRules },
            draft.posixMode.takeIf { !snapshot.isACL && it != snapshot.posixMode }, draft.owner, draft.group, draft.recursive)
    }
    fun canSubmit(): Boolean {
        val current = _state.value
        val change = change() ?: return false
        val repo = editorRepository ?: return false
        val workspace = workspace() ?: return false
        if (workspace.selectedModule != Module.FILES || !workspace.availability.allows(Module.FILES) || workspace.isPerformingAction) return false
        if (repository() !== repo || current.busy || current.submitted || current.pending || current.relatedPendingPath != null || !current.recoveryReadable ||
            !change.hasChanges || repo.filePermissionAccess != access || !access.granted) return false
        return if (change.baseline.isACL) (change.explicitRules == null || change.baseline.canChangePermissions) &&
            (change.owner == null || change.baseline.owner?.canChange == true && access.administrator)
        else change.baseline.canChangePermissions && access.administrator && validFilePermissionMode(current.draft.posixMode)
    }
    fun dismissConfirmation() { _state.update { it.copy(confirmation = false) } }
    fun submit(confirmed: Boolean = false) {
        if (!canSubmit()) return
        if (!confirmed) { _state.update { it.copy(confirmation = true) }; return }
        if (!_state.value.confirmation) return
        val repo = editorRepository ?: return
        val change = change() ?: return
        val generation = epoch
        _state.update { it.copy(busy = true, submitted = true, confirmation = false, failure = null) }
        onBusy(true)
        scope.launch {
            val result = suspendRunCatching { repo.filePermissions.changePermissionsResult(change, confirmed = true) }
            if (repository() === repo) onChanged()
            if (!current(repo, generation)) return@launch
            val pending = suspendRunCatching { repo.filePermissions.pending().any { it.path == change.baseline.target.path } }
            if (!current(repo, generation)) return@launch
            _state.update { it.copy(busy = false, outcome = result.getOrNull(), failure = result.exceptionOrNull()?.asDsmFailure(),
                pending = pending.getOrDefault(true), recoveryReadable = pending.isSuccess) }
            onBusy(false)
        }
    }
    fun refreshResult() {
        val repo = editorRepository ?: return
        val current = _state.value
        val path = current.path ?: return
        if (current.busy || !current.pending || repository() !== repo) return
        val generation = epoch
        _state.update { it.copy(busy = true, failure = null) }; onBusy(true)
        scope.launch {
            val result = suspendRunCatching { repo.filePermissions.review(path) }
            val snapshot = captureLoadable { repo.filePermissions.load(path) }
            if (repository() === repo) onChanged()
            if (!current(repo, generation)) return@launch
            _state.update { it.copy(busy = false, snapshot = snapshot, outcome = result.getOrNull(),
                pending = result.getOrNull()?.result?.status != MutationResultStatus.CONFIRMED_SUCCESS,
                submitted = true, failure = result.exceptionOrNull()?.asDsmFailure()) }
            onBusy(false)
        }
    }
    fun authorizationChanged() {
        val repo = editorRepository ?: return
        if (repo.filePermissionAccess != access) invalidate()
    }
    fun openMembers(purpose: FilePermissionMemberPurpose) {
        val snapshot = (_state.value.snapshot as? Loadable.Ready)?.value ?: return
        if (_state.value.busy || _state.value.submitted || _state.value.pending || _state.value.relatedPendingPath != null || !access.granted) return
        if (purpose == FilePermissionMemberPurpose.RULE && !snapshot.canChangePermissions ||
            purpose != FilePermissionMemberPurpose.RULE && (!access.administrator ||
                snapshot.isACL && (purpose == FilePermissionMemberPurpose.GROUP || snapshot.owner?.canChange != true))) return
        _state.update { it.copy(memberPurpose = purpose, memberQuery = "") }; searchMembers()
    }
    fun selectMember(member: FileSharePrincipal) {
        when (_state.value.memberPurpose ?: return) {
            FilePermissionMemberPurpose.RULE -> edit { it.copy(rules = it.rules + FileACLRule(member.kind.name.lowercase(), member.name,
                effect = FileACLEffect.ALLOW, rights = setOf(FileACLRight.READ_DATA), inheritance = setOf(FileACLInheritance.THIS_FOLDER))) }
            FilePermissionMemberPurpose.OWNER -> edit { it.copy(owner = member) }
            FilePermissionMemberPurpose.GROUP -> edit { it.copy(group = member) }
        }
        closeMembers()
    }
    fun closeMembers() { memberJob?.cancel(); _state.update { it.copy(memberPurpose = null) } }
    fun updateMemberQuery(query: String) { _state.update { it.copy(memberQuery = query) } }
    fun searchMembers() = loadMembers(false)
    fun moreMembers() = loadMembers(true)
    private fun loadMembers(append: Boolean) {
        val repo = editorRepository ?: return
        val before = _state.value
        if (before.memberPurpose == null || repository() !== repo) return
        val previous = if (append) (before.members as? Loadable.Ready)?.value ?: return else null
        if (previous != null && previous.nextOffset >= previous.total) return
        val query = if (append) before.memberResultQuery else before.memberQuery
        val generation = epoch
        memberJob?.cancel()
        _state.update { it.copy(members = if (append) it.members else Loadable.Loading, membersLoadingMore = append, membersMoreFailure = null) }
        memberJob = scope.launch {
            val result = captureLoadable { repo.listFileSharePrincipals(query, previous?.nextOffset ?: 0) }
            if (!current(repo, generation) || _state.value.memberPurpose != before.memberPurpose || _state.value.memberQuery != query) return@launch
            _state.update { state ->
                if (previous == null) state.copy(members = result, memberResultQuery = query, membersLoadingMore = false)
                else when (result) {
                    is Loadable.Ready -> if (result.value.total != previous.total || result.value.items.any { it in previous.items })
                        state.copy(membersLoadingMore = false, membersMoreFailure = io.github.qwertyuiop1995.dsmnativeclient.data.files.permissionChanged())
                    else state.copy(members = Loadable.Ready(result.value.copy(items = previous.items + result.value.items)), membersLoadingMore = false)
                    is Loadable.Failed -> state.copy(membersLoadingMore = false, membersMoreFailure = result.error)
                    else -> state.copy(membersLoadingMore = false)
                }
            }
        }
    }
    fun close() { if (!_state.value.busy) invalidate() }
    fun invalidate() {
        if (_state.value.busy) onBusy(false)
        epoch++; readJob?.cancel(); memberJob?.cancel(); editorRepository = null
        _state.value = FilePermissionState()
    }
    private fun current(repo: DsmRepository, generation: Long) = repository() === repo && editorRepository === repo && epoch == generation
}

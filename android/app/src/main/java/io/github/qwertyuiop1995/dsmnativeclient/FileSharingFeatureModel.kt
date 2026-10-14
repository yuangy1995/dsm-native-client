package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.ShareLinkMutationOutcome
import io.github.qwertyuiop1995.dsmnativeclient.data.files.FileSharePendingChange
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal enum class FileShareEditor { CREATE, EDIT, ACCESS }
internal enum class FileSharePasswordMode { KEEP, SET, REMOVE }
internal data class FileShareDraft(
    val passwordMode: FileSharePasswordMode = FileSharePasswordMode.KEEP,
    val password: String = "",
    val availableOn: FileShareDateChange = FileShareDateChange.Keep,
    val expiresOn: FileShareDateChange = FileShareDateChange.Keep,
    val fileRequest: Boolean = false,
    val requestName: String = "",
    val requestMessage: String = "",
    val audience: FileShareAudienceChange = FileShareAudienceChange.Keep,
    val maximumAccesses: String = "0",
) {
    override fun toString(): String = "FileShareDraft(redacted)"
}
internal data class FileShareItemResult(val name: String, val outcome: ShareLinkMutationOutcome)
internal data class FileSharingState(
    val editor: FileShareEditor? = null,
    val targets: List<FileItem> = emptyList(),
    val links: List<FileShareLink> = emptyList(),
    val draft: FileShareDraft = FileShareDraft(),
    val busy: Boolean = false,
    val submitted: Boolean = false,
    val confirmation: Boolean = false,
    val results: List<FileShareItemResult> = emptyList(),
    val pending: List<FileSharePendingChange> = emptyList(),
    val failure: DsmFailure? = null,
    val membersVisible: Boolean = false,
    val memberQuery: String = "",
    val memberResultQuery: String = "",
    val members: Loadable<FileSharePrincipalPage> = Loadable.Idle,
    val selectedMembers: Set<FileSharePrincipal> = emptySet(),
    val membersLoadingMore: Boolean = false,
    val membersMoreFailure: DsmFailure? = null,
)

/** 工作区独立拥有草稿与逐项结果；密码只存于内存，提交后立即移出界面状态。 */
internal class FileSharingFeatureModel(
    private val scope: CoroutineScope,
    private val repository: () -> DsmRepository?,
    private val workspace: () -> WorkspaceState?,
    private val updateLinks: (Loadable<List<FileShareLink>>) -> Unit,
    private val onBusy: (Boolean) -> Unit,
) {
    private val _state = MutableStateFlow(FileSharingState())
    val state = _state.asStateFlow()
    private var editorRepository: DsmRepository? = null
    private var readJob: Job? = null
    private var membersJob: Job? = null
    private var epoch = 0L
    private var stopRemaining = false

    fun openCreate(targets: List<FileItem>): Boolean {
        val repo = canOpen() ?: return false
        val items = targets.distinctBy(FileItem::path)
        if (items.isEmpty() || items.any { !it.canRead }) return false
        editorRepository = repo
        _state.value = FileSharingState(editor = FileShareEditor.CREATE, targets = items, pending = _state.value.pending,
            draft = FileShareDraft(availableOn = FileShareDateChange.Clear, expiresOn = FileShareDateChange.Clear))
        return true
    }
    fun openEdit(links: List<FileShareLink>, access: Boolean = false): Boolean {
        val repo = canOpen() ?: return false
        if (links.isEmpty() || links.any { !it.passwordKnown || !it.availabilityKnown || !it.expirationKnown } ||
            access && (links.size != 1 || links.single().advanced == null)) return false
        editorRepository = repo
        val advanced = links.singleOrNull()?.advanced
        _state.value = FileSharingState(editor = if (access) FileShareEditor.ACCESS else FileShareEditor.EDIT,
            links = links, pending = _state.value.pending, draft = FileShareDraft(maximumAccesses = (advanced?.maximumAccesses ?: 0).toString(),
                requestName = advanced?.requestName.orEmpty(), requestMessage = advanced?.requestMessage.orEmpty()))
        return true
    }
    private fun canOpen(): DsmRepository? {
        val current = workspace() ?: return null
        if (_state.value.busy || current.isPerformingAction || current.selectedModule != Module.FILES ||
            fileStationMutationBlocksOrdinaryLoad(current.fileStationMutationState)) return null
        return repository()?.takeIf { runCatching(it::requireCurrentOwner).isSuccess }
    }
    fun edit(transform: (FileShareDraft) -> FileShareDraft) {
        if (!_state.value.busy && !_state.value.submitted) _state.update { it.copy(draft = transform(it.draft), confirmation = false, failure = null) }
    }
    fun close() {
        if (_state.value.busy) return
        membersJob?.cancel(); editorRepository = null
        _state.value = FileSharingState(pending = _state.value.pending)
    }
    fun dismissConfirmation() { _state.update { it.copy(confirmation = false) } }
    fun stopAfterCurrent() { stopRemaining = true }

    fun refreshLinks() {
        val repo = repository() ?: return
        readJob?.cancel()
        updateLinks(Loadable.Loading)
        val generation = epoch
        readJob = scope.launch {
            val result = captureLoadable { repo.listShareLinks() }
            if (repository() !== repo || generation != epoch) return@launch
            updateLinks(result)
            try {
                val pending = if (result is Loadable.Ready) repo.recoverShareChanges() else repo.pendingShareChanges()
                if (repository() === repo && generation == epoch) _state.update { it.copy(pending = pending, failure = null) }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (repository() === repo && generation == epoch) _state.update { it.copy(failure = error.asDsmFailure()) }
            }
        }
    }

    fun canSubmit(): Boolean {
        val current = _state.value
        if (current.busy || current.submitted || current.editor == null) return false
        return runCatching { when (current.editor) {
            FileShareEditor.CREATE -> createRequests(current).all(FileShareCreateRequest::isValid) && current.targets.isNotEmpty()
            else -> editRequests(current).all(FileShareEditRequest::isValid) && current.links.isNotEmpty()
        } }.getOrDefault(false)
    }
    fun submit(acceptRisk: Boolean = false) {
        val repo = editorRepository ?: return
        if (repository() !== repo || !canSubmit()) return
        val before = _state.value
        val risk = before.draft.fileRequest || before.draft.passwordMode == FileSharePasswordMode.REMOVE ||
            before.draft.passwordMode == FileSharePasswordMode.SET && before.links.any { it.advanced?.protection == FileShareProtection.USERS } ||
            before.editor == FileShareEditor.ACCESS && before.draft.audience != FileShareAudienceChange.Keep
        if (risk && !acceptRisk) { _state.update { it.copy(confirmation = true) }; return }
        if (runCatching(repo::requireCurrentOwner).isFailure) return
        val creates = if (before.editor == FileShareEditor.CREATE) createRequests(before) else emptyList()
        val edits = if (before.editor != FileShareEditor.CREATE) editRequests(before) else emptyList()
        stopRemaining = false
        _state.update { it.copy(busy = true, submitted = true, confirmation = false, results = emptyList(), draft = it.draft.copy(password = "")) }
        onBusy(true)
        val generation = epoch
        scope.launch {
            try {
                val operations: List<Pair<String, suspend () -> ShareLinkMutationOutcome>> = creates.map { it.target.name to suspend { repo.createShareLinkResult(it) } } +
                    edits.map { it.baseline.name to suspend { repo.editShareLinkResult(it) } }
                for ((name, operation) in operations) {
                    val result = if (stopRemaining) cancelledOutcome() else try { operation() } catch (error: Exception) {
                        if (error is CancellationException) throw error
                        _state.update { it.copy(failure = error.asDsmFailure()) }
                        unknownOutcome()
                    }
                    if (repository() !== repo || generation != epoch) break
                    _state.update { it.copy(results = it.results + FileShareItemResult(name, result)) }
                }
            } finally {
                if (repository() === repo && generation == epoch) {
                    _state.update { it.copy(busy = false) }; onBusy(false); refreshLinks()
                }
            }
        }
    }

    private fun createRequests(state: FileSharingState): List<FileShareCreateRequest> {
        val draft = state.draft
        return state.targets.map { FileShareCreateRequest(it, draft.password.takeIf(String::isNotEmpty),
            (draft.availableOn as? FileShareDateChange.Set)?.date, (draft.expiresOn as? FileShareDateChange.Set)?.date,
            if (draft.fileRequest) FileRequestConfiguration(draft.requestName, draft.requestMessage) else null) }
    }
    private fun editRequests(state: FileSharingState): List<FileShareEditRequest> {
        val draft = state.draft
        return state.links.map { link ->
            FileShareEditRequest(link, password = when (draft.passwordMode) {
                FileSharePasswordMode.KEEP -> FileSharePasswordChange.Keep
                FileSharePasswordMode.REMOVE -> FileSharePasswordChange.Remove
                FileSharePasswordMode.SET -> FileSharePasswordChange.Set(draft.password)
            }, availableOn = draft.availableOn, expiresOn = draft.expiresOn,
                advanced = if (state.editor == FileShareEditor.ACCESS) FileShareAdvancedChange(draft.audience,
                    draft.maximumAccesses.toIntOrNull() ?: -1,
                    draft.requestName.takeIf { link.advanced?.isFileRequest == true }, draft.requestMessage.takeIf { link.advanced?.isFileRequest == true }) else null)
        }
    }

    fun openMembers() {
        if (_state.value.busy || _state.value.submitted || editorRepository !== repository()) return
        val current = _state.value
        val baseline = current.links.singleOrNull()?.advanced ?: return
        val selected = (current.draft.audience as? FileShareAudienceChange.Principals)?.members ?:
            (baseline.users.map { FileSharePrincipal(it, FileSharePrincipalKind.USER) } + baseline.groups.map { FileSharePrincipal(it, FileSharePrincipalKind.GROUP) }).toSet()
        _state.update { it.copy(membersVisible = true, selectedMembers = selected) }
        searchMembers("")
    }
    fun closeMembers() { membersJob?.cancel(); _state.update { it.copy(membersVisible = false) } }
    fun selectMember(member: FileSharePrincipal) {
        _state.update { current -> current.copy(selectedMembers = if (member in current.selectedMembers) current.selectedMembers - member else current.selectedMembers + member) }
    }
    fun useMembers() {
        if (_state.value.selectedMembers.isEmpty()) return
        edit { it.copy(audience = FileShareAudienceChange.Principals(_state.value.selectedMembers)) }
        closeMembers()
    }
    fun updateMemberQuery(query: String) { _state.update { it.copy(memberQuery = query) } }
    fun searchMembers(query: String = _state.value.memberQuery) = loadMembers(query, append = false)
    fun moreMembers() = loadMembers(_state.value.memberResultQuery, append = true)
    private fun loadMembers(query: String, append: Boolean) {
        val repo = editorRepository ?: return
        if (repository() !== repo) return
        val previous = if (append) (_state.value.members as? Loadable.Ready)?.value ?: return else null
        if (previous != null && previous.nextOffset >= previous.total) return
        membersJob?.cancel()
        _state.update { it.copy(memberQuery = query, members = if (append) it.members else Loadable.Loading, membersLoadingMore = append, membersMoreFailure = null) }
        membersJob = scope.launch {
            val result = captureLoadable { repo.listFileSharePrincipals(query, previous?.nextOffset ?: 0) }
            if (repository() !== repo || editorRepository !== repo || !_state.value.membersVisible || _state.value.memberQuery != query) return@launch
            _state.update { current ->
                if (previous == null) current.copy(members = result, memberResultQuery = query, membersLoadingMore = false)
                else when (result) {
                    is Loadable.Ready -> if (result.value.total != previous.total || result.value.items.any { it in previous.items })
                        current.copy(membersLoadingMore = false, membersMoreFailure = DsmFailure(null, "The member list changed", "Search again.", kind = DsmErrorKind.CHANGE_NOT_CONFIRMED))
                    else current.copy(members = Loadable.Ready(result.value.copy(items = previous.items + result.value.items)), membersLoadingMore = false)
                    is Loadable.Failed -> current.copy(membersLoadingMore = false, membersMoreFailure = result.error)
                    else -> current.copy(membersLoadingMore = false)
                }
            }
        }
    }
    fun invalidate() {
        if (_state.value.busy) onBusy(false)
        epoch++; readJob?.cancel(); membersJob?.cancel(); stopRemaining = true
        editorRepository = null
        _state.value = FileSharingState()
    }
    private fun cancelledOutcome() = ShareLinkMutationOutcome(MutationResult(1, MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
        "shareLinkBatch", false, false, MutationResultCounts(0, 0, 0)))
    private fun unknownOutcome() = ShareLinkMutationOutcome(MutationResult(1, MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        "shareLinkBatch", true, true, MutationResultCounts(0, 0, 1)))
}

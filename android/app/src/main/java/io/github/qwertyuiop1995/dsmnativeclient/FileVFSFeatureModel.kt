package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.FileVFSDownloadSource
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal enum class FileVFSScreen { MANAGER, EDITOR, CLOUD, ACTION, RECOVERY, BROWSER }
internal data class FileVFSInventory(val profiles: List<FileVFSProfile>, val protocols: List<FileVFSProtocol>)
internal data class FileVFSBrowserLocation(val path: String, val title: String)
internal data class FileVFSState(
    val screen: FileVFSScreen? = null, val inventory: Loadable<FileVFSInventory> = Loadable.Idle,
    val pending: List<FileVFSPending> = emptyList(), val recoveryReadable: Boolean = false, val filter: String = "",
    val baseline: FileVFSProfile? = null, val detail: Loadable<FileVFSDetail> = Loadable.Idle,
    val setup: FileVFSConfiguration = FileVFSConfiguration(), val action: FileVFSChange? = null,
    val recoveryId: String? = null, val busy: Boolean = false, val submitted: Boolean = false,
    val failure: DsmFailure? = null, val outcome: FileVFSOutcome? = null, val cleartextConfirmation: Boolean = false,
    val cloudLoading: Boolean = false, val cloudWaiting: Boolean = false, val browserUrl: String? = null,
    val authorizedAccount: String? = null, val cloudAlias: String = "",
    val locations: List<FileVFSBrowserLocation> = emptyList(), val files: Loadable<FilePage> = Loadable.Idle,
    val loadingMore: Boolean = false, val nextPageFailure: DsmFailure? = null,
)

/** 页面持有原账号与请求代次；密码由 Compose 管理，云令牌只在此对象的短期内存中。 */
internal class FileVFSFeatureModel(
    private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val workspace: () -> WorkspaceState?, private val onBusy: (Boolean) -> Unit,
) {
    private val _state = MutableStateFlow(FileVFSState())
    val state = _state.asStateFlow()
    private var activeRepository: DsmRepository? = null
    private var access = FilePermissionAccess()
    private var epoch = 0L
    private var readJob: Job? = null
    private var cloudJob: Job? = null
    private var expiryJob: Job? = null
    private var cloudRequest: FileVFSCloudRequest? = null
    private var cloudSession: FileVFSCloudAuthorizationSession? = null
    private var cloudAuthorization: FileVFSCloudAuthorization? = null

    fun available() = repository()?.fileMounts?.vfs?.supportsRead() == true
    fun openManager(): Boolean {
        val repo = repository() ?: return false
        val current = workspace() ?: return false
        if (_state.value.busy || current.isPerformingAction || current.selectedModule != Module.FILES ||
            !current.availability.allows(Module.FILES) || !available() || fileStationMutationBlocksOrdinaryLoad(current.fileStationMutationState) ||
            runCatching(repo::requireCurrentOwner).isFailure) return false
        invalidate(); activeRepository = repo; access = repo.filePermissionAccess
        _state.value = FileVFSState(screen = FileVFSScreen.MANAGER); reload(); return true
    }
    fun reload() {
        val repo = currentRepository() ?: return
        if (_state.value.busy) return
        readJob?.cancel(); val generation = ++epoch
        _state.update { it.copy(inventory = Loadable.Loading, recoveryReadable = false, failure = null) }
        readJob = scope.launch {
            var records = emptyList<FileVFSPending>()
            val result = captureLoadable {
                records = repo.fileMounts.vfs.pending()
                FileVFSInventory(repo.fileMounts.vfs.reader.profiles(), repo.fileMounts.vfs.reader.protocols())
            }
            if (!current(repo, generation)) return@launch
            access = repo.filePermissionAccess
            _state.update { it.copy(inventory = result, pending = records, recoveryReadable = result is Loadable.Ready) }
        }
    }
    fun filter(value: String) { _state.update { it.copy(filter = value) } }
    fun options() = (_state.value.inventory as? Loadable.Ready)?.value?.protocols.orEmpty()
    fun canManage(): Boolean {
        val repo = currentRepository() ?: return false
        return !_state.value.busy && _state.value.recoveryReadable && _state.value.pending.isEmpty() &&
            repo.fileMounts.vfs.supportsWrite() && repo.filePermissionAccess == access && access.granted && access.administrator
    }
    private fun contains(profile: FileVFSProfile) = (_state.value.inventory as? Loadable.Ready)?.value?.profiles?.any { it.sameSnapshot(profile) } == true
    fun openEditor(profile: FileVFSProfile? = null) {
        if (!canManage() || profile != null && (!contains(profile) || profile.state == FileVFSConnectionState.UNKNOWN)) return
        val option = options().firstOrNull { it.supportsServerSetup && (profile == null || profile.protocolId == it.id) } ?: return
        clearCloud(); readJob?.cancel(); val generation = ++epoch
        _state.update { it.copy(screen = FileVFSScreen.EDITOR, baseline = profile, detail = if (profile == null) Loadable.Idle else Loadable.Loading,
            setup = FileVFSConfiguration(protocolId = option.id, port = option.defaultPort ?: 0), action = null,
            failure = null, submitted = false, outcome = null, cleartextConfirmation = false) }
        if (profile == null) return
        val repo = currentRepository() ?: return
        readJob = scope.launch {
            val result = captureLoadable { repo.fileMounts.vfs.reader.detail(profile) }
            if (current(repo, generation)) _state.update { it.copy(detail = result, setup = (result as? Loadable.Ready)?.value?.configuration ?: it.setup) }
        }
    }
    fun edit(block: (FileVFSConfiguration) -> FileVFSConfiguration) {
        if (!canManage() || _state.value.submitted || _state.value.screen != FileVFSScreen.EDITOR) return
        _state.update { it.copy(setup = block(it.setup), failure = null, cleartextConfirmation = false) }
    }
    fun protocol(id: String) {
        if (_state.value.baseline != null) return
        val option = options().singleOrNull { it.id == id && it.supportsServerSetup } ?: return
        edit { it.copy(protocolId = id, port = option.defaultPort ?: 0, folder = "", usesOneConnection = false) }
    }
    fun canSave(passwordChanged: Boolean): Boolean {
        val value = _state.value
        if (!canManage() || value.submitted || workspace()?.isPerformingAction != false || value.screen != FileVFSScreen.EDITOR) return false
        val setup = runCatching { value.setup.resolved(options(), value.baseline?.protocolId) }.getOrNull() ?: return false
        if (value.baseline == null) return true
        val detail = (value.detail as? Loadable.Ready)?.value ?: return false
        return setup != detail.configuration || passwordChanged
    }
    fun dismissCleartext() { _state.update { it.copy(cleartextConfirmation = false) } }
    fun save(password: String?, cleartextAccepted: Boolean = false): Boolean {
        if (!canSave(password != null)) return false
        val value = _state.value
        val setup = value.setup.resolved(options(), value.baseline?.protocolId)
        if (setup.usesCleartext && !cleartextAccepted) { _state.update { it.copy(cleartextConfirmation = true) }; return false }
        if (setup.usesCleartext && !value.cleartextConfirmation) return false
        val change = (value.detail as? Loadable.Ready)?.value?.let { FileVFSChange.Update(it, setup) } ?: FileVFSChange.Create(setup)
        val repo = currentRepository() ?: return false
        runOperation(repo) { repo.fileMounts.vfs.changeVFSResult(change, password, true, cleartextAccepted) }; return true
    }
    fun openAction(change: FileVFSChange) {
        val profile = change.baselineProfile ?: return
        if (!canManage() || !contains(profile) || when (change) {
                is FileVFSChange.Connect, is FileVFSChange.RemoveSaved -> profile.state != FileVFSConnectionState.DISCONNECTED
                is FileVFSChange.Disconnect -> profile.state != FileVFSConnectionState.CONNECTED
                else -> true
            }) return
        clearCloud(); readJob?.cancel(); epoch++
        _state.update { it.copy(screen = FileVFSScreen.ACTION, action = change, baseline = profile, submitted = false, outcome = null, failure = null) }
    }
    fun submitAction() {
        val repo = currentRepository() ?: return
        val value = _state.value
        if (!canManage() || value.submitted || workspace()?.isPerformingAction != false || value.screen != FileVFSScreen.ACTION) return
        val change = value.action ?: return
        runOperation(repo) { repo.fileMounts.vfs.changeVFSResult(change, null, true) }
    }
    fun openRecovery(record: FileVFSPending) {
        if (_state.value.busy || record !in _state.value.pending) return
        clearCloud(); readJob?.cancel(); epoch++
        _state.update { it.copy(screen = FileVFSScreen.RECOVERY, recoveryId = record.id, action = record.change,
            baseline = record.change.baselineProfile, submitted = false, outcome = null, failure = null) }
    }
    fun review() {
        val repo = currentRepository() ?: return
        val id = _state.value.recoveryId ?: return
        if (_state.value.busy || _state.value.pending.none { it.id == id }) return
        runOperation(repo) { repo.fileMounts.vfs.review(id) }
    }
    private fun runOperation(repo: DsmRepository, block: suspend () -> FileVFSOutcome) {
        val generation = epoch
        _state.update { it.copy(busy = true, submitted = true, cleartextConfirmation = false, failure = null, outcome = null) }; onBusy(true)
        scope.launch {
            try {
                val result = suspendRunCatching { block() }
                if (current(repo, generation)) clearCloud()
                val records = suspendRunCatching { repo.fileMounts.vfs.pending() }
                val inventory = captureLoadable { FileVFSInventory(repo.fileMounts.vfs.reader.profiles(), repo.fileMounts.vfs.reader.protocols()) }
                if (!current(repo, generation)) return@launch
                val outcome = result.getOrNull()
                _state.update { it.copy(busy = false, outcome = outcome, failure = result.exceptionOrNull()?.asDsmFailure()
                    ?: records.exceptionOrNull()?.asDsmFailure() ?: outcome?.failure, inventory = inventory,
                    pending = records.getOrNull() ?: it.pending, recoveryReadable = records.isSuccess,
                    recoveryId = outcome?.pending?.id ?: it.recoveryId,
                    screen = if (outcome?.pending != null) FileVFSScreen.RECOVERY else it.screen) }
            } finally { if (repository() === repo) onBusy(false) }
        }
    }
    fun openCloud(protocolId: String, profile: FileVFSProfile? = null) {
        if (!canManage() || options().none { it.id == protocolId && it.supportsCloudAuthorization } ||
            profile != null && (!contains(profile) || profile.protocolId != protocolId)) return
        clearCloud(); readJob?.cancel(); epoch++
        _state.update { it.copy(screen = FileVFSScreen.CLOUD, baseline = profile, setup = FileVFSConfiguration(protocolId = protocolId),
            cloudAlias = profile?.alias.orEmpty(), action = null, submitted = false, outcome = null, failure = null) }
    }
    fun cloudAlias(value: String) {
        if (!canManage() || _state.value.submitted || _state.value.baseline != null) return
        _state.update { it.copy(cloudAlias = value, failure = null) }
    }
    fun startAuthorization(successText: String, failureText: String) {
        val repo = currentRepository() ?: return
        if (!canManage() || _state.value.submitted || _state.value.screen != FileVFSScreen.CLOUD || _state.value.cloudLoading) return
        clearCloud(); val generation = epoch; val protocol = _state.value.setup.protocolId
        _state.update { it.copy(cloudLoading = true, failure = null) }
        cloudJob = scope.launch {
            var request: FileVFSCloudRequest? = null
            var session: FileVFSCloudAuthorizationSession? = null
            try {
                request = repo.fileMounts.vfs.prepareCloudAuthorization(protocol)
                if (!current(repo, generation)) return@launch
                cloudRequest = request
                session = FileVFSCloudAuthorizationSession(request, scope, successText, failureText,
                    { authorization -> scope.launch { acceptAuthorization(repo, generation, authorization) } },
                    { failure -> scope.launch {
                        if (current(repo, generation) && cloudRequest?.id == request.id) {
                            clearCloud(); _state.update { it.copy(failure = if (failure == FileVFSCloudSessionFailure.EXPIRED) vfsAuthorizationExpired() else vfsAuthorizationFailed()) }
                        }
                    } })
                cloudSession = session
                val url = session.start()
                if (!current(repo, generation) || cloudRequest?.id != request.id) return@launch
                _state.update { it.copy(cloudLoading = false, cloudWaiting = true, browserUrl = url) }
                expiryJob = scope.launch {
                    delay((600_000 - (System.currentTimeMillis() - request.createdAtMillis)).coerceAtLeast(0))
                    if (current(repo, generation) && cloudRequest?.id == request.id) {
                        clearCloud(); _state.update { it.copy(failure = vfsAuthorizationExpired()) }
                    }
                }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (current(repo, generation)) { clearCloud(); _state.update { it.copy(failure = error as? DsmFailure ?: vfsAuthorizationFailed()) } }
            } finally {
                if (cloudRequest?.id != request?.id || !current(repo, generation)) {
                    session?.close(); request?.let { repo.fileMounts.vfs.cancelCloudAuthorization(it.id) }
                }
            }
        }
    }
    private fun acceptAuthorization(repo: DsmRepository, generation: Long, authorization: FileVFSCloudAuthorization) {
        if (!current(repo, generation) || cloudRequest?.id != authorization.requestId || authorization.owner != repo.owner ||
            authorization.protocolId != _state.value.setup.protocolId) return
        val baseline = _state.value.baseline
        if (baseline != null && baseline.account != authorization.account) {
            clearCloud(); _state.update { it.copy(failure = vfsChanged()) }; return
        }
        cloudAuthorization = authorization; cloudSession = null
        _state.update { it.copy(cloudWaiting = false, browserUrl = null, authorizedAccount = authorization.account,
            cloudAlias = it.cloudAlias.ifBlank { authorization.account }, failure = null) }
    }
    fun browserFailed() {
        if (_state.value.cloudWaiting) { clearCloud(); _state.update { it.copy(failure = vfsAuthorizationFailed()) } }
    }
    fun cancelAuthorization() { if (!_state.value.busy) clearCloud() }
    fun canSaveCloud() = canManage() && !_state.value.submitted && _state.value.screen == FileVFSScreen.CLOUD &&
        cloudAuthorization != null && _state.value.cloudAlias.trim().let { it.isNotEmpty() && it.length <= 255 && it.none(Char::isISOControl) }
    fun saveCloud() {
        val repo = currentRepository() ?: return
        if (!canSaveCloud() || workspace()?.isPerformingAction != false) return
        val authorization = cloudAuthorization ?: return
        expiryJob?.cancel(); expiryJob = null; cloudAuthorization = null
        val change = _state.value.baseline?.let(FileVFSChange::Reauthorize) ?: FileVFSChange.CreateCloud(
            FileVFSCloudIdentity(authorization.protocolId, _state.value.cloudAlias.trim(), authorization.account))
        runOperation(repo) { repo.fileMounts.vfs.authorizeVFSResult(change, authorization, true) }
    }
    private fun clearCloud() {
        cloudJob?.cancel(); cloudJob = null; expiryJob?.cancel(); expiryJob = null
        cloudSession?.close(); cloudSession = null; cloudAuthorization = null
        cloudRequest?.let { activeRepository?.fileMounts?.vfs?.cancelCloudAuthorization(it.id) }; cloudRequest = null
        _state.update { it.copy(cloudLoading = false, cloudWaiting = false, browserUrl = null, authorizedAccount = null) }
    }
    fun browse(profile: FileVFSProfile) {
        if (_state.value.busy || !contains(profile) || profile.state != FileVFSConnectionState.CONNECTED) return
        clearCloud()
        _state.update { it.copy(screen = FileVFSScreen.BROWSER, baseline = profile, filter = "", failure = null,
            locations = listOf(FileVFSBrowserLocation(profile.uri, profile.alias))) }
        loadFolder()
    }
    fun enter(item: FileItem) {
        if (!item.isDirectory || !item.canRead || item !in (_state.value.files as? Loadable.Ready)?.value?.items.orEmpty()) return
        _state.update { it.copy(locations = it.locations + FileVFSBrowserLocation(item.path, item.name), filter = "") }; loadFolder()
    }
    fun location(index: Int) {
        if (index !in _state.value.locations.indices || index == _state.value.locations.lastIndex) return
        _state.update { it.copy(locations = it.locations.take(index + 1), filter = "") }; loadFolder()
    }
    fun browserBack() {
        if (_state.value.locations.size > 1) location(_state.value.locations.lastIndex - 1) else backToManager()
    }
    fun loadFolder(more: Boolean = false) {
        val repo = currentRepository() ?: return
        val value = _state.value
        val profile = value.baseline ?: return
        val path = value.locations.lastOrNull()?.path ?: return
        val previous = (value.files as? Loadable.Ready)?.value
        if (value.screen != FileVFSScreen.BROWSER || more && (value.loadingMore || previous == null || previous.items.size >= previous.total)) return
        readJob?.cancel(); val generation = ++epoch
        _state.update { it.copy(files = if (more) it.files else Loadable.Loading, loadingMore = more, nextPageFailure = null) }
        readJob = scope.launch {
            val result = captureLoadable {
                val page = repo.fileMounts.vfs.reader.folder(profile, path, if (more) previous!!.items.size else 0)
                if (!more) page else {
                    if (page.total != previous!!.total || page.items.any { row -> previous.items.any { it.path == row.path } }) throw vfsChanged()
                    page.copy(items = previous.items + page.items, offset = 0)
                }
            }
            if (current(repo, generation)) _state.update { it.copy(files = if (more && result is Loadable.Failed) it.files else result,
                loadingMore = false, nextPageFailure = (result as? Loadable.Failed)?.error) }
        }
    }
    fun downloadSource(item: FileItem): FileVFSDownloadSource? {
        currentRepository() ?: return null
        val value = _state.value
        if (value.screen != FileVFSScreen.BROWSER || item.isDirectory || !item.canRead || item !in (value.files as? Loadable.Ready)?.value?.items.orEmpty()) return null
        return FileVFSDownloadSource(value.baseline ?: return null, value.locations.lastOrNull()?.path ?: return null,
            item.path, item.name, item.size, item.modifiedAtEpochSeconds).takeIf { it.valid() }
    }
    fun backToManager() {
        if (_state.value.busy) return
        clearCloud(); readJob?.cancel(); epoch++
        _state.value = FileVFSState(screen = FileVFSScreen.MANAGER); reload()
    }
    fun authorizationChanged() { if (activeRepository != null && (repository() !== activeRepository || repository()?.filePermissionAccess != access)) invalidate() }
    fun close() { if (!_state.value.busy) invalidate() }
    fun invalidate() {
        epoch++; readJob?.cancel(); clearCloud(); activeRepository = null; _state.value = FileVFSState()
    }
    private fun current(repo: DsmRepository, generation: Long) = currentRepository() === repo && epoch == generation
    private fun currentRepository(): DsmRepository? {
        val repo = activeRepository ?: return null
        val state = workspace() ?: return null
        if (repository() !== repo || state.selectedModule != Module.FILES || !state.availability.allows(Module.FILES)) return null
        return runCatching { repo.requireCurrentOwner(); repo }.getOrNull()
    }
}

private fun vfsAuthorizationFailed() = DsmFailure(null, "Cloud sign-in could not be completed",
    "Check that a browser is available, then sign in again.", kind = DsmErrorKind.FILE_VFS_AUTHORIZATION_FAILED)

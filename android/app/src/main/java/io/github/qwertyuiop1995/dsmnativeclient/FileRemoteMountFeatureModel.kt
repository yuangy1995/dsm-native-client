package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal enum class RemoteMountScreen { MANAGER, EDITOR, DISCONNECT, RECOVERY }
internal enum class RemoteMountConfirmation { AUTOMATIC, CHANGE, END_REMAINING }
internal data class FileRemoteMountState(
    val screen: RemoteMountScreen? = null, val account: String = "", val filter: String = "",
    val inventory: Loadable<FileMountInventory> = Loadable.Idle, val pending: List<FileRemoteMountPending> = emptyList(),
    val recoveryReadable: Boolean = false, val baseline: FileMountConnection? = null,
    val setup: FileRemoteMountSetup = FileRemoteMountSetup(), val destination: FileItem? = null,
    val automaticChosen: Boolean = true, val recoveryId: String? = null,
    val busy: Boolean = false, val submitted: Boolean = false, val failure: DsmFailure? = null,
    val outcome: RemoteMountOutcome? = null, val confirmation: RemoteMountConfirmation? = null,
    val locationsVisible: Boolean = false, val locations: FileMountDestinationState = FileMountDestinationState(),
)

/** 密码由当前 Compose 表单持有，不进入状态流、保存状态或恢复记录。 */
internal class FileRemoteMountFeatureModel(
    private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val workspace: () -> WorkspaceState?, private val onBusy: (Boolean) -> Unit,
    private val onChanged: () -> Unit, private val onBrowse: (FileItem) -> Unit,
) {
    private val _state = MutableStateFlow(FileRemoteMountState())
    val state = _state.asStateFlow()
    private var activeRepository: DsmRepository? = null
    private var access = FilePermissionAccess()
    private var epoch = 0L; private var locationEpoch = 0L
    private var readJob: Job? = null; private var locationJob: Job? = null

    fun available() = repository()?.fileMounts?.supportsRead() == true
    fun openManager(): Boolean {
        val repo = repository() ?: return false
        val workspace = workspace() ?: return false
        if (_state.value.busy || workspace.isPerformingAction || workspace.selectedModule != Module.FILES ||
            !workspace.availability.allows(Module.FILES) || !available() || fileStationMutationBlocksOrdinaryLoad(workspace.fileStationMutationState) ||
            runCatching(repo::requireCurrentOwner).isFailure) return false
        invalidate(); activeRepository = repo; access = repo.filePermissionAccess
        _state.value = FileRemoteMountState(screen = RemoteMountScreen.MANAGER, account = workspace.profile.username)
        reload(); return true
    }
    fun reload() {
        val repo = currentRepository() ?: return
        if (_state.value.busy) return
        readJob?.cancel(); val generation = ++epoch
        _state.update { it.copy(inventory = Loadable.Loading, confirmation = null, failure = null, recoveryReadable = false) }
        readJob = scope.launch {
            var records = emptyList<FileRemoteMountPending>()
            val result = captureLoadable { records = repo.fileMounts.remote.pending(); repo.fileMounts.inventory() }
            if (!current(repo, generation)) return@launch
            access = repo.filePermissionAccess
            _state.update { it.copy(inventory = result, pending = records, recoveryReadable = result is Loadable.Ready, submitted = false) }
        }
    }
    fun filter(value: String) { _state.update { it.copy(filter = value) } }
    fun canManage(baseline: FileMountConnection? = _state.value.baseline, automatic: Boolean = _state.value.setup.automatic): Boolean {
        val repo = currentRepository() ?: return false
        return repo.fileMounts.supportsWrite() && repo.filePermissionAccess == access && access.granted &&
            (!(automatic || baseline != null && baseline.automatic != false) || access.administrator) &&
            (_state.value.inventory as? Loadable.Ready)?.value?.remoteEnabled == true
    }
    fun canChange(connection: FileMountConnection) = canManage(connection, false) && !_state.value.busy &&
        _state.value.pending.none { row -> row.paths.any { mountPathsOverlap(it, connection.mountPoint) } }
    fun openEditor(connection: FileMountConnection? = null) {
        if (_state.value.busy || !canManage(connection, false) || connection != null && (!canChange(connection) || !contains(connection))) return
        _state.update { it.copy(screen = RemoteMountScreen.EDITOR, baseline = connection,
            setup = connection?.let(FileRemoteMountSetup::from) ?: FileRemoteMountSetup(), destination = null,
            automaticChosen = connection == null || connection.automatic != null,
            confirmation = null, submitted = false, failure = null, outcome = null, recoveryId = null) }
    }
    fun openDisconnect(connection: FileMountConnection) {
        if (!canChange(connection) || !contains(connection)) return
        _state.update { it.copy(screen = RemoteMountScreen.DISCONNECT, baseline = connection, confirmation = null,
            setup = FileRemoteMountSetup(), submitted = false, failure = null, outcome = null, recoveryId = null) }
    }
    fun openRecovery(record: FileRemoteMountPending) {
        if (_state.value.busy || record !in _state.value.pending) return
        _state.update { it.copy(screen = RemoteMountScreen.RECOVERY, recoveryId = record.id, baseline = record.baseline,
            setup = record.setup ?: FileRemoteMountSetup(), submitted = false, failure = null, outcome = null, confirmation = null) }
    }
    fun record() = _state.value.pending.singleOrNull { it.id == _state.value.recoveryId }
    fun edit(block: (FileRemoteMountSetup) -> FileRemoteMountSetup) {
        if (_state.value.busy || _state.value.submitted || _state.value.screen != RemoteMountScreen.EDITOR) return
        val updated = block(_state.value.setup)
        _state.update { it.copy(setup = updated, confirmation = null, failure = null) }
    }
    fun protocol(kind: FileMountKind) = edit { it.copy(kind = kind, username = "", domain = "", nfsVersion = "3", nfsTransport = "tcp") }
    fun automatic(value: Boolean) { edit { it.copy(automatic = value) }; _state.update { it.copy(automaticChosen = true) } }
    fun useOriginalDestination() {
        if (_state.value.busy || _state.value.submitted) return
        val original = _state.value.baseline ?: return
        _state.update { it.copy(destination = null, setup = it.setup.copy(mountPoint = original.mountPoint), confirmation = null) }
    }
    fun canSubmit(): Boolean {
        val state = _state.value
        if (state.busy || state.submitted || !state.recoveryReadable || workspace()?.isPerformingAction != false || !canManage()) return false
        return if (state.screen == RemoteMountScreen.DISCONNECT) state.baseline != null && canChange(state.baseline)
        else state.screen == RemoteMountScreen.EDITOR && state.automaticChosen && isMountTargetPath(state.setup.mountPoint) &&
            (state.destination != null || state.setup.mountPoint == state.baseline?.mountPoint) && runCatching { state.setup.normalized() }.isSuccess
    }
    fun dismissConfirmation() { _state.update { it.copy(confirmation = null) } }
    fun submit(password: String, confirmed: Boolean = false): Boolean {
        if (!canSubmit()) return false
        val state = _state.value
        val risk = if (state.screen == RemoteMountScreen.EDITOR && state.baseline != null) RemoteMountConfirmation.CHANGE
            else if (state.screen == RemoteMountScreen.EDITOR && state.setup.automatic) RemoteMountConfirmation.AUTOMATIC else null
        if (risk != null && !confirmed) { _state.update { it.copy(confirmation = risk) }; return false }
        if (risk != null && state.confirmation != risk) return false
        val repo = currentRepository() ?: return false
        runOperation(repo) { repo.fileMounts.remote.changeRemoteMountResult(if (state.screen == RemoteMountScreen.EDITOR) state.setup else null,
            state.baseline, state.destination, password, true) }
        return true
    }
    fun review(record: FileRemoteMountPending) {
        val repo = currentRepository() ?: return
        if (_state.value.busy || record !in _state.value.pending) return
        runOperation(repo) { repo.fileMounts.remote.review(record.id) }
    }
    fun continueOperation(password: String): Boolean {
        val repo = currentRepository() ?: return false
        val record = record() ?: return false
        if (_state.value.busy || !record.stage.canContinue || !canManage(record.baseline, record.setup?.automatic == true)) return false
        runOperation(repo) { repo.fileMounts.remote.continueRemoteMountResult(record.id, password, true) }
        return true
    }
    fun endRemaining(confirmed: Boolean = false) {
        val repo = currentRepository() ?: return
        val record = record() ?: return
        if (_state.value.busy || !record.stage.canContinue) return
        if (!confirmed) { _state.update { it.copy(confirmation = RemoteMountConfirmation.END_REMAINING) }; return }
        if (_state.value.confirmation != RemoteMountConfirmation.END_REMAINING) return
        runOperation(repo) { repo.fileMounts.remote.endRemaining(record.id, true) }
    }
    private fun runOperation(repo: DsmRepository, block: suspend () -> RemoteMountOutcome) {
        val generation = epoch
        _state.update { it.copy(busy = true, submitted = true, confirmation = null, failure = null, outcome = null) }; onBusy(true)
        scope.launch {
            try {
                val result = suspendRunCatching { block() }
                val records = suspendRunCatching { repo.fileMounts.remote.pending() }
                val inventory = captureLoadable { repo.fileMounts.inventory() }
                if (repository() === repo) onChanged()
                if (!current(repo, generation)) return@launch
                val outcome = result.getOrNull()
                _state.update { it.copy(busy = false, outcome = outcome, failure = result.exceptionOrNull()?.asDsmFailure()
                    ?: records.exceptionOrNull()?.asDsmFailure() ?: outcome?.failure,
                    pending = records.getOrNull() ?: it.pending, inventory = inventory, recoveryReadable = records.isSuccess,
                    recoveryId = outcome?.pending?.id ?: it.recoveryId,
                    screen = if (outcome?.pending != null) RemoteMountScreen.RECOVERY else it.screen) }
            } finally { if (repository() === repo) onBusy(false) }
        }
    }
    fun browse(connection: FileMountConnection) {
        val repo = currentRepository() ?: return
        if (_state.value.busy || !contains(connection)) return
        readJob?.cancel(); val generation = ++epoch
        _state.update { it.copy(inventory = Loadable.Loading) }
        readJob = scope.launch {
            val result = suspendRunCatching {
                if (connection !in repo.fileMounts.inventory().remoteConnections) throw mountChanged()
                repo.fileMounts.item(connection.mountPoint).also {
                    if (!it.isDirectory || !it.canRead || !isRemoteMountType(it.mountPointType, connection.kind)) throw mountChanged()
                }
            }
            if (!current(repo, generation)) return@launch
            result.onSuccess { invalidate(); onBrowse(it) }.onFailure { failure -> _state.update { it.copy(inventory = Loadable.Failed(failure.asDsmFailure())) } }
        }
    }
    fun openLocations() {
        if (_state.value.busy || _state.value.submitted) return
        _state.update { it.copy(locationsVisible = true) }; loadLocations("")
    }
    fun closeLocations() { locationJob?.cancel(); locationEpoch++; _state.update { it.copy(locationsVisible = false) } }
    fun filterLocations(value: String) { _state.update { it.copy(locations = it.locations.copy(filter = value)) } }
    fun locationUp() = loadLocations(_state.value.locations.path.substringBeforeLast('/', ""))
    fun retryLocations() = loadLocations(_state.value.locations.path)
    fun enterLocation(item: FileItem) {
        if (item.isDirectory && item.canRead && item in (_state.value.locations.items as? Loadable.Ready)?.value.orEmpty()) loadLocations(item.path)
    }
    fun canChooseLocation() = !_state.value.busy && _state.value.locations.items is Loadable.Ready &&
        _state.value.locations.item?.let { it.canWrite && it.isDirectory && isNormalFileMountType(it.mountPointType) && isMountTargetPath(it.path) } == true
    fun chooseLocation() {
        currentRepository() ?: return
        if (!canChooseLocation()) return
        val item = _state.value.locations.item ?: return
        _state.update { it.copy(destination = item, setup = it.setup.copy(mountPoint = item.path), locationsVisible = false, confirmation = null) }
        locationJob?.cancel(); locationEpoch++
    }
    private fun loadLocations(path: String) {
        val repo = currentRepository() ?: return
        if (_state.value.busy) return
        locationJob?.cancel(); val generation = epoch; val locationGeneration = ++locationEpoch
        _state.update { it.copy(locations = FileMountDestinationState(path = path, items = Loadable.Loading)) }
        locationJob = scope.launch {
            var item: FileItem? = null
            val result = captureLoadable { val loaded = loadMountDestinations(repo, path); item = loaded.first; loaded.second }
            if (current(repo, generation) && locationGeneration == locationEpoch && _state.value.locationsVisible)
                _state.update { it.copy(locations = it.locations.copy(item = item, items = result)) }
        }
    }
    fun backToManager() {
        if (_state.value.busy) return
        _state.update { it.copy(screen = RemoteMountScreen.MANAGER, baseline = null, setup = FileRemoteMountSetup(),
            confirmation = null, outcome = null, failure = null, submitted = false, recoveryId = null) }
        reload()
    }
    fun authorizationChanged() {
        if (activeRepository != null && (repository() !== activeRepository || repository()?.filePermissionAccess != access)) invalidate()
    }
    fun close() { if (!_state.value.busy) invalidate() }
    fun invalidate() {
        epoch++; locationEpoch++; readJob?.cancel(); locationJob?.cancel(); activeRepository = null; _state.value = FileRemoteMountState()
    }
    private fun contains(connection: FileMountConnection) = connection in (_state.value.inventory as? Loadable.Ready)?.value?.remoteConnections.orEmpty()
    private fun current(repo: DsmRepository, generation: Long) = currentRepository() === repo && epoch == generation
    private fun currentRepository(): DsmRepository? {
        val repo = activeRepository ?: return null
        val workspace = workspace() ?: return null
        if (repository() !== repo || workspace.selectedModule != Module.FILES || !workspace.availability.allows(Module.FILES)) return null
        return runCatching { repo.requireCurrentOwner(); repo }.getOrNull()
    }
}

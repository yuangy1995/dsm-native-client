package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal enum class ISOMountScreen { MANAGER, CONNECT, DISCONNECT }
internal data class FileISOMountState(
    val screen: ISOMountScreen? = null, val account: String = "", val sourcePath: String? = null,
    val source: FileItem? = null, val destination: FileItem? = null, val selected: FileMountConnection? = null,
    val inventory: Loadable<FileMountInventory> = Loadable.Idle, val pending: List<FileISOMountPending> = emptyList(),
    val recoveryReadable: Boolean = false, val automatic: Boolean = false, val confirmation: Boolean = false,
    val busy: Boolean = false, val submitted: Boolean = false, val filter: String = "",
    val result: MutationResult? = null, val resultPath: String? = null, val failure: DsmFailure? = null,
    val locationsVisible: Boolean = false, val locationPath: String = "", val location: FileItem? = null,
    val locations: Loadable<List<FileItem>> = Loadable.Idle, val locationFilter: String = "",
)

/** 原工作区持有表单与操作；关闭或撤权后迟到读取不能恢复旧页面。 */
internal class FileISOMountFeatureModel(
    private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val workspace: () -> WorkspaceState?, private val onBusy: (Boolean) -> Unit,
    private val onChanged: () -> Unit, private val onBrowse: (FileItem) -> Unit,
) {
    private val _state = MutableStateFlow(FileISOMountState())
    val state = _state.asStateFlow()
    private var activeRepository: DsmRepository? = null
    private var readJob: Job? = null
    private var locationJob: Job? = null
    private var epoch = 0L
    private var locationEpoch = 0L
    private var access = FilePermissionAccess()

    fun available() = repository()?.fileMounts?.supportsRead() == true
    fun openManager(): Boolean = open(ISOMountScreen.MANAGER)
    fun openMount(item: FileItem): Boolean {
        if (item.isDirectory || item.extension != "iso" || !item.canRead) return false
        return open(ISOMountScreen.CONNECT, item.path)
    }
    private fun open(screen: ISOMountScreen, path: String? = null): Boolean {
        val repo = repository() ?: return false
        val workspace = workspace() ?: return false
        if (_state.value.busy || workspace.isPerformingAction || workspace.selectedModule != Module.FILES ||
            !workspace.availability.allows(Module.FILES) || !available() || fileStationMutationBlocksOrdinaryLoad(workspace.fileStationMutationState) ||
            runCatching(repo::requireCurrentOwner).isFailure) return false
        invalidate(); activeRepository = repo; access = repo.filePermissionAccess
        _state.value = FileISOMountState(screen = screen, sourcePath = path, account = workspace.profile.username)
        reload(); return true
    }
    fun reload() {
        val repo = currentRepository() ?: return
        if (_state.value.busy) return
        readJob?.cancel(); val generation = ++epoch
        val sourcePath = _state.value.sourcePath
        _state.update { it.copy(inventory = Loadable.Loading, recoveryReadable = false, confirmation = false, failure = null) }
        readJob = scope.launch {
            var source: FileItem? = null
            var records = emptyList<FileISOMountPending>()
            val result = captureLoadable {
                if (sourcePath != null) source = repo.fileMounts.item(sourcePath, source = true)
                records = repo.fileMounts.pending()
                repo.fileMounts.inventory()
            }
            if (!current(repo, generation)) return@launch
            access = repo.filePermissionAccess
            _state.update { it.copy(inventory = result, pending = records, recoveryReadable = result is Loadable.Ready,
                source = source, submitted = false) }
        }
    }
    fun filter(value: String) { _state.update { it.copy(filter = value) } }
    fun automatic(value: Boolean) {
        if (!_state.value.busy && !_state.value.submitted) _state.update { it.copy(automatic = value, confirmation = false) }
    }
    fun openUnmount(connection: FileMountConnection) {
        if (_state.value.busy || connection !in (_state.value.inventory as? Loadable.Ready)?.value?.isoConnections.orEmpty()) return
        _state.update { it.copy(screen = ISOMountScreen.DISCONNECT, selected = connection, result = null, failure = null, submitted = false, confirmation = false) }
    }
    fun browse(connection: FileMountConnection) {
        val repo = currentRepository() ?: return
        if (_state.value.busy || connection !in (_state.value.inventory as? Loadable.Ready)?.value?.isoConnections.orEmpty()) return
        readJob?.cancel(); val generation = ++epoch
        _state.update { it.copy(inventory = Loadable.Loading) }
        readJob = scope.launch {
            val result = suspendRunCatching {
                if (connection !in repo.fileMounts.inventory().isoConnections) throw mountChanged()
                repo.fileMounts.item(connection.mountPoint).also {
                    if (!it.isDirectory || !it.canRead || it.mountPointType != "iso") throw mountChanged()
                }
            }
            if (!current(repo, generation)) return@launch
            result.onSuccess { item -> invalidate(); onBrowse(item) }
                .onFailure { error -> _state.update { it.copy(inventory = Loadable.Failed(error.asDsmFailure())) } }
        }
    }
    fun canManage(): Boolean {
        val repo = currentRepository() ?: return false
        return repo.fileMounts.supportsWrite() && repo.filePermissionAccess == access && access.granted && access.administrator &&
            (_state.value.inventory as? Loadable.Ready)?.value?.isoEnabled == true
    }
    fun currentPending(): FileISOMountPending? {
        val paths = listOfNotNull(_state.value.destination?.path, _state.value.selected?.mountPoint, _state.value.source?.path)
        return _state.value.pending.firstOrNull { record -> paths.any { mountPathsOverlap(record.connection.mountPoint, it) } }
    }
    private fun change(): FileISOMountChange? = when (_state.value.screen) {
        ISOMountScreen.CONNECT -> _state.value.source?.let { source -> _state.value.destination?.let { FileISOMountChange.Mount(source, it, _state.value.automatic) } }
        ISOMountScreen.DISCONNECT -> _state.value.selected?.let { FileISOMountChange.Unmount(it) }
        else -> null
    }
    fun canSubmit(): Boolean = !_state.value.busy && !_state.value.submitted && _state.value.recoveryReadable &&
        workspace()?.isPerformingAction == false && canManage() && change() != null && currentPending() == null
    fun dismissConfirmation() { _state.update { it.copy(confirmation = false) } }
    fun submit(confirmed: Boolean = false) {
        if (!canSubmit()) return
        val change = change() ?: return
        if (change is FileISOMountChange.Mount && change.automatic) {
            if (!confirmed) { _state.update { it.copy(confirmation = true) }; return }
            if (!_state.value.confirmation) return
        }
        val repo = currentRepository() ?: return
        runOperation(repo, change.mountPoint) { repo.fileMounts.changeISOMountResult(change, confirmed = true) }
    }
    fun review(record: FileISOMountPending) {
        val repo = currentRepository() ?: return
        if (_state.value.busy || record !in _state.value.pending) return
        runOperation(repo, record.connection.mountPoint) { repo.fileMounts.review(record.id) }
    }
    private fun runOperation(repo: DsmRepository, point: String, block: suspend () -> MutationResult) {
        val generation = epoch
        _state.update { it.copy(busy = true, submitted = true, confirmation = false, failure = null, result = null, resultPath = point) }
        onBusy(true)
        scope.launch {
            try {
                val result = suspendRunCatching { block() }
                val records = suspendRunCatching { repo.fileMounts.pending() }
                val inventory = captureLoadable { repo.fileMounts.inventory() }
                if (repository() === repo) onChanged()
                if (!current(repo, generation)) return@launch
                _state.update { it.copy(busy = false, result = result.getOrNull(), failure = result.exceptionOrNull()?.asDsmFailure()
                    ?: records.exceptionOrNull()?.asDsmFailure(), pending = records.getOrNull() ?: it.pending,
                    recoveryReadable = records.isSuccess, inventory = inventory) }
            } finally { if (repository() === repo) onBusy(false) }
        }
    }

    fun openLocations() {
        if (_state.value.busy || _state.value.submitted || currentPending() != null) return
        _state.update { it.copy(locationsVisible = true) }; loadLocations("")
    }
    fun closeLocations() { locationJob?.cancel(); locationEpoch++; _state.update { it.copy(locationsVisible = false) } }
    fun filterLocations(value: String) { _state.update { it.copy(locationFilter = value) } }
    fun locationUp() = loadLocations(_state.value.locationPath.substringBeforeLast('/', ""))
    fun retryLocations() = loadLocations(_state.value.locationPath)
    fun enterLocation(item: FileItem) {
        if (item.isDirectory && item.canRead && item in (_state.value.locations as? Loadable.Ready)?.value.orEmpty()) loadLocations(item.path)
    }
    fun canChooseLocation(): Boolean = !_state.value.busy && _state.value.locations is Loadable.Ready &&
        _state.value.location?.let { it.canWrite && it.isDirectory && isNormalFileMountType(it.mountPointType) && isMountTargetPath(it.path) } == true
    fun chooseLocation() {
        currentRepository() ?: return
        if (!canChooseLocation()) return
        _state.update { it.copy(destination = it.location, locationsVisible = false, confirmation = false, failure = null) }
        locationJob?.cancel(); locationEpoch++
    }
    private fun loadLocations(path: String) {
        val repo = currentRepository() ?: return
        if (_state.value.busy) return
        locationJob?.cancel(); val generation = epoch; val locationGeneration = ++locationEpoch
        _state.update { it.copy(locationPath = path, location = null, locations = Loadable.Loading, locationFilter = "") }
        locationJob = scope.launch {
            var location: FileItem? = null
            val result = captureLoadable {
                val loaded = loadMountDestinations(repo, path)
                location = loaded.first
                loaded.second
            }
            if (current(repo, generation) && locationEpoch == locationGeneration && _state.value.locationsVisible)
                _state.update { it.copy(location = location, locations = result) }
        }
    }
    fun authorizationChanged() {
        if (activeRepository != null && (repository() !== activeRepository || repository()?.filePermissionAccess != access)) invalidate()
    }
    fun close() { if (!_state.value.busy) invalidate() }
    fun invalidate() {
        epoch++; locationEpoch++; readJob?.cancel(); locationJob?.cancel(); activeRepository = null
        _state.value = FileISOMountState()
    }
    private fun current(repo: DsmRepository, generation: Long) = currentRepository() === repo && epoch == generation
    private fun currentRepository(): DsmRepository? {
        val repo = activeRepository ?: return null
        val workspace = workspace() ?: return null
        if (repository() !== repo || workspace.selectedModule != Module.FILES || !workspace.availability.allows(Module.FILES)) return null
        return runCatching { repo.requireCurrentOwner(); repo }.getOrNull()
    }
}

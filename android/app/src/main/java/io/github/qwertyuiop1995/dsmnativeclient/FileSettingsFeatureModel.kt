package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal enum class FileSettingsScreen { ROOT, GENERAL, POLICY_ACCOUNTS, MOUNT_SCOPE, MOUNT_ACCOUNTS, MOUNT_ACCOUNT, BANDWIDTH, BANDWIDTH_EDITOR, THEME }
internal data class FileSettingsState(
    val screen: FileSettingsScreen? = null,
    val general: Loadable<FileStationSettings> = Loadable.Idle, val generalDraft: FileStationSettings? = null, val linkLimit: String = "",
    val mountScope: Loadable<FileMountScope> = Loadable.Idle, val mountDraft: FileMountScope? = null,
    val directories: Loadable<FileMountDirectories> = Loadable.Idle,
    val source: FileMountAccountSource = FileMountAccountSource(FileMountSourceKind.LOCAL),
    val accountKind: FileSharePrincipalKind = FileSharePrincipalKind.USER, val query: String = "", val appliedQuery: String = "", val requestAccounts: Boolean = false,
    val policyAccounts: Loadable<FileSettingsPage<FileSettingsAccount>> = Loadable.Idle,
    val mountAccounts: Loadable<FileSettingsPage<FileMountAccount>> = Loadable.Idle,
    val mountAccount: FileMountAccount? = null, val accountEnabled: Boolean = false,
    val bandwidthType: FileBandwidthOwner = FileBandwidthOwner.LOCAL_USER,
    val bandwidth: Loadable<FileSettingsPage<FileBandwidthEntry>> = Loadable.Idle,
    val bandwidthBaseline: FileBandwidthEntry? = null, val bandwidthDraft: FileBandwidthEntry? = null,
    val rates: List<String> = emptyList(), val loadingMore: Boolean = false, val nextPageFailure: DsmFailure? = null,
    val pending: List<FileSettingsPending> = emptyList(), val recoveryReadable: Boolean = false,
    val busy: Boolean = false, val failure: DsmFailure? = null, val outcome: FileSettingsOutcome? = null,
    val confirmation: FileSettingsChange? = null,
    val theme: Loadable<FileSharingTheme> = Loadable.Idle, val themeDraft: FileSharingTheme? = null,
)

/** 设置草稿仅属于当前工作区。读取失败不生成默认草稿；保存和恢复固定原目标。 */
internal class FileSettingsFeatureModel(
    private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val workspace: () -> WorkspaceState?, private val onBusy: (Boolean) -> Unit,
) {
    private val _state = MutableStateFlow(FileSettingsState())
    val state = _state.asStateFlow()
    private var activeRepository: DsmRepository? = null
    private var access = FilePermissionAccess()
    private var epoch = 0L
    private var readJob: Job? = null
    val themePicker = FileThemePickerFeatureModel(scope, ::currentRepository, { canEdit() && _state.value.screen == FileSettingsScreen.THEME },
        { busy -> _state.update { it.copy(busy = busy) }; onBusy(busy) }, { image -> editTheme {
            if (image.kind == FileThemeImageKind.LOGO) it.copy(customLogo = true, logoImage = image) else it.copy(customBackground = true, backgroundImage = image)
        } })
    fun available() = repository()?.let { it.filePermissionAccess == FilePermissionAccess(true, true) &&
        (it.fileSettings.supportsGeneral() || it.fileSettings.supportsMountAccess() || it.fileSettings.supportsBandwidth() || it.fileSettings.supportsTheme()) } == true
    fun supportsGeneral() = currentRepository()?.fileSettings?.supportsGeneral() == true
    fun supportsMountAccess() = currentRepository()?.fileSettings?.supportsMountAccess() == true
    fun supportsBandwidth() = currentRepository()?.let { it.fileSettings.supportsBandwidth() && workspace()?.availability?.allows(Module.NAS_SETTINGS) == true } == true
    fun supportsTheme() = currentRepository()?.let { it.fileSettings.supportsTheme() && workspace()?.availability?.allows(Module.NAS_SETTINGS) == true } == true
    fun supportsThemeImages() = supportsTheme() && currentRepository()?.fileSettings?.supportsThemeImages() == true
    fun open(): Boolean {
        val repo = repository() ?: return false; val current = workspace() ?: return false
        if (current.selectedModule != Module.FILES || !current.availability.allows(Module.FILES) || current.isPerformingAction ||
            !available() || fileStationMutationBlocksOrdinaryLoad(current.fileStationMutationState) || runCatching(repo::requireCurrentOwner).isFailure) return false
        invalidate(); activeRepository = repo; access = repo.filePermissionAccess
        _state.value = FileSettingsState(screen = FileSettingsScreen.ROOT); reload(); return true
    }
    fun show(screen: FileSettingsScreen) {
        if (_state.value.busy || currentRepository() == null) return
        if (screen !in setOf(FileSettingsScreen.ROOT, FileSettingsScreen.GENERAL, FileSettingsScreen.MOUNT_SCOPE, FileSettingsScreen.BANDWIDTH, FileSettingsScreen.THEME)) return
        if (screen == FileSettingsScreen.THEME && !supportsTheme()) return
        themePicker.invalidate()
        readJob?.cancel(); epoch++
        _state.update { it.copy(screen = screen, query = "", appliedQuery = "", failure = null, outcome = null, confirmation = null) }
        reload()
    }
    fun reload() {
        val repo = currentRepository() ?: return; if (_state.value.busy) return
        readJob?.cancel(); val generation = ++epoch; val screen = _state.value.screen
        _state.update { it.copy(recoveryReadable = false, failure = null, nextPageFailure = null, loadingMore = false,
            general = if (screen == FileSettingsScreen.GENERAL) Loadable.Loading else it.general,
            generalDraft = if (screen == FileSettingsScreen.GENERAL) null else it.generalDraft,
            mountScope = if (screen == FileSettingsScreen.MOUNT_SCOPE) Loadable.Loading else it.mountScope,
            mountDraft = if (screen == FileSettingsScreen.MOUNT_SCOPE) null else it.mountDraft,
            policyAccounts = if (screen == FileSettingsScreen.POLICY_ACCOUNTS) Loadable.Loading else it.policyAccounts,
            mountAccounts = if (screen == FileSettingsScreen.MOUNT_ACCOUNTS) Loadable.Loading else it.mountAccounts,
            directories = if (screen == FileSettingsScreen.MOUNT_ACCOUNTS) Loadable.Loading else it.directories,
            bandwidth = if (screen == FileSettingsScreen.BANDWIDTH) Loadable.Loading else it.bandwidth,
            theme = if (screen == FileSettingsScreen.THEME) Loadable.Loading else it.theme,
            themeDraft = if (screen == FileSettingsScreen.THEME) null else it.themeDraft) }
        readJob = scope.launch {
            val pending = captureLoadable { repo.fileSettings.pending() }
            if (!current(repo, generation)) return@launch
            _state.update { it.copy(pending = (pending as? Loadable.Ready)?.value.orEmpty(), recoveryReadable = pending is Loadable.Ready,
                failure = (pending as? Loadable.Failed)?.error) }
            when (screen) {
                FileSettingsScreen.GENERAL -> {
                    val result = captureLoadable { repo.fileSettings.reader.general() }
                    if (current(repo, generation)) _state.update { it.copy(general = result, generalDraft = (result as? Loadable.Ready)?.value,
                        linkLimit = (result as? Loadable.Ready)?.value?.defaultLinkLimit?.toString().orEmpty()) }
                }
                FileSettingsScreen.THEME -> {
                    val result = captureLoadable { repo.fileSettings.reader.theme() }
                    if (current(repo, generation)) _state.update { it.copy(theme = result, themeDraft = (result as? Loadable.Ready)?.value) }
                }
                FileSettingsScreen.MOUNT_SCOPE -> {
                    val result = captureLoadable { repo.fileSettings.reader.mountScope() }
                    if (current(repo, generation)) _state.update { it.copy(mountScope = result, mountDraft = (result as? Loadable.Ready)?.value) }
                }
                FileSettingsScreen.MOUNT_ACCOUNTS -> {
                    val result = captureLoadable { repo.fileSettings.reader.directories() }
                    if (!current(repo, generation)) return@launch
                    _state.update { it.copy(directories = result, source = if (result is Loadable.Ready && result.value.items.none { row -> row.source == it.source })
                        FileMountAccountSource(FileMountSourceKind.LOCAL) else it.source) }
                    loadPage(repo, generation, false)
                }
                FileSettingsScreen.POLICY_ACCOUNTS, FileSettingsScreen.BANDWIDTH -> loadPage(repo, generation, false)
                else -> Unit
            }
        }
    }
    fun editGeneral(change: (FileStationSettings) -> FileStationSettings) {
        if (!canEdit()) return
        _state.update { value -> value.copy(generalDraft = value.generalDraft?.let(change), outcome = null, confirmation = null) }
    }
    fun editTheme(change: (FileSharingTheme) -> FileSharingTheme) {
        if (canEdit()) _state.update { it.copy(themeDraft = it.themeDraft?.let(change), outcome = null, confirmation = null) }
    }
    fun linkLimit(value: String) { if (canEdit() && value.length <= 9 && value.all { it in '0'..'9' }) _state.update { it.copy(linkLimit = value, outcome = null, confirmation = null) } }
    fun mountScope(value: FileMountScope) { if (canEdit()) _state.update { it.copy(mountDraft = value, outcome = null, confirmation = null) } }
    fun openPolicyAccounts(requests: Boolean) {
        if (!canEdit() || _state.value.generalDraft == null) return
        _state.update { it.copy(screen = FileSettingsScreen.POLICY_ACCOUNTS, requestAccounts = requests, query = "", appliedQuery = "", accountKind = FileSharePrincipalKind.USER) }
        reload()
    }
    fun togglePolicyAccount(row: FileSettingsAccount) {
        if (_state.value.busy || row.administrator || row !in (_state.value.policyAccounts as? Loadable.Ready)?.value?.items.orEmpty()) return
        val draft = _state.value.generalDraft ?: return
        val baseline = (_state.value.general as? Loadable.Ready)?.value ?: return
        if (!canWrite(FileSettingsChange.General(baseline, draft))) return
        val selected = if (_state.value.requestAccounts) draft.requestAccounts else draft.sharingAccounts
        val next = if (row.id in selected) selected - row.id else selected + row.id
        _state.update { it.copy(generalDraft = if (it.requestAccounts) draft.copy(requestAccounts = next) else draft.copy(sharingAccounts = next)) }
    }
    fun canChoosePolicyAccounts(): Boolean {
        val value = _state.value; val old = (value.general as? Loadable.Ready)?.value ?: return false
        return canWrite(FileSettingsChange.General(old, value.generalDraft ?: return false))
    }
    fun openMountAccounts() {
        if (_state.value.busy || currentRepository() == null) return
        _state.update { it.copy(screen = FileSettingsScreen.MOUNT_ACCOUNTS, query = "", appliedQuery = "", accountKind = FileSharePrincipalKind.USER, failure = null, outcome = null) }
        reload()
    }
    fun accountKind(kind: FileSharePrincipalKind) {
        if (_state.value.busy || kind == _state.value.accountKind) return
        _state.update { it.copy(accountKind = kind) }; search()
    }
    fun source(value: FileMountAccountSource) {
        if (_state.value.busy || value == _state.value.source || (_state.value.directories as? Loadable.Ready)?.value?.items?.none { it.source == value } != false) return
        _state.update { it.copy(source = value) }; search()
    }
    fun query(value: String) { if (!_state.value.busy) _state.update { it.copy(query = value) } }
    fun search() {
        if (_state.value.busy) return
        _state.update { it.copy(appliedQuery = it.query) }; reload()
    }
    fun bandwidthType(value: FileBandwidthOwner) {
        if (_state.value.busy || value == _state.value.bandwidthType) return
        _state.update { it.copy(bandwidthType = value, query = "", appliedQuery = "") }; reload()
    }
    fun more() {
        val repo = currentRepository() ?: return; if (_state.value.busy || _state.value.loadingMore) return
        _state.update { it.copy(loadingMore = true) }
        val generation = epoch; readJob = scope.launch { loadPage(repo, generation, true) }
    }
    private suspend fun loadPage(repo: DsmRepository, generation: Long, more: Boolean) {
        val value = _state.value
        _state.update { it.copy(loadingMore = more, nextPageFailure = null) }
        when (value.screen) {
            FileSettingsScreen.POLICY_ACCOUNTS -> {
                val old = (value.policyAccounts as? Loadable.Ready)?.value
                val result = captureLoadable { merge(old, more, { offset -> repo.fileSettings.reader.policyAccounts(value.accountKind, value.appliedQuery, offset) }, { it.id }) }
                if (current(repo, generation)) _state.update { it.copy(policyAccounts = if (more && result is Loadable.Failed) it.policyAccounts else result,
                    loadingMore = false, nextPageFailure = (result as? Loadable.Failed)?.error) }
            }
            FileSettingsScreen.MOUNT_ACCOUNTS -> {
                val old = (value.mountAccounts as? Loadable.Ready)?.value
                val result = captureLoadable { merge(old, more, { offset -> repo.fileSettings.reader.mountAccounts(value.source, value.accountKind, value.appliedQuery, offset) }, { it.id }) }
                if (current(repo, generation)) _state.update { it.copy(mountAccounts = if (more && result is Loadable.Failed) it.mountAccounts else result,
                    loadingMore = false, nextPageFailure = (result as? Loadable.Failed)?.error) }
            }
            FileSettingsScreen.BANDWIDTH -> {
                val old = (value.bandwidth as? Loadable.Ready)?.value
                val result = captureLoadable { merge(old, more, { offset -> repo.fileSettings.reader.bandwidth(value.bandwidthType, offset) }, { it.name }) }
                if (current(repo, generation)) _state.update { it.copy(bandwidth = if (more && result is Loadable.Failed) it.bandwidth else result,
                    loadingMore = false, nextPageFailure = (result as? Loadable.Failed)?.error) }
            }
            else -> _state.update { it.copy(loadingMore = false) }
        }
    }
    private suspend fun <T, K> merge(old: FileSettingsPage<T>?, more: Boolean, fetch: suspend (Int) -> FileSettingsPage<T>, key: (T) -> K): FileSettingsPage<T> {
        if (more && (old == null || old.nextOffset >= old.total)) throw settingsChanged()
        val page = fetch(if (more) old!!.nextOffset else 0)
        if (!more) return page
        if (page.total != old!!.total || page.items.any { row -> old.items.any { key(it) == key(row) } }) throw settingsChanged()
        return page.copy(items = old.items + page.items)
    }
    fun editMountAccount(row: FileMountAccount) {
        if (_state.value.busy || row !in (_state.value.mountAccounts as? Loadable.Ready)?.value?.items.orEmpty()) return
        readJob?.cancel(); epoch++
        _state.update { it.copy(screen = FileSettingsScreen.MOUNT_ACCOUNT, mountAccount = row, accountEnabled = row.enabled, outcome = null, failure = null) }
    }
    fun accountEnabled(enabled: Boolean) { if (canEdit() && _state.value.mountAccount?.canModify == true) _state.update { it.copy(accountEnabled = enabled, confirmation = null) } }
    fun editBandwidth(row: FileBandwidthEntry) {
        if (_state.value.busy || row !in (_state.value.bandwidth as? Loadable.Ready)?.value?.items.orEmpty()) return
        readJob?.cancel(); epoch++
        _state.update { it.copy(screen = FileSettingsScreen.BANDWIDTH_EDITOR, bandwidthBaseline = row, bandwidthDraft = row,
            rates = listOf(row.uploadLimit, row.downloadLimit, row.alternateUploadLimit, row.alternateDownloadLimit).map(Int::toString), outcome = null, failure = null) }
    }
    fun bandwidthDraft(change: (FileBandwidthEntry) -> FileBandwidthEntry) {
        if (canEdit()) _state.update { it.copy(bandwidthDraft = it.bandwidthDraft?.let(change), outcome = null, confirmation = null) }
    }
    fun rate(index: Int, value: String) {
        if (canEdit() && index in 0..3 && value.length <= 9 && value.all { it in '0'..'9' })
            _state.update { it.copy(rates = it.rates.mapIndexed { i, old -> if (i == index) value else old }, outcome = null, confirmation = null) }
    }
    fun currentChange(review: Boolean = false): FileSettingsChange? {
        val value = _state.value
        return when (value.screen) {
            FileSettingsScreen.THEME -> {
                val old = (value.theme as? Loadable.Ready)?.value ?: return null
                FileSettingsChange.Theme(old, if (review) old else value.themeDraft ?: return null)
            }
            FileSettingsScreen.GENERAL -> {
                val old = (value.general as? Loadable.Ready)?.value ?: return null
                FileSettingsChange.General(old, if (review) old else (value.generalDraft ?: return null).copy(defaultLinkLimit = value.linkLimit.toIntOrNull() ?: return null))
            }
            FileSettingsScreen.MOUNT_SCOPE -> FileSettingsChange.MountScope(currentRepository()?.owner ?: return null,
                (value.mountScope as? Loadable.Ready)?.value ?: return null, value.mountDraft ?: return null)
            FileSettingsScreen.MOUNT_ACCOUNT -> FileSettingsChange.MountAccount(value.mountAccount ?: return null, value.accountEnabled)
            FileSettingsScreen.BANDWIDTH_EDITOR -> {
                val old = value.bandwidthBaseline ?: return null
                val rates = value.rates.map { it.toIntOrNull() }
                FileSettingsChange.Bandwidth(old, if (review) old else (value.bandwidthDraft ?: return null).copy(uploadLimit = rates.getOrNull(0) ?: return null,
                    downloadLimit = rates.getOrNull(1) ?: return null, alternateUploadLimit = rates.getOrNull(2) ?: return null, alternateDownloadLimit = rates.getOrNull(3) ?: return null))
            }
            else -> null
        }
    }
    fun pendingCurrent(): Boolean = currentChange(true)?.let(::pendingFor) == true
    private fun pendingFor(change: FileSettingsChange) = _state.value.pending.any { it.kind == change.kind && it.target == change.target }
    private fun canWrite(change: FileSettingsChange) = currentRepository() != null && _state.value.recoveryReadable && !_state.value.busy && !pendingFor(change) &&
        (change !is FileSettingsChange.Theme || supportsTheme())
    fun canEdit() = currentChange(true)?.let(::canWrite) == true
    fun canSave() = currentChange()?.let { canWrite(it) && runCatching { it.parameters() }.isSuccess } == true
    fun prepareSave() {
        if (!canSave()) return
        val change = currentChange() ?: return
        _state.update { it.copy(confirmation = change, failure = null) }
        if (change.risks().isEmpty()) submit()
    }
    fun dismissConfirmation() { if (!_state.value.busy) _state.update { it.copy(confirmation = null) } }
    fun submit() {
        val repo = currentRepository() ?: return; val change = _state.value.confirmation ?: return
        if (!canSave() || change != currentChange() || workspace()?.isPerformingAction != false) return
        operate(repo) { repo.fileSettings.changeSettingsResult(change, true, change.risks().isNotEmpty()) }
    }
    fun review() {
        val repo = currentRepository() ?: return; val change = currentChange(true) ?: return
        if (_state.value.busy || !pendingFor(change) || workspace()?.isPerformingAction != false) return
        operate(repo) { repo.fileSettings.review(change) }
    }
    private fun operate(repo: DsmRepository, block: suspend () -> FileSettingsOutcome) {
        readJob?.cancel(); val generation = ++epoch
        _state.update { it.copy(busy = true, confirmation = null, failure = null, outcome = null) }; onBusy(true)
        scope.launch {
            var completed = false
            try {
                val result = block(); val records = repo.fileSettings.pending()
                completed = result.status == FileSettingsOutcomeStatus.COMPLETED
                if (current(repo, generation)) _state.update { it.copy(outcome = result, pending = records, recoveryReadable = true) }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                val records = captureLoadable { repo.fileSettings.pending() }
                if (current(repo, generation)) _state.update { it.copy(failure = error.asDsmFailure(), pending = (records as? Loadable.Ready)?.value.orEmpty(), recoveryReadable = records is Loadable.Ready) }
            } finally {
                if (current(repo, generation)) { _state.update { it.copy(busy = false) }; onBusy(false) }
            }
            if (completed && current(repo, generation)) {
                if (_state.value.screen in setOf(FileSettingsScreen.MOUNT_ACCOUNT, FileSettingsScreen.BANDWIDTH_EDITOR)) back() else reload()
            }
        }
    }
    fun back() {
        if (_state.value.busy) return
        readJob?.cancel(); epoch++
        when (_state.value.screen) {
            FileSettingsScreen.POLICY_ACCOUNTS -> _state.update { it.copy(screen = FileSettingsScreen.GENERAL, query = "", appliedQuery = "") }
            FileSettingsScreen.MOUNT_ACCOUNT -> { _state.update { it.copy(screen = FileSettingsScreen.MOUNT_ACCOUNTS) }; reload() }
            FileSettingsScreen.MOUNT_ACCOUNTS -> show(FileSettingsScreen.MOUNT_SCOPE)
            FileSettingsScreen.BANDWIDTH_EDITOR -> { _state.update { it.copy(screen = FileSettingsScreen.BANDWIDTH) }; reload() }
            FileSettingsScreen.ROOT -> close()
            else -> show(FileSettingsScreen.ROOT)
        }
    }
    fun authorizationChanged() { if (activeRepository != null && (repository() !== activeRepository || repository()?.filePermissionAccess != access ||
        _state.value.screen == FileSettingsScreen.THEME && workspace()?.availability?.allows(Module.NAS_SETTINGS) != true)) invalidate() }
    fun close() { if (!_state.value.busy) invalidate() }
    fun invalidate() {
        themePicker.invalidate()
        epoch++; readJob?.cancel()
        if (_state.value.busy && repository() === activeRepository) onBusy(false)
        activeRepository = null; _state.value = FileSettingsState()
    }
    private fun current(repo: DsmRepository, generation: Long) = currentRepository() === repo && epoch == generation
    private fun currentRepository(): DsmRepository? {
        val repo = activeRepository ?: return null; val current = workspace() ?: return null
        if (repository() !== repo || current.selectedModule != Module.FILES || !current.availability.allows(Module.FILES) || repo.filePermissionAccess != FilePermissionAccess(true, true)) return null
        return runCatching { repo.requireCurrentOwner(); repo }.getOrNull()
    }
}

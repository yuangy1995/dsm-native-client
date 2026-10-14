package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewModelScope
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceIdentityChanges
import java.util.UUID
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

internal enum class WorkspaceConnectionStatus { CONNECTED, CONNECTING, SIGN_IN, NEEDS_ATTENTION }
internal data class WorkspaceConnectionItem(val profile: NasProfile, val status: WorkspaceConnectionStatus, val selected: Boolean, val hasWorkspace: Boolean)
internal data class WorkspaceSelection(val key: String, val model: AppViewModel, val showConnectionForm: Boolean = false)

/** 每个连接只有一个领域模型，选择切换只改变前台所有者，不销毁其他会话和任务。 */
class WorkspaceHostModel(application: Application) : AndroidViewModel(application) {
    private val store = SecureProfileStore(application)
    private val crossNas by lazy { io.github.qwertyuiop1995.dsmnativeclient.data.files.CrossNasTransferStore(application) }
    private val entries = mutableListOf<OwnedWorkspace>()
    private var previousWorkspaceKey: String? = null
    private val initialProfile = store.profiles().let { profiles ->
        profiles.firstOrNull { it.id == store.lastProfileId() } ?: profiles.firstOrNull()
    }
    private val initialEntry = createEntry(initialProfile?.id)
    private val _active = MutableStateFlow(WorkspaceSelection(initialEntry.key, initialEntry.model))
    internal val active = _active.asStateFlow()
    private val _connections = MutableStateFlow<List<WorkspaceConnectionItem>>(emptyList())
    internal val connections = _connections.asStateFlow()
    internal val sharedInput = io.github.qwertyuiop1995.dsmnativeclient.systemfiles.SharedInputModel(
        viewModelScope, io.github.qwertyuiop1995.dsmnativeclient.systemfiles.SharedInputStore(application),
        io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore(application), store,
        source = { profileId -> entries.firstOrNull { it.profileId == profileId }?.model?.systemFileRepository() },
        connect = { profileId -> select(profileId) },
        enqueue = { profileId, records -> entries.firstOrNull { it.profileId == profileId }?.model?.enqueueSharedUploads(records) },
    )
    private val _pickerVisible = MutableStateFlow(false)
    internal val systemFiles = io.github.qwertyuiop1995.dsmnativeclient.systemfiles.SystemFileSettingsModel(
        viewModelScope, io.github.qwertyuiop1995.dsmnativeclient.systemfiles.SystemDocumentStore(application), store,
        source = { id -> entries.firstOrNull { it.profileId == id }?.model?.systemFileRepository() },
        connect = { id -> select(id) },
        changed = { io.github.qwertyuiop1995.dsmnativeclient.systemfiles.NasDocumentsProvider.changed(application.contentResolver, application.packageName) },
    )
    internal val pickerVisible = _pickerVisible.asStateFlow()
    private val _canReturn = MutableStateFlow(false)
    internal val canReturn = _canReturn.asStateFlow()

    private val liveTasks = MutableStateFlow<List<WorkspaceTaskSnapshot>>(emptyList())
    internal val taskCenter = GlobalTaskCenterModel(application, viewModelScope, liveTasks)
    internal val taskHistoryVisible = MutableStateFlow(false)
    internal val focusedTaskKey = MutableStateFlow<String?>(null)
    internal var taskHistoryToken: String? = null
        private set

    internal fun showTaskHistory(key: String? = null): Boolean {
        if (!active.value.model.canSwitchWorkspace()) return false
        taskHistoryToken = null
        focusedTaskKey.value = key
        taskHistoryVisible.value = true
        return true
    }
    internal fun clearTaskFocus() { focusedTaskKey.value = null; taskHistoryToken = null }
    internal fun closeTaskHistory() { taskHistoryVisible.value = false; focusedTaskKey.value = null; taskHistoryToken = null }

    internal fun taskModel(item: GlobalTransferItem): AppViewModel? = entries.firstOrNull {
        it.profileId == item.profileId && it.model.workspaceOwner?.let { owner ->
            item.owner?.hasSameIdentity(owner) == true
        } == true && it.model.workspace.value != null
    }?.model

    internal fun openTaskConnection(item: GlobalTransferItem) {
        if (!validTaskIdentity(item)) return
        if (select(item.profileId)) closeTaskHistory()
    }

    private fun validTaskIdentity(item: GlobalTransferItem): Boolean {
        val owner = item.owner ?: return false
        if (owner.profileId != item.profileId || store.profileForOwner(owner) == null) return false
        if (item.isCrossNas) return runCatching { crossNas.get(item.task.id) }.getOrNull()?.let {
            it.sourceOwner.hasSameIdentity(owner) && store.profileForOwner(it.targetOwner) != null
        } == true
        val recorded = store.recordOwner(item.kind, item.task.id)
        return recorded?.hasSameIdentity(owner) == true || recorded == null &&
            taskModel(item)?.workspace?.value?.transfers?.any { it.id == item.task.id && it.direction.recordKind() == item.kind } == true
    }

    internal fun clearFinishedTasks(items: List<GlobalTransferItem>) {
        if (items.any { !validTaskIdentity(it) || taskModel(it) == null }) return
        items.filterNot { it.isCrossNas }.mapNotNull(::taskModel).distinct().forEach { it.clearFinishedTransfers() }
        viewModelScope.launch(Dispatchers.IO) {
            items.filter { it.isCrossNas }.forEach { item ->
                runCatching { crossNas.get(item.task.id) }.getOrNull()?.takeIf {
                    it.isFinished
                }?.let { runCatching { crossNas.removeFinished(it) } }
            }
            taskCenter.retry()
        }
    }

    internal fun actOnTask(item: GlobalTransferItem, action: GlobalTransferAction) {
        if (!validTaskIdentity(item)) { taskCenter.retry(); return }
        if (item.isCrossNas) {
            if (action != GlobalTransferAction.OPEN_TARGET) return
            val model = taskModel(item) ?: run { openTaskConnection(item); return }
            if (active.value.model !== model && !select(item.profileId, attemptRestore = false)) return
            closeTaskHistory()
            if (model.navigateTo(io.github.qwertyuiop1995.dsmnativeclient.domain.WorkspaceRoute.ModuleRoot(
                    io.github.qwertyuiop1995.dsmnativeclient.domain.Module.TRANSFERS)) in setOf(WorkspaceNavigationResult.APPLIED, WorkspaceNavigationResult.ALREADY_SELECTED))
                model.crossNasTransfers.show(item.task.id)
            return
        }
        val local = action == GlobalTransferAction.PAUSE || action == GlobalTransferAction.CANCEL
        val model = taskModel(item) ?: if (local) {
            (entries.firstOrNull { it.profileId == item.profileId } ?: createEntry(item.profileId).also(::watch)).model
        } else { openTaskConnection(item); return }
        // 需要 NAS 的操作回到原账号，沿用该工作区的错误提示与恢复入口。
        if (!local && action != GlobalTransferAction.OPEN_TARGET) {
            if (active.value.model !== model && !select(item.profileId, attemptRestore = false)) return
            closeTaskHistory()
            if (model.navigateTo(io.github.qwertyuiop1995.dsmnativeclient.domain.WorkspaceRoute.ModuleRoot(
                    io.github.qwertyuiop1995.dsmnativeclient.domain.Module.TRANSFERS)) !in setOf(WorkspaceNavigationResult.APPLIED, WorkspaceNavigationResult.ALREADY_SELECTED)) return
        }
        when (action) {
            GlobalTransferAction.PAUSE -> model.pauseTransfer(item.task.id)
            GlobalTransferAction.RESUME -> model.resumeTransfer(item.task.id)
            GlobalTransferAction.CANCEL -> model.cancelTransfer(item.task.id)
            GlobalTransferAction.RETRY -> model.retryTransfer(item.task.id)
            GlobalTransferAction.OPEN_TARGET -> if (active.value.model === model || select(item.profileId, attemptRestore = false)) {
                closeTaskHistory()
                if (item.kind == WorkspaceRecordKind.VMM_IMPORT) model.navigateToVirtualMachineTasks()
                else if (item.kind == WorkspaceRecordKind.UPLOAD) model.openUploadTarget(item.task.id)
                else model.openAndRefreshFileServerTransferTarget(item.task.id)
            }
        }
    }

    init {
        watch(initialEntry)
        refreshConnections()
        viewModelScope.launch {
            workspaceIdentityChanges.collect {
                entries.forEach { it.model.refreshSavedProfiles() }
                refreshConnections()
                sharedInput.connectionChanged()
                systemFiles.connectionChanged()
            }
        }
    }

    private var initialRestoreAttempted = false
    internal fun restoreInitialConnection() {
        if (initialRestoreAttempted || taskHistoryVisible.value) return
        initialRestoreAttempted = true
        if (active.value.model !== initialEntry.model || initialEntry.model.workspace.value != null || initialEntry.model.login.value.isConnecting) return
        initialProfile?.takeIf { store.isAutoLoginEnabled(it.id) && !store.password(it.id).isNullOrEmpty() }
            ?.let { initialEntry.model.restore(it, store.password(it.id)) }
    }

    internal fun showPicker(): Boolean {
        if (!active.value.model.canSwitchWorkspace()) return false
        refreshConnections()
        _pickerVisible.value = true
        return true
    }

    internal fun dismissPicker() { _pickerVisible.value = false }

    internal suspend fun renameConnection(profile: NasProfile, name: String): Boolean =
        withContext(Dispatchers.IO) { store.renameProfile(profile, name) }.also { if (it) refreshConnections() }

    internal fun select(profileId: String, edit: Boolean = false, attemptRestore: Boolean = true): Boolean {
        val profile = store.profiles().firstOrNull { it.id == profileId } ?: run {
            active.value.model.reportConnectionUnavailable(); return false
        }
        val current = active.value.model
        if (!current.canSwitchWorkspace()) return false
        val target = entries.firstOrNull { it.profileId == profileId } ?: createEntry(profileId).also(::watch)
        if (edit && !target.model.returnToLogin()) return false
        rememberReturnWorkspace(target)
        activate(target, edit)
        target.model.refreshSavedProfiles()
        store.setLastProfileId(profileId)
        if (target.model.workspace.value == null) {
            target.model.selectProfile(profile)
            if (!edit && attemptRestore) target.model.restore(profile)
        }
        return true
    }

    internal fun newConnection(): Boolean {
        if (!active.value.model.canSwitchWorkspace()) return false
        val target = entries.firstOrNull { it.profileId == null } ?: createEntry(null).also(::watch)
        rememberReturnWorkspace(target)
        activate(target, showForm = true)
        target.model.newProfile()
        return true
    }

    internal fun returnToPreviousWorkspace(): Boolean {
        val target = entries.firstOrNull { it.key == previousWorkspaceKey && it.model.workspace.value != null } ?: return false
        active.value.model.cancelLogin()
        activate(target, showForm = false)
        previousWorkspaceKey = null
        _canReturn.value = false
        target.profileId?.let(store::setLastProfileId)
        return true
    }

    internal fun openLocalTransferTarget(token: String): Boolean? {
        val route = store.opaqueWorkspaceRoute(token) ?: return null
        val target = route.target as? io.github.qwertyuiop1995.dsmnativeclient.domain.OpaqueWorkspaceTarget.LocalTransfer ?: return null
        val owner = store.recordOwner(WorkspaceRecordKind.OPAQUE_ROUTE, token) ?: return false
        val kind = WorkspaceRecordKind.valueOf(target.kind.name)
        if (store.recordOwner(kind, target.id)?.hasSameIdentity(owner) != true) return false
        return showTaskHistory("${route.profileId}:${kind.name}:${target.id}").also { if (it) taskHistoryToken = token }
    }

    internal fun selectForOpaqueTarget(token: String): Boolean {
        val target = store.opaqueWorkspaceRoute(token) ?: run {
            active.value.model.reportConnectionUnavailable(); return false
        }
        return select(target.profileId).also { if (it) closeTaskHistory() }
    }

    internal fun removeConnection(profile: NasProfile) {
        val entry = entries.firstOrNull { it.profileId == profile.id } ?: createEntry(profile.id).also(::watch)
        if (!entry.model.canRemoveSavedConnection(profile.id)) {
            active.value.model.reportConnectionBusy()
            return
        }
        entry.model.removeProfile(profile)
        if (store.profiles().any { it.id == profile.id }) return
        val wasActive = active.value.key == entry.key
        entry.observer?.cancel(); entry.taskObserver?.cancel(); entry.models.clear(); entries.remove(entry)
        liveTasks.value = entries.mapNotNull { it.taskSnapshot }
        if (previousWorkspaceKey == entry.key) { previousWorkspaceKey = null; _canReturn.value = false }
        if (wasActive) {
            val remaining = store.profiles().firstOrNull()
            val next = entries.firstOrNull { it.profileId == remaining?.id }
                ?: createEntry(remaining?.id).also(::watch)
            activate(next, showForm = false)
        }
        refreshConnections()
    }

    internal fun signOut(profileId: String) {
        val entry = entries.firstOrNull { it.profileId == profileId } ?: return
        entry.model.logout()
        refreshConnections()
    }

    private fun rememberReturnWorkspace(target: OwnedWorkspace) {
        if (active.value.key != target.key && active.value.model.workspace.value != null) previousWorkspaceKey = active.value.key
        _canReturn.value = previousWorkspaceKey != null
    }

    private fun activate(target: OwnedWorkspace, showForm: Boolean) {
        if (active.value.model !== target.model) {
            active.value.model.setWorkspaceForeground(false)
            active.value.model.cancelLogin()
        }
        _active.value = WorkspaceSelection(target.key, target.model, showForm)
        _pickerVisible.value = false
        refreshConnections()
    }

    private fun createEntry(profileId: String?): OwnedWorkspace {
        val models = ViewModelStore()
        val model = ViewModelProvider(models, object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T =
                AppViewModel(getApplication(), profileId, restoreOnCreate = false, selectLastProfile = false) as T
        })[AppViewModel::class.java]
        val entry = OwnedWorkspace(UUID.randomUUID().toString(), profileId, model, models)
        model.onConnectionsRequested = ::showPicker
        model.onSystemFilesRequested = { systemFiles.show() }
        model.onSignInRequested = { entry.profileId?.let { select(it, edit = true) } ?: newConnection() }
        entries += entry
        return entry
    }

    private fun watch(entry: OwnedWorkspace) {
        entry.taskObserver = viewModelScope.launch {
            entry.model.workspace.map { state -> entry.model.workspaceOwner?.let { owner ->
                state?.let { WorkspaceTaskSnapshot(owner, it.transfers) }
            } }.distinctUntilChanged().collect { snapshot ->
                entry.taskSnapshot = snapshot
                liveTasks.value = entries.mapNotNull { it.taskSnapshot }
            }
        }
        entry.observer = viewModelScope.launch {
            combine(entry.model.login.map { it.isConnecting to it.error?.kind }.distinctUntilChanged(),
                entry.model.workspace.map { it?.profile?.id to it?.access }.distinctUntilChanged()) { _, workspace -> workspace }
                .collect { (profileId, _) ->
                    if (profileId != null) entry.profileId = profileId
                    refreshConnections()
                    sharedInput.connectionChanged()
                    systemFiles.connectionChanged()
                }
        }
    }

    private fun refreshConnections() {
        _connections.value = store.profiles().map { profile ->
            val entry = entries.firstOrNull { it.profileId == profile.id }
            val login = entry?.model?.login?.value
            val workspace = entry?.model?.workspace?.value
            val status = when {
                login?.isConnecting == true -> WorkspaceConnectionStatus.CONNECTING
                workspace?.access?.failure?.kind in setOf(DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.SAVED_SESSION_EXPIRED, DsmErrorKind.WORKSPACE_CHANGED) -> WorkspaceConnectionStatus.SIGN_IN
                workspace != null && workspace.access.failure != null -> WorkspaceConnectionStatus.NEEDS_ATTENTION
                workspace != null -> WorkspaceConnectionStatus.CONNECTED
                login?.error != null -> WorkspaceConnectionStatus.NEEDS_ATTENTION
                else -> WorkspaceConnectionStatus.SIGN_IN
            }
            WorkspaceConnectionItem(profile, status, entry?.key == active.value.key, workspace != null)
        }
    }

    override fun onCleared() {
        entries.forEach { it.observer?.cancel(); it.taskObserver?.cancel(); it.models.clear() }
        entries.clear()
        super.onCleared()
    }

    private data class OwnedWorkspace(val key: String, var profileId: String?, val model: AppViewModel,
        val models: ViewModelStore, var observer: Job? = null, var taskObserver: Job? = null,
        var taskSnapshot: WorkspaceTaskSnapshot? = null)
}

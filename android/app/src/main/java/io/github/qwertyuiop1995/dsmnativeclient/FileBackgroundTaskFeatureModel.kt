package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal enum class FileBackgroundTaskScreen { DETAIL, RECOVERY }
internal data class FileBackgroundTaskControlState(
    val screen: FileBackgroundTaskScreen? = null, val account: String = "", val taskId: String? = null,
    val detail: Loadable<FileBackgroundTaskSummary?> = Loadable.Idle,
    val pending: Loadable<List<FileBackgroundTaskPending>> = Loadable.Idle,
    val confirmation: FileBackgroundTaskAction? = null, val busy: Boolean = false,
    val completedAction: FileBackgroundTaskAction? = null, val failure: DsmFailure? = null,
    val fromRecovery: Boolean = false,
)

/** 与工作区共存的任务详情/恢复，不以列表刷新或任务消失猜测文件处理成功。 */
internal class FileBackgroundTaskFeatureModel(
    private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val workspace: () -> WorkspaceState?, private val onBusy: (Boolean) -> Unit,
    private val onChanged: () -> Unit,
) {
    private val _state = MutableStateFlow(FileBackgroundTaskControlState())
    val state = _state.asStateFlow()
    private var activeRepository: DsmRepository? = null
    private var readJob: Job? = null
    private var generation = 0L
    fun activate() {
        val repo = repository() ?: return
        if (workspace()?.selectedModule != Module.TRANSFERS || workspace()?.availability?.allows(Module.FILES) != true) return
        if (activeRepository === repo) return
        invalidate(); activeRepository = repo
        _state.update { it.copy(account = workspace()?.profile?.name.orEmpty()) }; reload()
    }
    fun open(task: FileBackgroundTaskSummary) {
        activate(); currentRepository() ?: return
        if (_state.value.busy || workspace()?.isPerformingAction == true ||
            task !in ((workspace()?.fileBackgroundTasks as? Loadable.Ready)?.value?.tasks.orEmpty())) return
        _state.update { it.copy(screen = FileBackgroundTaskScreen.DETAIL, taskId = task.id, detail = Loadable.Loading,
            confirmation = null, completedAction = null, failure = null, fromRecovery = false) }; reload()
    }
    fun openRecovery() {
        activate(); currentRepository() ?: return
        if (_state.value.busy) return
        _state.update { it.copy(screen = FileBackgroundTaskScreen.RECOVERY, taskId = null, confirmation = null,
            completedAction = null, failure = null, fromRecovery = false) }; reload()
    }
    fun open(record: FileBackgroundTaskPending) {
        currentRepository() ?: return
        if (_state.value.busy || record !in (_state.value.pending as? Loadable.Ready)?.value.orEmpty()) return
        _state.update { it.copy(screen = FileBackgroundTaskScreen.DETAIL, taskId = record.target.taskId, detail = Loadable.Loading,
            confirmation = null, completedAction = null, failure = null, fromRecovery = true) }; reload()
    }
    fun pendingCurrent() = (_state.value.pending as? Loadable.Ready)?.value?.singleOrNull { it.target.taskId == _state.value.taskId }
    fun canControl(action: FileBackgroundTaskAction): Boolean {
        val repo = currentRepository() ?: return false
        val state = _state.value; val task = (state.detail as? Loadable.Ready)?.value ?: return false
        return state.screen == FileBackgroundTaskScreen.DETAIL && !state.busy && workspace()?.isPerformingAction == false &&
            state.pending is Loadable.Ready && pendingCurrent() == null && repo.fileBackgroundTasks.canControl(task, action)
    }
    fun prepare(action: FileBackgroundTaskAction) {
        if (canControl(action)) _state.update { it.copy(confirmation = action, failure = null) }
    }
    fun dismissConfirmation() { _state.update { it.copy(confirmation = null) } }
    fun confirm() {
        val action = _state.value.confirmation ?: return
        val repo = currentRepository() ?: return
        if (!canControl(action)) return
        val task = (_state.value.detail as? Loadable.Ready)?.value ?: return
        readJob?.cancel(); val epoch = ++generation
        _state.update { it.copy(busy = true, confirmation = null, completedAction = null, failure = null) }; onBusy(true)
        scope.launch {
            try {
                val outcome = suspendRunCatching { repo.fileBackgroundTasks.controlBackgroundTaskResult(task, action, confirmed = true) }
                val pending = captureLoadable { repo.fileBackgroundTasks.pending() }
                val value = outcome.getOrNull()
                val detail = if (value?.status == FileBackgroundTaskOutcomeStatus.COMPLETED) Loadable.Ready(value.task)
                    else captureLoadable { repo.fileBackgroundTasks.reader.find(task.id) }
                if (currentRepository() === repo) onChanged()
                if (!current(repo, epoch)) return@launch
                _state.update { it.copy(busy = false, pending = pending, detail = detail,
                    completedAction = action.takeIf { value?.status == FileBackgroundTaskOutcomeStatus.COMPLETED },
                    failure = outcome.exceptionOrNull()?.asDsmFailure() ?: value?.failure) }
            } finally { if (repository() === repo) onBusy(false) }
        }
    }
    /** 刷新只读恢复已记录动作，不重发 stop/clear_finished。 */
    fun reload() {
        val repo = currentRepository() ?: return
        if (_state.value.busy) return
        readJob?.cancel(); val epoch = ++generation; val id = _state.value.taskId
        _state.update { it.copy(pending = Loadable.Loading, detail = if (id != null) Loadable.Loading else it.detail,
            confirmation = null, completedAction = null, failure = null) }
        readJob = scope.launch {
            var completed: FileBackgroundTaskAction? = null
            val pending = captureLoadable {
                val rows = repo.fileBackgroundTasks.pending()
                rows.singleOrNull { it.target.taskId == id }?.let { record ->
                    if (repo.fileBackgroundTasks.review(record).status == FileBackgroundTaskOutcomeStatus.COMPLETED) completed = record.action
                }
                repo.fileBackgroundTasks.pending()
            }
            val detail = if (id != null) captureLoadable { repo.fileBackgroundTasks.reader.find(id) } else Loadable.Idle
            if (!current(repo, epoch)) return@launch
            _state.update { it.copy(pending = pending, detail = detail, completedAction = completed ?: it.completedAction) }
            if (completed != null) onChanged()
        }
    }
    fun back() {
        if (_state.value.busy) return
        readJob?.cancel(); generation++
        if (_state.value.fromRecovery) {
            _state.update { it.copy(screen = FileBackgroundTaskScreen.RECOVERY, taskId = null, confirmation = null,
                detail = Loadable.Idle, fromRecovery = false, completedAction = null, failure = null) }; reload()
        } else _state.update { it.copy(screen = null, taskId = null, confirmation = null, detail = Loadable.Idle,
            completedAction = null, failure = null) }
    }
    fun authorizationChanged() {
        if (activeRepository != null && (repository() !== activeRepository || repository()?.filePermissionAccess?.granted != true)) invalidate()
    }
    fun invalidate() { generation++; readJob?.cancel(); activeRepository = null; _state.value = FileBackgroundTaskControlState() }
    private fun current(repo: DsmRepository, epoch: Long) = currentRepository() === repo && generation == epoch
    private fun currentRepository(): DsmRepository? {
        val repo = activeRepository ?: return null
        val current = workspace() ?: return null
        if (repository() !== repo || current.selectedModule != Module.TRANSFERS || !current.availability.allows(Module.FILES)) return null
        return runCatching { repo.requireCurrentOwner(); repo.takeIf { it.filePermissionAccess.granted } }.getOrNull()
    }
}

package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class NasObservationState(val logs: NasLogPage? = null, val logsLoading: Boolean = false,
    val logsFailure: Exception? = null, val selectedLog: NasLogItem? = null, val processes: NasProcessDirectory? = null,
    val processesLoading: Boolean = false, val processesFailure: Exception? = null)
/** 两个只读页面各自取消请求；账号变更和离开日志页不保留正文。 */
internal class NasObservationModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val mutable = MutableStateFlow(NasObservationState()); val state = mutable.asStateFlow()
    private val lock = Any(); private var bound: DsmRepository? = null
    private var logsJob: Job? = null; private var processesJob: Job? = null
    private var logsVersion = 0L; private var processesVersion = 0L
    private var requestedOffset = 0; private var requestedLimit = 100
    private fun source(): DsmRepository? = synchronized(lock) {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo }
        repo.requireCurrentOwner(); repo
    }
    fun clear() = synchronized(lock) {
        logsVersion++; processesVersion++; logsJob?.cancel(); processesJob?.cancel(); logsJob = null; processesJob = null
        requestedOffset = 0; requestedLimit = 100
        bound = null; mutable.value = NasObservationState()
    }
    fun logs(offset: Int? = null, limit: Int? = null) {
        val repo = source() ?: return
        synchronized(lock) {
            val targetOffset = offset ?: state.value.logs?.offset ?: 0
            val targetLimit = limit ?: state.value.logs?.limit ?: 100
            requestedOffset = targetOffset; requestedLimit = targetLimit
            val version = ++logsVersion; logsJob?.cancel()
            mutable.update { it.copy(logsLoading = true, logsFailure = null, selectedLog = null) }
            logsJob = scope.launch(dispatcher) {
                try {
                    val value = repo.nasObservation.logs(targetOffset, targetLimit)
                    synchronized(lock) { if (current(repo) && version == logsVersion) mutable.update { it.copy(logs = value, logsLoading = false) } }
                } catch (error: Exception) {
                    if (error is CancellationException) throw error
                    synchronized(lock) { if (current(repo) && version == logsVersion) mutable.update { it.copy(logsLoading = false, logsFailure = error) } }
                }
            }
        }
    }
    fun retryLogs() { source() ?: return; logs(requestedOffset, requestedLimit) }
    fun inspectLog(value: NasLogItem) { source() ?: return; if (state.value.logs?.entries?.contains(value) == true) mutable.update { it.copy(selectedLog = value) } }
    fun closeLog() { mutable.update { it.copy(selectedLog = null) } }
    fun leaveLogs() = synchronized(lock) {
        logsVersion++; logsJob?.cancel(); logsJob = null
        mutable.update { it.copy(logs = null, selectedLog = null, logsLoading = false, logsFailure = null) }
    }
    fun processes() {
        val repo = source() ?: return
        synchronized(lock) {
            val version = ++processesVersion; processesJob?.cancel()
            mutable.update { it.copy(processesLoading = true, processesFailure = null) }
            processesJob = scope.launch(dispatcher) {
                try {
                    val value = repo.nasObservation.processes()
                    synchronized(lock) { if (current(repo) && version == processesVersion) mutable.update { it.copy(processes = value, processesLoading = false) } }
                } catch (error: Exception) {
                    if (error is CancellationException) throw error
                    synchronized(lock) { if (current(repo) && version == processesVersion) mutable.update { it.copy(processesLoading = false, processesFailure = error) } }
                }
            }
        }
    }
    fun leaveProcesses() = synchronized(lock) {
        processesVersion++; processesJob?.cancel(); processesJob = null
        mutable.update { it.copy(processes = null, processesLoading = false, processesFailure = null) }
    }
    private fun current(repo: DsmRepository) = bound === repo && repository() === repo
}

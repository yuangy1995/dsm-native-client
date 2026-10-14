package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

internal class DsmFileBackgroundTaskRepository(
    private val supports: (String, Int) -> Boolean,
    private val call: suspend (String, String, Map<String, String>, Int) -> JsonObject,
    private val access: () -> FilePermissionAccess, private val refreshAccess: suspend () -> Unit,
    private val owner: () -> WorkspaceOwner?, private val requireOwner: () -> Unit,
) {
    val reader = FileBackgroundTaskReader(::request)
    private var store: FileBackgroundTaskRecoveryStore? = null
    private val active = mutableSetOf<String>()
    fun bindRecovery(value: FileBackgroundTaskRecoveryStore) { store = value }
    fun canControl(task: FileBackgroundTaskSummary, action: FileBackgroundTaskAction): Boolean {
        if (!access().granted || task.identity() == null || !supports(FILE_BACKGROUND_API, 3)) return false
        return when (action) {
            FileBackgroundTaskAction.CLEAR -> task.state == FileBackgroundTaskState.FINISHED
            FileBackgroundTaskAction.STOP -> task.state == FileBackgroundTaskState.ACTIVE &&
                task.apiVersion == task.kind.taskAPI.second && supports(task.kind.taskAPI.first, task.kind.taskAPI.second)
        }
    }
    suspend fun pending(): List<FileBackgroundTaskPending> = withContext(Dispatchers.IO) {
        requireOwner(); (store ?: throw workspaceStorageFailure()).pending(owner() ?: throw workspaceStorageFailure())
    }
    suspend fun controlBackgroundTaskResult(task: FileBackgroundTaskSummary, action: FileBackgroundTaskAction, confirmed: Boolean): FileBackgroundTaskOutcome = locked(task.id) {
        if (!confirmed) throw backgroundTaskChanged()
        requireCurrentAccess(); refreshAccess(); requireCurrentAccess()
        if (!canControl(task, action)) throw backgroundTaskChanged()
        if (pending().any { it.target.taskId == task.id }) throw backgroundTaskPending()
        val identity = task.identity() ?: throw backgroundTaskChanged()
        val fresh = reader.find(task.id)
        if (fresh == null || !identity.matches(fresh) || fresh.state != task.state) throw backgroundTaskChanged()
        refreshAccess(); requireCurrentAccess()
        if (!canControl(fresh, action)) throw backgroundTaskChanged()
        val api = if (action == FileBackgroundTaskAction.CLEAR) FILE_BACKGROUND_API to 3 else task.kind.taskAPI
        var record = FileBackgroundTaskPending(owner = owner() ?: throw workspaceStorageFailure(), target = identity, action = action)
        persist { it.begin(record) }
        var sent = false
        try {
            currentCoroutineContext().ensureActive(); requireCurrentAccess()
            sent = true
            request(api.first, if (action == FileBackgroundTaskAction.CLEAR) "clear_finished" else "stop",
                mapOf("taskid" to if (action == FileBackgroundTaskAction.CLEAR) JsonArray(listOf(JsonPrimitive(task.id))).toString() else task.id), api.second)
        } catch (error: Exception) {
            if (!sent) withContext(NonCancellable) { persist { it.replace(record, null) } }
            if (error is CancellationException) throw error
            if (!sent || error is DsmFailure && definiteRejection(error)) {
                if (sent) persist { it.replace(record, null) }
                return@locked FileBackgroundTaskOutcome(FileBackgroundTaskOutcomeStatus.REJECTED, failure = error as? DsmFailure ?: backgroundTaskChanged())
            }
            return@locked reviewCore(record)
        }
        val acknowledged = record.copy(acknowledged = true)
        persist { it.replace(record, acknowledged) }; record = acknowledged
        reviewCore(record)
    }
    suspend fun review(record: FileBackgroundTaskPending): FileBackgroundTaskOutcome = locked(record.target.taskId) {
        if (owner()?.hasSameIdentity(record.owner) != true) throw backgroundTaskChanged()
        reviewCore(record)
    }
    private suspend fun reviewCore(record: FileBackgroundTaskPending): FileBackgroundTaskOutcome {
        var current: FileBackgroundTaskSummary? = null
        val completed = try {
            if (pending().singleOrNull { it.id == record.id } != record) throw backgroundTaskChanged()
            current = reader.find(record.target.taskId)
            if (record.action == FileBackgroundTaskAction.CLEAR) current == null else
                current?.let { record.target.matches(it) && it.state == FileBackgroundTaskState.FINISHED } == true
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            false
        }
        requireOwner()
        if (completed) persist { it.replace(record, null) }
        return FileBackgroundTaskOutcome(if (completed) FileBackgroundTaskOutcomeStatus.COMPLETED else FileBackgroundTaskOutcomeStatus.UNKNOWN, current)
    }
    private suspend fun request(api: String, method: String, fields: Map<String, String>, version: Int): JsonObject {
        requireCurrentAccess()
        if (!supports(api, version)) throw DsmFailure(null, "Task action is unavailable", "Refresh the NAS tasks and try again.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
        val result = call(api, method, fields, version)
        if (method == "list") requireCurrentAccess()
        return result
    }
    private fun requireCurrentAccess() { requireOwner(); if (!access().granted) throw permissionDenied() }
    private suspend fun persist(action: (FileBackgroundTaskRecoveryStore) -> Unit) = withContext(Dispatchers.IO) { action(store ?: throw workspaceStorageFailure()) }
    private suspend fun <T> locked(id: String, block: suspend () -> T): T {
        requireOwner()
        synchronized(active) { if (!active.add(id)) throw backgroundTaskPending() }
        try { return block() } finally { synchronized(active) { active.remove(id) } }
    }
    private fun definiteRejection(error: DsmFailure) = error.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.AUTHENTICATION_FAILED,
        DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.FEATURE_UNSUPPORTED, DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED)
}

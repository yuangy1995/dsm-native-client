package io.github.qwertyuiop1995.dsmnativeclient.background

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

internal enum class WorkspaceExecutionActivity(val title: Int, val page: WorkspacePage) {
    PHOTO_UPLOAD(R.string.execution_photo_upload, WorkspacePage.PHOTOS),
    PHOTO_EXPORT(R.string.execution_photo_export, WorkspacePage.PHOTOS),
    CROSS_NAS(R.string.execution_cross_nas, WorkspacePage.TRANSFERS),
    OFFICE_PREPARE(R.string.execution_office_prepare, WorkspacePage.FILES),
    OFFICE_SAVE(R.string.execution_office_save, WorkspacePage.FILES),
}
internal interface WorkspaceExecutionLease {
    fun update(completed: Long, total: Long)
    fun finish()
}
internal fun interface WorkspaceExecution {
    suspend fun begin(owner: WorkspaceOwner, activity: WorkspaceExecutionActivity): WorkspaceExecutionLease
}
internal data class WorkspaceExecutionEntry(val id: String = UUID.randomUUID().toString(), val activity: WorkspaceExecutionActivity,
    val route: String, val caller: Job, val ready: CompletableDeferred<Unit> = CompletableDeferred(), val completed: Long = 0, val total: Long = 0)

/** 只描述本进程正在执行的协程；冷启动没有可重放的操作，持久恢复仍属于各领域记录。 */
internal class WorkspaceExecutionRegistry {
    private val mutable = MutableStateFlow<List<WorkspaceExecutionEntry>>(emptyList())
    val entries = mutable.asStateFlow()
    @Synchronized fun add(entry: WorkspaceExecutionEntry) { check(mutable.value.none { it.id == entry.id }); mutable.value += entry }
    @Synchronized fun started(id: String) { mutable.value.firstOrNull { it.id == id }?.ready?.complete(Unit) }
    @Synchronized fun failed(id: String, error: Throwable) { mutable.value.firstOrNull { it.id == id }?.ready?.completeExceptionally(error); finish(id) }
    @Synchronized fun update(id: String, done: Long, total: Long) {
        mutable.value = mutable.value.map { if (it.id == id) it.copy(completed = done.coerceAtLeast(0), total = total.coerceAtLeast(0)) else it }
    }
    @Synchronized fun cancel(id: String) { mutable.value.firstOrNull { it.id == id }?.caller?.cancel() }
    @Synchronized fun finish(id: String) { mutable.value = mutable.value.filterNot { it.id == id } }
    companion object { val shared = WorkspaceExecutionRegistry() }
}

internal class AndroidWorkspaceExecution(context: Context) : WorkspaceExecution {
    private val context = context.applicationContext
    override suspend fun begin(owner: WorkspaceOwner, activity: WorkspaceExecutionActivity): WorkspaceExecutionLease {
        val caller = currentCoroutineContext().job
        val route = withContext(Dispatchers.IO) {
            SecureProfileStore(context).issueOpaqueWorkspaceTarget(owner.profileId, OpaqueWorkspaceTarget.Page(activity.page), owner)
                ?: throw workspaceChangedFailure()
        }
        val registry = WorkspaceExecutionRegistry.shared
        val entry = WorkspaceExecutionEntry(activity = activity, route = route, caller = caller)
        registry.add(entry)
        try {
            ContextCompat.startForegroundService(context, Intent(context, WorkspaceExecutionService::class.java).putExtra(WorkspaceExecutionService.KEY, entry.id))
            withTimeout(10_000) { entry.ready.await() }
            caller.ensureActive()
        } catch (error: Exception) {
            registry.finish(entry.id)
            if (error is CancellationException && error !is TimeoutCancellationException) throw error
            throw unavailableExecution()
        }
        return object : WorkspaceExecutionLease {
            private var lastUpdate = 0L
            override fun update(completed: Long, total: Long) {
                val now = android.os.SystemClock.elapsedRealtime()
                if (now - lastUpdate >= 500 || total > 0 && completed >= total) {
                    lastUpdate = now; registry.update(entry.id, completed, total)
                }
            }
            override fun finish() = registry.finish(entry.id)
        }
    }
}
internal fun unavailableExecution() = DsmFailure(null, "Background execution is unavailable", "Return to the app and try again.", kind = DsmErrorKind.BACKGROUND_EXECUTION_UNAVAILABLE)

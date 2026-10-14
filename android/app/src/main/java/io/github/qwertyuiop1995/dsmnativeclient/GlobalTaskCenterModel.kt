package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class WorkspaceTaskSnapshot(val owner: WorkspaceOwner, val tasks: List<TransferTask>)
internal data class GlobalTransferItem(
    val profileId: String, val kind: WorkspaceRecordKind, val owner: WorkspaceOwner?,
    val profile: NasProfile?, val task: TransferTask,
    val canPause: Boolean = false, val canResume: Boolean = false, val canRetry: Boolean = false,
    val crossNas: CrossNasTransferRecord? = null, val isCrossNas: Boolean = crossNas != null,
) {
    val key: String get() = if (isCrossNas) "cross-nas:${task.id}" else "$profileId:${kind.name}:${task.id}"
}
internal enum class GlobalTransferAction { PAUSE, RESUME, CANCEL, RETRY, OPEN_TARGET }

/** 仅合并本机记录和已经打开的工作区；不恢复连接，也不轮询其他 NAS。 */
@OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
internal class GlobalTaskCenterModel(
    private val context: Context, scope: CoroutineScope,
    live: StateFlow<List<WorkspaceTaskSnapshot>>,
    private val store: SecureProfileStore = SecureProfileStore(context),
    private val transfers: TransferStore = TransferStore(context),
    private val crossNas: CrossNasTransferStore = CrossNasTransferStore(context),
) {
    private val presentation = TransferTaskPresentation(context)
    private val refresh = MutableStateFlow(0L)
    val state = combine(transferChanges.debounce(100), workspaceIdentityChanges, live.debounce(100), refresh, crossNasTransferChanges.debounce(100)) { _, _, snapshots, _, _ -> snapshots }
        .mapLatest { snapshots -> withContext(Dispatchers.IO) {
            try {
                Loadable.Ready(read(snapshots)) as Loadable<List<GlobalTransferItem>>
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { Loadable.Failed(workspaceStorageFailure()) }
        } }.stateIn(scope, SharingStarted.WhileSubscribed(5_000), Loadable.Loading)

    fun retry() { refresh.update { it + 1 } }

    private fun read(live: List<WorkspaceTaskSnapshot>): List<GlobalTransferItem> {
        val snapshot = transfers.snapshot()
        val items = linkedMapOf<String, GlobalTransferItem>()
        fun add(profileId: String, kind: WorkspaceRecordKind, task: TransferTask, liveOwner: WorkspaceOwner? = null,
            canPause: Boolean = false, canResume: Boolean = false, canRetry: Boolean = false) {
            val owner = store.recordOwner(kind, task.id) ?: liveOwner
            val profile = owner?.takeIf { it.profileId == profileId }?.let(store::profileForOwner)
            val visible = if (profile != null) task else TransferTask(task.id, context.getString(R.string.task_original_connection_unavailable),
                context.getString(R.string.task_original_connection_changed),
                task.direction, if (task.state in setOf(TransferState.SUCCEEDED, TransferState.FAILED, TransferState.CANCELLED)) task.state else TransferState.PAUSED,
                requiresRefresh = task.requiresRefresh, canCancel = false)
            val item = GlobalTransferItem(profileId, kind, owner, profile, visible, canPause, canResume, canRetry)
            items[item.key] = item
        }
        snapshot.downloads.forEach { add(it.profileId, WorkspaceRecordKind.DOWNLOAD, presentation.download(it), canPause = it.canPauseDownload(), canResume = it.canResumeDownload(),
            canRetry = it.canRetryDownload()) }
        snapshot.uploads.forEach { add(it.profileId, WorkspaceRecordKind.UPLOAD, presentation.upload(it),
            canRetry = it.state in setOf(TransferState.FAILED, TransferState.CANCELLED) ||
                it.state == TransferState.PAUSED && transfers.hasFolderUploadPlan(it.id)) }
        snapshot.servers.forEach { value -> presentation.server(value)?.let { add(value.profileId, WorkspaceRecordKind.SERVER, it) } }
        snapshot.imports.forEach { add(it.profileId, WorkspaceRecordKind.VMM_IMPORT, presentation.imageImport(it)) }
        live.forEach { workspace ->
            if (runCatching { store.requireCurrentOwner(workspace.owner) }.isSuccess) workspace.tasks.forEach { task ->
                val kind = task.direction.recordKind()
                val previous = items["${workspace.owner.profileId}:${kind.name}:${task.id}"]
                // 持久任务以 Worker 的最新事实为准，前台专属任务才取工作区进度。
                if (previous == null) add(workspace.owner.profileId, kind, task, workspace.owner)
            }
        }
        crossNas.allRecords().asReversed().forEach { row ->
            val profile = store.profileForOwner(row.sourceOwner)
            val destination = store.profileForOwner(row.targetOwner)
            val visible = profile != null && destination != null
            val task = TransferTask(row.id,
                if (visible) context.getString(R.string.cross_nas_route,
                    io.github.qwertyuiop1995.dsmnativeclient.ui.connectionConfirmationName(context, profile, listOf(profile, destination)),
                    io.github.qwertyuiop1995.dsmnativeclient.ui.connectionConfirmationName(context, destination, listOf(profile, destination)))
                else context.getString(R.string.task_original_connection_unavailable),
                if (visible) context.getString(io.github.qwertyuiop1995.dsmnativeclient.ui.crossNasPhaseLabel(row))
                else context.getString(R.string.task_original_connection_changed), TransferDirection.SERVER,
                when (row.phase) {
                    CrossNasPhase.FINISHED, CrossNasPhase.KEPT -> TransferState.SUCCEEDED
                    CrossNasPhase.COPYING, CrossNasPhase.REMOVING -> if (visible) TransferState.RUNNING else TransferState.PAUSED
                    else -> TransferState.PAUSED
                }, canCancel = false)
            val item = GlobalTransferItem(row.sourceOwner.profileId, WorkspaceRecordKind.SERVER, row.sourceOwner,
                profile.takeIf { visible }, task, crossNas = row.takeIf { visible }, isCrossNas = true)
            // 身份失效仍保留不含路径/名称的历史占位；稳定 key 不依赖可展示的清单。
            items["cross-nas:${row.id}"] = item
        }
        return items.values.toList().asReversed()
    }
}

internal fun TransferDirection.recordKind(): WorkspaceRecordKind = when (this) {
    TransferDirection.DOWNLOAD -> WorkspaceRecordKind.DOWNLOAD
    TransferDirection.UPLOAD -> WorkspaceRecordKind.UPLOAD
    TransferDirection.SERVER -> WorkspaceRecordKind.SERVER
}

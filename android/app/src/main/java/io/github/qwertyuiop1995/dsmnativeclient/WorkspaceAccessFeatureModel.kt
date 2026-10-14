package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

/** 前台与手动读取共用一个任务；回写必须仍属于原仓储，退出后不发布旧账号结果。 */
internal class WorkspaceAccessFeatureModel(
    private val scope: CoroutineScope,
    private val workspace: MutableStateFlow<WorkspaceState?>,
    private val repository: () -> DsmRepository?,
    private val onRevoked: (Set<Module>, WorkspaceState) -> Unit,
    private val onReload: (Module) -> Unit,
    private val onBackground: () -> Unit,
) {
    private var refreshJob: Job? = null
    private var refreshRepository: DsmRepository? = null
    private var reloadModule: Module? = null
    private var enteredForeground = false
    private var foreground = false
    private var failureObserver: Job? = null
    private var identityObserver: Job? = null

    fun reset() {
        refreshJob?.cancel(); refreshJob = null; refreshRepository = null; reloadModule = null
        enteredForeground = false; foreground = false
        failureObserver?.cancel()
        identityObserver?.cancel()
        val owner = repository() ?: return
        identityObserver = scope.launch {
            io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceIdentityChanges.collect {
                if (repository() !== owner) return@collect
                val before = workspace.value ?: return@collect
                val failure = runCatching { owner.requireCurrentOwner() }.exceptionOrNull() ?: return@collect
                refreshJob?.cancel(); refreshJob = null; reloadModule = null
                onRevoked(Module.entries.filterTo(mutableSetOf()) { it != Module.SETTINGS && it != Module.TRANSFERS }, before)
                workspace.update { current -> current?.takeIf { repository() === owner }?.copy(
                    availability = owner.availability(), access = WorkspaceAccessUiState(failure = failure.asDsmFailure()),
                ) ?: current }
            }
        }
        failureObserver = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            owner.accessFailures.collect {
                // 对象级拒绝仅触发重新读取，不能直接撤销整个模块，更不能重放失败的写操作。
                if (repository() === owner) refresh()
            }
        }
    }

    fun setForeground(value: Boolean) {
        if (foreground == value) return
        foreground = value
        if (!value) { reloadModule = null; onBackground(); return }
        // 登录和恢复已读取权限，第一次显示不立即再读一次。
        if (enteredForeground) refresh(workspace.value?.selectedModule)
        enteredForeground = true
    }

    fun refresh(reload: Module? = null) {
        val owner = repository() ?: return
        if (refreshJob?.isActive == true && refreshRepository === owner) {
            if (reload != null) reloadModule = reload
            return
        }
        refreshJob?.cancel()
        refreshRepository = owner
        reloadModule = reload
        workspace.update { it?.copy(access = WorkspaceAccessUiState(refreshing = true)) }
        refreshJob = scope.launch {
            val before = workspace.value ?: return@launch
            val outcome = suspendRunCatching { owner.refreshAccess() }
            if (repository() !== owner) return@launch
            val next = owner.availability()
            onRevoked(Module.entries.filterTo(mutableSetOf()) { before.availability.allows(it) && !next.allows(it) }, before)
            workspace.update { current ->
                current?.takeIf { repository() === owner }?.copy(
                    availability = next,
                    access = WorkspaceAccessUiState(failure = outcome.exceptionOrNull()?.asDsmFailure()),
                ) ?: current
            }
            val target = reloadModule
            reloadModule = null
            if (target != null && next.allows(target)) onReload(target)
        }
    }
}

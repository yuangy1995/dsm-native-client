package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** NAS 管理读取的唯一生命周期所有者：持有互斥边界、代次与当前加载 Job。 */
internal class NasAdministrationFeatureModel(
    private val scope: CoroutineScope,
    private val workspace: MutableStateFlow<WorkspaceState?>,
    private val repositoryProvider: () -> DsmRepository?,
) {
    private val settingsLoadController = NasSettingsLoadController()

    /** NAS 写操作与设置刷新共用的同步边界，避免旧回调跨资料覆盖。 */
    val mutationLock: Any
        get() = settingsLoadController.mutationLock

    /** 保持既有回调比对语义；代次本身由本特性模型唯一持有。 */
    val settingsRequestGeneration: AtomicLong
        get() = settingsLoadController.requestGeneration

    fun loadSettings(repository: DsmRepository) {
        val requestedProfileId = workspace.value?.profile?.id ?: return
        var previousSnapshot: NasSettingsSnapshot? = null
        settingsLoadController.start(
            scope = scope,
            profileId = requestedProfileId,
            onStart = { token ->
                val current = workspace.value ?: return@start false
                if (current.profile.id != token.profileId || current.isPerformingAction) return@start false
                previousSnapshot = (current.nasSettings as? Loadable.Ready)?.value
                workspace.value = current.copy(
                    nasSettings = Loadable.Loading,
                    diskTestStatuses = diskTestStatusesWithoutPendingLoads(current.diskTestStatuses),
                )
                true
            },
            load = { repository.nasSettings() },
            onResult = { token, value ->
                workspace.update { current ->
                    current?.takeIf {
                        repositoryProvider() === repository && it.profile.id == token.profileId &&
                            settingsRequestGeneration.get() == token.generation
                    }?.copy(
                        nasSettings = value,
                        diskTestStatuses = if (value is Loadable.Ready) {
                            reconciledDiskTestStatusesAfterSettingsRefresh(
                                previousSnapshot,
                                value.value,
                                current.diskTestStatuses,
                            )
                        } else current.diskTestStatuses,
                        fileServiceMutationRefreshCompleted =
                            value is Loadable.Ready && value.value.fileServiceSettings != null &&
                                current.fileServiceMutationResult != null,
                        terminalMutationRefreshCompleted =
                            value is Loadable.Ready && value.value.terminalSettings != null &&
                                current.terminalMutationResult != null,
                        proxyMutationRefreshCompleted =
                            value is Loadable.Ready && value.value.proxySettings != null &&
                                current.proxyMutationResult != null,
                        regionMutationRefreshCompleted =
                            value is Loadable.Ready && value.value.regionSettings != null &&
                                current.regionMutationResult != null,
                        remoteAccessState = current.remoteAccessState.copy(
                            mutationRefreshCompleted =
                                value is Loadable.Ready && value.value.remoteAccessSettingsAvailable &&
                                    (current.remoteAccessMutationResult != null ||
                                        current.remoteAccessMutationFailure != null) &&
                                    remoteAccessMutationRefreshIsComplete(
                                        current.remoteAccessSettingsBaseline,
                                        current.remoteAccessSettingsDraft,
                                        value.value.remoteAccessSettings,
                                    ),
                            mutationRefreshFailure = if (
                                value is Loadable.Ready && value.value.remoteAccessSettingsAvailable &&
                                value.value.remoteAccessSettings != null
                            ) null else current.remoteAccessMutationRefreshFailure,
                        ),
                    ) ?: current
                }
            },
        )
    }

    fun clearForProfileSwitch() {
        settingsLoadController.invalidate()
    }
}

internal data class NasSettingsLoadToken(
    val profileId: String,
    val generation: Long,
)

/**
 * 用于 NAS 设置读取的可测试取消边界。普通失败由 [captureLoadable] 映射，取消继续向上传播，
 * 且取消或过期的 Job 不得发布任何结果。
 */
internal class NasSettingsLoadController {
    internal val mutationLock = Any()
    internal val requestGeneration = AtomicLong(0)
    private var activeJob: Job? = null

    fun <T> start(
        scope: CoroutineScope,
        profileId: String,
        onStart: (NasSettingsLoadToken) -> Boolean,
        load: suspend () -> T,
        onResult: (NasSettingsLoadToken, Loadable<T>) -> Unit,
    ): Job? {
        val token = synchronized(mutationLock) {
            val candidate = NasSettingsLoadToken(profileId, requestGeneration.get() + 1)
            if (!onStart(candidate)) return@synchronized null
            requestGeneration.set(candidate.generation)
            candidate
        } ?: return null

        val job = scope.launch(start = kotlinx.coroutines.CoroutineStart.LAZY) {
            val result = captureLoadable(load)
            synchronized(mutationLock) {
                if (requestGeneration.get() == token.generation) onResult(token, result)
            }
        }
        val replaced = synchronized(mutationLock) {
            if (requestGeneration.get() != token.generation) {
                job.cancel()
                return@synchronized null
            }
            activeJob.also { activeJob = job }
        }
        replaced?.cancel()
        job.invokeOnCompletion {
            synchronized(mutationLock) {
                if (activeJob === job) activeJob = null
            }
        }
        job.start()
        return job
    }

    fun invalidate() {
        val job = synchronized(mutationLock) {
            requestGeneration.incrementAndGet()
            activeJob.also { activeJob = null }
        }
        job?.cancel()
    }
}

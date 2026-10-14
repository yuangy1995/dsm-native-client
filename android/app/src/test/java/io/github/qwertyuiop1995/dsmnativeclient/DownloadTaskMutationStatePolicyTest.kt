package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskMutationAction
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadTaskMutationStatePolicyTest {
    @Test
    fun `四种状态操作映射正式Repository枚举且仅删除文件操作携带扩展语义`() {
        assertEquals(DownloadTaskMutationAction.PAUSE, DownloadControlOperation.PAUSE.repositoryAction)
        assertEquals(DownloadTaskMutationAction.RESUME, DownloadControlOperation.RESUME.repositoryAction)
        assertEquals(
            DownloadTaskMutationAction.REMOVE_TASK,
            DownloadControlOperation.DELETE_TASK.repositoryAction,
        )
        assertEquals(
            DownloadTaskMutationAction.END_TASK_AND_MOVE_FILES,
            DownloadControlOperation.END_TASK_AND_MOVE_FILES.repositoryAction,
        )
        assertFalse(DownloadControlOperation.PAUSE.isDeletion)
        assertTrue(DownloadControlOperation.END_TASK_AND_MOVE_FILES.isDeletion)
    }

    @Test
    fun `目标规范化ID并绑定当前profile和完整canonical baseline`() {
        val source = task(id = " task-1 ", title = "下载项")
        val target = downloadControlTarget(
            "profile-a",
            Loadable.Ready(listOf(source)),
            " task-1 ",
            DownloadControlOperation.DELETE_TASK,
        )
        assertNotNull(target)
        assertEquals("profile-a", target?.profileId)
        assertEquals(source.copy(id = "task-1"), target?.taskBaseline)
    }

    @Test
    fun `空缺失或歧义ID不能建立目标`() {
        val duplicated = Loadable.Ready(listOf(task(), task(title = "重复项")))
        assertNull(downloadControlTarget("profile", duplicated, "task-1", DownloadControlOperation.DELETE_TASK))
        assertNull(downloadControlTarget("profile", Loadable.Ready(listOf(task())), " ", DownloadControlOperation.DELETE_TASK))
        assertNull(downloadControlTarget("profile", Loadable.Ready(listOf(task())), "missing", DownloadControlOperation.DELETE_TASK))
        assertNull(downloadControlTarget("profile", Loadable.Loading, "task-1", DownloadControlOperation.DELETE_TASK))
    }

    @Test
    fun `暂停和继续只接受各自可信状态`() {
        assertNotNull(target(DownloadControlOperation.PAUSE, ResourceState.RUNNING))
        assertNotNull(target(DownloadControlOperation.PAUSE, ResourceState.WAITING))
        assertNull(target(DownloadControlOperation.PAUSE, ResourceState.PAUSED))
        assertNotNull(target(DownloadControlOperation.RESUME, ResourceState.PAUSED))
        assertNull(target(DownloadControlOperation.RESUME, ResourceState.RUNNING))
    }

    @Test
    fun `删除确认按稳定baseline重查profile与状态漂移`() {
        val target = target(DownloadControlOperation.DELETE_TASK, ResourceState.RUNNING)!!
        assertTrue(downloadControlTargetIsCurrent(target, "profile-a", Loadable.Ready(listOf(target.taskBaseline))))
        assertTrue(
            downloadControlTargetIsCurrent(
                target,
                "profile-a",
                Loadable.Ready(
                    listOf(
                        target.taskBaseline.copy(
                            transferred = 768L,
                            downloadSpeed = 64L,
                            uploadSpeed = 8L,
                        ),
                    ),
                ),
            ),
        )
        assertFalse(downloadControlTargetIsCurrent(target, "profile-b", Loadable.Ready(listOf(target.taskBaseline))))
        assertFalse(
            downloadControlTargetIsCurrent(
                target,
                "profile-a",
                Loadable.Ready(listOf(target.taskBaseline.copy(status = ResourceState.PAUSED))),
            ),
        )
        assertFalse(
            downloadControlTargetIsCurrent(
                target,
                "profile-a",
                Loadable.Ready(listOf(target.taskBaseline.copy(title = "已变化"))),
            ),
        )
    }

    @Test
    fun `暂停专项刷新只接受PAUSED终态`() {
        val target = target(DownloadControlOperation.PAUSE, ResourceState.RUNNING)!!
        assertTrue(downloadControlRefreshMatches(target, listOf(target.taskBaseline.copy(status = ResourceState.PAUSED))))
        assertFalse(downloadControlRefreshMatches(target, listOf(target.taskBaseline.copy(status = ResourceState.RUNNING))))
        assertFalse(downloadControlRefreshMatches(target, emptyList()))
    }

    @Test
    fun `继续专项刷新只接受RUNNING或WAITING终态`() {
        val target = target(DownloadControlOperation.RESUME, ResourceState.PAUSED)!!
        assertTrue(downloadControlRefreshMatches(target, listOf(target.taskBaseline.copy(status = ResourceState.RUNNING))))
        assertTrue(downloadControlRefreshMatches(target, listOf(target.taskBaseline.copy(status = ResourceState.WAITING))))
        assertFalse(downloadControlRefreshMatches(target, listOf(target.taskBaseline)))
    }

    @Test
    fun `两种删除刷新都只确认任务消失`() {
        listOf(
            DownloadControlOperation.DELETE_TASK,
            DownloadControlOperation.END_TASK_AND_MOVE_FILES,
        ).forEach { operation ->
            val target = target(operation, ResourceState.RUNNING)!!
            assertTrue(downloadControlRefreshMatches(target, emptyList()))
            assertFalse(downloadControlRefreshMatches(target, listOf(target.taskBaseline)))
        }
    }

    @Test
    fun `旧Repository旧NAS旧目标及任一代次漂移均拒绝回调`() {
        val target = target(DownloadControlOperation.PAUSE, ResourceState.RUNNING)!!
        assertTrue(downloadControlCallbackMatches(true, true, target, target, 7, 7, 7))
        assertFalse(downloadControlCallbackMatches(false, true, target, target, 7, 7, 7))
        assertFalse(downloadControlCallbackMatches(true, false, target, target, 7, 7, 7))
        assertFalse(downloadControlCallbackMatches(true, true, target, target.copy(profileId = "profile-b"), 7, 7, 7))
        assertFalse(downloadControlCallbackMatches(true, true, target, target, 6, 7, 7))
        assertFalse(downloadControlCallbackMatches(true, true, target, target, 7, 6, 7))
        assertFalse(downloadControlCallbackMatches(true, true, target, target, 7, 7, 8))
    }

    @Test
    fun `同步claim后新操作立即被拒绝`() {
        assertTrue(canStartDownloadControlMutation(false, DownloadControlWorkspaceState()))
        assertFalse(canStartDownloadControlMutation(true, DownloadControlWorkspaceState()))
        assertFalse(
            canStartDownloadControlMutation(
                false,
                DownloadControlWorkspaceState(
                    target = target(DownloadControlOperation.PAUSE, ResourceState.RUNNING),
                    mutationInProgress = true,
                ),
            ),
        )
    }

    @Test
    fun `删除确认态纳入退出门禁且不能当结果dismiss`() {
        val state = DownloadControlWorkspaceState(
            target = target(DownloadControlOperation.DELETE_TASK, ResourceState.RUNNING),
            confirmationRequested = true,
        )
        assertTrue(downloadControlBlocksWorkspaceExit(state))
        assertFalse(canDismissDownloadControlMutation(state))
    }

    @Test
    fun `写入与专项刷新进行中都阻止退出`() {
        val target = target(DownloadControlOperation.PAUSE, ResourceState.RUNNING)
        assertTrue(downloadControlBlocksWorkspaceExit(DownloadControlWorkspaceState(target = target, mutationInProgress = true)))
        assertTrue(downloadControlBlocksWorkspaceExit(DownloadControlWorkspaceState(target = target, mutationRefreshInProgress = true)))
    }

    @Test
    fun `八类原始结果和三项计数不被状态层压缩`() {
        MutationResultStatus.entries.forEachIndexed { index, status ->
            val result = result(status)
            val state = DownloadControlWorkspaceState(
                target = target(DownloadControlOperation.DELETE_TASK, ResourceState.RUNNING),
                mutationResult = result,
                mutationGeneration = index.toLong(),
            )
            assertEquals(status, state.mutationResult?.status)
            assertEquals(result.counts, state.mutationResult?.counts)
            assertEquals(result.submitted, state.mutationResult?.submitted)
            assertEquals(result.requiresRefresh, state.mutationResult?.requiresRefresh)
        }
    }

    @Test
    fun `危险submitted删除结果在可信刷新前禁止dismiss和退出`() {
        val state = DownloadControlWorkspaceState(
            target = target(DownloadControlOperation.DELETE_TASK, ResourceState.RUNNING),
            mutationResult = result(MutationResultStatus.CONFIRMED_SUCCESS),
        )
        assertTrue(downloadControlRequiresRefreshBeforeDismiss(state))
        assertFalse(canDismissDownloadControlMutation(state))
        assertTrue(downloadControlBlocksWorkspaceExit(state))
        val refreshed = state.copy(mutationRefreshCompleted = true)
        assertTrue(canDismissDownloadControlMutation(refreshed))
        assertFalse(downloadControlBlocksWorkspaceExit(refreshed))
    }

    @Test
    fun `刷新成功与目标匹配分离且differs仍允许明确核对后dismiss`() {
        val target = target(DownloadControlOperation.END_TASK_AND_MOVE_FILES, ResourceState.RUNNING)!!
        val state = DownloadControlWorkspaceState(
            target = target,
            mutationResult = result(MutationResultStatus.PARTIAL_SUCCESS),
            mutationRefreshCompleted = true,
        )
        assertFalse(downloadControlRefreshMatches(target, listOf(target.taskBaseline)))
        assertTrue(canDismissDownloadControlMutation(state))
        assertFalse(downloadControlBlocksWorkspaceExit(state))
    }

    @Test
    fun `刷新失败不折叠为完成并继续保持危险门禁`() {
        val state = DownloadControlWorkspaceState(
            target = target(DownloadControlOperation.DELETE_TASK, ResourceState.RUNNING),
            mutationResult = result(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED),
            mutationRefreshFailure = DsmFailure(
                null,
                "Synthetic refresh failure",
                "Retry the scoped refresh.",
                kind = DsmErrorKind.CONNECTION_FAILED,
            ),
        )
        assertFalse(state.mutationRefreshCompleted)
        assertFalse(canDismissDownloadControlMutation(state))
        assertTrue(downloadControlBlocksWorkspaceExit(state))
    }

    @Test
    fun `畸形专项列表记录INVALID_RESPONSE且绝不标记刷新完成`() {
        val failure = DsmFailure(
            null,
            "Synthetic malformed task list",
            "Retry the strict scoped refresh.",
            kind = DsmErrorKind.INVALID_RESPONSE,
        )
        val state = DownloadControlWorkspaceState(
            target = target(DownloadControlOperation.DELETE_TASK, ResourceState.RUNNING),
            mutationResult = result(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED),
            mutationRefreshFailure = failure,
            mutationRefreshCompleted = false,
        )
        assertEquals(DsmErrorKind.INVALID_RESPONSE, state.mutationRefreshFailure?.kind)
        assertFalse(state.mutationRefreshCompleted)
        assertFalse(canDismissDownloadControlMutation(state))
        assertTrue(downloadControlBlocksWorkspaceExit(state))
    }

    @Test
    fun `严格匹配证据持久化后普通列表Loading或宽松覆盖均不改变`() {
        val target = target(DownloadControlOperation.DELETE_TASK, ResourceState.RUNNING)!!
        val control = DownloadControlWorkspaceState(
            target = target,
            mutationResult = result(MutationResultStatus.CONFIRMED_SUCCESS),
            mutationRefreshCompleted = true,
            mutationRefreshMatches = true,
            mutationGeneration = 9L,
        )
        val workspace = WorkspaceState(
            profile = NasProfile("profile-a", "NAS", "nas.invalid", "user"),
            downloads = Loadable.Ready(emptyList()),
            downloadControlState = control,
        )

        val loading = workspace.copy(downloads = Loadable.Loading)
        val looselyOverwritten = loading.copy(downloads = Loadable.Ready(listOf(target.taskBaseline)))

        assertTrue(loading.downloadControlState.mutationRefreshCompleted)
        assertEquals(true, loading.downloadControlState.mutationRefreshMatches)
        assertEquals(true, looselyOverwritten.downloadControlState.mutationRefreshMatches)
        assertFalse(downloadControlRefreshMatches(target, looselyOverwritten.downloads.let {
            (it as Loadable.Ready).value
        }))
    }

    @Test
    fun `旧代严格刷新回调不能覆盖当前持久证据`() {
        val target = target(DownloadControlOperation.PAUSE, ResourceState.RUNNING)!!
        val current = DownloadControlWorkspaceState(
            target = target,
            mutationResult = result(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED),
            mutationRefreshCompleted = true,
            mutationRefreshMatches = true,
            mutationGeneration = 12L,
        )
        val staleAccepted = downloadControlCallbackMatches(
            repositoryMatches = true,
            profileMatches = true,
            stateTarget = current.target,
            callbackTarget = target,
            stateGeneration = current.mutationGeneration,
            callbackGeneration = 11L,
            globalGeneration = 12L,
        )
        val afterStaleCallback = if (staleAccepted) {
            current.copy(mutationRefreshMatches = false)
        } else current

        assertFalse(staleAccepted)
        assertEquals(true, afterStaleCallback.mutationRefreshMatches)
        assertEquals(12L, afterStaleCallback.mutationGeneration)
    }

    @Test
    fun `控制目标存在时普通下载加载和旧普通回调均被拒绝`() {
        val profile = NasProfile("profile-a", "NAS", "nas.invalid", "user")
        val idle = WorkspaceState(profile = profile)
        val token = DownloadListRequestToken(generation = 4L, profileId = profile.id)
        assertTrue(canLoadDownloadsNormally(idle.downloadControlState))
        assertTrue(idle.matchesDownloadListRequest(token, currentGeneration = 4L))

        val controlled = idle.copy(
            downloadControlState = DownloadControlWorkspaceState(
                target = target(DownloadControlOperation.PAUSE, ResourceState.RUNNING),
                mutationInProgress = true,
                mutationGeneration = 8L,
            ),
        )
        assertFalse(canLoadDownloadsNormally(controlled.downloadControlState))
        assertFalse(controlled.matchesDownloadListRequest(token, currentGeneration = 4L))
        assertFalse(controlled.matchesDownloadListRequest(token, currentGeneration = 5L))
        assertEquals(Loadable.Idle, controlled.downloads)
    }

    @Test
    fun `launch外层取消保守保留已提交未知且只计算任务结果`() {
        val ordinary = target(DownloadControlOperation.PAUSE, ResourceState.RUNNING)!!
        val deleteFiles = target(
            DownloadControlOperation.END_TASK_AND_MOVE_FILES,
            ResourceState.RUNNING,
        )!!

        val ordinaryResult = cancelledDownloadControlResult(ordinary)
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, ordinaryResult.status)
        assertTrue(ordinaryResult.submitted)
        assertTrue(ordinaryResult.requiresRefresh)
        assertEquals(MutationResultCounts(0, 0, 1), ordinaryResult.counts)

        val deleteFilesResult = cancelledDownloadControlResult(deleteFiles)
        assertEquals("downloadEndAndMove", deleteFilesResult.operation)
        assertEquals(MutationResultCounts(0, 0, 1), deleteFilesResult.counts)
        val state = DownloadControlWorkspaceState(
            target = deleteFiles,
            mutationResult = deleteFilesResult,
        )
        assertTrue(downloadControlBlocksWorkspaceExit(state))
        assertFalse(canDismissDownloadControlMutation(state))
    }

    @Test
    fun `未提交的明确拒绝可保留原始结果后dismiss`() {
        listOf(
            MutationResultStatus.PERMISSION_DENIED,
            MutationResultStatus.UNSUPPORTED,
            MutationResultStatus.CONFIRMED_FAILURE,
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
        ).forEach { status ->
            val state = DownloadControlWorkspaceState(
                target = target(DownloadControlOperation.DELETE_TASK, ResourceState.RUNNING),
                mutationResult = result(status),
            )
            assertFalse(downloadControlRequiresRefreshBeforeDismiss(state))
            assertTrue(canDismissDownloadControlMutation(state))
            assertFalse(downloadControlBlocksWorkspaceExit(state))
        }
    }

    @Test
    fun `删除异常在专项刷新前保持门禁且刷新完成后释放`() {
        val state = DownloadControlWorkspaceState(
            target = target(DownloadControlOperation.DELETE_TASK, ResourceState.RUNNING),
            mutationFailure = DsmFailure(
                null,
                "Synthetic mutation failure",
                "Refresh before continuing.",
                kind = DsmErrorKind.UNKNOWN,
            ),
        )
        assertFalse(canDismissDownloadControlMutation(state))
        assertTrue(downloadControlBlocksWorkspaceExit(state))
        assertTrue(canDismissDownloadControlMutation(state.copy(mutationRefreshCompleted = true)))
    }

    private fun target(
        operation: DownloadControlOperation,
        status: ResourceState,
    ): DownloadControlTarget? = downloadControlTarget(
        profileId = "profile-a",
        downloads = Loadable.Ready(listOf(task(status = status))),
        taskId = "task-1",
        operation = operation,
    )

    private fun task(
        id: String = "task-1",
        title: String = "Synthetic task",
        status: ResourceState = ResourceState.RUNNING,
    ) = DownloadTask(
        id = id,
        type = "http",
        title = title,
        status = status,
        size = 1024L,
        transferred = 256L,
        downloadSpeed = 16L,
        uploadSpeed = 0L,
        destination = "downloads",
        error = null,
        createdAtEpochSeconds = 1_700_000_000L,
    )

    private fun result(status: MutationResultStatus): MutationResult {
        val submitted = status in setOf(
            MutationResultStatus.CONFIRMED_SUCCESS,
            MutationResultStatus.PARTIAL_SUCCESS,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        )
        val requiresRefresh = status in setOf(
            MutationResultStatus.PARTIAL_SUCCESS,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        )
        val counts = when (status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> MutationResultCounts(1, 0, 0)
            MutationResultStatus.PARTIAL_SUCCESS -> MutationResultCounts(1, 0, 1)
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            -> MutationResultCounts(0, 0, 1)
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> MutationResultCounts(0, 0, 0)
            MutationResultStatus.PERMISSION_DENIED,
            MutationResultStatus.UNSUPPORTED,
            MutationResultStatus.CONFIRMED_FAILURE,
            -> MutationResultCounts(0, 1, 0)
        }
        return MutationResult(
            schemaVersion = 1,
            status = status,
            operation = "downloadDelete",
            submitted = submitted,
            requiresRefresh = requiresRefresh,
            counts = counts,
            errorCategory = if (status == MutationResultStatus.CONFIRMED_FAILURE) {
                MutationErrorCategory.CONFLICT
            } else null,
            diagnosticTag = "download-station.synthetic",
        )
    }
}

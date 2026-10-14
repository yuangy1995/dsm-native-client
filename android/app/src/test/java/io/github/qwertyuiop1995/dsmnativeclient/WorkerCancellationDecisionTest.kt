package io.github.qwertyuiop1995.dsmnativeclient

import androidx.work.WorkInfo
import androidx.work.ExistingWorkPolicy
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedDownload
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedMutationResult
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedUpload
import io.github.qwertyuiop1995.dsmnativeclient.data.canRemoveFinishedUpload
import io.github.qwertyuiop1995.dsmnativeclient.data.toPersistedMutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferDirection
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferTask
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class WorkerCancellationDecisionTest {
    @Test
    fun `只有当前执行处于取消中才解释为用户取消`() {
        assertEquals(
            WorkerCancellationDecision.USER_CANCELLATION,
            workerCancellationDecision(TransferState.CANCELLING, "execution", "execution"),
        )
        assertEquals(
            WorkerCancellationDecision.PRESERVE_CURRENT_STATE,
            workerCancellationDecision(TransferState.RUNNING, "execution", "execution"),
        )
        assertEquals(
            WorkerCancellationDecision.PRESERVE_CURRENT_STATE,
            workerCancellationDecision(TransferState.PAUSED, "execution", "execution"),
        )
        assertEquals(
            WorkerCancellationDecision.PRESERVE_CURRENT_STATE,
            workerCancellationDecision(TransferState.CANCELLING, "new-execution", "old-execution"),
        )
    }

    @Test
    fun `下载系统停止和旧执行不改状态也不请求删除`() {
        val running = download(TransferState.RUNNING)
        val paused = download(TransferState.PAUSED)
        val replaced = download(TransferState.CANCELLING, workId = "new-execution")

        assertSame(running, running.cancelDownloadExecution("execution"))
        assertSame(paused, paused.cancelDownloadExecution("execution"))
        assertSame(replaced, replaced.cancelDownloadExecution("old-execution"))
        assertEquals(false, shouldDeleteCancelledDownload(running.state, running.workId, "execution"))
        assertEquals(false, shouldDeleteCancelledDownload(paused.state, paused.workId, "execution"))
        assertEquals(false, shouldDeleteCancelledDownload(replaced.state, replaced.workId, "old-execution"))
    }

    @Test
    fun `下载显式取消仅由当前执行落取消态`() {
        val cancelling = download(TransferState.CANCELLING, errorKind = "stale")

        val cancelled = cancelling.cancelDownloadExecution("execution")

        assertEquals(TransferState.CANCELLED, cancelled.state)
        assertEquals(null, cancelled.errorKind)
        assertEquals(true, shouldDeleteCancelledDownload(cancelling.state, cancelling.workId, "execution"))
    }

    @Test
    fun `上传系统停止暂停和旧执行保持原状态`() {
        val running = upload(TransferState.RUNNING)
        val paused = upload(TransferState.PAUSED)
        val replaced = upload(TransferState.CANCELLING, workId = "new-execution")

        assertSame(running, running.cancelUploadExecution("execution"))
        assertSame(paused, paused.cancelUploadExecution("execution"))
        assertSame(replaced, replaced.cancelUploadExecution("old-execution"))
    }

    @Test
    fun `上传与备份显式取消保留已发出请求的不确定性包括空文件`() {
        val ordinary = upload(TransferState.CANCELLING, completedBytes = 7, backupMode = false)
        val backup = upload(TransferState.CANCELLING, completedBytes = 7, backupMode = true)

        assertEquals(TransferState.CANCELLED, ordinary.cancelUploadExecution("execution").state)
        assertEquals(true, ordinary.cancelUploadExecution("execution").requiresRefresh)
        assertEquals(true, backup.cancelUploadExecution("execution").requiresRefresh)
        val empty = upload(TransferState.CANCELLING, completedBytes = 0, backupMode = true)
        assertEquals(true, empty.cancelUploadExecution("execution", attemptStarted = true).requiresRefresh)
        assertEquals(false, empty.cancelUploadExecution("execution", attemptStarted = false).requiresRefresh)
    }

    @Test
    fun `成功和跳过成功清理陈旧错误与刷新标记`() {
        val completedDownload = download(
            state = TransferState.RUNNING,
            errorKind = "stale",
            completedBytes = 4,
            totalBytes = 9,
        ).completeDownloadExecution("execution")
        val completedUpload = upload(
            state = TransferState.RUNNING,
            errorKind = "stale",
            completedBytes = 4,
            requiresRefresh = true,
        ).completeUploadExecution("execution", skippedExisting = false)
        val skippedUpload = upload(
            state = TransferState.RUNNING,
            errorKind = "stale",
            requiresRefresh = true,
        ).completeUploadExecution("execution", skippedExisting = true)

        assertEquals(TransferState.SUCCEEDED, completedDownload.state)
        assertEquals(9, completedDownload.completedBytes)
        assertEquals(null, completedDownload.errorKind)
        assertEquals(TransferState.SUCCEEDED, completedUpload.state)
        assertEquals(null, completedUpload.errorKind)
        assertEquals(false, completedUpload.requiresRefresh)
        assertEquals(false, completedUpload.skippedExisting)
        assertEquals(TransferState.SUCCEEDED, skippedUpload.state)
        assertEquals(null, skippedUpload.errorKind)
        assertEquals(false, skippedUpload.requiresRefresh)
        assertEquals(true, skippedUpload.skippedExisting)
    }

    @Test
    fun `旧执行不能写入成功状态`() {
        val download = download(TransferState.RUNNING, workId = "new-execution")
        val upload = upload(TransferState.RUNNING, workId = "new-execution")

        assertSame(download, download.completeDownloadExecution("old-execution"))
        assertSame(upload, upload.completeUploadExecution("old-execution", skippedExisting = false))
    }

    @Test
    fun `目录确认成功只保存结构化结果并继续当前上传`() {
        val result = mutationResult(MutationResultStatus.CONFIRMED_SUCCESS)

        val prepared = upload(TransferState.RUNNING).applyUploadMutationResult(
            "execution",
            result,
            UploadMutationStage.DIRECTORY,
        )

        assertEquals(TransferState.RUNNING, prepared.state)
        assertEquals(result.status, prepared.directoryMutationResult?.status)
        assertEquals(result.counts, prepared.directoryMutationResult?.counts)
        assertEquals(null, prepared.uploadMutationResult)
    }

    @Test
    fun `目录已满足不伪装成实际提交写入`() {
        val result = mutationResult(MutationResultStatus.CONFIRMED_SUCCESS).copy(
            diagnosticTag = "file-station.backup-folder.ensure.already-satisfied",
        )

        val prepared = upload(TransferState.RUNNING).applyUploadMutationResult(
            "execution",
            result,
            UploadMutationStage.DIRECTORY,
        )

        assertEquals(true, prepared.directoryMutationResult?.submitted)
        assertEquals(false, prepared.directoryMutationResult?.writeSubmitted)
    }

    @Test
    fun `上传确认成功保存完整稳定语义并完成任务`() {
        val result = mutationResult(MutationResultStatus.CONFIRMED_SUCCESS)

        val completed = upload(TransferState.RUNNING).applyUploadMutationResult(
            "execution",
            result,
            UploadMutationStage.UPLOAD,
        )

        assertEquals(TransferState.SUCCEEDED, completed.state)
        assertEquals(10, completed.completedBytes)
        assertEquals(false, completed.requiresRefresh)
        assertEquals(result.status, completed.uploadMutationResult?.status)
        assertEquals(result.submitted, completed.uploadMutationResult?.submitted)
        assertEquals(result.errorCategory, completed.uploadMutationResult?.errorCategory)
        assertEquals(result.diagnosticTag, completed.uploadMutationResult?.diagnosticTag)
        assertEquals(true, completed.uploadMutationResult?.writeSubmitted)
    }

    @Test
    fun `提交未确认不会降格为普通失败`() {
        val result = mutationResult(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED)

        val failed = upload(TransferState.RUNNING).applyUploadMutationResult(
            "execution",
            result,
            UploadMutationStage.UPLOAD,
        )

        assertEquals(TransferState.FAILED, failed.state)
        assertEquals(true, failed.requiresRefresh)
        assertEquals("CHANGE_NOT_CONFIRMED", failed.errorKind)
        assertEquals(true, failed.uploadMutationResult?.submitted)
        assertEquals(1, failed.uploadMutationResult?.counts?.unknown)
    }

    @Test
    fun `提交后取消持久保留未知边界而提交前取消无需刷新`() {
        val afterSubmission = upload(TransferState.RUNNING).applyUploadMutationResult(
            "execution",
            mutationResult(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION),
            UploadMutationStage.UPLOAD,
        )
        val beforeSubmission = upload(TransferState.RUNNING).applyUploadMutationResult(
            "execution",
            mutationResult(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION),
            UploadMutationStage.UPLOAD,
        )

        assertEquals(TransferState.CANCELLED, afterSubmission.state)
        assertEquals(true, afterSubmission.requiresRefresh)
        assertEquals(
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            afterSubmission.uploadMutationResult?.status,
        )
        assertEquals(TransferState.CANCELLED, beforeSubmission.state)
        assertEquals(false, beforeSubmission.requiresRefresh)
        assertEquals(null, beforeSubmission.errorKind)
    }

    @Test
    fun `结构化结果只允许当前执行写入`() {
        val current = upload(TransferState.RUNNING, workId = "new-execution")

        assertSame(
            current,
            current.applyUploadMutationResult(
                "old-execution",
                mutationResult(MutationResultStatus.CONFIRMED_SUCCESS),
                UploadMutationStage.UPLOAD,
            ),
        )
    }

    @Test
    fun `显式取消保留已经记录的结构化刷新要求`() {
        val cancelling = upload(
            state = TransferState.CANCELLING,
            backupMode = true,
        ).copy(
            uploadMutationResult = PersistedMutationResult(
                status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                submitted = true,
                requiresRefresh = true,
                counts = MutationResultCounts(0, 0, 1),
            ),
        )

        val cancelled = cancelling.cancelUploadExecution("execution")

        assertEquals(TransferState.CANCELLED, cancelled.state)
        assertEquals(true, cancelled.requiresRefresh)
    }

    @Test
    fun `旧上传密文缺少结果字段仍可读取且新字段可往返`() {
        val json = Json { ignoreUnknownKeys = true }
        val legacy = json.decodeFromString<PersistedUpload>(
            """{"id":"upload","profileId":"profile","sourceUri":"content://synthetic/source","title":"source.bin","expectedBytes":10,"destinationPath":"/synthetic/destination","futureField":true}""",
        )
        assertEquals(null, legacy.directoryMutationResult)
        assertEquals(null, legacy.uploadMutationResult)

        val current = legacy.copy(
            uploadMutationResult = PersistedMutationResult(
                status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                submitted = true,
                requiresRefresh = true,
                counts = MutationResultCounts(0, 0, 1),
                errorCategory = MutationErrorCategory.NETWORK,
                diagnosticTag = "file-station.upload.readback-failed",
                writeSubmitted = true,
            ),
        )
        val restored = json.decodeFromString<PersistedUpload>(json.encodeToString(current))
        assertEquals(current, restored)
    }

    @Test
    fun `上传观察器先收到显式取消时保留刷新语义`() {
        val cancelling = upload(
            state = TransferState.CANCELLING,
            completedBytes = 7,
            backupMode = false,
        )

        val cancelled = cancelling.applyUploadWorkObservation(
            executionId = "execution",
            workState = WorkInfo.State.CANCELLED,
        )

        assertEquals(TransferState.CANCELLED, cancelled.state)
        assertEquals(true, cancelled.requiresRefresh)
    }

    @Test
    fun `上传Worker先落取消时观察器保持终态`() {
        val cancelledByWorker = upload(
            state = TransferState.CANCELLING,
            completedBytes = 7,
            backupMode = false,
        ).cancelUploadExecution("execution")

        val observed = cancelledByWorker.applyUploadWorkObservation(
            executionId = "execution",
            workState = WorkInfo.State.CANCELLED,
        )

        assertSame(cancelledByWorker, observed)
        assertEquals(true, observed.requiresRefresh)
    }

    @Test
    fun `上传观察器忽略旧执行和暂停状态`() {
        val replaced = upload(TransferState.RUNNING, workId = "new-execution")
        val paused = upload(TransferState.PAUSED)

        assertSame(
            replaced,
            replaced.applyUploadWorkObservation("old-execution", WorkInfo.State.SUCCEEDED),
        )
        assertSame(
            paused,
            paused.applyUploadWorkObservation("execution", WorkInfo.State.RUNNING, 8),
        )
    }

    @Test
    fun `上传系统停止重新排队保持运行边界防止自动重放`() {
        val running = upload(TransferState.RUNNING, completedBytes = 7)
        val cancelling = upload(TransferState.CANCELLING, completedBytes = 7)

        val requeued = running.applyUploadWorkObservation(
            executionId = "execution",
            workState = WorkInfo.State.ENQUEUED,
        )

        assertSame(running, requeued)
        assertEquals(7, requeued.completedBytes)
        val terminated = running.applyUploadWorkObservation("execution", WorkInfo.State.CANCELLED)
        assertEquals(TransferState.FAILED, terminated.state)
        assertEquals(DsmErrorKind.CHANGE_NOT_CONFIRMED.name, terminated.errorKind)
        assertEquals(true, terminated.requiresRefresh)
        assertSame(
            cancelling,
            cancelling.applyUploadWorkObservation("execution", WorkInfo.State.ENQUEUED),
        )
    }

    @Test
    fun `尚未运行的上传继续保持排队状态`() {
        val waiting = upload(TransferState.WAITING)

        val observed = waiting.applyUploadWorkObservation(
            executionId = "execution",
            workState = WorkInfo.State.BLOCKED,
        )

        assertEquals(TransferState.WAITING, observed.state)
        assertEquals(false, observed.requiresRefresh)
    }

    @Test
    fun `登出只把可能到达NAS的上传标记为待核验`() {
        val waiting = upload(
            TransferState.WAITING,
            completedBytes = 0,
            backupMode = true,
        ).cancelUploadForLogout()
        val runningBackup = upload(
            TransferState.RUNNING,
            completedBytes = 0,
            backupMode = true,
        ).cancelUploadForLogout()

        assertEquals(TransferState.CANCELLED, waiting.state)
        assertEquals(false, waiting.requiresRefresh)
        assertEquals(null, waiting.errorKind)
        assertEquals(TransferState.CANCELLED, runningBackup.state)
        assertEquals(true, runningBackup.requiresRefresh)
        assertEquals(DsmErrorKind.CHANGE_NOT_CONFIRMED.name, runningBackup.errorKind)
    }

    @Test
    fun `取消请求优先保留为取消结果`() {
        val cancelling = upload(TransferState.CANCELLING)

        val result = cancelling.applyUploadMutationResult(
            "execution",
            mutationResult(MutationResultStatus.CONFIRMED_FAILURE),
            UploadMutationStage.UPLOAD,
        )

        assertEquals(TransferState.CANCELLED, result.state)
        assertEquals(false, result.requiresRefresh)
    }

    @Test
    fun `运行中Worker恢复只形成未确认结果而不允许自动重放`() {
        val result = interruptedUploadResult()

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(true, result.submitted)
        assertEquals(true, result.requiresRefresh)
        assertEquals(1, result.counts.unknown)
    }

    @Test
    fun `目标冲突形成提交前结构化失败`() {
        val result = uploadTargetConflictResult()

        assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
        assertEquals(false, result.submitted)
        assertEquals(MutationErrorCategory.CONFLICT, result.errorCategory)
    }

    @Test
    fun `未确认终态不可被清除而安全终态可以清除`() {
        assertEquals(
            false,
            upload(TransferState.FAILED, requiresRefresh = true).canRemoveFinishedUpload(),
        )
        assertEquals(
            true,
            upload(TransferState.FAILED, requiresRefresh = false).canRemoveFinishedUpload(),
        )
        assertEquals(false, upload(TransferState.RUNNING).canRemoveFinishedUpload())
    }

    @Test
    fun `明确重试回读成功替换旧未确认结果`() {
        val confirmed = confirmedUploadReadbackResult()
            .toPersistedMutationResult(writeSubmitted = false)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, confirmed.status)
        assertEquals(1, confirmed.counts.succeeded)
        assertEquals(false, confirmed.requiresRefresh)
        assertEquals(false, confirmed.writeSubmitted)
    }

    @Test
    fun `上传观察器不覆盖终态并在成功时清理陈旧状态`() {
        TransferState.entries
            .filter { it in setOf(TransferState.SUCCEEDED, TransferState.FAILED, TransferState.CANCELLED) }
            .forEach { terminal ->
                val current = upload(terminal, errorKind = "existing", requiresRefresh = true)
                assertSame(
                    current,
                    current.applyUploadWorkObservation("execution", WorkInfo.State.RUNNING, 9),
                )
            }
        val succeeded = upload(
            state = TransferState.RUNNING,
            errorKind = "stale",
            requiresRefresh = true,
        ).applyUploadWorkObservation("execution", WorkInfo.State.SUCCEEDED)

        assertEquals(TransferState.SUCCEEDED, succeeded.state)
        assertEquals(10, succeeded.completedBytes)
        assertEquals(null, succeeded.errorKind)
        assertEquals(false, succeeded.requiresRefresh)
    }

    @Test
    fun `初次入队保留旧任务而显式重试替换旧任务`() {
        assertEquals(
            ExistingWorkPolicy.KEEP,
            transferEnqueuePolicy(TransferEnqueueReason.INITIAL),
        )
        assertEquals(
            ExistingWorkPolicy.REPLACE,
            transferEnqueuePolicy(TransferEnqueueReason.USER_RETRY),
        )
    }

    @Test
    fun `排队任务只允许当前Work进入显式取消`() {
        val queuedDownload = download(TransferState.WAITING)
        val queuedUpload = upload(TransferState.WAITING)

        assertEquals(
            TransferState.CANCELLING,
            queuedDownload.requestUserCancellation("execution").state,
        )
        assertEquals(
            TransferState.CANCELLING,
            queuedUpload.requestUserCancellation("execution").state,
        )
        assertSame(queuedDownload, queuedDownload.requestUserCancellation("old-execution"))
        assertSame(queuedUpload, queuedUpload.requestUserCancellation("old-execution"))
    }

    @Test
    fun `上传取消中收到任一Work终态都最终化为用户取消`() {
        WorkInfo.State.entries.filter(WorkInfo.State::isFinished).forEach { finished ->
            val cancelling = upload(
                state = TransferState.CANCELLING,
                completedBytes = 7,
                backupMode = false,
            )

            val result = cancelling.applyUploadWorkObservation("execution", finished)

            assertEquals(finished.name, TransferState.CANCELLED, result.state)
            assertEquals(finished.name, true, result.requiresRefresh)
        }
    }

    @Test
    fun `下载取消中收到任一Work终态都最终化并允许清理`() {
        WorkInfo.State.entries.filter(WorkInfo.State::isFinished).forEach { finished ->
            val cancelling = download(TransferState.CANCELLING)

            val result = cancelling.applyDownloadWorkObservation("execution", finished)

            assertEquals(finished.name, TransferState.CANCELLED, result.state)
            assertEquals(
                finished.name,
                true,
                shouldDeleteCancelledDownload(cancelling.state, cancelling.workId, "execution"),
            )
        }
    }

    @Test
    fun `下载观察器忽略旧Work和系统取消`() {
        val replaced = download(TransferState.CANCELLING, workId = "new-execution")
        val running = download(TransferState.RUNNING)

        assertSame(
            replaced,
            replaced.applyDownloadWorkObservation("old-execution", WorkInfo.State.CANCELLED),
        )
        assertSame(
            running,
            running.applyDownloadWorkObservation("execution", WorkInfo.State.CANCELLED),
        )
    }

    @Test
    fun `前台取消完成回调只最终化取消中状态`() {
        val download = download(TransferState.CANCELLING, workId = "")
            .copy(workId = null)
        val uploadTask = TransferTask(
            id = "upload",
            title = "upload.bin",
            detail = "cancelling",
            direction = TransferDirection.UPLOAD,
            state = TransferState.CANCELLING,
            completedBytes = 7,
        )
        val runningTask = uploadTask.copy(state = TransferState.RUNNING)

        assertEquals(
            TransferState.CANCELLED,
            download.finalizeForegroundDownloadCancellation(ownsExecution = true).state,
        )
        assertSame(
            download,
            download.finalizeForegroundDownloadCancellation(ownsExecution = false),
        )
        val cancelledTask = uploadTask.finalizeForegroundUserCancellation("cancelled", "refresh")
        assertEquals(TransferState.CANCELLED, cancelledTask.state)
        assertEquals(true, cancelledTask.requiresRefresh)
        assertEquals("refresh", cancelledTask.detail)
        assertSame(
            runningTask,
            runningTask.finalizeForegroundUserCancellation("cancelled", "refresh"),
        )
    }

    private fun download(
        state: TransferState,
        workId: String = "execution",
        errorKind: String? = null,
        completedBytes: Long = 3,
        totalBytes: Long? = 10,
    ) = PersistedDownload(
        id = "download",
        profileId = "profile",
        sourcePath = "/synthetic/source",
        title = "source.bin",
        destinationUri = "content://synthetic/destination",
        isDirectory = false,
        state = state,
        completedBytes = completedBytes,
        totalBytes = totalBytes,
        errorKind = errorKind,
        workId = workId,
    )

    private fun upload(
        state: TransferState,
        workId: String = "execution",
        errorKind: String? = null,
        completedBytes: Long = 3,
        requiresRefresh: Boolean = false,
        backupMode: Boolean = false,
    ) = PersistedUpload(
        id = "upload",
        profileId = "profile",
        sourceUri = "content://synthetic/source",
        title = "source.bin",
        expectedBytes = 10,
        destinationPath = "/synthetic/destination",
        state = state,
        completedBytes = completedBytes,
        errorKind = errorKind,
        workId = workId,
        backupMode = backupMode,
        requiresRefresh = requiresRefresh,
    )

    private fun mutationResult(status: MutationResultStatus): MutationResult {
        val submitted = status in setOf(
            MutationResultStatus.CONFIRMED_SUCCESS,
            MutationResultStatus.PARTIAL_SUCCESS,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        )
        return MutationResult(
            schemaVersion = 1,
            status = status,
            operation = "fileUpload",
            submitted = submitted,
            requiresRefresh = status in setOf(
                MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            ),
            counts = when (status) {
                MutationResultStatus.CONFIRMED_SUCCESS -> MutationResultCounts(1, 0, 0)
                MutationResultStatus.PARTIAL_SUCCESS -> MutationResultCounts(1, 1, 0)
                MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                -> MutationResultCounts(0, 0, 1)
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> MutationResultCounts(0, 0, 0)
                else -> MutationResultCounts(0, 1, 0)
            },
            errorCategory = when (status) {
                MutationResultStatus.PERMISSION_DENIED -> MutationErrorCategory.PERMISSION
                MutationResultStatus.UNSUPPORTED -> MutationErrorCategory.UNSUPPORTED
                else -> null
            },
            diagnosticTag = "file-station.upload.synthetic",
        )
    }
}

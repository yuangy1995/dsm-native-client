package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedPhotoBackupSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import androidx.work.ListenableWorker
import androidx.work.WorkInfo
import org.junit.Assert.assertEquals
import org.junit.Test
import androidx.work.NetworkType
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import java.util.UUID

class PhotoBackupDecisionTest {
    @Test
    fun `不存在目标时上传`() {
        assertEquals(BackupTargetDecision.UPLOAD, backupTargetDecision(null, 100))
    }

    @Test
    fun `同名同大小文件必须继续比较内容`() {
        val existing = FileItem("/photos/a.jpg", "a.jpg", isDirectory = false, size = 100)
        assertEquals(BackupTargetDecision.VERIFY_CONTENT, backupTargetDecision(existing, 100))
    }

    @Test
    fun `同名不同大小和目录均拒绝覆盖`() {
        val different = FileItem("/photos/a.jpg", "a.jpg", isDirectory = false, size = 99)
        val directory = FileItem("/photos/a.jpg", "a.jpg", isDirectory = true)
        assertEquals(BackupTargetDecision.CONFLICT, backupTargetDecision(different, 100))
        assertEquals(BackupTargetDecision.CONFLICT, backupTargetDecision(directory, 100))
    }

    @Test
    fun `后台备份只在安全资源条件下运行`() {
        val constraints = photoBackupConstraints()

        assertEquals(NetworkType.UNMETERED, constraints.requiredNetworkType)
        assertTrue(constraints.requiresCharging())
        assertTrue(constraints.requiresBatteryNotLow())
        assertTrue(constraints.requiresStorageNotLow())
    }

    @Test
    fun `自动来源只接受安全名称并保留相对目录`() {
        assertTrue(isSafeBackupName("旅行 2026"))
        assertFalse(isSafeBackupName("../照片"))
        assertFalse(isSafeBackupName("a/b"))
        assertEquals("/photo/移动备份/旅行/海边", backupDestination("/photo/移动备份", "旅行/海边"))
    }

    @Test
    fun `普通上传只有明确确认后才允许替换文件`() {
        val file = FileItem("/share/a.txt", "a.txt", isDirectory = false, size = 10)
        val directory = FileItem("/share/a.txt", "a.txt", isDirectory = true)

        assertEquals(BackupTargetDecision.UPLOAD, userUploadTargetDecision(null, overwrite = false))
        assertEquals(BackupTargetDecision.CONFLICT, userUploadTargetDecision(file, overwrite = false))
        assertEquals(BackupTargetDecision.UPLOAD, userUploadTargetDecision(file, overwrite = true))
        assertEquals(BackupTargetDecision.CONFLICT, userUploadTargetDecision(directory, overwrite = true))
    }

    @Test
    fun `上传重试先读取目标再决定完成冲突或从头开始`() {
        val complete = FileItem("/share/a.txt", "a.txt", isDirectory = false, size = 10)
        val conflict = FileItem("/share/a.txt", "a.txt", isDirectory = false, size = 9)

        assertEquals(RetryUploadDecision.CONFLICT, retryUploadDecision(complete, false, true))
        assertEquals(RetryUploadDecision.UNRESOLVED, retryUploadDecision(null, false, true))
        assertEquals(RetryUploadDecision.ALREADY_COMPLETE, retryUploadDecision(complete, contentMatches = true, unresolved = true))
        assertEquals(RetryUploadDecision.CONFLICT, retryUploadDecision(conflict, contentMatches = false, unresolved = false))
        assertEquals(RetryUploadDecision.CONFLICT, retryUploadDecision(conflict, contentMatches = false, unresolved = true))
        assertEquals(RetryUploadDecision.REQUEUE, retryUploadDecision(null, contentMatches = false, unresolved = false))
    }

    @Test
    fun `扫描恰好达到上限且未截断时保留完整计划`() {
        val plan = photoBackupScanPlan(DocumentTreeScan(files = emptyList(), truncated = false))

        assertFalse(plan.needsAttention)
        assertTrue(plan.files.isEmpty())
    }

    @Test
    fun `扫描超过上限时不为前一万项创建部分计划`() {
        val plan = photoBackupScanPlan(DocumentTreeScan(files = emptyList(), truncated = true))
        val result = photoBackupScanFailure(PhotoBackupScanWorker.SCAN_OUTCOME_TOO_MANY_DOCUMENTS)

        assertTrue(plan.needsAttention)
        assertTrue(plan.files.isEmpty())
        assertTrue(result is ListenableWorker.Result.Failure)
        assertEquals(
            PhotoBackupScanWorker.SCAN_OUTCOME_TOO_MANY_DOCUMENTS,
            result.outputData.getString(PhotoBackupScanWorker.KEY_SCAN_OUTCOME),
        )
    }

    @Test
    fun `需要关注的自动来源不会被重复扫描`() {
        val active = PersistedPhotoBackupSource(
            profileId = "profile-a",
            treeUri = "content://synthetic/tree",
            destinationPath = "/photo/backup",
        )

        assertTrue(shouldScanPhotoBackupSource(active))
        assertFalse(shouldScanPhotoBackupSource(active.copy(enabled = false)))
        assertFalse(shouldScanPhotoBackupSource(active.copy(needsAttention = true)))
    }

    @Test
    fun `当前扫描截断才停用工作区来源，来源写入失败只提示`() {
        val active = PersistedPhotoBackupSource(
            profileId = "profile-a",
            treeUri = "content://synthetic/tree",
            destinationPath = "/photo/backup",
            workId = "periodic-a",
        )
        fun decision(
            source: PersistedPhotoBackupSource,
            observedWorkId: String = "initial-a",
            currentGeneration: Boolean = true,
            outcome: String,
            workState: WorkInfo.State = WorkInfo.State.FAILED,
        ) = photoBackupScanFailureDecision(
            observationIsCurrent = currentGeneration,
            workspaceProfileId = "profile-a",
            currentSource = source,
            expectedProfileId = "profile-a",
            expectedTreeUri = "content://synthetic/tree",
            expectedDestinationPath = "/photo/backup",
            expectedPeriodicWorkId = "periodic-a",
            expectedObservedWorkId = "initial-a",
            observedWorkId = observedWorkId,
            workState = workState,
            scanOutcome = outcome,
        )

        assertEquals(
            PhotoBackupScanFailureDecision.DISABLE_SOURCE,
            decision(
                source = active.copy(enabled = false, needsAttention = true, workId = null),
                outcome = PhotoBackupScanWorker.SCAN_OUTCOME_TOO_MANY_DOCUMENTS,
            ),
        )
        assertEquals(
            PhotoBackupScanFailureDecision.SHOW_SOURCE_STATE_UNAVAILABLE,
            decision(
                source = active,
                outcome = PhotoBackupScanWorker.SCAN_OUTCOME_SOURCE_STATE_NOT_PERSISTED,
            ),
        )
        assertEquals(
            PhotoBackupScanFailureDecision.IGNORE,
            decision(
                source = active.copy(workId = "periodic-b"),
                outcome = PhotoBackupScanWorker.SCAN_OUTCOME_SOURCE_STATE_NOT_PERSISTED,
            ),
        )
        assertEquals(
            PhotoBackupScanFailureDecision.IGNORE,
            decision(
                source = active.copy(enabled = false, needsAttention = true, workId = null),
                currentGeneration = false,
                outcome = PhotoBackupScanWorker.SCAN_OUTCOME_TOO_MANY_DOCUMENTS,
            ),
        )
        assertEquals(
            PhotoBackupScanFailureDecision.DISABLE_SOURCE,
            decision(
                source = active.copy(enabled = false, needsAttention = true, workId = null),
                outcome = "",
                workState = WorkInfo.State.ENQUEUED,
            ),
        )
    }

    @Test
    fun `二次周期调度复用 WorkManager 保留的活动 UUID`() {
        val firstScheduleWorkId = UUID.randomUUID()
        val secondRequestWorkId = UUID.randomUUID()

        val actual = resolvedPhotoBackupPeriodicWorkId(listOf(firstScheduleWorkId))

        assertEquals(firstScheduleWorkId, actual)
        assertFalse(secondRequestWorkId == actual)
        assertEquals(
            null,
            resolvedPhotoBackupPeriodicWorkId(listOf(firstScheduleWorkId, secondRequestWorkId)),
        )
    }

    @Test
    fun `调度回调晚于截断持久化时仍收敛同一来源`() {
        val expected = PersistedPhotoBackupSource(
            profileId = "profile-a",
            treeUri = "content://synthetic/tree",
            destinationPath = "/photo/backup",
        )

        assertTrue(
            isPhotoBackupSourceAttentionFor(
                current = expected.copy(enabled = false, needsAttention = true, workId = null),
                expectedProfileId = expected.profileId,
                expectedTreeUri = expected.treeUri,
                expectedDestinationPath = expected.destinationPath,
            ),
        )
        assertFalse(
            isPhotoBackupSourceAttentionFor(
                current = expected.copy(enabled = false, needsAttention = true, workId = null),
                expectedProfileId = expected.profileId,
                expectedTreeUri = expected.treeUri,
                expectedDestinationPath = "/photo/other",
            ),
        )
    }
}

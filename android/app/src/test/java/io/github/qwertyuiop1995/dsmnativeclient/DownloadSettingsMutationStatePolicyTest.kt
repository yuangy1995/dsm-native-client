package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadSettingsMutationStatePolicyTest {
    @Test
    fun `草稿严格解析目录限速与调度能力`() {
        val draft = validDraft().copy(
            destination = "/downloads/current ",
            btDownload = "0",
            btUpload = "1000000",
            scheduleEnabled = true,
            emuleEnabled = false,
            emuleScheduleEnabled = true,
        )

        val withSchedule = checkNotNull(draft.toSettingsOrNull(supportsSchedule = true))
        assertEquals("downloads/current ", withSchedule.defaultDestination)
        assertEquals(0, withSchedule.btDownloadLimitKb)
        assertEquals(1_000_000, withSchedule.btUploadLimitKb)
        assertTrue(withSchedule.scheduleEnabled)
        assertTrue(withSchedule.emuleScheduleEnabled)

        val withoutSchedule = checkNotNull(draft.toSettingsOrNull(supportsSchedule = false))
        assertFalse(withoutSchedule.scheduleEnabled)
        assertFalse(withoutSchedule.emuleScheduleEnabled)
    }

    @Test
    fun `草稿拒绝空白路径父目录片段与非严格整数`() {
        listOf("", "/", "downloads//private", "downloads/./private", "downloads/../private")
            .forEach { destination ->
                assertNull(destination, validDraft().copy(destination = destination).toSettingsOrNull(true))
            }
        listOf("", " 1", "1 ", "1.0", "1_000", "-1", "1000001")
            .forEach { value ->
                assertNull(value, validDraft().copy(btDownload = value).toSettingsOrNull(true))
            }
    }

    @Test
    fun `HTTP与FTP限速使用同一稳定值`() {
        val draft = DownloadSettingsDraftState.from(
            DownloadSettings(
                defaultDestination = "downloads",
                httpDownloadLimitKb = 640,
                ftpDownloadLimitKb = 320,
            ),
        )

        assertEquals("640", draft.httpDownload)
        assertEquals(draft.httpDownload, draft.ftpDownload)
        val parsed = checkNotNull(draft.toSettingsOrNull(supportsSchedule = true))
        assertEquals(640, parsed.httpDownloadLimitKb)
        assertEquals(parsed.httpDownloadLimitKb, parsed.ftpDownloadLimitKb)
    }

    @Test
    fun `八种结果保留计数且仅未确认语义要求刷新`() {
        MutationResultStatus.entries.forEach { status ->
            val result = result(status)
            val state = DownloadSettingsWorkspaceState(mutationResult = result)
            val expected = status in setOf(
                MutationResultStatus.PARTIAL_SUCCESS,
                MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            )

            assertEquals(status.name, status, state.mutationResult?.status)
            assertEquals(status.name, result.counts, state.mutationResult?.counts)
            assertEquals(status.name, expected, downloadSettingsRequiresRefreshBeforeDismiss(state))
        }
    }

    @Test
    fun `未知计数与异常均要求专项刷新`() {
        val unknown = result(MutationResultStatus.CONFIRMED_FAILURE).copy(
            counts = MutationResultCounts(succeeded = 0, failed = 0, unknown = 1),
        )
        assertTrue(
            downloadSettingsRequiresRefreshBeforeDismiss(
                DownloadSettingsWorkspaceState(mutationResult = unknown),
            ),
        )
        assertTrue(
            downloadSettingsRequiresRefreshBeforeDismiss(
                DownloadSettingsWorkspaceState(mutationFailure = failure()),
            ),
        )
    }

    @Test
    fun `写入刷新与已提交未确认在明确关闭前保持门禁`() {
        assertTrue(
            downloadSettingsBlocksWorkspaceExit(
                DownloadSettingsWorkspaceState(mutationInProgress = true),
            ),
        )
        assertTrue(
            downloadSettingsBlocksWorkspaceExit(
                DownloadSettingsWorkspaceState(mutationRefreshInProgress = true),
            ),
        )
        val unknown = DownloadSettingsWorkspaceState(
            mutationResult = result(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED),
        )
        assertTrue(downloadSettingsBlocksWorkspaceExit(unknown))
        assertTrue(downloadSettingsBlocksWorkspaceExit(unknown.copy(mutationRefreshCompleted = true)))
        assertFalse(
            downloadSettingsBlocksWorkspaceExit(
                DownloadSettingsWorkspaceState(
                    mutationResult = result(MutationResultStatus.CONFIRMED_FAILURE),
                ),
            ),
        )
    }

    @Test
    fun `危险结果和异常在可信刷新前不能关闭`() {
        val unknown = DownloadSettingsWorkspaceState(
            mutationResult = result(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED),
        )
        assertFalse(canDismissDownloadSettingsMutation(unknown))
        assertTrue(canDismissDownloadSettingsMutation(unknown.copy(mutationRefreshCompleted = true)))

        val failed = DownloadSettingsWorkspaceState(mutationFailure = failure())
        assertFalse(canDismissDownloadSettingsMutation(failed))
        assertTrue(canDismissDownloadSettingsMutation(failed.copy(mutationRefreshCompleted = true)))

        assertFalse(canDismissDownloadSettingsMutation(unknown.copy(mutationInProgress = true)))
        assertFalse(canDismissDownloadSettingsMutation(unknown.copy(mutationRefreshInProgress = true)))
    }

    @Test
    fun `过期回调必须同时匹配Repository_Profile与两层代次`() {
        assertTrue(scopedMutationCallbackMatches(true, true, 7, 7, 7))
        assertFalse(scopedMutationCallbackMatches(false, true, 7, 7, 7))
        assertFalse(scopedMutationCallbackMatches(true, false, 7, 7, 7))
        assertFalse(scopedMutationCallbackMatches(true, true, 6, 7, 7))
        assertFalse(scopedMutationCallbackMatches(true, true, 7, 6, 7))
        assertFalse(scopedMutationCallbackMatches(true, true, 7, 7, 8))
    }

    private fun validDraft() = DownloadSettingsDraftState(
        destination = "downloads",
        emuleEnabled = true,
        autoExtract = false,
        btDownload = "100",
        btUpload = "200",
        httpDownload = "300",
        ftpDownload = "300",
        nzbDownload = "400",
        emuleDownload = "500",
        emuleUpload = "600",
        scheduleEnabled = false,
        emuleScheduleEnabled = false,
    )

    private fun failure() = DsmFailure(
        code = null,
        message = "Synthetic settings failure",
        recovery = "Refresh settings before continuing.",
    )

    private fun result(status: MutationResultStatus): MutationResult {
        val submitted = status in setOf(
            MutationResultStatus.CONFIRMED_SUCCESS,
            MutationResultStatus.PARTIAL_SUCCESS,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        )
        val counts = when (status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> MutationResultCounts(1, 0, 0)
            MutationResultStatus.PARTIAL_SUCCESS -> MutationResultCounts(1, 1, 0)
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            -> MutationResultCounts(0, 0, 1)
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> MutationResultCounts(0, 0, 0)
            MutationResultStatus.CONFIRMED_FAILURE,
            MutationResultStatus.PERMISSION_DENIED,
            MutationResultStatus.UNSUPPORTED,
            -> MutationResultCounts(0, 1, 0)
        }
        return MutationResult(
            schemaVersion = 1,
            status = status,
            operation = "downloadSettingsSave",
            submitted = submitted,
            requiresRefresh = status in setOf(
                MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            ),
            counts = counts,
            errorCategory = when (status) {
                MutationResultStatus.PERMISSION_DENIED -> MutationErrorCategory.PERMISSION
                MutationResultStatus.UNSUPPORTED -> MutationErrorCategory.UNSUPPORTED
                MutationResultStatus.CONFIRMED_FAILURE -> MutationErrorCategory.VALIDATION
                else -> null
            },
        )
    }
}

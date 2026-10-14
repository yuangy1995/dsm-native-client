package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferDirection
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.UploadMutationLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.TransferTaskDetails
import org.junit.Rule
import org.junit.Test

class UploadMutationUiTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 上传结果不明保留恢复提示且不重复单文件阶段计数() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val result = MutationResult(
            schemaVersion = 1,
            status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            operation = "fileUpload",
            submitted = true,
            requiresRefresh = true,
            counts = MutationResultCounts(0, 0, 1),
            diagnosticTag = "synthetic.file-upload.unverified",
        )
        val task = TransferTask(
            id = "synthetic-upload",
            title = "Synthetic upload",
            detail = "Upload needs attention",
            direction = TransferDirection.UPLOAD,
            state = TransferState.FAILED,
            requiresRefresh = true,
            uploadMutation = UploadMutationLifecycle(uploadResult = result),
        )

        rule.setContent { LanStashTheme { TransferTaskDetails(task) } }

        rule.onNodeWithText(context.getString(R.string.transfer_mutation_upload_stage))
            .assertDoesNotExist()
        rule.onNodeWithText(context.getString(R.string.upload_unverified))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.transfer_mutation_counts, 0, 0, 1))
            .assertDoesNotExist()
        rule.onNodeWithText(context.getString(R.string.transfer_refresh_before_retry))
            .assertDoesNotExist()
    }

    @Test
    fun 目录部分成功不冒充文件上传结果() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val result = MutationResult(
            schemaVersion = 1,
            status = MutationResultStatus.PARTIAL_SUCCESS,
            operation = "backupFolderEnsure",
            submitted = true,
            requiresRefresh = true,
            counts = MutationResultCounts(1, 1, 0),
            diagnosticTag = "synthetic.backup-folder.partial",
        )
        val task = TransferTask(
            id = "synthetic-folder",
            title = "Synthetic folder preparation",
            detail = "Folder needs attention",
            direction = TransferDirection.UPLOAD,
            state = TransferState.FAILED,
            requiresRefresh = true,
            uploadMutation = UploadMutationLifecycle(directoryResult = result),
        )

        rule.setContent { LanStashTheme { TransferTaskDetails(task) } }

        rule.onNodeWithText(context.getString(R.string.transfer_mutation_folder_stage))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.folder_create_partial))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.transfer_mutation_counts, 1, 1, 0))
            .assertIsDisplayed()
    }
}

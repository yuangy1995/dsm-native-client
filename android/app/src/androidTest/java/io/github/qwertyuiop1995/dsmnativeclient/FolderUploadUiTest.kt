package io.github.qwertyuiop1995.dsmnativeclient

import android.graphics.Bitmap
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.ui.FolderUploadContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** 生产目录预览和详情组件，使用明确合成的清单，检查触控与长列表状态。 */
class FolderUploadUiTest {
    @get:Rule val compose = createComposeRule()
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val plan = FolderUploadPlan(taskId = "synthetic-folder-ui", profileId = "synthetic", treeUri = "content://synthetic/tree",
        destinationPath = "/synthetic", entries = listOf(
            FolderUploadEntry(FolderUploadSource("root", "content://synthetic/root", "旅行 ", true)),
            FolderUploadEntry(FolderUploadSource("empty", "content://synthetic/empty", "旅行 /空文件夹", true)),
            FolderUploadEntry(FolderUploadSource("file", "content://synthetic/file", "旅行 /a.txt", false, bytes = 3)),
        ))

    @Test fun `预览保留空目录且默认一次按钮上传不覆盖`() {
        val submitted = mutableListOf<Boolean>()
        compose.setContent { LanStashTheme { FolderUploadContent(FolderUploadUiState(plan, preview = true), {}, submitted::add, {}) } }
        compose.onNodeWithText("旅行 /空文件夹").assertIsDisplayed()
        compose.onNodeWithTag("folder_upload_start").performClick()
        compose.runOnIdle { assertEquals(listOf(false), submitted) }
        capture("folder-preview")
    }

    @Test fun `覆盖说明明确后才交付覆盖授权`() {
        var submitted: Boolean? = null
        compose.setContent { LanStashTheme { FolderUploadContent(FolderUploadUiState(plan, preview = true), {}, { submitted = it }, {}) } }
        compose.onNodeWithText(text(R.string.folder_upload_replace)).performClick()
        compose.onNodeWithTag("folder_upload_start").performClick()
        compose.onNodeWithText(text(R.string.folder_upload_replace_warning)).assertIsDisplayed()
        compose.runOnIdle { assertNull(submitted) }
        capture("folder-overwrite")
        compose.onNodeWithText(text(R.string.folder_upload_replace_action)).performClick()
        compose.runOnIdle { assertEquals(true, submitted) }
    }

    @Test fun `逐项错误过滤空状态以及继续操作可达`() {
        val state = mutableStateOf(FolderUploadUiState(plan.copy(entries = plan.entries.map {
            it.copy(state = FolderUploadEntryState.SUCCEEDED)
        }), taskState = TransferState.SUCCEEDED))
        var continued = false
        compose.setContent { LanStashTheme { FolderUploadContent(state.value, {}, {}, { continued = true }) } }
        compose.onNodeWithText(text(R.string.folder_upload_problems)).performClick()
        compose.onNodeWithText(text(R.string.folder_upload_no_problems)).assertIsDisplayed()
        capture("folder-filter-empty")
        compose.runOnIdle { state.value = state.value.copy(plan = plan.copy(entries = plan.entries.map {
            if (it.source.id == "file") it.copy(state = FolderUploadEntryState.UNRESOLVED) else it.copy(state = FolderUploadEntryState.SUCCEEDED)
        }), taskState = TransferState.FAILED) }
        compose.onNodeWithText(text(R.string.folder_upload_interrupted)).assertIsDisplayed()
        compose.onNodeWithText(text(R.string.folder_upload_continue)).performClick()
        compose.runOnIdle { assertTrue(continued) }
        capture("folder-partial")
    }

    @Test fun `准备保存期间不能重复启动且错误可恢复关闭`() {
        val state = mutableStateOf(FolderUploadUiState(plan, preview = true, busy = true))
        var closed = false
        compose.setContent { LanStashTheme { FolderUploadContent(state.value, { closed = true }, { error("Busy task must not start") }, {}) } }
        compose.onNodeWithTag("folder_upload_start").assertIsNotEnabled()
        compose.runOnIdle { state.value = FolderUploadUiState(message = R.string.folder_upload_scan_failed) }
        compose.onNodeWithText(text(R.string.folder_upload_scan_failed)).assertIsDisplayed()
        compose.onNodeWithText(text(R.string.close)).performClick()
        compose.runOnIdle { assertTrue(closed) }
    }

    @Test fun `千项长清单末项可滚动定位`() {
        val long = plan.copy(entries = plan.entries + (1..997).map { index ->
            FolderUploadEntry(FolderUploadSource("file-$index", "content://synthetic/$index", "旅行 /item-$index.txt", false, bytes = 1))
        })
        compose.setContent { LanStashTheme { FolderUploadContent(FolderUploadUiState(long, preview = true), {}, {}, {}) } }
        compose.onNodeWithTag("folder_upload_items").performScrollToIndex(long.entries.lastIndex)
        compose.onNodeWithText("旅行 /item-997.txt").assertIsDisplayed()
        compose.onNodeWithTag("folder_upload_start").assertIsDisplayed()
        capture("folder-long-list")
    }

    private fun text(resource: Int) = context.getString(resource)
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val output = File(context.getExternalFilesDir(null), "folder-upload-review/$name.png")
        output.parentFile?.mkdirs(); output.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}

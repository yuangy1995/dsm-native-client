package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.systemfiles.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.SharedInputContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.*
import org.junit.Assert.*

/** 正式分享页面在深色二倍字号下的五态和重复操作保护。 */
class SharedInputStateUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun text(id: Int) = context.getString(id)
    @Test fun directoryFiveStatesAndBusyControls() {
        val profile = NasProfile("profile", "Synthetic connection", "https://synthetic.example.invalid", "synthetic")
        val owner = WorkspaceOwner(profile.id, "identity", "session")
        val folder = FileItem("/share", "share", true, canWrite = true, mountPointType = "normal")
        val child = folder.copy(path = "/share/folder", name = "Child folder")
        val batch = SharedBatch("batch", listOf(SharedFile("source", "Synthetic file.txt", "text/plain", 100)))
        var state by mutableStateOf(SharedInputState(visible = true, batches = listOf(batch), profileId = profile.id,
            owner = owner, path = folder.path, folder = folder, locations = Loadable.Loading))
        var sent = 0; var closed = 0; var retried = 0
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 2f)) {
                LanStashTheme(darkTheme = true) {
                    SharedInputContent(state, listOf(WorkspaceConnectionItem(profile, WorkspaceConnectionStatus.CONNECTED, true, true)),
                        { closed++ }, {}, { state = state.copy(filter = it) }, {}, {}, { retried++ }, {}, { sent++ }, {})
                }
            }
        }
        compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo)).onFirst().assertExists()
        compose.onNodeWithTag("shared_send").assertIsNotEnabled()
        compose.runOnIdle { state = state.copy(locations = Loadable.Ready(FilePage(emptyList(), 0, 0))) }
        compose.onNodeWithText(text(R.string.file_search_no_folders)).assertExists()
        compose.onNodeWithTag("shared_send").assertIsEnabled().assertHeightIsAtLeast(48.dp)
        compose.runOnIdle { state = state.copy(locations = Loadable.Ready(FilePage(listOf(child), 1, 0))) }
        compose.onNodeWithText(child.name).assertExists()
        compose.onNode(hasText(text(R.string.file_search_filter_folders)) and hasSetTextAction()).performTextInput("absent")
        compose.onNodeWithText(text(R.string.no_items_match_filter)).assertExists()
        compose.onNode(hasText("absent") and hasSetTextAction()).performTextClearance()
        compose.runOnIdle { state = state.copy(locations = Loadable.Failed(DsmFailure(null, "synthetic", "retry", kind = DsmErrorKind.REQUEST_FAILED))) }
        compose.onNode(hasText(text(R.string.retry)) and hasClickAction()).performScrollTo().performClick(); assertEquals(1, retried)
        compose.onNodeWithTag("shared_send").assertIsNotEnabled()
        compose.runOnIdle { state = state.copy(locations = Loadable.Ready(FilePage(emptyList(), 0, 0)), folder = folder.copy(canWrite = false)) }
        compose.onNodeWithText(text(R.string.shared_folder_read_only)).assertExists(); compose.onNodeWithTag("shared_send").assertIsNotEnabled()
        compose.runOnIdle { state = state.copy(folder = folder, busy = true) }
        compose.onNodeWithTag("shared_send").assertIsNotEnabled(); compose.onNodeWithTag("shared_discard").assertIsNotEnabled()
        assertEquals(0, sent); assertEquals(0, closed)
    }
    @Test fun intakeLoadingEmptyFailureAndNoConnectionsStayRecoverable() {
        var state by mutableStateOf(SharedInputState(visible = true, copying = true))
        var closed = 0
        compose.setContent { LanStashTheme {
            SharedInputContent(state, emptyList(), { closed++ }, {}, {}, {}, {}, {}, {}, {}, {})
        } }
        compose.onNodeWithText(text(R.string.shared_copying)).assertExists()
        compose.runOnIdle { state = state.copy(copying = false) }
        compose.onNodeWithText(text(R.string.shared_empty)).assertExists()
        compose.runOnIdle { state = state.copy(notice = R.string.shared_source_unavailable) }
        compose.onNodeWithText(text(R.string.shared_source_unavailable)).assertExists()
        compose.runOnIdle { state = state.copy(notice = null, batches = listOf(SharedBatch("batch", listOf(SharedFile("file", "Synthetic.txt", "text/plain", 3))))) }
        compose.onNodeWithText(text(R.string.shared_sign_in_first)).assertExists()
        compose.onNode(hasText(text(R.string.shared_later)) and hasClickAction()).performClick(); assertEquals(1, closed)
    }
}

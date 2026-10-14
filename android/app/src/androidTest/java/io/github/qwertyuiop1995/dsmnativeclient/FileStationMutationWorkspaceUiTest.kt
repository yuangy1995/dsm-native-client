package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.core.app.ApplicationProvider
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.ui.FileCopyMoveDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.FileStationMutationConfirmationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.FileStationNameEditorDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class FileStationMutationWorkspaceUiTest {
    @get:Rule val rule = createComposeRule()

    @Test
    fun 重命名草稿由Workspace驱动且系统重建不会重放确认() {
        val context = context()
        val restoration = StateRestorationTester(rule)
        var confirms = 0
        restoration.setContent {
            var draft by rememberSaveable { mutableStateOf(file().name) }
            LanStashTheme {
                FileStationNameEditorDialog(
                    state = FileStationMutationWorkspaceState(
                        editorVisible = true,
                        nameDraft = draft,
                        editorSourceBaseline = file(),
                    ),
                    onDraftChange = { draft = it; true },
                    onConfirm = { confirms += 1; false },
                    onDismiss = { false },
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.save)).assertIsNotEnabled()
        rule.onNodeWithText(context.getString(R.string.new_name))
            .performTextReplacement("renamed.txt")
        restoration.emulateSavedInstanceStateRestore()
        rule.onNodeWithText("renamed.txt").assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.save))
            .assertHeightIsAtLeast(48.dp)
            .performClick()
        rule.onNodeWithText(context.getString(R.string.rename)).assertIsDisplayed()
        rule.runOnIdle { check(confirms == 1) }
    }

    @Test
    fun 复制确认拒绝后仍保留且重建不会自动提交() {
        val context = context()
        val restoration = StateRestorationTester(rule)
        var confirms = 0
        restoration.setContent {
            var visible by rememberSaveable { mutableStateOf(true) }
            LanStashTheme {
                if (visible) {
                    FileStationMutationConfirmationDialog(
                        target = copyTarget(),
                        onConfirm = { confirms += 1; false },
                        onDismiss = { visible = false; true },
                    )
                }
            }
        }

        restoration.emulateSavedInstanceStateRestore()
        rule.runOnIdle { check(confirms == 0) }
        rule.onNodeWithText(context.getString(R.string.copy_action))
            .assertHeightIsAtLeast(48.dp)
            .performClick()
        rule.onNodeWithText(context.getString(R.string.confirm_copy_files)).assertIsDisplayed()
        rule.runOnIdle { check(confirms == 1) }
    }

    @Test
    fun 取消复制确认会返回目的地选择而不是丢弃草稿() {
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        val picker = FileCopyMoveState(
            items = listOf(file()),
            operation = FileCopyMoveOperation.COPY,
            location = FileCopyMoveLocation(destination().path, canWrite = true),
            destinationBaselines = mapOf(destination().path to destination()),
        )
        workspace(model).value = WorkspaceState(
            profile = profile(),
            fileCopyMove = picker,
            fileStationMutationState = FileStationMutationWorkspaceState(
                draftTarget = copyTarget(),
                confirmationRequested = true,
            ),
        )

        assertTrue(model.cancelPendingFileStationMutation())
        val state = checkNotNull(workspace(model).value)
        assertNotNull(state.fileCopyMove)
        assertTrue(state.fileStationMutationState.editorVisible)
        assertFalse(state.fileStationMutationState.confirmationRequested)
    }

    @Test
    fun 复制未提交失败继续编辑会返回目的地选择() {
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        workspace(model).value = WorkspaceState(
            profile = profile(),
            fileCopyMove = FileCopyMoveState(
                items = listOf(file()),
                operation = FileCopyMoveOperation.COPY,
                location = FileCopyMoveLocation(destination().path, canWrite = true),
                destinationBaselines = mapOf(destination().path to destination()),
            ),
            fileStationMutationState = FileStationMutationWorkspaceState(
                draftTarget = copyTarget(),
                target = copyTarget(),
                mutationResult = io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult(
                    schemaVersion = 1,
                    status = io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus.CONFIRMED_FAILURE,
                    operation = "fileCopy",
                    submitted = false,
                    requiresRefresh = false,
                    counts = io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts(0, 1, 0),
                ),
            ),
        )

        assertTrue(model.continueEditingFileStationMutation())
        val state = checkNotNull(workspace(model).value)
        assertNotNull(state.fileCopyMove)
        assertTrue(state.fileStationMutationState.editorVisible)
        assertFalse(state.fileStationMutationState.confirmationRequested)
        assertFalse(state.fileStationMutationState.mutationInProgress)
    }

    @Test
    fun 跨Nas目标选择显示有界传输说明() {
        val context = context()
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        val source = profile()
        val target = profile(id = "profile-target", name = "Backup NAS")
        val state = WorkspaceState(
            profile = source,
            fileCopyMove = FileCopyMoveState(
                items = listOf(file()),
                operation = FileCopyMoveOperation.COPY,
                sourceProfileId = source.id,
                targetProfileId = target.id,
                targetProfiles = listOf(source, target),
                location = FileCopyMoveLocation(destination().path, canWrite = true),
                destinationBaselines = mapOf(destination().path to destination()),
            ),
            fileCopyMoveFolders = Loadable.Ready(
                io.github.qwertyuiop1995.dsmnativeclient.domain.FilePage(emptyList(), 0, 0),
            ),
        )
        rule.setContent { LanStashTheme { FileCopyMoveDialog(state, model) } }

        rule.onNodeWithText(context.getString(R.string.file_copy_move_destination_nas))
            .assertIsDisplayed()
        rule.onNodeWithText("Backup NAS").assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.file_copy_move_cross_nas_hint))
            .assertDoesNotExist()
        rule.onNodeWithText(context.getString(R.string.copy_here)).assertIsEnabled()
    }

    @Test
    fun 跨Nas文件夹移动允许先复制且说明删源为后续独立选择() {
        val context = context()
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        val source = profile()
        val target = profile(id = "profile-target", name = "Backup NAS")
        val state = WorkspaceState(
            profile = source,
            fileCopyMove = FileCopyMoveState(
                items = listOf(destination().copy(path = "/synthetic/source-folder")),
                operation = FileCopyMoveOperation.MOVE,
                sourceProfileId = source.id,
                targetProfileId = target.id,
                targetProfiles = listOf(source, target),
                location = FileCopyMoveLocation(destination().path, canWrite = true),
                destinationBaselines = mapOf(destination().path to destination()),
            ),
            fileCopyMoveFolders = Loadable.Ready(
                io.github.qwertyuiop1995.dsmnativeclient.domain.FilePage(emptyList(), 0, 0),
            ),
        )
        rule.setContent { LanStashTheme { FileCopyMoveDialog(state, model) } }

        rule.onNodeWithText(
            context.getString(R.string.file_copy_move_cross_nas_hint),
        ).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.move_here)).assertIsEnabled()
    }

    @Test
    fun 同名Nas选择器使用账号区别源和目标() {
        val context = context(); val source = profile(name = "NAS").copy(username = "alpha")
        val target = profile(id = "profile-target", name = "NAS").copy(username = "beta")
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        val state = WorkspaceState(profile = source, fileCopyMove = FileCopyMoveState(listOf(file()), FileCopyMoveOperation.MOVE,
            source.id, target.id, listOf(source, target), FileCopyMoveLocation(destination().path, true),
            destinationBaselines = mapOf(destination().path to destination())),
            fileCopyMoveFolders = Loadable.Ready(io.github.qwertyuiop1995.dsmnativeclient.domain.FilePage(emptyList(), 0, 0)))
        rule.setContent { LanStashTheme { FileCopyMoveDialog(state, model) } }
        rule.onNodeWithText(context.getString(R.string.workspace_account_page, "NAS", "beta")).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.file_copy_move_current_nas,
            context.getString(R.string.workspace_account_page, "NAS", "alpha"))).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.move_here)).assertIsEnabled()
    }

    private fun context() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun profile(
        id: String = "profile-synthetic",
        name: String = "Synthetic",
    ) = io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile(
        id = id,
        name = name,
        address = "https://nas.example.invalid",
        username = "operator",
    )

    @Suppress("UNCHECKED_CAST")
    private fun workspace(model: AppViewModel): MutableStateFlow<WorkspaceState?> {
        val field = AppViewModel::class.java.getDeclaredField("_workspace").apply {
            isAccessible = true
        }
        return field.get(model) as MutableStateFlow<WorkspaceState?>
    }

    private fun file() = FileItem(
        path = "/synthetic/source.txt",
        name = "source.txt",
        isDirectory = false,
        canRead = true,
        canWrite = true,
    )

    private fun destination() = FileItem(
        path = "/synthetic/destination",
        name = "destination",
        isDirectory = true,
        canRead = true,
        canWrite = true,
    )

    private fun copyTarget() = FileStationMutationTarget(
        profileId = "profile-synthetic",
        module = Module.FILES,
        operation = FileStationMutationOperation.COPY,
        sourceBaselines = listOf(file()),
        destinationPath = destination().path,
        destinationBaseline = destination(),
    )
}

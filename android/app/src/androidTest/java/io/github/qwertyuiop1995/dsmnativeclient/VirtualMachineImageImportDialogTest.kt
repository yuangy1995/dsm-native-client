package io.github.qwertyuiop1995.dsmnativeclient

import android.view.KeyEvent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasProgressBarRangeInfo
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResource
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VirtualMachineImageImportDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

class VirtualMachineImageImportDialogTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 系统返回优先退出当前NAS目录而不关闭映像表单() {
        var draft by mutableStateOf(
            VirtualMachineImageImportDraftState(
                storage = storage(),
                browserPath = "/share/images",
                browserHistory = listOf("", "/share"),
                browserItems = Loadable.Ready(FilePage(emptyList(), 0, 0)),
            ),
        )
        var dismissCount = 0
        rule.setContent {
            LanStashTheme {
                dialog(
                    draft = draft,
                    onBack = {
                        draft = draft.copy(
                            browserPath = draft.browserHistory.last(),
                            browserHistory = draft.browserHistory.dropLast(1),
                        )
                        true
                    },
                    onDismiss = { dismissCount++; true },
                )
            }
        }

        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)

        rule.runOnIdle {
            check(draft.browserPath == "/share")
            check(dismissCount == 0)
        }
    }

    @Test
    fun 两倍字体下三种映像类型可见且可换行() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        rule.setContent {
            CompositionLocalProvider(LocalDensity provides Density(1f, 2f)) {
                LanStashTheme {
                    dialog(
                        draft = VirtualMachineImageImportDraftState(
                            storage = storage(),
                            browserItems = Loadable.Ready(FilePage(emptyList(), 0, 0)),
                        ),
                    )
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.virtual_machine_image_type_disk))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.virtual_machine_image_type_vdsm))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.virtual_machine_image_type_iso))
            .assertIsDisplayed()
            .performClick()
    }

    @Test
    fun 根目录系统返回关闭表单() {
        var dismissCount = 0
        rule.setContent {
            LanStashTheme {
                dialog(
                    draft = draft(Loadable.Ready(FilePage(emptyList(), 0, 0))),
                    onDismiss = { dismissCount++; true },
                )
            }
        }

        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)

        rule.runOnIdle { check(dismissCount == 1) }
    }

    @Test
    fun 文件浏览加载错误重试空内容和正常内容均可操作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var content: Loadable<FilePage> by mutableStateOf(Loadable.Loading)
        var retryCount = 0
        var opened: String? = null
        var selected: String? = null
        rule.setContent {
            LanStashTheme {
                dialog(
                    draft = draft(content),
                    onRetry = { retryCount++; true },
                    onOpenFolder = { opened = it.path; true },
                    onSelectFile = { selected = it.path; true },
                )
            }
        }

        rule.onNode(hasProgressBarRangeInfo(ProgressBarRangeInfo.Indeterminate)).assertIsDisplayed()
        rule.runOnIdle {
            content = Loadable.Failed(DsmFailure(null, "Synthetic failure", "Retry"))
        }
        rule.onNodeWithText(context.getString(R.string.virtual_machine_image_browser_failed))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.retry)).performClick()
        rule.runOnIdle {
            check(retryCount == 1)
            content = Loadable.Ready(FilePage(emptyList(), 0, 0))
        }
        rule.onNodeWithText(context.getString(R.string.virtual_machine_image_browser_empty))
            .assertIsDisplayed()
        rule.runOnIdle {
            content = Loadable.Ready(
                FilePage(
                    listOf(
                        file("/share/images", "images", isDirectory = true),
                        file("/share/synthetic.img", "synthetic.img"),
                    ),
                    0,
                    2,
                ),
            )
        }
        rule.onNodeWithText("images").performScrollTo().assertIsDisplayed().performClick()
        rule.onNodeWithText("synthetic.img").performScrollTo().assertIsDisplayed().performClick()
        rule.runOnIdle {
            check(opened == "/share/images")
            check(selected == "/share/synthetic.img")
        }
    }

    @Test
    fun 提交中阻断表单按钮和文件选择() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var selected = false
        var confirmed = false
        var dismissed = false
        val source = file("/share/synthetic.img", "synthetic.img")
        rule.setContent {
            LanStashTheme {
                dialog(
                    draft = draft(Loadable.Ready(FilePage(listOf(source), 0, 1))).copy(
                        imageName = "Synthetic image",
                        sourceFile = source,
                    ),
                    submitting = true,
                    onSelectFile = { selected = true; true },
                    onConfirm = { confirmed = true; true },
                    onDismiss = { dismissed = true; true },
                )
            }
        }

        val radioRole = SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.RadioButton)
        rule.onNode(hasText("synthetic.img") and radioRole)
            .assertIsSelected()
            .assertIsNotEnabled()
        rule.onNode(hasText("Synthetic storage") and radioRole)
            .assertIsSelected()
            .assertIsNotEnabled()
        rule.onNode(hasText(context.getString(R.string.virtual_machine_image_import_confirm)) and hasClickAction())
            .assertIsNotEnabled()
        rule.onNodeWithText(context.getString(R.string.cancel)).assertIsNotEnabled()
        rule.runOnIdle {
            check(!selected)
            check(!confirmed)
            check(!dismissed)
        }
    }

    @Test
    fun 本地来源显示OVA与大小错误并在两TiB边界允许提交() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var draft by mutableStateOf(
            VirtualMachineImageImportDraftState(
                imageName = "Local disk",
                source = VirtualMachineImageImportSource.LOCAL,
                storage = storage(),
                localFile = VirtualMachineLocalImageSelection("machine.ova", 1L),
                localStagingDirectory = stagingDirectory(),
            ),
        )
        var submitted = false
        rule.setContent {
            CompositionLocalProvider(LocalDensity provides Density(1f, 2f)) {
                LanStashTheme {
                    dialog(
                        draft = draft,
                        onDraftChange = { draft = it; true },
                        onConfirmLocal = { submitted = true; true },
                    )
                }
            }
        }

        rule.onNodeWithText(context.getString(R.string.virtual_machine_local_image_ova_unsupported))
            .performScrollTo()
            .assertIsDisplayed()
        rule.runOnIdle {
            draft = draft.copy(
                localFile = VirtualMachineLocalImageSelection(
                    "machine.vhdx",
                    2_199_023_255_553L,
                ),
            )
        }
        rule.onNodeWithText(context.getString(R.string.virtual_machine_local_image_disk_too_large))
            .performScrollTo()
            .assertIsDisplayed()
        rule.runOnIdle {
            draft = draft.copy(
                localFile = VirtualMachineLocalImageSelection(
                    "machine.vhdx",
                    2_199_023_255_552L,
                ),
            )
        }
        rule.onNodeWithText(context.getString(R.string.virtual_machine_local_image_choose_another_file))
            .performScrollTo()
            .assertHeightIsAtLeast(48.dp)
        rule.onNodeWithText(context.getString(R.string.virtual_machine_local_image_cleanup_notice))
            .performScrollTo()
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.virtual_machine_local_image_import_confirm))
            .assertIsEnabled()
            .performClick()
        rule.runOnIdle { check(submitted) }
    }

    @Test
    fun 本地来源五状态可恢复且提交中锁定选择与返回() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var fileRequests = 0
        var directoryRequests = 0
        var dismissed = false
        val base = VirtualMachineImageImportDraftState(
            imageName = "Local ISO",
            source = VirtualMachineImageImportSource.LOCAL,
            storage = storage(),
        )
        var draft by mutableStateOf(base)
        var submitting by mutableStateOf(false)
        rule.setContent {
            LanStashTheme {
                dialog(
                    draft = draft,
                    submitting = submitting,
                    onRequestLocalFile = { fileRequests++; true },
                    onSelectStagingDirectory = { directoryRequests++; true },
                    onDismiss = { dismissed = true; true },
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.virtual_machine_image_no_file))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.virtual_machine_local_image_choose_file))
            .performScrollTo()
            .performClick()
        rule.runOnIdle {
            check(fileRequests == 1)
            draft = draft.copy(localFile = VirtualMachineLocalImageSelection("installer.iso", null))
        }
        rule.onNodeWithText(context.getString(R.string.virtual_machine_local_image_size_unknown_error))
            .performScrollTo()
            .assertIsDisplayed()
        rule.runOnIdle {
            draft = draft.copy(
                localFile = VirtualMachineLocalImageSelection("installer.iso", 4096L),
                browserItems = Loadable.Ready(FilePage(listOf(stagingDirectory()), 0, 1)),
            )
        }
        rule.onNodeWithText(context.getString(R.string.virtual_machine_local_image_detected_type, context.getString(R.string.virtual_machine_image_type_iso)))
            .performScrollTo()
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.virtual_machine_local_image_no_staging_directory))
            .performScrollTo()
            .assertIsDisplayed()
        rule.onNodeWithText(
            context.getString(R.string.virtual_machine_local_image_use_staging_directory, "staging"),
        )
            .performScrollTo()
            .performClick()
        rule.runOnIdle {
            check(directoryRequests == 1)
            draft = draft.copy(localStagingDirectory = stagingDirectory())
            submitting = true
        }
        rule.onNodeWithText(context.getString(R.string.virtual_machine_local_image_choose_another_file))
            .performScrollTo()
            .assertIsNotEnabled()
        rule.onNodeWithText(
            context.getString(R.string.virtual_machine_local_image_use_staging_directory, "staging"),
        )
            .performScrollTo()
            .assertIsNotEnabled()
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        rule.runOnIdle { check(!dismissed) }
    }

    @androidx.compose.runtime.Composable
    private fun dialog(
        draft: VirtualMachineImageImportDraftState,
        submitting: Boolean = false,
        onBack: () -> Boolean = { true },
        onDismiss: () -> Boolean = { true },
        onRetry: () -> Boolean = { true },
        onOpenFolder: (FileItem) -> Boolean = { true },
        onSelectFile: (FileItem) -> Boolean = { true },
        onDraftChange: (VirtualMachineImageImportDraftState) -> Boolean = { true },
        onConfirm: () -> Boolean = { true },
        onRequestLocalFile: () -> Boolean = { true },
        onSelectStagingDirectory: (FileItem) -> Boolean = { true },
        onConfirmLocal: (VirtualMachineLocalImageImportSubmission) -> Boolean = { true },
    ) {
        VirtualMachineImageImportDialog(
            draft = draft,
            storages = listOf(storage()),
            submitting = submitting,
            onDraftChange = onDraftChange,
            onOpenFolder = onOpenFolder,
            onBackFolder = onBack,
            onSelectFile = onSelectFile,
            onRetry = onRetry,
            onConfirm = onConfirm,
            onDismiss = onDismiss,
            onRequestLocalFile = onRequestLocalFile,
            onSelectStagingDirectory = onSelectStagingDirectory,
            onConfirmLocal = onConfirmLocal,
        )
    }

    private fun draft(content: Loadable<FilePage>) = VirtualMachineImageImportDraftState(
        storage = storage(),
        browserItems = content,
    )

    private fun file(path: String, name: String, isDirectory: Boolean = false) = FileItem(
        path = path,
        name = name,
        isDirectory = isDirectory,
        canRead = true,
    )

    private fun storage() = ManagedResource(
        id = "storage-1",
        name = "Synthetic storage",
        detail = "online",
        state = ResourceState.RUNNING,
        metadata = mapOf("status" to "online"),
    )

    private fun stagingDirectory() = FileItem(
        path = "/share/staging",
        name = "staging",
        isDirectory = true,
        canRead = true,
        canWrite = true,
    )
}

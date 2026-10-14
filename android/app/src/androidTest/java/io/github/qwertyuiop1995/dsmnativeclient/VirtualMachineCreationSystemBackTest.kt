package io.github.qwertyuiop1995.dsmnativeclient

import android.view.KeyEvent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VmmCreationSheet
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmCreationDraft
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

class VirtualMachineCreationSystemBackTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 系统返回从第三步回到第二步并保留草稿() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var draft by mutableStateOf(creationDraft(step = 2))
        var dismissCount = 0
        rule.setContent {
            LanStashTheme {
                VmmCreationSheet(
                    state = creationUiState().copy(draft = draft),
                    onChange = { draft = it },
                    onCreate = {}, onRetry = {}, onContinue = {},
                    onClose = { dismissCount++ },
                )
            }
        }

        pressSystemBack()

        rule.onNodeWithText(context.getString(R.string.virtual_machine_cpu)).assertIsDisplayed()
        rule.runOnIdle {
            check(draft.step == 1)
            check(draft.name == "Synthetic VM")
            check(dismissCount == 0)
        }
    }

    @Test
    fun 系统返回从第二步回到第一步() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var draft by mutableStateOf(creationDraft(step = 1))
        rule.setContent {
            LanStashTheme {
                VmmCreationSheet(
                    state = creationUiState().copy(draft = draft),
                    onChange = { draft = it },
                    onCreate = {}, onRetry = {}, onContinue = {},
                    onClose = {},
                )
            }
        }

        pressSystemBack()

        rule.onNodeWithText(context.getString(R.string.virtual_machine_name)).assertIsDisplayed()
        rule.runOnIdle { check(draft.step == 0) }
    }

    @Test
    fun 系统返回在第一步请求关闭向导() {
        var visible by mutableStateOf(true)
        var dismissCount = 0
        rule.setContent {
            LanStashTheme {
                if (visible) {
                    VmmCreationSheet(
                        state = creationUiState(),
                        onChange = {},
                        onCreate = {}, onRetry = {}, onContinue = {},
                        onClose = {
                            dismissCount++
                            visible = false
                        },
                    )
                }
            }
        }

        pressSystemBack()

        rule.runOnIdle {
            check(!visible)
            check(dismissCount == 1)
        }
    }

    @Test
    fun 提交期间系统返回不改变步骤也不请求关闭() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var draft by mutableStateOf(creationDraft(step = 2))
        var draftChangeCount = 0
        var dismissCount = 0
        rule.setContent {
            LanStashTheme {
                VmmCreationSheet(
                    state = creationUiState().copy(draft = draft, busy = true),
                    onChange = {
                        draftChangeCount++
                        draft = it
                    },
                    onCreate = {}, onRetry = {}, onContinue = {},
                    onClose = { dismissCount++ },
                )
            }
        }

        pressSystemBack()

        rule.onNodeWithText(context.getString(R.string.create_virtual_machine)).assertIsDisplayed()
        rule.runOnIdle {
            check(draft.step == 2)
            check(draftChangeCount == 0)
            check(dismissCount == 0)
        }
    }

    @Test
    fun 业务门禁拒绝退出时系统返回保持当前步骤() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val draft = creationDraft(step = 2)
        var draftChangeCount = 0
        rule.setContent {
            LanStashTheme {
                VmmCreationSheet(
                    state = creationUiState().copy(draft = draft),
                    onChange = {
                        draftChangeCount++
                    },
                    onCreate = {}, onRetry = {}, onContinue = {},
                    onClose = {},
                )
            }
        }

        pressSystemBack()

        rule.onNodeWithText(context.getString(R.string.virtual_machine_storage)).assertIsDisplayed()
        rule.runOnIdle { check(draftChangeCount == 1) }
    }

    private fun creationDraft(step: Int) = VmmCreationDraft(step = step, name = "Synthetic VM", storage = "storage-1")

    private fun pressSystemBack() {
        rule.waitForIdle()
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
    }
}

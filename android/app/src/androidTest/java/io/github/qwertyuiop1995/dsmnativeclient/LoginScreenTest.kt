package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelProvider
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class LoginScreenTest {
    @get:Rule
    val rule = createAndroidComposeRule<MainActivity>()

    @Test
    fun 登录页显示完整必要字段和主操作() {
        fun text(id: Int) = rule.activity.getString(id)
        rule.onNodeWithText(text(R.string.client_connect_nas)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.nas_address_or_quickconnect)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.account)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.password)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.remember_password)).performScrollTo().assertIsDisplayed()
            .assertHeightIsAtLeast(48.dp)
        rule.onNodeWithText(text(R.string.auto_login)).performScrollTo().assertIsDisplayed()
        rule.onAllNodesWithText(text(R.string.custom_https_port)).assertCountEquals(0)
        rule.onNodeWithText(text(R.string.client_more_connection_options)).performScrollTo().performClick()
        rule.waitUntil(timeoutMillis = 5_000) {
            rule.onAllNodesWithText(text(R.string.custom_https_port)).fetchSemanticsNodes().isNotEmpty()
        }
        rule.onNodeWithText(text(R.string.custom_https_port)).performScrollTo().assertIsDisplayed()
        rule.onNodeWithText(text(R.string.connect)).assertIsDisplayed()
            .assertHeightIsAtLeast(48.dp)
    }

    @Test
    fun Activity重建仅恢复非敏感登录字段并清空临时凭据() {
        showSyntheticLoginState(needsOtp = true)

        rule.onNodeWithText(rule.activity.getString(R.string.client_more_connection_options)).performScrollTo()
            .performSemanticsAction(SemanticsActions.OnClick) { it() }
        rule.onNodeWithTag("login_name").performScrollTo().performTextInput("Synthetic NAS")
        rule.onNodeWithTag("login_address").performScrollTo().performTextInput("nas.example.invalid")
        rule.onNodeWithTag("login_username").performScrollTo().performTextInput("synthetic-user")
        rule.onNodeWithTag("login_password").performScrollTo().performTextInput("temporary-password")
        // 填完目标信息后模拟 NAS 要求验证码；编辑目标会正确清除旧挑战。
        showSyntheticLoginState(needsOtp = true)
        rule.onNodeWithTag("login_otp").performScrollTo().performTextInput("123456")

        rule.activityRule.scenario.recreate()
        rule.waitForIdle()

        assertEquals("Synthetic NAS", editableText("login_name"))
        assertEquals("nas.example.invalid", editableText("login_address"))
        assertEquals("synthetic-user", editableText("login_username"))
        assertTrue(editableText("login_password").isEmpty())
        assertTrue(editableText("login_otp").isEmpty())
    }

    @Test
    fun Activity重建后仍从登录状态恢复明确保存的密码() {
        showSyntheticLoginState(
            needsOtp = true,
            savedPassword = "synthetic-saved-password",
            rememberPassword = true,
        )

        rule.activityRule.scenario.recreate()
        rule.waitForIdle()

        assertEquals("synthetic-saved-password".length, editableText("login_password").length)
        assertTrue(editableText("login_otp").isEmpty())
    }

    @Test
    fun 修改连接目标后不会将原密码和验证码恢复到新目标() {
        showSyntheticLoginState(needsOtp = true, savedPassword = "synthetic-saved-password", rememberPassword = true)
        rule.onNodeWithTag("login_otp").performScrollTo().performTextInput("123456")
        rule.onNodeWithTag("login_address").performScrollTo().performTextReplacement("https://other.example.invalid")
        rule.waitForIdle()
        assertTrue(editableText("login_password").isEmpty())
        rule.onNodeWithTag("login_otp").assertDoesNotExist()
        rule.activityRule.scenario.recreate()
        rule.waitForIdle()
        assertEquals("https://other.example.invalid", editableText("login_address"))
        assertTrue(editableText("login_password").isEmpty())
        rule.onNodeWithTag("login_otp").assertDoesNotExist()
    }

    @Suppress("UNCHECKED_CAST")
    private fun showSyntheticLoginState(
        needsOtp: Boolean,
        savedPassword: String = "",
        rememberPassword: Boolean = false,
    ) {
        rule.runOnUiThread {
            val model = ViewModelProvider(rule.activity)[WorkspaceHostModel::class.java].active.value.model
            val loginField = AppViewModel::class.java.getDeclaredField("_login").apply {
                isAccessible = true
            }
            val loginState = loginField.get(model) as MutableStateFlow<LoginState>
            val profile = io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile(
                "synthetic-login-profile", "Synthetic NAS", "https://nas.example.invalid", "synthetic-user")
            loginState.value = LoginState(
                profiles = if (rememberPassword) listOf(profile) else emptyList(),
                selectedProfileId = profile.id.takeIf { rememberPassword },
                savedPassword = savedPassword,
                rememberPassword = rememberPassword,
                needsOtp = needsOtp,
            )
        }
        rule.waitUntil(timeoutMillis = 5_000) {
            rule.onAllNodesWithText(rule.activity.getString(R.string.two_factor_code))
                .fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun editableText(tag: String): String =
        rule.onNodeWithTag(tag).fetchSemanticsNode().config[SemanticsProperties.EditableText].text
}

package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.network.ConnectionStatus
import io.github.qwertyuiop1995.dsmnativeclient.ui.login.LoginScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.login.LoginConnectionOverlay
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ApprovedLoginUiTest {
    @get:Rule val rule = createComposeRule()
    private val store = ViewModelStore()
    private fun text(id: Int) = InstrumentationRegistry.getInstrumentation().targetContext.getString(id)
    private fun model() = AppViewModel(ApplicationProvider.getApplicationContext<Application>()).also { store.put("login", it) }
    @After fun release() { store.clear() }

    @Test fun 已保存设备先展示选择页面而不是长表单() {
        val model = model()
        rule.setContent { LanStashTheme { LoginScreen(LoginState(profiles = listOf(ApprovedUiFixture.profile)), model) } }
        rule.onNodeWithText(text(R.string.client_login_choose)).assertIsDisplayed()
        rule.onNodeWithText(ApprovedUiFixture.profile.name).assertIsDisplayed()
        rule.onNodeWithTag("login_address").assertDoesNotExist()
        rule.onNodeWithText(text(R.string.client_add_nas)).performClick()
        rule.onNodeWithTag("login_address").assertIsDisplayed()
    }
    @Test fun 登录中使用真正的全局弹层并显示真实阶段() {
        val model = model()
        rule.setContent { LanStashTheme { LoginScreen(LoginState(isConnecting = true, connectionStatus = ConnectionStatus.AUTHENTICATING), model) } }
        rule.onNode(isDialog()).assertExists()
        rule.onNodeWithText(text(R.string.client_connecting)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.client_authenticating)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.client_cancel_connection)).assertIsDisplayed().assertHasClickAction()
    }
    @Test fun 取消按钮只调用一次取消事件() {
        var cancelled = 0
        var visible by mutableStateOf(true)
        rule.setContent { LanStashTheme { if (visible) LoginConnectionOverlay(ConnectionStatus.CONNECTING_DIRECT, true) { cancelled++; visible = false } } }
        rule.onNodeWithText(text(R.string.client_cancel_connection)).performClick()
        rule.onNode(isDialog()).assertDoesNotExist()
        rule.runOnIdle { assertEquals(1, cancelled) }
    }
    @Test fun 二次验证状态回到表单且不被加载层遮挡() {
        val model = model()
        var state by mutableStateOf(LoginState(isConnecting = true, connectionStatus = ConnectionStatus.AUTHENTICATING))
        rule.setContent { LanStashTheme { LoginScreen(state, model) } }
        rule.runOnIdle { state = LoginState(needsOtp = true) }
        rule.onNode(isDialog()).assertDoesNotExist()
        rule.onNodeWithTag("login_otp").performScrollTo().assertIsDisplayed()
    }
}

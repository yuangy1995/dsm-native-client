package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import io.github.qwertyuiop1995.dsmnativeclient.domain.ActiveConnection
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test

class ConnectionConfirmationRestorationTest {
    @get:Rule
    val rule = createAndroidComposeRule<MainActivity>()

    @Test
    fun 当前连接确认跨Activity配置重建保留同一安全目标且取消不提交() {
        val connection = ActiveConnection(
            id = "synthetic-connection",
            user = "operator",
            service = "HTTPS",
            client = "Synthetic browser",
            connectedAtEpochSeconds = null,
            isCurrent = false,
            deviceId = "private-device-id-not-shown",
            type = "HTTP/HTTPS",
            canDisconnect = true,
        )
        rule.runOnIdle {
            connectionState(rule.activity).value = io.github.qwertyuiop1995.dsmnativeclient.nas.NasConnectionState(confirmation = connection)
            assertEquals(connection, connectionState(rule.activity).value.confirmation)
        }
        rule.activityRule.scenario.recreate()
        rule.runOnIdle {
            assertEquals(connection, connectionState(rule.activity).value.confirmation)
            ViewModelProvider(rule.activity)[AppViewModel::class.java].nasConnections.cancel()
            val state = connectionState(rule.activity).value
            assertNull(state.confirmation)
            assertNull(state.record)
            assertEquals(false, state.busy)
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun connectionState(activity: MainActivity): MutableStateFlow<io.github.qwertyuiop1995.dsmnativeclient.nas.NasConnectionState> {
        val model = ViewModelProvider(activity)[AppViewModel::class.java].nasConnections
        val field = model.javaClass.getDeclaredField("mutable").apply { isAccessible = true }
        return field.get(model) as MutableStateFlow<io.github.qwertyuiop1995.dsmnativeclient.nas.NasConnectionState>
    }
}

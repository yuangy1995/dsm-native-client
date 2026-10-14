package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.network.VmmConsolePhase
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VmmConsoleContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.VmmConsoleState
import org.junit.*
import org.junit.Assert.*

class VmmConsoleUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val target = VmmControlTarget("guest", "Synthetic virtual machine with a long name", "running", emptySet())
    @Test fun connectingThenDisconnectedOffersManualReconnectAndClose() {
        var state by mutableStateOf(VmmConsoleState(target, phase = VmmConsolePhase.LOADING))
        var reconnected = 0; var closed = 0
        compose.setContent { LanStashTheme { VmmConsoleContent(state, { closed++ }, { reconnected++ }) } }
        compose.onNodeWithText(context.getString(R.string.vm_console_connecting)).assertIsDisplayed()
        compose.onNodeWithText(context.getString(R.string.vm_console_reconnect)).assertDoesNotExist()
        compose.runOnIdle { state = state.copy(phase = VmmConsolePhase.DISCONNECTED) }
        compose.onNodeWithText(context.getString(R.string.vm_console_disconnected)).assertIsDisplayed()
        compose.onNodeWithText(context.getString(R.string.vm_console_reconnect)).assertHeightIsAtLeast(48.dp).performClick()
        assertEquals(1, reconnected)
        compose.onNodeWithContentDescription(context.getString(R.string.go_up)).performClick(); assertEquals(1, closed)
    }
    @Test fun failureHasRecoveryWithDarkThemeAndDoubleSizeText() {
        var reconnects = 0
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 2f)) {
                LanStashTheme(darkTheme = true) {
                    VmmConsoleContent(VmmConsoleState(target, phase = VmmConsolePhase.FAILED, failure = VmmConsoleFailure(VmmConsoleProblem.RESPONSE)), {}, { reconnects++ })
                }
            }
        }
        compose.onNodeWithText(context.getString(R.string.vm_console_failed)).assertIsDisplayed()
        compose.onNodeWithText(context.getString(R.string.vm_console_reconnect)).assertIsDisplayed().performClick(); assertEquals(1, reconnects)
        compose.onNodeWithContentDescription(context.getString(R.string.go_up)).assertIsDisplayed()
    }
}

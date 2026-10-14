package io.github.qwertyuiop1995.dsmnativeclient

import android.Manifest
import android.content.pm.PackageManager
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.network.LocalNetworkAccess
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** 在专用 API 37 模拟器、初始未授权条件下操作真实系统授权窗口，不访问任何 NAS。 */
@SdkSuppress(minSdkVersion = 37)
class LocalNetworkPermissionUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun `系统拒绝保留重试并在Activity重建后允许原连接继续`() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertEquals(PackageManager.PERMISSION_DENIED, context.checkSelfPermission(Manifest.permission.ACCESS_LOCAL_NETWORK))
        lateinit var model: AppViewModel
        compose.runOnIdle { model = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java].active.value.model }
        assertNull(model.workspace.value)
        var result: Boolean? = null
        lateinit var job: Job
        compose.runOnIdle { job = model.viewModelScope.launch { result = model.localNetworkPermission.request() } }
        clickSystemButton("permission_deny_button")
        compose.waitUntil(10_000) { job.isCompleted }
        assertEquals(false, result); assertNull(model.localNetworkPermission.pending.value)
        assertFalse(LocalNetworkAccess(context).granted())

        val previousActivity = compose.activity
        compose.runOnIdle { job = model.viewModelScope.launch { result = model.localNetworkPermission.request() } }
        waitForSystemButton("permission_allow_button")
        // 系统授权窗口使 Activity 暂停；Scenario.recreate 会先强等 RESUMED，不能用于此场景。
        instrumentation.runOnMainSync { previousActivity.recreate() }
        clickSystemButton("permission_allow_button")
        compose.waitUntil(10_000) { job.isCompleted }
        assertEquals(true, result); assertNull(model.localNetworkPermission.pending.value)
        assertTrue(LocalNetworkAccess(context).granted())
        assertNotSame(previousActivity, compose.activity)
        compose.runOnIdle { assertSame(model, ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java].active.value.model) }
    }

    private fun waitForSystemButton(id: String): AccessibilityNodeInfo {
        var target: AccessibilityNodeInfo? = null
        compose.waitUntil(10_000) {
            val root = InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow
            target = root?.findAccessibilityNodeInfosByViewId("com.android.permissioncontroller:id/$id")?.firstOrNull()
            target != null
        }
        return requireNotNull(target)
    }

    private fun clickSystemButton(id: String) {
        assertTrue(waitForSystemButton(id).performAction(AccessibilityNodeInfo.ACTION_CLICK))
    }
}

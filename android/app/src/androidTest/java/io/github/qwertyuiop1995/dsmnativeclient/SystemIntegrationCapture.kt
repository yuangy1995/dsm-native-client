package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Activity
import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** 仅显式采集参数启用，合成系统流程的截图与布局配置供设备验收复核。 */
internal fun captureSystemIntegration(activity: Activity, name: String) {
    if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val rendered = CountDownLatch(1)
    instrumentation.runOnMainSync { activity.window.decorView.postOnAnimation {
        activity.window.decorView.postOnAnimation { rendered.countDown() }
    } }
    check(rendered.await(2, TimeUnit.SECONDS)); instrumentation.waitForIdleSync()
    val directory = File(activity.getExternalFilesDir(null), "system-review").apply { mkdirs() }
    val image = instrumentation.uiAutomation.takeScreenshot()
    File(directory, "$name.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }; image.recycle()
    val configuration = activity.resources.configuration
    File(directory, "configuration.txt").writeText("locales=${configuration.locales.toLanguageTags()}\nfontScale=${configuration.fontScale}\nuiMode=${configuration.uiMode}\nwidthDp=${configuration.screenWidthDp}\nheightDp=${configuration.screenHeightDp}\n")
}

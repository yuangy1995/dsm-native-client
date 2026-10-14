package io.github.qwertyuiop1995.dsmnativeclient

import android.os.SystemClock
import android.view.KeyEvent
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.ui.MediaPreview
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.*
import org.junit.Assert.*

/** 同一真实合成视频覆盖共享播放器的原用法和可选播放控制，不连接外部媒体。 */
class MediaPreviewPlaybackTest {
    @get:Rule val compose = createComposeRule()
    private var file: File? = null
    @After fun cleanup() { file?.delete() }

    @Test fun 文件预览默认等待用户播放且保留系统播放控制() {
        val local = video(); val ready = AtomicBoolean(); val ended = AtomicBoolean(); val failed = AtomicBoolean()
        compose.setContent { LanStashTheme { MediaPreview(local, null, "Synthetic video", false,
            onReady = { ready.set(true) }, onFinished = { ended.set(true) }, onFailure = { failed.set(true) }) } }
        compose.waitUntil(10_000) { ready.get() || failed.get() }; assertFalse(failed.get())
        val start = SystemClock.elapsedRealtime()
        compose.waitUntil(8_000) { SystemClock.elapsedRealtime() - start >= 6_300 }
        assertFalse("Default preview must wait for a user play action", ended.get())
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
        compose.waitUntil(10_000) { ended.get() || failed.get() }; assertFalse(failed.get()); assertTrue(ended.get())
    }

    @Test fun 受控本地视频准备时保持暂停继续播放至完成() {
        val local = video(); val playing = mutableStateOf(false)
        val ready = AtomicBoolean(); val ended = AtomicBoolean(); val failed = AtomicBoolean()
        compose.setContent { LanStashTheme { MediaPreview(local, null, "Synthetic video", false, playing.value,
            onReady = { ready.set(true) }, onFinished = { ended.set(true) }, onFailure = { failed.set(true) }) } }
        compose.waitUntil(10_000) { ready.get() || failed.get() }; assertFalse(failed.get())
        compose.runOnIdle { playing.value = true }
        compose.waitUntil(10_000) { ended.get() || failed.get() }; assertFalse(failed.get()); assertTrue(ended.get())
    }

    private fun video(): File {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        return File.createTempFile("synthetic-player-", ".mp4", instrumentation.targetContext.cacheDir).also { target ->
            file = target
            instrumentation.context.assets.open("synthetic-slideshow.mp4").use { input -> target.outputStream().use(input::copyTo) }
        }
    }
}

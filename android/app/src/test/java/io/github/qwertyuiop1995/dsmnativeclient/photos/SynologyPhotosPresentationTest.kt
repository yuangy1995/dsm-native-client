package io.github.qwertyuiop1995.dsmnativeclient.photos

import java.io.File
import org.junit.Assert.*
import org.junit.Test

/** 构建之外保留正式入口、原生替代操作和会话取消的源码门禁；不代替真机验证。 */
class SynologyPhotosPresentationTest {
    @Test fun `手势缩放保留48dp视口以及等价的原生无障碍按钮`() {
        val source = read("ui/photos/SynologyPhotoPreview.kt")
        assertTrue(source.contains("sizeIn(minWidth = 48.dp, minHeight = 48.dp)"))
        assertTrue(source.contains("coerceIn(1f, 8f)"))
        assertTrue(source.contains("IconButton(onClick = { zoom = if (zoom > 1f) 1f else 2f }"))
        assertTrue(source.contains("Icons.Outlined.ZoomIn, stringResource(R.string.sp_media_zoom)"))
    }

    @Test fun `正式图库使用独立Photos会话而仓储变化先关闭旧模型`() {
        val session = read("photos/SynologyPhotosSession.kt")
        assertTrue(session.contains("repository !== value"))
        assertTrue(session.indexOf("model?.close()", session.indexOf("override fun setValue")) < session.indexOf("repository = value"))
        assertTrue(session.contains("profileId != current.synologyPhotos.profileId"))
        assertTrue(session.contains("invokeOnCompletion { model?.close() }"))
        val app = read("AppViewModel.kt")
        assertTrue(app.contains("private var repository: DsmRepository? by photosSession"))
        assertFalse(session.contains("PhotoRepository("))
    }

    private fun read(relative: String): String {
        var root: File? = File(System.getProperty("user.dir"))
        while (root != null) {
            val file = File(root, "android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/$relative")
            if (file.isFile) return file.readText()
            root = root.parentFile
        }
        error(relative)
    }
}

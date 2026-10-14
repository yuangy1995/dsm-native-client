package io.github.qwertyuiop1995.dsmnativeclient.domain

import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner

internal enum class FileThemeLogoPosition(val value: String) { TOP_RIGHT("rightup"), TOP_LEFT("leftup"), BOTTOM_RIGHT("rightbottom"), BOTTOM_LEFT("leftbottom") }
internal enum class FileThemeBackgroundPosition(val value: String) { CENTER("center"), FILL("fill"), FIT("fit"), STRETCH("stretch"), TILE("tile") }
internal enum class FileThemeImageKind(val value: String) { LOGO("logo"), BACKGROUND("background"); val requestType get() = "fbsharing_login_$value" }
internal enum class FileThemeImageSource(val value: String) { NAS("fromDS"), HISTORY("history"), DEFAULT("default") }
internal data class FileThemeImage(val kind: FileThemeImageKind, val source: FileThemeImageSource, val path: String, val name: String, val historyIndex: Int? = null) {
    override fun toString() = "FileThemeImage($kind, $source)"
    val validPath get() = supportsFilename(path) && path.none { it == '\u0000' || it == '\r' || it == '\n' } && path.split('/').none { it == "." || it == ".." }
    val requestPath get() = if (source == FileThemeImageSource.NAS) path else path.substringAfterLast('/')
    companion object {
        fun supportsFilename(value: String) = value.substringAfterLast('.', "").lowercase() in setOf("jpg", "jpeg", "jpe", "gif", "bmp", "png")
        val defaults get() = (1..10).map { FileThemeImage(FileThemeImageKind.BACKGROUND, FileThemeImageSource.DEFAULT, "dsm7_0$it.jpg", "dsm7_0$it.jpg") }
    }
}

/** 序列用于核查图片是否更换，不能推导当前图片路径；草稿图片只保留于当前页面。 */
internal data class FileSharingTheme(
    val owner: WorkspaceOwner, val customLogo: Boolean, val customBackground: Boolean,
    val logoPosition: FileThemeLogoPosition, val backgroundPosition: FileThemeBackgroundPosition,
    val backgroundColor: String, val footer: String, val footerUsesHtml: Boolean,
    val logoSequence: String?, val backgroundSequence: String?,
    val logoImage: FileThemeImage? = null, val backgroundImage: FileThemeImage? = null,
) { override fun toString() = "FileSharingTheme" }

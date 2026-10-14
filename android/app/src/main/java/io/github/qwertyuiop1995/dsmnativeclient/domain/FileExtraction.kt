package io.github.qwertyuiop1995.dsmnativeclient.domain

data class ArchiveItemPage(val items: List<ArchiveItem>, val offset: Int, val total: Int?, val hasMore: Boolean)

sealed interface FileArchiveSelection {
    data object All : FileArchiveSelection
    data class Items(val items: List<ArchiveItem>) : FileArchiveSelection
}

/** 密码只在本次读取和提交中持有，不进入恢复记录。 */
data class FileExtractionOptions(
    val selection: FileArchiveSelection = FileArchiveSelection.All,
    val keepDirectories: Boolean = true,
    val createSubfolder: Boolean = false,
    val overwrite: Boolean = false,
    val codepage: String? = null,
    val password: String? = null,
) {
    val isValid: Boolean get() = when (val selected = selection) {
        FileArchiveSelection.All -> true
        is FileArchiveSelection.Items -> selected.items.isNotEmpty() && selected.items.all { it.id >= 0 && isArchiveRelativePath(it.path) } &&
            selected.items.map(ArchiveItem::id).distinct().size == selected.items.size
    }
    override fun toString() = "FileExtractionOptions(redacted)"
}

data class FileExtractionRequest(val source: FileItem, val destination: FileItem, val options: FileExtractionOptions) {
    override fun toString() = "FileExtractionRequest(redacted)"
}

data class FileCompressionRequest(
    val sources: List<FileItem>, val destination: FileItem, val name: String,
    val format: ArchiveFormat, val level: ArchiveCompressionLevel, val password: String?,
) {
    val filename: String get() = if (name.endsWith(".${format.fileExtension}", ignoreCase = true)) name else "$name.${format.fileExtension}"
    val isValid: Boolean get() = sources.isNotEmpty() && sources.all(FileItem::canRead) &&
        destination.isDirectory && destination.canWrite && name.isNotBlank() && '/' !in name &&
        '\\' !in name && name != "." && name != ".." && name.none(Char::isISOControl)
    override fun toString() = "FileCompressionRequest(redacted)"
}

/** 包内路径保留原样；不能把绝对路径、父目录或不安全的分隔符修正后用于写入。 */
fun isArchiveRelativePath(path: String): Boolean = path.isNotEmpty() && !path.startsWith('/') &&
    '\\' !in path && ':' !in path && path.none(Char::isISOControl) &&
    path.split('/').all { it.isNotEmpty() && it != "." && it != ".." }

fun FileItem.isSupportedArchive(): Boolean = !isDirectory && name.substringAfterLast('.', "").lowercase() in
    setOf("zip", "gz", "tar", "tgz", "tbz", "bz2", "rar", "7z", "iso")

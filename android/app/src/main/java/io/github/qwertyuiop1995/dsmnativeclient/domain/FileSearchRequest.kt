package io.github.qwertyuiop1995.dsmnativeclient.domain

/** 与公开 Search v2 条件一一对应，不保存搜索词或账号路径。 */
enum class FileSearchKind(val apiValue: String) { ALL("all"), FILE("file"), DIRECTORY("dir") }
enum class FileSearchIndexCoverage { NOT_REQUESTED, COMPLETE, INCOMPLETE }

data class FileSearchTimeRange(val fromEpochSeconds: Long? = null, val toEpochSeconds: Long? = null) {
    val isValid: Boolean get() = listOfNotNull(fromEpochSeconds, toEpochSeconds).all { it >= 0 } &&
        (fromEpochSeconds == null || toEpochSeconds == null || fromEpochSeconds <= toEpochSeconds)
}

data class FileSearchRequest(
    val folders: List<String>,
    val name: String = "",
    val recursive: Boolean = true,
    val extension: String = "",
    val kind: FileSearchKind = FileSearchKind.ALL,
    val minimumBytes: Long? = null,
    val maximumBytes: Long? = null,
    val modified: FileSearchTimeRange = FileSearchTimeRange(),
    val created: FileSearchTimeRange = FileSearchTimeRange(),
    val accessed: FileSearchTimeRange = FileSearchTimeRange(),
    val owner: String = "",
    val group: String = "",
    val searchesContents: Boolean = false,
) {
    internal val nameSearch: FileNameSearch by lazy { FileNameSearch.parse(name) }
    internal val nameError: DsmErrorKind? get() = when {
        nameSearch.isRegularExpression && searchesContents -> DsmErrorKind.FILE_CONTENT_SEARCH_REGEX
        nameSearch.isRegularExpression && nameSearch.expression == null -> DsmErrorKind.FILE_SEARCH_INVALID_REGEX
        else -> null
    }
    val isValid: Boolean get() = nameError == null && folders.isNotEmpty() && folders.all { path ->
        path.startsWith('/') && path != "/" && path.split('/').none { it == "." || it == ".." }
    } && listOfNotNull(minimumBytes, maximumBytes).all { it >= 0 } &&
        (minimumBytes == null || maximumBytes == null || minimumBytes <= maximumBytes) &&
        modified.isValid && created.isValid && accessed.isValid && (!searchesContents || name.isNotBlank())
}

data class FileSearchResult(val page: FilePage, val indexCoverage: FileSearchIndexCoverage = FileSearchIndexCoverage.NOT_REQUESTED)

internal fun FileTypeFilter.searchKind(): FileSearchKind = when (this) {
    FileTypeFilter.ALL -> FileSearchKind.ALL
    FileTypeFilter.FILES -> FileSearchKind.FILE
    FileTypeFilter.FOLDERS -> FileSearchKind.DIRECTORY
}
internal fun FileSearchKind.typeFilter(): FileTypeFilter = when (this) {
    FileSearchKind.ALL -> FileTypeFilter.ALL
    FileSearchKind.FILE -> FileTypeFilter.FILES
    FileSearchKind.DIRECTORY -> FileTypeFilter.FOLDERS
}

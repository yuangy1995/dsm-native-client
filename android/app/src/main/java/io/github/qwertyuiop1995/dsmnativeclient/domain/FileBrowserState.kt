package io.github.qwertyuiop1995.dsmnativeclient.domain

enum class FileSortOption {
    NAME,
    MODIFIED_TIME,
    SIZE,
}

enum class FileTypeFilter {
    ALL,
    FOLDERS,
    FILES,
}

enum class FileViewMode {
    LIST,
    GRID,
}

data class FileBrowserState(
    val path: String = "",
    val pathHistory: List<String> = emptyList(),
    val searchQuery: String = "",
    val activeSearchQuery: String? = null,
    val searchRequest: FileSearchRequest? = null,
    val sortOption: FileSortOption = FileSortOption.NAME,
    val sortAscending: Boolean = true,
    val typeFilter: FileTypeFilter = FileTypeFilter.ALL,
    val viewMode: FileViewMode = FileViewMode.LIST,
    val selectedPaths: Set<String> = emptySet(),
) {
    fun enterDirectory(directoryPath: String): FileBrowserState = copy(
        path = directoryPath,
        pathHistory = pathHistory + path,
        searchQuery = "",
        activeSearchQuery = null,
        searchRequest = null,
        selectedPaths = emptySet(),
    )

    fun navigateUp(): FileBrowserState? {
        val previous = pathHistory.lastOrNull() ?: return null
        return copy(
            path = previous,
            pathHistory = pathHistory.dropLast(1),
            searchQuery = "",
            activeSearchQuery = null,
        searchRequest = null,
            selectedPaths = emptySet(),
        )
    }

    fun navigateTo(targetPath: String): FileBrowserState? {
        val lineage = pathHistory + path
        val targetIndex = lineage.indexOf(targetPath)
        if (targetIndex < 0 || targetPath == path) return null
        return copy(
            path = targetPath,
            pathHistory = lineage.take(targetIndex),
            searchQuery = "",
            activeSearchQuery = null,
        searchRequest = null,
            selectedPaths = emptySet(),
        )
    }

    fun editSearchQuery(query: String): FileBrowserState = copy(searchQuery = query)

    fun submitSearch(): FileBrowserState = copy(
        activeSearchQuery = if (searchRequest != null) searchQuery.trim() else searchQuery.trim().ifBlank { null },
        searchRequest = searchRequest?.copy(name = searchQuery.trim()),
        selectedPaths = emptySet(),
    )


    fun changeSort(option: FileSortOption): FileBrowserState = when (option) {
        sortOption -> copy(sortAscending = !sortAscending)
        else -> copy(sortOption = option, sortAscending = true)
    }

    fun changeFilter(filter: FileTypeFilter): FileBrowserState = copy(
        typeFilter = filter,
        searchRequest = searchRequest?.copy(kind = filter.searchKind()),
        selectedPaths = emptySet(),
    )

    fun changeViewMode(mode: FileViewMode): FileBrowserState = copy(viewMode = mode)

    fun toggleSelection(path: String): FileBrowserState = copy(
        selectedPaths = if (path in selectedPaths) selectedPaths - path else selectedPaths + path,
    )

    fun clearSelection(): FileBrowserState = copy(selectedPaths = emptySet())

    fun openShortcut(targetPath: String): FileBrowserState = copy(
        path = targetPath,
        pathHistory = listOf(""),
        searchQuery = "",
        activeSearchQuery = null,
        searchRequest = null,
        selectedPaths = emptySet(),
    )

    fun visibleItems(items: List<FileItem>): List<FileItem> {
        val filtered = items.filter { item ->
            when (typeFilter) {
                FileTypeFilter.ALL -> true
                FileTypeFilter.FOLDERS -> item.isDirectory
                FileTypeFilter.FILES -> !item.isDirectory
            }
        }
        val comparator = Comparator<FileItem> { left, right ->
            when (sortOption) {
                FileSortOption.NAME -> left.name.compareTo(right.name, ignoreCase = true)
                FileSortOption.MODIFIED_TIME -> compareValues(
                    left.modifiedAtEpochSeconds ?: Long.MIN_VALUE,
                    right.modifiedAtEpochSeconds ?: Long.MIN_VALUE,
                )
                FileSortOption.SIZE -> left.size.compareTo(right.size)
            }
        }
        return filtered.sortedWith(if (sortAscending) comparator else comparator.reversed())
    }

    companion object {
        /**
         * 从已签发的规范目录路径重建正常目录层级。
         *
         * 外链不恢复搜索、筛选、选择或视图偏好，只恢复用户需要查看的目录和逐级返回路径。
         */
        fun fromCanonicalDirectoryPath(canonicalPath: String): FileBrowserState? =
            canonicalFileDirectoryLineage(canonicalPath)?.let { lineage ->
                FileBrowserState(
                    path = lineage.last(),
                    pathHistory = lineage.dropLast(1),
                )
            }

        /**
         * 从已签发的规范文件路径重建其父目录层级，供单项预览的返回栈使用。
         */
        fun fromCanonicalFilePath(canonicalPath: String): FileBrowserState? {
            val segments = canonicalFilePathSegments(canonicalPath) ?: return null
            if (segments.size < 2) return null
            return fromCanonicalDirectoryPath("/${segments.dropLast(1).joinToString("/")}")
        }
    }
}

private fun canonicalFileDirectoryLineage(path: String): List<String>? {
    val segments = canonicalFilePathSegments(path) ?: return null
    return buildList {
        add("")
        segments.indices.forEach { index ->
            add("/${segments.take(index + 1).joinToString("/")}")
        }
    }
}

private fun canonicalFilePathSegments(path: String): List<String>? {
    if (!path.startsWith('/') || path == "/" || path.endsWith('/')) return null
    val segments = path.drop(1).split('/')
    if (segments.any { it.isEmpty() || it == "." || it == ".." || it == "#recycle" }) return null
    return segments
}

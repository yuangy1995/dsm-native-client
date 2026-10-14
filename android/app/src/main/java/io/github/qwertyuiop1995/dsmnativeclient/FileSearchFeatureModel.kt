package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.math.BigDecimal
import java.math.RoundingMode

internal enum class FileSearchSizeUnit(val bytes: Long) { BYTES(1), MIB(1_048_576), GIB(1_073_741_824) }

internal data class FileSearchDraft(
    val request: FileSearchRequest = FileSearchRequest(emptyList()),
    val minimumSize: String = request.minimumBytes?.toString().orEmpty(),
    val maximumSize: String = request.maximumBytes?.toString().orEmpty(),
    val sizeUnit: FileSearchSizeUnit = FileSearchSizeUnit.BYTES,
) {
    fun resolved(): FileSearchRequest? {
        fun bytes(text: String): Long? {
            val value = text.trim()
            if (!value.matches(Regex("[0-9]+(?:\\.[0-9]+)?"))) return null
            return runCatching { BigDecimal(value).multiply(BigDecimal(sizeUnit.bytes))
                .setScale(0, RoundingMode.DOWN).longValueExact() }.getOrNull()
        }
        val minimum = if (minimumSize.isBlank()) null else bytes(minimumSize) ?: return null
        val maximum = if (maximumSize.isBlank()) null else bytes(maximumSize) ?: return null
        return request.copy(minimumBytes = minimum, maximumBytes = maximum).takeIf { it.isValid }
    }
}

internal data class FileSearchEditorState(
    val visible: Boolean = false,
    val draft: FileSearchDraft = FileSearchDraft(),
    val locationsVisible: Boolean = false,
    val locationPath: String = "",
    val locations: Loadable<List<FileItem>> = Loadable.Idle,
    val locationFilter: String = "",
    val failure: DsmFailure? = null,
)

/** 每个工作区独立拥有条件草稿、目录选择和可取消的搜索；不承载 NAS 写操作。 */
internal class FileSearchFeatureModel(
    private val scope: CoroutineScope,
    private val repository: () -> DsmRepository?,
    private val workspace: () -> WorkspaceState?,
    private val onQueryChange: (FileBrowserState) -> Unit,
    private val onBrowse: (FileBrowserState) -> Unit,
) {
    private val _editor = MutableStateFlow(FileSearchEditorState())
    val editor = _editor.asStateFlow()
    private var editorRepository: DsmRepository? = null
    private var locationJob: Job? = null
    private var searchJob: Deferred<FileSearchResult>? = null

    fun open() {
        val current = workspace() ?: return
        val repo = repository() ?: return
        if (current.selectedModule != Module.FILES || current.isPerformingAction ||
            fileStationMutationBlocksOrdinaryLoad(current.fileStationMutationState)) return
        val request = current.fileBrowser.searchRequest ?: FileSearchRequest(
            folders = current.fileBrowser.path.takeIf { it.isNotBlank() }?.let(::listOf).orEmpty(),
            name = current.fileBrowser.searchQuery, kind = current.fileBrowser.typeFilter.searchKind(),
        )
        editorRepository = repo
        _editor.value = FileSearchEditorState(visible = true, draft = FileSearchDraft(request))
    }

    fun edit(transform: (FileSearchDraft) -> FileSearchDraft) { _editor.update { it.copy(draft = transform(it.draft), failure = null) } }
    fun close() { locationJob?.cancel(); editorRepository = null; _editor.value = FileSearchEditorState() }
    fun reset() {
        val path = workspace()?.fileBrowser?.path?.takeIf { it.isNotBlank() }
        edit { FileSearchDraft(FileSearchRequest(path?.let(::listOf).orEmpty(), name = workspace()?.fileBrowser?.searchQuery.orEmpty())) }
    }
    fun apply() {
        if (!editorIsCurrent()) return
        val request = _editor.value.draft.resolved() ?: return
        val browser = workspace()?.fileBrowser ?: return
        close(); onBrowse(browser.copy(searchQuery = request.name, activeSearchQuery = request.name, searchRequest = request, typeFilter = request.kind.typeFilter(), selectedPaths = emptySet()))
    }
    fun updateQuery(query: String) { workspace()?.fileBrowser?.let { onQueryChange(it.editSearchQuery(query)) } }
    fun submitQuery() { workspace()?.fileBrowser?.let { onBrowse(it.submitSearch()) } }
    fun clearSearch() { workspace()?.fileBrowser?.let { onBrowse(it.copy(searchQuery = "", activeSearchQuery = null, searchRequest = null, selectedPaths = emptySet())) } }

    fun openLocations() {
        if (!editorIsCurrent()) return
        _editor.update { it.copy(locationsVisible = true) }
        loadLocations("")
    }
    fun closeLocations() { locationJob?.cancel(); _editor.update { it.copy(locationsVisible = false, locations = Loadable.Idle) } }
    fun filterLocations(value: String) { _editor.update { it.copy(locationFilter = value) } }
    fun retryLocations() = loadLocations(_editor.value.locationPath)
    fun locationUp() = loadLocations(_editor.value.locationPath.substringBeforeLast('/', ""))
    fun enterLocation(item: FileItem) {
        if (item.isDirectory && item.canRead && (editor.value.locations as? Loadable.Ready)?.value?.contains(item) == true) loadLocations(item.path)
    }
    fun addLocation() {
        if (!editorIsCurrent()) return
        val state = editor.value
        if (state.locationPath.isBlank() || state.locations !is Loadable.Ready) return
        edit { it.copy(request = it.request.copy(folders = (it.request.folders + state.locationPath).distinct())) }
        closeLocations()
    }
    fun removeLocation(path: String) = edit { it.copy(request = it.request.copy(folders = it.request.folders - path)) }

    private fun loadLocations(path: String) {
        if (!editorIsCurrent()) return
        val repo = editorRepository ?: return
        locationJob?.cancel()
        _editor.update { it.copy(locationPath = path, locations = Loadable.Loading, locationFilter = "") }
        locationJob = scope.launch {
            val result = captureLoadable { folders(repo, path) }
            if (repository() === repo && editorRepository === repo && _editor.value.locationsVisible && _editor.value.locationPath == path) {
                _editor.update { it.copy(locations = result) }
            }
        }
    }

    private fun editorIsCurrent(): Boolean {
        val repo = editorRepository ?: return false
        if (repository() !== repo || workspace()?.selectedModule != Module.FILES) { close(); return false }
        return runCatching { repo.requireCurrentOwner() }.onFailure { failure ->
            _editor.update { it.copy(failure = failure.asDsmFailure()) }
        }.isSuccess
    }

    suspend fun search(repo: DsmRepository, browser: FileBrowserState): FileSearchResult = coroutineScope {
        cancelSearch()
        val task = async {
            var request = browser.searchRequest ?: FileSearchRequest(
                folders = if (browser.path.isNotBlank()) listOf(browser.path) else emptyList(),
                name = browser.activeSearchQuery.orEmpty(), kind = browser.typeFilter.searchKind(),
            )
            request.nameError?.let { throw DsmFailure(null, "Invalid filename expression", "Adjust the search.", kind = it) }
            if (request.folders.isEmpty() && browser.searchRequest == null) request = request.copy(folders = folders(repo, "").map(FileItem::path))
            if (request.folders.isEmpty() && browser.searchRequest == null) FileSearchResult(FilePage(emptyList(), 0, 0))
            else repo.searchWithReport(request)
        }
        searchJob = task
        try { task.await() } finally { if (searchJob === task) searchJob = null }
    }
    fun cancelSearch() { searchJob?.cancel(); searchJob = null }
    fun invalidate() { cancelSearch(); close() }

    private suspend fun folders(repo: DsmRepository, path: String): List<FileItem> {
        val result = linkedMapOf<String, FileItem>()
        var offset = 0
        do {
            currentCoroutineContext().ensureActive()
            val page = if (path.isBlank()) repo.listShares(offset, 200) else repo.listDirectory(path, offset, 200, fileType = "dir")
            if (page.offset != offset || page.items.isEmpty() && offset < page.total || page.items.any { it.path in result })
                throw DsmFailure(null, "Folder list is incomplete", "Try again.", kind = DsmErrorKind.FILE_SEARCH_INCOMPLETE)
            page.items.filter(FileItem::isDirectory).forEach { result[it.path] = it }
            offset += page.items.size
        } while (offset < page.total)
        return result.values.toList()
    }
}

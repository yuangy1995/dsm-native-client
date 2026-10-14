package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.archiveListFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal enum class FileArchiveEditor { EXTRACT, COMPRESS }
internal data class FileArchiveState(
    val editor: FileArchiveEditor? = null,
    val sources: List<FileItem> = emptyList(),
    val destination: FileItem? = null,
    val options: FileExtractionOptions = FileExtractionOptions(createSubfolder = true),
    val extractAll: Boolean = true,
    val selected: Map<Int, ArchiveItem> = emptyMap(),
    val parents: List<ArchiveItem> = emptyList(),
    val page: Loadable<ArchiveItemPage> = Loadable.Idle,
    val loadingMore: Boolean = false,
    val moreFailure: DsmFailure? = null,
    val filter: String = "",
    val browserVisible: Boolean = false,
    val confirmation: Boolean = false,
    val failure: DsmFailure? = null,
    val locationsVisible: Boolean = false,
    val locationPath: String = "",
    val location: FileItem? = null,
    val locations: Loadable<List<FileItem>> = Loadable.Idle,
    val locationFilter: String = "",
    val archiveName: String = "",
    val format: ArchiveFormat = ArchiveFormat.ZIP,
    val level: ArchiveCompressionLevel = ArchiveCompressionLevel.MODERATE,
) {
    val source get() = sources.singleOrNull()
    override fun toString() = "FileArchiveState(redacted)"
}

/** 每个工作区独立拥有归档草稿；读取可取消，提交交给现有任务中心。 */
internal class FileArchiveFeatureModel(
    private val scope: CoroutineScope,
    private val repository: () -> DsmRepository?,
    private val workspace: () -> WorkspaceState?,
    private val defaultArchiveName: () -> String,
    private val extract: (FileExtractionRequest) -> Boolean,
    private val compress: (FileCompressionRequest) -> Boolean,
) {
    private val _state = MutableStateFlow(FileArchiveState())
    val state = _state.asStateFlow()
    private var activeRepository: DsmRepository? = null
    private var reading: Job? = null
    private var locationsJob: Job? = null
    private var generation = 0L
    private var resolvedCodepage: String? = null

    fun open(item: FileItem): Boolean = open(listOf(item), FileArchiveEditor.EXTRACT)
    fun openCompression(items: List<FileItem>): Boolean = open(items, FileArchiveEditor.COMPRESS)
    private fun open(items: List<FileItem>, editor: FileArchiveEditor): Boolean {
        val current = workspace() ?: return false
        val repo = repository() ?: return false
        if (current.selectedModule != Module.FILES || current.isPerformingAction || fileStationMutationBlocksOrdinaryLoad(current.fileStationMutationState) ||
            items.isEmpty() || items.any { !it.canRead } || editor == FileArchiveEditor.EXTRACT && (items.size != 1 || !items.single().isSupportedArchive()) ||
            runCatching(repo::requireCurrentOwner).isFailure) return false
        close()
        activeRepository = repo
        _state.value = FileArchiveState(editor = editor, sources = items.distinctBy(FileItem::path),
            destination = current.fileDirectoryBaselines[current.fileBrowser.path],
            archiveName = items.singleOrNull()?.name?.substringBeforeLast('.') ?: defaultArchiveName())
        if (editor == FileArchiveEditor.EXTRACT) reload()
        return true
    }

    fun close() { generation++; reading?.cancel(); locationsJob?.cancel(); activeRepository = null; resolvedCodepage = null; _state.value = FileArchiveState() }
    fun invalidate() = close()
    fun editOptions(transform: (FileExtractionOptions) -> FileExtractionOptions) {
        val previous = _state.value.options
        val next = transform(previous)
        _state.update { it.copy(options = next, confirmation = false, failure = null) }
        if (next.password != previous.password || next.codepage != previous.codepage) {
            generation++; reading?.cancel(); resolvedCodepage = null
            _state.update { it.copy(page = Loadable.Idle, parents = emptyList(), selected = emptyMap(), loadingMore = false, moreFailure = null, filter = "") }
        }
    }
    fun editCompression(name: String? = null, format: ArchiveFormat? = null, level: ArchiveCompressionLevel? = null) {
        _state.update { it.copy(archiveName = name ?: it.archiveName, format = format ?: it.format, level = level ?: it.level, failure = null) }
    }
    fun setExtractAll(value: Boolean) { _state.update { it.copy(extractAll = value, selected = if (value) emptyMap() else it.selected, confirmation = false) } }
    fun filter(value: String) { _state.update { it.copy(filter = value) } }
    fun openBrowser() { _state.update { it.copy(browserVisible = true) } }
    fun closeBrowser() { _state.update { it.copy(browserVisible = false) } }
    fun toggle(item: ArchiveItem) {
        if (item !in (_state.value.page as? Loadable.Ready)?.value?.items.orEmpty()) return
        _state.update { it.copy(extractAll = false, confirmation = false,
            selected = if (item.id in it.selected) it.selected - item.id else it.selected + (item.id to item)) }
    }
    fun reload() {
        resolvedCodepage = _state.value.options.codepage
        _state.update { it.copy(parents = emptyList(), selected = emptyMap(), filter = "") }
        load(reset = true, resolveEncoding = true)
    }
    fun enter(item: ArchiveItem) {
        val current = _state.value
        if (current.page is Loadable.Loading || current.loadingMore || !item.isDirectory || item !in (current.page as? Loadable.Ready)?.value?.items.orEmpty()) return
        _state.update { it.copy(parents = it.parents + item, filter = "") }; load(reset = true)
    }
    fun up() {
        if (_state.value.parents.isEmpty() || _state.value.page is Loadable.Loading || _state.value.loadingMore) return
        _state.update { it.copy(parents = it.parents.dropLast(1), filter = "") }; load(reset = true)
    }
    fun retry() = load(reset = true)
    fun more() { if ((_state.value.page as? Loadable.Ready)?.value?.hasMore == true && !_state.value.loadingMore) load(reset = false) }

    private fun load(reset: Boolean, resolveEncoding: Boolean = false) {
        val repo = currentRepository() ?: return
        val current = _state.value
        val source = current.source ?: return
        val previous = (current.page as? Loadable.Ready)?.value
        reading?.cancel()
        val epoch = ++generation
        val offset = if (reset) 0 else previous?.items?.size ?: return
        _state.update { it.copy(page = if (reset) Loadable.Loading else it.page, loadingMore = !reset, moreFailure = null, failure = null) }
        reading = scope.launch {
            val result = captureLoadable {
                var page = repo.listArchivePage(source.path, current.parents.lastOrNull()?.id ?: -1, offset,
                    codepage = resolvedCodepage, password = current.options.password)
                if (resolveEncoding && current.options.codepage == null && archiveNamePenalty(page.items) > 0) {
                    val chinese = try { repo.listArchivePage(source.path, codepage = "chs", password = current.options.password) }
                    catch (failure: DsmFailure) {
                        if (failure.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.AUTHENTICATION_FAILED)) throw failure
                        null
                    }
                    if (chinese != null && archiveNamePenalty(chinese.items) < archiveNamePenalty(page.items)) {
                        page = chinese
                        if (epoch == generation) resolvedCodepage = "chs"
                    }
                }
                if (!reset && previous != null) {
                    if (previous.total != null && previous.total != page.total || page.items.any { item -> previous.items.any { it.id == item.id || it.path == item.path } }) throw archiveListFailure()
                    page = page.copy(items = previous.items + page.items, offset = 0)
                }
                page
            }
            if (repository() !== repo || activeRepository !== repo || epoch != generation) return@launch
            _state.update { if (!reset && result is Loadable.Failed) it.copy(loadingMore = false, moreFailure = result.error)
                else it.copy(page = result, loadingMore = false) }
        }
    }

    fun canSubmit(): Boolean {
        val current = _state.value
        val destination = current.destination ?: return false
        if (!destination.isDirectory || !destination.canWrite) return false
        if (current.editor == FileArchiveEditor.COMPRESS) return compressionRequest(current)?.isValid == true
        val page = (current.page as? Loadable.Ready)?.value ?: return false
        return !current.loadingMore && current.moreFailure == null && (current.extractAll && (page.items.isNotEmpty() || current.parents.isNotEmpty()) || !current.extractAll && current.selected.isNotEmpty())
    }
    fun dismissConfirmation() { _state.update { it.copy(confirmation = false) } }
    fun submit(acceptOverwrite: Boolean = false) {
        currentRepository() ?: return
        if (!canSubmit()) return
        val current = _state.value
        if (current.editor == FileArchiveEditor.EXTRACT && current.options.overwrite && !acceptOverwrite) { _state.update { it.copy(confirmation = true) }; return }
        val accepted = if (current.editor == FileArchiveEditor.COMPRESS) compress(compressionRequest(current) ?: return) else extract(
            FileExtractionRequest(current.source ?: return, current.destination ?: return,
                current.options.copy(codepage = resolvedCodepage,
                    selection = if (current.extractAll) FileArchiveSelection.All else FileArchiveSelection.Items(current.selected.values.sortedBy(ArchiveItem::id)))))
        if (accepted) close() else _state.update { it.copy(failure = DsmFailure(null, "", "", kind = DsmErrorKind.WORKSPACE_BUSY), confirmation = false) }
    }
    private fun compressionRequest(current: FileArchiveState) = current.destination?.let {
        FileCompressionRequest(current.sources, it, current.archiveName, current.format, current.level, current.options.password)
    }

    fun openLocations() { _state.update { it.copy(locationsVisible = true) }; loadLocations("") }
    fun closeLocations() { locationsJob?.cancel(); _state.update { it.copy(locationsVisible = false) } }
    fun filterLocations(value: String) { _state.update { it.copy(locationFilter = value) } }
    fun retryLocations() = loadLocations(_state.value.locationPath)
    fun locationUp() = loadLocations(_state.value.locationPath.substringBeforeLast('/', ""))
    fun enterLocation(item: FileItem) { if (item.isDirectory && item.canRead && item in (_state.value.locations as? Loadable.Ready)?.value.orEmpty()) loadLocations(item.path) }
    fun chooseLocation() {
        currentRepository() ?: return
        val current = _state.value
        val location = current.location?.takeIf { it.isDirectory && it.canWrite } ?: return
        if (current.locations !is Loadable.Ready) return
        _state.update { it.copy(destination = location, locationsVisible = false, failure = null) }; locationsJob?.cancel()
    }
    private fun loadLocations(path: String) {
        val repo = currentRepository() ?: return
        locationsJob?.cancel()
        _state.update { it.copy(locationPath = path, location = null, locations = Loadable.Loading, locationFilter = "") }
        locationsJob = scope.launch {
            var folder: FileItem? = null
            val result = captureLoadable {
                if (path.isNotEmpty()) folder = repo.fileInfo(path)
                val items = mutableListOf<FileItem>()
                do {
                    val page = if (path.isEmpty()) repo.listShares(items.size, 200) else repo.listDirectory(path, items.size, 200, fileType = "dir")
                    if (page.offset != items.size || page.items.isEmpty() && items.size < page.total || page.items.any { item -> items.any { it.path == item.path } }) throw archiveListFailure()
                    items += page.items
                } while (items.size < page.total)
                items.filter(FileItem::isDirectory)
            }
            if (repository() === repo && activeRepository === repo && _state.value.locationsVisible && _state.value.locationPath == path) {
                _state.update { it.copy(location = folder, locations = result) }
            }
        }
    }
    private fun currentRepository(): DsmRepository? {
        val repo = activeRepository ?: return null
        if (repository() !== repo || workspace()?.selectedModule != Module.FILES) { close(); return null }
        return runCatching { repo.requireCurrentOwner(); repo }.onFailure { error -> _state.update { it.copy(failure = error.asDsmFailure()) } }.getOrNull()
    }
}

internal fun archiveNamePenalty(items: List<ArchiveItem>): Int = items.sumOf { item ->
    item.name.sumOf { if (it == '\uFFFD' || it.code in 0x00C0..0x024F) 3 else 0 } +
        listOf("Ã", "Â", "Ð", "æ", "å", "ç", "ï¿½", "¤", "¦", "¨").count { it in item.name } * 5
}

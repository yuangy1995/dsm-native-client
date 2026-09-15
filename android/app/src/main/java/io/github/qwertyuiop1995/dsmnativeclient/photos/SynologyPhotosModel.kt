package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.Closeable
import java.time.YearMonth
import java.time.ZoneId
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** 与会话同寿命的 Photos 导航模型；UI 只负责触控/键盘，绝不启动旧文件扫描。 */
internal class SynologyPhotosModel(
    private val repository: SynologyPhotosServing,
    parent: CoroutineScope,
    private val pageSize: Int = 100,
    private val zone: ZoneId = ZoneId.systemDefault(),
) : Closeable {
    init { require(pageSize in 1..500) }
    private val job = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + job)
    private val mutable = MutableStateFlow(SynologyPhotosState())
    val state = mutable.asStateFlow()
    val profileId: String get() = repository.profileId
    val thumbnails = SynologyPhotoThumbnailStore(scope)
    val preview = SynologyPhotoPreviewModel(repository, scope) { state.value.items }
    val deletion = SynologyPhotoDeletionModel(repository, scope) { photo ->
        confirmedDeletedIds.add(photo.id)
        replaceItems(state.value.items.filterNot { it.id == photo.id })
        if (preview.state.value.photo?.id == photo.id) preview.closePreview()
        if (active) refresh()
    }
    private val confirmedDeletedIds = mutableSetOf<SynologyPhotoId>()
    private var active = false
    private var generation = 0L
    private var navigationJob: Job? = null
    private var pagingJob: Job? = null
    private var previousJob: Job? = null
    private var optionsJob: Job? = null
    private var optionsGeneration = 0L
    private var query: SynologyPhotoQuery? = null
    private var baseQuery: SynologyPhotoQuery? = null
    private var previousMonth: YearMonth? = null
    private var nextOffset = 0
    private var collectionOffset = 0

    fun activate() {
        active = true
        if (!state.value.loaded && !state.value.loading) refresh()
    }

    fun refresh(): Job? {
        if (!active || deletion.state.value.writing) return null
        val token = resetRequests()
        val navigation = state.value.navigation
        query = null; baseQuery = null; previousMonth = null
        nextOffset = 0; collectionOffset = 0
        mutable.value = state.value.copy(items = emptyList(), groups = emptyList(), collections = emptyList(), sharing = emptyList(),
            months = emptyList(), selectedMonth = null, hasPrevious = false, hasMore = false, hasMoreCollections = false,
            loaded = false, loading = true, error = null, categoriesError = null, previousError = null)
        navigationJob = scope.launch {
            try {
                val access = repository.access()
                checkCurrent(token)
                if (SynologyPhotoSpace.PERSONAL !in access.spaces) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
                when {
                    navigation.section == SynologyPhotosSection.SHARING && navigation.album == null -> loadCollections(token)
                    navigation.showsCollectionRoot -> {
                        try {
                            val categories = repository.categories()
                            checkCurrent(token)
                            mutable.update { it.copy(categories = categories) }
                        } catch (error: Exception) {
                            checkCurrent(token)
                            if (error is CancellationException) throw error
                            mutable.update { it.copy(categoriesError = error) }
                        }
                        loadCollections(token)
                    }
                    navigation.category != null && navigation.category !in setOf(SynologyPhotoCategory.RECENT, SynologyPhotoCategory.VIDEOS) && navigation.categoryItem == null -> loadCollections(token)
                    else -> loadQuery(navigation, token)
                }
                checkCurrent(token)
                mutable.update { it.copy(loaded = true) }
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loading = false) } }
        }
        return navigationJob
    }

    private suspend fun loadQuery(navigation: SynologyPhotoNavigation, token: Long) {
        val initial: SynologyPhotoQuery
        when {
            navigation.category == SynologyPhotoCategory.RECENT -> initial = SynologyPhotoQuery.Recent
            navigation.filter.isActive -> initial = SynologyPhotoQuery.Filtered(navigation.filter, 0, Long.MAX_VALUE)
            navigation.keyword.isNotEmpty() -> initial = SynologyPhotoQuery.Search(navigation.keyword, 0, Long.MAX_VALUE)
            navigation.category != null && navigation.categoryItem != null -> initial = SynologyPhotoQuery.Category(navigation.category, navigation.categoryItem.id, 0, Long.MAX_VALUE)
            navigation.section == SynologyPhotosSection.FOLDERS -> {
                if (navigation.folders.isEmpty()) {
                    val root = repository.rootFolder(SynologyPhotoSpace.PERSONAL)
                    checkCurrent(token)
                    mutable.update { it.copy(navigation = it.navigation.copy(folders = listOf(root))) }
                }
                loadCollections(token)
                checkCurrent(token)
                initial = SynologyPhotoQuery.Folder(state.value.navigation.folders.last().id)
            }
            navigation.album != null -> initial = SynologyPhotoQuery.Album(navigation.album.id)
            else -> initial = SynologyPhotoQuery.Timeline(0, Long.MAX_VALUE)
        }
        val resolved = when (initial) {
            is SynologyPhotoQuery.Folder, is SynologyPhotoQuery.Album, SynologyPhotoQuery.Recent -> initial
            else -> {
                val days = repository.timeline(SynologyPhotoSpace.PERSONAL, initial)
                checkCurrent(token)
                val months = days.filter { it.count > 0 }.map { it.month }.distinct().sortedDescending()
                mutable.update { it.copy(months = months) }
                val bounds = SynologyPhotoWindows.bounds(days) ?: return
                val bounded = SynologyPhotoWindows.constrain(initial, bounds.first, bounds.last) ?: return
                baseQuery = bounded
                bounded
            }
        }
        query = resolved
        val page = repository.photos(SynologyPhotoSpace.PERSONAL, resolved, 0, pageSize)
        checkCurrent(token)
        accept(page, 0)
    }

    fun selectSection(section: SynologyPhotosSection) {
        if (deletion.state.value.writing) return
        mutable.update { it.copy(navigation = SynologyPhotoNavigation(section = section)) }
        preview.closePreview(); deletion.cancelCandidate(); refresh()
    }

    fun search(keyword: String) {
        if (deletion.state.value.writing) return
        mutable.update { it.copy(navigation = SynologyPhotoNavigation(keyword = keyword.trim())) }
        refresh()
    }

    fun applyFilter(filter: SynologyPhotoFilter) {
        if (deletion.state.value.writing) return
        mutable.update { it.copy(navigation = SynologyPhotoNavigation(filter = filter)) }
        refresh()
    }

    fun openCategory(category: SynologyPhotoCategory) {
        if (category !in state.value.categories || deletion.state.value.writing) return
        mutable.update { it.copy(navigation = SynologyPhotoNavigation(section = SynologyPhotosSection.ALBUMS,
            category = category, filter = if (category == SynologyPhotoCategory.VIDEOS) SynologyPhotoFilter(mediaType = 1) else SynologyPhotoFilter())) }
        refresh()
    }

    fun openCollection(collection: SynologyPhotoCollection) {
        if (deletion.state.value.writing || state.value.collections.none { it.id == collection.id }) return
        val old = state.value.navigation
        val next = when {
            old.section == SynologyPhotosSection.FOLDERS -> old.copy(folders = old.folders + collection)
            old.category != null -> old.copy(categoryItem = collection, filter = when (old.category) {
                SynologyPhotoCategory.PEOPLE -> SynologyPhotoFilter(personId = collection.id)
                SynologyPhotoCategory.LOCATIONS -> SynologyPhotoFilter(locationId = collection.id)
                else -> SynologyPhotoFilter()
            })
            else -> old.copy(album = collection)
        }
        mutable.update { it.copy(navigation = next) }
        refresh()
    }

    fun goBack(): Boolean {
        if (deletion.state.value.writing) return false
        val old = state.value.navigation
        val next = when {
            old.folders.size > 1 -> old.copy(folders = old.folders.dropLast(1))
            old.album != null -> old.copy(album = null)
            old.categoryItem != null -> old.copy(categoryItem = null, filter = SynologyPhotoFilter())
            old.category != null -> old.copy(category = null, filter = SynologyPhotoFilter())
            else -> return false
        }
        mutable.update { it.copy(navigation = next) }
        refresh()
        return true
    }

    fun selectShareScope(scope: SynologyPhotoShareScope) {
        if (deletion.state.value.writing) return
        mutable.update { it.copy(navigation = SynologyPhotoNavigation(section = SynologyPhotosSection.SHARING, shareScope = scope)) }
        refresh()
    }

    fun openSharedAlbum(entry: SynologyPhotoSharedEntry) {
        val id = entry.albumId ?: return
        if (deletion.state.value.writing || state.value.sharing.none { it == entry }) return
        mutable.update { it.copy(navigation = it.navigation.copy(album = SynologyPhotoCollection(id, entry.title))) }
        refresh()
    }

    fun loadMore(automatic: Boolean = false): Job? {
        val state = state.value
        if (!active || deletion.state.value.writing || state.loading || state.loadingMore ||
            (!state.hasMore && !state.hasMoreCollections) || (automatic && state.error != null)) return null
        val token = generation
        mutable.update { it.copy(loadingMore = true, error = null) }
        pagingJob = scope.launch {
            try {
                if (state.hasMoreCollections) loadCollections(token) else {
                    val requested = nextOffset
                    val page = repository.photos(SynologyPhotoSpace.PERSONAL, query ?: return@launch, requested, pageSize)
                    checkCurrent(token)
                    accept(page, requested)
                }
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loadingMore = false) } }
        }
        return pagingJob
    }

    private suspend fun loadCollections(token: Long) {
        val navigation = state.value.navigation
        val offset = collectionOffset
        val sharing = navigation.section == SynologyPhotosSection.SHARING && navigation.album == null
        if (sharing) {
            val page = repository.sharedEntries(navigation.shareScope, offset, pageSize)
            checkCurrent(token)
            if (page.size > pageSize || page.map { it.id }.distinct().size != page.size) invalid()
            val previous = state.value.sharing.mapTo(mutableSetOf()) { it.id }
            val added = page.filter { previous.add(it.id) }
            if (page.size == pageSize && added.isEmpty()) invalid()
            collectionOffset += page.size
            mutable.update { it.copy(sharing = it.sharing + added, hasMoreCollections = page.size == pageSize, paginationKey = it.paginationKey + 1) }
        } else {
            val page = when {
                navigation.section == SynologyPhotosSection.FOLDERS -> repository.folders(SynologyPhotoSpace.PERSONAL, navigation.folders.last().id, offset, pageSize)
                navigation.category != null -> repository.categoryItems(navigation.category, offset, pageSize)
                else -> repository.albums(offset, pageSize)
            }
            checkCurrent(token)
            if (page.size > pageSize || page.map { it.id }.distinct().size != page.size) invalid()
            val previous = state.value.collections.mapTo(mutableSetOf()) { it.id }
            val added = page.filter { previous.add(it.id) }
            if (page.size == pageSize && added.isEmpty()) invalid()
            collectionOffset += page.size
            mutable.update { it.copy(collections = it.collections + added, hasMoreCollections = page.size == pageSize, paginationKey = it.paginationKey + 1) }
        }
    }

    fun jumpToMonth(month: YearMonth): Job? {
        if (!active || deletion.state.value.writing || month !in state.value.months) return null
        val end = month.plusMonths(1).atDay(1).atStartOfDay(zone).toEpochSecond() - 1
        val nextQuery = SynologyPhotoWindows.constrain(baseQuery ?: return null, end = end) ?: return null
        val token = resetRequests()
        query = nextQuery; previousMonth = month; nextOffset = 0
        replaceItems(emptyList())
        mutable.update { it.copy(selectedMonth = month, loading = true, error = null, previousError = null,
            hasMore = false, hasPrevious = it.months.any { candidate -> candidate > month }) }
        navigationJob = scope.launch {
            try {
                val page = repository.photos(SynologyPhotoSpace.PERSONAL, nextQuery, 0, pageSize)
                checkCurrent(token); accept(page, 0)
            } catch (error: Exception) { present(error, token) }
            finally { if (current(token)) mutable.update { it.copy(loading = false) } }
        }
        return navigationJob
    }

    fun loadPrevious(): Job? {
        if (!active || deletion.state.value.writing || state.value.loading || state.value.loadingPrevious) return null
        val prior = previousMonth ?: return null
        val next = state.value.months.lastOrNull { it > prior } ?: return null
        val base = baseQuery ?: return null
        val request = SynologyPhotoWindows.constrain(base,
            start = prior.plusMonths(1).atDay(1).atStartOfDay(zone).toEpochSecond(),
            end = next.plusMonths(1).atDay(1).atStartOfDay(zone).toEpochSecond() - 1) ?: return null
        val token = generation
        mutable.update { it.copy(loadingPrevious = true, previousError = null) }
        previousJob = scope.launch {
            try {
                // 同月可能有多页甚至相同拍摄秒；原始游标分页完整后再一次性插入。
                val staged = mutableListOf<SynologyPhoto>()
                val stagedIds = mutableSetOf<SynologyPhotoId>()
                var offset = 0
                do {
                    val page = repository.photos(SynologyPhotoSpace.PERSONAL, request, offset, pageSize)
                    checkCurrent(token); validatePage(page, offset)
                    val added = page.items.filter { stagedIds.add(it.id) && it.id !in confirmedDeletedIds }
                    if (page.hasMore && added.isEmpty()) invalid()
                    staged += added
                    offset = page.nextOffset
                    if (!page.hasMore) break
                    yield()
                } while (true)
                checkCurrent(token)
                val existing = state.value.items.mapTo(mutableSetOf()) { it.id }
                replaceItems(staged.filterNot { it.id in existing } + state.value.items)
                previousMonth = next
                mutable.update { it.copy(hasPrevious = it.months.any { month -> month > next }, paginationKey = it.paginationKey + 1) }
            } catch (error: Exception) {
                if (error !is CancellationException && current(token)) mutable.update { it.copy(previousError = error) }
            } finally { if (current(token)) mutable.update { it.copy(loadingPrevious = false) } }
        }
        return previousJob
    }

    fun loadFilterOptions(): Job? {
        if (!active || state.value.optionsLoading) return null
        val token = ++optionsGeneration
        mutable.update { it.copy(optionsLoading = true, optionsError = null) }
        optionsJob = scope.launch {
            try {
                val options = repository.filterOptions()
                if (active && token == optionsGeneration) mutable.update { it.copy(options = options) }
            } catch (error: Exception) {
                if (error !is CancellationException && active && token == optionsGeneration) mutable.update { it.copy(optionsError = error) }
            } finally { if (active && token == optionsGeneration) mutable.update { it.copy(optionsLoading = false) } }
        }
        return optionsJob
    }

    suspend fun thumbnail(photo: SynologyPhoto): ByteArray {
        val token = generation
        return thumbnails.load(photo) { repository.thumbnail(photo) }.also { checkCurrent(token) }
    }

    private fun accept(page: SynologyPhotoPage, requestedOffset: Int) {
        validatePage(page, requestedOffset)
        val existing = state.value.items.mapTo(mutableSetOf()) { it.id }
        val additions = page.items.filter { existing.add(it.id) && it.id !in confirmedDeletedIds }
        if (page.hasMore && additions.isEmpty()) invalid()
        replaceItems(state.value.items + additions)
        nextOffset = page.nextOffset
        mutable.update { it.copy(hasMore = page.hasMore, paginationKey = it.paginationKey + 1) }
    }
    private fun validatePage(page: SynologyPhotoPage, offset: Int) {
        if (page.offset != offset || page.items.size > pageSize || page.nextOffset != offset + page.items.size ||
            (page.hasMore && page.items.isEmpty()) || page.items.map { it.id }.distinct().size != page.items.size ||
            page.items.any { it.id.profileId != profileId || it.id.space != SynologyPhotoSpace.PERSONAL }) invalid()
    }
    private fun replaceItems(items: List<SynologyPhoto>) {
        val groups = SynologyPhotoWindows.groups(items, state.value.navigation.category == SynologyPhotoCategory.RECENT, zone)
        mutable.update { it.copy(items = items, groups = groups) }
    }
    private fun resetRequests(): Long {
        generation++; navigationJob?.cancel(); pagingJob?.cancel(); previousJob?.cancel()
        mutable.update { it.copy(loadingMore = false, loadingPrevious = false, paginationKey = it.paginationKey + 1) }
        return generation
    }
    private fun current(token: Long): Boolean = active && token == generation
    private suspend fun checkCurrent(token: Long) { currentCoroutineContext().ensureActive(); if (!current(token)) throw CancellationException() }
    private fun present(error: Exception, token: Long) {
        if (error !is CancellationException && current(token)) mutable.update { it.copy(error = error) }
    }
    private fun invalid(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)

    fun deactivate(preservePreparedExport: Boolean = false) {
        active = false; resetRequests(); optionsGeneration++; optionsJob?.cancel()
        preview.deactivate(preservePreparedExport); deletion.deactivate()
        mutable.update { it.copy(loading = false, loaded = false, optionsLoading = false) }
        scope.launch { thumbnails.clear() }
    }
    override fun close() { deactivate(); thumbnails.close(); job.cancel(); mutable.value = SynologyPhotosState() }
}

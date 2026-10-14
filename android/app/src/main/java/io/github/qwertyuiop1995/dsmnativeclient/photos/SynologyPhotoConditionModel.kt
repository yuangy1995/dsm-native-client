package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoConditionCodec
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.*

internal data class SynologyPhotoConditionState(
    val condition: SynologyPhotoAlbumCondition? = null, val userId: Long = 0,
    val spaces: List<SynologyPhotoSpace> = emptyList(),
    val search: String = "", val suggestions: Map<String, List<SynologyPhotoConditionOption>>? = null,
    val searching: Boolean = false, val searchError: Throwable? = null,
    val count: Long? = null, val counting: Boolean = false, val countError: Throwable? = null,
    val path: List<SynologyPhotoCollection> = emptyList(), val folders: List<SynologyPhotoCollection> = emptyList(),
    val foldersLoading: Boolean = false, val moreFolders: Boolean = true, val folderError: Throwable? = null,
) {
    val valid: Boolean get() = condition?.let { value -> runCatching { SynologyPhotoConditionCodec.canonical(value, userId) }.isSuccess } == true
}

/** 规则编辑中的读取可取消；写入和恢复仍由相册模型统一负责。 */
internal class SynologyPhotoConditionModel(
    private val repository: SynologyPhotosServing, private val scope: CoroutineScope,
    private val requireCurrent: () -> Unit, private val canEdit: () -> Boolean,
) {
    private val mutable = MutableStateFlow(SynologyPhotoConditionState())
    val state = mutable.asStateFlow()
    private val drafts = mutableMapOf<SynologyPhotoSpace, SynologyPhotoAlbumCondition>()
    private var generation = 0L
    private var searchSequence = 0L; private var countSequence = 0L
    private var searchJob: Job? = null; private var countJob: Job? = null; private var folderJob: Job? = null

    fun initialize(user: Long, spaces: List<SynologyPhotoSpace>, condition: SynologyPhotoAlbumCondition? = null) {
        reset()
        if (user <= 0 || spaces.isEmpty() || condition != null && condition.space !in spaces)
            throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        mutable.value = SynologyPhotoConditionState(userId = user, spaces = spaces, condition = condition ?: empty(spaces.first(), user))
    }
    fun reset() {
        generation++; searchJob?.cancel(); countJob?.cancel(); folderJob?.cancel(); drafts.clear()
        mutable.value = SynologyPhotoConditionState()
    }
    fun selectSource(space: SynologyPhotoSpace) {
        val old = state.value; val condition = old.condition ?: return
        if (!canEdit() || space !in old.spaces || space == condition.space) return
        drafts[condition.space] = condition
        generation++; searchJob?.cancel(); countJob?.cancel(); folderJob?.cancel()
        mutable.value = SynologyPhotoConditionState(userId = old.userId, spaces = old.spaces, condition = drafts[space] ?: empty(space, old.userId))
    }
    private fun empty(space: SynologyPhotoSpace, user: Long) = SynologyPhotoAlbumCondition().withField("user_id", JsonPrimitive(if (space == SynologyPhotoSpace.SHARED) 0 else user))
    fun change(transform: (SynologyPhotoAlbumCondition) -> SynologyPhotoAlbumCondition) {
        val condition = state.value.condition ?: return
        if (!canEdit()) return
        countSequence++; countJob?.cancel()
        mutable.update { it.copy(condition = transform(condition), count = null, counting = false, countError = null) }
    }
    fun values(key: String, values: List<JsonElement>) = change { it.withValues(key, values) }
    fun policy(field: SynologyPhotoConditionField, all: Boolean) = change {
        it.withField("${field.key}_policy", JsonPrimitive(if (all) "and" else "or"))
    }
    fun add(key: String, option: SynologyPhotoConditionOption) = change { old ->
        var next = old.withValues(key, (old.values(key) + option.value).distinct())
        if (SynologyPhotoConditionField.entries.any { it.key == key && it.supportsPolicy } && "${key}_policy" !in next.fields)
            next = next.withField("${key}_policy", JsonPrimitive("or"))
        next.copy(names = next.names + (key to (next.names[key].orEmpty().filterNot { it.value == option.value } + option)))
    }
    fun remove(key: String, value: JsonElement) = change { it.withValues(key, it.values(key).filterNot { old -> old == value }) }
    fun searchText(value: String) {
        if (!canEdit()) return
        searchSequence++; searchJob?.cancel()
        mutable.update { it.copy(search = value, suggestions = null, searching = false, searchError = null) }
    }
    fun search(): Job? {
        val old = state.value; val space = old.condition?.space ?: return null
        if (!canEdit() || old.searching) return null
        val token = generation; val request = ++searchSequence
        mutable.update { it.copy(searching = true, suggestions = null, searchError = null) }
        searchJob = scope.launch {
            try {
                requireCurrent()
                val choices = repository.conditionSuggestions(old.search.trim(), space)
                currentCoroutineContext().ensureActive(); requireCurrent()
                if (token == generation && request == searchSequence) mutable.update { it.copy(suggestions = choices) }
            } catch (error: Exception) { if (error !is CancellationException && token == generation && request == searchSequence) mutable.update { it.copy(searchError = error) } }
            finally { if (token == generation && request == searchSequence) mutable.update { it.copy(searching = false) } }
        }
        return searchJob
    }
    fun preview(): Job? {
        val old = state.value; val condition = old.condition ?: return null
        if (!canEdit() || old.counting || !old.valid) return null
        val token = generation; val request = ++countSequence
        mutable.update { it.copy(counting = true, count = null, countError = null) }
        countJob = scope.launch {
            try {
                requireCurrent()
                val count = repository.conditionItemCount(condition)
                currentCoroutineContext().ensureActive(); requireCurrent()
                if (token == generation && request == countSequence) mutable.update { it.copy(count = count) }
            } catch (error: Exception) { if (error !is CancellationException && token == generation && request == countSequence) mutable.update { it.copy(countError = error) } }
            finally { if (token == generation && request == countSequence) mutable.update { it.copy(counting = false) } }
        }
        return countJob
    }
    fun enter(folder: SynologyPhotoCollection) {
        if (!canEdit() || state.value.foldersLoading || folder !in state.value.folders) return
        mutable.update { it.copy(path = it.path + folder, folders = emptyList(), moreFolders = true, folderError = null) }
        loadFolders()
    }
    fun up() {
        if (!canEdit() || state.value.foldersLoading || state.value.path.size <= 1) return
        mutable.update { it.copy(path = it.path.dropLast(1), folders = emptyList(), moreFolders = true, folderError = null) }
        loadFolders()
    }
    fun loadFolders(): Job? {
        val old = state.value; val space = old.condition?.space ?: return null
        if (!canEdit() || old.foldersLoading || !old.moreFolders) return null
        val token = generation
        mutable.update { it.copy(foldersLoading = true, folderError = null) }
        folderJob = scope.launch {
            try {
                requireCurrent()
                val path = old.path.ifEmpty { listOf(repository.rootFolder(space)) }
                val folders = repository.folders(space, path.last().id, old.folders.size, 100)
                currentCoroutineContext().ensureActive(); requireCurrent()
                val seen = old.folders.mapTo(mutableSetOf()) { it.id }
                if (folders.size > 100 || folders.any { it.id <= 0 || it.space != space || !seen.add(it.id) })
                    throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
                if (token == generation) mutable.update { it.copy(path = path, folders = old.folders + folders, moreFolders = folders.size == 100) }
            } catch (error: Exception) { if (error !is CancellationException && token == generation) mutable.update { it.copy(folderError = error) } }
            finally { if (token == generation) mutable.update { it.copy(foldersLoading = false) } }
        }
        return folderJob
    }
}

package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerRegistryImage
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogEntry
import io.github.qwertyuiop1995.dsmnativeclient.data.container.containerEvents
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 容器总览、仓库搜索与标签各自拥有读取任务，撤权和切换可一并取消并拒绝迟到结果。 */
internal class ContainerReadFeatureModel(
    private val scope: CoroutineScope,
    private val workspace: MutableStateFlow<WorkspaceState?>,
    private val repository: () -> DsmRepository?,
) {
    private val containerRegistrySearchGeneration = AtomicLong(0)
    private val containerRegistryTagsGeneration = AtomicLong(0)
    private val overviewGeneration = AtomicLong(0)
    private var overviewJob: Job? = null
    private var eventsJob: Job? = null
    private val eventsGeneration = AtomicLong(0)
    private val mutableEvents = MutableStateFlow<Loadable<List<LogEntry>>>(Loadable.Idle)
    val events = mutableEvents.asStateFlow()
    private var searchJob: Job? = null
    private var tagsJob: Job? = null

    fun invalidate() {
        stopEvents()
        mutableEvents.value = Loadable.Idle
        overviewGeneration.incrementAndGet()
        overviewJob?.cancel(); overviewJob = null
        invalidateRegistry()
    }

    fun loadEvents() {
        val repo = repository() ?: return
        if (workspace.value?.availability?.allows(Module.CONTAINERS) != true) return
        stopEvents()
        val generation = eventsGeneration.incrementAndGet()
        mutableEvents.value = Loadable.Loading
        eventsJob = scope.launch {
            val result = captureLoadable { repo.containerManagement.containerEvents() }
            if (repository() === repo && eventsGeneration.get() == generation) mutableEvents.value = result
        }
    }
    fun stopEvents() {
        eventsGeneration.incrementAndGet(); eventsJob?.cancel(); eventsJob = null
        if (mutableEvents.value is Loadable.Loading) mutableEvents.value = Loadable.Idle
    }

    private fun invalidateRegistry() {
        containerRegistrySearchGeneration.incrementAndGet()
        containerRegistryTagsGeneration.incrementAndGet()
        searchJob?.cancel(); tagsJob?.cancel()
        searchJob = null; tagsJob = null
    }

    fun loadModule(repo: DsmRepository) {
        if (repository() !== repo || workspace.value?.availability?.allows(Module.CONTAINERS) != true) return
        overviewJob?.cancel()
        val generation = overviewGeneration.incrementAndGet()
        workspace.update { it?.copy(containers = Loadable.Loading) }
        overviewJob = scope.launch {
            val value = captureLoadable { repo.containerOverview() }
            workspace.update { current ->
                current?.takeIf { repository() === repo && overviewGeneration.get() == generation }
                    ?.copy(containers = value) ?: current
            }
        }
    }

    fun showRegistry() {
        val state = workspace.value ?: return
        if (!state.availability.allows(Module.CONTAINERS) || state.selectedModule != Module.CONTAINERS || !state.supportsContainerRegistry) return
        if (state.containerRegistryVisible) return
        invalidateRegistry()
        workspace.update { current ->
            current?.takeIf {
                it.selectedModule == Module.CONTAINERS && it.supportsContainerRegistry
            }?.copy(
                containerRegistryVisible = true,
                containerRegistryResults = current.containerRegistryResults.takeUnless { value ->
                    value is Loadable.Loading
                } ?: Loadable.Idle,
                selectedContainerRegistryImage = null,
                containerRegistryTags = Loadable.Idle,
            ) ?: current
        }
    }

    fun closeRegistry() {
        invalidateRegistry()
        workspace.update {
            it?.copy(
                containerRegistryVisible = false,
                containerRegistryResults = it.containerRegistryResults.takeUnless { value ->
                    value is Loadable.Loading
                } ?: Loadable.Idle,
                selectedContainerRegistryImage = null,
                containerRegistryTags = Loadable.Idle,
            )
        }
    }

    fun updateQuery(value: String) {
        if (value.length > 200) return
        if (workspace.value?.containerRegistryQuery == value) return
        invalidateRegistry()
        workspace.update {
            it?.copy(
                containerRegistryQuery = value,
                containerRegistryResults = Loadable.Idle,
                selectedContainerRegistryImage = null,
                containerRegistryTags = Loadable.Idle,
            )
        }
    }

    fun searchRegistry() {
        val repo = repository() ?: return
        val state = workspace.value ?: return
        if (!state.containerRegistryVisible || state.selectedModule != Module.CONTAINERS) return
        val query = state.containerRegistryQuery.trim()
        if (query.isEmpty()) return
        val token = ContainerRegistrySearchToken(
            generation = containerRegistrySearchGeneration.incrementAndGet(),
            profileId = state.profile.id,
            query = query,
        )
        containerRegistryTagsGeneration.incrementAndGet()
        workspace.update {
            it?.copy(
                containerRegistryResults = Loadable.Loading,
                selectedContainerRegistryImage = null,
                containerRegistryTags = Loadable.Idle,
            )
        }
        searchJob?.cancel()
        searchJob = scope.launch {
            capture(
                block = { repo.searchContainerRegistry(query) },
                update = { value ->
                    workspace.update { state ->
                        if (repository() === repo && state?.matchesContainerRegistrySearch(
                                token,
                                containerRegistrySearchGeneration.get(),
                            ) == true
                        ) {
                            state.copy(containerRegistryResults = value)
                        } else state
                    }
                },
            )
        }
    }

    fun selectImage(image: ContainerRegistryImage) {
        val repo = repository() ?: return
        val state = workspace.value ?: return
        if (!state.containerRegistryVisible || state.selectedModule != Module.CONTAINERS) return
        val token = ContainerRegistryTagsToken(
            generation = containerRegistryTagsGeneration.incrementAndGet(),
            profileId = state.profile.id,
            imageId = image.id,
        )
        workspace.update {
            it?.copy(
                selectedContainerRegistryImage = image,
                containerRegistryTags = Loadable.Loading,
            )
        }
        tagsJob?.cancel()
        tagsJob = scope.launch {
            capture(
                block = { repo.containerRegistryTags(image.name) },
                update = { value ->
                    workspace.update { state ->
                        if (repository() === repo && state?.matchesContainerRegistryTags(
                                token,
                                containerRegistryTagsGeneration.get(),
                            ) == true
                        ) {
                            state.copy(containerRegistryTags = value)
                        } else state
                    }
                },
            )
        }
    }

    private suspend fun <T> capture(block: suspend () -> T, update: (Loadable<T>) -> Unit) {
        update(captureLoadable(block))
    }
}

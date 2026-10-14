package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

/** NAS任务目标复用图库导航，并核对读取完成后的完整目录身份。 */
internal suspend fun openPhotoBackgroundTarget(path: List<SynologyPhotoCollection>, state: MutableStateFlow<SynologyPhotosState>,
    allowed: () -> Boolean, before: () -> Unit, refresh: () -> Job?) {
    fun invalid(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
    if (!allowed() || state.value.loading || path.isEmpty()) invalid()
    val space = path.last().space
    if (space !in state.value.access?.spaces.orEmpty() || path.any { it.space != space }) invalid()
    before()
    state.update { it.copy(navigation = SynologyPhotoNavigation(space = space, section = SynologyPhotosSection.FOLDERS, folders = path)) }
    val loading = refresh() ?: throw CancellationException(); loading.join()
    val navigation = state.value.navigation
    if (!allowed() || navigation.section != SynologyPhotosSection.FOLDERS || navigation.folders.size != path.size || navigation.folders.zip(path).any { (a, b) ->
            a.id != b.id || a.space != b.space || a.parentId != b.parentId || a.path != b.path || a.name != b.name
        }) throw CancellationException()
    state.value.error?.let { throw it }
}

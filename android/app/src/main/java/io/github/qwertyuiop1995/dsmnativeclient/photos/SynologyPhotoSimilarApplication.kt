package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal data class SynologyPhotoSimilarResult(val items: List<SynologyPhoto>, val replaced: Set<SynologyPhotoId>,
    val added: Set<SynologyPhotoId>, val removed: Set<SynologyPhotoId>)

/** 仅更新当前月份已有组；撤销不把别的月份插回当前页面。推荐改变时使用真实成员。 */
internal fun applyPhotoSimilarGroup(state: SynologyPhotosState, group: SynologyPhotoSimilarGroup,
    detail: SynologyPhotoSimilarDetail?): SynologyPhotoSimilarResult? {
    if (state.navigation.category != SynologyPhotoCategory.SIMILAR || state.navigation.space != group.space) return null
    val old = state.items.singleOrNull { it.similarGroup?.id == group.id && it.id.profileId == group.profileId && it.id.space == group.space } ?: return null
    val next = detail?.let { value -> value.photos.single { it.id.itemId == value.group.topPickId }.copy(similarGroup = value.group) }
    val items = state.items.mapNotNull { if (it.id == old.id) next else it }
    return SynologyPhotoSimilarResult(items, setOf(old.id), setOfNotNull(next?.id), if (next == null) setOf(old.id) else emptySet())
}

/** 保留内存中的当前查询位置，只有同一窗口的撤销才能恢复已拆组的卡片和分页位置。 */
internal class SynologyPhotoSimilarApplication(
    private val repository: SynologyPhotosServing, private val state: MutableStateFlow<SynologyPhotosState>,
    private val query: () -> SynologyPhotoQuery?, private val paged: MutableSet<SynologyPhotoId>,
    private val offset: () -> Int, private val updateOffset: (Int) -> Unit,
    private val generation: () -> Long, private val checkCurrent: suspend (Long) -> Unit,
    private val reset: () -> Unit, private val replaceItems: (List<SynologyPhoto>) -> Unit,
    private val clearSelection: (Set<SynologyPhotoId>) -> Unit,
) {
    private data class Position(val index: Int, val paged: Boolean, val query: SynologyPhotoQuery?)
    private val deletionRefresh = Mutex()
    private val positions = mutableMapOf<String, Position>()
    suspend fun apply(row: SynologyPhotoAlbumCheckpoint) { update(row.similar!!.group, row) }
    suspend fun originalDeleted(group: SynologyPhotoSimilarGroup) { deletionRefresh.withLock { update(group, null) } }
    private suspend fun update(group: SynologyPhotoSimilarGroup, row: SynologyPhotoAlbumCheckpoint?) {
        val token = generation(); val detail = repository.similarGroupDetails(group); checkCurrent(token)
        val current = state.value
        if (current.navigation.category != SynologyPhotoCategory.SIMILAR || current.navigation.space != group.space) return
        val change = row?.similar; val oldIndex = current.items.indexOfFirst { it.similarGroup?.id == group.id && it.id.profileId == group.profileId }
        if (oldIndex >= 0 && row != null && change?.canUndo == true)
            positions[row.operationId] = Position(oldIndex, current.items[oldIndex].id in paged, query())
        val result = applyPhotoSimilarGroup(current, group, detail)
        if (result != null) {
            val wasPaged = result.replaced.any { it in paged }
            reset(); updateOffset(maxOf(0, offset() - result.removed.count { it in paged }))
            paged.removeAll(result.replaced); if (wasPaged) paged.addAll(result.added)
            clearSelection(result.replaced); replaceItems(result.items)
        } else if (change?.edit == SynologyPhotoSimilarEdit.UNDO && detail != null) {
            val position = positions[change.undo!!.operationId]
            if (position != null && position.query == query()) {
                val representative = detail.photos.single { it.id.itemId == detail.group.topPickId }.copy(similarGroup = detail.group)
                val items = current.items.toMutableList().apply { add(minOf(position.index, size), representative) }
                reset(); if (position.paged) { paged += representative.id; updateOffset(offset() + 1) }
                replaceItems(items)
            }
        }
        change?.undo?.let { positions.remove(it.operationId) }
    }
    fun clear() { positions.clear() }
}

package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

/** 只应用已回读的主题及原件缺席结果，不重置月份和其余来源。 */
internal fun applyPhotoConceptResult(values: List<SynologyPhotoCollection>, row: SynologyPhotoAlbumCheckpoint): List<SynologyPhotoCollection> {
    val change = row.concept ?: return values
    if (!row.finished) return values
    return values.map { value -> if (value.space == change.space) change.updated.singleOrNull { it.id == value.id }?.collection() ?: value else value }
}

internal fun applyPhotoConceptChange(state: MutableStateFlow<SynologyPhotosState>, row: SynologyPhotoAlbumCheckpoint,
    latest: List<SynologyPhotoCollection>?, onRemoved: (Set<SynologyPhotoId>) -> Unit): Int? {
    val change = row.concept ?: return null
    if (!row.finished || change.updated.isEmpty()) return null
    var offset: Int? = null; var removed = emptySet<SynologyPhotoId>()
    state.update { current ->
        val navigation = current.navigation
        if (navigation.space != change.space || navigation.category != SynologyPhotoCategory.SUBJECTS) return@update current
        val target = navigation.categoryItem
        if (target == null) {
            if (latest == null) return@update current
            val collections = latest.filter { it.space == change.space && SynologyPhotoConceptSnapshot(it).appearsInList }
            offset = collections.size
            current.copy(collections = collections, hasMoreCollections = false, paginationKey = current.paginationKey + 1)
        } else {
            val updated = change.updated.singleOrNull { it.id == target.id }?.collection() ?: return@update current
            removed = row.targets.filter { it.id.itemId in change.removedPhotoIds }.map { it.id }.toSet()
            current.copy(navigation = navigation.copy(categoryItem = updated), items = current.items.filterNot { it.id in removed },
                groups = current.groups.mapNotNull { group -> group.copy(items = group.items.filterNot { it.id in removed }).takeIf { it.items.isNotEmpty() } })
        }
    }
    if (removed.isNotEmpty()) onRemoved(removed)
    return offset
}

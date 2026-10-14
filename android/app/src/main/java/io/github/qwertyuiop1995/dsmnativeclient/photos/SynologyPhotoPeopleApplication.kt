package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

/** 仅应用已完成的人物结果；保持图库月份、照片选择和其他来源不变。 */
internal fun applyPhotoPeopleResult(people: List<SynologyPhotoCollection>, row: SynologyPhotoAlbumCheckpoint): List<SynologyPhotoCollection> {
    val change = row.people ?: return people
    return people.mapNotNull { person ->
        when {
            person.space != change.space || person.id !in change.completedIds -> person
            person.id in change.removedIds -> null
            row.action == SynologyPhotoAlbumAction.SHOW_PEOPLE -> person.copy(personVisible = change.visible)
            row.action.isPersonFaces -> if (row.action == SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES && person.id == change.originals.getOrNull(1)?.id)
                person.copy(name = change.name!!) else if (person.id == change.originals.first().id)
                    person.copy(count = person.count?.let { maxOf(0, it - change.faces!!.removedPhotoIds.size) }) else person
            else -> person.copy(name = change.name!!, count = if (row.action == SynologyPhotoAlbumAction.MERGE_PEOPLE) change.memberIds!!.size else person.count)
        }
    }
}

/** 完整人物读取可更新分页窗口；人物内容页仅更新标题，不重置照片时间窗口。 */
internal fun applyPhotoPeopleChange(state: MutableStateFlow<SynologyPhotosState>, row: SynologyPhotoAlbumCheckpoint,
    latest: List<SynologyPhotoCollection>?, onRemoved: (Set<SynologyPhotoId>) -> Unit = {}): Int? {
    val change = row.people ?: return null
    if (!row.finished || change.completedIds.isEmpty()) return null
    var offset: Int? = null; var removedPhotos = emptySet<SynologyPhotoId>()
    state.update { current ->
        val navigation = current.navigation
        if (navigation.space != change.space || navigation.category != SynologyPhotoCategory.PEOPLE) return@update current
        if (navigation.categoryItem == null) {
            val people = (latest ?: applyPhotoPeopleResult(current.collections, row)).filter { it.personVisible != false }
            offset = people.size
            current.copy(collections = people, hasMoreCollections = if (latest == null) current.hasMoreCollections else false,
                paginationKey = current.paginationKey + 1)
        } else {
            val original = navigation.categoryItem
            val item = latest?.singleOrNull { it.id == original.id } ?: applyPhotoPeopleResult(listOf(original), row).singleOrNull() ?:
                if (row.action == SynologyPhotoAlbumAction.RENAME_PERSON && original.id in change.removedIds) original.copy(name = change.name!!, personVisible = false) else original
            val removed = if (original.id == change.originals.first().id) row.targets.map { it.id }.filter { it.itemId in change.faces?.removedPhotoIds.orEmpty() }.toSet() else emptySet()
            removedPhotos = removed
            current.copy(navigation = navigation.copy(categoryItem = item), items = current.items.filterNot { it.id in removed },
                groups = current.groups.mapNotNull { group -> group.copy(items = group.items.filterNot { it.id in removed }).takeIf { it.items.isNotEmpty() } })
        }
    }
    if (removedPhotos.isNotEmpty()) onRemoved(removedPhotos)
    return offset
}

/** 手工人脸完成后按当前读取更新人物标题和成员，不重置图库月份。 */
internal suspend fun applyPhotoManualFacesChange(repository: SynologyPhotosServing, state: MutableStateFlow<SynologyPhotosState>,
    row: SynologyPhotoAlbumCheckpoint, check: suspend () -> Unit, onRemoved: (Set<SynologyPhotoId>) -> Unit): Int? {
    val target = row.targets.single(); val navigation = state.value.navigation
    if (navigation.space != target.id.space || navigation.category != SynologyPhotoCategory.PEOPLE) return null
    val people = repository.managementPeople(target.id.space, true)
    val faces = if (navigation.categoryItem != null) repository.photoFaces(target.photo()) else emptyList()
    check(); var offset: Int? = null; var removed = emptySet<SynologyPhotoId>()
    state.update { current ->
        if (current.navigation != navigation) return@update current
        val person = navigation.categoryItem
        if (person == null) {
            val visible = people.filter { it.personVisible != false }; offset = visible.size
            current.copy(collections = visible, hasMoreCollections = false, paginationKey = current.paginationKey + 1)
        } else {
            if (faces.none { it.face.personId == person.id }) removed = setOf(target.id)
            current.copy(navigation = navigation.copy(categoryItem = people.singleOrNull { it.id == person.id } ?: person.copy(count = 0)),
                items = current.items.filterNot { it.id in removed },
                groups = current.groups.mapNotNull { group -> group.copy(items = group.items.filterNot { it.id in removed }).takeIf { it.items.isNotEmpty() } })
        }
    }
    if (removed.isNotEmpty()) onRemoved(removed)
    return offset
}

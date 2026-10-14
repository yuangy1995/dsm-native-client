package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.time.ZoneId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

/** 只改变设置影响的来源和分类；其他月份、文件夹、选择与列表保持原位。 */
internal fun SynologyPhotosState.applyingPhotoSettings(value: SynologyPhotoSettings): SynologyPhotosState {
    if (value is SynologyPhotoGlobalSettings) {
        val updated = copy(access = access?.copy(supportsOriginalSizeJPEG = value.supportsOriginalJPEG))
        if (navigation.space == SynologyPhotoSpace.PERSONAL) return updated.applyingPhotoSettings(value.recognition())
        val disabled = listOf(SynologyPhotoCategory.PEOPLE to SynologyPhotoRecognition.PEOPLE, SynologyPhotoCategory.SUBJECTS to SynologyPhotoRecognition.SUBJECTS)
            .mapNotNull { (category, key) -> category.takeIf { !value.sharedEnabled || value.sharedRole == SynologyPhotoSharedSettings.Role.NONE ||
                value.sharedRecognition[key] == false || value.values[SynologyPhotoGlobalSetting.entries.first { it.field == key.field }] == false } }.toSet()
        return updated.copy(categories = categories - disabled, navigation = if (navigation.category in disabled)
            navigation.copy(section = SynologyPhotosSection.ALBUMS, category = null, categoryItem = null, keyword = "", filter = SynologyPhotoFilter()) else navigation)
    }
    var updated = this
    val disabled = when (value) {
        is SynologyPhotoRecognitionSettings -> {
            if (navigation.space != SynologyPhotoSpace.PERSONAL || SynologyPhotoSpace.PERSONAL !in access?.spaces.orEmpty()) return this
            listOf(SynologyPhotoCategory.PEOPLE to SynologyPhotoRecognition.PEOPLE, SynologyPhotoCategory.SUBJECTS to SynologyPhotoRecognition.SUBJECTS)
                .mapNotNull { (category, key) -> category.takeIf { !value.personalEnabled || value.personal[key] == false || value.global[key] == false } }.toSet()
        }
        is SynologyPhotoSharedSettings -> {
            val spaces = (access?.spaces.orEmpty() - SynologyPhotoSpace.SHARED).let { if (value.canAccess) it + SynologyPhotoSpace.SHARED else it }
            updated = copy(access = access?.copy(spaces = spaces, canManageSharedSpace = value.canAccess && value.role == SynologyPhotoSharedSettings.Role.MANAGEMENT))
            if (navigation.space != SynologyPhotoSpace.SHARED) return updated
            if (!value.canAccess) return updated.copy(navigation = SynologyPhotoNavigation(space = spaces.firstOrNull() ?: SynologyPhotoSpace.PERSONAL,
                section = if (spaces.isEmpty()) SynologyPhotosSection.ALBUMS else navigation.section), categories = emptySet())
            if (value.role != SynologyPhotoSharedSettings.Role.MANAGEMENT) SynologyPhotoCategory.entries.toSet() else
            listOf(SynologyPhotoCategory.PEOPLE to SynologyPhotoSharedSetting.PEOPLE, SynologyPhotoCategory.SUBJECTS to SynologyPhotoSharedSetting.SUBJECTS)
                .mapNotNull { (category, key) -> category.takeIf { value.values[key] != true || value.global[key] != true } }.toSet()
        }
        else -> return this
    }
    updated = updated.copy(categories = updated.categories - disabled)
    return if (navigation.category in disabled) updated.copy(navigation = navigation.copy(section = SynologyPhotosSection.ALBUMS,
        category = null, categoryItem = null, keyword = "", filter = SynologyPhotoFilter())) else updated
}

/** 设置结果对图库的应用独立于表单，管理员成员保存也复用同一入口。 */
internal class SynologyPhotoSettingsApplication(
    private val repository: SynologyPhotosServing, private val mutable: MutableStateFlow<SynologyPhotosState>,
    private val zone: ZoneId, private val generation: () -> Long, private val current: (Long) -> Boolean,
    private val checkCurrent: suspend (Long) -> Unit, private val navigationChanged: (Boolean) -> Unit,
) {
    suspend fun readPreference(target: SynologyPhotoSettingsTarget, token: Long): SynologyPhotoSettings? {
        if (!repository.canManageSettings(target.kind)) return null
        return try {
            val value = repository.photoSettings(target); checkCurrent(token)
            if (value.target() != target) throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
            value
        } catch (error: Exception) {
            checkCurrent(token)
            if (error is CancellationException) throw error
            mutable.update { it.copy(preferenceErrors = it.preferenceErrors + (target.kind to error)) }
            null
        }
    }
    suspend fun loadListPreferences(navigation: SynologyPhotoNavigation, token: Long) {
        val target = navigation.albumListScope ?: return
        val sort = readPreference(SynologyPhotoSettingsTarget(SynologyPhotoSettingsKind.LIST_SORT, listScope = target), token) as? SynologyPhotoAlbumListSortSettings
        mutable.update { it.copy(albumListSort = sort?.sort) }
        if (target == SynologyPhotoAlbumListScope.ALBUMS) {
            val display = readPreference(SynologyPhotoSettingsTarget(SynologyPhotoSettingsKind.LIST_DISPLAY), token) as? SynologyPhotoAlbumDisplaySettings
            mutable.update { it.copy(albumDisplay = display?.display) }
        }
    }
    suspend fun apply(value: SynologyPhotoSettings) {
        when (value) {
            is SynologyPhotoDisplaySettings -> {
                mutable.update { it.copy(access = it.access?.copy(displaySettings = value),
                    groups = SynologyPhotoWindows.groups(it.items, it.navigation.category == SynologyPhotoCategory.RECENT, zone, value.grouping)) }
            }
            is SynologyPhotoRecognitionSettings, is SynologyPhotoSharedSettings, is SynologyPhotoGlobalSettings -> {
                val previous = mutable.value
                mutable.update { it.applyingPhotoSettings(value) }
                if (previous.navigation != mutable.value.navigation) {
                    navigationChanged(previous.navigation.space != mutable.value.navigation.space); return
                }
                val navigation = mutable.value.navigation
                val source = if (value is SynologyPhotoGlobalSettings) navigation.space else if (value is SynologyPhotoSharedSettings) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL
                if (current(generation()) && navigation.space == source && source in mutable.value.access?.spaces.orEmpty() &&
                    (navigation.showsCollectionRoot || navigation.category != null)) {
                    val token = generation()
                    try {
                        val categories = repository.categories(source)
                        if (current(token)) mutable.update { it.copy(categories = categories, categoriesError = null) }
                    } catch (error: Exception) {
                        if (error is CancellationException) throw error
                        if (current(token)) mutable.update { it.copy(categoriesError = error) }
                    }
                }
            }
            else -> Unit
        }
    }
}

/** 权限更新后只重读原查询的已加载范围，不重新定位到最新月份。 */
internal suspend fun readPhotoMemberWindow(repository: SynologyPhotosServing, space: SynologyPhotoSpace, query: SynologyPhotoQuery,
    count: Int, pageSize: Int, accept: suspend (SynologyPhotoPage, Int) -> Unit) {
    var offset = 0
    do {
        val page = repository.photos(space, query, offset, minOf(pageSize, count - offset))
        accept(page, offset)
        offset += page.items.size
    } while (page.hasMore && page.items.isNotEmpty() && offset < count)
}

/** 共享权限变化时仅保留恢复位置，不保留先前可能失权的照片或目录。 */
internal data class SynologyPhotoMemberWindow(val navigation: SynologyPhotoNavigation, val query: SynologyPhotoQuery?, val count: Int)

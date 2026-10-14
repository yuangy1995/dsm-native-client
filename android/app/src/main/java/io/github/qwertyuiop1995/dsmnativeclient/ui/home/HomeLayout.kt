package io.github.qwertyuiop1995.dsmnativeclient.ui.home

import androidx.annotation.StringRes
import io.github.qwertyuiop1995.dsmnativeclient.R

/** 稳定标识只用于本机界面偏好，不包含 NAS 或账号身份。 */
internal enum class HomeSection(val id: String, @StringRes val title: Int) {
    QUICK_ACTIONS("quickActions", R.string.client_home_quick_actions),
    ACTIVE_TASKS("activeTasks", R.string.client_active_tasks),
    COMMON_LOCATIONS("commonLocations", R.string.client_common_locations),
    RECENT_ITEMS("recentItems", R.string.client_recent_access),
}

/** 只保存用户主动隐藏的模块；暂时缺少权限不会改写此偏好。 */
internal data class HomeLayout(val hidden: Set<HomeSection> = emptySet()) {
    fun isVisible(section: HomeSection): Boolean = section !in hidden

    fun withVisibility(section: HomeSection, visible: Boolean): HomeLayout =
        copy(hidden = if (visible) hidden - section else hidden + section)

    fun encode(): String = HomeSection.entries.filter { it in hidden }.joinToString("|") { it.id }

    companion object {
        fun decode(value: String?): HomeLayout {
            val identifiers = value?.split('|')?.toSet().orEmpty()
            return HomeLayout(HomeSection.entries.filter { it.id in identifiers }.toSet())
        }
    }
}

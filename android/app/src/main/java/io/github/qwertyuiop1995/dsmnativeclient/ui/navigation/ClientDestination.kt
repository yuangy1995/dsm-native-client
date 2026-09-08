package io.github.qwertyuiop1995.dsmnativeclient.ui.navigation

import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Apps
import androidx.compose.material.icons.outlined.CloudDownload
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.ui.graphics.vector.ImageVector
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module

/** 界面目的地与业务模块分离；首页、设备根页也必须通过原模块退出门。 */
internal enum class ClientDestination(val id: String, @StringRes val title: Int, val module: Module) {
    HOME("home", R.string.client_home, Module.SETTINGS),
    FILES("files", R.string.client_files, Module.FILES),
    PHOTOS("photos", R.string.client_photos, Module.PHOTOS),
    CHAT("chat", R.string.client_chat, Module.CHAT),
    DEVICE("device", R.string.client_device, Module.SETTINGS),
    TASKS("tasks", R.string.client_tasks, Module.TRANSFERS),
    DOWNLOADS("downloads", R.string.client_downloads, Module.DOWNLOADS),
    CONTAINERS("containers", R.string.module_containers, Module.CONTAINERS),
    VIRTUAL_MACHINES("virtual-machines", R.string.module_virtual_machines, Module.VIRTUAL_MACHINES),
    SETTINGS("settings", R.string.client_app_settings, Module.SETTINGS),
    NAS_SETTINGS("nas-settings", R.string.module_nas_settings, Module.NAS_SETTINGS);

    val icon: ImageVector get() = when (this) {
        HOME -> Icons.Outlined.Home
        FILES -> Icons.Outlined.FolderOpen
        PHOTOS -> Icons.Outlined.PhotoLibrary
        CHAT -> Icons.Outlined.ChatBubbleOutline
        DEVICE, NAS_SETTINGS -> Icons.Outlined.Dns
        TASKS -> Icons.Outlined.SwapVert
        DOWNLOADS -> Icons.Outlined.CloudDownload
        CONTAINERS -> Icons.Outlined.Apps
        VIRTUAL_MACHINES -> Icons.Outlined.Computer
        SETTINGS -> Icons.Outlined.Settings
    }

    companion object {
        val defaults = listOf(HOME, FILES, PHOTOS, CHAT, DEVICE)
        val pinnable = entries.filter { it != NAS_SETTINGS }
        fun forModule(module: Module): ClientDestination = when (module) {
            Module.FILES -> FILES
            Module.PHOTOS -> PHOTOS
            Module.CHAT -> CHAT
            Module.DOWNLOADS -> DOWNLOADS
            Module.CONTAINERS -> CONTAINERS
            Module.VIRTUAL_MACHINES -> VIRTUAL_MACHINES
            Module.NAS_SETTINGS -> NAS_SETTINGS
            Module.TRANSFERS -> TASKS
            Module.SETTINGS -> SETTINGS
        }
    }
}

internal data class PinnedModules(val items: List<ClientDestination> = ClientDestination.defaults) {
    init {
        require(items.size <= 5 && items.distinct().size == items.size)
        require(items.all { it in ClientDestination.pinnable })
    }

    fun hide(item: ClientDestination) = PinnedModules(items - item)
    fun add(item: ClientDestination) = PinnedModules(items + item)
    fun replace(index: Int, item: ClientDestination) = PinnedModules(items.toMutableList().also { it[index] = item })
    fun move(item: ClientDestination, by: Int): PinnedModules {
        val index = items.indexOf(item)
        val target = index + by
        if (index < 0 || target !in items.indices) return this
        return PinnedModules(items.toMutableList().also { it.add(target, it.removeAt(index)) })
    }

    fun encode(): String = items.joinToString("|") { it.id }

    companion object {
        /** 空串表示用户隐藏了全部固定项；未知的旧/新版本标识不参与导航。 */
        fun decode(value: String?): PinnedModules = if (value == null) PinnedModules() else PinnedModules(
            value.split('|').mapNotNull { id -> ClientDestination.pinnable.firstOrNull { it.id == id } }
                .distinct().take(5),
        )
    }
}

internal enum class ClientEntryAction { SEARCH, UPLOAD, PHOTO_BACKUP, DOWNLOAD_CREATE, FAVORITES, RECENT, SHARE_LINKS }

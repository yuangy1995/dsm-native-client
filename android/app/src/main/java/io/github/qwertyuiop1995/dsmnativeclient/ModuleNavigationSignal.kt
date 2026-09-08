package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.Module

/** 内存内的导航通知，使同一业务模块的外链也能离开首页/设备等界面根页。 */
internal data class ModuleNavigationSignal(val profileId: String, val module: Module, val revision: Long)

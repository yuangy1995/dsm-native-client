package io.github.qwertyuiop1995.dsmnativeclient.ui.navigation

import androidx.compose.runtime.staticCompositionLocalOf

/** 首页/顶栏的一次性界面入口，不携带凭据或文件载荷。 */
internal data class ClientEntryRequest(val action: ClientEntryAction, val revision: Long, val consume: () -> Unit)
internal val LocalClientEntry = staticCompositionLocalOf<ClientEntryRequest?> { null }

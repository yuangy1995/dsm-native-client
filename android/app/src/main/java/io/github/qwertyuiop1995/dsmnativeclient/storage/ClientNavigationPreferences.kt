package io.github.qwertyuiop1995.dsmnativeclient.storage

import android.content.Context
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.PinnedModules

/** 用户已授权的本机界面偏好，不接触 NAS、账号、密码或会话存储。 */
internal class ClientNavigationPreferences(context: Context) {
    private val preferences = context.getSharedPreferences("lanstash_interface", Context.MODE_PRIVATE)
    fun load(): PinnedModules = PinnedModules.decode(preferences.getString("pinned_modules_v1", null))
    fun save(value: PinnedModules): Boolean = preferences.edit().putString("pinned_modules_v1", value.encode()).commit()
}

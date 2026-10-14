package io.github.qwertyuiop1995.dsmnativeclient.storage

import android.content.Context
import io.github.qwertyuiop1995.dsmnativeclient.ui.home.HomeLayout

/** 与导航共用本机界面偏好文件，仅写自己的键，不影响账号和其他偏好。 */
internal class ClientHomePreferences(context: Context) {
    private val preferences = context.getSharedPreferences("lanstash_interface", Context.MODE_PRIVATE)

    fun load(): HomeLayout = HomeLayout.decode(preferences.getString("hidden_home_sections_v1", null))

    fun save(value: HomeLayout): Boolean = preferences.edit()
        .putString("hidden_home_sections_v1", value.encode())
        .commit()
}

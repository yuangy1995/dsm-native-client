package io.github.qwertyuiop1995.dsmnativeclient.testing

import android.content.SharedPreferences
import java.util.concurrent.ConcurrentHashMap

/** 仅替代 Android 存储介质；测试仍走正式序列化、跨实例锁与保存入口。 */
internal class MemoryPreferences : SharedPreferences {
    private val values = ConcurrentHashMap<String, Any>()
    var commitSucceeds = true
    override fun getAll(): MutableMap<String, *> = values.toMutableMap()
    override fun getString(key: String?, defValue: String?): String? = values[key] as? String ?: defValue
    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
        (values[key] as? Set<String>)?.toMutableSet() ?: defValues
    override fun getInt(key: String?, defValue: Int) = values[key] as? Int ?: defValue
    override fun getLong(key: String?, defValue: Long) = values[key] as? Long ?: defValue
    override fun getFloat(key: String?, defValue: Float) = values[key] as? Float ?: defValue
    override fun getBoolean(key: String?, defValue: Boolean) = values[key] as? Boolean ?: defValue
    override fun contains(key: String?) = values.containsKey(key)
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        private val updates = mutableMapOf<String, Any?>()
        private var clear = false
        private fun put(key: String?, value: Any?): SharedPreferences.Editor = apply { updates[requireNotNull(key)] = value }
        override fun putString(key: String?, value: String?) = put(key, value)
        override fun putStringSet(key: String?, values: MutableSet<String>?) = put(key, values?.toSet())
        override fun putInt(key: String?, value: Int) = put(key, value)
        override fun putLong(key: String?, value: Long) = put(key, value)
        override fun putFloat(key: String?, value: Float) = put(key, value)
        override fun putBoolean(key: String?, value: Boolean) = put(key, value)
        override fun remove(key: String?) = put(key, null)
        override fun clear(): SharedPreferences.Editor = apply { clear = true }
        override fun commit(): Boolean { apply(); return commitSucceeds }
        override fun apply() { synchronized(values) {
            if (clear) values.clear()
            updates.forEach { (key, value) -> if (value == null) values.remove(key) else values[key] = value }
        } }
    }
}

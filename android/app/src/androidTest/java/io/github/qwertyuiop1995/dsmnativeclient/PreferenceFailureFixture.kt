package io.github.qwertyuiop1995.dsmnativeclient

import android.content.SharedPreferences
import java.io.Closeable
import java.io.IOException

/** 只在当前存储实例注入失败；不破坏真实文件，结束时恢复原实例。 */
internal class PreferenceFailureFixture(target: Any) : Closeable {
    private val field = target.javaClass.getDeclaredField("preferences").apply { isAccessible = true }
    private val targetStore = target
    private val original = field.get(target) as SharedPreferences
    @Volatile var failReads = false
    @Volatile var failCommits = false
    init {
        field.set(target, object : SharedPreferences by original {
            override fun getAll(): MutableMap<String, *> {
                if (failReads) throw IOException("Synthetic local storage unavailable")
                return original.all
            }
            override fun getString(key: String?, defValue: String?): String? {
                if (failReads) throw IOException("Synthetic local storage unavailable")
                return original.getString(key, defValue)
            }
            override fun edit(): SharedPreferences.Editor {
                val actual = original.edit()
                return object : SharedPreferences.Editor by actual {
                    override fun putString(key: String?, value: String?) = apply { actual.putString(key, value) }
                    override fun putStringSet(key: String?, values: MutableSet<String>?) = apply { actual.putStringSet(key, values) }
                    override fun putInt(key: String?, value: Int) = apply { actual.putInt(key, value) }
                    override fun putLong(key: String?, value: Long) = apply { actual.putLong(key, value) }
                    override fun putFloat(key: String?, value: Float) = apply { actual.putFloat(key, value) }
                    override fun putBoolean(key: String?, value: Boolean) = apply { actual.putBoolean(key, value) }
                    override fun remove(key: String?) = apply { actual.remove(key) }
                    override fun clear() = apply { actual.clear() }
                    override fun commit(): Boolean = if (failCommits) false else actual.commit()
                }
            }
        })
    }
    override fun close() { field.set(targetStore, original) }
}

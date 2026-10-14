package io.github.qwertyuiop1995.dsmnativeclient.chat

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatReminder
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

@Serializable internal data class ChatNoticeScope(val id: String = UUID.randomUUID().toString(), val owner: WorkspaceOwner, val version: Int = 1)
@Serializable internal data class ChatLocalReminder(val id: String = UUID.randomUUID().toString(), val scopeId: String,
    val conversation: String, val reminder: ChatReminder, val route: String, val delivered: Boolean = false, val version: Int = 1)

/** 通知正文不落盘；系统任务只携带随机记录编号。关闭先保存禁用，再取消系统请求。 */
internal class ChatNoticeStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_chat_notices",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    fun enabled() = synchronized(lock) { preferences.getBoolean("enabled", false) }
    fun setEnabled(value: Boolean) = synchronized(lock) { commit(preferences.edit().putBoolean("enabled", value)) }
    fun scopes(): List<ChatNoticeScope> = synchronized(lock) {
        preferences.all.keys.filter { it.startsWith("scope:") }.mapNotNull { key ->
            decode<ChatNoticeScope>(key)?.takeIf { it.version == 1 && key == "scope:${it.id}" && uuid(it.id) }
        }
    }
    fun scope(owner: WorkspaceOwner): ChatNoticeScope = synchronized(lock) {
        (scopes().singleOrNull { it.owner.hasSameIdentity(owner) }?.copy(owner = owner) ?: ChatNoticeScope(owner = owner)).also {
            commit(preferences.edit().putString("scope:${it.id}", json.encodeToString(it)))
        }
    }
    fun scope(id: String) = scopes().singleOrNull { it.id == id }
    fun reminders(scope: String? = null): List<ChatLocalReminder> = synchronized(lock) {
        preferences.all.keys.filter { it.startsWith("reminder:") }.mapNotNull { key ->
            decode<ChatLocalReminder>(key)?.takeIf { it.version == 1 && key == "reminder:${it.id}" && uuid(it.id) &&
                (scope == null || it.scopeId == scope) && it.reminder.remindAtEpochMillis > 0 && it.route.isOpaqueWorkspaceToken() }
        }
    }
    fun reminder(id: String) = reminders().singleOrNull { it.id == id }
    fun sync(scope: ChatNoticeScope, channel: String, values: List<ChatReminder>, route: String, now: Long) = synchronized(lock) {
        if (!enabled() || scope(scope.id) != scope || !route.isOpaqueWorkspaceToken()) throw workspaceChangedFailure()
        val prior = reminders(scope.id).filter { it.conversation == channel }
        val next = values.filter { value -> value.remindAtEpochMillis > now || prior.any { it.reminder == value && !it.delivered } }.distinctBy { it.id }.map { value ->
            prior.singleOrNull { it.reminder == value } ?: ChatLocalReminder(scopeId = scope.id, conversation = channel, reminder = value, route = route)
        }
        val edit = preferences.edit()
        prior.filter { old -> next.none { it.id == old.id } }.forEach { edit.remove("reminder:${it.id}") }
        next.forEach { edit.putString("reminder:${it.id}", json.encodeToString(it)) }
        commit(edit)
    }
    fun retainChannels(scope: ChatNoticeScope, channels: Set<String>) = synchronized(lock) {
        if (scope(scope.id) != scope) throw workspaceChangedFailure()
        val edit = preferences.edit()
        reminders(scope.id).filter { it.conversation !in channels }.forEach { edit.remove("reminder:${it.id}") }; commit(edit)
    }
    /** 写前领取，系统重试不重发已经消费的提醒；崩溃发生在保存后显示前可能遗漏一次。 */
    fun claim(row: ChatLocalReminder, now: Long): Boolean = synchronized(lock) {
        if (!enabled() || row.delivered || reminder(row.id) != row || row.reminder.remindAtEpochMillis > now) return@synchronized false
        commit(preferences.edit().putString("reminder:${row.id}", json.encodeToString(row.copy(delivered = true))))
        true
    }
    fun remove(scope: ChatNoticeScope) = synchronized(lock) {
        if (scope(scope.id) != scope) return@synchronized
        val edit = preferences.edit().remove("scope:${scope.id}")
        reminders(scope.id).forEach { edit.remove("reminder:${it.id}") }; commit(edit)
    }
    private inline fun <reified T> decode(key: String): T? = runCatching { json.decodeFromString<T>(preferences.getString(key, null) ?: return null) }.getOrNull()
    private fun commit(edit: SharedPreferences.Editor) { if (!edit.commit()) throw workspaceStorageFailure() }
    private fun uuid(value: String) = runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)
    companion object { internal val lock = Any() }
}

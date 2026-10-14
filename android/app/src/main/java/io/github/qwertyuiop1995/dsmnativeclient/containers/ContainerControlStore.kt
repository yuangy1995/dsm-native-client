package io.github.qwertyuiop1995.dsmnativeclient.containers

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerAction
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable internal data class ContainerControlItem(val id: String, val identity: String, val name: String,
    val startedAt: Long?, val stage: ContainerStage = ContainerStage.PREPARED) {
    val pending get() = stage in setOf(ContainerStage.PREPARED, ContainerStage.SUBMITTED, ContainerStage.ACCEPTED)
}
@Serializable internal data class ContainerControlActivity(val id: String, val owner: WorkspaceOwner, val action: ContainerAction,
    val items: List<ContainerControlItem>, val createdAt: Long = System.currentTimeMillis(), val version: Int = 1) {
    val pending get() = items.any { it.pending }
    override fun toString() = "ContainerControlActivity($action)"
}

/** 独立加密摘要，不保存容器名称、原始 ID、主机或日志正文。写前落盘失败不得发送。 */
internal class ContainerControlStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_container_controls",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }; private var failed = false
    fun records(owner: WorkspaceOwner) = synchronized(lock) { all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt } }
    fun begin(record: ContainerControlActivity) = synchronized(lock) {
        if (record.items.any { it.stage != ContainerStage.PREPARED } || all().any { it.id == record.id || it.owner.hasSameIdentity(record.owner) && it.pending }) containerConflict()
        write(record)
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, index: Int, stage: ContainerStage) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: storageFailure()
        val item = old.items.getOrNull(index) ?: storageFailure()
        val allowed = when (item.stage) {
            ContainerStage.PREPARED -> if (old.owner == owner) setOf(ContainerStage.SUBMITTED, ContainerStage.CANCELLED) else setOf(ContainerStage.CANCELLED)
            ContainerStage.SUBMITTED -> if (old.owner == owner) setOf(ContainerStage.ACCEPTED, ContainerStage.REJECTED, ContainerStage.VERIFIED) else setOf(ContainerStage.VERIFIED)
            ContainerStage.ACCEPTED -> setOf(ContainerStage.VERIFIED)
            else -> emptySet()
        }
        if (stage !in allowed) containerConflict()
        write(old.copy(items = old.items.mapIndexed { position, value -> if (position == index) value.copy(stage = stage) else value }))
    }
    fun dismiss(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        if (records(owner).singleOrNull { it.id == id }?.pending != false) containerConflict()
        if (!preferences.edit().remove(key(id)).commit()) storageFailure()
    }
    fun removeProfile(id: String) = synchronized(lock) {
        if (id in active) containerConflict()
        val editor = preferences.edit(); all().filter { it.owner.profileId == id }.forEach { editor.remove(key(it.id)) }
        if (!editor.commit()) storageFailure()
    }
    suspend fun <T> execute(owner: WorkspaceOwner, block: suspend () -> T): T {
        synchronized(lock) { if (!active.add(owner.profileId)) containerConflict() }
        try { return block() } finally { synchronized(lock) { active.remove(owner.profileId) } }
    }
    private fun all(): List<ContainerControlActivity> = try {
        if (failed) storageFailure()
        preferences.all.filterKeys { it.startsWith("control:") }.map { (key, raw) ->
            json.decodeFromString<ContainerControlActivity>(raw as? String ?: storageFailure()).also { validate(it); if (key != key(it.id)) storageFailure() }
        }
    } catch (_: Exception) { storageFailure() }
    private fun validate(record: ContainerControlActivity) {
        fun String.digest() = length == 64 && all { it in "0123456789abcdef" }
        if (record.version != 1 || record.id.isBlank() || record.createdAt < 0 || record.items.isEmpty() || record.items.any { !it.id.digest() || !it.identity.digest() || !it.name.digest() } ||
            record.items.map { it.id }.distinct().size != record.items.size || record.items.map { it.name }.distinct().size != record.items.size) storageFailure()
    }
    private fun write(record: ContainerControlActivity) { validate(record); if (!preferences.edit().putString(key(record.id), json.encodeToString(record)).commit()) storageFailure() }
    private fun key(id: String) = "control:$id"
    private fun storageFailure(): Nothing { failed = true; throw ContainerFailure(ContainerProblem.STORAGE) }
    companion object { private val lock = Any(); private val active = mutableSetOf<String>() }
}

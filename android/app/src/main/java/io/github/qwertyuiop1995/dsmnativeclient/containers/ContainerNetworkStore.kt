package io.github.qwertyuiop1995.dsmnativeclient.containers

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable internal enum class ContainerNetworkOperation { CREATE, DELETE }
@Serializable internal data class ContainerNetworkItem(val target: ContainerNetworkIdentity, val stage: ContainerStage = ContainerStage.PREPARED, val accepted: Boolean = false) {
    val pending get() = stage in setOf(ContainerStage.PREPARED, ContainerStage.SUBMITTED, ContainerStage.ACCEPTED)
}
@Serializable internal data class ContainerNetworkActivity(val id: String, val owner: WorkspaceOwner, val operation: ContainerNetworkOperation,
    val items: List<ContainerNetworkItem>, val createdAt: Long = System.currentTimeMillis(), val version: Int = 1) {
    val pending get() = items.any { it.pending }
    override fun toString() = "ContainerNetworkActivity($operation)"
}

/** 网络名称及地址只留在界面内存；恢复文件只有身份/配置摘要、接受事实和逐项阶段。 */
internal class ContainerNetworkStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_container_networks",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }; private var failed = false
    fun records(owner: WorkspaceOwner) = synchronized(lock) { all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt } }
    fun begin(record: ContainerNetworkActivity) = synchronized(lock) {
        if (record.items.any { it.stage != ContainerStage.PREPARED || it.accepted } || all().any { old -> old.id == record.id || old.owner.hasSameIdentity(record.owner) &&
            old.items.any { it.pending && record.items.any { new -> it.target.overlaps(new.target) } } }) containerConflict()
        write(record)
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, index: Int, stage: ContainerStage) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        val item = old.items.getOrNull(index) ?: failure()
        val allowed = when (item.stage) {
            ContainerStage.PREPARED -> if (old.owner == owner) setOf(ContainerStage.SUBMITTED, ContainerStage.CANCELLED) else setOf(ContainerStage.CANCELLED)
            ContainerStage.SUBMITTED -> if (old.owner == owner) setOf(ContainerStage.ACCEPTED, ContainerStage.REJECTED, ContainerStage.VERIFIED) else setOf(ContainerStage.VERIFIED)
            ContainerStage.ACCEPTED -> setOf(ContainerStage.VERIFIED)
            else -> emptySet()
        }
        if (stage !in allowed) containerConflict()
        write(old.copy(items = old.items.mapIndexed { position, value -> if (position == index) value.copy(stage = stage, accepted = value.accepted || stage == ContainerStage.ACCEPTED) else value }))
    }
    fun dismiss(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        if (records(owner).singleOrNull { it.id == id }?.pending != false) containerConflict()
        if (!preferences.edit().remove(key(id)).commit()) failure()
    }
    fun removeProfile(id: String) = synchronized(lock) {
        if (id in active) containerConflict()
        val editor = preferences.edit(); all().filter { it.owner.profileId == id }.forEach { editor.remove(key(it.id)) }
        if (!editor.commit()) failure()
    }
    suspend fun <T> execute(owner: WorkspaceOwner, block: suspend () -> T): T {
        synchronized(lock) { if (!active.add(owner.profileId)) containerConflict() }
        try { return block() } finally { synchronized(lock) { active.remove(owner.profileId) } }
    }
    private fun all(): List<ContainerNetworkActivity> = try {
        if (failed) failure()
        preferences.all.filterKeys { it.startsWith("network:") }.map { (key, raw) ->
            json.decodeFromString<ContainerNetworkActivity>(raw as? String ?: failure()).also { validate(it); if (key != key(it.id)) failure() }
        }
    } catch (_: Exception) { failure() }
    private fun validate(record: ContainerNetworkActivity) {
        fun String.digest() = length == 64 && all { it in "0123456789abcdef" }
        if (record.version != 1 || record.id.isBlank() || record.createdAt < 0 || record.items.isEmpty() ||
            record.items.map { it.target.name }.distinct().size != record.items.size || record.items.any {
                val target = it.target
                !target.name.digest() || !target.configuration.digest() || target.id?.digest() == false || target.ipv4?.digest() == false ||
                    record.operation == ContainerNetworkOperation.CREATE && (target.id != null || target.ipv6 == null || record.items.size != 1) ||
                    record.operation == ContainerNetworkOperation.DELETE && (target.id == null || target.ipv4 != null || target.ipv6 != null) ||
                    it.accepted && it.stage !in setOf(ContainerStage.ACCEPTED, ContainerStage.VERIFIED)
            }) failure()
    }
    private fun write(record: ContainerNetworkActivity) { validate(record); if (!preferences.edit().putString(key(record.id), json.encodeToString(record)).commit()) failure() }
    private fun key(id: String) = "network:$id"
    private fun failure(): Nothing { failed = true; throw ContainerFailure(ContainerProblem.STORAGE) }
    companion object { private val lock = Any(); private val active = mutableSetOf<String>() }
}

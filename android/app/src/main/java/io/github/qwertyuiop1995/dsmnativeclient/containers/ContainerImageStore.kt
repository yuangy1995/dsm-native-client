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

@Serializable internal enum class ContainerImageOperation { PULL, DELETE }
@Serializable internal data class ContainerImageActivity(val id: String, val owner: WorkspaceOwner, val operation: ContainerImageOperation,
    val stage: ContainerStage = ContainerStage.PREPARED, val reference: String? = null, val baselineIds: Set<String> = emptySet(),
    val task: ContainerImageTaskId? = null, val targets: List<ContainerImageIdentity> = emptyList(), val removed: Set<String> = emptySet(),
    val createdAt: Long = System.currentTimeMillis(), val version: Int = 1) {
    val pending get() = stage in setOf(ContainerStage.PREPARED, ContainerStage.SUBMITTED, ContainerStage.ACCEPTED)
    fun overlaps(other: ContainerImageActivity): Boolean = when {
        operation == ContainerImageOperation.PULL && other.operation == ContainerImageOperation.PULL -> reference == other.reference
        operation == ContainerImageOperation.DELETE && other.operation == ContainerImageOperation.DELETE -> targets.any { a -> other.targets.any(a::overlaps) }
        operation == ContainerImageOperation.PULL -> other.targets.any { it.reference == reference || it.untagged && it.image in baselineIds }
        else -> other.overlaps(this)
    }
    override fun toString() = "ContainerImageActivity($operation, $stage)"
}

/** 映像下载和删除共用持久互斥，原任务编号保留原类型；记录不含仓库、标签或原映像 ID。 */
internal class ContainerImageStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_container_images",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }; private var failed = false
    fun records(owner: WorkspaceOwner) = synchronized(lock) { all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt } }
    fun begin(record: ContainerImageActivity) = synchronized(lock) {
        if (record.stage != ContainerStage.PREPARED || record.task != null || record.removed.isNotEmpty() || all().any {
            it.id == record.id || it.owner.hasSameIdentity(record.owner) && it.pending && it.overlaps(record)
        }) containerConflict()
        write(record)
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, stage: ContainerStage, task: ContainerImageTaskId? = null) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        val allowed = when (old.stage) {
            ContainerStage.PREPARED -> if (old.owner == owner) setOf(ContainerStage.SUBMITTED, ContainerStage.CANCELLED) else setOf(ContainerStage.CANCELLED)
            ContainerStage.SUBMITTED -> if (old.owner == owner) setOf(ContainerStage.ACCEPTED, ContainerStage.REJECTED) else emptySet()
            ContainerStage.ACCEPTED -> if (old.operation == ContainerImageOperation.PULL && old.task != null) setOf(ContainerStage.VERIFIED, ContainerStage.REJECTED) else emptySet()
            else -> emptySet()
        }
        if (stage !in allowed || task != null && (stage != ContainerStage.ACCEPTED || old.operation != ContainerImageOperation.PULL)) containerConflict()
        write(old.copy(stage = stage, task = task ?: old.task))
    }
    fun reviewDelete(owner: WorkspaceOwner, id: String, removed: Set<String>) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        if (old.operation != ContainerImageOperation.DELETE || old.stage !in setOf(ContainerStage.SUBMITTED, ContainerStage.ACCEPTED) ||
            removed.any { value -> old.targets.none { it.selection == value } }) containerConflict()
        val combined = old.removed + removed
        write(old.copy(removed = combined, stage = if (combined.size == old.targets.size) ContainerStage.VERIFIED else old.stage))
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
    private fun all(): List<ContainerImageActivity> = try {
        if (failed) failure()
        preferences.all.filterKeys { it.startsWith("image:") }.map { (key, raw) ->
            json.decodeFromString<ContainerImageActivity>(raw as? String ?: failure()).also { validate(it); if (key != key(it.id)) failure() }
        }
    } catch (_: Exception) { failure() }
    private fun validate(record: ContainerImageActivity) {
        fun String.digest() = length == 64 && all { it in "0123456789abcdef" }
        if (record.version != 1 || record.id.isBlank() || record.createdAt < 0) failure()
        if (record.operation == ContainerImageOperation.PULL) {
            if (record.reference?.digest() != true || record.baselineIds.any { !it.digest() } || record.targets.isNotEmpty() || record.removed.isNotEmpty() || record.task?.valid == false ||
                record.stage == ContainerStage.VERIFIED && record.task == null) failure()
        } else if (record.reference != null || record.task != null || record.baselineIds.isNotEmpty() || record.targets.isEmpty() ||
            record.targets.any { !it.selection.digest() || !it.image.digest() || !it.reference.digest() } ||
            record.targets.map { it.selection }.distinct().size != record.targets.size || record.removed.any { removed -> record.targets.none { it.selection == removed } } ||
            record.stage == ContainerStage.VERIFIED && record.removed.size != record.targets.size) failure()
    }
    private fun write(record: ContainerImageActivity) { validate(record); if (!preferences.edit().putString(key(record.id), json.encodeToString(record)).commit()) failure() }
    private fun key(id: String) = "image:$id"
    private fun failure(): Nothing { failed = true; throw ContainerFailure(ContainerProblem.STORAGE) }
    companion object { private val lock = Any(); private val active = mutableSetOf<String>() }
}

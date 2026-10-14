package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private val VmmStage.taskPending get() = this in setOf(VmmStage.PREPARED, VmmStage.SUBMITTED, VmmStage.ACCEPTED)
@Serializable internal data class VmmImportActivity(val id: String, val owner: WorkspaceOwner, val snapshot: VmmImportSnapshot,
    val progress: VmmImportProgress = VmmImportProgress(), val createdAt: Long = System.currentTimeMillis(), val version: Int = 1) {
    val pending get() = progress.stage.taskPending
    override fun toString() = "VmmImportActivity(${progress.stage})"
}
@Serializable internal data class VmmTaskClearItem(val id: String, val identity: String, val stage: VmmStage = VmmStage.PREPARED) {
    val pending get() = stage.taskPending
}
@Serializable internal data class VmmTaskClearActivity(val id: String, val owner: WorkspaceOwner, val items: List<VmmTaskClearItem>,
    val createdAt: Long = System.currentTimeMillis(), val version: Int = 1) {
    val pending get() = items.any { it.pending }
    override fun toString() = "VmmTaskClearActivity(count=${items.size})"
}

/** 名称、源路径、存储与响应均不落盘；仅原导入任务保留恢复必需的标识，文件独立加密。 */
internal class VmmTaskStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_vmm_tasks",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }; private var failed = false
    fun imports(owner: WorkspaceOwner) = synchronized(lock) { imports().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt } }
    fun cleanups(owner: WorkspaceOwner) = synchronized(lock) { cleanups().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt } }
    fun begin(record: VmmImportActivity) = synchronized(lock) {
        if (record.progress != VmmImportProgress() || imports().any { it.id == record.id || it.owner.hasSameIdentity(record.owner) && it.pending && it.snapshot.nameKey == record.snapshot.nameKey }) vmmConflict()
        write(record)
    }
    fun begin(record: VmmTaskClearActivity) = synchronized(lock) {
        if (record.items.any { it.stage != VmmStage.PREPARED } || cleanups().any { old -> old.id == record.id || old.owner.hasSameIdentity(record.owner) && old.items.any { it.pending && record.items.any { item -> item.id == it.id } } }) vmmConflict()
        write(record)
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, progress: VmmImportProgress) = synchronized(lock) {
        val old = imports(owner).singleOrNull { it.id == id } ?: storageFailure()
        val previous = old.progress
        if (progress.stage !in allowed(previous.stage, old.owner == owner, import = true) ||
            previous.task != null && previous.task != progress.task || previous.image != null && previous.image != progress.image) vmmConflict()
        write(old.copy(progress = progress))
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, index: Int, stage: VmmStage) = synchronized(lock) {
        val old = cleanups(owner).singleOrNull { it.id == id } ?: storageFailure()
        val item = old.items.getOrNull(index) ?: storageFailure()
        if (stage !in allowed(item.stage, old.owner == owner, import = false)) vmmConflict()
        write(old.copy(items = old.items.mapIndexed { i, value -> if (i == index) value.copy(stage = stage) else value }))
    }
    private fun allowed(stage: VmmStage, sameSession: Boolean, import: Boolean): Set<VmmStage> = when (stage) {
        VmmStage.PREPARED -> if (sameSession) setOf(VmmStage.SUBMITTED, VmmStage.CANCELLED) else setOf(VmmStage.CANCELLED)
        VmmStage.SUBMITTED -> if (sameSession) setOf(VmmStage.ACCEPTED, VmmStage.REJECTED) else emptySet()
        VmmStage.ACCEPTED -> if (import) setOf(VmmStage.ACCEPTED, VmmStage.VERIFIED) else setOf(VmmStage.VERIFIED)
        else -> emptySet()
    }
    fun dismissImport(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        if (imports(owner).singleOrNull { it.id == id }?.pending != false) vmmConflict()
        remove("import:$id")
    }
    fun dismissCleanup(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        if (cleanups(owner).singleOrNull { it.id == id }?.pending != false) vmmConflict()
        remove("clear:$id")
    }
    fun removeProfile(id: String) = synchronized(lock) {
        VmmExecutionGate.requireIdle(id)
        val editor = preferences.edit()
        imports().filter { it.owner.profileId == id }.forEach { editor.remove("import:${it.id}") }
        cleanups().filter { it.owner.profileId == id }.forEach { editor.remove("clear:${it.id}") }
        if (!editor.commit()) storageFailure()
    }
    suspend fun <T> execute(owner: WorkspaceOwner, wait: Boolean = false, block: suspend () -> T): T = VmmExecutionGate.execute(owner, wait, block)
    private fun imports(): List<VmmImportActivity> = read("import:") { raw -> json.decodeFromString<VmmImportActivity>(raw).also(::validate).let { it.id to it } }
    private fun cleanups(): List<VmmTaskClearActivity> = read("clear:") { raw -> json.decodeFromString<VmmTaskClearActivity>(raw).also(::validate).let { it.id to it } }
    private fun <T> read(prefix: String, decode: (String) -> Pair<String, T>): List<T> = try {
        if (failed) storageFailure()
        preferences.all.filterKeys { it.startsWith(prefix) }.map { (key, raw) ->
            val (id, value) = decode(raw as? String ?: storageFailure()); if (key != "$prefix$id") storageFailure(); value
        }
    } catch (_: Exception) { storageFailure() }
    private fun digest(value: String) = value.length == 64 && value.all { it in "0123456789abcdef" }
    private fun common(id: String, createdAt: Long, version: Int) {
        if (version != 1 || createdAt < 0 || runCatching { UUID.fromString(id) }.isFailure) storageFailure()
    }
    private fun validate(record: VmmImportActivity) {
        common(record.id, record.createdAt, record.version)
        val snapshot = record.snapshot; val progress = record.progress
        if (!digest(snapshot.name) || !digest(snapshot.nameKey) || snapshot.type !in setOf("disk", "iso", "vdsm") || snapshot.existingImages.any { !digest(it) } ||
            progress.task?.let { !validVmmId(it) } == true || progress.image?.let { !digest(it) || it in snapshot.existingImages } == true ||
            (progress.stage in setOf(VmmStage.ACCEPTED, VmmStage.VERIFIED)) != (progress.task != null) ||
            progress.image != null && progress.stage !in setOf(VmmStage.ACCEPTED, VmmStage.VERIFIED) || progress.stage == VmmStage.VERIFIED && progress.image == null) storageFailure()
    }
    private fun validate(record: VmmTaskClearActivity) {
        common(record.id, record.createdAt, record.version)
        if (record.items.isEmpty() || record.items.size > 100 || record.items.map { it.id }.distinct().size != record.items.size ||
            record.items.any { !digest(it.id) || !digest(it.identity) }) storageFailure()
    }
    private fun write(record: VmmImportActivity) { validate(record); save("import:${record.id}", json.encodeToString(record)) }
    private fun write(record: VmmTaskClearActivity) { validate(record); save("clear:${record.id}", json.encodeToString(record)) }
    private fun save(key: String, value: String) { if (!preferences.edit().putString(key, value).commit()) storageFailure() }
    private fun remove(key: String) { if (!preferences.edit().remove(key).commit()) storageFailure() }
    private fun storageFailure(): Nothing { failed = true; throw VmmFailure(VmmProblem.STORAGE) }
    companion object { private val lock = Any() }
}

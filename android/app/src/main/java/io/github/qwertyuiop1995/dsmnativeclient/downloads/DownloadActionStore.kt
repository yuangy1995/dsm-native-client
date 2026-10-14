package io.github.qwertyuiop1995.dsmnativeclient.downloads

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.data.downloads.downloadCreationKey
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
internal enum class DownloadActionKind { CREATE_LINK, CREATE_FILE, PAUSE, RESUME, REMOVE, END_AND_MOVE, EDIT, SETTINGS, SCHEDULE, RSS }
@Serializable
internal enum class DownloadActionPhase { READY, SUBMITTED, COMPLETED, REJECTED, CANCELLED }

/** 名称、链接、文件内容及密码不进入恢复记录；目录与设置值仅在本机加密保存。 */
@Serializable
internal data class DownloadActionStep(
    val kind: DownloadActionKind,
    val target: String,
    val identityDigest: String,
    val original: Map<String, String> = emptyMap(),
    val desired: Map<String, String> = emptyMap(),
    val phase: DownloadActionPhase = DownloadActionPhase.READY,
    val accepted: Boolean = false,
    val error: String? = null,
) {
    val terminal get() = phase in setOf(DownloadActionPhase.COMPLETED, DownloadActionPhase.REJECTED, DownloadActionPhase.CANCELLED)
    override fun toString() = "DownloadActionStep($kind, $phase)"
}

@Serializable
internal data class DownloadActionRecord(
    val id: String,
    val owner: WorkspaceOwner,
    val steps: List<DownloadActionStep>,
    val createdAt: Long = System.currentTimeMillis(),
    val version: Int = 1,
) {
    val terminal get() = steps.all { it.terminal }
    override fun toString() = "DownloadActionRecord(${steps.size}, $terminal)"
}

/** 单一下载恢复账本：原子提交失败不放行写入，损坏记录不被覆盖或清空。 */
internal class DownloadActionStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_download_actions",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }
    private var writeFailed = false
    fun records(owner: WorkspaceOwner): List<DownloadActionRecord> = synchronized(lock) {
        all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt }
    }
    fun get(owner: WorkspaceOwner, id: String): DownloadActionRecord = synchronized(lock) {
        all().singleOrNull { it.owner.hasSameIdentity(owner) && it.id == id } ?: storageFailure()
    }
    fun begin(record: DownloadActionRecord) = synchronized(lock) {
        validate(record)
        if (record.steps.any { it.phase != DownloadActionPhase.READY } || all().any { it.id == record.id }) storageFailure()
        if (all().any { old -> old.owner.hasSameIdentity(record.owner) && old.steps.any { a ->
            !a.terminal && record.steps.any { b -> downloadStepsConflict(a, b) } } }) throw DsmFailure(
                null, "This download change is still updating", "Open its activity and refresh the status.", kind = DsmErrorKind.WORKSPACE_BUSY)
        write(record)
    }
    fun save(owner: WorkspaceOwner, id: String, index: Int, next: DownloadActionStep) = synchronized(lock) {
        val record = get(owner, id)
        val old = record.steps.getOrNull(index) ?: storageFailure()
        if (old.copy(phase = next.phase, accepted = next.accepted, error = next.error) != next ||
            old.terminal && old != next || old.accepted && !next.accepted ||
            old.phase == DownloadActionPhase.SUBMITTED && next.phase in setOf(DownloadActionPhase.READY, DownloadActionPhase.CANCELLED) ||
            old.phase == DownloadActionPhase.READY && next.phase == DownloadActionPhase.COMPLETED) storageFailure()
        write(record.copy(steps = record.steps.toMutableList().also { it[index] = next }))
    }
    fun discard(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        val record = get(owner, id)
        if (!record.terminal || id in active) storageFailure()
        if (!preferences.edit().remove(key(id)).commit()) storageFailure()
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val matches = all().filter { it.owner.profileId == profileId }
        if (matches.any { it.id in active }) storageFailure()
        val editor = preferences.edit(); matches.forEach { editor.remove(key(it.id)) }
        if (!editor.commit()) storageFailure()
    }
    suspend fun <T> execute(id: String, block: suspend () -> T): T {
        synchronized(lock) { if (!active.add(id)) storageFailure() }
        try { return block() } finally { synchronized(lock) { active.remove(id) } }
    }
    private fun all(): List<DownloadActionRecord> = try {
        if (writeFailed) storageFailure()
        preferences.all.filterKeys { it.startsWith("download:") }.map { (key, value) ->
            val record = json.decodeFromString<DownloadActionRecord>(value as? String ?: storageFailure())
            validate(record); if (key != key(record.id)) storageFailure(); record
        }
    } catch (_: Exception) { storageFailure() }
    private fun validate(record: DownloadActionRecord) {
        if (record.version != 1 || record.id.isBlank() || record.steps.isEmpty() || record.createdAt < 0 || record.steps.any { step ->
            step.target.isBlank() || step.identityDigest.length != 64 || step.identityDigest.any { it !in "0123456789abcdef" } ||
                step.accepted && step.phase in setOf(DownloadActionPhase.READY, DownloadActionPhase.CANCELLED) ||
                (step.original.keys + step.desired.keys).any { it !in allowedFields(step.kind) }
        }) storageFailure()
    }
    private fun write(record: DownloadActionRecord) {
        validate(record)
        if (!preferences.edit().putString(key(record.id), json.encodeToString(record)).commit()) { writeFailed = true; storageFailure() }
    }
    private fun key(id: String) = "download:$id"
    private fun storageFailure(): Nothing = throw DsmFailure(null, "Download activity could not be saved on this device",
        "Free up space and try again.", kind = DsmErrorKind.LOCAL_STORAGE_FAILED)
    companion object { private val lock = Any(); private val active = mutableSetOf<String>() }
}

private fun allowedFields(kind: DownloadActionKind): Set<String> = when (kind) {
    DownloadActionKind.CREATE_LINK, DownloadActionKind.CREATE_FILE -> setOf("request_digest")
    DownloadActionKind.SETTINGS -> DOWNLOAD_BASIC_SETTING_FIELDS
    DownloadActionKind.SCHEDULE -> DOWNLOAD_SCHEDULE_SETTING_FIELDS
    DownloadActionKind.RSS -> setOf("updated_at")
    else -> setOf("status", "destination")
}
internal fun downloadStepsConflict(a: DownloadActionStep, b: DownloadActionStep): Boolean {
    val creations = setOf(DownloadActionKind.CREATE_LINK, DownloadActionKind.CREATE_FILE)
    val settings = setOf(DownloadActionKind.SETTINGS, DownloadActionKind.SCHEDULE)
    return when {
        a.kind in creations || b.kind in creations -> a.kind in creations && b.kind in creations && a.target == b.target
        a.kind in settings || b.kind in settings -> a.kind == b.kind
        a.kind == DownloadActionKind.RSS || b.kind == DownloadActionKind.RSS -> a.kind == b.kind && a.target == b.target
        else -> a.target == b.target
    }
}
internal fun downloadTaskDigest(task: DownloadTask): String = downloadCreationKey("task", task.id, task.type.orEmpty(),
    task.title, task.size?.toString().orEmpty(), task.createdAtEpochSeconds?.toString().orEmpty())
internal fun downloadRssDigest(site: DownloadRssSite): String = site.identityDigest

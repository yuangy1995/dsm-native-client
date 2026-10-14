package io.github.qwertyuiop1995.dsmnativeclient.nas

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*

/** 脚本、名称、执行用户、通知和输出均不落盘；创建只保留已有数字ID与字段摘要。 */
@Serializable internal data class NasTaskRecord(
    val id: String, val owner: WorkspaceOwner, val action: NasTaskAction, val taskId: Long?,
    val selectorDigest: String, val targetDigest: String, val fieldsDigest: String, val existingIds: List<Long>,
    val stage: NasTaskStage = NasTaskStage.SUBMITTED, val accepted: Boolean = false,
    val createdAt: Long = System.currentTimeMillis(), val version: Int = 1,
) {
    val terminal get() = stage in setOf(NasTaskStage.COMPLETED, NasTaskStage.REJECTED)
    val needsAcknowledgement get() = action in setOf(NasTaskAction.CREATE, NasTaskAction.RUN)
    override fun toString() = "NasTaskRecord($action, $stage)"
}
internal class NasTaskActivityStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_scheduled_task_activity",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }
    private var failed = false
    fun records(owner: WorkspaceOwner) = synchronized(lock) { all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt } }
    fun begin(record: NasTaskRecord) = synchronized(lock) {
        if (all().any { it.id == record.id || it.owner.hasSameIdentity(record.owner) && !it.terminal }) busy()
        if (record.stage != NasTaskStage.SUBMITTED || record.accepted) failure()
        write(record)
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, stage: NasTaskStage) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        if (old.terminal || stage == NasTaskStage.SUBMITTED || stage == NasTaskStage.ACCEPTED && old.accepted ||
            stage == NasTaskStage.REJECTED && old.accepted || stage == NasTaskStage.COMPLETED && old.needsAcknowledgement && !old.accepted) failure()
        write(old.copy(stage = stage, accepted = old.accepted || stage == NasTaskStage.ACCEPTED))
    }
    fun discard(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        if (records(owner).singleOrNull { it.id == id }?.terminal != true) failure()
        if (!preferences.edit().remove(key(id)).commit()) failure()
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        if (profileId in active) busy()
        val editor = preferences.edit(); all().filter { it.owner.profileId == profileId }.forEach { editor.remove(key(it.id)) }
        if (!editor.commit()) failure()
    }
    suspend fun <T> execute(owner: WorkspaceOwner, block: suspend () -> T): T {
        synchronized(lock) { if (!active.add(owner.profileId)) busy() }
        try { return block() } finally { synchronized(lock) { active.remove(owner.profileId) } }
    }
    private fun all(): List<NasTaskRecord> = try {
        if (failed) failure()
        preferences.all.filterKeys { it.startsWith("scheduled:") }.map { (key, raw) ->
            val record = json.decodeFromString<NasTaskRecord>(raw as? String ?: failure())
            validate(record); if (key != key(record.id)) failure(); record
        }
    } catch (_: Exception) { failure() }
    private fun validate(record: NasTaskRecord) {
        if (record.id.isBlank() || record.version != 1 || record.createdAt < 0 ||
            (record.taskId == null) != (record.action == NasTaskAction.CREATE) || record.taskId?.let { it < 0 } == true ||
            record.existingIds.size >= 1000 || record.existingIds.any { it < 0 } || record.existingIds.distinct().size != record.existingIds.size ||
            record.action != NasTaskAction.CREATE && record.existingIds.isNotEmpty() ||
            listOf(record.selectorDigest, record.targetDigest, record.fieldsDigest).any { it.length != 64 || it.any { char -> char !in "0123456789abcdef" } } ||
            record.stage == NasTaskStage.ACCEPTED && !record.accepted || record.stage == NasTaskStage.REJECTED && record.accepted ||
            record.stage == NasTaskStage.COMPLETED && record.needsAcknowledgement && !record.accepted) failure()
    }
    private fun write(record: NasTaskRecord) {
        validate(record)
        if (!preferences.edit().putString(key(record.id), json.encodeToString(record)).commit()) { failed = true; failure() }
    }
    private fun key(id: String) = "scheduled:$id"
    private fun failure(): Nothing = throw DsmFailure(null, "Task activity could not be saved", "Free up space and try again.", kind = DsmErrorKind.LOCAL_STORAGE_FAILED)
    private fun busy(): Nothing = throw NasTaskFailure(NasTaskProblem.BUSY)
    companion object { private val lock = Any(); private val active = mutableSetOf<String>() }
}
internal fun taskCreationTarget(name: String, owner: String?) = packageDigest(JsonArray(listOf(JsonPrimitive(name.trim()), owner?.let { JsonPrimitive(it.trim()) } ?: JsonNull)).toString())
internal fun taskRealOwnerDigest(value: String?) = packageDigest(value?.let(::JsonPrimitive)?.toString() ?: "null")
internal fun taskRecord(id: String, owner: WorkspaceOwner, change: NasTaskChange, existingIds: List<Long>): NasTaskRecord {
    val desired = if (change.action == NasTaskAction.ENABLE) change.original?.copy(enabled = true) else change.desired
    return NasTaskRecord(id, owner, change.action, change.task?.id, taskRealOwnerDigest(change.task?.realOwner),
        change.task?.let { packageDigest(taskTargetFields(it).toString()) } ?: taskCreationTarget(desired!!.name, desired.owner),
        packageDigest(desired?.let { taskSavedFields(it).toString() }.orEmpty()), existingIds)
}

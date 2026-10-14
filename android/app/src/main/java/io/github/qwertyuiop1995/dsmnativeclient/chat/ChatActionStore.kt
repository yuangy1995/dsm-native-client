package io.github.qwertyuiop1995.dsmnativeclient.chat

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
internal data class ChatActionRecord(val version: Int = 1, val owner: WorkspaceOwner,
    val checkpoint: ChatActionCheckpoint, val createdAtMillis: Long = System.currentTimeMillis()) {
    override fun toString() = "ChatActionRecord(${checkpoint.kind}, ${checkpoint.phase})"
}

/** 独立加密恢复，不改既有登录/消息缓存；跨实例锁防止同一账号重复开始原目标。 */
internal class ChatActionStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_chat_actions",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }

    fun records(owner: WorkspaceOwner): List<ChatActionRecord> = synchronized(lock) {
        all().filter { it.owner.hasSameIdentity(owner) }.sortedBy { it.createdAtMillis }
    }
    fun get(owner: WorkspaceOwner, id: String): ChatActionRecord = synchronized(lock) {
        all().singleOrNull { it.owner.hasSameIdentity(owner) && it.checkpoint.id == id } ?: storageFailure()
    }
    fun begin(record: ChatActionRecord) = synchronized(lock) {
        validate(record)
        if (record.checkpoint.phase != ChatActionPhase.READY || all().any { it.checkpoint.id == record.checkpoint.id }) storageFailure()
        requireNoConflict(record)
        write(record)
    }
    fun requireNoConflict(record: ChatActionRecord) = synchronized(lock) {
        if (all().any { it.owner.hasSameIdentity(record.owner) && chatActionsConflict(it.checkpoint, record.checkpoint) })
            throw DsmFailure(null, "This chat action is still updating", "Refresh its status.", kind = DsmErrorKind.WORKSPACE_BUSY)
    }
    fun save(owner: WorkspaceOwner, next: ChatActionCheckpoint) = synchronized(lock) {
        val old = all().singleOrNull { it.owner.hasSameIdentity(owner) && it.checkpoint.id == next.id } ?: storageFailure()
        val before = old.checkpoint
        if (!before.sameOperation(next) || before.finished && before != next || before.submitted && !next.submitted ||
            before.remoteId != null && before.remoteId != next.remoteId || before.acknowledged && !next.acknowledged ||
            before.submittedAtMillis != null && before.submittedAtMillis != next.submittedAtMillis ||
            !before.submitted && next.phase !in setOf(ChatActionPhase.READY, ChatActionPhase.SUBMITTED, ChatActionPhase.REJECTED) &&
                !(next.kind == ChatActionKind.DIRECT && next.phase == ChatActionPhase.COMPLETED && next.remoteId != null) ||
            before.group?.let { old -> next.group?.let { fresh ->
                !groupStepAdvances(old.join, fresh.join) || !groupStepAdvances(old.invite, fresh.invite) } != false } == true ||
            before.forwardTargets.zip(next.forwardTargets).any { (old, fresh) -> old.confirmedId != null && old.confirmedId != fresh.confirmedId }) storageFailure()
        write(old.copy(checkpoint = next))
    }
    fun discard(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        val old = all().singleOrNull { it.owner.hasSameIdentity(owner) && it.checkpoint.id == id } ?: storageFailure()
        if (id in active || old.checkpoint.phase == ChatActionPhase.SUBMITTED) storageFailure()
        if (!preferences.edit().remove(key(id)).commit()) storageFailure()
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val records = all().filter { it.owner.profileId == profileId }
        if (records.any { it.checkpoint.id in active }) storageFailure()
        val editor = preferences.edit()
        records.forEach { editor.remove(key(it.checkpoint.id)) }
        if (!editor.commit()) storageFailure()
    }
    suspend fun <T> execute(id: String, block: suspend () -> T): T {
        synchronized(lock) { if (!active.add(id)) storageFailure() }
        try { return block() } finally { synchronized(lock) { active.remove(id) } }
    }
    private fun all(): List<ChatActionRecord> = try {
        preferences.all.filterKeys { it.startsWith("action:") }.map { (key, value) ->
            val record = json.decodeFromString<ChatActionRecord>(value as? String ?: storageFailure())
            validate(record)
            if (key != key(record.checkpoint.id)) storageFailure()
            record
        }
    } catch (_: Exception) { storageFailure() }
    private fun validate(record: ChatActionRecord) {
        val c = record.checkpoint
        if (record.version != 1 || c.id.isBlank() || c.channelId.isBlank() || c.currentUserId.isBlank() ||
            c.choiceIds.distinct().size != c.choiceIds.size || c.choiceIds.any(String::isBlank) ||
            c.phase == ChatActionPhase.SUBMITTED && c.submittedAtMillis == null ||
            listOfNotNull(c.baselineDigest, c.desiredDigest, c.attachmentNameDigest).any { it.length != 64 || it.any { ch -> ch !in "0123456789abcdef" } }) storageFailure()
    }
    private fun write(record: ChatActionRecord) {
        validate(record)
        if (!preferences.edit().putString(key(record.checkpoint.id), json.encodeToString(record)).commit()) storageFailure()
    }
    private fun key(id: String) = "action:$id"
    private fun storageFailure(): Nothing = throw DsmFailure(null, "Chat changes could not be saved on this device", "Free up space and try again.", kind = DsmErrorKind.LOCAL_STORAGE_FAILED)
    companion object { private val lock = Any(); private val active = mutableSetOf<String>() }
}

internal fun chatActionsConflict(a: ChatActionCheckpoint, b: ChatActionCheckpoint): Boolean {
    if (a.finished || a.id == b.id) return false
    val aChannels = setOfNotNull(a.channelId, a.remoteId.takeIf { a.kind in setOf(ChatActionKind.DIRECT, ChatActionKind.GROUP) }) + a.forwardTargets.map { it.channelId }
    val bChannels = setOfNotNull(b.channelId, b.remoteId.takeIf { b.kind in setOf(ChatActionKind.DIRECT, ChatActionKind.GROUP) }) + b.forwardTargets.map { it.channelId }
    if (aChannels.intersect(bChannels).isEmpty()) return false
    if (a.kind == ChatActionKind.CLOSE || b.kind == ChatActionKind.CLOSE) return true
    if (a.messageId != null && b.messageId != null) return a.messageId == b.messageId
    return a.kind == b.kind && a.desiredDigest == b.desiredDigest && a.atMillis == b.atMillis
}

private fun groupStepAdvances(before: ChatGroupStep, after: ChatGroupStep): Boolean = when (before) {
    ChatGroupStep.READY -> true
    ChatGroupStep.SUBMITTED -> after != ChatGroupStep.READY
    ChatGroupStep.COMPLETED -> after == ChatGroupStep.COMPLETED
    ChatGroupStep.REJECTED -> after != ChatGroupStep.READY
}

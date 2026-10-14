package io.github.qwertyuiop1995.dsmnativeclient.chat

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.File
import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
internal data class ChatSavedAttachment(val fileId: String, val name: String, val mime: String?, val size: Long)

/** 草稿单独加密保存，动作检查点继续只保留最小身份和摘要。 */
@Serializable
internal data class ChatSavedDraft(val owner: WorkspaceOwner, val id: String, val kind: ChatActionKind,
    val channelId: String, val original: ChatMessage? = null, val conversation: ChatConversation? = null,
    val text: String = "", val choiceIds: Set<String> = emptySet(), val options: List<String> = emptyList(),
    val multiple: Boolean = false, val anonymous: Boolean = false, val atMillis: Long? = null,
    val reminder: ChatReminder? = null, val schedule: ChatScheduledMessage? = null,
    val attachment: ChatSavedAttachment? = null, val memberIds: List<String> = emptyList(), val targetIds: List<String> = emptyList(),
    val version: Int = 1) {
    override fun toString() = "ChatSavedDraft(kind=$kind)"
}

@Serializable
private data class ChatComposerRecord(val owner: WorkspaceOwner, val channel: String, val text: String, val version: Int = 1)

@Serializable
internal data class ChatBatchRecord(val owner: WorkspaceOwner, val id: String, val kind: ChatActionKind,
    val actionIds: List<String>, val version: Int = 1)

internal class ChatDraftStore(private val preferences: SharedPreferences, private val directory: File) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_chat_drafts",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM), File(context.filesDir, "chat_drafts"))
    private val json = Json { encodeDefaults = true }

    fun batches(owner: WorkspaceOwner): List<ChatBatchRecord> = synchronized(lock) {
        preferences.all.filterKeys { it.startsWith("batch:") }.map { (key, value) ->
            val record = try { json.decodeFromString<ChatBatchRecord>(value as? String ?: storageFailure()) } catch (_: Exception) { storageFailure() }
            if (record.version != 1 || key != "batch:${record.id}" || record.actionIds.isEmpty() || record.actionIds.distinct() != record.actionIds) storageFailure()
            record
        }.filter { it.owner.hasSameIdentity(owner) }
    }
    fun saveBatch(batch: ChatBatchRecord) = synchronized(lock) {
        if (preferences.contains("batch:${batch.id}") || !preferences.edit().putString("batch:${batch.id}", json.encodeToString(batch)).commit()) storageFailure()
    }
    fun removeBatch(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        if (batches(owner).none { it.id == id }) storageFailure()
        if (!preferences.edit().remove("batch:$id").commit()) storageFailure()
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val editor = preferences.edit()
        val files = mutableListOf<File>()
        preferences.all.forEach { (key, value) ->
            try {
                val text = value as? String ?: storageFailure()
                when {
                    key.startsWith("action:") -> json.decodeFromString<ChatSavedDraft>(text).takeIf { it.owner.profileId == profileId }?.let {
                        editor.remove(key); it.attachment?.let { attachment -> files += file(attachment) }
                    }
                    key.startsWith("composer:") -> if (json.decodeFromString<ChatComposerRecord>(text).owner.profileId == profileId) editor.remove(key)
                    key.startsWith("batch:") -> if (json.decodeFromString<ChatBatchRecord>(text).owner.profileId == profileId) editor.remove(key)
                }
            } catch (_: Exception) { storageFailure() }
        }
        if (!editor.commit()) storageFailure()
        files.forEach(File::delete)
    }

    fun actions(owner: WorkspaceOwner): List<ChatSavedDraft> = synchronized(lock) {
        preferences.all.filterKeys { it.startsWith("action:") }.map { (key, value) ->
            val record = try { json.decodeFromString<ChatSavedDraft>(value as? String ?: storageFailure()) } catch (_: Exception) { storageFailure() }
            if (record.version != 1 || key != "action:${record.id}") storageFailure()
            record
        }.filter { it.owner.hasSameIdentity(owner) }
    }

    suspend fun saveAction(owner: WorkspaceOwner, id: String, draft: ChatActionDraft): ChatSavedDraft {
        val attachment = draft.attachment?.let { copyAttachment(it) }
        val saved = ChatSavedDraft(owner, id, draft.kind, draft.channelId, draft.original, draft.conversation, draft.text,
            draft.choiceIds, draft.options, draft.multiple, draft.anonymous, draft.atMillis, draft.reminder, draft.schedule,
            attachment, draft.memberIds, draft.targetIds)
        try { synchronized(lock) {
            if (preferences.contains("action:$id") || !preferences.edit().putString("action:$id", json.encodeToString(saved)).commit()) storageFailure()
        } } catch (error: Exception) { attachment?.let { file(it).delete() }; throw error }
        return saved
    }
    fun action(owner: WorkspaceOwner, id: String): ChatSavedDraft? = synchronized(lock) {
        preferences.getString("action:$id", null)?.let { value ->
            val record = try { json.decodeFromString<ChatSavedDraft>(value) } catch (_: Exception) { storageFailure() }
            if (record.version != 1 || record.id != id) storageFailure()
            record.takeIf { it.owner.hasSameIdentity(owner) }
        }
    }
    fun draft(saved: ChatSavedDraft): ChatActionDraft = ChatActionDraft(saved.kind, saved.channelId, saved.original, saved.conversation,
        saved.text, saved.choiceIds, saved.options, saved.multiple, saved.anonymous, saved.atMillis, saved.reminder, saved.schedule,
        saved.attachment?.let { item ->
            val file = file(item)
            if (!file.isFile || file.length() != item.size) storageFailure()
            UploadSource(item.name, item.mime, item.size, { file.inputStream() }, requestToken = item.fileId)
        }, saved.memberIds, saved.targetIds)
    fun removeAction(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        val saved = action(owner, id) ?: return@synchronized
        if (!preferences.edit().remove("action:$id").commit()) storageFailure()
        saved.attachment?.let { file(it).delete() }
    }
    fun composers(owner: WorkspaceOwner): Map<String, String> = synchronized(lock) {
        preferences.all.filterKeys { it.startsWith("composer:") }.values.map { value ->
            try { json.decodeFromString<ChatComposerRecord>(value as? String ?: storageFailure()) } catch (_: Exception) { storageFailure() }
        }.onEach { if (it.version != 1 || it.channel.isBlank() || it.text.length > 10_000) storageFailure() }
            .filter { it.owner.hasSameIdentity(owner) }.associate { it.channel to it.text }
    }
    fun saveComposer(owner: WorkspaceOwner, channel: String, text: String) = synchronized(lock) {
        require(channel.isNotBlank() && text.length <= 10_000)
        val key = "composer:" + chatTextDigest(owner.profileId + ":" + owner.identityRevision + ":" + channel)
        val editor = preferences.edit()
        if (text.isEmpty()) editor.remove(key) else editor.putString(key, json.encodeToString(ChatComposerRecord(owner, channel, text)))
        if (!editor.commit()) storageFailure()
    }
    private suspend fun copyAttachment(source: UploadSource): ChatSavedAttachment {
        if (!directory.isDirectory && !directory.mkdirs()) storageFailure()
        val id = UUID.randomUUID().toString()
        val output = File(directory, id)
        try {
            var total = 0L
            source.openInputStream().use { input -> output.outputStream().use { sink ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val read = input.read(buffer); if (read < 0) break
                    total += read
                    if (total > source.contentLength) storageFailure()
                    sink.write(buffer, 0, read)
                }
                sink.fd.sync()
            } }
            if (total != source.contentLength) storageFailure()
            return ChatSavedAttachment(id, source.displayName, source.contentType, total)
        } catch (error: Exception) { output.delete(); throw error }
    }
    private fun file(attachment: ChatSavedAttachment): File {
        if (runCatching { UUID.fromString(attachment.fileId).toString() }.getOrNull() != attachment.fileId) storageFailure()
        return File(directory, attachment.fileId)
    }
    private fun storageFailure(): Nothing = throw DsmFailure(null, "Chat drafts could not be saved on this device", "Free up space and try again.", kind = DsmErrorKind.LOCAL_STORAGE_FAILED)
    companion object { private val lock = Any() }
}

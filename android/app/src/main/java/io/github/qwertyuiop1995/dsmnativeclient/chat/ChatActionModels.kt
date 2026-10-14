package io.github.qwertyuiop1995.dsmnativeclient.chat

import io.github.qwertyuiop1995.dsmnativeclient.chatPayloadFingerprint
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.serialization.Serializable

@Serializable
internal enum class ChatActionKind {
    SEND, ATTACHMENT, REPLY, EDIT, VOTE, PIN, UNPIN, DELETE, CLOSE,
    REMINDER_SET, REMINDER_DELETE, SCHEDULE_CREATE, SCHEDULE_DELETE, POLL_CREATE, DIRECT, GROUP, FORWARD,
}
@Serializable
internal enum class ChatActionPhase { READY, SUBMITTED, COMPLETED, REJECTED }

/** 只保存身份、摘要及回执；不把正文、文件名、成员名或凭据复制到恢复记录。 */
@Serializable
internal data class ChatActionCheckpoint(
    val id: String,
    val kind: ChatActionKind,
    val channelId: String,
    val currentUserId: String,
    val messageId: String? = null,
    val threadId: String? = null,
    val authorId: String? = null,
    val baselineDigest: String? = null,
    val desiredDigest: String? = null,
    val choiceIds: List<String> = emptyList(),
    val atMillis: Long? = null,
    val baselineAtMillis: Long? = null,
    val remoteId: String? = null,
    val phase: ChatActionPhase = ChatActionPhase.READY,
    val submittedAtMillis: Long? = null,
    val acknowledged: Boolean = false,
    val attachmentNameDigest: String? = null,
    val attachmentSize: Long? = null,
    val memberIds: List<String> = emptyList(),
    val group: ChatGroupProgress? = null,
    val forwardTargets: List<ChatForwardTarget> = emptyList(),
) {
    val finished get() = phase in setOf(ChatActionPhase.COMPLETED, ChatActionPhase.REJECTED)
    val submitted get() = phase != ChatActionPhase.READY
    fun sameOperation(other: ChatActionCheckpoint): Boolean = copy(remoteId = null, phase = ChatActionPhase.READY,
        submittedAtMillis = null, acknowledged = false, group = group?.identity(), forwardTargets = forwardTargets.map { it.copy(confirmedId = null) }) == other.copy(remoteId = null, phase = ChatActionPhase.READY,
        submittedAtMillis = null, acknowledged = false, group = other.group?.identity(), forwardTargets = other.forwardTargets.map { it.copy(confirmedId = null) })
    override fun toString() = "ChatActionCheckpoint(kind=$kind, phase=$phase)"
}

internal data class ChatActionDraft(
    val kind: ChatActionKind,
    val channelId: String,
    val original: ChatMessage? = null,
    val conversation: ChatConversation? = null,
    val text: String = "",
    val choiceIds: Set<String> = emptySet(),
    val options: List<String> = emptyList(),
    val multiple: Boolean = false,
    val anonymous: Boolean = false,
    val atMillis: Long? = null,
    val reminder: ChatReminder? = null,
    val schedule: ChatScheduledMessage? = null,
    val attachment: io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource? = null,
    val memberIds: List<String> = emptyList(),
    val targetIds: List<String> = emptyList(),
)
internal data class ChatPreparedAction(val checkpoint: ChatActionCheckpoint, val draft: ChatActionDraft)
internal data class ChatActionOutcome(val checkpoint: ChatActionCheckpoint,
    val message: ChatMessage? = null, val conversation: ChatConversation? = null,
    val reminder: ChatReminder? = null, val schedule: ChatScheduledMessage? = null, val failure: DsmFailure? = null)

internal fun chatTextDigest(text: String): String = chatPayloadFingerprint(listOf(text))
internal fun ChatPoll.definitionDigest(): String = chatPayloadFingerprint(listOf(question, allowsMultipleSelection.toString(),
    isAnonymous.toString()) + options.map { it.text })
internal fun ChatPoll.votingDigest(): String = chatPayloadFingerprint(listOf(definitionDigest()) + options.map { it.id })
internal fun ChatMessage.contentDigest(): String = chatPayloadFingerprint(listOf(id, conversationId, sender?.id.orEmpty(),
    body, createdAtEpochMillis.toString(), editedAtEpochMillis.toString(), threadId.orEmpty(), kind, isEncrypted.toString(),
    poll?.id.orEmpty(), poll?.votingDigest().orEmpty()) + attachments.flatMap { listOf(it.id, it.name, it.mimeType.orEmpty(), it.size.toString()) })
internal fun ChatConversation.contentDigest(): String = chatPayloadFingerprint(listOf(id, title, kind.name, isEncrypted.toString()) + memberIds.sorted())
internal fun chatPollDefinitionDigest(text: String, options: List<String>, multiple: Boolean, anonymous: Boolean): String =
    chatPayloadFingerprint(listOf(text, multiple.toString(), anonymous.toString()) + options)

@Serializable
internal enum class ChatGroupStep { READY, SUBMITTED, COMPLETED, REJECTED }
@Serializable
internal data class ChatGroupProgress(val join: ChatGroupStep = ChatGroupStep.READY, val invite: ChatGroupStep = ChatGroupStep.READY) {
    fun identity() = ChatGroupProgress()
    val canContinue get() = join in setOf(ChatGroupStep.READY, ChatGroupStep.REJECTED) ||
        join == ChatGroupStep.COMPLETED && invite in setOf(ChatGroupStep.READY, ChatGroupStep.REJECTED)
}
@Serializable
internal data class ChatForwardTarget(val channelId: String, val baselineIds: List<String>, val latestAtMillis: Long?, val confirmedId: String? = null)
internal fun ChatMessage.forwardDigest(): String = chatPayloadFingerprint(listOf(body) + attachments.flatMap {
    listOf(it.name, it.mimeType.orEmpty(), it.size.toString()) })

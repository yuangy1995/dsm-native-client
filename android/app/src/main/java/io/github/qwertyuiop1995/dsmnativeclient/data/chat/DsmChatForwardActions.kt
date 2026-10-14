package io.github.qwertyuiop1995.dsmnativeclient.data.chat

import io.github.qwertyuiop1995.dsmnativeclient.asDsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*
import kotlin.math.abs

internal suspend fun DsmChatRepository.prepareForwardAction(draft: ChatActionDraft, id: String): ChatPreparedAction {
    val original = requireNotNull(draft.original)
    require(original.conversationId == draft.channelId && draft.targetIds.isNotEmpty() && draft.targetIds.distinct().size == draft.targetIds.size)
    val targets = draft.targetIds.sorted()
    if (!gateway.supports(DsmChatRepository.POST, 5)) throw chatUnsupported()
    if (original.isEncrypted || original.poll != null || original.deliveryState != ChatDeliveryState.SENT ||
        original.body.isBlank() && original.attachments.isEmpty() || original.conversationId in targets ||
        targets.any { it.toLongOrNull()?.let { number -> number <= 0 || number.toString() != it } != false }) throw chatChanged()
    val channels = conversations(requireCurrentUser = true)
    val current = users().singleOrNull { it.isCurrent && !it.isDisabled }?.id ?: throw chatChanged()
    if ((targets + original.conversationId).any { target -> channels.none { it.id == target && !it.isEncrypted } }) throw chatChanged()
    val source = message(original.conversationId, original.id, original.threadId) ?: throw chatChanged()
    if (source.contentDigest() != original.contentDigest()) throw chatChanged()
    val baselines = targets.map { channel ->
        val page = messages(channel, limit = 100)
        ChatForwardTarget(channel, page.messages.map { it.id }, page.messages.maxOfOrNull { it.createdAtEpochMillis })
    }
    val checkpoint = ChatActionCheckpoint(id, ChatActionKind.FORWARD, original.conversationId, current,
        original.id, original.threadId, original.sender?.id, original.contentDigest(), original.forwardDigest(), forwardTargets = baselines)
    return ChatPreparedAction(checkpoint, draft.copy(targetIds = targets))
}

internal suspend fun DsmChatRepository.executeForwardAction(prepared: ChatPreparedAction, checkpoint: ChatActionCheckpoint,
    save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome {
    if (checkpoint.finished) return ChatActionOutcome(checkpoint)
    if (checkpoint.submitted) return recoverForwardAction(checkpoint, save)
    val fresh = prepareForwardAction(prepared.draft, checkpoint.id)
    if (!fresh.checkpoint.sameOperation(checkpoint)) throw chatChanged()
    currentCoroutineContext().ensureActive()
    var c = checkpoint.copy(phase = ChatActionPhase.SUBMITTED, submittedAtMillis = System.currentTimeMillis())
    save(c); currentCoroutineContext().ensureActive()
    try {
        gateway.call(DsmChatRepository.POST, "forward", 5, mapOf("post_id" to JsonPrimitive(c.messageId),
            "channel_ids" to JsonArray(c.forwardTargets.map { JsonPrimitive(it.channelId.toLong()) })), oneShot = true)
    } catch (error: Exception) {
        val failure = error.asDsmFailure()
        if (failure.isExplicitApiRejection) {
            val rejected = c.copy(phase = ChatActionPhase.REJECTED)
            return try { save(rejected); ChatActionOutcome(rejected, failure = failure) }
                catch (storage: Exception) { ChatActionOutcome(c, failure = storage.asDsmFailure()) }
        }
        return ChatActionOutcome(c, failure = failure)
    }
    c = c.copy(acknowledged = true)
    try { save(c) } catch (error: Exception) { return ChatActionOutcome(c, failure = error.asDsmFailure()) }
    return recoverForwardAction(c, save)
}

internal suspend fun DsmChatRepository.recoverForwardAction(checkpoint: ChatActionCheckpoint,
    save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome {
    if (!checkpoint.submitted || checkpoint.finished || !checkpoint.acknowledged) return ChatActionOutcome(checkpoint)
    var c = checkpoint
    var failure: DsmFailure? = null
    try {
        val channels = conversations(requireCurrentUser = true)
        if (gateway.currentUserId() != c.currentUserId) throw chatChanged()
        for (index in c.forwardTargets.indices) {
            val target = c.forwardTargets[index]
            if (target.confirmedId != null) continue
            val candidate = try {
                if (channels.none { it.id == target.channelId && !it.isEncrypted }) throw chatChanged()
                forwardedMessageId(c, target)
            } catch (error: Exception) { failure = error.asDsmFailure(); continue }
            if (candidate == null) continue
            if (c.forwardTargets.any { it.confirmedId == candidate }) { failure = chatChanged(); continue }
            c = c.copy(forwardTargets = c.forwardTargets.mapIndexed { i, row -> if (i == index) row.copy(confirmedId = candidate) else row })
            try { save(c) } catch (storage: Exception) { return ChatActionOutcome(c, failure = storage.asDsmFailure()) }
        }
        val result = ChatActionOutcome(c, failure = failure)
        return if (c.forwardTargets.all { it.confirmedId != null }) finishAction(result, save) else result
    } catch (error: Exception) { return ChatActionOutcome(c, failure = error.asDsmFailure()) }
}

private suspend fun DsmChatRepository.forwardedMessageId(c: ChatActionCheckpoint, target: ChatForwardTarget): String? {
    val at = requireNotNull(c.submittedAtMillis)
    val earliest = maxOf(at - 180_000, target.latestAtMillis ?: Long.MIN_VALUE)
    var cursor: String? = null
    val seen = mutableSetOf<String>(); val cursors = mutableSetOf<String>(); var candidate: String? = null
    while (true) {
        currentCoroutineContext().ensureActive()
        val page = messages(target.channelId, cursor, 100)
        for (message in page.messages) {
            if (!seen.add(message.id)) ChatCodec.invalid()
            if (message.sender?.id == c.currentUserId && message.isMine && !message.isEncrypted && message.poll == null &&
                message.threadId == null && message.id !in target.baselineIds && abs(message.createdAtEpochMillis - at) <= 180_000 &&
                (target.latestAtMillis == null || message.createdAtEpochMillis > target.latestAtMillis) && message.forwardDigest() == c.desiredDigest) {
                if (candidate != null) return null
                candidate = message.id
            }
        }
        if (!page.hasMore || page.messages.any { it.createdAtEpochMillis < earliest }) return candidate
        val next = page.previousCursor ?: ChatCodec.invalid()
        if (next == cursor || !cursors.add(next)) ChatCodec.invalid()
        cursor = next
    }
}

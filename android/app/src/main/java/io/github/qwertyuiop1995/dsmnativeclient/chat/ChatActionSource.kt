package io.github.qwertyuiop1995.dsmnativeclient.chat

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner

/** 动作模型只绑定一个工作区；生产适配器不保留另一份消息或写实现。 */
internal interface ChatActionSource {
    val identity: Any
    val owner: WorkspaceOwner
    suspend fun prepare(draft: ChatActionDraft, id: String): ChatPreparedAction
    suspend fun execute(prepared: ChatPreparedAction, checkpoint: ChatActionCheckpoint,
        onProgress: (Long, Long) -> Unit, save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome
    suspend fun recover(checkpoint: ChatActionCheckpoint, save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome
    suspend fun continueGroup(checkpoint: ChatActionCheckpoint, save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome
}

internal class DsmChatActionSource(private val repository: DsmRepository) : ChatActionSource {
    override val identity: Any get() = repository
    override val owner = requireNotNull(repository.owner)
    override suspend fun prepare(draft: ChatActionDraft, id: String) = repository.chatRepository.prepareAction(draft, id)
    override suspend fun execute(prepared: ChatPreparedAction, checkpoint: ChatActionCheckpoint,
        onProgress: (Long, Long) -> Unit, save: (ChatActionCheckpoint) -> Unit) =
        repository.chatRepository.executeAction(prepared, checkpoint, onProgress, save)
    override suspend fun recover(checkpoint: ChatActionCheckpoint, save: (ChatActionCheckpoint) -> Unit) =
        repository.chatRepository.recoverAction(checkpoint, save)
    override suspend fun continueGroup(checkpoint: ChatActionCheckpoint, save: (ChatActionCheckpoint) -> Unit) =
        repository.chatRepository.continueGroupAction(checkpoint, save)
}

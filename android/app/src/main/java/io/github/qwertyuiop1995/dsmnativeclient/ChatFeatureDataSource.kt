package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessagePage
import kotlinx.coroutines.CoroutineScope

/** Chat 读取与实时生命周期的最小内部适配边界，不承载任何写业务。 */
internal interface ChatFeatureDataSource {
    /** 用现有仓库实例作为身份，资料切换后可拒绝旧回调。 */
    val identity: Any

    suspend fun conversations(): List<ChatConversation>

    suspend fun messages(conversationId: String, offset: Int): ChatMessagePage

    fun realtimeConnection(
        onConnectionChanged: (Boolean) -> Unit,
        onContentChanged: () -> Unit,
    ): ChatFeatureRealtimeConnection
}

/** 实时连接只暴露 Feature 需要的启动和停止语义。 */
internal interface ChatFeatureRealtimeConnection {
    fun start(scope: CoroutineScope)

    fun stop()
}

/** 唯一生产适配器：直接委托既有 DsmRepository 与 ChatRealtimeClient。 */
internal class DsmRepositoryChatFeatureDataSource(
    private val repository: DsmRepository,
) : ChatFeatureDataSource {
    override val identity: Any
        get() = repository

    override suspend fun conversations(): List<ChatConversation> = repository.chatConversations()

    override suspend fun messages(conversationId: String, offset: Int): ChatMessagePage =
        repository.chatMessages(conversationId, offset)

    override fun realtimeConnection(
        onConnectionChanged: (Boolean) -> Unit,
        onContentChanged: () -> Unit,
    ): ChatFeatureRealtimeConnection {
        val client = repository.chatRealtimeClient(onConnectionChanged, onContentChanged)
        return object : ChatFeatureRealtimeConnection {
            override fun start(scope: CoroutineScope) = client.start(scope)

            override fun stop() = client.stop()
        }
    }
}

package io.github.qwertyuiop1995.dsmnativeclient.data.chat

import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.dsmApiFailure
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChatConversationRecoveryTest {
    @Test fun `已有精确两人单聊直接打开且零创建`() = runBlocking {
        val f = ChatActionGateway(); f.channels["21"] = channel("21", direct = true, members = listOf("1", "2"))
        val prepared = f.repo.prepareAction(direct())
        val result = f.repo.executeAction(prepared) {}
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase); assertEquals("21", result.conversation!!.id); assertTrue(f.writes.isEmpty())
    }
    @Test fun `单聊发送字符串成员数组关闭加密并核对返回身份`() = runBlocking {
        val f = ChatActionGateway(); val prepared = f.repo.prepareAction(direct())
        f.write = { r ->
            assertEquals(2, r.version); assertEquals("initiate", r.method); assertEquals(JsonArray(listOf(JsonPrimitive("2"))), r.params["user_ids"])
            assertEquals(JsonPrimitive(false), r.params["encrypted"]); assertEquals(JsonArray(emptyList()), r.params["channel_key_encs"])
            f.channels["21"] = channel("21", direct = true, members = listOf("1", "2")); obj("{\"channel_id\":\"21\"}")
        }
        val result = f.repo.executeAction(prepared) {}; assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase); assertEquals(1, f.writes.size)
    }
    @Test fun `单聊丢回执只读恢复且群聊同名和额外成员不能认领`() = runBlocking {
        val f = ChatActionGateway(); val prepared = f.repo.prepareAction(direct())
        f.write = { throw java.io.IOException() }
        val result = f.repo.executeAction(prepared) {}
        f.channels["21"] = channel("21", direct = false, members = listOf("1", "2"))
        assertEquals(ChatActionPhase.SUBMITTED, DsmChatRepository(f).recoverAction(result.checkpoint) {}.checkpoint.phase)
        f.channels["21"] = channel("21", direct = true, members = listOf("1", "2", "3"))
        assertEquals(ChatActionPhase.SUBMITTED, f.repo.recoverAction(result.checkpoint) {}.checkpoint.phase)
        f.channels["21"] = channel("21", direct = true, members = listOf("1", "2"))
        assertEquals(ChatActionPhase.COMPLETED, f.repo.recoverAction(result.checkpoint) {}.checkpoint.phase); assertEquals(1, f.writes.size)
    }
    @Test fun `单聊错误返回编号不能重绑其他正确单聊`() = runBlocking {
        val f = ChatActionGateway(); val prepared = f.repo.prepareAction(direct())
        f.write = { f.channels["21"] = channel("21", direct = true, members = listOf("1", "2")); obj("{\"channel_id\":\"99\"}") }
        val result = f.repo.executeAction(prepared) {}; assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase); assertEquals("99", result.checkpoint.remoteId)
    }
    @Test fun `群聊创建加入邀请分别落盘且缺少成员不误报完成`() = runBlocking {
        val f = ChatActionGateway(); var saved: ChatActionCheckpoint? = null
        f.write = { r ->
            val c = requireNotNull(saved); assertEquals(ChatActionPhase.SUBMITTED, c.phase); assertTrue(r.oneShot)
            when (r.method) {
                "create" -> { assertEquals(JsonPrimitive("Synthetic group"), r.params["name"]); f.channels["21"] = channel("21"); obj("{\"channel_id\":\"21\"}") }
                "join" -> { assertEquals(ChatGroupStep.SUBMITTED, c.group!!.join); f.members = listOf("1"); obj("{}") }
                "invite" -> { assertEquals(ChatGroupStep.SUBMITTED, c.group!!.invite); assertEquals(JsonArray(listOf(JsonPrimitive("2"), JsonPrimitive("3"))), r.params["user_ids"]); f.members = listOf("1", "2", "3"); obj("{}") }
                else -> error("unexpected")
            }
        }
        val prepared = f.repo.prepareAction(group()); saved = prepared.checkpoint
        val result = f.repo.executeAction(prepared) { saved = it }
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase); assertEquals(listOf("create", "join", "invite"), f.writes.map { it.method })
    }
    @Test fun `群聊缺创建编号不按同名群认领也不开始加入邀请`() = runBlocking {
        val f = ChatActionGateway(); f.write = { f.channels["21"] = channel("21"); obj("{}") }
        val result = f.repo.executeAction(f.repo.prepareAction(group())) {}
        val cold = DsmChatRepository(f).recoverAction(result.checkpoint) {}
        assertEquals(ChatActionPhase.SUBMITTED, cold.checkpoint.phase); assertNull(cold.checkpoint.remoteId); assertEquals(listOf("create"), f.writes.map { it.method })
    }
    @Test fun `邀请未知只读刷新不重邀且恢复全部成员后完成`() = runBlocking {
        val f = ChatActionGateway(); f.defaultGroupWrites()
        val normal = f.write
        f.write = { r -> if (r.method == "invite") { f.members = listOf("1", "2"); throw java.io.IOException() } else normal(r) }
        val result = f.repo.executeAction(f.repo.prepareAction(group())) {}
        assertEquals(ChatGroupStep.SUBMITTED, result.checkpoint.group!!.invite)
        val refreshed = f.repo.recoverAction(result.checkpoint) {}
        assertEquals(ChatActionPhase.SUBMITTED, refreshed.checkpoint.phase)
        assertEquals(ChatActionPhase.SUBMITTED, f.repo.continueGroupAction(refreshed.checkpoint) {}.checkpoint.phase)
        assertEquals(3, f.writes.size)
        f.members = listOf("1", "2", "3")
        assertEquals(ChatActionPhase.COMPLETED, DsmChatRepository(f).recoverAction(result.checkpoint) {}.checkpoint.phase); assertEquals(3, f.writes.size)
    }
    @Test fun `邀请明确拒绝可显式继续但只邀请仍缺少的成员`() = runBlocking {
        val f = ChatActionGateway(); f.defaultGroupWrites(); val normal = f.write
        f.write = { r -> if (r.method == "invite") { f.members = listOf("1", "2"); throw dsmApiFailure(105) } else normal(r) }
        val result = f.repo.executeAction(f.repo.prepareAction(group())) {}
        assertEquals(ChatGroupStep.REJECTED, result.checkpoint.group!!.invite)
        f.write = { r -> assertEquals("invite", r.method); assertEquals(JsonArray(listOf(JsonPrimitive("3"))), r.params["user_ids"]); f.members = listOf("1", "2", "3"); obj("{}") }
        val continued = f.repo.continueGroupAction(result.checkpoint) {}
        assertEquals(ChatActionPhase.COMPLETED, continued.checkpoint.phase); assertEquals(listOf("create", "join", "invite", "invite"), f.writes.map { it.method })
    }
    @Test fun `加入已完成后被移出不能通过继续重入`() = runBlocking {
        val f = ChatActionGateway(); f.defaultGroupWrites(); val normal = f.write
        f.write = { r -> if (r.method == "invite") throw dsmApiFailure(105) else normal(r) }
        val result = f.repo.executeAction(f.repo.prepareAction(group())) {}; f.members = emptyList()
        f.repo.continueGroupAction(result.checkpoint) {}; assertEquals(3, f.writes.size)
    }
    @Test fun `创建回执保存失败保留编号不继续加入且冷恢复零写`() = runBlocking {
        val f = ChatActionGateway(); f.defaultGroupWrites()
        val prepared = f.repo.prepareAction(group())
        val result = f.repo.executeAction(prepared) { if (it.remoteId != null) error("disk") }
        assertEquals("21", result.checkpoint.remoteId); assertEquals(listOf("create"), f.writes.map { it.method })
        DsmChatRepository(f).recoverAction(result.checkpoint) {}; assertEquals(1, f.writes.size)
    }
    @Test fun `附件按实际转义名称摘要和原编号回读`() = runBlocking {
        val f = ChatActionGateway(); val source = UploadSource("synthetic\".txt", "text/plain", 3, { byteArrayOf(1, 2, 3).inputStream() })
        val prepared = f.repo.prepareAction(ChatActionDraft(ChatActionKind.ATTACHMENT, "11", text = "caption", attachment = source))
        f.uploadResult = obj("{\"post_id\":\"71\"}")
        f.posts["11"] = listOf(JsonObject(post("71", "11", "caption") + ("files" to JsonArray(listOf(obj("{\"file_id\":\"9\",\"name\":\"synthetic_.txt\",\"size\":3}"))))))
        val result = f.repo.executeAction(prepared) {}
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase); assertEquals(1, f.uploads)
    }
    @Test fun `附件缺回执不依赖源文件恢复且同名附件不能认领`() = runBlocking {
        val f = ChatActionGateway(); val source = UploadSource("synthetic.txt", "text/plain", 3, { error("Do not reopen") })
        val prepared = f.repo.prepareAction(ChatActionDraft(ChatActionKind.ATTACHMENT, "11", attachment = source))
        val result = f.repo.executeAction(prepared) {}; assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase)
        DsmChatRepository(f).recoverAction(result.checkpoint) {}; assertEquals(1, f.uploads)
    }
    private fun direct() = ChatActionDraft(ChatActionKind.DIRECT, "new-direct:2", memberIds = listOf("2"))
    private fun group() = ChatActionDraft(ChatActionKind.GROUP, "new-group", text = "Synthetic group", memberIds = listOf("2", "3"))
}

internal class ChatActionGateway : DsmChatRepositoryGateway {
    val repo = DsmChatRepository(this); var current: String? = null
    val channels = linkedMapOf("11" to channel("11"), "12" to channel("12"), "13" to channel("13"))
    var members = listOf("1")
    val posts = mutableMapOf<String, List<JsonObject>>()
    val calls = mutableListOf<ChatTestCall>(); val writes get() = calls.filter { it.method !in setOf("list", "get", "get_choices", "search") }
    var write: (ChatTestCall) -> JsonObject = { obj("{}") }
    var overrideRead: ((ChatTestCall) -> JsonObject?)? = null
    var uploadResult = obj("{}"); var uploads = 0
    override suspend fun usersData() = userData
    var userData = obj("{\"current_user_id\":\"1\",\"users\":[{\"user_id\":\"1\",\"username\":\"tester\"},{\"user_id\":\"2\",\"username\":\"peer2\"},{\"user_id\":\"3\",\"username\":\"peer3\"}]}")
    override suspend fun conversationsData() = JsonObject(mapOf("channels" to JsonArray(channels.values.toList())))
    override suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement>, oneShot: Boolean): JsonObject {
        val call = ChatTestCall(api, method, version, parameters, oneShot); calls += call
        if (method !in setOf("list", "get", "get_choices", "search")) return write(call)
        overrideRead?.invoke(call)?.let { return it }
        val channel = (parameters["channel_id"] as? JsonPrimitive)?.content.orEmpty()
        val anchor = (parameters["post_id"] as? JsonPrimitive)?.content
        val limit = (parameters["prev_count"] as? JsonPrimitive)?.int ?: 100
        val values = posts[channel].orEmpty()
        val rows = if (limit == 0) values.filter { it["post_id"] == JsonPrimitive(anchor) }
            else values.sortedByDescending { (it["create_at"] as JsonPrimitive).long }.let { all ->
                val offset = if (anchor == null) 0 else all.indexOfFirst { it["post_id"] == JsonPrimitive(anchor) }.coerceAtLeast(0)
                all.drop(offset).take(limit + if (anchor == null) 0 else 1)
            }
        return JsonObject(mapOf("posts" to JsonArray(rows)))
    }
    override fun supports(api: String, version: Int) = true
    override suspend fun upload(channelId: String, text: String, source: UploadSource, willSubmit: () -> Unit, onProgress: (Long, Long) -> Unit): JsonObject {
        willSubmit(); uploads++; return uploadResult
    }
    override suspend fun conversationMembersData(conversationId: String) = JsonObject(mapOf("user_ids" to JsonArray(members.map(::JsonPrimitive))))
    override fun supportsConversationMembers() = true
    override fun invalidConversationRequest() = chatChanged()
    override fun unsupportedConversationRead() = chatUnsupported()
    override fun username() = "tester"
    override fun currentUserId() = current
    override fun updateCurrentUserId(userId: String?) { current = userId }
    fun defaultGroupWrites() { write = { r -> when (r.method) {
        "create" -> { channels["21"] = channel("21"); obj("{\"channel_id\":\"21\"}") }
        "join" -> { members = listOf("1"); obj("{}") }
        "invite" -> { members = listOf("1", "2", "3"); obj("{}") }
        else -> error("Unexpected write")
    } } }
}
internal data class ChatTestCall(val api: String, val method: String, val version: Int, val params: Map<String, JsonElement>, val oneShot: Boolean)
internal fun obj(text: String) = Json.parseToJsonElement(text) as JsonObject
internal fun channel(id: String, direct: Boolean = false, members: List<String> = listOf("1")) = buildJsonObject {
    put("channel_id", id); put("name", "Synthetic group"); put("type", if (direct) "anonymous" else "private")
    put("members", JsonArray(members.map(::JsonPrimitive))); put("member_count", members.size)
}
internal fun post(id: String, channel: String, text: String = "Synthetic", at: Long = System.currentTimeMillis() - 60_000) = buildJsonObject {
    put("post_id", id); put("channel_id", channel); put("message", text); put("create_at", at); put("creator_id", "1"); put("thread_id", "0")
}

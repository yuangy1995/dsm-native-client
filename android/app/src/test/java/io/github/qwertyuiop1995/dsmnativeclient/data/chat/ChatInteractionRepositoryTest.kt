package io.github.qwertyuiop1995.dsmnativeclient.data.chat

import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChatInteractionRepositoryTest {
    @Test fun `真实历史游标不发送offset并跳过重复锚点且辅助记录推进`() = runBlocking {
        val f = Fixture()
        f.repo.users()
        f.read = { request ->
            assertEquals("list", request.method); assertEquals(5, request.version)
            assertFalse(request.parameters.containsKey("offset")); assertFalse(request.parameters.containsKey("limit"))
            if (request.parameters["post_id"] == null) posts(post("8"), post("7", ""))
            else { assertEquals(JsonPrimitive("7"), request.parameters["post_id"]); posts(post("7", ""), post("6")) }
        }
        val first = f.repo.messages("11", limit = 2)
        assertEquals("tester", first.messages.single().sender?.displayName)
        assertEquals("7", first.previousCursor); assertTrue(first.hasMore); assertEquals(listOf("8"), first.messages.map { it.id })
        val second = f.repo.messages("11", first.previousCursor, 2)
        assertEquals(listOf("6"), second.messages.map { it.id }); assertFalse(second.hasMore)
    }
    @Test fun `线程首屏不用根做定位且拒绝其他线程回复`() = runBlocking {
        val f = Fixture(); f.read = { request ->
            assertNull(request.parameters["post_id"]); assertEquals(JsonPrimitive("7"), request.parameters["thread_id"])
            posts(post("8", thread = "7"))
        }
        assertEquals("8", f.repo.messages("11", threadId = "7").messages.single().id)
        f.read = { posts(post("9", thread = "4")) }
        rejected { f.repo.messages("11", threadId = "7") }
    }
    @Test fun `坏列表重复身份跨会话与超过页大小均拒绝`() = runBlocking {
        val f = Fixture()
        for (data in listOf(obj("{}"), posts(post("7"), post("7")), posts(post("7", channel = "12")), posts(post("1"), post("2")))) {
            f.read = { data }; rejected { f.repo.messages("11", limit = 1) }
        }
    }
    @Test fun `搜索使用数字in与独立offset并过滤加密正文`() = runBlocking {
        val f = Fixture(); f.read = { r ->
            assertEquals("search", r.method); assertEquals(JsonArray(listOf(JsonPrimitive(11))), r.parameters["in"])
            assertEquals(JsonPrimitive(50), r.parameters["offset"])
            obj("""{"search_results":[${post("9")},${post("8", encrypted = true)}],"total":53}""")
        }
        val page = f.repo.search("keyword", "11", 50)
        assertEquals(52, page.nextOffset); assertEquals(listOf("9"), page.messages.map { it.id })
        f.read = { obj("""{"search_results":[${post("9", channel = "12")}],"total":1}""") }
        rejected { f.repo.search("keyword", "11") }
    }
    @Test fun `公告完整分页包含101项且严格同会话`() = runBlocking {
        val f = Fixture(); var page = 0
        f.read = { r ->
            assertEquals(JsonArray(listOf(JsonPrimitive("pin"))), r.parameters["has"])
            assertEquals(JsonPrimitive("last_pin_at"), r.parameters["sort_by"])
            val rows = if (page++ == 0) (1..100).map { post(it.toString(), pinned = true) } else listOf(post("101", pinned = true))
            obj("""{"search_results":[${rows.joinToString()}],"total":101}""")
        }
        assertEquals(101, f.repo.pinnedMessages("11").size); assertEquals(2, page)
    }
    @Test fun `props投票保留选择和截止且不保留投票者名单`() = runBlocking {
        val f = Fixture(); f.repo.users(); f.read = { posts(poll()) }
        val result = f.repo.messages("11").messages.single().poll!!
        assertEquals(2, result.options.size); assertTrue(result.options.first().isSelectedByCurrentUser)
        assertEquals(3, result.options.first().voteCount); assertFalse(result.isClosed)
        assertNull(result.closesAtEpochMillis)
    }
    @Test fun `发送必须先保存且只按返回身份读取无相似认领`() = runBlocking {
        val f = Fixture(); val prepared = f.repo.prepareAction(ChatActionDraft(ChatActionKind.SEND, "11", text = "same text"))
        var saved = prepared.checkpoint
        f.write = { r -> assertEquals(ChatActionPhase.SUBMITTED, saved.phase); assertTrue(r.oneShot); obj("{\"post_id\":\"71\"}") }
        f.read = { r -> assertEquals(JsonPrimitive("71"), r.parameters["post_id"]); posts(post("71", "same text")) }
        val result = f.repo.executeAction(prepared) { saved = it }
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase); assertEquals("71", result.message!!.id)
        assertEquals(1, f.writes.size)
    }
    @Test fun `写前保存失败零提交`() = runBlocking {
        val f = Fixture(); val prepared = f.repo.prepareAction(ChatActionDraft(ChatActionKind.SEND, "11", text = "same text"))
        rejected { f.repo.executeAction(prepared) { error("disk") } }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `无创建回执即使存在相同文字也保持未知且恢复零写`() = runBlocking {
        val f = Fixture(); val prepared = f.repo.prepareAction(ChatActionDraft(ChatActionKind.SEND, "11", text = "same text"))
        f.write = { obj("{}") }; f.read = { posts(post("71", "same text")) }
        var saved = prepared.checkpoint
        val result = f.repo.executeAction(prepared) { saved = it }
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase); assertNull(saved.remoteId)
        val cold = DsmChatRepository(f)
        val restored = cold.recoverAction(saved) { saved = it }
        assertEquals(ChatActionPhase.SUBMITTED, restored.checkpoint.phase); assertEquals(1, f.writes.size)
        assertTrue(f.requests.none { it.method == "list" && it.api == DsmChatRepository.POST })
    }
    @Test fun `HTTP403保留未知而明确API拒绝终结`() = runBlocking {
        for (failure in listOf(httpFailure(403), dsmApiFailure(105))) {
            val f = Fixture(); val prepared = f.repo.prepareAction(ChatActionDraft(ChatActionKind.SEND, "11", text = "test"))
            f.write = { throw failure }
            val result = f.repo.executeAction(prepared) {}
            assertEquals(if (failure.isExplicitApiRejection) ChatActionPhase.REJECTED else ChatActionPhase.SUBMITTED, result.checkpoint.phase)
        }
    }
    @Test fun `回执保存失败保留编号并在新实例只读恢复`() = runBlocking {
        val f = Fixture(); val prepared = f.repo.prepareAction(ChatActionDraft(ChatActionKind.SEND, "11", text = "test"))
        f.write = { obj("{\"post_id\":\"71\"}") }; f.read = { posts(post("71", "test")) }
        val result = f.repo.executeAction(prepared) { if (it.remoteId != null) error("disk") }
        assertEquals("71", result.checkpoint.remoteId); assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase)
        val restored = DsmChatRepository(f).recoverAction(result.checkpoint) {}
        assertEquals(ChatActionPhase.COMPLETED, restored.checkpoint.phase); assertEquals(1, f.writes.size)
    }
    @Test fun `错误作者错误内容与错误线程都不能确认发送`() = runBlocking {
        for (row in listOf(post("71", "test", creator = "2"), post("71", "other"), post("71", "test", thread = "8"))) {
            val f = Fixture(); val prepared = f.repo.prepareAction(ChatActionDraft(ChatActionKind.SEND, "11", text = "test"))
            f.write = { obj("{\"post_id\":\"71\"}") }; f.read = { posts(row) }
            assertEquals(ChatActionPhase.SUBMITTED, f.repo.executeAction(prepared) {}.checkpoint.phase)
        }
    }
    @Test fun `回复根独立读取并固定原线程创建与回读`() = runBlocking {
        val f = Fixture(); f.read = { r -> if (r.parameters["post_id"] == JsonPrimitive("71")) posts(post("71", "reply", thread = "7")) else posts(post("7")) }
        val root = f.repo.message("11", "7")!!
        val prepared = f.repo.prepareAction(ChatActionDraft(ChatActionKind.REPLY, "11", original = root, text = "reply"))
        f.write = { r -> assertEquals(JsonPrimitive("7"), r.parameters["thread_id"]); assertEquals(JsonPrimitive(false), r.parameters["is_thread"]); obj("{\"post_id\":\"71\"}") }
        assertEquals(ChatActionPhase.COMPLETED, f.repo.executeAction(prepared) {}.checkpoint.phase)
    }
    @Test fun `编辑本人原文时限预检且其他客户端变化零写`() = runBlocking {
        val f = Fixture(); var body = "old"
        f.read = { if (it.api == "SYNO.Chat.Admin.Setting") obj("{\"allow_edit_message\":true,\"allow_edit_message_time_within_min\":0}") else posts(post("7", body)) }
        val original = f.repo.message("11", "7")!!
        val prepared = f.repo.prepareAction(ChatActionDraft(ChatActionKind.EDIT, "11", original = original, text = "new"))
        body = "other client"
        rejected { f.repo.executeAction(prepared) {} }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `编辑未知仅查原消息且必须保持附件及作者`() = runBlocking {
        val f = Fixture(); var body = "old"
        f.read = { if (it.api == "SYNO.Chat.Admin.Setting") obj("{\"allow_edit_message\":true,\"allow_edit_message_time_within_min\":0}") else posts(post("7", body)) }
        val original = f.repo.message("11", "7")!!
        val prepared = f.repo.prepareAction(ChatActionDraft(ChatActionKind.EDIT, "11", original = original, text = "new"))
        f.write = { r -> assertEquals(8, r.version); assertEquals("set", r.method); body = "new"; throw java.io.IOException() }
        assertEquals(ChatActionPhase.COMPLETED, f.repo.executeAction(prepared) {}.checkpoint.phase)
        assertEquals(1, f.writes.size)
    }
    @Test fun `投票完整选择字符串数组回读本人选项及票数`() = runBlocking {
        val f = Fixture(); var voted = false
        f.read = { r -> when (r.method) {
            "get_choices" -> obj("""{"choices":[{"id":"a","count":3,"voters":[]},{"id":"b","count":1,"voters":[1]}]}""")
            else -> posts(poll())
        } }
        val original = f.repo.message("11", "7")!!
        val prepared = f.repo.prepareAction(ChatActionDraft(ChatActionKind.VOTE, "11", original = original, choiceIds = setOf("b")))
        f.write = { r -> assertEquals(JsonArray(listOf(JsonPrimitive("b"))), r.parameters["choice_ids"]); voted = true; obj("{}") }
        val result = f.repo.executeAction(prepared) {}
        assertTrue(voted); assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase)
        assertEquals(listOf("b"), result.message!!.poll!!.options.filter { it.isSelectedByCurrentUser }.map { it.id })
    }
    @Test fun `关闭过期或变更选项投票不提交`() = runBlocking {
        val f = Fixture(); f.read = { posts(poll().let { row -> JsonObject(row + ("props" to obj("{\"vote\":{\"state\":\"close\",\"choices\":[{\"id\":\"a\",\"text\":\"A\"}]}}"))) }) }
        val original = f.repo.message("11", "7")!!
        rejected { f.repo.prepareAction(ChatActionDraft(ChatActionKind.VOTE, "11", original = original, choiceIds = setOf("a"))) }
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `创建投票对象参数及返回编号不可按相同问题认领`() = runBlocking {
        val f = Fixture(); val prepared = f.repo.prepareAction(ChatActionDraft(ChatActionKind.POLL_CREATE, "11", text = "Question", options = listOf("A", "B"), multiple = true))
        f.write = { r -> assertTrue(r.parameters["options"] is JsonObject); assertTrue((r.parameters["choices"] as JsonArray).all { it is JsonObject }); obj("{}") }
        f.read = { posts(poll()) }
        assertEquals(ChatActionPhase.SUBMITTED, f.repo.executeAction(prepared) {}.checkpoint.phase)
    }
    @Test fun `定时取消过期后消失不能误报取消成功`() = runBlocking {
        val f = Fixture(); f.read = { obj("{\"schedules\":[]}") }
        val c = ChatActionCheckpoint("schedule", ChatActionKind.SCHEDULE_DELETE, "11", "1", messageId = "81",
            baselineAtMillis = System.currentTimeMillis() - 1000, phase = ChatActionPhase.SUBMITTED, submittedAtMillis = 1)
        assertEquals(ChatActionPhase.SUBMITTED, f.repo.recoverAction(c) {}.checkpoint.phase)
    }
    @Test fun `提醒和定时读取缺容器重复身份或跨会话拒绝`() = runBlocking {
        val f = Fixture()
        for (value in listOf("{}", "{\"reminders\":[{\"post_id\":\"7\",\"channel_id\":\"12\",\"remind_at\":1900000000000}]}")) {
            f.read = { obj(value) }; rejected { f.repo.reminders("11") }
        }
        f.read = { obj("{\"schedules\":[{\"id\":\"81\",\"channel_id\":\"12\",\"message\":\"test\",\"send_at\":1900000000000}]}") }
        rejected { f.repo.schedules("11") }
    }
    @Test fun `删除完整历史找到旧页目标或空辅助目标不能完成`() = runBlocking {
        val f = Fixture(); var pages = 0
        f.read = { if (pages++ == 0) posts(*(101..200).map { post(it.toString()) }.toTypedArray()) else posts(post("7", "")) }
        val c = ChatActionCheckpoint("delete", ChatActionKind.DELETE, "11", "1", messageId = "7", phase = ChatActionPhase.SUBMITTED, submittedAtMillis = 1)
        assertEquals(ChatActionPhase.SUBMITTED, f.repo.recoverAction(c) {}.checkpoint.phase); assertEquals(2, pages)
        f.read = { posts() }
        assertEquals(ChatActionPhase.COMPLETED, f.repo.recoverAction(c) {}.checkpoint.phase)
    }
    @Test fun `关闭坏列表和读取失败不能确认不可见`() = runBlocking {
        val f = Fixture(); val c = ChatActionCheckpoint("close", ChatActionKind.CLOSE, "11", "1", phase = ChatActionPhase.SUBMITTED, submittedAtMillis = 1)
        f.channels = obj("{}")
        assertEquals(ChatActionPhase.SUBMITTED, f.repo.recoverAction(c) {}.checkpoint.phase)
        f.channels = obj("{\"channels\":[]}")
        assertEquals(ChatActionPhase.COMPLETED, f.repo.recoverAction(c) {}.checkpoint.phase)
    }
    @Test fun `阅读同步只接受读到的消息时间且回读未推进仍失败`() = runBlocking {
        val f = Fixture(); f.read = { posts(post("7")) }; f.repo.messages("11")
        f.write = { r -> assertEquals(JsonPrimitive(1700000000007), r.parameters["last_view_at"]); obj("{}") }
        rejected { f.repo.markRead("11", "unknown") }; assertEquals(0, f.writes.size)
        rejected { f.repo.markRead("11", "7") }; assertEquals(1, f.writes.size)
        f.channels = obj("{\"channels\":[{\"channel_id\":\"11\",\"name\":\"Synthetic\",\"type\":\"private\",\"last_view_at\":1700000000007}]}")
        assertEquals(1700000000007, f.repo.markRead("11", "7").lastViewedAtEpochMillis)
        assertEquals(1, f.writes.size)
        f.channels = obj("{\"channels\":[{\"channel_id\":\"11\",\"name\":\"Synthetic\",\"type\":\"private\",\"last_view_at\":1700000000010}]}")
        assertEquals(1700000000010, f.repo.markRead("11", "7").lastViewedAtEpochMillis)
        assertEquals(1, f.writes.size)
    }
    @Test fun `线程阅读遇到未显示的新回复不发送view`() = runBlocking {
        val f = Fixture(); f.read = { posts(post("8", thread = "7")) }; f.repo.messages("11", threadId = "7")
        f.read = { posts(post("9", thread = "7")) }
        rejected { f.repo.markThreadRead("11", "7", "8") }; assertTrue(f.writes.isEmpty())
    }
    @Test fun `已读同步断线或取消不自动重放且不报告已推进`() = runBlocking {
        for (thread in listOf(false, true)) for (cancel in listOf(false, true)) {
            val f = Fixture(); f.read = { posts(post("8", thread = if (thread) "7" else "0")) }
            f.repo.messages("11", threadId = if (thread) "7" else null)
            f.write = { if (cancel) throw kotlinx.coroutines.CancellationException("synthetic") else throw java.io.IOException("synthetic") }
            val error = runCatching { if (thread) f.repo.markThreadRead("11", "7", "8") else f.repo.markRead("11", "8") }.exceptionOrNull()
            assertNotNull(error); assertEquals(1, f.writes.size)
            assertEquals(cancel, error is kotlinx.coroutines.CancellationException)
        }
    }
    @Test fun `线程已读明确回执仅结束同步不推测未读数量`() = runBlocking {
        val f = Fixture(); f.read = { posts(post("8", thread = "7")) }; f.repo.messages("11", threadId = "7")
        f.write = { request ->
            assertEquals("SYNO.Chat.Post.Subscribe", request.api); assertEquals("view", request.method)
            assertEquals(mapOf("channel_id" to JsonPrimitive("11"), "thread_id" to JsonPrimitive("7")), request.parameters)
            obj("{}")
        }
        f.repo.markThreadRead("11", "7", "8"); assertEquals(1, f.writes.size)
        f.read = { throw java.io.IOException("synthetic read failure") }
        rejected { f.repo.markThreadRead("11", "7", "8") }; assertEquals(1, f.writes.size)
    }
    @Test fun `编辑策略零分钟无限期且非本人系统投票不允许`() {
        val base = ChatMessage("7", "11", ChatUser("1", "Synthetic", "tester"), "test", 1, true)
        val policy = ChatEditingPolicy(true, null)
        assertTrue(policy.permits(base)); assertFalse(policy.permits(base.copy(isMine = false)))
        assertFalse(policy.permits(base.copy(kind = "system"))); assertFalse(ChatEditingPolicy(true, 60_000).permits(base))
    }

    private class Fixture : DsmChatRepositoryGateway {
        val repo = DsmChatRepository(this); var current: String? = null
        var channels = obj("{\"channels\":[{\"channel_id\":\"11\",\"name\":\"Synthetic\",\"type\":\"private\",\"members\":[1,2]}]}")
        val requests = mutableListOf<Call>(); val writes get() = requests.filter { it.method !in setOf("list", "search", "get", "get_choices") }
        var read: (Call) -> JsonObject = { posts() }
        var write: (Call) -> JsonObject = { obj("{}") }
        override suspend fun usersData() = obj("{\"current_user_id\":\"1\",\"users\":[{\"user_id\":\"1\",\"username\":\"tester\"},{\"user_id\":\"2\",\"username\":\"peer\"}]}")
        override suspend fun conversationsData() = channels
        override suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement>, oneShot: Boolean): JsonObject {
            val call = Call(api, method, version, parameters, oneShot); requests += call
            return if (method in setOf("list", "search", "get", "get_choices")) read(call) else write(call)
        }
        override suspend fun upload(channelId: String, text: String, source: io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource,
            willSubmit: () -> Unit, onProgress: (Long, Long) -> Unit): JsonObject = error("No attachment in this fixture")
        override fun supports(api: String, version: Int) = true
        override suspend fun conversationMembersData(conversationId: String) = obj("{\"user_ids\":[1,2]}")
        override fun supportsConversationMembers() = true
        override fun invalidConversationRequest() = chatChanged()
        override fun unsupportedConversationRead() = chatUnsupported()
        override fun username() = "tester"
        override fun currentUserId() = current
        override fun updateCurrentUserId(userId: String?) { current = userId }
    }
    private data class Call(val api: String, val method: String, val version: Int, val parameters: Map<String, JsonElement>, val oneShot: Boolean)
    companion object {
        private fun obj(text: String) = Json.parseToJsonElement(text) as JsonObject
        private fun posts(vararg rows: JsonObject) = JsonObject(mapOf("posts" to JsonArray(rows.toList())))
        private fun post(id: String, text: String = "synthetic", channel: String = "11", creator: String = "1", thread: String = "0", encrypted: Boolean = false, pinned: Boolean = false) = buildJsonObject {
            put("post_id", id); put("channel_id", channel); put("creator_id", creator); put("message", text)
            put("create_at", 1700000000000 + id.toLong()); put("thread_id", thread); put("encrypted", encrypted)
            put("last_pin_at", if (pinned) 1700000000000 else 0)
        }
        private fun poll() = JsonObject(post("7", "Question") + ("props" to obj("""{"vote":{"state":"open","options":{"multiple":true,"anonymous":false,"expire_at":0},"choices":[{"id":"a","text":"A","count":3,"voters":[1]},{"id":"b","text":"B","count":0,"voters":[]}]}}""")))
        private suspend fun rejected(block: suspend () -> Any?) { try { block(); fail("Expected rejection") } catch (_: Exception) {} }
    }
}

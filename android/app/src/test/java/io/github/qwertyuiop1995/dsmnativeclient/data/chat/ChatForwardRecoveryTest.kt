package io.github.qwertyuiop1995.dsmnativeclient.data.chat

import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChatForwardRecoveryTest {
    @Test fun `数字目标数组绑定原消息且两个目标均回读后完成`() = runBlocking {
        val f = fixture(); val prepared = prepare(f)
        f.write = { request ->
            assertTrue(request.oneShot); assertEquals("forward", request.method); assertEquals(5, request.version)
            assertEquals(JsonArray(listOf(JsonPrimitive(12), JsonPrimitive(13))), request.params["channel_ids"])
            f.posts["12"] = listOf(post("71", "12", at = System.currentTimeMillis()))
            f.posts["13"] = listOf(post("72", "13", at = System.currentTimeMillis()))
            obj("{}")
        }
        val result = f.repo.executeAction(prepared) {}
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase)
        assertEquals(listOf("71", "72"), result.checkpoint.forwardTargets.map { it.confirmedId }); assertEquals(1, f.writes.size)
    }
    @Test fun `没有成功回执时相同内容不认领也不再次转发`() = runBlocking {
        val f = fixture(); val prepared = prepare(f)
        f.write = { f.posts["12"] = listOf(post("71", "12", at = System.currentTimeMillis())); throw java.io.IOException() }
        val result = f.repo.executeAction(prepared) {}; val before = f.calls.size
        val restored = DsmChatRepository(f).recoverAction(result.checkpoint) {}
        assertEquals(ChatActionPhase.SUBMITTED, restored.checkpoint.phase); assertEquals(before, f.calls.size); assertEquals(1, f.writes.size)
    }
    @Test fun `部分目标先保存恢复仅读取尚未完成者`() = runBlocking {
        val f = fixture(); val prepared = prepare(f)
        f.write = { f.posts["12"] = listOf(post("71", "12", at = System.currentTimeMillis())); obj("{}") }
        var saved = prepared.checkpoint
        val partial = f.repo.executeAction(prepared) { saved = it }
        assertEquals("71", saved.forwardTargets.first().confirmedId); assertNull(saved.forwardTargets.last().confirmedId)
        assertEquals(ChatActionPhase.SUBMITTED, partial.checkpoint.phase)
        f.calls.clear(); f.posts["13"] = listOf(post("72", "13", at = System.currentTimeMillis()))
        val result = DsmChatRepository(f).recoverAction(saved) {}
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase)
        assertTrue(f.calls.none { it.params["channel_id"] == JsonPrimitive("12") }); assertTrue(f.writes.isEmpty())
    }
    @Test fun `候选不唯一旧基线相同时刻或窗口外均不认领`() = runBlocking {
        for (scenario in 0..3) {
            val f = fixture(); val baseTime = System.currentTimeMillis() - 1000
            f.posts["12"] = listOf(post("old", "12", at = baseTime))
            val prepared = prepare(f)
            f.write = {
                val at = when (scenario) { 2 -> baseTime; 3 -> System.currentTimeMillis() + 200_000; else -> System.currentTimeMillis() }
                f.posts["12"] = when (scenario) {
                    0 -> listOf(post("71", "12", at = at), post("72", "12", at = at))
                    1 -> listOf(post("old", "12", at = at))
                    else -> listOf(post("71", "12", at = at))
                }
                obj("{}")
            }
            val result = f.repo.executeAction(prepared) {}
            assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase); assertNull(result.checkpoint.forwardTargets.first().confirmedId)
        }
    }
    @Test fun `找到第一页候选后仍翻到旧时间边界证明唯一`() = runBlocking {
        val f = fixture(); val prepared = prepare(f)
        f.write = {
            val at = System.currentTimeMillis()
            f.posts["12"] = (1..100).map { post(it.toString(), "12", if (it == 100) "Synthetic" else "Other", at + it) } + post("older", "12", "Other", at - 200_000)
            f.posts["13"] = listOf(post("second", "13", at = at))
            obj("{}")
        }
        val result = f.repo.executeAction(prepared) {}
        assertEquals(ChatActionPhase.COMPLETED, result.checkpoint.phase)
        assertTrue(f.calls.any { it.params["channel_id"] == JsonPrimitive("12") && it.params["post_id"] != null })
    }
    @Test fun `来源改变目标不可见或变为加密时零转发`() = runBlocking {
        for (scenario in 0..2) {
            val f = fixture(); val prepared = prepare(f)
            when (scenario) {
                0 -> f.posts["11"] = listOf(post("7", "11", "Changed"))
                1 -> f.channels.remove("12")
                2 -> f.channels["12"] = JsonObject(channel("12") + ("encrypted" to JsonPrimitive(true)))
            }
            try { f.repo.executeAction(prepared) {}; fail("Expected rejection") } catch (_: Exception) {}
            assertTrue(f.writes.isEmpty())
        }
    }
    @Test fun `目标权限丢失不抹掉已完成项也不误报全部成功`() = runBlocking {
        val f = fixture(); val prepared = prepare(f)
        f.write = { f.posts["12"] = listOf(post("71", "12", at = System.currentTimeMillis())); obj("{}") }
        val partial = f.repo.executeAction(prepared) {}
        f.channels.remove("13")
        val result = f.repo.recoverAction(partial.checkpoint) {}
        assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase); assertEquals("71", result.checkpoint.forwardTargets.first().confirmedId)
    }
    @Test fun `来源在转发后消失仍可按原摘要读取剩余目标`() = runBlocking {
        val f = fixture(); val prepared = prepare(f)
        f.write = { obj("{}") }; val partial = f.repo.executeAction(prepared) {}
        f.channels.remove("11"); f.posts.clear()
        f.posts["12"] = listOf(post("71", "12", at = System.currentTimeMillis()))
        f.posts["13"] = listOf(post("72", "13", at = System.currentTimeMillis()))
        assertEquals(ChatActionPhase.COMPLETED, DsmChatRepository(f).recoverAction(partial.checkpoint) {}.checkpoint.phase); assertEquals(1, f.writes.size)
    }
    private fun fixture() = ChatActionGateway().also { it.posts["11"] = listOf(post("7", "11")) }
    private suspend fun prepare(f: ChatActionGateway): ChatPreparedAction {
        val original = f.repo.message("11", "7")!!
        return f.repo.prepareAction(ChatActionDraft(ChatActionKind.FORWARD, "11", original = original, targetIds = listOf("12", "13")))
    }
}

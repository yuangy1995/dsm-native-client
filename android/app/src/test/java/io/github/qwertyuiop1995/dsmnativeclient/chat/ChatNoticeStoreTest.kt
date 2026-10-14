package io.github.qwertyuiop1995.dsmnativeclient.chat

import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatReminder
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import org.junit.Assert.*
import org.junit.Test

class ChatNoticeStoreTest {
    private val preferences = MemoryPreferences()
    private val store = ChatNoticeStore(preferences)
    private val owner = WorkspaceOwner("profile", "identity", "session")
    private val token = createOpaqueWorkspaceToken()
    private fun setup(): Pair<ChatNoticeScope, ChatLocalReminder> {
        store.setEnabled(true); val scope = store.scope(owner)
        store.sync(scope, "channel", listOf(ChatReminder("r", "m", 10_000)), token, 0)
        return scope to store.reminders().single()
    }
    @Test fun `冷重建保留精确归属到期领取一次不提前不重放`() {
        val (scope, row) = setup(); val cold = ChatNoticeStore(preferences)
        assertEquals(scope, cold.scope(scope.id)); assertEquals(row, cold.reminder(row.id))
        assertFalse(cold.claim(row, 9_999)); assertTrue(cold.claim(row, 10_000)); assertFalse(cold.claim(row, 10_000))
        assertFalse(cold.claim(cold.reminder(row.id)!!, 20_000))
    }
    @Test fun `改期旧任务禁用任务和不同身份任务不能领取`() {
        val (scope, row) = setup()
        store.sync(scope, "channel", listOf(row.reminder.copy(remindAtEpochMillis = 20_000)), token, 0)
        assertFalse(store.claim(row, 50_000))
        val replacement = store.reminders().single(); store.setEnabled(false); assertFalse(store.claim(replacement, 50_000))
        val another = store.scope(owner.copy(identityRevision = "other")); assertNotEquals(scope.id, another.id)
    }
    @Test fun `同一身份重登录保存新会话旧清理不能移除新记录`() {
        val (scope, _) = setup(); val renewed = store.scope(owner.copy(sessionGeneration = "renewed"))
        assertEquals(scope.id, renewed.id); store.remove(scope); assertEquals(renewed, store.scope(scope.id))
        store.remove(renewed); assertTrue(store.scopes().isEmpty()); assertTrue(store.reminders().isEmpty())
    }
    @Test fun `系统延后时再次同步仍保留已经到期而未显示的同一提醒`() {
        val (scope, row) = setup()
        store.sync(scope, row.conversation, listOf(row.reminder), token, 20_000)
        assertEquals(row, store.reminder(row.id)); assertTrue(store.claim(row, 20_000))
    }
    @Test fun `未知版本损坏记录和非法路由不交付`() {
        val (_, row) = setup(); preferences.edit().putString("reminder:${row.id}", "{broken").commit()
        assertNull(store.reminder(row.id)); assertFalse(store.claim(row, 50_000))
        val scope = store.scope(owner)
        assertTrue(runCatching { store.sync(scope, "c", listOf(row.reminder), "raw-object-id", 0) }.isFailure)
    }
}

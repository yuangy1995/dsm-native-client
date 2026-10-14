package io.github.qwertyuiop1995.dsmnativeclient.chat

import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ChatBatchModelTest {
    @get:Rule val temporary = TemporaryFolder()
    private val owner = WorkspaceOwner("synthetic", "identity", "session")
    private inner class Source : ChatActionSource {
        override val identity = Any()
        override val owner = this@ChatBatchModelTest.owner
        val writes = mutableListOf<String>()
        var reads = 0
        var unknown: String? = null; var rejected: String? = null
        var completeRecovery = false; var changed = false
        override suspend fun prepare(draft: ChatActionDraft, id: String) = ChatPreparedAction(ChatActionCheckpoint(id, draft.kind, draft.channelId, "1",
            messageId = draft.original!!.id, baselineDigest = chatTextDigest(if (changed) "changed" else draft.original.id),
            desiredDigest = chatTextDigest(draft.original.body)), draft)
        override suspend fun execute(prepared: ChatPreparedAction, checkpoint: ChatActionCheckpoint, onProgress: (Long, Long) -> Unit,
            save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome {
            val submitted = checkpoint.copy(phase = ChatActionPhase.SUBMITTED, submittedAtMillis = 10); save(submitted)
            writes += checkpoint.messageId!!
            val next = submitted.copy(phase = when (checkpoint.messageId) { unknown -> ChatActionPhase.SUBMITTED; rejected -> ChatActionPhase.REJECTED; else -> ChatActionPhase.COMPLETED })
            save(next); return ChatActionOutcome(next)
        }
        override suspend fun recover(checkpoint: ChatActionCheckpoint, save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome {
            reads++
            val next = if (completeRecovery) checkpoint.copy(phase = ChatActionPhase.COMPLETED) else checkpoint
            save(next); return ChatActionOutcome(next)
        }
        override suspend fun continueGroup(checkpoint: ChatActionCheckpoint, save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome = error("Not a group")
    }
    private inner class Fixture(val scope: TestScope) {
        val source = Source(); var active: ChatActionSource? = source
        val preferences = MemoryPreferences(); val store = ChatActionStore(preferences)
        val drafts = ChatDraftStore(MemoryPreferences(), temporary.newFolder())
        val workspace = MutableStateFlow<WorkspaceState?>(WorkspaceState(NasProfile("synthetic", "NAS", "https://example.invalid", "user"),
            selectedModule = Module.CHAT, selectedConversation = ChatConversation("11", "Synthetic", ConversationKind.GROUP)))
        val dispatcher = StandardTestDispatcher(scope.testScheduler)
        fun actions() = ChatActionModel(scope, workspace, { active }, { store }, { drafts }, {}, {}, dispatcher)
        val actions = actions()
        fun batch(actions: ChatActionModel = this.actions) = ChatBatchModel(scope, actions, { active }, { drafts }, dispatcher)
        val batch = batch()
        fun values() = (1..3).map { index -> ChatActionDraft(ChatActionKind.DELETE, "11", original = ChatMessage(index.toString(), "11", null, "same text", index.toLong(), true)) }
        fun id() = batch.state.value.items.single().record.id
    }
    @Test fun `整批预检后等待一次明确确认并按原顺序完成`() = runTest {
        val f = Fixture(this); assertTrue(f.batch.request(f.values())); advanceUntilIdle()
        assertTrue(f.source.writes.isEmpty()); assertTrue(f.batch.state.value.items.single().confirmation)
        assertEquals(3, f.store.records(owner).size)
        assertTrue(f.batch.continueBatch(f.id())); advanceUntilIdle()
        assertEquals(listOf("1", "2", "3"), f.source.writes)
        assertTrue(f.actions.state.value.items.all { it.checkpoint!!.phase == ChatActionPhase.COMPLETED })
    }
    @Test fun `同样文字的不同原消息不会错误互斥`() = runTest {
        val f = Fixture(this); f.batch.request(f.values()); advanceUntilIdle()
        assertTrue(f.actions.state.value.items.all { it.failure == null && it.confirmation })
        assertEquals(listOf("1", "2", "3"), f.actions.state.value.items.map { it.checkpoint!!.messageId })
    }
    @Test fun `第二项结果不明停止后续并禁止再次发送`() = runTest {
        val f = Fixture(this); f.source.unknown = "2"
        f.batch.request(f.values()); advanceUntilIdle(); f.batch.continueBatch(f.id()); advanceUntilIdle()
        assertEquals(listOf("1", "2"), f.source.writes)
        assertFalse(f.batch.continueBatch(f.id())); assertFalse(f.batch.discard(f.id()))
        assertEquals(ChatActionPhase.READY, f.actions.state.value.items.last().checkpoint!!.phase)
    }
    @Test fun `只读恢复完成后必须明确继续剩余项且不重放前项`() = runTest {
        val f = Fixture(this); f.source.unknown = "2"
        f.batch.request(f.values()); advanceUntilIdle(); f.batch.continueBatch(f.id()); advanceUntilIdle()
        f.source.completeRecovery = true
        val second = f.actions.state.value.items[1].id
        f.actions.refresh(second); advanceUntilIdle()
        assertEquals(listOf("1", "2"), f.source.writes)
        assertTrue(f.batch.continueBatch(f.id())); advanceUntilIdle()
        assertEquals(listOf("1", "2", "3"), f.source.writes); assertEquals(1, f.source.reads)
    }
    @Test fun `明确拒绝保留失败记录并仅在继续后处理后续`() = runTest {
        val f = Fixture(this); f.source.rejected = "2"
        f.batch.request(f.values()); advanceUntilIdle(); f.batch.continueBatch(f.id()); advanceUntilIdle()
        assertEquals(listOf("1", "2"), f.source.writes)
        assertTrue(f.batch.continueBatch(f.id())); advanceUntilIdle()
        assertEquals(listOf("1", "2", "3"), f.source.writes)
        assertEquals(ChatActionPhase.REJECTED, f.actions.state.value.items[1].checkpoint!!.phase)
    }
    @Test fun `冷启动整批恢复只读且未提交目标正文保留`() = runTest {
        val f = Fixture(this); f.source.unknown = "2"
        f.batch.request(f.values()); advanceUntilIdle(); f.batch.continueBatch(f.id()); advanceUntilIdle()
        f.batch.clear(); f.actions.clear()
        val actions = f.actions(); val batch = f.batch(actions)
        actions.restore(); batch.restore(); advanceUntilIdle()
        assertEquals(listOf("1", "2"), f.source.writes)
        assertEquals(3, actions.state.value.items.size)
        assertEquals("same text", actions.state.value.items.single { it.checkpoint?.messageId == "3" }.draft!!.original!!.body)
        assertFalse(batch.continueBatch(batch.state.value.items.single().record.id))
        f.source.completeRecovery = true
        actions.refresh(actions.state.value.items.single { it.checkpoint?.messageId == "2" }.id); advanceUntilIdle()
        assertTrue(batch.continueBatch(batch.state.value.items.single().record.id)); advanceUntilIdle()
        assertEquals(listOf("1", "2", "3"), f.source.writes)
    }
    @Test fun `冷启动原目标改变后停止而非改为删除新内容`() = runTest {
        val f = Fixture(this); f.batch.request(f.values()); advanceUntilIdle(); f.batch.clear(); f.actions.clear()
        val actions = f.actions(); val batch = f.batch(actions); actions.restore(); batch.restore(); advanceUntilIdle()
        f.source.changed = true
        batch.continueBatch(batch.state.value.items.single().record.id); advanceUntilIdle()
        assertTrue(f.source.writes.isEmpty())
        assertEquals(DsmErrorKind.CHAT_ITEM_CHANGED, actions.state.value.items.single { it.checkpoint?.messageId == "1" }.failure!!.kind)
    }
    @Test fun `取消未提交整批清理本批草稿且没有NAS写入`() = runTest {
        val f = Fixture(this); f.batch.request(f.values()); advanceUntilIdle()
        assertTrue(f.batch.discard(f.id()))
        assertTrue(f.store.records(owner).isEmpty()); assertTrue(f.drafts.actions(owner).isEmpty()); assertTrue(f.drafts.batches(owner).isEmpty())
        assertTrue(f.source.writes.isEmpty())
    }
    @Test fun `同身份重登保留批次不同账号没有记录`() = runTest {
        val f = Fixture(this); f.batch.request(f.values()); advanceUntilIdle()
        assertEquals(1, f.drafts.batches(owner.copy(sessionGeneration = "new")).size)
        assertTrue(f.drafts.batches(owner.copy(identityRevision = "other")).isEmpty())
    }
}

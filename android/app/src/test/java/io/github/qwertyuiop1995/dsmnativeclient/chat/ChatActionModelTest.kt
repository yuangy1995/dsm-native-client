package io.github.qwertyuiop1995.dsmnativeclient.chat

import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class ChatActionModelTest {
    @get:Rule val temporary = TemporaryFolder()
    private val owner = WorkspaceOwner("synthetic", "identity", "session")
    private val channel = ChatConversation("11", "Synthetic", ConversationKind.GROUP)
    private val message = ChatMessage("71", "11", ChatUser("1", "Test", "user", isCurrent = true), "hello", 1, true)
    private fun workspace() = MutableStateFlow<WorkspaceState?>(WorkspaceState(
        NasProfile("synthetic", "NAS", "https://example.invalid", "user"), selectedModule = Module.CHAT,
        selectedConversation = channel, chatDrafts = mapOf("11" to "hello"), chatMessages = Loadable.Ready(ChatMessagePage(emptyList(), null, false))))

    private inner class Source : ChatActionSource {
        override val identity = Any()
        override val owner = this@ChatActionModelTest.owner
        var prepares = 0; var writes = 0; var reads = 0; var groupWrites = 0
        var unknown = false
        var prepareGate: CompletableDeferred<Unit>? = null
        var ignorePrepareCancellation = false
        var writeGate: CompletableDeferred<Unit>? = null
        var onPrepare: () -> Unit = {}
        var receiptWithoutSave = false
        var recoverySeesReceipt = false
        override suspend fun prepare(draft: ChatActionDraft, id: String): ChatPreparedAction {
            prepares++; onPrepare(); if (ignorePrepareCancellation) withContext(NonCancellable) { prepareGate?.await() } else prepareGate?.await()
            return ChatPreparedAction(ChatActionCheckpoint(id, draft.kind, draft.channelId, "1", desiredDigest = chatTextDigest(draft.text)), draft)
        }
        override suspend fun execute(prepared: ChatPreparedAction, checkpoint: ChatActionCheckpoint,
            onProgress: (Long, Long) -> Unit, save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome {
            val submitted = checkpoint.copy(phase = ChatActionPhase.SUBMITTED, submittedAtMillis = 10)
            save(submitted); writes++; writeGate?.await()
            if (receiptWithoutSave) return ChatActionOutcome(submitted.copy(remoteId = "71", acknowledged = true))
            if (unknown) return ChatActionOutcome(submitted)
            val completed = submitted.copy(remoteId = "71", acknowledged = true, phase = ChatActionPhase.COMPLETED)
            save(completed)
            return ChatActionOutcome(completed, message)
        }
        override suspend fun recover(checkpoint: ChatActionCheckpoint, save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome {
            reads++; recoverySeesReceipt = checkpoint.remoteId == "71"
            return ChatActionOutcome(checkpoint)
        }
        override suspend fun continueGroup(checkpoint: ChatActionCheckpoint, save: (ChatActionCheckpoint) -> Unit): ChatActionOutcome {
            groupWrites++; return ChatActionOutcome(checkpoint)
        }
    }
    private inner class Fixture(val scope: TestScope) {
        val prefs = MemoryPreferences(); val store = ChatActionStore(prefs)
        val drafts = ChatDraftStore(MemoryPreferences(), temporary.newFolder())
        val workspace = workspace(); val source = Source(); var active: ChatActionSource? = source
        var changes = 0
        fun model() = ChatActionModel(scope, workspace, { active }, { store }, { drafts }, {}, { changes++ }, StandardTestDispatcher(scope.testScheduler))
        val model = model()
        fun request() = checkNotNull(model.request(ChatActionDraft(ChatActionKind.SEND, "11", text = "hello")))
    }

    @Test fun `预检阶段重复点击不会产生第二次提交`() = runTest {
        val f = Fixture(this); f.source.prepareGate = CompletableDeferred()
        val id = f.request(); runCurrent()
        assertNull(f.model.request(ChatActionDraft(ChatActionKind.SEND, "11", text = "hello")))
        f.source.prepareGate!!.complete(Unit); advanceUntilIdle()
        assertEquals(1, f.source.writes)
        assertEquals(ChatActionPhase.COMPLETED, f.store.get(owner, id).checkpoint.phase)
        assertEquals("71", f.workspace.value!!.chatOutgoingMessages["11"]!!.single().id)
        assertTrue(f.drafts.actions(owner).isEmpty())
    }
    @Test fun `不明结果刷新关闭删除均不能变成重发`() = runTest {
        val f = Fixture(this); f.source.unknown = true
        val id = f.request(); advanceUntilIdle()
        assertFalse(f.model.discard(id)); assertTrue(f.model.dismiss(id)); assertTrue(f.model.refresh(id)); advanceUntilIdle()
        assertEquals(1, f.source.writes); assertEquals(1, f.source.reads)
        assertEquals(ChatActionPhase.SUBMITTED, f.model.state.value.items.single().checkpoint!!.phase)
        assertFalse(f.model.state.value.items.single().canEdit)
        assertEquals("hello", f.drafts.actions(owner).single().text)
    }
    @Test fun `冷启动读取固定编号不自动写入并恢复草稿`() = runTest {
        val f = Fixture(this); f.source.unknown = true
        val id = f.request(); advanceUntilIdle(); f.model.clear()
        f.drafts.saveComposer(owner, "22", "draft in another conversation")
        val restored = f.model(); restored.restore(); advanceUntilIdle()
        assertEquals(1, f.source.writes); assertEquals(1, f.source.reads)
        assertEquals(id, restored.state.value.items.single().id)
        assertEquals("draft in another conversation", f.workspace.value!!.chatDrafts["22"])
        assertEquals("hello", restored.state.value.items.single().draft!!.text)
    }
    @Test fun `回执保存失败保留内存编号并先补存再恢复`() = runTest {
        val f = Fixture(this); f.source.receiptWithoutSave = true
        val id = f.request(); advanceUntilIdle()
        assertNull(f.store.get(owner, id).checkpoint.remoteId)
        assertEquals("71", f.model.state.value.items.single().checkpoint!!.remoteId)
        f.model.refresh(id); advanceUntilIdle()
        assertTrue(f.source.recoverySeesReceipt)
        assertEquals("71", f.store.get(owner, id).checkpoint.remoteId)
        assertEquals(1, f.source.writes)
    }
    @Test fun `写前保存失败不发送`() = runTest {
        val f = Fixture(this); f.source.onPrepare = { f.prefs.commitSucceeds = false }
        f.request(); advanceUntilIdle()
        assertEquals(0, f.source.writes)
        assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, f.model.state.value.items.single().failure!!.kind)
    }
    @Test fun `预检切换会话后保留草稿但不会发送旧目标`() = runTest {
        val f = Fixture(this); f.source.prepareGate = CompletableDeferred()
        f.request(); runCurrent()
        f.workspace.value = f.workspace.value!!.copy(selectedConversation = channel.copy(id = "22"))
        f.source.prepareGate!!.complete(Unit); advanceUntilIdle()
        assertEquals(0, f.source.writes); assertEquals("hello", f.drafts.actions(owner).single().text)
        assertFalse(f.model.state.value.items.single().busy)
    }
    @Test fun `切换账号拒绝旧响应且原草稿不会串号`() = runTest {
        val f = Fixture(this); f.source.prepareGate = CompletableDeferred()
        f.request(); runCurrent(); f.active = null; f.model.clear()
        f.source.prepareGate!!.complete(Unit); advanceUntilIdle()
        assertEquals(0, f.source.writes); assertTrue(f.model.state.value.items.isEmpty())
        assertTrue(f.drafts.actions(owner.copy(identityRevision = "different")).isEmpty())
    }
    @Test fun `取消已开始的写入仍保留待恢复阶段`() = runTest {
        val f = Fixture(this); f.source.writeGate = CompletableDeferred()
        val id = f.request(); runCurrent(); assertEquals(1, f.source.writes)
        f.model.cancel(id); runCurrent()
        assertEquals(ChatActionPhase.SUBMITTED, f.model.state.value.items.single().checkpoint!!.phase)
        assertFalse(f.model.discard(id)); assertTrue(f.model.refresh(id)); advanceUntilIdle()
        assertEquals(1, f.source.writes)
    }
    @Test fun `危险操作等待确认取消不会发出写入`() = runTest {
        val f = Fixture(this)
        val id = checkNotNull(f.model.request(ChatActionDraft(ChatActionKind.DELETE, "11", original = message), confirm = true))
        advanceUntilIdle(); assertTrue(f.model.state.value.items.single().confirmation)
        assertEquals(0, f.source.writes); assertTrue(f.model.cancel(id)); advanceUntilIdle()
        assertTrue(f.store.records(owner).isEmpty()); assertTrue(f.drafts.actions(owner).isEmpty())
    }
    @Test fun `确认只执行一次且新输入不会被原发送清空`() = runTest {
        val f = Fixture(this); f.source.prepareGate = CompletableDeferred()
        val id = f.request(); runCurrent(); f.model.updateComposer("11", "new draft")
        f.source.prepareGate!!.complete(Unit); advanceUntilIdle()
        assertFalse(f.model.confirm(id)); assertEquals(1, f.source.writes)
        assertEquals("new draft", f.workspace.value!!.chatDrafts["11"])
        assertEquals("new draft", f.drafts.composers(owner)["11"])
    }
    @Test fun `未提交草稿冷启动保留而不自动执行`() = runTest {
        val f = Fixture(this); f.source.onPrepare = { error("Synthetic unavailable") }
        val id = f.request(); advanceUntilIdle(); f.model.clear()
        val restored = f.model(); restored.restore(); advanceUntilIdle()
        assertEquals(id, restored.state.value.items.single().id)
        assertTrue(restored.state.value.items.single().canEdit)
        assertEquals(0, f.source.writes)
    }
    @Test fun `仓库实例更换后迟到预检不能提交或污染新模型`() = runTest {
        val f = Fixture(this); f.source.prepareGate = CompletableDeferred()
        f.request(); runCurrent()
        val replacement = Source(); f.active = replacement
        f.source.prepareGate!!.complete(Unit); advanceUntilIdle()
        assertEquals(0, f.source.writes); assertEquals(0, replacement.writes)
        assertTrue(f.store.records(owner).isEmpty())
        val id = f.request(); advanceUntilIdle()
        assertEquals(1, replacement.writes)
        assertEquals(listOf(id), f.model.state.value.items.map { it.id })
    }
    @Test fun `清理后回到相同账号会话仍拒绝旧附件预检代次`() = runTest {
        val f = Fixture(this); f.source.prepareGate = CompletableDeferred(); f.source.ignorePrepareCancellation = true
        val attachment = io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource("synthetic.txt", "text/plain", 9,
            openInputStream = { "synthetic".byteInputStream() })
        val oldId = checkNotNull(f.model.request(ChatActionDraft(ChatActionKind.ATTACHMENT, "11", text = "hello", attachment = attachment)))
        runCurrent(); f.model.clear()
        val replacement = Source(); f.active = replacement
        val newId = f.request(); runCurrent()
        f.source.prepareGate!!.complete(Unit); advanceUntilIdle()
        assertEquals(0, f.source.writes); assertEquals(1, replacement.writes)
        assertEquals(listOf(newId), f.model.state.value.items.map { it.id })
        assertTrue(f.store.records(owner).none { it.checkpoint.id == oldId })
        // 新流程保存私有副本；未提交原草稿留待用户处置，不能借清理模型静默丢失。
        assertEquals(listOf(oldId), f.drafts.actions(owner).map { it.id })
    }

    @Test fun `显示投影使用合法结果并不会把不明阶段显示成功`() = runTest {
        val f = Fixture(this); f.source.unknown = true
        f.request(); advanceUntilIdle()
        val entry = f.model.state.value.presentation(owner.profileId).entries.values.single()
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, entry.mutationResult!!.status)
        assertFalse(entry.mutationRefreshCompleted)
        assertNull(entry.mutationVerification)
    }
}

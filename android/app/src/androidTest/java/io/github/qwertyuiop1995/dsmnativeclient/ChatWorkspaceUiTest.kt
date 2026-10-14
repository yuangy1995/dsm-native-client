package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch

/** 原生界面驱动正式模型、加密草稿和Repository，网络只访问合成拦截器。 */
class ChatWorkspaceUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val previous = profiles.lastProfileId()
    private val profile = NasProfile("chat-ui-" + UUID.randomUUID(), "Synthetic Chat NAS", "https://synthetic.example.invalid", "synthetic")
    private val fixture = ChatWorkspaceFixture()
    private lateinit var model: AppViewModel
    private lateinit var owner: WorkspaceOwner

    @Before fun prepare() {
        val session = DsmSession(profile.id, "synthetic-session")
        owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, session, null, false)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(profile.id, attemptRestore = false)); model = host.active.value.model
            val access = WorkspaceAccessReader(fixture.capabilities, { DesktopAppPrivileges(mapOf(DesktopApplication.CHAT to true), false) },
                { error("Unexpected synthetic fallback") }, {})
            val repo = DsmRepository(profile, session, fixture.api, fixture.capabilities, access)
            runBlocking { repo.refreshAccess() }; repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.SETTINGS))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.CHAT))
        }
        awaitText("Synthetic group")
        compose.onNodeWithText("Synthetic group").performClick()
        compose.waitUntil(10_000) { model.workspace.value?.chatMessages is Loadable.Ready }
        compose.onNodeWithTag("chat_composer").assertIsDisplayed()
    }
    @After fun clean() {
        fixture.searchGate?.countDown()
        if (::model.isInitialized) compose.runOnIdle {
            model.chatVoice.clear(); model.chatBatches.clear(); model.chatActions.clear(); model.chatContent.clear()
        }
        // 等待取消结束后移除本用例专属记录，绝不清理其他工作区。
        compose.waitForIdle()
        ChatDraftStore(app).removeProfile(profile.id); ChatActionStore(app).removeProfile(profile.id)
        profiles.removeProfile(profile.id); profiles.setLastProfileId(previous)
    }

    @Test fun textSendAndMissingReceiptRestoreNeverResend() {
        send("Synthetic sent message")
        awaitAction(ChatActionKind.SEND, ChatActionPhase.COMPLETED)
        assertEquals(1, fixture.writes("create").size)
        fixture.omitReceipt = true
        send("Synthetic missing receipt")
        compose.waitUntil(10_000) { model.chatActions.state.value.items.lastOrNull()?.let { !it.busy && it.checkpoint?.phase == ChatActionPhase.SUBMITTED } == true }
        val original = model.chatActions.state.value.items.last().id
        compose.runOnIdle { model.chatActions.clear(); model.chatActions.restore() }
        compose.waitUntil(10_000) { !model.chatActions.state.value.restoring && model.chatActions.state.value.items.any { it.id == original } }
        compose.runOnIdle { model.chatActions.focus(original) }
        awaitText(text(R.string.chat_action_waiting)); capture("chat-recovery")
        compose.onAllNodesWithText(text(R.string.refresh)).onLast().performScrollTo().performClick()
        compose.waitUntil(10_000) { model.chatActions.state.value.focused?.busy == false }
        assertEquals(ChatActionPhase.SUBMITTED, model.chatActions.state.value.focused!!.checkpoint!!.phase)
        assertEquals(2, fixture.writes("create").size)
        compose.onNodeWithText(text(R.string.chat_action_delayed)).assertExists()
    }

    @Test fun searchLoadingEmptyErrorAndThreadReplyUseActualRequests() {
        options(R.string.chat_search_messages)
        compose.onNodeWithTag("chat_search_query").performTextInput("missing")
        fixture.searchGate = CountDownLatch(1)
        compose.onNodeWithText(text(R.string.chat_search), substring = false).performClick()
        compose.waitUntil(10_000) { model.chatContent.state.value.search == Loadable.Loading }
        capture("chat-search-loading"); fixture.searchGate!!.countDown(); fixture.searchGate = null
        awaitText(text(R.string.chat_search_empty)); capture("chat-search-empty")
        fixture.failSearch = true
        compose.onNodeWithTag("chat_search_query").performTextReplacement("root")
        compose.onNodeWithTag("chat_search_query").performImeAction()
        compose.waitUntil(10_000) { model.chatContent.state.value.search is Loadable.Failed }
        capture("chat-search-error"); fixture.failSearch = false
        compose.onNodeWithText(text(R.string.retry)).performClick()
        awaitText("Synthetic root"); capture("chat-search-results")
        fixture.failThreadRoot = true
        compose.onNodeWithText("Synthetic root").performClick()
        compose.waitUntil(10_000) { model.chatContent.state.value.thread is Loadable.Failed }
        fixture.failThreadRoot = false
        compose.onNodeWithText(text(R.string.retry)).performClick()
        awaitText("Synthetic reply")
        compose.onAllNodesWithTag("chat_composer").onLast().performTextInput("Synthetic new reply")
        compose.onAllNodesWithContentDescription(text(R.string.send_message)).onLast().performClick()
        awaitAction(ChatActionKind.REPLY, ChatActionPhase.COMPLETED)
        assertEquals("71", fixture.writes("create").single()["thread_id"])
        awaitText("Synthetic new reply"); capture("chat-thread")
    }

    @Test fun ownMessageEditPinAndConcreteDeleteConfirmation() {
        messageMenu("73", R.string.chat_edit_message)
        compose.onNodeWithTag("chat_edit_text").performTextReplacement("Synthetic edited message")
        compose.onNodeWithText(text(R.string.save), substring = false).performScrollTo().performClick()
        awaitAction(ChatActionKind.EDIT, ChatActionPhase.COMPLETED); dismissAction()
        messageMenu("73", R.string.chat_pin_message)
        awaitAction(ChatActionKind.PIN, ChatActionPhase.COMPLETED); dismissAction()
        options(R.string.chat_pinned_messages)
        awaitText("Synthetic edited message"); capture("chat-pinned")
        compose.runOnIdle { model.chatContent.close() }
        messageMenu("73", R.string.chat_delete_message)
        compose.waitUntil(10_000) { model.chatActions.state.value.focused?.confirmation == true }
        assertTrue(fixture.writes("delete").isEmpty())
        compose.onNodeWithText(text(R.string.chat_delete_message_warning)).performScrollTo().assertIsDisplayed(); capture("chat-delete-confirmation")
        compose.onNodeWithTag("chat_action_confirm").performScrollTo().performClick()
        awaitAction(ChatActionKind.DELETE, ChatActionPhase.COMPLETED)
        assertEquals("73", fixture.writes("delete").single()["post_id"])
    }

    @Test fun pollChoiceSubmissionAndBatchUnknownStopLaterDeletes() {
        messageMenu("74", R.string.chat_vote)
        compose.onNode(hasText("Synthetic choice B", substring = true) and isToggleable()).performScrollTo().performClick()
        compose.onAllNodesWithText(text(R.string.chat_vote), substring = false).onLast().performScrollTo().performClick()
        awaitAction(ChatActionKind.VOTE, ChatActionPhase.COMPLETED)
        assertEquals("[\"b\"]", fixture.writes("vote").single()["choice_ids"]); dismissAction()
        fixture.ignoreDelete = true
        compose.runOnIdle {
            val messages = (model.workspace.value!!.chatMessages as Loadable.Ready).value.messages.filter { it.id in setOf("71", "73") }
            assertTrue(model.chatBatches.request(messages.map { ChatActionDraft(ChatActionKind.DELETE, "11", original = it) }))
        }
        compose.waitUntil(10_000) { model.chatBatches.state.value.focused?.confirmation == true }
        assertTrue(fixture.writes("delete").isEmpty()); capture("chat-batch-confirmation")
        compose.onNodeWithTag("chat_batch_continue").performScrollTo().performClick()
        compose.waitUntil(10_000) { model.chatBatches.state.value.focused?.busy == false && fixture.writes("delete").size == 1 }
        compose.onNodeWithTag("chat_batch_continue").assertDoesNotExist()
        compose.onNodeWithText(text(R.string.chat_action_delayed)).performScrollTo().assertIsDisplayed(); capture("chat-batch-paused")
        assertEquals(1, fixture.writes("delete").size)
    }

    @Test fun recordedVoicePreviewCancelRemovesLocalDraftAndNeverUploads() {
        InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(app.packageName, android.Manifest.permission.RECORD_AUDIO)
        compose.onNodeWithContentDescription(text(R.string.chat_voice)).performClick()
        compose.waitUntil(10_000) { model.chatVoice.state.value.recording && model.chatVoice.state.value.seconds >= 1 }
        compose.onNodeWithText(text(R.string.chat_voice_stop)).performClick()
        compose.waitUntil(10_000) { model.chatVoice.state.value.draftId != null && !model.chatVoice.state.value.saving }
        val id = model.chatVoice.state.value.draftId!!
        assertNotNull(ChatDraftStore(app).action(owner, id))
        capture("chat-voice-preview")
        compose.onNodeWithText(text(R.string.chat_voice_preview)).performClick()
        compose.waitUntil(10_000) { model.chatVoice.state.value.playing || model.chatVoice.state.value.error != null }
        assertNull(model.chatVoice.state.value.error)
        compose.onNodeWithText(text(R.string.cancel)).performClick()
        compose.waitUntil(10_000) { !model.chatVoice.state.value.visible }
        assertNull(ChatDraftStore(app).action(owner, id)); assertTrue(fixture.writes("create").isEmpty())
    }

    @Test fun selectedConversationsCloseAfterOneConfirmationAndRecordsRemainReachable() {
        compose.runOnIdle { model.closeConversation() }
        compose.onNodeWithText("Synthetic group").performTouchInput { longClick() }
        compose.onNodeWithText(text(R.string.select_item)).performScrollTo().performClick()
        compose.onNodeWithText("Synthetic peer").performClick()
        compose.onNodeWithContentDescription(text(R.string.chat_close_conversation)).performClick()
        compose.waitUntil(10_000) { model.chatBatches.state.value.focused?.confirmation == true }
        assertTrue(fixture.writes("close").isEmpty())
        compose.onNodeWithText(text(R.string.chat_close_conversation_warning)).performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("chat_batch_continue").performScrollTo().performClick()
        compose.waitUntil(10_000) { model.chatBatches.state.value.focused?.busy == false && fixture.writes("close").size == 2 }
        assertEquals(setOf("11", "12"), fixture.writes("close").map { it["channel_id"] }.toSet())
        compose.runOnIdle { model.chatBatches.focus(null) }
        compose.onNodeWithContentDescription(text(R.string.chat_activity)).performClick()
        compose.onNodeWithText(text(R.string.chat_batches)).performScrollTo().performClick()
        compose.waitUntil(10_000) { model.chatBatches.state.value.focusedId == "all" }
        capture("chat-closed-conversation-records")
    }

    private fun text(id: Int) = compose.activity.getString(id)
    private fun awaitText(value: String) { compose.waitUntil(10_000) { compose.onAllNodesWithText(value).fetchSemanticsNodes().isNotEmpty() } }
    private fun send(body: String) { compose.onNodeWithTag("chat_composer").performTextInput(body); compose.onNodeWithContentDescription(text(R.string.send_message)).performClick() }
    private fun awaitAction(kind: ChatActionKind, phase: ChatActionPhase) {
        compose.waitUntil(10_000) { model.chatActions.state.value.items.lastOrNull { it.kind == kind }?.let { !it.busy && it.checkpoint?.phase == phase } == true }
    }
    private fun dismissAction() { compose.onNodeWithText(text(R.string.close), substring = false).performScrollTo().performClick() }
    private fun options(resource: Int) { compose.onNodeWithContentDescription(text(R.string.client_conversation_options)).performClick(); compose.onNodeWithText(text(resource), substring = false).performScrollTo().performClick() }
    private fun messageMenu(id: String, resource: Int) {
        compose.onNodeWithTag("chat_message_options_$id").performScrollTo().performClick()
        compose.onNodeWithText(text(resource), substring = false).performScrollTo().performClick()
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val file = File(app.getExternalFilesDir(null), "chat-review/$name.png")
        file.parentFile?.mkdirs(); file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}

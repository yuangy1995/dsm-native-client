package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.WorkManager
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.systemfiles.*
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.util.concurrent.TimeUnit

/** 正式 Activity、系统接收 Intent、加密草稿和私有 provider；远端仅合成只读目录。 */
class SharedInputUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val previous = profiles.lastProfileId()
    private val store = SharedInputStore(app)
    private val transfers = TransferStore(app)
    private val fixture = SystemFileFixture()
    private lateinit var host: WorkspaceHostModel
    private lateinit var owner: WorkspaceOwner
    private val sourceAuthority = SynologyPhotoExportTestProvider.AUTHORITY
    private val sourceRoot = DocumentsContract.buildDocumentUri(sourceAuthority, "root")
    @Before fun prepare() {
        app.contentResolver.call(sourceAuthority, "reset", null, null)
        owner = profiles.commitConnection(profiles.connectionAttempt(fixture.profile.id), fixture.profile, fixture.session, null, false, persistSession = true)
        compose.runOnIdle {
            host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(fixture.profile.id, attemptRestore = false))
            val model = host.active.value.model
            val repo = fixture.repository(owner) { profiles.requireCurrentOwner(owner) }
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(fixture.profile, availability = repo.availability(), selectedModule = Module.SETTINGS))
        }
    }
    @After fun cleanup() {
        transfers.uploads(fixture.profile.id).forEach { row -> row.workId?.let {
            WorkManager.getInstance(app).cancelWorkById(java.util.UUID.fromString(it)).result.get(10, TimeUnit.SECONDS)
        } }
        store.batches().forEach { if (transfers.sharedUploadBatchExists(it.id)) store.handedOff(it) else store.discard(it) }
        transfers.removeProfile(fixture.profile.id); store.reconcile(transfers)
        profiles.removeProfile(fixture.profile.id); profiles.setLastProfileId(previous)
        app.contentResolver.call(sourceAuthority, "reset", null, null)
    }
    private fun sharedFile(name: String = "shared.txt"): Uri = requireNotNull(DocumentsContract.createDocument(app.contentResolver, sourceRoot, "text/plain", name)).also {
        app.contentResolver.openOutputStream(it, "wt")!!.use { output -> output.write("synthetic-content".toByteArray()) }
    }
    private fun deliver(intent: Intent) = compose.runOnIdle {
        compose.activity.startActivity(intent.setClass(app, MainActivity::class.java).addCategory(Intent.CATEGORY_LAUNCHER).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP))
    }
    private fun sendIntent(uri: Uri) = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_STREAM, uri)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).apply { clipData = ClipData.newRawUri("synthetic", uri) }
    private fun awaitDraft() { compose.waitUntil(10_000) { !host.sharedInput.state.value.copying && host.sharedInput.state.value.batch != null }; compose.waitForIdle() }
    private fun click(resource: Int) = compose.onAllNodesWithText(compose.activity.getString(resource)).filter(isEnabled()).onLast().performClick()
    private fun chooseFolder() {
        compose.onNode(hasText(fixture.profile.name) and hasAnyAncestor(hasTestTag("shared_connections"))).performClick()
        compose.waitUntil(10_000) { host.sharedInput.state.value.locations is Loadable.Ready }
        compose.onNodeWithText("share", useUnmergedTree = true).performClick()
        compose.waitUntil(10_000) { host.sharedInput.state.value.folder?.path == "/share" && host.sharedInput.state.value.locations is Loadable.Ready }
    }
    @Test fun externalFileIsCopiedThroughBinderAndPrivateSourceSurvivesOriginalDeletionAndRecreation() {
        val uri = sharedFile(); val intent = sendIntent(uri); deliver(intent); awaitDraft()
        assertEquals(Intent.ACTION_MAIN, compose.activity.intent.action); assertNull(compose.activity.intent.clipData); assertFalse(compose.activity.intent.hasExtra(Intent.EXTRA_STREAM))
        val row = host.sharedInput.state.value.batch!!.files.single(); val local = Uri.parse(store.uri(row.id))
        DocumentsContract.deleteDocument(app.contentResolver, uri)
        assertEquals("synthetic-content", app.contentResolver.openInputStream(local)!!.bufferedReader().use { it.readText() })
        assertEquals("text/plain", app.contentResolver.getType(local))
        val info = app.packageManager.resolveContentProvider(local.authority!!, 0)!!
        assertFalse(info.exported); assertFalse(info.grantUriPermissions)
        try { app.contentResolver.openFileDescriptor(local, "rw"); fail("Internal copy must be read only") } catch (_: java.io.FileNotFoundException) { }
        compose.activityRule.scenario.recreate()
        compose.onNodeWithText("shared.txt", substring = true).assertIsDisplayed()
        capture("received"); compose.onNodeWithTag("shared_discard").performClick()
        compose.waitUntil(10_000) { store.batches().isEmpty() }; assertFalse(store.file(row.id).exists())
    }
    @Test fun textShareRetainsDraftAndExplicitSelectionCreatesOwnedBackgroundTask() {
        deliver(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "Synthetic shared text")); awaitDraft()
        val row = host.sharedInput.state.value.batch!!.files.single()
        chooseFolder(); capture("destination"); compose.onNodeWithTag("shared_send").assertIsEnabled().performClick()
        compose.waitUntil(10_000) { transfers.upload(row.id)?.workId != null && !host.sharedInput.state.value.busy }
        val task = transfers.upload(row.id)!!; assertEquals(owner, profiles.recordOwner(WorkspaceRecordKind.UPLOAD, row.id))
        assertEquals("/share", task.destinationPath); assertFalse(task.overwrite); assertFalse(task.backupMode)
        assertFalse(task.ownsPersistedReadGrant); assertEquals("Synthetic shared text", app.contentResolver.openInputStream(Uri.parse(task.sourceUri))!!.bufferedReader().use { it.readText() })
        assertTrue(store.batches().isEmpty()); assertEquals(1, transfers.uploads(fixture.profile.id).size)
    }
    @Test fun conflictConfirmationCanBeCancelledAndPermissionLossKeepsReceivedFiles() {
        fixture.entries["/share/shared.txt"] = SystemFileFixture.item("/share/shared.txt")
        deliver(sendIntent(sharedFile())); awaitDraft(); chooseFolder(); compose.onNodeWithTag("shared_send").performClick()
        compose.waitUntil(10_000) { host.sharedInput.state.value.conflicts != null && !host.sharedInput.state.value.busy }
        capture("conflict"); click(R.string.cancel); assertTrue(transfers.uploads(fixture.profile.id).isEmpty())
        compose.runOnIdle { profiles.signOut(owner); host.sharedInput.connectionChanged() }
        compose.onNodeWithTag("shared_send").assertIsNotEnabled(); assertNotNull(host.sharedInput.state.value.batch)
        capture("revoked")
    }
    @Test fun multipleStreamsDeduplicateAndMissingGrantOrInternalUriAreRefused() {
        val first = sharedFile("one.txt"); val second = sharedFile("two.txt")
        val intent = Intent(Intent.ACTION_SEND_MULTIPLE).setType("text/plain")
            .putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(first, second, first))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        deliver(intent); awaitDraft(); assertEquals(2, host.sharedInput.state.value.batch!!.files.size)
        val local = Uri.parse(store.uri(host.sharedInput.state.value.batch!!.files.first().id))
        for (bad in listOf(sendIntent(local), Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, first),
            sendIntent(Uri.parse("file:///private/synthetic.txt")))) {
            try { bad.sharedInput(app.packageName); fail("Unsafe source accepted") } catch (_: IllegalArgumentException) { }
        }
        assertTrue(fixture.calls.isEmpty()); assertTrue(transfers.uploads(fixture.profile.id).isEmpty())
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        val rendered = java.util.concurrent.CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync { compose.activity.window.decorView.postOnAnimation {
            compose.activity.window.decorView.postOnAnimation { rendered.countDown() }
        } }
        check(rendered.await(2, TimeUnit.SECONDS))
        val directory = File(app.getExternalFilesDir(null), "system-share-review").apply { mkdirs() }
        val config = compose.activity.resources.configuration
        File(directory, "configuration.txt").writeText("locales=${config.locales.toLanguageTags()}\nfontScale=${config.fontScale}\nuiMode=${config.uiMode}\nwidthDp=${config.screenWidthDp}\nheightDp=${config.screenHeightDp}\n")
        InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()?.let { bitmap ->
            File(directory, "$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        }
    }
}

package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.containers.*
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** 正式 Activity、工作区归属、加密记录、请求编码与页面交互；只替换远端响应为合成数据。 */
class ContainerWorkspaceUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val previous = profiles.lastProfileId()
    private val fixture = ContainerFixture()
    private val profile = fixture.profile
    private lateinit var model: AppViewModel
    private lateinit var owner: WorkspaceOwner

    @Before fun prepare() {
        val session = DsmSession(profile.id, "synthetic-session")
        owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, session, null, false)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(profile.id, attemptRestore = false)); model = host.active.value.model
            val caps = fixture.capabilities()
            val repo = DsmRepository(profile, session, DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(fixture).build()), caps, fixture.reader(caps))
            runBlocking { repo.refreshAccess() }; repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.SETTINGS, supportsContainerRegistry = true))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.CONTAINERS))
        }
        ready(); awaitText(text(R.string.images))
        if (captureEnabled()) {
            val c = compose.activity.resources.configuration
            File(app.getExternalFilesDir(null), "container-review/configuration.txt").also { it.parentFile?.mkdirs() }
                .writeText("locales=${c.locales.toLanguageTags()}\nfontScale=${c.fontScale}\nuiMode=${c.uiMode}\nwidthDp=${c.screenWidthDp}\nheightDp=${c.screenHeightDp}\n")
        }
    }
    @After fun clean() {
        if (::model.isInitialized) compose.runOnIdle { model.containerControls.clear(); model.containerImages.clear(); model.containerNetworks.clear(); model.stopContainerEvents() }
        compose.waitForIdle()
        ContainerControlStore(app).removeProfile(profile.id); ContainerImageStore(app).removeProfile(profile.id); ContainerNetworkStore(app).removeProfile(profile.id)
        profiles.removeProfile(profile.id); profiles.setLastProfileId(previous)
    }

    @Test fun controlConfirmCancelStartRestartStopDeleteRoundTrip() {
        click(R.string.containers); awaitControls(); detail("Synthetic container")
        click(R.string.cm_start); capture("control-confirmation"); click(R.string.cancel)
        assertTrue(fixture.writes.isEmpty())
        control(R.string.cm_start); awaitControlDone(); assertEquals("start", fixture.writes.single().method)
        capture("control-started"); control(R.string.cm_restart); awaitControlDone()
        control(R.string.cm_stop); awaitControlDone(); control(R.string.cm_delete); awaitControlDone()
        assertEquals(listOf("start", "restart", "stop", "delete"), fixture.writes.map { it.method })
        assertEquals(JsonPrimitive(false), fixture.writes.last().fields["force"])
        assertEquals(JsonPrimitive(false), fixture.writes.last().fields["preserve_profile"])
        awaitText(text(R.string.cm_empty)); capture("control-deleted")
        assertTrue(fixture.writes.all { it.oneShot })
    }
    @Test fun batchStopsAtUnknownAndColdRestoreOnlyReads() {
        fixture.controls = listOf(ContainerFixture.control(), ContainerFixture.control("second-id", "Synthetic second"))
        click(R.string.containers); awaitControls()
        compose.onNodeWithContentDescription("Synthetic container").performClick()
        compose.onNodeWithContentDescription("Synthetic second").performClick()
        click(R.string.cm_start); fixture.before = { if (it.method == "start") throw IOException("Synthetic lost receipt") }
        click(R.string.cm_start)
        await { model.containerControls.state.value.let { !it.busy && it.record?.pending == true } }
        assertEquals(listOf(ContainerStage.SUBMITTED, ContainerStage.CANCELLED), model.containerControls.state.value.record!!.items.map { it.stage })
        capture("control-unknown")
        fixture.before = {}; compose.runOnIdle { model.containerControls.clear(); model.containerControls.refresh() }
        awaitControls(); assertTrue(model.containerControls.state.value.blocked)
        detail("Synthetic container"); button(R.string.cm_start).assertIsNotEnabled()
        assertEquals(1, fixture.writes.size); capture("control-restored")
    }
    @Test fun registryDownloadCancelThenOriginalTaskCompletesAndRefreshesOverview() {
        fixture.images = emptyList(); fixture.pullFinished = JsonPrimitive(false)
        click(R.string.images); awaitImages(); click(R.string.search_images)
        field(R.string.image_name).performTextInput("synthetic"); click(R.string.search_images)
        awaitText("synthetic/image"); detail("synthetic/image"); awaitText("stable")
        tagDownload("stable"); awaitText(text(R.string.cm_image_download_risk)); capture("image-download-confirmation")
        click(R.string.cancel); assertTrue(fixture.writes.isEmpty())
        click(R.string.search_images); awaitText("synthetic/image"); detail("synthetic/image"); awaitText("stable"); tagDownload("stable")
        click(R.string.cm_image_download)
        await { model.containerImages.state.value.let { !it.busy && it.activities.singleOrNull()?.stage == ContainerStage.ACCEPTED } }
        capture("image-downloading"); fixture.pullFinished = JsonPrimitive(true)
        await { model.containerImages.state.value.activities.singleOrNull()?.stage == ContainerStage.VERIFIED }
        ready(); awaitImages(); awaitText("synthetic/image:stable"); capture("image-available")
        assertEquals(1, fixture.writes.size); assertEquals("pull_start", fixture.writes.single().method)
        assertEquals(1, (model.workspace.value!!.containers as Loadable.Ready).value.images.size)
    }
    @Test fun imageDeletionKeepsOtherTagsAndProtectsUsedImage() {
        fixture.images = listOf(ContainerFixture.image(tags = listOf("stable", "latest")), ContainerFixture.image("used-id", "synthetic/other"))
        click(R.string.images); awaitImages(); detail("synthetic/other:stable")
        button(R.string.cm_image_delete).assertIsNotEnabled(); closeSheet()
        detail("synthetic/image:stable"); click(R.string.cm_image_delete); click(R.string.cancel)
        assertTrue(fixture.writes.isEmpty()); detail("synthetic/image:stable"); click(R.string.cm_image_delete); capture("image-delete-confirmation"); click(R.string.cm_image_delete)
        await { model.containerImages.state.value.let { !it.busy && it.activities.singleOrNull()?.stage == ContainerStage.VERIFIED } }; ready(); awaitImages()
        awaitText("synthetic/image:latest")
        assertEquals(JsonArray(listOf(JsonPrimitive("stable"))), fixture.writes.single().fields.getValue("images").jsonArray.single().jsonObject["tags"])
        assertEquals(2, model.containerImages.state.value.images.size); capture("image-tag-preserved")
    }
    @Test fun manualNetworkFormCancelCreateAndDeleteWithExactParameters() {
        click(R.string.networks); awaitNetworks(); click(R.string.cm_network_create)
        field(R.string.cm_network_name).performTextInput("Synthetic-manual")
        click(R.string.cm_network_manual_ipv4)
        field(R.string.cm_network_subnet).performTextInput("192.0.2.0/24")
        field(R.string.cm_network_range).performTextInput("192.0.2.0/25")
        field(R.string.cm_network_gateway).performTextInput("192.0.2.1")
        click(R.string.cm_network_ipv6)
        field(R.string.cm_network_ipv6_subnet).performScrollTo().performTextInput("2001:db8::/64")
        field(R.string.cm_network_ipv6_range).performScrollTo().performTextInput("2001:db8::/80")
        field(R.string.cm_network_ipv6_gateway).performScrollTo().performTextInput("2001:db8::1")
        click(R.string.cm_network_disable_masquerade); click(R.string.continue_action)
        capture("network-confirmation"); click(R.string.cancel); assertTrue(fixture.writes.isEmpty())
        click(R.string.continue_action); click(R.string.cm_network_create)
        await { model.containerNetworks.state.value.let { !it.busy && it.activities.singleOrNull()?.pending == false } }; ready(); awaitNetworks()
        awaitText("Synthetic-manual"); assertEquals(JsonPrimitive(true), fixture.writes.single().fields["enable_ipv6"])
        assertEquals(JsonPrimitive("2001:db8::1"), fixture.writes.single().fields["ipv6_gateway"])
        assertEquals(JsonPrimitive(true), fixture.writes.single().fields["disable_masquerade"])
        capture("network-created"); detail("Synthetic-manual"); click(R.string.cm_network_delete); click(R.string.cm_network_delete)
        await { model.containerNetworks.state.value.let { !it.busy && it.activities.size == 2 && it.activities.none { row -> row.pending } } }
        assertEquals(listOf("create", "remove"), fixture.writes.map { it.method }); capture("network-deleted")
    }
    @Test fun defaultNetworkAndMissingCreateReceiptRemainProtected() {
        fixture.networks = listOf(ContainerFixture.network(name = "bridge"))
        click(R.string.networks); awaitNetworks(); detail("bridge")
        button(R.string.cm_network_delete).assertIsNotEnabled(); closeSheet()
        click(R.string.cm_network_create); field(R.string.cm_network_name).performTextInput("Synthetic-unknown"); click(R.string.continue_action)
        fixture.after = { if (it.api == "SYNO.Docker.Network" && it.method == "create") throw IOException("Synthetic lost receipt") }
        click(R.string.cm_network_create)
        await { model.containerNetworks.state.value.let { !it.busy && it.activities.singleOrNull()?.pending == true } }
        fixture.after = {}; compose.runOnIdle { model.containerNetworks.clear(); model.containerNetworks.refresh() }; awaitNetworks()
        assertFalse(model.containerNetworks.state.value.activities.single().pending)
        assertFalse(model.containerNetworks.state.value.activities.single().items.single().accepted)
        awaitText("Synthetic-unknown"); capture("network-existing-after-unknown")
        assertEquals(1, fixture.writes.size); assertFalse(fixture.writes.single().fields.containsKey("subnet"))
    }
    @Test fun projectsAndLazyEventsShowActualDataAndFilterWithoutWrites() {
        fixture.projects = ContainerFixture.obj("""{"project-id":{"name":"Synthetic project","status":"running","containerIds":["synthetic-id"]}}""")
        fixture.logs = listOf(ContainerFixture.obj("""{"event":"Synthetic event","user":"Synthetic user","level":"info","time":"2026/10/14 09:10:11"}"""))
        compose.runOnIdle { model.load(Module.CONTAINERS) }; ready()
        assertFalse(fixture.calls.any { it.api == "SYNO.Docker.Log" })
        click(R.string.projects); detail("Synthetic project"); awaitText(text(R.string.running)); capture("project-details"); click(R.string.close)
        compose.onAllNodesWithContentDescription(text(R.string.go_up)).onFirst().performClick(); click(R.string.events)
        awaitText("Synthetic event"); capture("events")
        compose.onNode(hasSetTextAction()).performTextInput("no-matching-synthetic-event")
        awaitText(text(R.string.no_matching_log_entries)); capture("events-filter-empty")
        assertTrue(fixture.calls.any { it.api == "SYNO.Docker.Log" && it.method == "list" }); assertTrue(fixture.writes.isEmpty())
    }

    private fun ready() = await { model.workspace.value?.containers is Loadable.Ready }
    private fun awaitControls() = await { model.containerControls.state.value.let { it.loaded && !it.busy } }
    private fun awaitImages() = await { model.containerImages.state.value.let { it.loaded && !it.busy } }
    private fun awaitNetworks() = await { model.containerNetworks.state.value.let { it.loaded && !it.busy } }
    private fun awaitControlDone() { await { model.containerControls.state.value.let { !it.busy && it.record?.pending == false } }; ready(); awaitControls() }
    private fun text(id: Int) = compose.activity.getString(id)
    private fun field(id: Int) = compose.onNode(hasText(text(id)) and hasSetTextAction())
    private fun await(predicate: () -> Boolean) = compose.waitUntil(15_000, predicate)
    private fun awaitText(value: String) = await { compose.onAllNodesWithText(value).fetchSemanticsNodes().isNotEmpty() }
    private fun button(id: Int) = compose.onAllNodes(hasText(text(id)) and hasClickAction() and !hasText(profile.name)).onLast()
    private fun click(id: Int) { val node = button(id); scroll(node); node.assertIsDisplayed().performClick() }
    private fun detail(name: String) { val node = compose.onNode(hasText(name) and hasClickAction()); scroll(node); node.performClick() }
    private fun closeSheet() = compose.onNodeWithContentDescription(text(R.string.close)).performClick()
    private fun control(id: Int) { detail("Synthetic container"); click(id); click(id) }
    private fun tagDownload(tag: String) {
        compose.onNode(hasText(text(R.string.cm_image_download)) and hasClickAction() and hasAnyAncestor(hasText(tag))).performScrollTo().performClick()
    }
    private fun scroll(node: SemanticsNodeInteraction) {
        var parent = node.fetchSemanticsNode().parent; var scrollable = false
        while (parent != null) { if (parent.config.contains(SemanticsActions.ScrollBy)) scrollable = true; parent = parent.parent }
        if (scrollable) node.performScrollTo()
    }
    private fun captureEnabled() = InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") == "true"
    private fun capture(name: String) {
        if (!captureEnabled()) return
        // 面板替换时同时等待 Compose 动画和独立窗口呈现，不能把旧背景截图当作确认页。
        compose.mainClock.advanceTimeBy(600)
        compose.waitForIdle()
        InstrumentationRegistry.getInstrumentation().uiAutomation.waitForIdle(200, 3_000)
        val rendered = CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            compose.activity.window.decorView.postOnAnimation { compose.activity.window.decorView.postOnAnimation { rendered.countDown() } }
        }
        check(rendered.await(2, TimeUnit.SECONDS)); InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        File(app.getExternalFilesDir(null), "container-review/$name.png").also { it.parentFile?.mkdirs() }.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }
}

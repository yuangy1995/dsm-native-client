package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.FileVFSFixture
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.net.Socket
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class FileVFSFeatureModelTest {
    private val fixture = FileVFSFixture()
    private var active: DsmRepository? = fixture.repository
    private var workspace = WorkspaceState(fixture.nas, availability = fixture.repository.availability(), selectedModule = Module.FILES)
    private fun model(scope: CoroutineScope) = FileVFSFeatureModel(scope, { active }, { workspace }, { workspace = workspace.copy(isPerformingAction = it) })
    private suspend fun ready(value: FileVFSFeatureModel) = await { value.state.value.inventory is Loadable.Ready && value.state.value.recoveryReadable }
    private suspend fun await(block: () -> Boolean) = withTimeout(5000) { while (!block()) delay(5) }
    @Test fun managerUsesDynamicProtocolsAndEmptyErrorRetryRemainDistinct() = runBlocking {
        val value = model(this); fixture.profiles = emptyList(); fixture.profileFailure = true
        assertTrue(value.openManager()); await { value.state.value.inventory is Loadable.Failed }; assertFalse(value.canManage())
        fixture.profileFailure = false; value.reload(); ready(value)
        assertTrue((value.state.value.inventory as Loadable.Ready).value.profiles.isEmpty())
        assertTrue(value.options().any { it.id == "ftp" && !it.hasConnections }); assertTrue(value.canManage())
        value.openEditor(); assertEquals("ftp", value.state.value.setup.protocolId); value.invalidate()
    }
    @Test fun cleartextRequiresConcreteConfirmationAndUpdateDoesNotReplacePassword() = runBlocking {
        val value = model(this); value.openManager(); ready(value); value.openEditor()
        value.edit { it.copy(hostname = "new.invalid", alias = "New FTP", account = "synthetic") }
        assertFalse(value.save("synthetic-secret")); assertTrue(value.state.value.cleartextConfirmation); assertTrue(fixture.writes().isEmpty())
        value.edit { it.copy(alias = "Changed FTP") }; assertFalse(value.state.value.cleartextConfirmation)
        assertFalse(value.save("synthetic-secret", true)); assertTrue(fixture.writes().isEmpty())
        assertFalse(value.save("synthetic-secret")); assertTrue(value.save("synthetic-secret", true))
        await { !value.state.value.busy && value.state.value.outcome != null }
        assertEquals(FileVFSOutcomeStatus.COMPLETED, value.state.value.outcome?.status); assertEquals(2, fixture.writes().size)
        value.backToManager(); ready(value)
        val saved = (value.state.value.inventory as Loadable.Ready).value.profiles.single()
        value.openEditor(saved); await { value.state.value.detail is Loadable.Ready }
        assertFalse(value.canSave(false)); value.edit { it.copy(alias = "Renamed") }; assertTrue(value.canSave(false))
        assertFalse(value.save(null)); assertTrue(value.save(null, true)); await { !value.state.value.busy }
        assertEquals(4, fixture.writes().size); assertFalse(fixture.writes().takeLast(2).any { "password" in it })
        value.invalidate()
    }
    @Test fun connectDisconnectAndRemoveRequireOriginalSavedItemAndNeverDeleteFiles() = runBlocking {
        val value = model(this); value.openManager(); ready(value)
        value.openAction(FileVFSChange.RemoveSaved(fixture.original)); assertEquals(FileVFSScreen.MANAGER, value.state.value.screen)
        value.openAction(FileVFSChange.Disconnect(fixture.original)); value.submitAction(); value.submitAction()
        await { !value.state.value.busy && value.state.value.outcome != null }; assertEquals(1, fixture.writes().size)
        value.backToManager(); ready(value); val saved = (value.state.value.inventory as Loadable.Ready).value.profiles.single()
        value.openAction(FileVFSChange.RemoveSaved(saved)); value.submitAction(); await { !value.state.value.busy }
        assertTrue(fixture.profiles.isEmpty()); assertEquals(2, fixture.writes().size)
        assertTrue(fixture.calls.none { it["api"] == "SYNO.FileStation.Delete" }); value.invalidate()
    }
    @Test fun unknownCompoundWritesSurviveReopenAndReviewNeverReplays() = runBlocking {
        val value = model(this); fixture.profiles = emptyList(); fixture.applyWrites = false
        value.openManager(); ready(value); value.openEditor(); value.protocol("davs")
        value.edit { it.copy(hostname = "new.invalid", alias = "New", port = 443) }; assertTrue(value.save("synthetic"))
        await { !value.state.value.busy && value.state.value.screen == FileVFSScreen.RECOVERY }
        assertEquals(FileVFSOutcomeStatus.UNKNOWN, value.state.value.outcome?.status); assertEquals(2, fixture.writes().size)
        value.close(); value.openManager(); ready(value); assertFalse(value.canManage())
        value.openRecovery(value.state.value.pending.single()); value.review(); await { !value.state.value.busy }
        assertEquals(2, fixture.writes().size); assertEquals(FileVFSOutcomeStatus.UNKNOWN, value.state.value.outcome?.status); value.invalidate()
    }
    @Test fun folderPaginationRejectsChangedSnapshotAndDownloadBindsRawOriginalSource() = runBlocking {
        val value = model(this); value.openManager(); ready(value)
        fixture.children = { path, offset -> FilePage(listOf(FileItem(path + "/part-$offset", "part-$offset", false, 8, 10)), 2, offset) }
        value.browse(fixture.original); await { value.state.value.files is Loadable.Ready }
        value.loadFolder(true); await { !value.state.value.loadingMore }
        val files = (value.state.value.files as Loadable.Ready).value.items; assertEquals(2, files.size)
        val source = value.downloadSource(files.last())!!
        assertEquals(fixture.original, source.profile); assertEquals(fixture.original.uri, source.parent); assertEquals(files.last().path, source.path)
        assertNull(value.downloadSource(files.last().copy(path = "davs://other/file")))
        fixture.profiles = listOf(fixture.original.copy(account = "another-account")); value.loadFolder()
        await { value.state.value.files is Loadable.Failed }; assertNull(value.downloadSource(files.last())); value.invalidate()
    }
    @Test fun accountAndPermissionChangesInvalidateEditorsAndRejectLateReads() = runBlocking {
        val value = model(this); value.openManager(); ready(value); value.openEditor()
        fixture.allowed = false; fixture.repository.refreshAccess(); value.authorizationChanged()
        assertNull(value.state.value.screen); assertFalse(value.save("secret")); assertTrue(fixture.writes().isEmpty())
        fixture.allowed = true; fixture.repository.refreshAccess(); value.openManager(); ready(value)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { fields -> if (fields["api"] == "SYNO.FileStation.List") { entered.countDown(); release.await(5, TimeUnit.SECONDS) } }
        value.browse(fixture.original); withContext(Dispatchers.IO) { assertTrue(entered.await(5, TimeUnit.SECONDS)) }
        active = null; value.invalidate(); release.countDown()
        coroutineContext[Job]!!.children.toList().forEach { it.join() }
        assertNull(value.state.value.screen); assertTrue(fixture.writes().isEmpty())
    }
    @Test fun cloudCallbackOnlyEnablesExplicitSaveAndTokensNeverEnterRecovery() = runBlocking {
        val value = model(this); fixture.profiles = emptyList(); value.openManager(); ready(value); value.openCloud("google")
        value.startAuthorization("Done", "Failed"); await { value.state.value.cloudWaiting }
        val url = value.state.value.browserUrl!!; sendAuthorization(url, "synthetic-cloud")
        await { value.state.value.authorizedAccount != null }; assertTrue(value.canSaveCloud()); assertTrue(fixture.writes().isEmpty())
        value.saveCloud(); value.saveCloud(); await { !value.state.value.busy && value.state.value.outcome != null }
        assertEquals(2, fixture.writes().size); assertEquals(FileVFSOutcomeStatus.COMPLETED, value.state.value.outcome?.status)
        assertNull(value.state.value.authorizedAccount); assertFalse(value.canSaveCloud())
        assertFalse(fixture.preferences.all.values.joinToString().contains("synthetic-token")); value.invalidate()
    }
    @Test fun cancelledCloudListenerAndWrongAccountCannotAuthorizeSavedConnection() = runBlocking {
        val cloud = fixture.original.copy(protocolId = "google", uri = "google://opaque-cloud/root", account = "original-account")
        fixture.profiles = listOf(cloud); val value = model(this); value.openManager(); ready(value); value.openCloud("google", cloud)
        value.startAuthorization("Done", "Failed"); await { value.state.value.cloudWaiting }
        sendAuthorization(value.state.value.browserUrl!!, "another-account"); await { value.state.value.failure != null }
        assertFalse(value.canSaveCloud()); assertNull(value.state.value.authorizedAccount); assertTrue(fixture.writes().isEmpty())
        value.startAuthorization("Done", "Failed"); await { value.state.value.cloudWaiting }
        val callback = callback(value.state.value.browserUrl!!); value.cancelAuthorization()
        assertFalse(value.state.value.cloudWaiting); assertFalse(value.canSaveCloud())
        assertTrue(withContext(Dispatchers.IO) { runCatching { Socket(callback.host, callback.port).close() }.isFailure })
        value.invalidate()
    }
    @Test fun browserFailureClosesAttemptAndDoesNotReportNasCapabilityFailure() = runBlocking {
        val value = model(this); fixture.profiles = emptyList(); value.openManager(); ready(value); value.openCloud("google")
        value.startAuthorization("Done", "Failed"); await { value.state.value.cloudWaiting }
        val callback = callback(value.state.value.browserUrl!!); value.browserFailed()
        assertEquals(DsmErrorKind.FILE_VFS_AUTHORIZATION_FAILED, value.state.value.failure?.kind)
        assertNull(value.state.value.browserUrl); assertFalse(value.canSaveCloud()); assertTrue(fixture.writes().isEmpty())
        assertTrue(withContext(Dispatchers.IO) { runCatching { Socket(callback.host, callback.port).close() }.isFailure })
        value.invalidate()
    }
    @Test fun lateOperationFromPreviousAccountCannotClearNewCloudAttempt() = runBlocking {
        val value = model(this); value.openManager(); ready(value)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { fields -> if (fields["api"] == "SYNO.FileStation.VFS.Connection" && fields["method"] == "delete") {
            entered.countDown(); release.await(5, TimeUnit.SECONDS)
        } }
        value.openAction(FileVFSChange.Disconnect(fixture.original)); value.submitAction()
        withContext(Dispatchers.IO) { assertTrue(entered.await(5, TimeUnit.SECONDS)) }
        val other = FileVFSFixture("vfs-other-account"); active = other.repository
        workspace = WorkspaceState(other.nas, availability = other.repository.availability(), selectedModule = Module.FILES)
        value.invalidate(); assertTrue(value.openManager()); ready(value); value.openCloud("google")
        value.startAuthorization("Done", "Failed"); await { value.state.value.cloudWaiting }
        val url = value.state.value.browserUrl; release.countDown()
        await { fixture.profiles.single().state == FileVFSConnectionState.DISCONNECTED }
        delay(100)
        assertEquals(FileVFSScreen.CLOUD, value.state.value.screen); assertEquals(url, value.state.value.browserUrl)
        assertTrue(value.state.value.cloudWaiting); assertTrue(other.writes().isEmpty()); value.invalidate()
    }
    private fun fields(url: String) = URI(url).rawQuery.split('&').associate { it.substringBefore('=') to URLDecoder.decode(it.substringAfter('='), "UTF-8") }
    private fun callback(url: String) = URI(fields(url).getValue("host"))
    private suspend fun sendAuthorization(url: String, account: String) = withContext(Dispatchers.IO) {
        val values = fields(url); val target = callback(url)
        val payload = buildJsonObject { put("callback", values.getValue("callback")); put("account", account); put("access_token", "synthetic-token") }.toString()
        Socket(target.host, target.port).use { socket ->
            socket.soTimeout = 5000
            socket.getOutputStream().write(("GET ${target.rawPath}?data=${URLEncoder.encode(payload, "UTF-8")} HTTP/1.1\r\nHost: ${target.host}:${target.port}\r\n\r\n").toByteArray())
            assertTrue(socket.getInputStream().bufferedReader().readLine().startsWith("HTTP/1.1 200"))
        }
    }
}

package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class FileVFSRepositoryTest {
    private val owner = WorkspaceOwner("synthetic-vfs", "identity", "session")
    private val setup = FileVFSConfiguration("davs", "server.invalid", 443, "Synthetic", "synthetic-account", folder = "Shared Files")
    private val baseline = FileVFSProfile(owner, "opaque-id", "davs", "WebDAV", "davs://opaque-root/folder", setup.hostname, setup.port,
        setup.alias, setup.account, setup.codepage, FileVFSConnectionState.CONNECTED)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>, val version: Int)
    private suspend fun create(h: Harness) = h.repo.changeVFSResult(FileVFSChange.Create(setup), "synthetic-secret", true)

    @Test fun serverCreateWritesBothRecordedRequestsAndKeepsCredentialsOutOfRecovery() = runBlocking {
        val h = Harness(); h.applyWrites = false
        val result = create(h)
        assertEquals(FileVFSOutcomeStatus.UNKNOWN, result.status)
        assertEquals(listOf(VFS_CONNECTION_API, VFS_PROFILE_API), h.writes.map { it.api })
        assertEquals(mapOf("protocol" to "davs", "hostname" to "server.invalid", "port" to "443", "alias" to "Synthetic",
            "account" to "synthetic-account", "password" to "synthetic-secret", "codepage" to "UTF-8", "uri_path" to "Shared Files",
            "max_connection" to "0", "force" to "false"), h.writes.first().fields)
        assertEquals(h.writes.first().fields - "force", h.writes.last().fields)
        assertTrue(h.writes.all { it.version == 1 && it.method == "create" })
        val raw = h.preferences.all.values.joinToString()
        assertFalse(raw.contains("synthetic-secret")); assertFalse(raw.contains("password"))
        assertFalse(result.pending!!.toString().contains("server.invalid"))
        assertEquals(FileVFSStep.ACKNOWLEDGED, result.pending.profile)
    }
    @Test fun createCompletesOnlyAfterNewUniqueIdentityAndFullDetailsMatch() = runBlocking {
        val h = Harness(); assertEquals(FileVFSOutcomeStatus.COMPLETED, create(h).status)
        assertTrue(h.repo.pending().isEmpty()); assertEquals(2, h.writes.size)
        val changed = Harness(); changed.afterWrite = { call -> if (call.api == VFS_PROFILE_API) changed.config = setup.copy(folder = "Other") }
        assertEquals(FileVFSOutcomeStatus.UNKNOWN, create(changed).status)
        assertEquals(1, changed.repo.pending().size)
    }
    @Test fun updateOmitsUnchangedAndPasswordFieldsUnlessExplicitlyReplaced() = runBlocking {
        val h = Harness(); h.profiles = listOf(baseline)
        assertEquals(FileVFSOutcomeStatus.COMPLETED,
            h.repo.changeVFSResult(FileVFSChange.Update(FileVFSDetail(baseline, setup), setup.copy(alias = "New alias")), null, true).status)
        assertEquals(mapOf("alias" to "New alias", "id" to baseline.id, "force" to "false"), h.writes.first().fields)
        assertFalse(h.writes.any { "password" in it.fields })
        val replacement = Harness(); replacement.profiles = listOf(baseline)
        assertEquals(FileVFSOutcomeStatus.COMPLETED,
            replacement.repo.changeVFSResult(FileVFSChange.Update(FileVFSDetail(baseline, setup), setup), "", true).status)
        assertEquals(mapOf("password" to "", "id" to baseline.id), replacement.writes.last().fields)
    }
    @Test fun disconnectReconnectAndRemoveSavedRemainDifferentSingleWrites() = runBlocking {
        val h = Harness(); h.profiles = listOf(baseline)
        assertEquals(FileVFSOutcomeStatus.COMPLETED, h.repo.changeVFSResult(FileVFSChange.Disconnect(baseline), null, true).status)
        assertEquals(VFS_CONNECTION_API, h.writes.single().api); assertEquals("delete", h.writes.single().method)
        assertEquals(1, h.profiles.size)
        val disconnected = h.profiles.single()
        assertEquals(FileVFSOutcomeStatus.COMPLETED, h.repo.changeVFSResult(FileVFSChange.Connect(disconnected), null, true).status)
        assertEquals(mapOf("profile_id" to baseline.id, "force" to "false"), h.writes.last().fields)
        assertTrue(runCatching { h.repo.changeVFSResult(FileVFSChange.RemoveSaved(h.profiles.single()), null, true) }.isFailure)
        assertEquals(2, h.writes.size)
        h.profiles = listOf(disconnected)
        assertEquals(FileVFSOutcomeStatus.COMPLETED, h.repo.changeVFSResult(FileVFSChange.RemoveSaved(disconnected), null, true).status)
        assertEquals(VFS_PROFILE_API, h.writes.last().api); assertEquals(mapOf("id" to baseline.id), h.writes.last().fields)
        assertTrue(h.profiles.isEmpty()); assertTrue(h.calls.none { it.api == "SYNO.FileStation.Delete" })
    }
    @Test fun missingConfirmationPermissionsCleartextNasAndUnacceptedRemoteCleartextNeverWrite() = runBlocking {
        for (access in listOf(FilePermissionAccess(false, true), FilePermissionAccess(true, false))) {
            val h = Harness(); h.access = access
            assertTrue(runCatching { create(h) }.isFailure); assertTrue(h.writes.isEmpty())
        }
        val h = Harness(); h.secure = false
        assertTrue(runCatching { create(h) }.isFailure); assertTrue(h.writes.isEmpty())
        h.secure = true
        assertTrue(runCatching { h.repo.changeVFSResult(FileVFSChange.Create(setup), "secret", false) }.isFailure)
        val ftp = setup.copy(protocolId = "ftp", port = 21, folder = "")
        assertTrue(runCatching { h.repo.changeVFSResult(FileVFSChange.Create(ftp), "secret", true) }.isFailure)
        assertTrue(h.writes.isEmpty())
        assertEquals(FileVFSOutcomeStatus.COMPLETED, h.repo.changeVFSResult(FileVFSChange.Create(ftp), "secret", true, true).status)
    }
    @Test fun secondPermissionRefreshAndChangedBaselinePreventAllWrites() = runBlocking {
        val h = Harness(); h.onRefresh = { if (h.refreshes == 2) h.access = FilePermissionAccess(false, true) }
        assertTrue(runCatching { create(h) }.isFailure); assertTrue(h.writes.isEmpty())
        val changed = Harness(); changed.profiles = listOf(baseline.copy(account = "other"))
        assertTrue(runCatching { changed.repo.changeVFSResult(FileVFSChange.Disconnect(baseline), null, true) }.isFailure)
        assertTrue(changed.writes.isEmpty())
    }
    @Test fun unsupportedVersionAndFailedInitialPersistenceCannotSendCredentials() = runBlocking {
        val h = Harness(); h.supported = false
        assertTrue(runCatching { create(h) }.isFailure); assertTrue(h.writes.isEmpty())
        val persistence = Harness(); persistence.preferences.commitSucceeds = false
        assertTrue(runCatching { create(persistence) }.isFailure); assertTrue(persistence.writes.isEmpty())
    }
    @Test fun firstUnknownNeverSendsProfileAndColdReviewNeverReplaysEitherStep() = runBlocking {
        val h = Harness(); h.afterWrite = { throw IOException("synthetic dropped response") }
        val result = create(h)
        assertEquals(FileVFSOutcomeStatus.UNKNOWN, result.status); assertEquals(1, h.writes.size)
        assertEquals(FileVFSStep.SUBMITTED, result.pending!!.connection); assertEquals(FileVFSStep.UNSENT, result.pending.profile)
        val cold = Harness(h.preferences); cold.identity = owner.copy(sessionGeneration = "new-session")
        assertEquals(FileVFSOutcomeStatus.UNKNOWN, cold.repo.review(result.pending.id).status)
        assertTrue(runCatching { create(cold) }.isFailure); assertTrue(cold.writes.isEmpty())
    }
    @Test fun secondUnknownCannotInferChangedCredentialsFromMatchingPublicFields() = runBlocking {
        val h = Harness(); h.profiles = listOf(baseline)
        h.afterWrite = { if (it.api == VFS_PROFILE_API) throw IOException("synthetic dropped profile response") }
        val result = h.repo.changeVFSResult(FileVFSChange.Update(FileVFSDetail(baseline, setup), setup), "new-synthetic-secret", true)
        assertEquals(FileVFSOutcomeStatus.UNKNOWN, result.status); assertEquals(2, h.writes.size)
        assertEquals(FileVFSStep.ACKNOWLEDGED, result.pending!!.connection); assertEquals(FileVFSStep.SUBMITTED, result.pending.profile)
        assertEquals(FileVFSOutcomeStatus.UNKNOWN, h.repo.review(result.pending.id).status)
        assertEquals(2, h.writes.size); assertFalse(h.preferences.all.values.joinToString().contains("new-synthetic-secret"))
    }
    @Test fun knownFirstRejectionClearsOnlyUnperformedAttemptAndNeverForcesIdentityWarnings() = runBlocking {
        for (code in listOf(2107, 2112, 2115)) {
            val h = Harness(); h.beforeWrite = { throw DsmFailure(code, "synthetic", "synthetic", kind = DsmErrorKind.REQUEST_FAILED) }
            assertEquals(FileVFSOutcomeStatus.REJECTED, create(h).status)
            assertTrue(h.repo.pending().isEmpty()); assertEquals(1, h.writes.size)
            assertEquals("false", h.writes.single().fields["force"])
        }
    }
    @Test fun knownSecondRejectionKeepsAcknowledgedConnectionAndDoesNotReplay() = runBlocking {
        val h = Harness(); h.beforeWrite = { if (it.api == VFS_PROFILE_API) throw DsmFailure(105, "synthetic", "synthetic", kind = DsmErrorKind.PERMISSION_DENIED) }
        val result = create(h)
        assertEquals(FileVFSOutcomeStatus.UNKNOWN, result.status)
        assertEquals(FileVFSStep.REJECTED, result.pending!!.profile)
        assertEquals(FileVFSOutcomeStatus.UNKNOWN, h.repo.review(result.pending.id).status); assertEquals(2, h.writes.size)
    }
    @Test fun cancellationBetweenStepsAndFailedAcknowledgmentPersistenceStopSecondWrite() = runBlocking {
        for (failSave in listOf(false, true)) {
            val h = Harness(); h.afterWrite = { if (failSave) h.preferences.commitSucceeds = false else throw CancellationException("synthetic stop") }
            assertTrue(runCatching { create(h) }.isFailure); assertEquals(1, h.writes.size)
            assertEquals(1, h.repo.pending().size)
        }
    }
    @Test fun lostDisconnectResponseCanCompleteFromExactIdentityButReplacementCannot() = runBlocking {
        val h = Harness(); h.profiles = listOf(baseline); h.afterWrite = { throw IOException("synthetic lost response") }
        assertEquals(FileVFSOutcomeStatus.COMPLETED, h.repo.changeVFSResult(FileVFSChange.Disconnect(baseline), null, true).status)
        val changed = Harness(); changed.profiles = listOf(baseline)
        changed.afterWrite = { changed.profiles = listOf(baseline.copy(account = "other", state = FileVFSConnectionState.DISCONNECTED)) }
        assertEquals(FileVFSOutcomeStatus.UNKNOWN, changed.repo.changeVFSResult(FileVFSChange.Disconnect(baseline), null, true).status)
    }
    @Test fun cloudAuthorizationIsBoundSingleUseAndDoesNotPersistTokens() = runBlocking {
        val h = Harness(); h.applyWrites = false
        val request = h.repo.prepareCloudAuthorization("google")
        assertEquals("https://synooauth.synology.com/FileStation/Cloud/login.php?major=7&minor=2&type=google", request.loginUrl)
        assertFalse(request.loginUrl.contains(owner.profileId))
        val authorization = auth(request)
        val change = FileVFSChange.CreateCloud(FileVFSCloudIdentity("google", "Cloud", authorization.account))
        val result = h.repo.authorizeVFSResult(change, authorization, true)
        assertEquals(FileVFSOutcomeStatus.UNKNOWN, result.status); assertEquals(2, h.writes.size)
        assertEquals("synthetic-access", h.writes.first().fields["access_token"])
        val raw = h.preferences.all.values.joinToString()
        assertFalse(raw.contains("synthetic-access")); assertFalse(raw.contains("synthetic-refresh")); assertFalse(raw.contains("access_token"))
        assertTrue(runCatching { h.repo.authorizeVFSResult(change, authorization, true) }.isFailure); assertEquals(2, h.writes.size)
    }
    @Test fun expiredCancelledMismatchedOrOtherOwnerCloudCallbacksCannotWrite() = runBlocking {
        for (variant in 0..4) {
            val h = Harness(); val request = h.repo.prepareCloudAuthorization("google")
            val authorization = when (variant) { 2 -> auth(request).copy(account = "other"); 3 -> auth(request).copy(owner = owner.copy(identityRevision = "other")); else -> auth(request) }
            if (variant == 0) h.clock += 600_001
            if (variant == 1) h.repo.cancelCloudAuthorization(request.id)
            if (variant == 4) h.identity = owner.copy(sessionGeneration = "new-session")
            assertTrue(runCatching { h.repo.authorizeVFSResult(FileVFSChange.CreateCloud(FileVFSCloudIdentity("google", "Cloud", "cloud-account")), authorization, true) }.isFailure)
            assertTrue(h.writes.isEmpty())
        }
    }
    private fun auth(request: FileVFSCloudRequest) = FileVFSCloudAuthorization(request.id, request.owner, request.protocolId,
        "cloud-account", "synthetic-access", "synthetic-client", "synthetic-refresh", 3600)

    private inner class Harness(val preferences: MemoryPreferences = MemoryPreferences()) {
        val calls = mutableListOf<Call>(); val writes get() = calls.filter { it.method in setOf("create", "set", "delete") }
        var identity = owner; var access = FilePermissionAccess(true, true); var supported = true; var secure = true
        var current = true; var clock = 1000L; var refreshes = 0; var applyWrites = true
        var profiles = emptyList<FileVFSProfile>(); var config = setup
        var onRefresh: suspend () -> Unit = {}
        var beforeWrite: suspend (Call) -> Unit = {}; var afterWrite: suspend (Call) -> Unit = {}
        val repo = DsmFileVFSRepository({ _, version -> supported && version == 1 }, ::call, { access }, { refreshes++; onRefresh() },
            { secure }, { identity }, { check(current) }, { clock }).also { it.bindRecovery(FileVFSRecoveryStore(preferences)) }
        private suspend fun call(api: String, method: String, fields: Map<String, String>, version: Int): JsonObject {
            val request = Call(api, method, fields, version); calls += request
            if (method in setOf("create", "set", "delete")) {
                beforeWrite(request)
                if (applyWrites) apply(request)
                afterWrite(request); return buildJsonObject {}
            }
            return when (api) {
                VFS_PROTOCOL_API -> buildJsonObject { putJsonArray("protocols") { for ((id, port) in listOf("davs" to 443, "ftp" to 21, "google" to 0)) add(buildJsonObject {
                    put("protocol", id); put("name", id); put("default_port", port); put("has_server", false)
                }) } }
                VFS_PROFILE_API -> if (method == "get") buildJsonObject {
                    put("hostname", config.hostname); put("port", config.port); put("alias", config.alias); put("account", config.account)
                    put("codepage", config.codepage); put("uri_path", config.folder); put("max_connection", if (config.usesOneConnection) 1 else 0)
                    put("password", "synthetic-never-return")
                } else buildJsonObject { put("total", profiles.size); putJsonArray("profiles") { profiles.forEach { row -> add(buildJsonObject {
                    put("id", row.id); put("protocol", row.protocolId); put("protocol_name", row.protocolName); put("uri", row.uri)
                    put("hostname", row.hostname); put("port", row.port); put("alias", row.alias); put("account", row.account); put("codepage", row.codepage)
                    put("connect_status", when (row.state) { FileVFSConnectionState.CONNECTED -> 1; FileVFSConnectionState.DISCONNECTED -> 0; else -> 2 })
                }) } } }
                "SYNO.Core.System" -> buildJsonObject { put("firmware_ver", "DSM 7.2.1") }
                else -> error("Unexpected synthetic request")
            }
        }
        private fun apply(call: Call) {
            val f = call.fields
            if (call.api == VFS_CONNECTION_API) {
                if (call.method == "delete") profiles = profiles.map { it.copy(state = FileVFSConnectionState.DISCONNECTED) }
                if ("profile_id" in f) profiles = profiles.map { it.copy(state = FileVFSConnectionState.CONNECTED) }
            } else if (call.method == "delete") profiles = emptyList()
            else {
                config = config.copy(protocolId = f["protocol"] ?: config.protocolId, hostname = f["hostname"] ?: config.hostname,
                    port = f["port"]?.toInt() ?: config.port, alias = f["alias"] ?: config.alias, account = f["account"] ?: config.account,
                    codepage = f["codepage"] ?: config.codepage, folder = f["uri_path"] ?: config.folder, usesOneConnection = f["max_connection"]?.let { it == "1" } ?: config.usesOneConnection)
                profiles = listOf(baseline.copy(owner = identity, id = f["id"] ?: "new-opaque-id", protocolId = config.protocolId,
                    hostname = config.hostname, port = config.port, alias = config.alias, account = config.account, codepage = config.codepage))
            }
        }
    }
}

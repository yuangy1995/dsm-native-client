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

class RemoteMountRepositoryTest {
    private val owner = WorkspaceOwner("synthetic-remote", "identity", "session")
    private val oldPoint = "/synthetic/old "
    private val newPoint = "/synthetic/new "
    private val setup = FileRemoteMountSetup(server = "server.invalid", remotePath = "share/folder", mountPoint = newPoint,
        username = "synthetic-user", domain = "synthetic-domain")
    private val old = setup.copy(server = "previous.invalid", mountPoint = oldPoint).connection
    private fun folder(path: String) = FileItem(path, path.substringAfterLast('/'), true,
        canRead = true, canWrite = true, canDelete = true, mountPointType = "")
    private suspend fun create(h: Harness, value: FileRemoteMountSetup = setup, password: String = "synthetic-password") =
        h.remote.changeRemoteMountResult(value, null, h.items[value.mountPoint], password, true)
    private suspend fun update(h: Harness, value: FileRemoteMountSetup = setup) =
        h.remote.changeRemoteMountResult(value, old, h.items[value.mountPoint], "synthetic-password", true)

    @Test fun cifsUsesOnlyRecordedFieldsAndPasswordNeverEntersRecovery() = runBlocking {
        val h = Harness(); h.applyWrite = false
        assertEquals(RemoteMountOutcomeStatus.UNKNOWN, create(h).status)
        assertEquals(mapOf("mount_type" to "CIFS", "server_ip" to "//server.invalid/share/folder", "mount_point" to newPoint,
            "user_set" to "true", "auto_mount" to "false", "account" to "synthetic-domain\\synthetic-user", "passwd" to "synthetic-password"), h.writes.single().parameters)
        val serialized = h.preferences.all.values.joinToString()
        assertFalse(serialized.contains("synthetic-password")); assertFalse(serialized.contains("passwd"))
        assertFalse(h.remote.pending().single().toString().contains("server.invalid")); assertEquals(2, h.refreshes)
        assertFalse(h.calls.any { it.api.contains("Delete") || it.version != 1 && it.api == MOUNT_API })
    }
    @Test fun nfsHasProtocolFieldsAndNeverSendsCredentials() = runBlocking {
        for (version in listOf("3", "4")) {
            val h = Harness(); val nfs = setup.copy(kind = FileMountKind.NFS, username = "", domain = "", nfsVersion = version)
            assertEquals(RemoteMountOutcomeStatus.COMPLETED, create(h, nfs, "").status)
            assertEquals(mapOf("mount_type" to "NFS", "server_ip" to "server.invalid:/share/folder", "mount_point" to newPoint,
                "user_set" to "true", "auto_mount" to "false", "nfs_version" to version, "protocol" to "tcp"), h.writes.single().parameters)
            assertTrue(h.remote.pending().isEmpty())
        }
    }
    @Test fun invalidOptionsCleartextAndMissingConfirmationNeverWrite() = runBlocking {
        for (invalid in listOf(setup.copy(server = "server.invalid:445"), setup.copy(server = "user@server.invalid"),
            setup.copy(remotePath = "../folder"), setup.copy(remotePath = "//server/share"), setup.copy(domain = "domain/invalid"),
            setup.copy(kind = FileMountKind.NFS), setup.copy(kind = FileMountKind.NFS, username = "", domain = "", nfsVersion = "4", nfsTransport = "udp"))) {
            val h = Harness(); assertTrue(runCatching { create(h, invalid) }.isFailure); assertTrue(h.writes.isEmpty())
        }
        val h = Harness(); h.secure = false
        assertEquals(DsmErrorKind.INSECURE_ADDRESS, (runCatching { create(h) }.exceptionOrNull() as DsmFailure).kind)
        assertTrue(h.writes.isEmpty())
        assertTrue(runCatching { h.remote.changeRemoteMountResult(setup, null, folder(newPoint), "", false) }.isFailure)
    }
    @Test fun ordinaryGrantedAccountCanConnectButPersistentOrUnknownSettingsNeedAdmin() = runBlocking {
        val regular = Harness(); assertEquals(RemoteMountOutcomeStatus.COMPLETED, create(regular).status)
        for (access in listOf(FilePermissionAccess(false, true), FilePermissionAccess(true, false))) {
            val h = Harness(); h.access = access
            assertTrue(runCatching { create(h, setup.copy(automatic = true)) }.isFailure); assertTrue(h.writes.isEmpty())
        }
        val admin = Harness(); admin.access = FilePermissionAccess(true, true)
        assertEquals(RemoteMountOutcomeStatus.COMPLETED, create(admin, setup.copy(automatic = true)).status)
        val unknown = Harness(); unknown.connections = listOf(old.copy(automatic = null))
        assertTrue(runCatching { unknown.remote.changeRemoteMountResult(null, unknown.connections.single(), null, "", true) }.isFailure)
        assertTrue(unknown.writes.isEmpty())
    }
    @Test fun revokedSecondGrantDisabledSettingAndChangedDestinationNeverWrite() = runBlocking {
        for (change in listOf<(Harness) -> Unit>({ it.access = FilePermissionAccess(false, false) },
            { it.enabled = false }, { it.items[newPoint] = folder(newPoint).copy(canWrite = false) },
            { it.connections = listOf(setup.connection) }, { it.full = true })) {
            val h = Harness(); h.onRefresh = { if (h.refreshes == 2) change(h) }
            assertTrue(runCatching { create(h) }.isFailure); assertTrue(h.writes.isEmpty())
        }
    }
    @Test fun movingConnectsFirstAndNeverAutomaticallyDisconnectsPrevious() = runBlocking {
        val h = Harness(); h.connections = listOf(old)
        val first = update(h)
        assertEquals(RemoteMountOutcomeStatus.READY, first.status)
        assertEquals(RemoteMountStage.READY_TO_DISCONNECT, first.pending!!.stage)
        assertEquals(listOf("mount_remote"), h.writes.map { it.method })
        assertEquals(RemoteMountOutcomeStatus.READY, h.remote.review(first.pending.id).status)
        assertEquals(1, h.writes.size)
        assertEquals(RemoteMountOutcomeStatus.COMPLETED, h.remote.continueRemoteMountResult(first.pending.id, "", true).status)
        assertEquals(listOf(setup.connection), h.connections)
        assertEquals(mapOf("mount_point" to mountStrings(listOf(oldPoint))), h.writes.last().parameters)
        assertTrue(h.items.containsKey(oldPoint)); assertTrue(h.remote.pending().isEmpty())
    }
    @Test fun sameLocationDisconnectsFirstAndRequiresExplicitSecondStep() = runBlocking {
        val h = Harness(); h.connections = listOf(old)
        val same = setup.copy(mountPoint = oldPoint)
        val first = update(h, same)
        assertEquals(RemoteMountStage.READY_TO_CONNECT, first.pending!!.stage)
        assertEquals(listOf("unmount"), h.writes.map { it.method })
        assertTrue(runCatching { h.remote.continueRemoteMountResult(first.pending.id, "", false) }.isFailure)
        assertEquals(1, h.writes.size)
        assertEquals(RemoteMountOutcomeStatus.COMPLETED, h.remote.continueRemoteMountResult(first.pending.id, "new-synthetic-secret", true).status)
        assertEquals("new-synthetic-secret", h.writes.last().parameters["passwd"])
        assertEquals(listOf(same.connection), h.connections)
    }
    @Test fun nestedPositionsAndReplacedOldIdentityNeverStartUpdate() = runBlocking {
        val nested = Harness(); nested.connections = listOf(old)
        assertTrue(runCatching { update(nested, setup.copy(mountPoint = oldPoint + "/nested")) }.isFailure)
        assertTrue(nested.writes.isEmpty())
        val replaced = Harness(); replaced.connections = listOf(old.copy(source = "//replacement.invalid/share"))
        assertTrue(runCatching { update(replaced) }.isFailure); assertTrue(replaced.writes.isEmpty())
    }
    @Test fun changedNewOrOldIdentityPreventsSecondDisconnect() = runBlocking {
        for (replaceNew in listOf(false, true)) {
            val h = Harness(); h.connections = listOf(old)
            val first = update(h)
            h.connections = h.connections.map { if ((it.mountPoint == newPoint) == replaceNew) it.copy(source = "//replacement.invalid/share") else it }
            assertTrue(runCatching { h.remote.continueRemoteMountResult(first.pending!!.id, "", true) }.isFailure)
            assertEquals(1, h.writes.size); assertEquals(RemoteMountStage.READY_TO_DISCONNECT, h.remote.pending().single().stage)
        }
    }
    @Test fun missingOldLocationCompletesMoveOnlyWhenNewIdentityStillMatches() = runBlocking {
        val h = Harness(); h.connections = listOf(old)
        val first = update(h)
        h.connections = listOf(setup.connection); h.missing += oldPoint
        assertEquals(RemoteMountOutcomeStatus.COMPLETED, h.remote.continueRemoteMountResult(first.pending!!.id, "", true).status)
        assertEquals(1, h.writes.size)
    }
    @Test fun networkLossColdRecoveryAndStaleContinueNeverReplay() = runBlocking {
        val h = Harness(); h.applyWrite = false; h.afterWrite = { throw IOException("synthetic transport failure") }
        val initial = create(h)
        assertEquals(RemoteMountOutcomeStatus.UNKNOWN, initial.status)
        val cold = Harness(h.preferences); cold.identity = owner.copy(sessionGeneration = "reconnected")
        assertEquals(RemoteMountOutcomeStatus.UNKNOWN, cold.remote.continueRemoteMountResult(initial.pending!!.id, "", true).status)
        assertTrue(runCatching { create(cold) }.isFailure); assertTrue(cold.writes.isEmpty())
        cold.connections = listOf(setup.connection)
        assertEquals(RemoteMountOutcomeStatus.COMPLETED, cold.remote.review(initial.pending.id).status)
        assertTrue(cold.writes.isEmpty()); assertTrue(cold.remote.pending().isEmpty())
    }
    @Test fun unknownUpdateReviewAdvancesButDoesNotExecuteNextStep() = runBlocking {
        val h = Harness(); h.connections = listOf(old); h.applyWrite = false
        val first = update(h)
        h.connections = listOf(old, setup.connection)
        assertEquals(RemoteMountOutcomeStatus.READY, h.remote.continueRemoteMountResult(first.pending!!.id, "", true).status)
        assertEquals(1, h.writes.size); assertEquals(RemoteMountStage.READY_TO_DISCONNECT, h.remote.pending().single().stage)
    }
    @Test fun unreadableOrWrongMountTypeNeverCountsAsDisconnected() = runBlocking {
        for (bad in listOf<(Harness) -> Unit>({ it.readFailure = true }, { it.items[oldPoint] = folder(oldPoint).copy(mountPointType = "iso") })) {
            val h = Harness(); h.connections = listOf(old); h.afterWrite = { bad(h) }
            assertEquals(RemoteMountOutcomeStatus.UNKNOWN, h.remote.changeRemoteMountResult(null, old, null, "", true).status)
            assertEquals(1, h.remote.pending().size)
        }
        val missing = Harness(); missing.connections = listOf(old); missing.afterWrite = { missing.missing += oldPoint }
        assertEquals(RemoteMountOutcomeStatus.COMPLETED, missing.remote.changeRemoteMountResult(null, old, null, "", true).status)
    }
    @Test fun definiteRejectionReleasesFirstStepButPreservesReadySecondStep() = runBlocking {
        val h = Harness(); h.applyWrite = false; h.afterWrite = { throw DsmFailure(105, "synthetic denial", "", kind = DsmErrorKind.PERMISSION_DENIED) }
        assertEquals(RemoteMountOutcomeStatus.REJECTED, create(h).status); assertTrue(h.remote.pending().isEmpty())
        val second = Harness(); second.connections = listOf(old)
        val first = update(second, setup.copy(mountPoint = oldPoint))
        second.applyWrite = false; second.afterWrite = { throw DsmFailure(400, "synthetic rejection", "", kind = DsmErrorKind.REQUEST_FAILED) }
        assertEquals(RemoteMountOutcomeStatus.REJECTED, second.remote.continueRemoteMountResult(first.pending!!.id, "", true).status)
        assertEquals(RemoteMountStage.READY_TO_CONNECT, second.remote.pending().single().stage)
    }
    @Test fun httpFailureWithNumericCodeStillCannotReleaseUnknownWrite() = runBlocking {
        val h = Harness(); h.applyWrite = false; h.afterWrite = { throw DsmFailure(500, "synthetic connection failure", "", kind = DsmErrorKind.CONNECTION_FAILED) }
        assertEquals(RemoteMountOutcomeStatus.UNKNOWN, create(h).status); assertEquals(1, h.remote.pending().size)
    }
    @Test fun cancelledSecondStepCannotBeEndedOrReplayedAfterReconnection() = runBlocking {
        val h = Harness(); h.connections = listOf(old)
        val first = update(h, setup.copy(mountPoint = oldPoint))
        h.applyWrite = false; h.afterWrite = { throw CancellationException("synthetic second-step cancellation") }
        assertTrue(runCatching { h.remote.continueRemoteMountResult(first.pending!!.id, "", true) }.exceptionOrNull() is CancellationException)
        val record = h.remote.pending().single()
        assertEquals(RemoteMountStage.CHECK_CONNECTION, record.stage)
        assertTrue(runCatching { h.remote.endRemaining(record.id, true) }.isFailure)
        assertEquals(RemoteMountOutcomeStatus.UNKNOWN, h.remote.continueRemoteMountResult(record.id, "", true).status)
        assertEquals(2, h.writes.size)
    }
    @Test fun endingRemainderRequiresReadyStageAndNeverChangesNas() = runBlocking {
        val unknown = Harness(); unknown.applyWrite = false
        val result = create(unknown)
        assertTrue(runCatching { unknown.remote.endRemaining(result.pending!!.id, true) }.isFailure)
        val ready = Harness(); ready.connections = listOf(old)
        val first = update(ready)
        assertEquals(RemoteMountOutcomeStatus.ENDED, ready.remote.endRemaining(first.pending!!.id, true).status)
        assertEquals(1, ready.writes.size); assertEquals(listOf(old, setup.connection), ready.connections)
        assertTrue(ready.remote.pending().isEmpty())
    }
    @Test fun concurrentAndRelatedPermissionOrIsoOperationsCannotOverlap() = runBlocking {
        for (path in listOf("/synthetic", newPoint + "/nested")) {
            val h = Harness(); h.onClaim = { h.otherPending = listOf(path) }
            assertTrue(runCatching { create(h) }.isFailure); assertTrue(h.writes.isEmpty())
        }
        val h = Harness(); val sent = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        h.afterWrite = { sent.complete(Unit); release.await() }
        val first = async { create(h) }; sent.await()
        assertTrue(runCatching { create(h) }.isFailure); assertEquals(1, h.writes.size)
        release.complete(Unit); assertEquals(RemoteMountOutcomeStatus.COMPLETED, first.await().status)
    }
    @Test fun unboundFailedStorageAndRetiredOwnerNeverSubmit() = runBlocking {
        val h = Harness(); h.preferences.commitSucceeds = false
        assertTrue(runCatching { create(h) }.isFailure); assertTrue(h.writes.isEmpty())
        val retired = Harness(); retired.ownerValid = false
        assertTrue(runCatching { create(retired) }.isFailure); assertTrue(retired.writes.isEmpty())
        val unbound = Harness(bind = false)
        assertTrue(runCatching { create(unbound) }.isFailure); assertTrue(unbound.writes.isEmpty())
    }
    @Test fun cancelledSubmittedStepStaysUnknownAndAccountSwitchCannotReadIt() = runBlocking {
        val h = Harness(); h.applyWrite = false; h.afterWrite = { throw CancellationException("synthetic cancellation") }
        assertTrue(runCatching { create(h) }.exceptionOrNull() is CancellationException)
        assertEquals(1, h.remote.pending().size)
        val store = FileRemoteMountRecoveryStore(h.preferences)
        assertTrue(store.pending(owner.copy(identityRevision = "different-account")).isEmpty())
        assertEquals(1, store.pending(owner.copy(sessionGeneration = "new-session")).size)
    }
    @Test fun remoteSourceNormalizationPreservesPathCaseAndWhitespace() = runBlocking {
        assertEquals("//server.invalid/Share/Folder ", canonicalRemoteMountSource(FileMountKind.CIFS, "\\\\SERVER.invalid\\Share\\Folder "))
        assertEquals("server.invalid:/Share/Folder ", canonicalRemoteMountSource(FileMountKind.NFS, "SERVER.invalid:/Share/Folder "))
        for (bad in listOf("//server.invalid//share", "//server.invalid/share/../child", "//user@server.invalid/share"))
            assertTrue(runCatching { canonicalRemoteMountSource(FileMountKind.CIFS, bad) }.isFailure)
        assertEquals(newPoint, setup.normalized().mountPoint)
    }

    private data class Call(val api: String, val method: String, val parameters: Map<String, String>, val version: Int)
    @Test fun remoteMountUsesActualPermissionsWithoutVersionCallback() = runBlocking {
        val h = Harness(); assertEquals(RemoteMountOutcomeStatus.COMPLETED, create(h).status)
        assertEquals(1, h.writes.size); assertTrue(h.remote.pending().isEmpty())
    }

    private inner class Harness(val preferences: MemoryPreferences = MemoryPreferences(), bind: Boolean = true) {
        val calls = mutableListOf<Call>(); val writes get() = calls.filter { it.method in setOf("mount_remote", "unmount") }
        var connections = emptyList<FileMountConnection>(); val items = mutableMapOf(oldPoint to folder(oldPoint), newPoint to folder(newPoint))
        var identity = owner; var ownerValid = true; var access = FilePermissionAccess(true, false)
        var secure = true; var enabled = true; var supported = true; var full = false; var applyWrite = true; var readFailure = false
        var otherPending = emptyList<String>(); var claimed = false; var refreshes = 0; val missing = mutableSetOf<String>()
        var onRefresh: () -> Unit = {}; var onClaim: () -> Unit = {}; var afterWrite: suspend () -> Unit = {}
        val reader = FileMountReader(::call)
        val remote = DsmRemoteMountRepository(reader, ::call, { supported }, { secure }, { access }, { refreshes++; onRefresh() },
            { if (claimed) false else { claimed = true; onClaim(); true } }, { claimed = false }, { otherPending }, { identity },
            { if (!ownerValid) throw DsmFailure(null, "synthetic owner retired", "", kind = DsmErrorKind.WORKSPACE_CHANGED) }).also {
            if (bind) it.bindRecovery(FileRemoteMountRecoveryStore(preferences))
        }
        suspend fun call(api: String, method: String, parameters: Map<String, String>, version: Int): JsonObject {
            calls += Call(api, method, parameters.toMap(), version)
            if (readFailure && method !in setOf("mount_remote", "unmount")) throw IOException("synthetic read failure")
            return when (method) {
                "get" -> buildJsonObject {
                    putJsonObject("mountConfig") { put("enable_iso_mount", true); put("enable_remote_mount", enabled) }
                    putJsonArray("isoList") {}
                    putJsonArray("remoteList") { connections.forEach { connection -> add(buildJsonObject {
                        put("type", connection.kind.name); put("source", connection.source); put("mount_point", connection.mountPoint)
                        connection.automatic?.let { put("auto_mount", it) }
                    }) } }
                }
                "getinfo" -> {
                    val path = Json.parseToJsonElement(parameters.getValue("path")).jsonArray.single().jsonPrimitive.content
                    buildJsonObject { putJsonArray("files") { add(buildJsonObject {
                        put("path", path)
                        if (path in missing) put("code", 408) else {
                            val item = items.getValue(path); put("name", item.name); put("isdir", item.isDirectory)
                            putJsonObject("additional") { put("mount_point_type", if (connections.any { it.mountPoint == path }) "remote" else item.mountPointType)
                                putJsonObject("perm") { putJsonObject("acl") { put("read", item.canRead); put("write", item.canWrite); put("del", item.canDelete) } } }
                        }
                    }) } }
                }
                "list" -> buildJsonObject { put("offset", 0); put("total", if (full) 1 else 0); putJsonArray("files") {} }
                "mount_remote" -> {
                    if (applyWrite) connections += FileMountConnection(FileMountKind.valueOf(parameters.getValue("mount_type")),
                        parameters.getValue("server_ip"), parameters.getValue("mount_point"), parameters["auto_mount"] == "true")
                    afterWrite(); buildJsonObject {}
                }
                "unmount" -> {
                    val path = Json.parseToJsonElement(parameters.getValue("mount_point")).jsonArray.single().jsonPrimitive.content
                    if (applyWrite) connections = connections.filterNot { it.mountPoint == path }
                    afterWrite(); buildJsonObject {}
                }
                else -> error("Unexpected synthetic request")
            }
        }
    }
}

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

class FileMountRepositoryTest {
    private val owner = WorkspaceOwner("synthetic-iso", "identity", "session")
    private val source = FileItem("/synthetic/disc.iso", "disc.iso", false, 24, 10,
        canRead = true, canWrite = true, canDelete = true, mountPointType = "normal")
    private val destination = FileItem("/synthetic/empty ", "empty ", true, modifiedAtEpochSeconds = 10,
        canRead = true, canWrite = true, canDelete = true, mountPointType = "normal")
    private val connection = FileMountConnection(FileMountKind.ISO, source.path, destination.path, false)
    private val change get() = FileISOMountChange.Mount(source, destination)

    @Test fun inventoryUsesStrictBooleansAndRetainsUnknownAutomaticFlag() = runBlocking {
        val h = Harness(); h.connections = listOf(connection.copy(automatic = null))
        val result = h.repo.inventory()
        assertNull(result.isoConnections.single().automatic)
        assertTrue(result.isoEnabled); assertTrue(result.remoteEnabled)
        assertEquals(Call(MOUNT_LIST_API, "get", emptyMap(), 1), h.calls.single())
        for (transform in listOf<(JsonObject) -> JsonObject>(
            { JsonObject(it - "isoList") }, { JsonObject(it - "remoteList") },
            { JsonObject(it + ("mountConfig" to buildJsonObject { put("enable_iso_mount", "true"); put("enable_remote_mount", true) })) },
            { data ->
                val malformed = JsonObject(row(connection) + ("auto_mount" to JsonPrimitive("false")))
                JsonObject(data + ("isoList" to JsonArray(listOf(malformed))))
            },
        )) {
            h.inventoryTransform = transform
            assertTrue(runCatching { h.repo.inventory() }.isFailure)
        }
    }
    @Test fun duplicateWrongKindAndInvalidLogicalTargetsDoNotBecomeEmptyInventory() = runBlocking {
        val h = Harness()
        for (rows in listOf(listOf(connection, connection), listOf(connection.copy(mountPoint = "/synthetic/../empty")),
            listOf(connection.copy(source = "relative.iso")))) {
            h.connections = rows; assertTrue(runCatching { h.repo.inventory() }.isFailure)
        }
        h.connections = emptyList(); h.inventoryTransform = { JsonObject(it + ("isoList" to JsonArray(listOf(row(connection.copy(kind = FileMountKind.CIFS)))))) }
        assertTrue(runCatching { h.repo.inventory() }.isFailure)
    }
    @Test fun mountUsesRecordedFieldsOriginalWhitespaceAndFullStateReadback() = runBlocking {
        val h = Harness()
        val result = h.repo.changeISOMountResult(change.copy(automatic = true), true)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        val write = h.calls.single { it.method == "mount_iso" }
        assertEquals(Call(MOUNT_API, "mount_iso", mapOf("source" to source.path, "mount_point" to destination.path,
            "auto_mount" to "true", "user_set" to "true"), 1), write)
        assertEquals(2, h.refreshes); assertEquals(2, h.emptyReads)
        assertTrue(h.repo.pending().isEmpty()); assertEquals(1, h.writes)
        assertFalse(h.calls.any { it.api.contains("Delete") || "password" in it.parameters || "passwd" in it.parameters })
    }
    @Test fun unconfirmedMissingGrantNonAdministratorAndDisabledFeatureNeverWrite() = runBlocking {
        for (setup in listOf<(Harness) -> Unit>({ it.access = FilePermissionAccess(false, true) },
            { it.access = FilePermissionAccess(true, false) }, { it.isoEnabled = false }, { it.supported = false })) {
            val h = Harness(); setup(h)
            assertTrue(runCatching { h.repo.changeISOMountResult(change, true) }.isFailure); assertEquals(0, h.writes)
        }
        val h = Harness()
        assertTrue(runCatching { h.repo.changeISOMountResult(change, false) }.isFailure); assertEquals(0, h.writes)
    }
    @Test fun nonEmptyMissingCountInvalidSourceAndUnwritableDestinationNeverMount() = runBlocking {
        val full = Harness(); full.contents = 1
        val error = runCatching { full.repo.changeISOMountResult(change, true) }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.FILE_MOUNT_EMPTY_REQUIRED, error.kind); assertEquals(0, full.writes)
        val missing = Harness(); missing.emptyTransform = { JsonObject(it - "total") }
        assertTrue(runCatching { missing.repo.changeISOMountResult(change, true) }.isFailure); assertEquals(0, missing.writes)
        for (invalid in listOf(change.copy(source = source.copy(isDirectory = true)), change.copy(source = source.copy(canRead = false)),
            change.copy(destination = destination.copy(canWrite = false)), change.copy(destination = destination.copy(path = "/synthetic")),
            change.copy(destination = destination.copy(path = "/synthetic/#recycle/empty")), change.copy(destination = destination.copy(path = source.path)))) {
            val h = Harness(); assertTrue(runCatching { h.repo.changeISOMountResult(invalid, true) }.isFailure); assertEquals(0, h.writes)
        }
    }
    @Test fun changedSourceAndTargetAtEitherPreflightStopBeforeSubmission() = runBlocking {
        for (read in listOf(1, 3)) {
            val h = Harness(); h.onItemRead = { if (h.itemReads == read) h.currentSource = source.copy(size = 25) }
            assertTrue(runCatching { h.repo.changeISOMountResult(change, true) }.isFailure); assertEquals(0, h.writes)
        }
        val h = Harness(); h.onItemRead = { if (h.itemReads == 4) h.currentDestination = destination.copy(canWrite = false) }
        assertTrue(runCatching { h.repo.changeISOMountResult(change, true) }.isFailure); assertEquals(0, h.writes)
        val noMetadata = Harness(); noMetadata.itemTransform = { JsonObject(it - "size") }
        assertTrue(runCatching { noMetadata.repo.changeISOMountResult(change, true) }.isFailure); assertEquals(0, noMetadata.writes)
    }
    @Test fun secondAuthorizationCheckAndRelatedPermissionChangesPreventWrite() = runBlocking {
        val h = Harness(); h.onRefresh = { if (h.refreshes == 2) h.access = FilePermissionAccess(true, false) }
        assertTrue(runCatching { h.repo.changeISOMountResult(change, true) }.isFailure); assertEquals(0, h.writes)
        for (path in listOf("/synthetic", destination.path + "/child", source.path)) {
            val blocked = Harness(); blocked.permissionPaths = listOf(path)
            assertTrue(runCatching { blocked.repo.changeISOMountResult(change, true) }.isFailure); assertEquals(0, blocked.writes)
        }
    }
    @Test fun existingRelatedRemoteOrIsoMountIsNeverImplicitlyDisconnected() = runBlocking {
        for (mounted in listOf(connection, connection.copy(mountPoint = destination.path + "/child"),
            connection.copy(mountPoint = "/synthetic/empty ", kind = FileMountKind.CIFS, source = "//synthetic.invalid/share"))) {
            val h = Harness(); h.connections = listOf(mounted)
            assertTrue(runCatching { h.repo.changeISOMountResult(change, true) }.isFailure); assertEquals(0, h.writes)
        }
    }
    @Test fun unresolvedRemoteConnectionBlocksIsoAtTheSameDestination() = runBlocking {
        val h = Harness()
        val store = FileRemoteMountRecoveryStore(MemoryPreferences())
        val setup = FileRemoteMountSetup(kind = FileMountKind.NFS, server = "synthetic.invalid", remotePath = "share", mountPoint = destination.path)
        store.begin(FileRemoteMountPending(owner = owner, action = RemoteMountAction.CREATE, baseline = null, setup = setup,
            stage = RemoteMountStage.CHECK_CONNECTION))
        h.repo.remote.bindRecovery(store)
        assertEquals(DsmErrorKind.FILE_MOUNT_PENDING, (runCatching { h.repo.changeISOMountResult(change, true) }.exceptionOrNull() as DsmFailure).kind)
        assertEquals(0, h.writes)
    }
    @Test fun acknowledgedMountNeedsExactSourceAutomaticAndIsoDirectory() = runBlocking {
        for (after in listOf<(Harness) -> Unit>({ it.connections = listOf(connection.copy(source = "/synthetic/another.iso")) },
            { it.connections = listOf(connection.copy(automatic = null)) }, { it.currentDestination = destination },
            { it.currentDestination = destination.copy(mountPointType = "cifs") })) {
            val h = Harness(); h.afterWrite = { after(h) }
            assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, h.repo.changeISOMountResult(change, true).status)
            assertEquals(1, h.repo.pending().size); assertEquals(1, h.writes)
        }
    }
    @Test fun disconnectRequiresOriginalIdentityAndLeavesFilesUntouched() = runBlocking {
        val h = Harness(); h.connections = listOf(connection); h.currentDestination = destination.copy(mountPointType = "iso")
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS,
            h.repo.changeISOMountResult(FileISOMountChange.Unmount(connection), true).status)
        assertEquals(Call(MOUNT_LIST_API, "unmount", mapOf("mount_point" to mountStrings(listOf(destination.path))), 1),
            h.calls.single { it.method == "unmount" })
        assertFalse(h.calls.any { it.api.contains("Delete") }); assertEquals(source, h.currentSource)
        val stale = Harness(); stale.connections = listOf(connection.copy(automatic = true)); stale.currentDestination = destination.copy(mountPointType = "iso")
        assertTrue(runCatching { stale.repo.changeISOMountResult(FileISOMountChange.Unmount(connection), true) }.isFailure)
        assertEquals(0, stale.writes)
    }
    @Test fun disconnectReadFailureIsUnknownWhileExplicitMissingCanComplete() = runBlocking {
        for (missing in listOf(false, true)) {
            val h = Harness(); h.connections = listOf(connection); h.currentDestination = destination.copy(mountPointType = "iso")
            h.afterWrite = { if (missing) h.missing = true else h.itemFailure = true }
            assertEquals(if (missing) MutationResultStatus.CONFIRMED_SUCCESS else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                h.repo.changeISOMountResult(FileISOMountChange.Unmount(connection), true).status)
        }
    }
    @Test fun connectionLossAndColdRecoveryNeverResubmitUnknownMount() = runBlocking {
        val preferences = MemoryPreferences(); val h = Harness(preferences); h.applyWrite = false; h.afterWrite = { throw IOException("synthetic disconnect") }
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, h.repo.changeISOMountResult(change, true).status)
        val cold = Harness(preferences); cold.identity = owner.copy(sessionGeneration = "new-session")
        assertTrue(runCatching { cold.repo.changeISOMountResult(change, true) }.isFailure); assertEquals(0, cold.writes)
        val record = cold.repo.pending().single()
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, cold.repo.review(record.id).status); assertEquals(0, cold.writes)
        cold.connections = listOf(connection); cold.currentDestination = destination.copy(mountPointType = "iso")
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, cold.repo.review(record.id).status); assertTrue(cold.repo.pending().isEmpty())
        assertEquals(0, cold.writes)
    }
    @Test fun wrongIdentityAndStorageFailureCannotStartOrFinishAnotherOwnersOperation() = runBlocking {
        val preferences = MemoryPreferences(); val h = Harness(preferences); preferences.commitSucceeds = false
        assertTrue(runCatching { h.repo.changeISOMountResult(change, true) }.isFailure); assertEquals(0, h.writes)
        val fresh = Harness(); fresh.applyWrite = false; fresh.repo.changeISOMountResult(change, true)
        val record = fresh.repo.pending().single(); fresh.identity = owner.copy(identityRevision = "other")
        assertTrue(fresh.repo.pending().isEmpty()); assertTrue(runCatching { fresh.repo.review(record.id) }.isFailure)
        fresh.identity = owner; fresh.ownerValid = false
        assertTrue(runCatching { fresh.repo.review(record.id) }.isFailure)
    }
    @Test fun crossInstanceRecoveryStoreRejectsOverlappingTargetsButAllowsSiblings() {
        val prefs = MemoryPreferences(); val a = FileISOMountRecoveryStore(prefs); val b = FileISOMountRecoveryStore(prefs)
        val first = FileISOMountPending(owner = owner, connecting = true, connection = connection)
        a.begin(first)
        assertTrue(runCatching { b.begin(first.copy(id = "child", connection = connection.copy(mountPoint = destination.path + "/child"))) }.isFailure)
        b.begin(first.copy(id = "sibling", connection = connection.copy(mountPoint = "/synthetic/sibling")))
        assertEquals(2, a.pending(owner).size)
    }
    @Test fun cancellationAndConcurrentDuplicateKeepOneWriteAndRecoverableRecord() = runBlocking {
        val h = Harness(); h.applyWrite = false
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        h.afterWrite = { entered.complete(Unit); release.await() }
        val first = launch { h.repo.changeISOMountResult(change, true) }; entered.await()
        assertTrue(runCatching { h.repo.changeISOMountResult(change, true) }.isFailure)
        first.cancelAndJoin(); release.complete(Unit)
        assertEquals(1, h.writes); assertEquals(1, h.repo.pending().size)
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, h.repo.review(h.repo.pending().single().id).status)
        assertEquals(1, h.writes)
    }
    @Test fun explicitPermissionRejectionClearsOnlyThatOperation() = runBlocking {
        val h = Harness(); h.applyWrite = false; h.afterWrite = { throw DsmFailure(119, "", "", kind = DsmErrorKind.PERMISSION_DENIED) }
        assertEquals(MutationResultStatus.PERMISSION_DENIED, h.repo.changeISOMountResult(change, true).status)
        assertTrue(h.repo.pending().isEmpty())
    }

    @Test fun observedEmptyMountTypeIsOrdinaryButMissingFieldRemainsUnknown() = runBlocking {
        val h = Harness(); h.currentSource = source.copy(mountPointType = ""); h.currentDestination = destination.copy(mountPointType = "")
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS,
            h.repo.changeISOMountResult(change.copy(source = h.currentSource, destination = h.currentDestination), true).status)
        h.afterWrite = { h.currentDestination = destination.copy(mountPointType = "") }
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS,
            h.repo.changeISOMountResult(FileISOMountChange.Unmount(connection), true).status)
        val unknown = Harness(); unknown.currentDestination = destination.copy(mountPointType = null)
        assertTrue(runCatching { unknown.repo.changeISOMountResult(change.copy(destination = unknown.currentDestination), true) }.isFailure)
        assertEquals(0, unknown.writes)
    }

    private data class Call(val api: String, val method: String, val parameters: Map<String, String>, val version: Int?)
    private fun row(value: FileMountConnection) = buildJsonObject {
        put("type", value.kind.name.lowercase()); put("source", value.source); put("mount_point", value.mountPoint)
        value.automatic?.let { put("auto_mount", it) }
    }
    @Test fun isoMountUsesActualCapabilityAndPermissionsWithoutVersionCallback() = runBlocking {
        val h = Harness(); assertTrue(h.repo.inventory().isoEnabled)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, h.repo.changeISOMountResult(change, true).status)
        assertEquals(1, h.writes); assertTrue(h.repo.pending().isEmpty())
    }

    private inner class Harness(preferences: MemoryPreferences = MemoryPreferences()) {
        val calls = mutableListOf<Call>()
        var identity = owner; var ownerValid = true; var supported = true
        var access = FilePermissionAccess(true, true)
        var currentSource = source; var currentDestination = destination
        var connections = emptyList<FileMountConnection>(); var permissionPaths = emptyList<String>()
        var isoEnabled = true; var contents = 0; var missing = false; var itemFailure = false; var applyWrite = true
        var writes = 0; var refreshes = 0; var itemReads = 0; var emptyReads = 0
        var onRefresh: () -> Unit = {}; var onItemRead: () -> Unit = {}; var afterWrite: suspend () -> Unit = {}
        var inventoryTransform: (JsonObject) -> JsonObject = { it }; var emptyTransform: (JsonObject) -> JsonObject = { it }
        var itemTransform: (JsonObject) -> JsonObject = { it }
        val repo = DsmFileMountRepository({ _, _ -> supported }, { api, method, parameters, version ->
            calls += Call(api, method, parameters, version)
            when (method) {
                "get" -> inventoryTransform(buildJsonObject {
                    putJsonObject("mountConfig") { put("enable_iso_mount", isoEnabled); put("enable_remote_mount", true) }
                    put("isoList", JsonArray(connections.filter { it.kind == FileMountKind.ISO }.map(::row)))
                    put("remoteList", JsonArray(connections.filter { it.kind != FileMountKind.ISO }.map(::row)))
                })
                "getinfo" -> {
                    itemReads++; onItemRead(); if (itemFailure) throw IOException("synthetic read failure")
                    val path = Json.parseToJsonElement(parameters.getValue("path")).jsonArray.single().jsonPrimitive.content
                    val item = if (path == source.path) currentSource else currentDestination
                    buildJsonObject { putJsonArray("files") { add(if (missing) buildJsonObject { put("path", path); put("code", 408) } else itemTransform(buildJsonObject {
                        put("path", item.path); put("name", item.name); put("isdir", item.isDirectory); put("size", item.size)
                        putJsonObject("additional") { put("mount_point_type", item.mountPointType); putJsonObject("time") { put("mtime", item.modifiedAtEpochSeconds) }
                            putJsonObject("perm") { putJsonObject("acl") { put("read", item.canRead); put("write", item.canWrite); put("del", item.canDelete) } } }
                    })) } }
                }
                "list" -> { emptyReads++; emptyTransform(buildJsonObject { put("offset", 0); put("total", contents); putJsonArray("files") {} }) }
                "mount_iso", "unmount" -> {
                    writes++
                    if (applyWrite) {
                        connections = if (method == "mount_iso") listOf(connection.copy(automatic = parameters["auto_mount"] == "true")) else emptyList()
                        currentDestination = destination.copy(mountPointType = if (method == "mount_iso") "iso" else "normal")
                    }
                    afterWrite(); buildJsonObject {}
                }
                else -> error("Unexpected synthetic request")
            }
        }, { access }, { refreshes++; onRefresh() }, { true }, {}, { permissionPaths }, { identity },
            { if (!ownerValid) throw DsmFailure(null, "", "", kind = DsmErrorKind.WORKSPACE_CHANGED) }).also {
            it.bindRecovery(FileISOMountRecoveryStore(preferences))
            it.remote.bindRecovery(FileRemoteMountRecoveryStore(MemoryPreferences()))
        }
    }
}

package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class FileVFSReaderTest {
    private val owner = WorkspaceOwner("synthetic-vfs", "identity", "session")
    private val profile = FileVFSProfile(owner, "opaque-id", "davs", "WebDAV", "davs://opaque-root/folder", "server.invalid", 443,
        "Synthetic", "synthetic-account", "UTF-8", FileVFSConnectionState.CONNECTED)
    private val configuration = FileVFSConfiguration("davs", "server.invalid", 443, "Synthetic", "synthetic-account", folder = "folder")
    private fun profileRow(value: FileVFSProfile = profile) = buildJsonObject {
        put("id", value.id); put("protocol", value.protocolId); put("protocol_name", value.protocolName); put("uri", value.uri)
        put("hostname", value.hostname); put("port", value.port); put("alias", value.alias); put("account", value.account); put("codepage", value.codepage)
        put("connect_status", when (value.state) { FileVFSConnectionState.CONNECTED -> 1; FileVFSConnectionState.DISCONNECTED -> 0; else -> 7 })
    }
    private class Call(val api: String, val method: String, val fields: Map<String, String>, val version: Int)
    private inner class Harness {
        val calls = mutableListOf<Call>()
        var rows = listOf(profileRow())
        var changedOwner = false
        var detail = buildJsonObject { put("hostname", configuration.hostname); put("port", 443); put("alias", configuration.alias)
            put("account", configuration.account); put("codepage", "UTF-8"); put("uri_path", "folder"); put("max_connection", 0)
            put("password", "synthetic-do-not-retain") }
        var protocols = buildJsonObject { putJsonArray("protocols") { add(buildJsonObject {
            put("protocol", "ftp"); put("name", "FTP"); put("default_port", 21); put("has_server", false)
        }) } }
        var page = buildJsonObject { put("offset", 0); put("total", 1); putJsonArray("files") { add(buildJsonObject {
            put("path", profile.uri + "/Child"); put("name", "Child"); put("isdir", true)
        }) } }
        val reader = FileVFSReader({ api, method, fields, version ->
            calls += Call(api, method, fields, version)
            when (api) {
                VFS_PROTOCOL_API -> protocols
                VFS_PROFILE_API -> if (method == "get") detail else buildJsonObject { put("total", rows.size); put("profiles", JsonArray(rows)) }
                "SYNO.FileStation.List" -> page
                else -> error("Unexpected API")
            }
        }, { owner }, { check(!changedOwner) })
    }
    @Test fun protocolHasServerFalseStillAllowsFtpSetupAndUsesFixedVersion() = runBlocking {
        val h = Harness(); val option = h.reader.protocols().single()
        assertFalse(option.hasConnections); assertTrue(option.supportsServerSetup); assertEquals(21, option.defaultPort)
        assertEquals("list", h.calls.single().method); assertEquals(1, h.calls.single().version)
    }
    @Test fun malformedAndDuplicateProtocolFieldsNeverBecomeAnEmptyList() = runBlocking {
        for (rows in listOf("null", "[]", "[{}]", "[{\"protocol\":\"ftp\",\"name\":\"FTP\",\"has_server\":\"false\"}]")) {
            val h = Harness(); h.protocols = Json.parseToJsonElement("{\"protocols\":$rows}").jsonObject
            if (rows == "[]") assertTrue(h.reader.protocols().isEmpty()) else assertTrue(runCatching { h.reader.protocols() }.isFailure)
        }
        val h = Harness(); val row = h.protocols["protocols"]!!.jsonArray.single()
        h.protocols = buildJsonObject { put("protocols", JsonArray(listOf(row, row))) }
        assertTrue(runCatching { h.reader.protocols() }.isFailure)
    }
    @Test fun profilesRetainOpaqueIdentityUnknownStateAndRejectDuplicateOrWrongTypedFields() = runBlocking {
        val h = Harness(); h.rows = listOf(profileRow(profile.copy(state = FileVFSConnectionState.UNKNOWN)))
        assertEquals(FileVFSConnectionState.UNKNOWN, h.reader.profiles().single().state)
        assertEquals("opaque-id", h.reader.profiles().single().id)
        h.rows = listOf(profileRow(), profileRow()); assertTrue(runCatching { h.reader.profiles() }.isFailure)
        h.rows = listOf(JsonObject(profileRow() + ("port" to JsonPrimitive("443"))))
        assertTrue(runCatching { h.reader.profiles() }.isFailure)
    }
    @Test fun detailDoesNotReadPasswordAndRequiresOriginalIdentity() = runBlocking {
        val h = Harness(); val result = h.reader.detail(profile)
        assertEquals(configuration, result.configuration); assertFalse(result.toString().contains("synthetic-do-not-retain"))
        assertEquals(mapOf("id" to "opaque-id"), h.calls.last().fields)
        h.rows = listOf(profileRow(profile.copy(account = "another-account")))
        assertTrue(runCatching { h.reader.detail(profile) }.isFailure)
        assertEquals(1, h.calls.count { it.method == "get" })
    }
    @Test fun remoteFolderKeepsOriginalUriAndRefusesRootEscapeOrIncompletePages() = runBlocking {
        val h = Harness(); val result = h.reader.folder(profile, profile.uri, 0)
        assertEquals(profile.uri + "/Child", result.items.single().path)
        assertEquals(profile.uri, h.calls.last().fields["folder_path"]); assertEquals(2, h.calls.last().version)
        for (path in listOf(profile.uri + "/../other", profile.uri + "-other", "/synthetic")) {
            assertTrue(runCatching { h.reader.folder(profile, path, 0) }.isFailure)
        }
        h.page = buildJsonObject { put("offset", 0); put("total", 2); putJsonArray("files") {} }
        assertTrue(runCatching { h.reader.folder(profile, profile.uri, 0) }.isFailure)
    }
    @Test fun everyPageRejectsChangedAccountSessionAndConnectionState() = runBlocking {
        val h = Harness(); h.rows = listOf(profileRow(profile.copy(state = FileVFSConnectionState.DISCONNECTED)))
        assertTrue(runCatching { h.reader.folder(profile, profile.uri, 0) }.isFailure)
        h.rows = listOf(profileRow()); h.changedOwner = true
        assertTrue(runCatching { h.reader.folder(profile, profile.uri, 0) }.isFailure)
        assertTrue(h.calls.none { it.api == "SYNO.FileStation.List" })
        assertFalse(profile.sameIdentity(profile.copy(owner = owner.copy(identityRevision = "other"))))
        assertTrue(profile.sameIdentity(profile.copy(owner = owner.copy(sessionGeneration = "new-session"))))
    }
    @Test fun detailMismatchAndNonNativeConnectionCountAreRejected() = runBlocking {
        for (pair in listOf("hostname" to JsonPrimitive("other.invalid"), "max_connection" to JsonPrimitive(2), "max_connection" to JsonPrimitive("0"))) {
            val h = Harness(); h.detail = JsonObject(h.detail + pair)
            assertTrue(runCatching { h.reader.detail(profile) }.isFailure)
        }
    }
}

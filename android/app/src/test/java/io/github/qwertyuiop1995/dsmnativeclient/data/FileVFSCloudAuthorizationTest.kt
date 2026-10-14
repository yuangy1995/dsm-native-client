package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.net.Socket
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder

class FileVFSCloudAuthorizationTest {
    private val request = FileVFSCloudRequest(owner = WorkspaceOwner("synthetic", "identity", "session"), protocolId = "google",
        loginUrl = "https://synooauth.synology.com/FileStation/Cloud/login.php?major=7&minor=2&type=google", createdAtMillis = 1000)
    private val host = "127.0.0.1:12345"
    private val path = "/synthetic-random-path"
    private val json get() = buildJsonObject { put("callback", request.callbackName); put("account", "synthetic-account")
        put("access_token", "synthetic-access"); put("refresh_token", "synthetic-refresh"); put("client_id", "synthetic-client"); put("expires_in", 3600) }
    private fun encode(value: String) = URLEncoder.encode(value, "UTF-8")
    private val form get() = json.entries.joinToString("&") { (key, value) -> encode(key) + "=" + encode(value.jsonPrimitive.content) }
    private fun http(method: String = "GET", target: String = path, body: String = "", type: String = "application/json", hostname: String = host): ByteArray {
        val bytes = body.toByteArray()
        return ("$method $target HTTP/1.1\r\nHost: $hostname\r\nContent-Type: $type\r\nContent-Length: ${bytes.size}\r\n\r\n".toByteArray() + bytes)
    }
    private fun decode(bytes: ByteArray) = FileVFSCloudCallbackHTTP.decode(bytes)!!.authorization(request, host, path)
    @Test fun acceptsRecordedQueryFormJsonAndStringDataWrapperWithoutLeakingDescription() {
        val cases = listOf(http(target = "$path?$form"), http("POST", body = form, type = "application/x-www-form-urlencoded; charset=UTF-8"),
            http("POST", body = json.toString()), http("POST", body = "data=" + encode(json.toString()), type = "application/x-www-form-urlencoded"))
        cases.forEach { bytes ->
            val value = decode(bytes)
            assertEquals(request.id, value.requestId); assertEquals(request.owner, value.owner); assertEquals("google", value.protocolId)
            assertEquals("synthetic-access", value.accessToken); assertEquals(3600, value.expiresIn)
            assertFalse(value.toString().contains("synthetic-access")); assertFalse(FileVFSCloudCallbackHTTP.decode(bytes).toString().contains("synthetic-access"))
        }
    }
    @Test fun partialBodyWaitsAndOversizedTrailingOrDuplicateHeaderInputIsRejected() {
        val bytes = http("POST", body = json.toString())
        assertNull(FileVFSCloudCallbackHTTP.decode(bytes.copyOf(bytes.size - 1)))
        assertTrue(runCatching { decode(bytes + byteArrayOf(1)) }.isFailure)
        assertTrue(runCatching { FileVFSCloudCallbackHTTP.decode(ByteArray(131_073)) }.isFailure)
        val duplicate = String(bytes).replace("Host: $host", "Host: $host\r\nHost: $host")
        assertTrue(runCatching { decode(duplicate.toByteArray()) }.isFailure)
        val chunked = String(bytes).replace("Host: $host", "Host: $host\r\nTransfer-Encoding: chunked")
        assertTrue(runCatching { decode(chunked.toByteArray()) }.isFailure)
    }
    @Test fun wrongHostPathNonceAndConflictingFieldsNeverProduceAuthorization() {
        val cases = listOf(http("POST", body = json.toString(), hostname = "localhost:12345"), http("POST", target = path + "other", body = json.toString()),
            http("POST", body = JsonObject(json + ("callback" to JsonPrimitive("other"))).toString()),
            http("POST", target = "$path?account=other", body = json.toString()), http(target = "$path?$form&callback=other"))
        cases.forEach { assertTrue(runCatching { decode(it) }.isFailure) }
    }
    @Test fun missingOrWrongTypedTokensAndExpiryAreRejectedRatherThanCoerced() {
        for (value in listOf(JsonObject(json - "access_token"), JsonObject(json + ("access_token" to JsonPrimitive(1))),
            JsonObject(json + ("expires_in" to JsonPrimitive(true))), JsonObject(json + ("expires_in" to JsonPrimitive(-1))))) {
            assertTrue(runCatching { decode(http("POST", body = value.toString())) }.isFailure)
        }
        assertNull(decode(http("POST", body = JsonObject(json + ("expires_in" to JsonNull)).toString())).expiresIn)
    }
    @Test fun unsupportedMethodsAbsoluteTargetsAndMalformedEncodingAreRejected() {
        for (bytes in listOf(http("PUT", body = json.toString()), http(target = "https://example.invalid/$path"),
            http("POST", body = json.toString(), type = "text/plain"), http(target = "$path?data=%ZZ"))) {
            assertTrue(runCatching { decode(bytes) }.isFailure)
        }
    }
    @Test fun realLoopbackSessionReturnsSafePageAndDeliversAuthorizationOnce() = runBlocking {
        val result = CompletableDeferred<FileVFSCloudAuthorization>()
        val session = FileVFSCloudAuthorizationSession(request, this, "Synthetic sign-in complete", "Synthetic sign-in failed", result::complete,
            { result.completeExceptionally(IllegalStateException("Unexpected callback failure")) })
        try {
            val login = URI(session.start())
            val query = fields(login.rawQuery); val callback = URI(query.getValue("host"))
            assertEquals("127.0.0.1", callback.host); assertTrue(callback.port > 0); assertNotEquals("/", callback.path)
            assertEquals(request.callbackName, query["callback"]); assertTrue(session.isRunning)
            val response = withContext(Dispatchers.IO) {
                Socket(callback.host, callback.port).use { socket ->
                    socket.soTimeout = 5000
                    socket.getOutputStream().write(http("POST", callback.path, json.toString(), hostname = "127.0.0.1:${callback.port}"))
                    socket.getOutputStream().flush(); socket.getInputStream().bufferedReader().readText()
                }
            }
            assertTrue(response.startsWith("HTTP/1.1 200")); assertTrue(response.contains("Cache-Control: no-store")); assertTrue(response.contains("history.replaceState"))
            assertFalse(response.contains("synthetic-access")); assertFalse(response.contains(request.callbackName))
            assertEquals("synthetic-access", withTimeout(5000) { result.await() }.accessToken)
            assertFalse(session.isRunning)
            assertTrue(runCatching { session.start() }.isFailure)
        } finally { session.close() }
    }
    @Test fun invalidCallbackDoesNotConsumeSessionBeforeValidBrowserReturn() = runBlocking {
        val result = CompletableDeferred<FileVFSCloudAuthorization>()
        val session = FileVFSCloudAuthorizationSession(request, this, "Done", "Failed", result::complete, {})
        try {
            val callback = URI(fields(URI(session.start()).rawQuery).getValue("host"))
            suspend fun send(body: String) = withContext(Dispatchers.IO) {
                Socket(callback.host, callback.port).use { socket ->
                    socket.soTimeout = 5000; socket.getOutputStream().write(http("POST", callback.path, body, hostname = "127.0.0.1:${callback.port}"))
                    socket.getInputStream().bufferedReader().readText()
                }
            }
            assertTrue(send("{}").startsWith("HTTP/1.1 400")); assertFalse(result.isCompleted); assertTrue(session.isRunning)
            assertTrue(send(json.toString()).startsWith("HTTP/1.1 200")); withTimeout(5000) { result.await() }; Unit
        } finally { session.close() }
    }
    @Test fun expiryAndExplicitCloseReleaseListenerWithoutAuthorization() = runBlocking {
        val expired = CompletableDeferred<FileVFSCloudSessionFailure>()
        val session = FileVFSCloudAuthorizationSession(request, this, "Done", "Failed", { error("Unexpected authorization") }, expired::complete, 30)
        val callback = URI(fields(URI(session.start()).rawQuery).getValue("host"))
        assertEquals(FileVFSCloudSessionFailure.EXPIRED, withTimeout(5000) { expired.await() }); assertFalse(session.isRunning)
        assertTrue(runCatching { Socket(callback.host, callback.port).close() }.isFailure)
        val closed = FileVFSCloudAuthorizationSession(request, this, "Done", "Failed", { error("Unexpected authorization") }, {})
        closed.close(); assertTrue(runCatching { closed.start() }.isFailure)
    }
    @Test fun parentScopeCancellationClosesListener() = runBlocking {
        val parent = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val session = FileVFSCloudAuthorizationSession(request, parent, "Done", "Failed", { error("Unexpected authorization") }, {})
        try {
            val callback = URI(fields(URI(session.start()).rawQuery).getValue("host"))
            parent.cancel()
            withTimeout(5000) { while (session.isRunning) delay(10) }
            assertTrue(runCatching { Socket(callback.host, callback.port).close() }.isFailure)
        } finally { session.close(); parent.cancel() }
    }
    private fun fields(query: String) = query.split('&').associate { pair ->
        pair.substringBefore('=') to URLDecoder.decode(pair.substringAfter('='), "UTF-8")
    }
}

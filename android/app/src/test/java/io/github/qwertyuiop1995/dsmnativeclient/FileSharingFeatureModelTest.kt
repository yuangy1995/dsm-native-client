package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.time.LocalDate

class FileSharingFeatureModelTest {
    private val profile = NasProfile("share-model", "NAS", "https://synthetic.example.invalid", "synthetic")
    private val sources = listOf("a", "b", "c").map { FileItem("/synthetic/$it", it, false, canRead = true) }

    @Test fun batchPreservesPartialSuccessClearsPasswordAndCannotBeSubmittedTwice() = runBlocking {
        val fixture = Fixture(this)
        fixture.rejectPath = sources[1].path
        assertTrue(fixture.feature.openCreate(sources.take(2)))
        fixture.feature.edit { it.copy(password = "synthetic-secret") }
        assertFalse(fixture.feature.state.value.toString().contains("synthetic-secret"))
        fixture.feature.submit()
        assertEquals("", fixture.feature.state.value.draft.password)
        await { !fixture.feature.state.value.busy }
        assertEquals(listOf(MutationResultStatus.CONFIRMED_SUCCESS, MutationResultStatus.PERMISSION_DENIED), fixture.feature.state.value.results.map { it.outcome.result.status })
        fixture.feature.submit()
        assertEquals(2, fixture.writes.size)
        assertTrue(fixture.writes.all { it["password"] == "synthetic-secret" })
        assertFalse(fixture.current.isPerformingAction)
    }

    @Test fun stopRemainingNeverCancelsOrReplaysAlreadySubmittedItem() = runBlocking {
        val fixture = Fixture(this)
        val gate = CountDownLatch(1)
        fixture.writeGate = gate
        fixture.feature.openCreate(sources)
        fixture.feature.submit()
        await { fixture.writes.isNotEmpty() }
        fixture.feature.stopAfterCurrent(); gate.countDown()
        await { !fixture.feature.state.value.busy }
        assertEquals(listOf(MutationResultStatus.CONFIRMED_SUCCESS, MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, MutationResultStatus.CANCELLED_BEFORE_SUBMISSION), fixture.feature.state.value.results.map { it.outcome.result.status })
        assertEquals(1, fixture.writes.size)
    }

    @Test fun batchEditPreservesSuccessfulLinksWhenAnotherLinkRejectsChanges() = runBlocking {
        val fixture = Fixture(this)
        fixture.feature.openCreate(sources.take(2)); fixture.feature.submit()
        await { !fixture.feature.state.value.busy }
        val links = fixture.feature.state.value.results.map { it.outcome.link!! }
        fixture.feature.close(); fixture.rejectPath = sources[1].path
        assertTrue(fixture.feature.openEdit(links))
        fixture.feature.edit { it.copy(expiresOn = FileShareDateChange.Set(LocalDate.of(2027,1,1))) }
        fixture.feature.submit()
        await { !fixture.feature.state.value.busy }
        assertEquals(listOf(MutationResultStatus.CONFIRMED_SUCCESS, MutationResultStatus.PERMISSION_DENIED), fixture.feature.state.value.results.map { it.outcome.result.status })
        assertEquals(2, fixture.writes.count { it["method"] == "edit" })
        fixture.feature.submit()
        assertEquals(2, fixture.writes.count { it["method"] == "edit" })
    }

    @Test fun changingWorkspacePreventsOldDraftSubmissionAndLateListPublication() = runBlocking {
        val fixture = Fixture(this)
        fixture.feature.openCreate(sources)
        fixture.activeRepository = null
        fixture.feature.submit()
        assertTrue(fixture.writes.isEmpty())
        fixture.activeRepository = fixture.repo
        val gate = CountDownLatch(1)
        fixture.listGate = gate
        fixture.feature.refreshLinks()
        await { fixture.listStarted.count == 0L }
        fixture.activeRepository = null
        fixture.current = fixture.current.copy(profile = profile.copy(id = "other"), fileShareLinks = Loadable.Ready(emptyList()))
        gate.countDown()
        currentCoroutineContext()[Job]!!.children.toList().joinAll()
        assertEquals("other", fixture.current.profile.id)
        assertEquals(emptyList<FileShareLink>(), (fixture.current.fileShareLinks as Loadable.Ready).value)
    }

    @Test fun ordinaryCreateNeedsNoExtraConfirmationButCollectionDoes() = runBlocking {
        val fixture = Fixture(this)
        assertTrue(fixture.feature.openCreate(sources.take(1)))
        fixture.feature.submit()
        assertFalse(fixture.feature.state.value.confirmation)
        await { !fixture.feature.state.value.busy }
        fixture.feature.close()
        assertTrue(fixture.feature.openCreate(listOf(sources[0].copy(isDirectory = true, canWrite = true))))
        fixture.feature.edit { it.copy(fileRequest = true) }
        fixture.feature.submit()
        assertTrue(fixture.feature.state.value.confirmation)
        assertEquals(1, fixture.writes.size)
        fixture.feature.dismissConfirmation()
        assertFalse(fixture.feature.state.value.confirmation)
        assertFalse(fixture.feature.state.value.submitted)
    }

    @Test fun revokedModuleOrExistingMutationDoesNotOpenAnotherWrite() = runBlocking {
        val fixture = Fixture(this)
        fixture.current = fixture.current.copy(isPerformingAction = true)
        assertFalse(fixture.feature.openCreate(sources))
        fixture.current = fixture.current.copy(isPerformingAction = false, selectedModule = Module.SETTINGS)
        assertFalse(fixture.feature.openCreate(sources))
        assertTrue(fixture.writes.isEmpty())
    }

    private suspend fun await(predicate: () -> Boolean) = withTimeout(5_000) { while (!predicate()) delay(10) }

    private inner class Fixture(scope: CoroutineScope) {
        @Volatile var current = WorkspaceState(profile, selectedModule = Module.FILES)
        @Volatile var rejectPath: String? = null
        @Volatile var writeGate: CountDownLatch? = null
        @Volatile var listGate: CountDownLatch? = null
        val listStarted = CountDownLatch(1)
        val writes = Collections.synchronizedList(mutableListOf<Map<String, String>>())
        private val links = Collections.synchronizedList(mutableListOf<JsonObject>())
        val repo = authorizedRepository(profile, DsmSession(profile.id, "synthetic-session"), DsmApiClient(
            OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); val form = request.body as FormBody
                val fields = (0 until form.size).associate { form.name(it) to form.value(it) }
                var apiError: Int? = null
                val data = when (fields["api"] to fields["method"]) {
                    "SYNO.FileStation.List" to "getinfo" -> {
                        val path = Json.parseToJsonElement(fields.getValue("path")).jsonArray.single().jsonPrimitive.content
                        buildJsonObject { putJsonArray("files") { add(buildJsonObject {
                            put("path", path); put("name", path.substringAfterLast('/')); put("isdir", false)
                            putJsonObject("additional") { putJsonObject("perm") {
                                put("is_acl_mode", false); putJsonObject("acl") { put("read", true); put("write", false); put("del", false) }
                            } }
                        }) } }
                    }
                    "SYNO.FileStation.Sharing" to "list" -> {
                        listStarted.countDown(); listGate?.await(3, TimeUnit.SECONDS)
                        synchronized(links) { buildJsonObject { put("links", JsonArray(links.toList())); put("total", links.size) } }
                    }
                    "SYNO.FileStation.Sharing" to "create" -> {
                        writes += fields; writeGate?.await(3, TimeUnit.SECONDS)
                        val path = Json.parseToJsonElement(fields.getValue("path")).jsonArray.single().jsonPrimitive.content
                        val id = "link-${writes.size}"
                        val error = if (path == rejectPath) 105 else 0
                        if (error == 0) links += buildJsonObject {
                            put("id", id); put("path", path); put("url", "https://share.example.invalid/$id")
                            put("has_password", fields["password"]?.isNotEmpty() == true); put("date_available", 0); put("date_expired", 0)
                        }
                        buildJsonObject { putJsonArray("links") { add(buildJsonObject { put("id", id); put("path", path); put("error", error) }) } }
                    }
                    "SYNO.FileStation.Sharing" to "edit" -> {
                        writes += fields
                        val id = Json.parseToJsonElement(fields.getValue("id")).jsonArray.single().jsonPrimitive.content
                        val index = links.indexOfFirst { it["id"]!!.jsonPrimitive.content == id }
                        if (links[index]["path"]!!.jsonPrimitive.content == rejectPath) apiError = 105
                        else links[index] = JsonObject(links[index] + ("date_expired" to JsonPrimitive(fields.getValue("date_expired"))))
                        buildJsonObject {}
                    }
                    else -> error("Unexpected synthetic request")
                }
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                    .body((apiError?.let { "{\"success\":false,\"error\":{\"code\":$it}}" } ?: "{\"success\":true,\"data\":$data}").toResponseBody("application/json".toMediaType())).build()
            }.build()), mapOf("SYNO.FileStation.List" to ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2),
                "SYNO.FileStation.Sharing" to ApiCapability("SYNO.FileStation.Sharing", "entry.cgi", 1, 3)))
        @Volatile var activeRepository: DsmRepository? = repo
        val feature = FileSharingFeatureModel(scope, { activeRepository }, { current }, { current = current.copy(fileShareLinks = it) }, { current = current.copy(isPerformingAction = it) })
    }
}

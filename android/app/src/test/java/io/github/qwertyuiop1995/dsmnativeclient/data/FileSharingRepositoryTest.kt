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
import java.time.LocalDate

class FileSharingRepositoryTest {
    private val source = FileItem("/synthetic/folder ", "folder ", true, canRead = true, canWrite = true)
    private val owner = WorkspaceOwner("synthetic", "identity-a", "session-a")
    private val json = Json

    @Test fun listPreservesRawPathTimestampProtectionAndUnknownFields() = runBlocking {
        val raw = link(available = "2026-10-11 13:24:56", password = true)
        val repo = harness(page(raw)).repo
        val value = repo.list().single()
        assertEquals(source.path, value.path)
        assertEquals("2026-10-11 13:24:56", value.availableAt)
        assertTrue(value.passwordKnown && value.availabilityKnown && value.expirationKnown)
        assertTrue(value.hasPassword)
        val incomplete = parseFileShareLink(JsonObject(raw - setOf("has_password", "date_available", "protect_groups")))
        assertFalse(incomplete.passwordKnown)
        assertFalse(incomplete.availabilityKnown)
        assertNull(incomplete.advanced)
        assertFalse(FileShareEditRequest(incomplete, password = FileSharePasswordChange.Remove).isValid)
    }

    @Test fun malformedDateAndCredentialBearingUrlAreRejected() {
        listOf("2026-02-30", "2026-10-11 29:00:00", "2026-10-11T12:00:00").forEach { date ->
            assertThrows(DsmFailure::class.java) { parseFileShareLink(link(available = date)) }
        }
        assertThrows(DsmFailure::class.java) { parseFileShareLink(JsonObject(link() + ("url" to JsonPrimitive("https://name:secret@example.invalid/share")))) }
    }

    @Test fun completePagingContinuesAfterShortPageAndRejectsDuplicates() = runBlocking {
        val transport = harness(page(link("one"), total = 2), page(link("two"), total = 2, offset = 1))
        assertEquals(listOf("one", "two"), transport.repo.list().map { it.id })
        assertEquals(listOf("0", "1"), transport.calls.map { it.parameters["offset"] })
        val duplicate = harness(page(link("one"), total = 2), page(link("one"), total = 2, offset = 1))
        assertTrue(runCatching { duplicate.repo.list() }.exceptionOrNull() is DsmFailure)
        val truncated = harness(page(link("one"), total = 2), page(total = 2, offset = 1))
        assertTrue(runCatching { truncated.repo.list() }.exceptionOrNull() is DsmFailure)
    }

    @Test fun createCollectionUsesExactV3FieldsAndConfirmsReturnedIdentity() = runBlocking {
        val saved = link(password = true, available = "2026-10-12", expires = "2026-11-12", collection = true, name = "Inbox", message = "Files here")
        val transport = harness(page(), receipt(), page(saved))
        val result = transport.repo.create(FileShareCreateRequest(source, "synthetic-secret", LocalDate.of(2026,10,12), LocalDate.of(2026,11,12), FileRequestConfiguration("Inbox", "Files here")))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.result.status)
        assertEquals("link-a", result.link?.id)
        val write = transport.calls.single { it.method == "create" }
        assertEquals(3, write.version)
        assertEquals(mapOf("path" to "[\"/synthetic/folder \"]", "password" to "synthetic-secret", "date_available" to "2026-10-12",
            "date_expired" to "2026-11-12", "file_request" to "true", "request_name" to "Inbox", "request_info" to "Files here"), write.parameters)
        assertEquals(listOf("list", "create", "list"), transport.calls.map { it.method })
    }

    @Test fun collectionRequiresCurrentDirectoryWritePermission() = runBlocking {
        val transport = harness()
        transport.currentSource = source.copy(canWrite = false)
        val request = FileShareCreateRequest(transport.currentSource, fileRequest = FileRequestConfiguration("", ""))
        assertEquals(MutationResultStatus.PERMISSION_DENIED, transport.repo.create(request).result.status)
        assertTrue(transport.calls.isEmpty())
    }

    @Test fun createWithoutReceiptNeverClaimsAnotherClientsMatchingLink() = runBlocking {
        val transport = harness(page(), buildJsonObject {}, page(link()))
        val result = transport.repo.create(FileShareCreateRequest(source))
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.result.status)
        assertNull(result.link)
        val duplicate = transport.repo.create(FileShareCreateRequest(source))
        assertFalse(duplicate.result.submitted)
        assertEquals(MutationErrorCategory.CONFLICT, duplicate.result.errorCategory)
        assertEquals(1, transport.calls.count { it.method == "create" })
    }

    @Test fun createCannotClaimOldIdentifierOrWrongPathOrMissingProtection() = runBlocking {
        val old = harness(page(link()), receipt(), page(link()))
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, old.repo.create(FileShareCreateRequest(source)).result.status)
        val wrong = harness(page(), buildJsonObject { putJsonArray("links") { add(buildJsonObject { put("id", "link-a"); put("path", "/other"); put("error", 0) }) } }, page(link()))
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, wrong.repo.create(FileShareCreateRequest(source)).result.status)
        val incomplete = harness(page(), receipt(), page(JsonObject(link() - "has_password")))
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, incomplete.repo.create(FileShareCreateRequest(source)).result.status)
    }

    @Test fun createItemRejectionDoesNotBecomeSuccessfulReadback() = runBlocking {
        val transport = harness(page(), receipt(error = 105))
        assertEquals(MutationResultStatus.PERMISSION_DENIED, transport.repo.create(FileShareCreateRequest(source)).result.status)
        assertEquals(2, transport.calls.size)
    }

    @Test fun editKeepsDatesIncludingTimeAndOmitsPasswordWhenNotChanged() = runBlocking {
        val raw = link(available = "2026-10-11 13:24:56", expires = "2026-11-11 15:20:00")
        val before = parseFileShareLink(raw)
        val changed = JsonObject(raw + ("expire_times" to JsonPrimitive(42)))
        val transport = harness(page(raw), page(raw), buildJsonObject {}, page(changed))
        val outcome = transport.repo.edit(FileShareEditRequest(before, advanced = FileShareAdvancedChange(maximumAccesses = 42)))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, outcome.result.status)
        assertEquals(mapOf("id" to "[\"link-a\"]", "expire_times" to "42"), transport.calls.single { it.method == "edit" }.parameters)
    }

    @Test fun passwordSetRequiresAcceptedResponseNotJustExistingPasswordFlag() = runBlocking {
        val raw = link(password = true)
        val request = FileShareEditRequest(parseFileShareLink(raw), password = FileSharePasswordChange.Set("synthetic-new"))
        val dropped = harness(page(raw), IOException("synthetic disconnect"), page(raw))
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, dropped.repo.edit(request).result.status)
        val accepted = harness(page(raw), buildJsonObject {}, page(raw))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, accepted.repo.edit(request).result.status)
        assertEquals("synthetic-new", accepted.calls.single { it.method == "edit" }.parameters["password"])
    }

    @Test fun passwordRemoveAndDateClearAreExplicitAndNeverSentAsKeep() = runBlocking {
        val raw = link(password = true, expires = "2026-11-11")
        val transport = harness(page(raw), buildJsonObject {}, page(link()))
        val result = transport.repo.edit(FileShareEditRequest(parseFileShareLink(raw), password = FileSharePasswordChange.Remove, expiresOn = FileShareDateChange.Clear))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.result.status)
        assertEquals(mapOf("id" to "[\"link-a\"]", "password" to "", "date_expired" to "0"), transport.calls.single { it.method == "edit" }.parameters)
    }

    @Test fun namedMembersUseCompleteSetsAddedDeltasAndSecondBaseline() = runBlocking {
        val raw = link(users = setOf("existing"))
        val changed = link(users = setOf("existing", "new"), groups = setOf("team"))
        val members = linkedSetOf(FileSharePrincipal("existing", FileSharePrincipalKind.USER), FileSharePrincipal("new", FileSharePrincipalKind.USER), FileSharePrincipal("team", FileSharePrincipalKind.GROUP))
        val transport = harness(page(raw), principals("existing", "user"), principals("new", "user"), principals("team", "group"), page(raw), buildJsonObject {}, page(changed))
        val result = transport.repo.edit(FileShareEditRequest(parseFileShareLink(raw), advanced = FileShareAdvancedChange(audience = FileShareAudienceChange.Principals(members))))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.result.status)
        val parameters = transport.calls.single { it.method == "edit" }.parameters
        assertEquals("user", parameters["protect_type"])
        assertEquals("[\"existing\",\"new\"]", parameters["protect_users"])
        assertEquals("[\"team\"]", parameters["protect_groups"])
        assertEquals("[\"new\"]", parameters["new_protect_users"])
        assertEquals("[\"team\"]", parameters["new_protect_groups"])
        assertFalse(parameters.containsKey("password"))
    }

    @Test fun changedBaselineAfterMemberLookupPreventsWrite() = runBlocking {
        val raw = link()
        val transport = harness(page(raw), principals("member", "user"), page(link(expires = "2027-01-01")))
        val result = transport.repo.edit(FileShareEditRequest(parseFileShareLink(raw), advanced = FileShareAdvancedChange(audience = FileShareAudienceChange.Principals(setOf(FileSharePrincipal("member", FileSharePrincipalKind.USER))))))
        assertEquals(MutationErrorCategory.CONFLICT, result.result.errorCategory)
        assertFalse(result.result.submitted)
        assertTrue(transport.calls.none { it.method == "edit" })
    }

    @Test fun namedMemberMissingOrEmptyNeverFallsBackToPublic() = runBlocking {
        val before = parseFileShareLink(link())
        val empty = harness()
        assertFalse(empty.repo.edit(FileShareEditRequest(before, advanced = FileShareAdvancedChange(FileShareAudienceChange.Principals(emptySet())))).result.submitted)
        assertTrue(empty.calls.isEmpty())
        val missing = harness(page(link()), buildJsonObject { put("total", 0); put("owners", JsonArray(emptyList())) })
        assertFalse(missing.repo.edit(FileShareEditRequest(before, advanced = FileShareAdvancedChange(FileShareAudienceChange.Principals(setOf(FileSharePrincipal("absent", FileSharePrincipalKind.USER)))))).result.submitted)
        assertTrue(missing.calls.none { it.method == "edit" })
    }

    @Test fun publicAudienceMayRetainUnusedMemberMetadata() = runBlocking {
        val raw = link(users = setOf("member"))
        val updated = JsonObject(raw + ("protect_type" to JsonPrimitive("none")))
        val transport = harness(page(raw), page(raw), buildJsonObject {}, page(updated))
        val result = transport.repo.edit(FileShareEditRequest(parseFileShareLink(raw), advanced = FileShareAdvancedChange(FileShareAudienceChange.Anyone)))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.result.status)
        assertEquals(mapOf("id" to "[\"link-a\"]", "protect_type" to "none"), transport.calls.single { it.method == "edit" }.parameters)
    }

    @Test fun collectionEditPreservesUploadStateAndNeverSendsEnableUpload() = runBlocking {
        val raw = link(collection = true, name = "Before")
        val transport = harness(page(raw), page(raw), buildJsonObject {}, page(link(collection = true, name = "After", message = "Please upload")))
        val result = transport.repo.edit(FileShareEditRequest(parseFileShareLink(raw), advanced = FileShareAdvancedChange(requestName = "After", requestMessage = "Please upload")))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.result.status)
        assertEquals(mapOf("id" to "[\"link-a\"]", "file_request" to "true", "request_name" to "After", "request_info" to "Please upload"), transport.calls.single { it.method == "edit" }.parameters)
    }

    @Test fun readbackPermissionFailureAfterWriteRemainsUnknown() = runBlocking {
        val raw = link()
        val transport = harness(page(raw), buildJsonObject {}, DsmFailure(105, "synthetic", "synthetic", kind = DsmErrorKind.PERMISSION_DENIED))
        val result = transport.repo.edit(FileShareEditRequest(parseFileShareLink(raw), expiresOn = FileShareDateChange.Set(LocalDate.of(2027,1,1))))
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.result.status)
        assertTrue(result.result.submitted)
    }

    @Test fun recoverySurvivesRestartAndNeverSavesPasswordOrReplaysWrite() = runBlocking {
        val preferences = MemoryPreferences()
        val store = FileShareRecoveryStore(preferences)
        val transport = harness(page(), receipt(), IOException("synthetic readback"))
        transport.repo.bindRecovery(store)
        val request = FileShareCreateRequest(source, password = "synthetic-secret")
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, transport.repo.create(request).result.status)
        assertFalse(preferences.all.values.toString().contains("synthetic-secret"))
        val pending = store.pending(owner).single()
        assertTrue(pending.acknowledged)
        assertEquals("link-a", pending.linkId)
        val restored = harness(page(link(password = true)))
        restored.repo.bindRecovery(FileShareRecoveryStore(preferences))
        assertFalse(restored.repo.create(request).result.submitted)
        assertTrue(restored.calls.isEmpty())
        assertTrue(restored.repo.recover().isEmpty())
        assertEquals(listOf("list"), restored.calls.map { it.method })
        assertTrue(store.pending(owner).isEmpty())
    }

    @Test fun unidentifiedCreationAndUnacknowledgedPasswordRemainReadOnlyAcrossRestart() = runBlocking {
        val preferences = MemoryPreferences()
        val store = FileShareRecoveryStore(preferences)
        val transport = harness(page(), IOException("synthetic write disconnect"))
        transport.repo.bindRecovery(store)
        transport.repo.create(FileShareCreateRequest(source))
        val restored = harness(page(link()))
        restored.repo.bindRecovery(store)
        assertEquals(1, restored.repo.recover().size)
        val record = store.pending(owner).single()
        assertNull(record.linkId)
        assertFalse(record.acknowledged)
        assertTrue(store.pending(owner.copy(identityRevision = "other-account")).isEmpty())
        assertEquals(1, store.pending(owner.copy(sessionGeneration = "new-session")).size)
    }

    @Test fun storageFailureBeforeSubmissionSendsNoWrite() = runBlocking {
        val preferences = MemoryPreferences().apply { commitSucceeds = false }
        val transport = harness(page())
        transport.repo.bindRecovery(FileShareRecoveryStore(preferences))
        val result = transport.repo.create(FileShareCreateRequest(source))
        assertFalse(result.result.submitted)
        assertEquals(listOf("list"), transport.calls.map { it.method })
    }

    @Test fun editCancellationAfterSubmissionKeepsUnknownRecordAndBlocksReplay() = runBlocking {
        val raw = link()
        val transport = harness(page(raw), CancellationException("synthetic cancellation"))
        val store = FileShareRecoveryStore(MemoryPreferences())
        transport.repo.bindRecovery(store)
        val request = FileShareEditRequest(parseFileShareLink(raw), expiresOn = FileShareDateChange.Set(LocalDate.of(2027,1,1)))
        val cancelled = transport.repo.edit(request)
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, cancelled.result.status)
        assertEquals(1, store.pending(owner).size)
        assertFalse(transport.repo.edit(request).result.submitted)
        assertEquals(1, transport.calls.count { it.method == "edit" })
    }

    @Test fun corruptRecoveryCannotBeIgnoredAndProfileRemovalOnlyClearsThatProfile() = runBlocking {
        val preferences = MemoryPreferences()
        val store = FileShareRecoveryStore(preferences)
        val expected = FileShareCreateRequest(source).expectation()
        store.begin(FileSharePendingChange(owner = owner, key = "create:${source.path}", path = source.path, name = source.name, expected = expected))
        val key = preferences.all.keys.single()
        store.begin(FileSharePendingChange(owner = owner.copy(profileId = "other"), key = "create:${source.path}", path = source.path, name = source.name, expected = expected))
        preferences.edit().putString(key, "{").commit()
        val transport = harness(); transport.repo.bindRecovery(store)
        assertFalse(transport.repo.create(FileShareCreateRequest(source)).result.submitted)
        assertTrue(transport.calls.isEmpty())
        store.removeProfile(owner.profileId)
        assertTrue(store.pending(owner).isEmpty())
        assertEquals(1, store.pending(owner.copy(profileId = "other")).size)
    }

    @Test fun missingAdvancedOrInvalidCountOrPasswordCombinationPreventsWrite() = runBlocking {
        val before = parseFileShareLink(link())
        val transport = harness()
        listOf(
            FileShareEditRequest(before, advanced = FileShareAdvancedChange(maximumAccesses = 10000)),
            FileShareEditRequest(before.copy(advanced = null), advanced = FileShareAdvancedChange(maximumAccesses = 3)),
            FileShareEditRequest(before, password = FileSharePasswordChange.Set("p"), advanced = FileShareAdvancedChange(FileShareAudienceChange.Anyone)),
            FileShareEditRequest(before.copy(advanced = before.advanced!!.copy(isFileRequest = true)), advanced = FileShareAdvancedChange(FileShareAudienceChange.Anyone)),
        ).forEach { assertFalse(transport.repo.edit(it).result.submitted) }
        assertTrue(transport.calls.isEmpty())
    }

    @Test fun ordinaryAndCollectionLinksUseActualPermissionsWithoutVersionCallback() = runBlocking {
        val public = harness(page(), receipt(), page(link()))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, public.repo.create(FileShareCreateRequest(source)).result.status)
        val collection = harness(page(), receipt(), page(link(collection = true, name = "Synthetic", message = "")))
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, collection.repo.create(FileShareCreateRequest(source, fileRequest = FileRequestConfiguration("Synthetic", ""))).result.status)
        assertEquals(1, public.calls.count { it.method == "create" }); assertEquals(1, collection.calls.count { it.method == "create" })
    }

    private fun harness(vararg responses: Any) = Harness(responses.toList())
    private inner class Harness(responses: List<Any>) {
        val calls = mutableListOf<Call>()
        var currentSource = source
        private val queue = ArrayDeque(responses)
        private val paths = mutableSetOf<String>()
        val repo = DsmFileSharingRepository({ _, _ -> true }, { api, method, parameters, version ->
            calls += Call(api, method, parameters, version)
            when (val response = queue.removeFirstOrNull() ?: error("Missing synthetic response for $method")) {
                is Exception -> throw response
                else -> response as JsonObject
            }
        }, { currentSource }, { incoming -> if (incoming.any { it in paths }) false else { paths.addAll(incoming); true } }, { paths.removeAll(it); Unit }, { owner })
    }
    private data class Call(val api: String, val method: String, val parameters: Map<String, String>, val version: Int)
    private fun page(vararg links: JsonObject, total: Int = links.size, offset: Int = 0) = buildJsonObject {
        put("links", JsonArray(links.toList())); put("total", total); put("offset", offset)
    }
    private fun receipt(error: Int = 0) = buildJsonObject { putJsonArray("links") { add(buildJsonObject { put("id", "link-a"); put("path", source.path); put("error", error) }) } }
    private fun principals(name: String, kind: String) = buildJsonObject { put("total", 1); putJsonArray("owners") { add(buildJsonObject { put("name", name); put("type", kind) }) } }
    private fun link(id: String = "link-a", password: Boolean = false, available: String = "0", expires: String = "0",
                     collection: Boolean = false, name: String = "", message: String = "", users: Set<String> = emptySet(), groups: Set<String> = emptySet()) = buildJsonObject {
        put("id", id); put("name", source.name); put("path", source.path); put("url", "https://share.example.invalid/$id")
        put("has_password", password); put("date_available", available); put("date_expired", expires); put("status", "valid")
        put("protect_type", if (password) "password" else if (users.isNotEmpty() || groups.isNotEmpty()) "user" else "none")
        put("protect_users", JsonArray(users.map(::JsonPrimitive))); put("protect_groups", JsonArray(groups.map(::JsonPrimitive))); put("expire_times", 0)
        put("enable_upload", collection); put("project_name", if (collection) "SYNO.SDS.App.SharingUpload.Application" else "SYNO.SDS.App.FileStation3.Instance")
        put("request_name", name); put("request_info", message)
    }
}

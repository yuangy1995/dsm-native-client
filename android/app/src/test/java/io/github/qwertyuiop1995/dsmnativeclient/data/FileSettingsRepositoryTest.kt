package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.FileSettingsFixture
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class FileSettingsRepositoryTest {
    private val local = FileMountAccountSource(FileMountSourceKind.LOCAL)
    private suspend fun change(h: FileSettingsFixture): FileSettingsChange.General {
        val old = h.settings.reader.general(); return FileSettingsChange.General(old, old.copy(recordsTransfers = true))
    }
    private suspend fun save(h: FileSettingsFixture, value: FileSettingsChange) = h.settings.changeSettingsResult(value, true, true)

    @Test fun generalSendsOnlyActualDirtyFieldsAndConfirmsCompleteFreshSnapshot() = runBlocking {
        val h = FileSettingsFixture(); val change = change(h)
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, save(h, change).status)
        assertTrue(h.settings.pending().isEmpty())
        assertEquals(mapOf("transfer_log_enable" to "true"), fields(h.writes().single()))
        assertEquals(FILE_SETTINGS_API, h.writes().single()["api"]); assertEquals("1", h.writes().single()["version"])
        assertEquals(4, h.calls.count { it["api"] == FILE_SETTINGS_API && it["method"] == "get" })
    }
    @Test fun selectedPrivilegesSendSortedUidGidDeltasAfterReadingAllAccountPages() = runBlocking {
        val h = FileSettingsFixture(); h.users = (1L..201L).map { FileSettingsFixture.policyRow(it, "Synthetic $it", false) }
        h.general = JsonObject(h.general + ("sharing_group_privilege" to buildJsonObject {
            putJsonArray("items") { add(buildJsonObject { put("gid", 20); put("enabled", true) }) }
        }))
        val old = h.settings.reader.general()
        val updated = old.copy(sharing = FileSettingsScope.SELECTED, sharingAccounts = setOf(
            FileSettingsAccountId(FileSharePrincipalKind.USER, 201), FileSettingsAccountId(FileSharePrincipalKind.USER, 2)))
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, save(h, FileSettingsChange.General(old, updated)).status)
        assertEquals(mapOf("sharing_allow" to "per_user", "enabled_sharing_privilege" to "2,201", "disabled_sharing_group_privilege" to "20"), fields(h.writes().single()))
        assertEquals(listOf("0", "200"), h.calls.filter { it["method"] == "list_user" }.map { it["offset"] })
        assertTrue(h.calls.filter { it["api"] == FILE_SETTINGS_PRINCIPAL_API }.all { it["type"] == "all" && it["query"] == "" })
    }
    @Test fun administratorMissingAndDuplicateAcrossPagesCannotChangePrivileges() = runBlocking {
        for (mode in listOf("admin", "missing", "duplicate")) {
            val h = FileSettingsFixture()
            val id = if (mode == "admin") 0L else 201L
            if (mode == "duplicate") h.users = (1L..201L).map { FileSettingsFixture.policyRow(if (it == 201L) 1 else it, "Synthetic $it", false) }
            val old = h.settings.reader.general()
            assertTrue(mode, runCatching { save(h, FileSettingsChange.General(old, old.copy(sharingAccounts = setOf(FileSettingsAccountId(FileSharePrincipalKind.USER, id))))) }.isFailure)
            assertTrue(h.writes().isEmpty()); assertTrue(h.settings.pending().isEmpty())
        }
    }
    @Test fun changedBaselineOrChangesDuringAccountPaginationCannotOverwriteOtherAdmin() = runBlocking {
        val h = FileSettingsFixture(); val change = change(h)
        h.general = JsonObject(h.general + ("use_unix_default_perm" to JsonPrimitive(true)))
        assertTrue(runCatching { save(h, change) }.isFailure); assertTrue(h.writes().isEmpty())
        val concurrent = FileSettingsFixture(); val old = concurrent.settings.reader.general()
        concurrent.before = { if (it["api"] == FILE_SETTINGS_PRINCIPAL_API) concurrent.general = JsonObject(concurrent.general + ("use_unix_default_perm" to JsonPrimitive(true))) }
        assertTrue(runCatching { save(concurrent, FileSettingsChange.General(old, old.copy(sharingAccounts = setOf(FileSettingsAccountId(FileSharePrincipalKind.USER, 12))))) }.isFailure)
        assertTrue(concurrent.writes().isEmpty())
    }
    @Test fun missingConfirmationRiskAcceptancePermissionsAndOwnerCannotWrite() = runBlocking {
        val h = FileSettingsFixture(); val old = h.settings.reader.general(); val change = FileSettingsChange.General(old, old.copy(sharing = FileSettingsScope.EVERYONE))
        assertTrue(runCatching { h.settings.changeSettingsResult(change, false, true) }.isFailure)
        assertTrue(runCatching { h.settings.changeSettingsResult(change, true, false) }.isFailure)
        h.allowed = false; assertTrue(runCatching { save(h, change) }.isFailure)
        h.allowed = true; h.administrator = false; assertTrue(runCatching { save(h, change) }.isFailure)
        h.administrator = true; h.ownerValid = false; assertTrue(runCatching { save(h, change) }.isFailure)
        assertTrue(h.writes().isEmpty())
        val other = FileSettingsFixture("other-profile")
        assertTrue(runCatching { save(other, change) }.isFailure); assertTrue(other.writes().isEmpty())
    }
    @Test fun permissionRevokedAfterBaselineReadStopsSecondPreflight() = runBlocking {
        val h = FileSettingsFixture(); val change = change(h)
        h.before = { if (it["api"] == FILE_SETTINGS_API && it["method"] == "get") h.allowed = false }
        assertTrue(runCatching { save(h, change) }.isFailure); assertTrue(h.writes().isEmpty()); assertTrue(h.settings.pending().isEmpty())
    }
    @Test fun noChangeInvalidRatesAndUnknownThemeCannotWrite() = runBlocking {
        val h = FileSettingsFixture(); val old = h.settings.reader.general()
        for (new in listOf(old, old.copy(defaultLinkLimit = -1), old.copy(remoteMounts = FileSettingsScope.SELECTED),
                old.copy(bandwidth = FileBandwidthPolicy.UNCONFIGURED), old.copy(bandwidth = FileBandwidthPolicy.SCHEDULED),
                old.copy(customSharingPage = null))) assertTrue(runCatching { save(h, FileSettingsChange.General(old, new)) }.isFailure)
        val rate = h.settings.reader.bandwidth(FileBandwidthOwner.LOCAL_USER, 0).items.single()
        for (new in listOf(rate, rate.copy(policy = FileBandwidthPolicy.ENABLED, uploadLimit = 9), rate.copy(policy = FileBandwidthPolicy.SCHEDULED)))
            assertTrue(runCatching { save(h, FileSettingsChange.Bandwidth(rate, new)) }.isFailure)
        assertTrue(h.writes().isEmpty())
    }
    @Test fun mountScopeAndSingleAccountAreSeparateWritesWithSourceBoundReadback() = runBlocking {
        val h = FileSettingsFixture()
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, save(h, FileSettingsChange.MountScope(h.owner, FileMountScope.ADMINISTRATORS, FileMountScope.SELECTED)).status)
        assertEquals(mapOf("settings" to "{\"user_enabled_type\":\"custom\"}"), fields(h.writes().single()))
        val source = FileMountAccountSource(FileMountSourceKind.DOMAIN, "DIRECTORY-REQUEST")
        val baseline = h.settings.reader.mountAccounts(source, FileSharePrincipalKind.GROUP, "", 0).items.single()
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, save(h, FileSettingsChange.MountAccount(baseline, true)).status)
        assertEquals(mapOf("settings" to "{\"group_settings\":[{\"gid\":20,\"enabled\":true}]}"), fields(h.writes().last()))
        assertTrue(h.calls.filter { it["content"] == "group_settings" }.all { it["domain"] == "DIRECTORY-REQUEST" && it["type"] == "domain" })
        assertTrue(h.writes().all { "domain" !in it && "type" !in it })
    }
    @Test fun lockedOrRenamedMountAccountCannotBeChanged() = runBlocking {
        val h = FileSettingsFixture(); val row = h.settings.reader.mountAccounts(local, FileSharePrincipalKind.USER, "", 0).items.single()
        assertTrue(runCatching { save(h, FileSettingsChange.MountAccount(row.copy(canModify = false), true)) }.isFailure)
        h.accounts = { _, _ -> listOf(JsonObject(FileSettingsFixture.mountRow(12, true) + ("name" to JsonPrimitive("Changed name")))) }
        assertTrue(runCatching { save(h, FileSettingsChange.MountAccount(row, true)) }.isFailure); assertTrue(h.writes().isEmpty())
    }
    @Test fun accountBandwidthPreservesIdentityAndWritesAllFourRatesAndWeeklySlots() = runBlocking {
        val h = FileSettingsFixture(); val old = h.settings.reader.bandwidth(FileBandwidthOwner.LDAP_GROUP, 0).items.single()
        val new = old.copy(policy = FileBandwidthPolicy.SCHEDULED, schedule = "012".repeat(56), uploadLimit = 10, downloadLimit = 100,
            alternateUploadLimit = 0, alternateDownloadLimit = 999_999_999)
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, save(h, FileSettingsChange.Bandwidth(old, new)).status)
        assertEquals(FILE_BANDWIDTH_API, h.writes().single()["api"])
        assertEquals(new.settingsValue(), Json.parseToJsonElement(h.writes().single().getValue("bandwidths")).jsonArray.single())
        assertTrue(h.settings.pending().isEmpty())
    }
    @Test fun timeoutWithAppliedValuesCanRecoverByReadingWithoutASecondWrite() = runBlocking {
        val h = FileSettingsFixture(); val change = change(h)
        h.afterWrite = { throw IOException("synthetic lost response") }
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, save(h, change).status)
        assertEquals(1, h.writes().size); assertTrue(h.settings.pending().isEmpty())
    }
    @Test fun unknownSavePersistsOnlyDigestsBlocksSameTargetAndSurvivesNewSession() = runBlocking {
        val h = FileSettingsFixture(); h.applyWrites = false; val change = change(h)
        assertEquals(FileSettingsOutcomeStatus.UNKNOWN, save(h, change).status)
        val record = h.settings.pending().single(); assertTrue(record.acknowledged)
        val raw = h.preferences.all.values.joinToString()
        for (sensitive in listOf("transfer_log_enable", "sharing_privilege", "Synthetic user", "DIRECTORY-REQUEST")) assertFalse(raw.contains(sensitive))
        assertTrue(runCatching { save(h, change) }.isFailure); assertEquals(1, h.writes().size)
        assertEquals(FileSettingsOutcomeStatus.UNKNOWN, h.settings.review(change).status); assertEquals(1, h.writes().size)
        val resumed = FileSettingsFixture(session = "new-session", preferences = h.preferences)
        resumed.general = JsonObject(resumed.general + ("transfer_log_enable" to JsonPrimitive(true)))
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, resumed.settings.review(change).status)
        assertTrue(resumed.writes().isEmpty()); assertTrue(resumed.settings.pending().isEmpty())
        val other = FileSettingsFixture("other-profile", preferences = h.preferences)
        assertTrue(runCatching { other.settings.review(change) }.isFailure)
    }
    @Test fun readbackMustMatchAllSettingsAndNewDraftCannotReplaceStoredExpectation() = runBlocking {
        val h = FileSettingsFixture(); val change = change(h)
        h.afterWrite = { h.general = JsonObject(h.general + ("use_unix_default_perm" to JsonPrimitive(true))) }
        assertEquals(FileSettingsOutcomeStatus.UNKNOWN, save(h, change).status)
        val current = h.settings.reader.general()
        assertEquals(FileSettingsOutcomeStatus.UNKNOWN, h.settings.review(FileSettingsChange.General(current, current)).status)
        assertEquals(1, h.writes().size); assertEquals(1, h.settings.pending().size)
    }
    @Test fun unknownGeneralDoesNotBlockSeparateScopeSaveAndReviewNeverReplays() = runBlocking {
        val h = FileSettingsFixture(); val change = change(h); h.applyWrites = false
        assertEquals(FileSettingsOutcomeStatus.UNKNOWN, save(h, change).status)
        h.applyWrites = true
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, save(h, FileSettingsChange.MountScope(h.owner, FileMountScope.ADMINISTRATORS, FileMountScope.EVERYONE)).status)
        assertEquals(1, h.settings.pending().size); assertEquals(2, h.writes().size)
        assertEquals(FileSettingsOutcomeStatus.UNKNOWN, h.settings.review(change).status); assertEquals(2, h.writes().size)
    }
    @Test fun initialStorageFailureOrCorruptRecoveryFailsBeforeSending() = runBlocking {
        val h = FileSettingsFixture(); val change = change(h); h.preferences.commitSucceeds = false
        assertTrue(runCatching { save(h, change) }.isFailure); assertTrue(h.writes().isEmpty())
        val corrupt = FileSettingsFixture(); val pending = change(corrupt); corrupt.applyWrites = false; save(corrupt, pending)
        corrupt.preferences.edit().putString(corrupt.preferences.all.keys.single(), "broken").commit()
        assertTrue(runCatching { save(corrupt, pending) }.isFailure); assertEquals(1, corrupt.writes().size)
    }
    @Test fun concurrentSaveCannotSendSameChangeTwice() = runBlocking {
        val h = FileSettingsFixture(); val change = change(h); val entered = CountDownLatch(1); val release = CountDownLatch(1)
        h.before = { if (it["method"] == "set") { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) } }
        val first = async(Dispatchers.Default) { save(h, change) }
        try {
            assertTrue(withContext(Dispatchers.IO) { entered.await(10, TimeUnit.SECONDS) })
            assertEquals(DsmErrorKind.FILE_SETTINGS_PENDING, (runCatching { save(h, change) }.exceptionOrNull() as? DsmFailure)?.kind)
        } finally { release.countDown() }
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, first.await().status); assertEquals(1, h.writes().size)
    }
    @Test fun recoveryRemovalKeepsOtherProfilesAndChangedIdentityIsIsolated() = runBlocking {
        val preferences = MemoryPreferences(); val one = FileSettingsFixture("one", preferences = preferences); val two = FileSettingsFixture("two", preferences = preferences)
        one.applyWrites = false; two.applyWrites = false; save(one, change(one)); save(two, change(two))
        val store = FileSettingsRecoveryStore(preferences)
        assertTrue(store.pending(one.owner.copy(identityRevision = "replacement")).isEmpty())
        store.removeProfile("one"); assertTrue(one.settings.pending().isEmpty()); assertEquals(1, two.settings.pending().size)
    }
    @Test fun cancellationAfterSubmissionKeepsRecoveryAndOnlyReadsOnResume() = runBlocking {
        val h = FileSettingsFixture(); val change = change(h); val entered = CountDownLatch(1); val release = CountDownLatch(1)
        h.before = { if (it["method"] == "set") { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) } }
        val job = launch(Dispatchers.Default) { save(h, change) }
        try { assertTrue(withContext(Dispatchers.IO) { entered.await(10, TimeUnit.SECONDS) }); job.cancel() } finally { release.countDown() }
        job.join(); assertTrue(job.isCancelled); assertEquals(1, h.writes().size); assertEquals(1, h.settings.pending().size)
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, h.settings.review(change).status); assertEquals(1, h.writes().size)
    }
    @Test fun permissionLostAfterAcceptedWriteCannotEraseRecoveryAsIfRejected() = runBlocking {
        val h = FileSettingsFixture(); val change = change(h)
        h.afterWrite = { h.allowed = false; runBlocking { h.repository.refreshAccess() } }
        assertEquals(FileSettingsOutcomeStatus.UNKNOWN, save(h, change).status)
        assertTrue(h.settings.pending().single().acknowledged); assertEquals(1, h.writes().size)
    }
    @Test fun disappearingDirectorySourceCannotWriteAStaleAccountWithMatchingNumericId() = runBlocking {
        val h = FileSettingsFixture(); val source = FileMountAccountSource(FileMountSourceKind.DOMAIN, "DIRECTORY-REQUEST")
        val row = h.settings.reader.mountAccounts(source, FileSharePrincipalKind.USER, "", 0).items.single()
        h.domainEnabled = false
        assertTrue(runCatching { save(h, FileSettingsChange.MountAccount(row, true)) }.isFailure); assertTrue(h.writes().isEmpty())
    }
    private fun fields(values: Map<String, String>) = values.filterKeys { it !in setOf("api", "method", "version", "_sid", "SynoToken") }
}

package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.FileSettingsFixture
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class FileSettingsReaderTest {
    @Test fun generalPreservesExplicitValuesAndOptionalUnknownThemeWithoutInventingDefaults() = runBlocking {
        val h = FileSettingsFixture(); h.general = JsonObject(h.general + mapOf("sharing_allow" to JsonPrimitive("per_user"),
            "sharing_privilege" to buildJsonObject { putJsonArray("items") { add(buildJsonObject { put("uid", 12); put("enabled", true) }) } },
            "enable_sharing_custom_setting" to JsonPrimitive("unrecognized")))
        val value = h.settings.reader.general()
        assertEquals(h.owner, value.owner); assertEquals(FileSettingsScope.SELECTED, value.sharing)
        assertEquals(setOf(FileSettingsAccountId(FileSharePrincipalKind.USER, 12)), value.sharingAccounts)
        assertNull(value.customSharingPage); assertFalse(value.recordsTransfers); assertTrue(h.writes().isEmpty())
        assertEquals("1", h.calls.single()["version"])
    }
    @Test fun malformedGeneralFieldsCannotBecomeWritableDefaults() = runBlocking {
        val changes = listOf("transfer_log_enable" to JsonPrimitive("false"), "sharing_default_limit" to JsonPrimitive(0),
            "rf_allow" to JsonPrimitive("per_user"), "vd_allow" to JsonPrimitive("unknown"), "bandwidth_enable" to JsonPrimitive("notexist"),
            "schedule_plan" to JsonPrimitive("2".repeat(168)), "sharing_default_limit" to JsonPrimitive("1000000000"))
        for ((key, bad) in changes) {
            val h = FileSettingsFixture(); h.general = JsonObject(h.general + (key to bad))
            assertEquals(key, DsmErrorKind.INVALID_RESPONSE, (runCatching { h.settings.reader.general() }.exceptionOrNull() as? DsmFailure)?.kind)
            assertTrue(h.writes().isEmpty())
        }
        val missing = FileSettingsFixture(); missing.general = JsonObject(missing.general - "enable_list_usergrp")
        assertTrue(runCatching { missing.settings.reader.general() }.isFailure)
    }
    @Test fun settingsPrivilegeIdsRemainNativeIntegersAndDuplicatesAreRejected() = runBlocking {
        for (rows in listOf(listOf(JsonPrimitive("12")), listOf(JsonPrimitive(12), JsonPrimitive(12)), listOf(JsonPrimitive(-1)))) {
            val h = FileSettingsFixture()
            h.general = JsonObject(h.general + ("sharing_privilege" to buildJsonObject {
                put("items", JsonArray(rows.map { id -> buildJsonObject { put("uid", id); put("enabled", true) } }))
            }))
            assertTrue(runCatching { h.settings.reader.general() }.isFailure)
        }
    }
    @Test fun mountIdsAcceptOnlyRecordedIntegerOrDecimalStringFormsAndStrictBooleans() = runBlocking {
        val source = FileMountAccountSource(FileMountSourceKind.LOCAL)
        for (id in listOf(JsonPrimitive(12), JsonPrimitive("12"))) {
            val h = FileSettingsFixture(); h.accounts = { _, _ -> listOf(JsonObject(FileSettingsFixture.mountRow(12, true) + ("uid" to id))) }
            assertEquals(12L, h.settings.reader.mountAccounts(source, FileSharePrincipalKind.USER, "", 0).items.single().id.value)
        }
        for (id in listOf(JsonNull, JsonPrimitive(true), JsonPrimitive(""), JsonPrimitive("-1"), JsonPrimitive(-1),
                JsonPrimitive("12.0"), JsonPrimitive("9223372036854775808"))) {
            val h = FileSettingsFixture(); h.accounts = { _, _ -> listOf(JsonObject(FileSettingsFixture.mountRow(12, true) + ("uid" to id))) }
            assertTrue(id.toString(), runCatching { h.settings.reader.mountAccounts(source, FileSharePrincipalKind.USER, "", 0) }.isFailure)
        }
        val h = FileSettingsFixture(); h.accounts = { _, _ -> listOf(JsonObject(FileSettingsFixture.mountRow(12, true) + ("enabled" to JsonPrimitive("true")))) }
        assertTrue(runCatching { h.settings.reader.mountAccounts(source, FileSharePrincipalKind.USER, "", 0) }.isFailure)
    }
    @Test fun mountAndPolicyPagingValidatesEmptyDuplicateAndOffsetResponses() = runBlocking {
        val source = FileMountAccountSource(FileMountSourceKind.LOCAL)
        for (bad in listOf(
            buildJsonObject { put("total", 1); putJsonArray("usergrp_settings") {} },
            buildJsonObject { put("total", 2); putJsonArray("usergrp_settings") { add(FileSettingsFixture.mountRow(12, true)); add(FileSettingsFixture.mountRow(12, true)) } },
            buildJsonObject { put("total", 1); put("offset", 1); putJsonArray("usergrp_settings") { add(FileSettingsFixture.mountRow(12, true)) } })) {
            val h = FileSettingsFixture(); h.overrideResponse = { bad }
            assertTrue(runCatching { h.settings.reader.mountAccounts(source, FileSharePrincipalKind.USER, "", 0) }.isFailure)
        }
        val h = FileSettingsFixture(); h.users = listOf(JsonObject(h.users[1] - "is_admin"))
        assertTrue(runCatching { h.settings.reader.policyAccounts(FileSharePrincipalKind.USER, "", 0) }.isFailure)
        h.users = emptyList(); assertTrue(h.settings.reader.policyAccounts(FileSharePrincipalKind.USER, "", 0).items.isEmpty())
    }
    @Test fun directoryUsesRequestValueAndReadFailuresKeepOtherSourcesAvailable() = runBlocking {
        val h = FileSettingsFixture(); val value = h.settings.reader.directories()
        assertFalse(value.hasUnavailableSources); assertEquals(3, value.items.size)
        val domain = value.items.last(); assertEquals("Directory display", domain.name); assertEquals("DIRECTORY-REQUEST", domain.source.domain)
        h.settings.reader.mountAccounts(domain.source, FileSharePrincipalKind.GROUP, "Synthetic", 0)
        assertEquals("DIRECTORY-REQUEST", h.calls.last()["domain"]); assertEquals("group_settings", h.calls.last()["content"])
        assertEquals("2", h.calls.single { it["method"] == "get_domain_list" }["version"])
        h.before = { if (it["api"] == FILE_DIRECTORY_LDAP_API) throw IOException("synthetic unavailable") }
        val partial = h.settings.reader.directories(); assertTrue(partial.hasUnavailableSources)
        assertEquals(listOf(FileMountSourceKind.LOCAL, FileMountSourceKind.DOMAIN), partial.items.map { it.source.kind })
        assertTrue(h.writes().isEmpty())
    }
    @Test fun explicitNasDenialKeepsOnlyLocalSourceAndDoesNotBypassManagementGate() = runBlocking {
        val h = FileSettingsFixture(); h.nasAllowed = false; h.repository.refreshAccess()
        val sources = h.settings.reader.directories()
        assertTrue(sources.hasUnavailableSources); assertEquals(FileMountSourceKind.LOCAL, sources.items.single().source.kind)
        assertTrue(h.calls.none { it["api"]?.startsWith("SYNO.Core.") == true })
        assertTrue(runCatching { h.settings.reader.bandwidth(FileBandwidthOwner.LOCAL_USER, 0) }.isFailure)
        assertEquals(0, h.settings.reader.general().defaultLinkLimit)
    }
    @Test fun allBandwidthOwnerTypesPreserveUnconfiguredAndRejectUnknownPolicies() = runBlocking {
        val h = FileSettingsFixture()
        for (type in FileBandwidthOwner.entries) {
            val value = h.settings.reader.bandwidth(type, 0).items.single()
            assertEquals(FileBandwidthPolicy.UNCONFIGURED, value.policy); assertEquals(type, value.ownerType); assertEquals("", value.schedule)
        }
        h.bandwidthRows = mapOf(FileBandwidthOwner.LOCAL_USER to listOf(JsonObject(FileSettingsFixture.bandwidthRow(FileBandwidthOwner.LOCAL_USER) + ("policy" to JsonPrimitive("unknown")))))
        assertTrue(runCatching { h.settings.reader.bandwidth(FileBandwidthOwner.LOCAL_USER, 0) }.isFailure)
    }
    @Test fun scheduleKeepsSundayFirstAndDistinguishesServiceAndAccountSlots() {
        assertEquals(0, FileWeeklySchedule.index(0, 0)); assertEquals(167, FileWeeklySchedule.index(6, 23))
        assertTrue(FileWeeklySchedule.valid("1".repeat(168), false)); assertTrue(FileWeeklySchedule.valid("2".repeat(168), true))
        assertFalse(FileWeeklySchedule.valid("2".repeat(168), false)); assertFalse(FileWeeklySchedule.valid("1".repeat(167), true))
        assertFalse(FileWeeklySchedule.valid("", false)); assertTrue(runCatching { FileWeeklySchedule.index(7, 0) }.isFailure)
    }
}

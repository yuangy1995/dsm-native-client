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

class FilePermissionRepositoryTest {
    private val path = "/synthetic/folder "
    private val owner = WorkspaceOwner("synthetic", "identity-a", "session-a")
    private val rule = FileACLRule("user", "synthetic-user", 1000, false, FileACLEffect.ALLOW,
        setOf(FileACLRight.READ_DATA), setOf(FileACLInheritance.THIS_FOLDER))
    private val inherited = rule.copy(ownerType = "group", ownerName = "synthetic-group", level = 1)

    @Test fun completeReadRequestsRealPathAndPreservesAllRightsAndInheritance() = runBlocking {
        val h = Harness(); h.rules = listOf(rule.copy(rights = FileACLRight.entries.toSet(), inheritance = FileACLInheritance.entries.toSet()), inherited)
        val result = h.repo.load(path)
        assertEquals(h.rules, result.rules); assertEquals("/volume-synthetic/folder ", result.resolvedPath)
        assertTrue(result.canChangePermissions); assertTrue(result.owner!!.canChange)
        assertNull(result.target.accessedAtEpochSeconds)
        val request = h.calls.first()
        assertEquals(2, request.version); assertEquals("[\"/synthetic/folder \"]", request.parameters["path"])
        assertTrue(Json.parseToJsonElement(request.parameters.getValue("additional")).jsonArray.contains(JsonPrimitive("real_path")))
    }
    @Test fun sharedRootRecycleAndMountsRemainReadableButCannotBeModified() = runBlocking {
        for ((target, mount) in listOf("/synthetic" to "normal", "/synthetic/#recycle/item" to "normal", path to "cifs", path to null)) {
            val h = Harness(); h.path = target; h.mount = mount
            val result = h.repo.load(target)
            assertFalse(result.canChangePermissions); assertFalse(result.owner!!.canChange)
            assertTrue(runCatching { h.repo.changePermissionsResult(FilePermissionChange(result, explicitRules = emptyList()), true) }.isFailure)
            assertEquals(0, h.writes)
        }
    }
    @Test fun missingPathWrongModeIncompleteAndUnknownRightsFailClosed() = runBlocking {
        val h = Harness()
        val malformed = listOf<(JsonObject) -> JsonObject>(
            { JsonObject(it - "change_permission") },
            { JsonObject(it + ("is_acl" to JsonPrimitive(false))) },
            { data -> JsonObject(data + ("acl" to JsonArray(listOf(buildJsonObject {
                permissionRulePayload(rule).forEach { (key,value) -> put(key,value) }; put("level", 0)
                put("permission", JsonObject(permissionRulePayload(rule).getValue("permission").jsonObject - "read_data"))
            })))) },
            { data -> JsonObject(data + ("acl" to JsonArray(listOf(buildJsonObject {
                permissionRulePayload(rule).forEach { (key,value) -> put(key,value) }; put("level", 0)
                put("permission", JsonObject(permissionRulePayload(rule).getValue("permission").jsonObject + ("unknown" to JsonPrimitive(true))))
            })))) },
        )
        for (transform in malformed) { h.transformAcl = transform; assertTrue(runCatching { h.repo.load(path) }.isFailure) }
        h.transformAcl = { it }; h.resolved = "/volume-synthetic/../folder"
        assertTrue(runCatching { h.repo.load(path) }.isFailure)
        assertEquals(0, h.writes)
    }
    @Test fun explicitChangeChecksSameDraftAndSendsOnlyExplicitRules() = runBlocking {
        val h = Harness(); val before = h.repo.load(path)
        val changed = rule.copy(rights = rule.rights + FileACLRight.WRITE_DATA)
        val result = h.repo.changePermissionsResult(FilePermissionChange(before, explicitRules = listOf(changed)), true)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.result.status)
        val set = h.calls.single { it.method == "set" }; val check = h.calls.single { it.method == "check_self_denied" }
        assertEquals(check.parameters, set.parameters); assertEquals("false", set.parameters["acl_recur"])
        val rules = Json.parseToJsonElement(set.parameters.getValue("rules")).jsonArray
        assertEquals(1, rules.size); assertEquals(13, rules.single().jsonObject.getValue("permission").jsonObject.size)
        assertEquals(4, rules.single().jsonObject.getValue("inherit").jsonObject.size)
        assertFalse(rules.single().jsonObject.containsKey("level")); assertFalse(rules.single().jsonObject.containsKey("owner_is_internal"))
        assertEquals(2, h.accessRefreshes); assertEquals(4, h.fileReads); assertTrue(h.repo.pending().isEmpty())
    }
    @Test fun denyMissingAndStringSelfCheckNeverSubmit() = runBlocking {
        for (value in listOf<JsonElement?>(JsonPrimitive(true), null, JsonPrimitive("false"))) {
            val h = Harness(); val before = h.repo.load(path)
            h.selfCheck = if (value == null) buildJsonObject {} else buildJsonObject { put("is_denied", value) }
            assertTrue(runCatching { h.repo.changePermissionsResult(FilePermissionChange(before, explicitRules = emptyList()), true) }.isFailure)
            assertEquals(0, h.writes); assertTrue(h.repo.pending().isEmpty())
        }
    }
    @Test fun bothBaselineChecksRejectChangedTargetOrInheritedRules() = runBlocking {
        for (read in listOf(2, 3)) {
            val h = Harness(); val before = h.repo.load(path)
            h.onFileRead = { if (h.fileReads == read) h.resolved = "/volume-synthetic/another" }
            assertTrue(runCatching { h.repo.changePermissionsResult(FilePermissionChange(before, explicitRules = emptyList()), true) }.isFailure)
            assertEquals(0, h.writes)
        }
        val h = Harness(); val before = h.repo.load(path); h.rules = h.rules + inherited.copy(ownerName = "another")
        assertTrue(runCatching { h.repo.changePermissionsResult(FilePermissionChange(before, explicitRules = emptyList()), true) }.isFailure)
        assertEquals(0, h.writes)
    }
    @Test fun missingExplicitAppGrantAndRevokedAdministratorBlockWrites() = runBlocking {
        val h = Harness(); val before = h.repo.load(path)
        h.access = FilePermissionAccess(false, true)
        assertTrue(runCatching { h.repo.changePermissionsResult(FilePermissionChange(before, explicitRules = emptyList()), true) }.isFailure)
        assertEquals(0, h.writes)
        h.access = FilePermissionAccess(true, true)
        h.onRefresh = { if (h.accessRefreshes >= 3) h.access = FilePermissionAccess(true, false) }
        assertTrue(runCatching { h.repo.changePermissionsResult(FilePermissionChange(before, owner = FileSharePrincipal("new", FileSharePrincipalKind.USER)), true) }.isFailure)
        assertEquals(0, h.writes)
    }
    @Test fun ordinaryAccountCanEditAclButCannotTransferOwnerOrPosix() = runBlocking {
        val h = Harness(); h.access = FilePermissionAccess(true, false)
        val before = h.repo.load(path); assertTrue(before.canChangePermissions); assertFalse(before.owner!!.canChange)
        assertTrue(runCatching { h.repo.changePermissionsResult(FilePermissionChange(before, owner = FileSharePrincipal("new", FileSharePrincipalKind.USER)), true) }.isFailure)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, h.repo.changePermissionsResult(FilePermissionChange(before, explicitRules = emptyList()), true).result.status)
        h.acl = false
        assertFalse(h.repo.load(path).canChangePermissions)
    }
    @Test fun newMemberIsRecheckedAndCannotBringForgedIdentityOrInheritedRule() = runBlocking {
        for (draft in listOf(rule.copy(ownerName = "missing", ownerId = null, isInternal = null),
            rule.copy(ownerName = "new", ownerId = 9876), inherited)) {
            val h = Harness(); val before = h.repo.load(path); h.availableMembers = emptyList()
            assertTrue(runCatching { h.repo.changePermissionsResult(FilePermissionChange(before, explicitRules = listOf(draft)), true) }.isFailure)
            assertEquals(0, h.writes)
        }
    }
    @Test fun newMemberReceivesServerIdAndDuplicateRuleCannotMaskMissingRule() = runBlocking {
        val h = Harness(); val before = h.repo.load(path)
        val added = rule.copy(ownerName = "new", ownerId = null, isInternal = null)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS,
            h.repo.changePermissionsResult(FilePermissionChange(before, explicitRules = listOf(rule, added)), true).result.status)
        val expected = FilePermissionChange(before, explicitRules = listOf(rule, rule)).expectation()
        assertFalse(expected.matches(before.copy(rules = listOf(rule, inherited, added))))
    }
    @Test fun posixUsesDecimalDigitsAndLogicalParentAndCanChangeOwnerAndGroup() = runBlocking {
        val h = Harness(); h.acl = false; h.directory = false
        val before = h.repo.load(path); assertEquals("755", before.posixMode)
        val result = h.repo.changePermissionsResult(FilePermissionChange(before, posixMode = "750", owner = FileSharePrincipal("new", FileSharePrincipalKind.USER),
            group = FileSharePrincipal("team", FileSharePrincipalKind.GROUP)), true)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.result.status)
        val set = h.calls.single { it.method == "set" }
        assertEquals(PERMISSION_PROPERTY_API, set.api); assertEquals("750", set.parameters["mode"])
        assertEquals("[\"/synthetic\"]", set.parameters["dir_paths"]); assertEquals("new", set.parameters["owner"])
        assertFalse(h.calls.any { it.method == "check_self_denied" })
    }
    @Test fun ownerOnlyKeepsPosixModeAndRejectsUnconfirmedOrRecursiveFile() = runBlocking {
        val h = Harness(); h.acl = false
        val before = h.repo.load(path)
        val change = FilePermissionChange(before, owner = FileSharePrincipal("new", FileSharePrincipalKind.USER))
        assertTrue(runCatching { h.repo.changePermissionsResult(change, false) }.isFailure)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, h.repo.changePermissionsResult(change, true).result.status)
        assertEquals("-1", h.calls.single { it.method == "set" }.parameters["mode"])
        h.directory = false
        assertTrue(runCatching { h.repo.changePermissionsResult(FilePermissionChange(h.repo.load(path), posixMode = "700", recursive = true), true) }.isFailure)
    }
    @Test fun recursiveRootMatchRequiresAcknowledgementAndFinishedTask() = runBlocking {
        val h = Harness(); h.receipt = buildJsonObject { put("task_id", "task-a"); put("running", true) }
        h.status = buildJsonObject { put("finished", false) }
        val change = FilePermissionChange(h.repo.load(path), explicitRules = emptyList(), recursive = true)
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, h.repo.changePermissionsResult(change, true).result.status)
        assertTrue(runCatching { h.repo.changePermissionsResult(change, true) }.isFailure); assertEquals(1, h.writes)
        h.status = buildJsonObject { put("finished", true) }
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, h.repo.review(path).result.status)
        assertEquals("task-a", h.calls.last { it.method == "status" }.parameters["task_id"])
    }
    @Test fun recursivePartialFailureRemainsUnknownAfterRestartEvenWhenRootMatches() = runBlocking {
        val h = Harness(); h.receipt = buildJsonObject { put("taskid", "task-posix"); put("running", true) }; h.acl = false
        h.status = buildJsonObject { put("finished", true); putJsonArray("errItems") { add(buildJsonObject { put("path", "/synthetic-private-error") }) } }
        val result = h.repo.changePermissionsResult(FilePermissionChange(h.repo.load(path), posixMode = "700", recursive = true), true)
        assertTrue(result.partialFailure); assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.result.status)
        h.restart(); h.status = buildJsonObject { put("finished", true) }
        assertTrue(h.repo.review(path).partialFailure); assertEquals(1, h.writes)
        assertFalse(h.preferences.all.toString().contains("synthetic-private-error"))
    }
    @Test fun connectionLossNeverReplaysAndColdRecoveryUsesHashesWithoutRawPermissionsOrMapping() = runBlocking {
        val h = Harness(); h.disconnectAfterSet = true
        val changed = rule.copy(rights = FileACLRight.entries.toSet())
        h.failReadAfterSet = true
        val result = h.repo.changePermissionsResult(FilePermissionChange(h.repo.load(path), explicitRules = listOf(changed)), true)
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.result.status)
        val stored = h.preferences.all.toString()
        assertFalse(stored.contains(h.resolved)); assertFalse(stored.contains(rule.ownerName)); assertFalse(stored.contains("read_data"))
        h.restart(); h.failReadAfterSet = false
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, h.repo.review(path).result.status)
        assertEquals(1, h.writes); assertTrue(h.repo.pending().isEmpty())
    }
    @Test fun recursiveLostReceiptNeverInfersSubtreeSuccessFromRoot() = runBlocking {
        val h = Harness(); h.disconnectAfterSet = true
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            h.repo.changePermissionsResult(FilePermissionChange(h.repo.load(path), explicitRules = emptyList(), recursive = true), true).result.status)
        h.restart()
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, h.repo.review(path).result.status)
        assertEquals(1, h.writes)
    }
    @Test fun knownMemberIdAndInheritedIdentityChangesCannotBecomeSuccess() = runBlocking {
        for (inheritedChanged in listOf(false, true)) {
            val h = Harness(); h.failReadAfterSet = true
            h.repo.changePermissionsResult(FilePermissionChange(h.repo.load(path), explicitRules = listOf(rule.copy(rights = FileACLRight.entries.toSet()))), true)
            h.rules = h.rules.map { if ((it.level > 0) == inheritedChanged) it.copy(ownerId = 9999) else it }
            h.failReadAfterSet = false
            assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, h.repo.review(path).result.status)
        }
    }
    @Test fun storeFailureBlocksBeforeSetAndAccountChangeCannotReadOtherRecovery() = runBlocking {
        val failed = Harness(); val original = failed.repo.load(path); failed.preferences.commitSucceeds = false
        assertTrue(runCatching { failed.repo.changePermissionsResult(FilePermissionChange(original, explicitRules = emptyList()), true) }.isFailure)
        assertEquals(0, failed.writes)
        val h = Harness(); val before = h.repo.load(path); h.failReadAfterSet = true
        h.repo.changePermissionsResult(FilePermissionChange(before, explicitRules = emptyList()), true)
        assertEquals(1, h.repo.pending().size)
        h.currentOwner = owner.copy(identityRevision = "another-account")
        assertTrue(h.repo.pending().isEmpty()); assertTrue(runCatching { h.repo.review(path) }.isFailure)
    }
    @Test fun concurrentIdenticalSubmissionsProduceOneSetAndCancellationKeepsRecovery() = runBlocking {
        val h = Harness(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        h.beforeSet = { entered.complete(Unit); release.await() }
        val change = FilePermissionChange(h.repo.load(path), explicitRules = emptyList())
        val job = launch { h.repo.changePermissionsResult(change, true) }
        entered.await()
        assertTrue(runCatching { h.repo.changePermissionsResult(change, true) }.isFailure)
        job.cancelAndJoin(); assertEquals(1, h.repo.pending().size); assertEquals(1, h.writes)
        assertTrue(runCatching { h.repo.changePermissionsResult(change, true) }.isFailure)
    }

    @Test fun confirmationDiffPreservesDuplicateRuleRemovalsAndAdditions() {
        val (removed, added) = changedFilePermissionRules(listOf(rule, rule), listOf(rule, inherited))
        assertEquals(listOf(rule), removed); assertEquals(listOf(inherited), added)
    }

    @Test fun malformedStatusAndPermissionDenialNeverTurnIntoSuccess() = runBlocking {
        val h = Harness(); h.receipt = buildJsonObject { put("task_id", "task-a") }
        h.status = buildJsonObject { put("finished", "true") }
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            h.repo.changePermissionsResult(FilePermissionChange(h.repo.load(path), explicitRules = emptyList()), true).result.status)
        h.status = buildJsonObject { put("finished", true); put("errno", 105) }
        assertTrue(h.repo.review(path).partialFailure)
    }

    @Test fun unfinishedFolderPermissionChangeBlocksChildAndParentButNotSibling() = runBlocking {
        val h = Harness(); h.failReadAfterSet = true
        h.repo.changePermissionsResult(FilePermissionChange(h.repo.load(path), explicitRules = emptyList(), recursive = true), true)
        h.failReadAfterSet = false
        for (nextPath in listOf("$path/child", "/synthetic")) {
            h.path = nextPath
            val before = h.repo.load(nextPath)
            val error = runCatching { h.repo.changePermissionsResult(FilePermissionChange(before, explicitRules = listOf(
                rule.copy(ownerName = "new", ownerId = null, isInternal = null))), true) }.exceptionOrNull()
            assertEquals(DsmErrorKind.FILE_PERMISSIONS_PENDING, (error as DsmFailure).kind)
            assertEquals(1, h.writes)
        }
        h.path = "/synthetic/sibling"
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, h.repo.changePermissionsResult(FilePermissionChange(h.repo.load(h.path),
            explicitRules = listOf(rule.copy(ownerName = "new", ownerId = null, isInternal = null))), true).result.status)
        assertEquals(2, h.writes)
    }

    @Test fun independentStoresAtomicallyRejectOverlappingRecoveryTargets() = runBlocking {
        val h = Harness(); val expected = FilePermissionChange(h.repo.load(path), explicitRules = emptyList()).expectation()
        val first = FilePermissionRecoveryStore(h.preferences); val other = FilePermissionRecoveryStore(h.preferences)
        val record = FilePermissionPending(owner = owner, path = path, isACL = true, recursive = true, expected = expected)
        first.begin(record)
        assertThrows(DsmFailure::class.java) { other.begin(record.copy(id = "child-record", path = "$path/child")) }
        other.begin(record.copy(id = "sibling-record", path = "/synthetic/sibling"))
        assertEquals(2, first.pending(owner).size)
    }

    @Test fun mountRecoveryCreatedWhileClaimingPathPreventsPermissionSubmission() = runBlocking {
        val h = Harness(); val before = h.repo.load(path)
        h.onClaim = { h.mountPaths = listOf("/synthetic") }
        val error = runCatching { h.repo.changePermissionsResult(FilePermissionChange(before, explicitRules = emptyList()), true) }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.FILE_MOUNT_PENDING, error.kind); assertEquals(0, h.writes)
        assertFalse(h.calls.any { it.method == "check_self_denied" })
    }

    @Test fun observedEmptyMountTypeAllowsNormalPermissionEditingButMissingDoesNot() = runBlocking {
        val h = Harness(); h.mount = ""
        val before = h.repo.load(path); assertTrue(before.canChangePermissions)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS,
            h.repo.changePermissionsResult(FilePermissionChange(before, explicitRules = emptyList()), true).result.status)
        h.mount = null; assertFalse(h.repo.load(path).canChangePermissions)
    }

    private data class Call(val api: String, val method: String, val parameters: Map<String,String>, val version: Int)
    @Test fun permissionWriteUsesObjectAccessWithoutEnvironmentCallback() = runBlocking {
        val h = Harness(); val original = h.repo.load(path)
        val result = h.repo.changePermissionsResult(FilePermissionChange(original, explicitRules = emptyList()), true)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.result.status)
        assertEquals(1, h.writes); assertTrue(h.repo.pending().isEmpty())
    }

    private inner class Harness {
        var path = this@FilePermissionRepositoryTest.path; var resolved = "/volume-synthetic/folder "; var mount: String? = "normal"
        var acl = true; var directory = true; var mode = "755"; var user = "synthetic-user"; var group = "synthetic-group"
        var rules = listOf(rule, inherited); var access = FilePermissionAccess(true, true)
        var currentOwner = owner; var accessRefreshes = 0; var fileReads = 0; var writes = 0
        val preferences = MemoryPreferences(); val calls = mutableListOf<Call>()
        var availableMembers = listOf(FileSharePrincipal("new", FileSharePrincipalKind.USER), FileSharePrincipal("team", FileSharePrincipalKind.GROUP))
        var selfCheck = buildJsonObject { put("is_denied", false) }
        var receipt = buildJsonObject {}; var status = buildJsonObject { put("finished", true) }
        var disconnectAfterSet = false; var failReadAfterSet = false
        var onRefresh: () -> Unit = {}; var onFileRead: () -> Unit = {}; var beforeSet: suspend () -> Unit = {}
        var transformAcl: (JsonObject) -> JsonObject = { it }
        var mountPaths = emptyList<String>(); var onClaim: () -> Unit = {}
        var repo = makeRepo()
        fun restart() { currentOwner = currentOwner.copy(sessionGeneration = "new-session"); repo = makeRepo() }
        private fun makeRepo() = DsmFilePermissionRepository({ _, _ -> true }, ::call, { access },
            { accessRefreshes++; onRefresh() }, { prefix, offset, _ -> val matching = availableMembers.filter { it.name.startsWith(prefix) }; FileSharePrincipalPage(matching.drop(offset), matching.size, matching.size) },
            { onClaim(); true }, {}, { currentOwner }, {}, { mountPaths }).also { it.bindRecovery(FilePermissionRecoveryStore(preferences)) }
        private suspend fun call(api: String, method: String, parameters: Map<String,String>, version: Int): JsonObject {
            calls += Call(api, method, parameters, version)
            if (method == "getinfo") {
                fileReads++; onFileRead()
                if (writes > 0 && failReadAfterSet) throw IOException("synthetic read failure")
                return buildJsonObject { putJsonArray("files") { add(buildJsonObject {
                    put("path", path); put("name", "folder "); put("isdir", directory)
                    putJsonObject("additional") {
                        put("real_path", resolved); mount?.let { put("mount_point_type", it) }
                        putJsonObject("time") { put("mtime", 100); put("atime", fileReads) }
                        putJsonObject("owner") { put("user", user); put("group", group) }
                        putJsonObject("perm") { put("is_acl_mode", acl); put("posix", mode.toInt()); putJsonObject("acl") { put("read", true); put("write", true); put("del", true) } }
                    }
                }) } }
            }
            if (api == "SYNO.FileStation.Property.ACLOwner") return buildJsonObject { put("name", user); put("type", "user"); put("value", "1000"); put("hasPrivilege", true) }
            if (method == "get") return transformAcl(buildJsonObject {
                put("is_acl", true); put("change_permission", true); put("is_inherited", true)
                putJsonArray("acl") { rules.forEach { rule -> add(buildJsonObject {
                    permissionRulePayload(rule).forEach { (key,value) -> put(key,value) }; put("level", rule.level)
                    rule.isInternal?.let { put("owner_is_internal", it) }
                }) } }
            })
            if (method == "check_self_denied") return selfCheck
            if (method == "status") return status
            check(method == "set"); writes++; beforeSet()
            if (api == PERMISSION_ACL_API) {
                if (parameters["change_acl"] == "true") rules = Json.parseToJsonElement(parameters.getValue("rules")).jsonArray.map { row ->
                    parsePermissionRule(JsonObject(row.jsonObject + mapOf("level" to JsonPrimitive(0), "owner_is_internal" to JsonPrimitive(false)))).let { it.copy(ownerId = it.ownerId ?: 2000) }
                } + rules.filter { it.level > 0 }
                parameters["acl_owner"]?.let { user = it }
            } else {
                parameters["mode"]?.takeUnless { it == "-1" }?.let { mode = it }
                parameters["owner"]?.let { user = it }; parameters["group"]?.let { group = it }
            }
            if (disconnectAfterSet) throw IOException("synthetic lost response")
            return receipt
        }
    }
}

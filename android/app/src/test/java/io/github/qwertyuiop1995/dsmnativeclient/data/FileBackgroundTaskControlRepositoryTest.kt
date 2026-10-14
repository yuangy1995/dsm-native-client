package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class FileBackgroundTaskControlRepositoryTest {
    @Test fun stopEachKnownKindUsesExactVersionAndConfirmsFinishedIdentity() = runBlocking {
        for (kind in FileBackgroundTaskKind.entries) {
            val h = FileBackgroundTaskFixture(); h.rows = listOf(FileBackgroundTaskFixture.row(kind = kind))
            val task = h.repository.listFileBackgroundTasks().tasks.single()
            assertEquals(1700000000.125, task.controlCreatedAtSeconds!!, 0.0)
            assertTrue(h.tasks.canControl(task, FileBackgroundTaskAction.STOP))
            assertEquals(FileBackgroundTaskOutcomeStatus.COMPLETED, h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, true).status)
            val write = h.writes().single()
            assertEquals(kind.taskAPI.first, write["api"]); assertEquals(kind.taskAPI.second.toString(), write["version"])
            assertEquals("stop", write["method"]); assertEquals(task.id, write["taskid"])
            assertTrue(h.tasks.pending().isEmpty())
            val request = h.requests.first { (it.body as okhttp3.FormBody).let { b -> (0 until b.size).any { b.name(it) == "method" && b.value(it) == "stop" } } }
            assertNull(request.url.queryParameter("_sid")); assertNotNull(request.header("Cookie"))
        }
    }
    @Test fun clearOnlySelectedFinishedRecordUsesSingleIdArrayAndCompleteReadback() = runBlocking {
        val h = FileBackgroundTaskFixture(); h.rows = listOf(FileBackgroundTaskFixture.row(finished = true), FileBackgroundTaskFixture.row("other"))
        val selected = h.repository.listFileBackgroundTasks().tasks.first()
        assertEquals(FileBackgroundTaskOutcomeStatus.COMPLETED, h.tasks.controlBackgroundTaskResult(selected, FileBackgroundTaskAction.CLEAR, true).status)
        assertEquals(FILE_BACKGROUND_API, h.writes().single()["api"]); assertEquals("3", h.writes().single()["version"])
        assertEquals("[\"${selected.id}\"]", h.writes().single()["taskid"])
        assertEquals(listOf("other"), h.repository.listFileBackgroundTasks().tasks.map { it.id })
    }
    @Test fun missingConfirmationStaleSnapshotWrongStateAndUnsupportedVersionNeverWrite() = runBlocking {
        val h = FileBackgroundTaskFixture(); val task = h.repository.listFileBackgroundTasks().tasks.single()
        assertTrue(runCatching { h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, false) }.isFailure)
        for (bad in listOf(task.copy(method = null), task.copy(controlCreatedAtSeconds = null), task.copy(apiVersion = 1), task.copy(id = "/private/path"))) {
            assertFalse(h.tasks.canControl(bad, FileBackgroundTaskAction.STOP))
            assertTrue(runCatching { h.tasks.controlBackgroundTaskResult(bad, FileBackgroundTaskAction.STOP, true) }.isFailure)
        }
        assertTrue(runCatching { h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.CLEAR, true) }.isFailure)
        val old = FileBackgroundTaskFixture(stopVersions = mapOf(task.kind to 2))
        assertFalse(old.tasks.canControl(task, FileBackgroundTaskAction.STOP))
        assertTrue(runCatching { old.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, true) }.isFailure)
        assertTrue(h.writes().isEmpty()); assertTrue(old.writes().isEmpty())
    }
    @Test fun changedIdentityIncludingFractionalCreationTimeAndFinishedStateNeverWrite() = runBlocking {
        for (field in listOf("crtime", "api", "version", "method", "finished")) {
            val h = FileBackgroundTaskFixture(); val task = h.repository.listFileBackgroundTasks().tasks.single()
            val value = when (field) { "crtime" -> JsonPrimitive(1700000000.875); "api" -> JsonPrimitive("SYNO.FileStation.Delete")
                "version" -> JsonPrimitive(2); "method" -> JsonPrimitive("other"); else -> JsonPrimitive(true) }
            h.rows = listOf(JsonObject(h.rows.single() + (field to value)))
            assertTrue(field, runCatching { h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, true) }.isFailure)
            assertTrue(h.writes().isEmpty())
        }
    }
    @Test fun currentAccessAndOriginalOwnerAreRequiredBeforeAndAfterReads() = runBlocking {
        for (stage in listOf("before", "read", "owner")) {
            val h = FileBackgroundTaskFixture(); val task = h.repository.listFileBackgroundTasks().tasks.single()
            if (stage == "before") h.allowed = false
            h.before = { if (it["method"] == "list") { if (stage == "read") h.allowed = false; if (stage == "owner") h.validOwner = false } }
            assertTrue(runCatching { h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, true) }.isFailure)
            assertTrue(h.writes().isEmpty())
        }
    }
    @Test fun malformedOrIncompleteControlListNeverBecomesAbsenceOrWrites() = runBlocking {
        val invalid = listOf("{}", "{\"offset\":0,\"total\":1,\"tasks\":[]}", "{\"offset\":1,\"total\":1,\"tasks\":[]}",
            "{\"offset\":0,\"total\":1,\"tasks\":[{}]}", "{\"offset\":{},\"total\":1,\"tasks\":[]}")
        for (raw in invalid) {
            val h = FileBackgroundTaskFixture(); val task = h.repository.listFileBackgroundTasks().tasks.single()
            h.overrideRead = { Json.parseToJsonElement(raw).jsonObject }
            assertTrue(runCatching { h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, true) }.isFailure)
            assertTrue(h.writes().isEmpty())
        }
    }
    @Test fun duplicatedIdentityAndChangingTotalsAcrossPagesRejectControl() = runBlocking {
        for (mode in listOf("duplicate", "total")) {
            val h = FileBackgroundTaskFixture(); val task = h.repository.listFileBackgroundTasks().tasks.single()
            h.rows = (0..100).map { FileBackgroundTaskFixture.row(if (it == 0) task.id else "task-$it") }
            if (mode == "duplicate") h.rows = h.rows.dropLast(1) + h.rows.first()
            else h.before = { if (it["offset"] == "100") h.rows = h.rows.dropLast(1) }
            assertTrue(runCatching { h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, true) }.isFailure)
            assertTrue(h.writes().isEmpty())
        }
    }
    @Test fun unknownStopPersistsBlocksReplayAndRestoresAcrossSessionsWithoutClaimingSuccess() = runBlocking {
        val h = FileBackgroundTaskFixture(); val task = h.repository.listFileBackgroundTasks().tasks.single(); h.applyWrites = false
        h.afterWrite = { throw IOException("Synthetic disconnect") }
        assertEquals(FileBackgroundTaskOutcomeStatus.UNKNOWN, h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, true).status)
        assertEquals(1, h.tasks.pending().size)
        assertTrue(runCatching { h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, true) }.isFailure)
        val reopened = FileBackgroundTaskFixture(h.preferences, session = "new-session")
        val record = reopened.tasks.pending().single()
        assertEquals(FileBackgroundTaskOutcomeStatus.UNKNOWN, reopened.tasks.review(record).status)
        reopened.rows = listOf(FileBackgroundTaskFixture.row(finished = true))
        assertEquals(FileBackgroundTaskOutcomeStatus.COMPLETED, reopened.tasks.review(record).status)
        assertTrue(reopened.writes().isEmpty()); assertEquals(1, h.writes().size); assertTrue(reopened.tasks.pending().isEmpty())
    }
    @Test fun lostReplyMayConfirmFinalStateButNeverInferFileSuccessOrStopFromAbsence() = runBlocking {
        val h = FileBackgroundTaskFixture(); val task = h.repository.listFileBackgroundTasks().tasks.single()
        h.afterWrite = { throw IOException("Synthetic disconnect") }
        assertEquals(FileBackgroundTaskOutcomeStatus.COMPLETED, h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, true).status)
        val missing = FileBackgroundTaskFixture(); val original = missing.repository.listFileBackgroundTasks().tasks.single()
        missing.afterWrite = { missing.rows = emptyList() }
        assertEquals(FileBackgroundTaskOutcomeStatus.UNKNOWN, missing.tasks.controlBackgroundTaskResult(original, FileBackgroundTaskAction.STOP, true).status)
        assertEquals(1, missing.tasks.pending().size)
    }
    @Test fun unknownClearRequiresCompleteValidAbsenceAndCannotClearReusedId() = runBlocking {
        val h = FileBackgroundTaskFixture(); h.rows = listOf(FileBackgroundTaskFixture.row(finished = true))
        val task = h.repository.listFileBackgroundTasks().tasks.single()
        h.afterWrite = { h.overrideRead = { buildJsonObject { } } }
        assertEquals(FileBackgroundTaskOutcomeStatus.UNKNOWN, h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.CLEAR, true).status)
        val record = h.tasks.pending().single(); h.overrideRead = { null }
        h.rows = listOf(FileBackgroundTaskFixture.row(time = 1700000001.0, finished = true))
        assertEquals(FileBackgroundTaskOutcomeStatus.UNKNOWN, h.tasks.review(record).status)
        assertTrue(runCatching { h.tasks.controlBackgroundTaskResult(h.repository.listFileBackgroundTasks().tasks.single(), FileBackgroundTaskAction.CLEAR, true) }.isFailure)
        h.rows = emptyList(); assertEquals(FileBackgroundTaskOutcomeStatus.COMPLETED, h.tasks.review(record).status)
        assertEquals(1, h.writes().size)
    }
    @Test fun acknowledgedStopDoesNotMatchReplacedIdentityOrChangedMethod() = runBlocking {
        val h = FileBackgroundTaskFixture(); val task = h.repository.listFileBackgroundTasks().tasks.single()
        h.afterWrite = { h.rows = listOf(FileBackgroundTaskFixture.row(time = 1700000000.875, finished = true)) }
        assertEquals(FileBackgroundTaskOutcomeStatus.UNKNOWN, h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, true).status)
        assertTrue(h.tasks.pending().single().acknowledged)
        h.rows = listOf(JsonObject(FileBackgroundTaskFixture.row(finished = true) + ("method" to JsonPrimitive("other"))))
        assertEquals(FileBackgroundTaskOutcomeStatus.UNKNOWN, h.tasks.review(h.tasks.pending().single()).status)
    }
    @Test fun permissionRejectionClearsFactsAndStorageFailurePreventsWrite() = runBlocking {
        val h = FileBackgroundTaskFixture(); val task = h.repository.listFileBackgroundTasks().tasks.single()
        h.responseError = { if (it["method"] == "stop") 105 else null }
        val result = h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, true)
        assertEquals(FileBackgroundTaskOutcomeStatus.REJECTED, result.status); assertEquals(DsmErrorKind.PERMISSION_DENIED, result.failure?.kind)
        assertTrue(h.tasks.pending().isEmpty())
        val broken = FileBackgroundTaskFixture(); val selected = broken.repository.listFileBackgroundTasks().tasks.single()
        broken.preferences.commitSucceeds = false
        assertTrue(runCatching { broken.tasks.controlBackgroundTaskResult(selected, FileBackgroundTaskAction.STOP, true) }.isFailure)
        assertTrue(broken.writes().isEmpty())
    }
    @Test fun independentTaskRemainsUsableAndOtherAccountCannotReviewOriginalFacts() = runBlocking {
        val h = FileBackgroundTaskFixture(); h.rows = listOf(FileBackgroundTaskFixture.row(), FileBackgroundTaskFixture.row("other"))
        val initial = h.repository.listFileBackgroundTasks().tasks; h.applyWrites = false
        assertEquals(FileBackgroundTaskOutcomeStatus.UNKNOWN, h.tasks.controlBackgroundTaskResult(initial[0], FileBackgroundTaskAction.STOP, true).status)
        h.applyWrites = true
        assertEquals(FileBackgroundTaskOutcomeStatus.COMPLETED, h.tasks.controlBackgroundTaskResult(initial[1], FileBackgroundTaskAction.STOP, true).status)
        val other = FileBackgroundTaskFixture(h.preferences, profileId = "other-account")
        assertTrue(other.tasks.pending().isEmpty()); assertTrue(runCatching { other.tasks.review(h.tasks.pending().single()) }.isFailure)
        val stored = h.preferences.all.values.joinToString()
        assertFalse(stored.contains("_sid")); assertFalse(stored.contains("synthetic-token")); assertFalse(stored.contains("https://"))
    }
    @Test fun simultaneousStopIsRejectedAndCancellationKeepsSubmittedFacts() = runBlocking {
        val h = FileBackgroundTaskFixture(); val task = h.repository.listFileBackgroundTasks().tasks.single()
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        h.afterWrite = { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
        val job = launch(Dispatchers.Default) { h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, true) }
        assertTrue(withContext(Dispatchers.IO) { entered.await(5, TimeUnit.SECONDS) })
        assertTrue(runCatching { h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, true) }.isFailure)
        job.cancel(); release.countDown(); job.join()
        assertEquals(1, h.tasks.pending().size); assertEquals(1, h.writes().size)
        h.afterWrite = {}; assertEquals(FileBackgroundTaskOutcomeStatus.COMPLETED, h.tasks.review(h.tasks.pending().single()).status)
        assertEquals(1, h.writes().size)
    }
    @Test fun ownerRevokedAfterWriteKeepsOriginalRecoveryWithoutUpdatingNewAccount() = runBlocking {
        val h = FileBackgroundTaskFixture(); val task = h.repository.listFileBackgroundTasks().tasks.single()
        h.afterWrite = { h.validOwner = false }
        assertTrue(runCatching { h.tasks.controlBackgroundTaskResult(task, FileBackgroundTaskAction.STOP, true) }.isFailure)
        assertEquals(1, h.writes().size)
        val reopened = FileBackgroundTaskFixture(h.preferences, session = "new-session")
        val record = reopened.tasks.pending().single(); reopened.rows = h.rows
        assertEquals(FileBackgroundTaskOutcomeStatus.COMPLETED, reopened.tasks.review(record).status)
        assertTrue(reopened.writes().isEmpty()); assertTrue(reopened.tasks.pending().isEmpty())
    }
}

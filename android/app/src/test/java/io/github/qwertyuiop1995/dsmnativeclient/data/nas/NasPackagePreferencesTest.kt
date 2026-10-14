package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasPackagePreferencesTest {
    private enum class Change { SETTINGS, ADD, UPDATE, DELETE }
    private class Scenario(val change: Change) {
        val fixture = NasPackageFixture()
        val repository = NasPackageRepository(fixture)
        val events = mutableListOf<NasPackageCheckpoint>()
        val source = NasPackageSource("Synthetic", "https://example.invalid/feed")
        private lateinit var original: NasPackagePreferences
        suspend fun prepare() {
            original = repository.preferences()
            if (change in setOf(Change.UPDATE, Change.DELETE)) fixture.feeds = JsonArray(listOf(buildJsonObject {
                put("name", source.name); put("feed", source.url)
            }))
        }
        suspend fun save(observer: NasPackageObserver = { events += it }) {
            when (change) {
                Change.SETTINGS -> repository.savePreferences("synthetic-operation", original, original.copy(email = true), observer)
                Change.ADD -> repository.saveSource("synthetic-operation", null, source, observer)
                Change.UPDATE -> repository.saveSource("synthetic-operation", source, source.copy(name = "Updated", url = "https://example.invalid/new"), observer)
                Change.DELETE -> repository.saveSource("synthetic-operation", source, null, observer)
            }
        }
        suspend fun read() = if (change == Change.SETTINGS) repository.preferences() else repository.sources()
        suspend fun assertBlocked() {
            try { save(); fail("An unresolved write must not be repeated") }
            catch (error: NasPackageFailure) { assertEquals(NasPackageProblem.BUSY, error.problem) }
            assertEquals(1, fixture.writes.size)
        }
    }

    @Test fun `设置与来源增改删权限或落盘失败均零写且无未决记录`() = runBlocking {
        for (change in Change.entries) for (storageFailure in listOf(false, true)) {
            val test = Scenario(change); test.prepare()
            if (!storageFailure) test.fixture.accessFailure = DsmFailure(105, "synthetic", "", kind = DsmErrorKind.PERMISSION_DENIED)
            val failure = runCatching { test.save { if (storageFailure) throw IOException("synthetic storage") else test.events += it } }.exceptionOrNull()
            if (storageFailure) assertTrue(failure is IOException) else assertTrue(failure is DsmFailure)
            assertTrue(test.fixture.writes.isEmpty()); assertTrue(test.events.isEmpty()); assertFalse(test.repository.preferencePending)
        }
    }

    @Test fun `设置与来源发送前取消零写发送中取消保留未决且读取不重放`() = runBlocking {
        for (change in Change.entries) {
            val before = Scenario(change); before.prepare()
            try { before.save { throw CancellationException("synthetic before send") }; fail() } catch (_: CancellationException) { }
            assertTrue(before.fixture.writes.isEmpty()); assertFalse(before.repository.preferencePending)
            val sent = Scenario(change); sent.prepare()
            sent.fixture.intercept = { if (it.write) throw CancellationException("synthetic after send") else null }
            try { sent.save(); fail() } catch (_: CancellationException) { }
            assertEquals(listOf(NasPackageWriteStage.WILL_SUBMIT), sent.events.map { it.stage })
            assertTrue(sent.repository.preferencePending); sent.fixture.intercept = null
            sent.read(); sent.assertBlocked()
        }
    }

    @Test fun `设置与来源回执丢失仅保留提交阶段重复保存被阻止`() = runBlocking {
        for (change in Change.entries) {
            val test = Scenario(change); test.prepare()
            test.fixture.intercept = { if (it.write) throw IOException("synthetic receipt lost") else null }
            try { test.save(); fail() } catch (_: IOException) { }
            assertEquals(listOf(NasPackageWriteStage.WILL_SUBMIT), test.events.map { it.stage })
            assertTrue(test.repository.preferencePending); test.fixture.intercept = null
            test.read(); test.assertBlocked()
        }
    }

    @Test fun `设置与来源明确拒绝记录拒绝后允许重新确认而不误报成功`() = runBlocking {
        for (change in Change.entries) {
            val test = Scenario(change); test.prepare()
            test.fixture.intercept = { if (it.write) throw DsmFailure(105, "synthetic", "", kind = DsmErrorKind.PERMISSION_DENIED) else null }
            try { test.save(); fail() } catch (_: DsmFailure) { }
            assertEquals(listOf(NasPackageWriteStage.WILL_SUBMIT, NasPackageWriteStage.REJECTED), test.events.map { it.stage })
            assertFalse(test.repository.preferencePending); assertEquals(1, test.fixture.writes.size)
            test.fixture.intercept = null; test.save()
            assertEquals(2, test.fixture.writes.size); assertEquals(NasPackageWriteStage.VERIFIED, test.events.last().stage)
        }
    }

    @Test fun `设置与来源接受后回读失败或内容不符保留未决不允许再次提交`() = runBlocking {
        for (change in Change.entries) for (readFailure in listOf(false, true)) {
            val test = Scenario(change); test.prepare(); var sent = false
            test.fixture.intercept = {
                if (it.write) { sent = true; if (readFailure) null else buildJsonObject { } }
                else if (sent && readFailure) throw IOException("synthetic read unavailable") else null
            }
            val failure = runCatching { test.save() }.exceptionOrNull()
            if (readFailure) assertTrue(failure is IOException) else assertEquals(NasPackageProblem.UNKNOWN, (failure as NasPackageFailure).problem)
            assertEquals(listOf(NasPackageWriteStage.WILL_SUBMIT, NasPackageWriteStage.ACCEPTED), test.events.map { it.stage })
            assertTrue(test.repository.preferencePending); test.fixture.intercept = null
            test.read(); test.assertBlocked()
        }
    }

    @Test fun `设置与来源完成落盘失败保留已接受事实且不重发`() = runBlocking {
        for (change in Change.entries) {
            val test = Scenario(change); test.prepare()
            try { test.save { if (it.stage == NasPackageWriteStage.VERIFIED) throw IOException("synthetic storage") else test.events += it }; fail() }
            catch (_: IOException) { }
            assertEquals(listOf(NasPackageWriteStage.WILL_SUBMIT, NasPackageWriteStage.ACCEPTED), test.events.map { it.stage })
            assertTrue(test.repository.preferencePending); test.assertBlocked()
        }
    }
}

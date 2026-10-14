package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasPowerActionRepositoryTest {
    @Test fun `关机重启均固定v3空参数一次提交且接受之后没有读取`() = runBlocking {
        for (format in listOf("FORM", "JSON")) for (action in NasPowerAction.entries) {
            val fixture = NasPowerActionFixture().also { it.format = format; it.maximumVersion = 5 }
            val stages = mutableListOf<NasPowerStage>(); fixture.repository().nasPower.perform(action, stages::add)
            assertEquals(listOf(NasPowerStage.SUBMITTED, NasPowerStage.ACCEPTED), stages)
            assertEquals(listOf("info", if (action == NasPowerAction.SHUTDOWN) "shutdown" else "reboot"), fixture.calls.map { it.method })
            assertEquals(3, fixture.calls[0].version); assertEquals(3, fixture.writes.single().version)
            assertTrue(fixture.writes.single().oneShot); assertTrue(fixture.calls.all { it.fields.isEmpty() })
        }
    }
    @Test fun `接口不支持权限撤销与旧归属均没有电源写入`() = runBlocking {
        for (condition in 1..3) {
            val fixture = NasPowerActionFixture(); if (condition == 1) fixture.maximumVersion = 2
            val repo = fixture.repository(); when (condition) { 2 -> fixture.admin = false; 3 -> fixture.ownerValid = false }
            val stages = mutableListOf<NasPowerStage>()
            assertTrue(runCatching { repo.nasPower.perform(NasPowerAction.REBOOT, stages::add) }.isFailure)
            assertEquals(listOf(NasPowerStage.CANCELLED), stages); assertTrue(fixture.writes.isEmpty())
        }
    }
    @Test fun `未知DSM电源操作按实际接口授权执行且只有一次必要连接读取`() = runBlocking {
        val fixture = NasPowerActionFixture(); fixture.known = false
        val stages = mutableListOf<NasPowerStage>(); fixture.repository().nasPower.perform(NasPowerAction.REBOOT, stages::add)
        assertEquals(listOf("info", "reboot"), fixture.calls.map { it.method })
        assertEquals(listOf(NasPowerStage.SUBMITTED, NasPowerStage.ACCEPTED), stages)
    }
    @Test fun `明确拒绝与写后断线分别保留拒绝和未知而不重试`() = runBlocking {
        for (rejected in listOf(true, false)) {
            val fixture = NasPowerActionFixture(); val repo = fixture.repository()
            if (rejected) fixture.rejection = 105 else fixture.before = { if (it.oneShot) throw IOException("Synthetic lost receipt") }
            val stages = mutableListOf<NasPowerStage>(); assertTrue(runCatching { repo.nasPower.perform(NasPowerAction.SHUTDOWN, stages::add) }.isFailure)
            assertEquals(if (rejected) listOf(NasPowerStage.SUBMITTED, NasPowerStage.REJECTED) else listOf(NasPowerStage.SUBMITTED), stages)
            assertEquals(1, fixture.writes.size); assertTrue(fixture.calls.last().oneShot)
        }
    }
    @Test fun `预检失败与写前持久失败均不发送且接受后持久失败不读取重放`() = runBlocking {
        for (condition in 0..2) {
            val fixture = NasPowerActionFixture(); val repo = fixture.repository()
            if (condition == 0) fixture.before = { if (fixture.calls.size == 1) throw IOException("Synthetic info failure") }
            val stages = mutableListOf<NasPowerStage>()
            assertTrue(runCatching { repo.nasPower.perform(NasPowerAction.REBOOT) {
                if (condition == 1 && it == NasPowerStage.SUBMITTED || condition == 2 && it == NasPowerStage.ACCEPTED)
                    throw DsmFailure(null, "Synthetic storage failure", "", kind = DsmErrorKind.LOCAL_STORAGE_FAILED)
                stages += it
            } }.isFailure)
            assertEquals(if (condition == 2) 1 else 0, fixture.writes.size)
            assertEquals(if (condition == 2) listOf(NasPowerStage.SUBMITTED) else listOf(NasPowerStage.CANCELLED), stages)
        }
    }
    @Test fun `取消按提交边界区分且并发重启关机只允许一个写请求`() = runBlocking {
        for (during in listOf(false, true)) {
            val stages = mutableListOf<NasPowerStage>(); var writes = 0
            val gateway = object : NasManagementGateway {
                override suspend fun requireWriteAccess() { if (!during) throw CancellationException("Synthetic before") }
                override suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement>, write: Boolean): JsonObject {
                    if (write) { writes++; throw CancellationException("Synthetic after") }; return JsonObject(emptyMap())
                }
            }
            val repo = NasPowerActionRepository(gateway) { _, _ -> true }
            assertTrue(runCatching { repo.perform(NasPowerAction.REBOOT, stages::add) }.exceptionOrNull() is CancellationException)
            assertEquals(if (during) 1 else 0, writes)
            assertEquals(listOf(if (during) NasPowerStage.SUBMITTED else NasPowerStage.CANCELLED), stages)
        }
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>(); var writes = 0
        val gateway = object : NasManagementGateway {
            override suspend fun requireWriteAccess() { entered.complete(Unit); release.await() }
            override suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement>, write: Boolean): JsonObject {
                if (write) writes++; return JsonObject(emptyMap())
            }
        }
        val repo = NasPowerActionRepository(gateway) { _, _ -> true }
        val first = launch { repo.perform(NasPowerAction.REBOOT) {} }; entered.await()
        assertTrue(runCatching { repo.perform(NasPowerAction.SHUTDOWN) {} }.isFailure)
        release.complete(Unit); first.join(); assertEquals(1, writes)
    }
}

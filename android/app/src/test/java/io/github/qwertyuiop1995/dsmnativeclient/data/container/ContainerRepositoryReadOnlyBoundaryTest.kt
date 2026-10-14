package io.github.qwertyuiop1995.dsmnativeclient.data.container

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLHandshakeException
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ContainerRepositoryReadOnlyBoundaryTest {
    @Test fun `仅支持v2的附属API和日志不会发出请求`() = runBlocking {
        val fixture = ContainerFixture().apply { versions = apis.associateWith { if (it == "SYNO.Docker.Container") 1..1 else 2..2 } }
        val overview = fixture.repository().containerOverview()
        assertEquals(ContainerSection.entries.toSet(), overview.unavailableSections)
        assertEquals(listOf("SYNO.Docker.Container"), fixture.calls.map { it.api })
    }
    @Test fun `概览所有Container读取强制v1且不提前读取日志`() = runBlocking {
        val fixture = ContainerFixture(); fixture.repository().containerOverview()
        assertEquals(apis.dropLast(1), fixture.calls.map { it.api }); assertTrue(fixture.calls.all { it.version == 1 })
        assertTrue(fixture.calls.none { it.api == "SYNO.Docker.Log" })
    }
    @Test fun `真实传输的会话和证书失败停止后续分区`() = runBlocking {
        for (kind in listOf(DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.TLS_UNTRUSTED)) {
            val fixture = ContainerFixture()
            if (kind == DsmErrorKind.SESSION_EXPIRED) fixture.errors = mapOf(("SYNO.Docker.Image" to "list") to 106)
            else fixture.before = { if (it.api == "SYNO.Docker.Image") throw SSLHandshakeException("Synthetic trust failure") }
            val error = runCatching { fixture.repository().containerOverview() }.exceptionOrNull() as? DsmFailure
            assertEquals(kind, error?.kind); assertEquals("SYNO.Docker.Image", fixture.calls.last().api)
        }
    }
    @Test fun `取消真实挂起读取不继续其他分区`() = runBlocking {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val fixture = ContainerFixture().apply { before = { if (it.api == "SYNO.Docker.Image") { entered.countDown(); release.await(5, TimeUnit.SECONDS) } } }
        val repo = fixture.repository()
        val job = async(Dispatchers.Default) { repo.containerOverview() }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS)); job.cancel(); release.countDown()
            assertTrue(runCatching { job.await() }.exceptionOrNull() is CancellationException)
            assertTrue(job.isCancelled); assertEquals("SYNO.Docker.Image", fixture.calls.last().api)
        } finally { release.countDown(); job.cancelAndJoin() }
    }
    @Test fun `概览不保留响应的未知元数据且原生运行字段正确`() = runBlocking {
        val fixture = ContainerFixture().apply { controls = listOf(JsonObject(ContainerFixture.control(running = true) + mapOf(
            "detail" to JsonPrimitive("/private/synthetic"), "token" to JsonPrimitive("Synthetic secret"), "environment" to JsonPrimitive("Synthetic environment")))) }
        val item = fixture.repository().containerOverview().containers.single()
        assertEquals("Synthetic container", item.name); assertEquals(ResourceState.RUNNING, item.state)
        assertEquals("", item.detail); assertTrue(item.metadata.isEmpty())
    }
    companion object { val apis = listOf("SYNO.Docker.Container", "SYNO.Docker.Image", "SYNO.Docker.Network", "SYNO.Docker.Project", "SYNO.Docker.Log") }
}

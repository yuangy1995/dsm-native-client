package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.network.VmmConsolePhase
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class VmmConsoleModelTest {
    private val fixture = VmmFixture().apply {
        guests = listOf(VmmFixture.guest(status = "running"))
        responseOverride = { call -> if (call.api == "SYNO.Virtualization.Guest" && call.method == "get")
            JsonObject(guests.single() + mapOf("kb_layout" to JsonPrimitive("en-us"), "is_online" to JsonPrimitive(true))) else null }
    }
    private var repository = fixture.repository(); private var allowed = true
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val model = VmmConsoleModel(scope, { repository }, { allowed })
    @org.junit.After fun cleanup() { model.clear(); scope.cancel() }
    private suspend fun ready() { withTimeout(5_000) { while (model.state.value.session == null && model.state.value.phase != VmmConsolePhase.FAILED) delay(10) } }
    private suspend fun target() = repository.virtualMachineManagement.controlTargets().single()
    @Test fun `打开保持原目标并且二次点击不产生连接`() = runBlocking {
        val target = target(); assertTrue(model.open(target)); assertFalse(model.open(target)); ready()
        assertNotNull(model.state.value.session); assertTrue(model.protects(target.id)); assertTrue(fixture.writes.isEmpty())
        assertFalse(model.reconnect()); model.clear(); assertNull(model.state.value.target)
    }
    @Test fun `进入后台关闭并保留手动重连重新读取目标`() = runBlocking {
        assertTrue(model.open(target())); ready(); val original = model.state.value.session!!
        model.disconnect(); assertNull(model.state.value.session); assertEquals(VmmConsolePhase.DISCONNECTED, original.transport.phase.value)
        val before = fixture.calls.size; delay(30); assertEquals(before, fixture.calls.size)
        assertTrue(model.reconnect()); ready(); assertNotEquals(original.policy.id, model.state.value.session!!.policy.id)
        model.disconnect(); fixture.guests = listOf(VmmFixture.guest(status = "shutdown"))
        assertTrue(model.reconnect()); ready(); assertEquals(VmmConsolePhase.FAILED, model.state.value.phase); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `操作互锁与权限改变不打开控制台`() = runBlocking {
        val target = target(); allowed = false; assertFalse(model.open(target)); assertNull(model.state.value.target)
        allowed = true; fixture.allowed = false; assertTrue(model.open(target)); ready(); assertEquals(VmmConsolePhase.FAILED, model.state.value.phase)
        assertNull(model.state.value.session); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `准备中的迟到响应不能恢复退出页面或新账号`() = runBlocking {
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val target = target()
        fixture.before = { if (it.api == "SYNO.Virtualization.Guest" && it.method == "get") { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) } }
        assertTrue(model.open(target)); assertTrue(entered.await(5, TimeUnit.SECONDS)); model.clear()
        repository = fixture.repository("new-generation", "new-identity"); release.countDown(); delay(100)
        assertNull(model.state.value.target); assertNull(model.state.value.session); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `连接失败时清除会话对象保留明确重连入口`() = runBlocking {
        assertTrue(model.open(target())); ready(); val session = model.state.value.session!!; session.transport.close(true)
        withTimeout(5_000) { while (model.state.value.session != null) delay(10) }
        assertEquals(VmmConsolePhase.FAILED, model.state.value.phase); assertNotNull(model.state.value.target)
        assertTrue(model.reconnect()); ready(); assertNotNull(model.state.value.session)
    }
}

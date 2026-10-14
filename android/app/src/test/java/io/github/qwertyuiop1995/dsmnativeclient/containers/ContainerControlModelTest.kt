package io.github.qwertyuiop1995.dsmnativeclient.containers

import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ContainerControlModelTest {
    private val fixture = ContainerFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private var store = ContainerControlStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private var canStart = true
    private fun model() = ContainerControlModel(scope, { repository }, { store }, { canStart })
    private suspend fun idle(model: ContainerControlModel) { withTimeout(8_000) { while (model.state.value.busy) delay(10) } }
    private suspend fun load(model: ContainerControlModel) { model.refresh(); idle(model); assertNull(model.state.value.failure) }
    private suspend fun send(model: ContainerControlModel, action: ContainerAction = ContainerAction.START) {
        assertTrue(model.request(model.state.value.targets, action)); assertTrue(model.confirm(model.state.value.confirmation!!)); idle(model)
    }
    private fun cold(old: ContainerControlModel, identity: String = "identity"): ContainerControlModel {
        old.clear(); repository = fixture.repository("new-generation", identity); store = ContainerControlStore(preferences); return model()
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `必须加载固定确认取消双击及外部忙碌零重复请求`() = runBlocking {
        val model = model(); assertFalse(model.request(emptyList(), ContainerAction.START)); load(model)
        assertTrue(model.request(model.state.value.targets, ContainerAction.START)); val confirmation = model.state.value.confirmation!!
        assertFalse(model.confirm(confirmation.copy(action = ContainerAction.DELETE))); model.cancel(); assertTrue(fixture.writes.isEmpty())
        canStart = false; assertFalse(model.request(model.state.value.targets, ContainerAction.START)); canStart = true
        assertTrue(model.request(model.state.value.targets, ContainerAction.START)); assertTrue(model.confirm(model.state.value.confirmation!!)); assertFalse(model.confirm(confirmation)); idle(model)
        assertNull(model.state.value.failure); assertEquals(ContainerStage.VERIFIED, model.state.value.record!!.items.single().stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `整批第二项失败保留首项终态停止后项且明确拒绝不因外部变化成功`() = runBlocking {
        fixture.controls = (1..3).map { ContainerFixture.control("id-$it", "Synthetic $it") }
        fixture.before = { if (it.method == "start" && it.fields["name"] == JsonPrimitive("Synthetic 2")) fixture.rejection = 105 }
        val model = model(); load(model); send(model)
        assertEquals(listOf(ContainerStage.VERIFIED, ContainerStage.REJECTED, ContainerStage.CANCELLED), model.state.value.record!!.items.map { it.stage })
        assertEquals(2, fixture.writes.size)
        fixture.rejection = null; fixture.controls = (1..3).map { ContainerFixture.control("id-$it", "Synthetic $it", running = true) }
        load(model); assertEquals(ContainerStage.REJECTED, model.state.value.record!!.items[1].stage); assertEquals(2, fixture.writes.size)
    }
    @Test fun `整批接受但未结束停止后项冷恢复只读不继续`() = runBlocking {
        fixture.controls = (1..2).map { ContainerFixture.control("id-$it", "Synthetic $it") }; fixture.applyWrite = false
        val model = model(); load(model); send(model)
        assertEquals(listOf(ContainerStage.ACCEPTED, ContainerStage.CANCELLED), model.state.value.record!!.items.map { it.stage })
        var next = cold(model); load(next); assertFalse(next.request(next.state.value.targets, ContainerAction.START)); assertEquals(1, fixture.writes.size)
        fixture.controls = listOf(ContainerFixture.control("id-1", "Synthetic 1", running = true), ContainerFixture.control("id-2", "Synthetic 2"))
        next = cold(next); load(next)
        assertEquals(listOf(ContainerStage.VERIFIED, ContainerStage.CANCELLED), next.state.value.record!!.items.map { it.stage }); assertEquals(1, fixture.writes.size)
    }
    @Test fun `丢回执保留原身份同名新容器不能认领启停但删除仅认原ID消失`() = runBlocking {
        val model = model(); load(model); fixture.before = { if (it.method == "start") throw IOException("Synthetic lost response") }; send(model)
        assertEquals(ContainerStage.SUBMITTED, model.state.value.record!!.items.single().stage)
        fixture.before = {}; fixture.controls = listOf(ContainerFixture.control(id = "new-id", running = true))
        var next = cold(model); load(next); assertTrue(next.state.value.record!!.pending); next.dismiss(); assertTrue(next.state.value.record!!.pending)
        fixture.controls = listOf(ContainerFixture.control(running = true)); next = cold(next); load(next)
        assertFalse(next.state.value.record!!.pending); assertEquals(1, fixture.writes.size)
    }
    @Test fun `丢失删除回执后同名新容器不被删除或阻止原ID恢复`() = runBlocking {
        val model = model(); load(model); fixture.before = { if (it.method == "delete") throw IOException("Synthetic lost response") }; send(model, ContainerAction.DELETE)
        fixture.before = {}; fixture.controls = listOf(ContainerFixture.control(id = "new-id"))
        val next = cold(model); load(next); assertEquals(ContainerStage.VERIFIED, next.state.value.record!!.items.single().stage)
        assertEquals(1, fixture.writes.size); assertEquals("new-id", next.state.value.targets.single().id)
    }
    @Test fun `记录写入失败零请求且不可忽略错误解锁`() = runBlocking {
        val model = model(); load(model); preferences.commitSucceeds = false; send(model)
        assertTrue(model.state.value.failure is ContainerFailure); assertTrue(fixture.writes.isEmpty()); model.dismiss()
        assertTrue(model.state.value.blocked)
    }
    @Test fun `不同账号不读取原记录重建后未知请求不重放`() = runBlocking {
        val model = model(); load(model); fixture.applyWrite = false; send(model)
        val next = cold(model, "different-identity"); load(next); assertNull(next.state.value.record); assertEquals(1, fixture.writes.size)
        next.clear(); repository = fixture.repository("third-generation"); val original = model(); load(original)
        assertTrue(original.state.value.record!!.pending); assertEquals(1, fixture.writes.size)
    }
    @Test fun `迟到回执只更新原记录不回填新页面`() = runBlocking {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { if (it.method == "start") { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) } }
        val model = model(); load(model); assertTrue(model.request(model.state.value.targets, ContainerAction.START)); assertTrue(model.confirm(model.state.value.confirmation!!))
        assertTrue(entered.await(5, TimeUnit.SECONDS)); model.clear(); repository = fixture.repository("next-generation", "different-identity"); release.countDown()
        delay(100); assertFalse(model.state.value.loaded); load(model); assertNull(model.state.value.record)
        assertEquals(1, fixture.writes.size)
    }
}

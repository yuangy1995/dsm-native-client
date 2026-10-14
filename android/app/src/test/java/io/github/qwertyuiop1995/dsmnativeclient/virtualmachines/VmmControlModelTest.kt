package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.*
import org.junit.Test

class VmmControlModelTest {
    private val fixture = VmmFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private var store = VmmControlStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private var canStart = true
    private fun model() = VmmControlModel(scope, { repository }, { store }, { canStart })
    private suspend fun idle(model: VmmControlModel) { withTimeout(8_000) { while (model.state.value.busy) delay(10) } }
    private suspend fun load(model: VmmControlModel) { model.refresh(); idle(model); assertNull(model.state.value.failure) }
    private suspend fun send(model: VmmControlModel, action: VmmAction = VmmAction.START) {
        assertTrue(model.request(model.state.value.targets, action)); assertTrue(model.confirm(model.state.value.confirmation!!)); idle(model)
    }
    private fun cold(old: VmmControlModel, identity: String = "identity"): VmmControlModel {
        old.clear(); repository = fixture.repository("new-generation", identity); store = VmmControlStore(preferences); return model()
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `加载固定确认取消双击及外部忙碌零重复请求`() = runBlocking {
        val model = model(); assertFalse(model.request(emptyList(), VmmAction.START)); load(model)
        assertTrue(model.request(model.state.value.targets, VmmAction.START)); val confirmation = model.state.value.confirmation!!
        assertFalse(model.confirm(confirmation.copy(action = VmmAction.DELETE))); model.cancel(); assertTrue(fixture.writes.isEmpty())
        canStart = false; assertFalse(model.request(model.state.value.targets, VmmAction.START)); canStart = true
        assertTrue(model.request(model.state.value.targets, VmmAction.START)); assertTrue(model.confirm(model.state.value.confirmation!!)); assertFalse(model.confirm(confirmation)); idle(model)
        assertNull(model.state.value.failure); assertEquals(VmmStage.VERIFIED, model.state.value.record!!.items.single().stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `整批第二项拒绝保留首项停止后项且拒绝不变成功`() = runBlocking {
        fixture.guests = (1..3).map { VmmFixture.guest("id-$it", "Synthetic $it") }
        fixture.before = { if (it.method == "poweron" && it.fields["guest_id"] == JsonPrimitive("id-2")) fixture.rejection = 105 }
        val model = model(); load(model); send(model)
        assertEquals(listOf(VmmStage.VERIFIED, VmmStage.REJECTED, VmmStage.CANCELLED), model.state.value.record!!.items.map { it.stage })
        assertEquals(2, fixture.writes.size)
        fixture.rejection = null; fixture.guests = (1..3).map { VmmFixture.guest("id-$it", "Synthetic $it", "running") }
        load(model); assertEquals(VmmStage.REJECTED, model.state.value.record!!.items[1].stage); assertEquals(2, fixture.writes.size)
    }
    @Test fun `接受但未结束停止后项冷恢复只读不继续`() = runBlocking {
        fixture.guests = (1..2).map { VmmFixture.guest("id-$it", "Synthetic $it") }; fixture.applyWrite = false
        val model = model(); load(model); send(model)
        assertEquals(listOf(VmmStage.ACCEPTED, VmmStage.CANCELLED), model.state.value.record!!.items.map { it.stage })
        var next = cold(model); load(next); assertTrue(next.hasPending()); assertFalse(next.request(next.state.value.targets, VmmAction.START)); assertEquals(1, fixture.writes.size)
        fixture.guests = listOf(VmmFixture.guest("id-1", "Synthetic 1", "running"), VmmFixture.guest("id-2", "Synthetic 2"))
        next = cold(next); load(next)
        assertEquals(listOf(VmmStage.VERIFIED, VmmStage.CANCELLED), next.state.value.record!!.items.map { it.stage }); assertEquals(1, fixture.writes.size)
    }
    @Test fun `丢失控制或删除回执后外部变化不能认领或重发`() = runBlocking {
        for (action in listOf(VmmAction.START, VmmAction.DELETE)) {
            preferences.edit().clear().commit(); fixture.guests = listOf(VmmFixture.guest()); fixture.calls.clear()
            val model = model(); load(model); fixture.before = { if (it.method == action.command) throw IOException("lost response") }; send(model, action)
            assertEquals(VmmStage.SUBMITTED, model.state.value.record!!.items.single().stage)
            fixture.before = {}; fixture.guests = if (action == VmmAction.DELETE) emptyList() else listOf(VmmFixture.guest(status = "running"))
            val next = cold(model); load(next); assertTrue(next.hasPending()); next.dismiss(); assertTrue(next.hasPending())
            assertEquals(VmmStage.SUBMITTED, next.state.value.record!!.items.single().stage); assertEquals(1, fixture.writes.size); next.clear()
        }
    }
    @Test fun `内部重启接受后跨重启仍不以running认领`() = runBlocking {
        fixture.guests = listOf(VmmFixture.guest(status = "running")); val model = model(); load(model); send(model, VmmAction.RESTART)
        assertEquals(VmmStage.ACCEPTED, model.state.value.record!!.items.single().stage)
        val next = cold(model); load(next); assertTrue(next.hasPending()); assertEquals(1, fixture.writes.size)
    }
    @Test fun `未知重启只保护原虚拟机其他虚拟机可单独操作`() = runBlocking {
        fixture.guests = listOf(VmmFixture.guest(status = "running"), VmmFixture.guest("other", "Other VM"))
        val model = model(); load(model)
        assertTrue(model.request(listOf(model.state.value.targets.first()), VmmAction.RESTART)); assertTrue(model.confirm(model.state.value.confirmation!!)); idle(model)
        val next = cold(model); load(next)
        assertTrue(next.request(listOf(next.state.value.targets.single { it.id == "other" }), VmmAction.START))
        assertTrue(next.confirm(next.state.value.confirmation!!)); idle(next)
        assertEquals(2, fixture.writes.size); assertEquals(2, next.state.value.records.size)
        assertTrue(next.hasPending("synthetic-guest")); assertFalse(next.hasPending("other"))
        next.dismiss(); assertEquals(1, next.state.value.records.size); assertTrue(next.state.value.records.single().pending)
    }
    @Test fun `写前落盘失败零请求且不可通过关闭绕过`() = runBlocking {
        val model = model(); load(model); preferences.commitSucceeds = false; send(model)
        assertTrue(model.state.value.failure is VmmFailure); assertTrue(fixture.writes.isEmpty()); model.dismiss()
        assertTrue(model.state.value.blocked); assertTrue(model.hasPending())
    }
    @Test fun `不同账号不读取旧记录同身份重新登录保留保护`() = runBlocking {
        val model = model(); load(model); fixture.applyWrite = false; send(model)
        val next = cold(model, "different"); load(next); assertNull(next.state.value.record); assertEquals(1, fixture.writes.size)
        next.clear(); repository = fixture.repository("third-generation"); val original = model(); load(original)
        assertTrue(original.hasPending()); assertEquals(1, fixture.writes.size)
    }
    @Test fun `迟到回执不能回填新账号页面`() = runBlocking {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { if (it.method == "poweron") { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) } }
        val model = model(); load(model); assertTrue(model.request(model.state.value.targets, VmmAction.START)); assertTrue(model.confirm(model.state.value.confirmation!!))
        assertTrue(entered.await(5, TimeUnit.SECONDS)); model.clear(); repository = fixture.repository("next", "different"); release.countDown()
        delay(100); assertFalse(model.state.value.loaded); load(model); assertNull(model.state.value.record); assertEquals(1, fixture.writes.size)
    }
    @Test fun `已接受删除仅原来源完整清单缺原ID才完成`() = runBlocking {
        val model = model(); load(model); fixture.applyWrite = false; send(model, VmmAction.DELETE)
        fixture.total = 1; fixture.guests = emptyList(); val next = cold(model); next.refresh(); idle(next)
        assertNotNull(next.state.value.failure); assertTrue(next.hasPending())
        fixture.total = null; fixture.guests = listOf(VmmFixture.guest(id = "new-id")); load(next)
        assertEquals(VmmStage.VERIFIED, next.state.value.record!!.items.single().stage); assertEquals(1, fixture.writes.size)
    }
}

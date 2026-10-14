package io.github.qwertyuiop1995.dsmnativeclient.containers

import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ContainerNetworkModelTest {
    private val fixture = ContainerFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private var store = ContainerNetworkStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private var canStart = true
    private fun model() = ContainerNetworkModel(scope, { repository }, { store }, { canStart })
    private suspend fun idle(model: ContainerNetworkModel) { withTimeout(8_000) { while (model.state.value.busy) delay(10) } }
    private suspend fun load(model: ContainerNetworkModel) { model.refresh(); idle(model); assertNull(model.state.value.failure) }
    private suspend fun create(model: ContainerNetworkModel, name: String = "Synthetic-new") {
        assertTrue(model.openCreate()); model.edit(ContainerNetworkDraft(name)); assertTrue(model.requestCreate()); assertTrue(model.confirm(model.state.value.confirmation!!)); idle(model)
    }
    private fun cold(old: ContainerNetworkModel, identity: String = "identity"): ContainerNetworkModel {
        old.clear(); repository = fixture.repository("new-generation", identity); store = ContainerNetworkStore(preferences); return model()
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `表单固定确认取消外部忙碌和重复点击不会重复创建`() = runBlocking {
        val model = model(); assertFalse(model.openCreate()); load(model); assertTrue(model.openCreate()); model.edit(ContainerNetworkDraft("Synthetic-new")); assertTrue(model.requestCreate())
        val confirmation = model.state.value.confirmation!!; model.cancel(); assertFalse(model.confirm(confirmation)); assertTrue(fixture.writes.isEmpty())
        assertTrue(model.requestCreate()); canStart = false; assertFalse(model.confirm(model.state.value.confirmation!!)); canStart = true
        assertTrue(model.confirm(model.state.value.confirmation!!)); assertFalse(model.confirm(confirmation)); idle(model)
        assertNull(model.state.value.failure); assertEquals(ContainerStage.VERIFIED, model.state.value.activities.single().items.single().stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `丢创建回执重启后同名只标记已存在而不认领创建`() = runBlocking {
        val model = model(); load(model); fixture.before = { if (it.method == "create") throw IOException("Synthetic lost response") }; create(model)
        assertEquals(ContainerStage.SUBMITTED, model.state.value.activities.single().items.single().stage)
        fixture.before = {}; fixture.networks = fixture.networks + ContainerFixture.network("external", "Synthetic-new")
        val next = cold(model); load(next); val item = next.state.value.activities.single().items.single()
        assertEquals(ContainerStage.VERIFIED, item.stage); assertFalse(item.accepted); assertEquals(1, fixture.writes.size)
    }
    @Test fun `已接受但配置不匹配持续保护并阻止同名创建`() = runBlocking {
        val model = model(); load(model); fixture.applyWrite = false; create(model)
        fixture.networks = fixture.networks + JsonObject(ContainerFixture.network("external", "Synthetic-new") + ("enable_ipv6" to JsonPrimitive(true)))
        val next = cold(model); load(next); assertTrue(next.state.value.activities.single().pending); assertTrue(next.openCreate()); next.edit(ContainerNetworkDraft("Synthetic-new"))
        assertFalse(next.requestCreate()); assertEquals(1, fixture.writes.size)
    }
    @Test fun `删除批次保留已完成项明确拒绝后停止且不会被外部消失覆盖`() = runBlocking {
        fixture.networks = (1..3).map { ContainerFixture.network("id-$it", "Synthetic-$it") }
        fixture.before = { if (it.method == "remove" && it.fields.getValue("networks").jsonArray.single().jsonObject["id"] == JsonPrimitive("id-2")) fixture.failedNetworks = JsonArray(listOf(JsonPrimitive("failure"))) }
        val model = model(); load(model); assertTrue(model.requestDelete(model.state.value.networks)); assertTrue(model.confirm(model.state.value.confirmation!!)); idle(model)
        assertEquals(listOf(ContainerStage.VERIFIED, ContainerStage.REJECTED, ContainerStage.CANCELLED), model.state.value.activities.single().items.map { it.stage })
        fixture.networks = emptyList(); val next = cold(model); load(next)
        assertEquals(ContainerStage.REJECTED, next.state.value.activities.single().items[1].stage); assertEquals(2, fixture.writes.size)
    }
    @Test fun `未知删除仅按原ID消失恢复不删除同名替代`() = runBlocking {
        val model = model(); load(model); fixture.before = { if (it.method == "remove") throw IOException("Synthetic lost response") }
        assertTrue(model.requestDelete(model.state.value.networks)); assertTrue(model.confirm(model.state.value.confirmation!!)); idle(model)
        fixture.before = {}; fixture.networks = listOf(ContainerFixture.network("new-id")); val next = cold(model); load(next)
        assertEquals(ContainerStage.VERIFIED, next.state.value.activities.single().items.single().stage); assertFalse(next.state.value.activities.single().items.single().accepted)
        assertEquals("new-id", next.state.value.networks.single().id); assertEquals(1, fixture.writes.size)
    }
    @Test fun `删除确认取消零写在途取消停止批次冷恢复不重发`() = runBlocking {
        fixture.networks = (1..2).map { ContainerFixture.network("id-$it", "Synthetic-$it") }
        val model = model(); load(model); assertTrue(model.requestDelete(model.state.value.networks))
        val cancelled = model.state.value.confirmation!!; model.cancel(); assertFalse(model.confirm(cancelled)); assertTrue(fixture.writes.isEmpty())
        fixture.before = { if (it.method == "remove") throw CancellationException("Synthetic cancellation") }
        assertTrue(model.requestDelete(model.state.value.networks)); assertTrue(model.confirm(model.state.value.confirmation!!)); idle(model)
        assertEquals(listOf(ContainerStage.SUBMITTED, ContainerStage.CANCELLED), model.state.value.activities.single().items.map { it.stage })
        assertEquals("remove", fixture.calls.last().method); assertEquals(1, fixture.writes.size)
        fixture.before = {}; val next = cold(model); load(next)
        assertTrue(next.state.value.activities.single().pending); assertEquals(1, fixture.writes.size)
        fixture.networks = fixture.networks.filter { it["id"] != JsonPrimitive("id-1") }; load(next)
        assertEquals(listOf(ContainerStage.VERIFIED, ContainerStage.CANCELLED), next.state.value.activities.single().items.map { it.stage })
        assertEquals("id-2", next.state.value.networks.single().id); assertEquals(1, fixture.writes.size)
    }
    @Test fun `存储失败零写不同身份不读原记录`() = runBlocking {
        val model = model(); load(model); preferences.commitSucceeds = false; create(model)
        assertTrue(model.state.value.failure is ContainerFailure); assertTrue(fixture.writes.isEmpty())
        preferences.commitSucceeds = true; val next = cold(model, "other-identity"); load(next); assertTrue(next.state.value.activities.isEmpty())
    }
}

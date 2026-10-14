package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.*
import org.junit.Test

class VmmAssetModelTest {
    private val fixture = VmmFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private var store = VmmAssetStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private var allowed = true
    private fun model() = VmmAssetModel(scope, { repository }, { store }, { allowed })
    private suspend fun idle(model: VmmAssetModel) { withTimeout(8_000) { while (model.state.value.busy) delay(10) } }
    private suspend fun load(model: VmmAssetModel, kind: VmmAssetKind) { model.refresh(kind); idle(model); assertNull(model.state.value.failure) }
    private suspend fun send(model: VmmAssetModel, kind: VmmAssetKind) {
        assertTrue(if (kind == VmmAssetKind.NETWORK) model.requestNetworks(model.state.value.networks!!.networks) else model.requestImages(model.state.value.images!!.images))
        assertTrue(model.confirm(model.state.value.confirmation!!)); idle(model)
    }
    private fun cold(old: VmmAssetModel, identity: String = "identity"): VmmAssetModel {
        old.clear(); repository = fixture.repository("next", identity); store = VmmAssetStore(preferences); return model()
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `网络取消零写改名一次保存到完整回读`() = runBlocking {
        val model = model(); load(model, VmmAssetKind.NETWORK); val target = model.state.value.networks!!.networks.single()
        assertTrue(model.requestNetworks(listOf(target))); model.cancel(); assertTrue(fixture.writes.isEmpty())
        assertTrue(model.saveNetworkName(target, "Renamed")); assertFalse(model.saveNetworkName(target, "Again")); idle(model)
        assertEquals(VmmStage.VERIFIED, model.state.value.records.single().items.single().stage)
        assertEquals("Renamed", model.state.value.networks!!.networks.single().name); assertEquals(1, fixture.writes.size)
    }
    @Test fun `网络和映像未知接受分阶段恢复不续批`() = runBlocking {
        for (kind in VmmAssetKind.entries) {
            preferences.edit().clear().commit(); fixture.calls.clear(); fixture.applyWrite = false
            fixture.networks = (1..3).map { VmmFixture.network("network-$it", "Network $it") }
            fixture.images = (1..3).map { VmmFixture.image("image-$it", "Image $it") }
            val model = model(); load(model, kind); send(model, kind)
            assertEquals(listOf(VmmStage.ACCEPTED, VmmStage.CANCELLED, VmmStage.CANCELLED), model.state.value.records.single().items.map { it.stage })
            if (kind == VmmAssetKind.NETWORK) fixture.networks = fixture.networks.drop(1) else fixture.images = fixture.images.drop(1)
            val next = cold(model); load(next, kind)
            assertEquals(VmmStage.VERIFIED, next.state.value.records.single().items.first().stage); assertEquals(1, fixture.writes.size); next.clear()
        }
    }
    @Test fun `网络和映像确认取消零写发送中取消保留原项且冷恢复不续批`() = runBlocking {
        for (kind in VmmAssetKind.entries) {
            preferences.edit().clear().commit(); fixture.calls.clear(); fixture.applyWrite = false
            fixture.networks = (1..2).map { VmmFixture.network("network-$it", "Network $it") }
            fixture.images = (1..2).map { VmmFixture.image("image-$it", "Image $it") }
            val model = model(); load(model, kind)
            assertTrue(if (kind == VmmAssetKind.NETWORK) model.requestNetworks(model.state.value.networks!!.networks) else model.requestImages(model.state.value.images!!.images))
            model.cancel(); assertNull(model.state.value.confirmation); assertTrue(fixture.writes.isEmpty())
            fixture.before = { if (it.method == "delete") throw CancellationException("synthetic after send") }
            send(model, kind)
            val stored = store.records(repository.owner!!).single()
            assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.CANCELLED), stored.items.map { it.stage })
            fixture.before = {}; fixture.networks = emptyList(); fixture.images = emptyList()
            val next = cold(model); load(next, kind)
            assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.CANCELLED), next.state.value.records.single().items.map { it.stage })
            assertEquals(1, fixture.writes.size); next.clear()
        }
    }
    @Test fun `第二项拒绝保留首项并终止后项`() = runBlocking {
        fixture.images = (1..3).map { VmmFixture.image("image-$it", "Image $it") }
        fixture.before = { if (it.method == "delete" && it.fields["image_id"] == JsonPrimitive("image-2")) fixture.rejection = 105 }
        val model = model(); load(model, VmmAssetKind.IMAGE); send(model, VmmAssetKind.IMAGE)
        assertEquals(listOf(VmmStage.VERIFIED, VmmStage.REJECTED, VmmStage.CANCELLED), model.state.value.records.single().items.map { it.stage })
        assertEquals(2, fixture.writes.size)
    }
    @Test fun `缺回执外部删除不能认领重建不能清理保护`() = runBlocking {
        val model = model(); load(model, VmmAssetKind.IMAGE)
        fixture.before = { if (it.method == "delete") throw IOException("lost") }; send(model, VmmAssetKind.IMAGE)
        fixture.before = {}; fixture.images = emptyList(); val next = cold(model); load(next, VmmAssetKind.IMAGE); next.dismiss()
        assertEquals(VmmStage.SUBMITTED, next.state.value.records.single().items.single().stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `保存失败零写拒绝外部忙碌且不同账号不读取记录`() = runBlocking {
        val model = model(); load(model, VmmAssetKind.NETWORK); allowed = false
        assertFalse(model.requestNetworks(model.state.value.networks!!.networks)); allowed = true
        preferences.commitSucceeds = false; send(model, VmmAssetKind.NETWORK); assertTrue(fixture.writes.isEmpty()); assertNotNull(model.state.value.failure)
        preferences.commitSucceeds = true; val next = cold(model, "different"); load(next, VmmAssetKind.NETWORK); assertTrue(next.state.value.records.isEmpty())
    }
    @Test fun `改名接受后重建只按原ID新名称及原拓扑完成`() = runBlocking {
        val model = model(); load(model, VmmAssetKind.NETWORK); fixture.applyWrite = false
        assertTrue(model.saveNetworkName(model.state.value.networks!!.networks.single(), "Renamed")); idle(model)
        fixture.networks = listOf(VmmFixture.network(name = "Renamed", type = "private")); var next = cold(model); load(next, VmmAssetKind.NETWORK)
        assertTrue(next.state.value.records.single().pending)
        fixture.networks = listOf(VmmFixture.network(name = "Renamed")); next = cold(next); load(next, VmmAssetKind.NETWORK)
        assertFalse(next.state.value.records.single().pending); assertEquals(1, fixture.writes.size)
    }
}
